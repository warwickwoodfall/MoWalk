import Foundation
import CoreLocation
import AVFoundation
import UIKit
import Observation

/// Wayfinder: follows a route on the phone's GPS, points a
/// compass arrow down the path, and calls out turns and going off route by voice +
/// haptics, which keeps working with the phone locked in a pocket.
@Observable
final class Navigator: NSObject, CLLocationManagerDelegate {
    // library
    private(set) var routes: [Route] = []
    private(set) var route: Route?
    var showFollow = false
    var showRoutes = false

    // live state
    private(set) var position: CLLocationCoordinate2D?
    private(set) var source = "no position"
    private(set) var accuracy: Double = 0
    private(set) var heading: Double?            // phone compass (true north)
    private(set) var headingAccuracy: Double = -1
    private(set) var course: Double?             // direction of travel when moving
    private(set) var along: Double = 0
    private(set) var offM: Double = 0
    private(set) var offRoute = false
    private(set) var aimBearing: Double?         // bearing from us to the aim point
    private(set) var nextTurn: (turn: Route.Turn, dist: Double)?
    private(set) var thenTurn: Route.Turn?       // a second turn hard on the heels of the next
    private(set) var arrived = false

    var voiceOn = UserDefaults.standard.object(forKey: "voiceOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceOn, forKey: "voiceOn") }
    }
    var suppressVoice = false                    // an interview is recording

    private let lm = CLLocationManager()
    private let synth = AVSpeechSynthesizer()
    private var bg: CLBackgroundActivitySession?
    private var phoneFix: CLLocation?
    private var hint: Int?
    private var spoken: [Int: Int] = [:]         // turn index -> 1 (approach) / 2 (now)
    @ObservationIgnored private var offSince: Date?
    @ObservationIgnored private var offSaidAt: Date?

    static let aimAhead = 60.0, offOn = 40.0, offOff = 30.0

    let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override init() {
        super.init()
        lm.delegate = self
        lm.activityType = .fitness
        lm.headingFilter = 2
        loadRoutes()
    }

    // MARK: library

    var builtIn: URL? { Bundle.main.url(forResource: "mowalk_route", withExtension: "gpx") }

    func loadRoutes() {
        var r: [Route] = []
        if let b = builtIn, let m = Route(gpxURL: b) { r.append(m) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files.filter({ $0.pathExtension.lowercased() == "gpx" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let x = Route(gpxURL: f) { r.append(x) }
        }
        routes = r
    }

    func isBuiltIn(_ r: Route) -> Bool { r.id == builtIn?.lastPathComponent }

    /// Copy a GPX in (Files picker, or "Open in Mo'Walk" from WhatsApp / Mail / AirDrop).
    @discardableResult
    func importGPX(_ url: URL) -> Route? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard Route(gpxURL: url) != nil else { return nil }        // check it before keeping it
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if dest.pathExtension.lowercased() != "gpx" { dest = dest.appendingPathExtension("gpx") }
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil, let r = Route(gpxURL: dest) else {
            try? FileManager.default.removeItem(at: dest); return nil
        }
        loadRoutes()
        return r
    }

    func deleteRoute(_ r: Route) {
        guard !isBuiltIn(r) else { return }
        if route?.id == r.id { stop() }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(r.id))
        loadRoutes()
    }

    // MARK: follow

    func start(_ r: Route) {
        route = r; hint = nil; spoken = [:]; offSince = nil; offSaidAt = nil; offRoute = false; arrived = false
        nextTurn = nil; thenTurn = nil; aimBearing = nil
        lm.requestWhenInUseAuthorization()
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.distanceFilter = 2
        lm.pausesLocationUpdatesAutomatically = false
        lm.allowsBackgroundLocationUpdates = true          // cues keep coming with the phone locked
        lm.showsBackgroundLocationIndicator = true
        bg = CLBackgroundActivitySession()
        lm.startUpdatingLocation()
        lm.startUpdatingHeading()
        showFollow = true
        say("Following \(r.name). \(String(format: "%.1f", r.length / 1000)) kilometres.")
    }

    func stop() {
        route = nil; showFollow = false
        lm.stopUpdatingLocation(); lm.stopUpdatingHeading()
        lm.allowsBackgroundLocationUpdates = false
        bg?.invalidate(); bg = nil
    }

    // MARK: inputs

    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let x = l.last, x.horizontalAccuracy > 0 else { return }
        phoneFix = x
        if x.speed > 0.6, x.course >= 0 { course = x.course }
        update()
    }
    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        headingAccuracy = h.headingAccuracy
        heading = h.headingAccuracy >= 0 ? (h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading) : nil
    }

    // MARK: the work

    private func update() {
        guard let r = route else { return }
        if let p = phoneFix, Date().timeIntervalSince(p.timestamp) < 15, p.horizontalAccuracy <= 50 {
            position = p.coordinate; source = "Phone GPS"; accuracy = p.horizontalAccuracy
        } else {
            source = "waiting for GPS"; return
        }
        guard let here = position else { return }

        let sn = r.snap(here, near: hint)
        hint = sn.seg; along = sn.along; offM = sn.off
        if offM > Self.offOn { offRoute = true } else if offM < Self.offOff { offRoute = false }

        // aim: 60 m down the line, or straight back to it when off route
        let aim = offRoute ? sn.at : r.point(at: along + Self.aimAhead)
        aimBearing = Route.dist(here, aim) > 3 ? Route.bearing(here, aim) : nil

        // next turn (and one right after it)
        if let i = r.turns.firstIndex(where: { $0.along > along + 3 }) {
            let t = r.turns[i]
            nextTurn = (t, t.along - along)
            thenTurn = i + 1 < r.turns.count && r.turns[i + 1].along - t.along < 50 ? r.turns[i + 1] : nil
            cue(i, t, t.along - along)
        } else { nextTurn = nil; thenTurn = nil }

        offRouteCue()
        if !arrived && r.length - along < 30 && offM < Self.offOff {
            arrived = true; buzz(.success); say("You've arrived. Well walked.")
        }
    }

    private func cue(_ i: Int, _ t: Route.Turn, _ d: Double) {
        guard !offRoute else { return }
        let then = thenTurn.map { ", then \($0.words)" } ?? ""
        if d <= 60 && d > 20 && (spoken[i] ?? 0) < 1 {
            spoken[i] = 1; buzz(.warning)
            say("In \(Int((d / 10).rounded()) * 10) metres, \(t.words)\(then).")
        } else if d <= 15 && (spoken[i] ?? 0) < 2 {
            spoken[i] = 2; buzz(.success)
            say("\(t.words.prefix(1).uppercased() + t.words.dropFirst()) now\(then).")
        }
    }

    private func offRouteCue() {
        let now = Date()
        if offRoute {
            if offSince == nil { offSince = now }
            // sustained 8 s, then a reminder every 90 s
            if now.timeIntervalSince(offSince!) > 8,
               offSaidAt == nil || now.timeIntervalSince(offSaidAt!) > 90 {
                offSaidAt = now; buzz(.error)
                say("Off route. The path is \(Int((offM / 10).rounded()) * 10) metres away.")
            }
        } else {
            if offSaidAt != nil { buzz(.success); say("Back on route.") }
            offSince = nil; offSaidAt = nil
        }
    }

    // MARK: output

    private func buzz(_ t: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(t)
    }

    private func say(_ text: String) {
        guard voiceOn, !suppressVoice else { return }
        let s = AVAudioSession.sharedInstance()
        // (never while an interview records: suppressVoice; after one, leave the
        // earpiece-routed record category for the loudspeaker)
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? s.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-GB")
        synth.speak(u)
    }
}
