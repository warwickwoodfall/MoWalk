import Foundation
import CoreLocation
import Observation

/// One thing captured on a walk: a photo, an interview or a note, tagged with where it happened.
struct Capture: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case photo, audio, note }
    var id: String
    var kind: Kind
    var time: Date
    var lat: Double?
    var lon: Double?
    var km: Double?             // distance into the walk when it was taken
    var file: String?           // media file name inside the walk folder
    var title: String           // interviewee name / note text / photo caption
    var consent: Bool?          // interviews: verbal consent given on the recording
    var duration: Double?       // interviews: seconds
    var walk: String?           // walk it belongs to, e.g. "20261120-walk1" (nil = not on a walk)
}

/// One recorded walk.
struct Walk: Codable, Identifiable, Hashable {
    var id: String
    var num: Int
    var start: Date
    var end: Date
    var odoM: Double
    var movingS: Int
    var active: Bool

    var title: String { "Walk \(num)" }
    var durationS: Int { max(0, Int(end.timeIntervalSince(start))) }
    var stoppedS: Int { max(0, durationS - movingS) }
}

/// Walks, their tracks (phone GPS) and everything captured on them.
/// Lives in Documents/walk/ (visible in the Files app): walks.json, captures.json,
/// captures.csv, tracks/<walk>.csv and the media.
@Observable
final class CaptureStore: NSObject, CLLocationManagerDelegate {
    private(set) var captures: [Capture] = []
    private(set) var walks: [Walk] = []          // newest first
    private(set) var walkID: String?             // the walk being recorded
    private(set) var kmhNow: Double = 0          // speed over the last few minutes
    private(set) var accuracy: Double = 0        // latest GPS accuracy, metres
    private(set) var location: CLLocation?

    private let loc = CLLocationManager()
    private var bg: CLBackgroundActivitySession?
    private var crumb: CLLocation?
    private var recent: [(Date, Double)] = []    // (time, odo) over the last 5 min
    private var lastTrackPt: CLLocation?
    private var lastSave = Date.distantPast

