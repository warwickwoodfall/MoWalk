import SwiftUI
import MapKit
import UniformTypeIdentifiers

extension UTType { static let gpx = UTType(importedAs: "com.topografix.gpx") }

/// Pick a route to follow: the Mo Walk, or any GPX loaded from Files / WhatsApp / Mail.
struct RoutesView: View {
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(nav.routes) { r in
                        Button { nav.start(r); dismiss() } label: {
                            HStack {
                                Image(systemName: nav.isBuiltIn(r) ? "star.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                                    .foregroundStyle(.gold).frame(width: 26)
                                VStack(alignment: .leading) {
                                    Text(r.name).font(.headline).foregroundStyle(.primary)
                                    Text(String(format: "%.1f km · %d turns", r.length / 1000, r.turns.count))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if nav.route?.id == r.id { Text("FOLLOWING").font(.caption2.bold()).foregroundStyle(.moGreen) }
                            }
                        }
                        .swipeActions {
                            if !nav.isBuiltIn(r) {
                                Button("Delete", systemImage: "trash", role: .destructive) { nav.deleteRoute(r) }
                            }
                        }
                    }
                } footer: {
                    Text("Load a GPX from Files, or share one to Mo'Walk from WhatsApp, Mail or AirDrop.")
                }
                Section {
                    Button("Load a GPX…", systemImage: "square.and.arrow.down") { importing = true }
                    if nav.route != nil {
                        Button("Stop following", systemImage: "xmark.circle", role: .destructive) { nav.stop() }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Follow a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .xml, .data]) { res in
                if case .success(let url) = res {
                    if nav.importGPX(url) == nil { error = "That file has no track or route points." } else { error = nil }
                }
            }
        }
    }
}

/// The wayfinder: compass arrow down the path, next turn, distance done / to go.
struct FollowView: View {
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStop = false

    var body: some View {
        @Bindable var nav = nav
        if let r = nav.route {
            VStack(spacing: 14) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.bold()) }
                    Spacer()
                    VStack(spacing: 0) {
                        Text(r.name).font(.subheadline.bold()).lineLimit(1)
                        Text(String(format: "%.1f km done · %.1f to go", nav.along / 1000, max(0, r.length - nav.along) / 1000))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Toggle(isOn: $nav.voiceOn) { Image(systemName: nav.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill") }
                        .toggleStyle(.button).tint(.moGreen)
                }
                .foregroundStyle(.white)

                Compass(rel: relAngle, heading: displayHeading, off: nav.offRoute)
                    .frame(maxWidth: 300, maxHeight: 300)

                turnCard

                HStack {
                    Label(nav.source + (nav.accuracy > 0 && nav.source != "waiting for GPS" ? String(format: " ±%.0f m", nav.accuracy) : ""),
                          systemImage: "location.fill")
                    Spacer()
                    Text(compassNote).foregroundStyle(compassNote.hasPrefix("Compass") ? .orange : .white.opacity(0.6))
                }
                .font(.caption).foregroundStyle(.white.opacity(0.7))

                MiniMap(route: r, here: nav.position).frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))

                Button(role: .destructive) { confirmStop = true } label: {
                    Label("Stop following", systemImage: "xmark").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).tint(.red)
            }
            .padding()
            .background(Color.cloth.ignoresSafeArea())
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .confirmationDialog("Stop following \(r.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive) { nav.stop(); dismiss() }
            }
        } else {
            ContentUnavailableView("Not following a route", systemImage: "location.north.circle")
        }
    }

    /// What the arrow is measured against: the phone compass, else the direction of travel.
    private var displayHeading: Double? {
        if let h = nav.heading, nav.headingAccuracy >= 0, nav.headingAccuracy < 45 { return h }
        return nav.course
    }
    private var relAngle: Double? {
        guard let b = nav.aimBearing, let h = displayHeading else { return nil }
        return b - h
    }
    private var compassNote: String {
        if nav.heading == nil && nav.course == nil { return "No compass yet" }
        if nav.headingAccuracy < 0 || nav.headingAccuracy >= 45 {
            return nav.course != nil ? "Compass weak: using walking direction" : "Compass: wave the phone in a figure-of-eight"
        }
        return "Hold the phone flat"
    }

    @ViewBuilder private var turnCard: some View {
        let card = RoundedRectangle(cornerRadius: 14)
        if nav.offRoute {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("Off route").font(.title2.bold())
                    Text(String(format: "The path is %.0f m away. Follow the arrow back to it.", nav.offM)).font(.subheadline)
                }
                Spacer()
            }
            .padding().frame(maxWidth: .infinity).background(.red, in: card).foregroundStyle(.white)
        } else if nav.arrived {
            Label("You've arrived", systemImage: "flag.checkered").font(.title2.bold())
                .padding().frame(maxWidth: .infinity).background(Color.moGreen, in: card).foregroundStyle(.black)
        } else if let n = nav.nextTurn {
            HStack(spacing: 14) {
                Image(systemName: n.turn.icon).font(.system(size: 44, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.dist < 1000 ? String(format: "%.0f m", (n.dist / 10).rounded() * 10) : String(format: "%.1f km", n.dist / 1000))
                        .font(.title.monospacedDigit().bold())
                    Text(n.turn.words.capitalized + (nav.thenTurn.map { ", then \($0.words)" } ?? ""))
                        .font(.headline)
                }
                Spacer()
            }
            .padding().frame(maxWidth: .infinity)
            .background(n.dist < 60 ? Color.gold : Color.cloth2, in: card)
            .foregroundStyle(n.dist < 60 ? Color.black : .white)
        } else {
            Label("Straight on to the finish", systemImage: "arrow.up").font(.title3.bold())
                .padding().frame(maxWidth: .infinity).background(Color.cloth2, in: card).foregroundStyle(.white)
        }
    }
}

/// Ring with N marker turning against the heading, and a big arrow pointing down the path.
struct Compass: View {
    let rel: Double?        // degrees, 0 = straight ahead
    let heading: Double?
    let off: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            if let h = heading {
                ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { i, l in
                    Text(l).font(.headline.bold()).foregroundStyle(l == "N" ? Color.red : .white.opacity(0.6))
                        .offset(y: -128).rotationEffect(.degrees(Double(i) * 90 - h))
                }
            }
            if let a = rel {
                Image(systemName: "location.north.fill")
                    .resizable().scaledToFit().frame(width: 120)
                    .foregroundStyle(off ? Color.red : Color.gold)
                    .rotationEffect(.degrees(a))
                    .animation(.easeOut(duration: 0.4), value: a)
            } else {
                VStack(spacing: 6) {
                    ProgressView().tint(.white)
                    Text("Finding direction…\nstart walking or hold the phone flat")
                        .multilineTextAlignment(.center).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(18)
    }
}

struct MiniMap: View {
    let route: Route
    let here: CLLocationCoordinate2D?

    var body: some View {
        Map(position: .constant(here.map { .camera(MapCamera(centerCoordinate: $0, distance: 900)) } ?? .automatic)) {
            MapPolyline(coordinates: route.pts).stroke(Color.gold, lineWidth: 4)
            if let here {
                Annotation("", coordinate: here) {
                    Circle().fill(Color.moGreen).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .allowsHitTesting(false)
    }
}