    let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("walk", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var capturesURL: URL { dir.appendingPathComponent("captures.json") }
    private var walksURL: URL { dir.appendingPathComponent("walks.json") }
    private var trackDir: URL {
        let d = dir.appendingPathComponent("tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    override init() {
        super.init()
        if let d = try? Data(contentsOf: capturesURL), let c = try? Self.decoder.decode([Capture].self, from: d) { captures = c }
        if let d = try? Data(contentsOf: walksURL), let w = try? Self.decoder.decode([Walk].self, from: d) { walks = w }
        loc.delegate = self
        loc.activityType = .fitness
        loc.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        loc.requestWhenInUseAuthorization()
        loc.startUpdatingLocation()
        // the app was closed mid-walk: carry on with the same walk
        if let w = walks.first(where: { $0.active }) { resume(w.id) }
    }

    var currentWalk: Walk? { walks.first { $0.id == walkID } }

    // MARK: walking

    func startWalk() {
        guard walkID == nil else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        let day = f.string(from: Date())
        let num = (walks.filter { $0.id.hasPrefix("\(day)-walk") }
                    .compactMap { Int($0.id.components(separatedBy: "-walk").last ?? "") }.max() ?? 0) + 1
        let id = "\(day)-walk\(num)"
        walks.insert(Walk(id: id, num: walks.count + 1, start: Date(), end: Date(), odoM: 0, movingS: 0, active: true), at: 0)
        saveWalks()
        resume(id)
    }

    private func resume(_ id: String) {
        walkID = id; crumb = nil; recent = []; lastTrackPt = nil; kmhNow = 0
        loc.desiredAccuracy = kCLLocationAccuracyBest
        loc.distanceFilter = 3
        loc.pausesLocationUpdatesAutomatically = false
        loc.allowsBackgroundLocationUpdates = true          // keeps tracking in a pocket, screen locked
        loc.showsBackgroundLocationIndicator = true
        bg = CLBackgroundActivitySession()
        loc.startUpdatingLocation()
    }

    func endWalk() {
        guard let id = walkID, let i = walks.firstIndex(where: { $0.id == id }) else { return }
        walks[i].end = Date(); walks[i].active = false
        walkID = nil
        saveWalks()
        bg?.invalidate(); bg = nil
        loc.allowsBackgroundLocationUpdates = false
        loc.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        loc.distanceFilter = kCLDistanceFilterNone
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let last = l.last else { return }
        location = last
        accuracy = last.horizontalAccuracy
        if walkID != nil { for x in l { walkFix(x) } }
    }

    /// Distance rules: a breadcrumb every 10 m (filters GPS jitter), jumps faster than
    /// 4 m/s ignored (GPS glitches), time between crumbs under a minute counts as moving.
    private func walkFix(_ l: CLLocation) {
        guard l.horizontalAccuracy > 0, l.horizontalAccuracy <= 25,         // poor sky: don't count it
              let id = walkID, let i = walks.firstIndex(where: { $0.id == id }) else { return }
        if lastTrackPt == nil || l.distance(from: lastTrackPt!) >= 5 {
            lastTrackPt = l
            let line = "\(Int(l.timestamp.timeIntervalSince1970)),\(String(format: "%.6f,%.6f", l.coordinate.latitude, l.coordinate.longitude))\n"
            let url = trackFile(id)
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
        if let c = crumb {
            let d = l.distance(from: c), dt = l.timestamp.timeIntervalSince(c.timestamp)
            if d >= 10 && d <= 4 * dt + 30 {
                walks[i].odoM += d
                if dt < 60 { walks[i].movingS += Int(dt.rounded()) }
                crumb = l
                recent.append((l.timestamp, walks[i].odoM))
                recent.removeAll { l.timestamp.timeIntervalSince($0.0) > 300 }
                if let first = recent.first, l.timestamp.timeIntervalSince(first.0) > 20 {
                    kmhNow = (walks[i].odoM - first.1) / l.timestamp.timeIntervalSince(first.0) * 3.6
                }
            }
        } else { crumb = l; recent = [(l.timestamp, walks[i].odoM)] }
        walks[i].end = l.timestamp
        if Date().timeIntervalSince(lastSave) > 15 { saveWalks() }
    }

    // MARK: captures

    /// New capture id, e.g. "photo-20261120-231504"
    func newID(_ kind: Capture.Kind) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(kind.rawValue)-\(f.string(from: Date()))"
    }

    /// Record a capture at the phone's position, filed under the walk in progress.
    func add(kind: Capture.Kind, id: String, file: String?, title: String,
             consent: Bool? = nil, duration: Double? = nil) {
        var c = Capture(id: id, kind: kind, time: Date(), file: file, title: title,
                        consent: consent, duration: duration, walk: walkID)
        if let p = location, Date().timeIntervalSince(p.timestamp) < 120 {
            c.lat = p.coordinate.latitude; c.lon = p.coordinate.longitude
        }
        if let w = currentWalk { c.km = w.odoM / 1000 }
        captures.insert(c, at: 0)
        save()
    }

    func delete(_ c: Capture) {
        if let f = c.file { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        captures.removeAll { $0.id == c.id }
        save()
    }

    func url(_ c: Capture) -> URL? { c.file.map { dir.appendingPathComponent($0) } }
    func captures(in walkID: String?) -> [Capture] { captures.filter { $0.walk == walkID } }

    // MARK: tracks, GPX, zip

    func trackFile(_ walkID: String) -> URL { trackDir.appendingPathComponent("\(walkID).csv") }

    /// The walk's track (time, lat, lon).
    func track(_ walkID: String) -> [(Date, Double, Double)] {
        guard let text = try? String(contentsOf: trackFile(walkID), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            let f = $0.split(separator: ",")
            guard f.count == 3, let t = Double(f[0]), let la = Double(f[1]), let lo = Double(f[2]) else { return nil }
            return (Date(timeIntervalSince1970: t), la, lo)
        }
    }

    /// Delete a walk: its record, track and every capture filed under it.
    func deleteWalk(_ w: Walk) {
        if w.id == walkID { endWalk() }
        for c in captures(in: w.id) { delete(c) }
        try? FileManager.default.removeItem(at: trackFile(w.id))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(w.id).gpx"))
        walks.removeAll { $0.id == w.id }
        saveWalks()
    }

    /// GPX of a walk: the track plus a waypoint for every photo, interview and note on it.
    func exportGPX(_ w: Walk) -> URL? {
        let iso = ISO8601DateFormatter()
        func x(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var g = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        g += "<gpx version=\"1.1\" creator=\"MoWalk\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        g += "<metadata><name>\(x(w.title))</name><time>\(iso.string(from: w.start))</time></metadata>\n"
        for c in captures(in: w.id).reversed() where c.lat != nil {
            let what = c.kind == .photo ? "Photo" : c.kind == .audio ? "Interview" : "Note"
            let name = c.title.isEmpty ? what : "\(what): \(c.title)"
            g += "<wpt lat=\"\(String(format: "%.6f", c.lat!))\" lon=\"\(String(format: "%.6f", c.lon!))\">"
            g += "<time>\(iso.string(from: c.time))</time><name>\(x(name))</name>"
            if let f = c.file { g += "<desc>\(x(f))</desc>" }
            g += "</wpt>\n"
        }
        g += "<trk><name>\(x(w.title))</name><trkseg>\n"
        for p in track(w.id) {
            g += "<trkpt lat=\"\(String(format: "%.6f", p.1))\" lon=\"\(String(format: "%.6f", p.2))\"><time>\(iso.string(from: p.0))</time></trkpt>\n"
        }
        g += "</trkseg></trk></gpx>\n"
        let out = dir.appendingPathComponent("\(w.id).gpx")
        try? g.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// One walk as a zip: its GPX, captures.csv and media.
    func exportWalkZip(_ w: Walk) -> URL? {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent(w.id, isDirectory: true)
        try? fm.removeItem(at: stage)
        try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
        if let g = exportGPX(w) { try? fm.copyItem(at: g, to: stage.appendingPathComponent(g.lastPathComponent)) }
        let mine = captures(in: w.id)
        for c in mine { if let f = c.file { try? fm.copyItem(at: dir.appendingPathComponent(f), to: stage.appendingPathComponent(f)) } }
        try? csv(mine).write(to: stage.appendingPathComponent("captures.csv"), atomically: true, encoding: .utf8)
        return zip(stage, name: w.id)
    }

    /// Everything, for a backup.
    func exportZip() -> URL? {
        for w in walks { _ = exportGPX(w) }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        return zip(dir, name: "mowalk-\(f.string(from: Date()))")
    }

    private func zip(_ folder: URL, name: String) -> URL? {
        var out: URL?, err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &err) { z in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: z, to: dest)
            out = dest
        }
        return out
    }

    // MARK: persistence

    private func save() {
        if let d = try? Self.encoder.encode(captures) { try? d.write(to: capturesURL, options: .atomic) }
        try? csv(captures).write(to: dir.appendingPathComponent("captures.csv"), atomically: true, encoding: .utf8)
    }

    private func saveWalks() {
        lastSave = Date()
        if let d = try? Self.encoder.encode(walks) { try? d.write(to: walksURL, options: .atomic) }
    }

    private func csv(_ list: [Capture]) -> String {
        let iso = ISO8601DateFormatter()
        var s = "id,kind,time_utc,lat,lon,km,file,title,consent,duration_s,walk\n"
        for c in list.reversed() {
            let t = c.title.replacingOccurrences(of: "\"", with: "'")
            s += [c.id, c.kind.rawValue, iso.string(from: c.time),
                  c.lat.map { String(format: "%.6f", $0) } ?? "", c.lon.map { String(format: "%.6f", $0) } ?? "",
                  c.km.map { String(format: "%.2f", $0) } ?? "", c.file ?? "", "\"\(t)\"",
                  c.consent.map { $0 ? "yes" : "no" } ?? "", c.duration.map { String(format: "%.0f", $0) } ?? "",
                  c.walk ?? ""].joined(separator: ",") + "\n"
        }
        return s
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
