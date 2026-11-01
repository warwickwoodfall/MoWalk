import SwiftUI
import MapKit

/// A row in the Walks table.
struct WalkRow: View {
    @Environment(CaptureStore.self) private var store
    let w: Walk

    var body: some View {
        let items = store.captures(in: w.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(w.title).font(.headline)
                if w.active {
                    Text("IN PROGRESS").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.moGreen, in: Capsule()).foregroundStyle(.black)
                }
                Spacer()
                Text(String(format: "%.2f km", w.odoM / 1000)).font(.subheadline.monospacedDigit().bold())
            }
            HStack(spacing: 10) {
                Text(w.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                Text(Fmt.hm(UInt32(w.durationS)))
                Spacer()
                count(items, .photo, "camera.fill"); count(items, .audio, "mic.fill"); count(items, .note, "text.quote")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func count(_ items: [Capture], _ k: Capture.Kind, _ icon: String) -> some View {
        let n = items.filter { $0.kind == k }.count
        if n > 0 { Label("\(n)", systemImage: icon).labelStyle(.titleAndIcon) }
    }
}

/// One walk: map of the track with its tags, the numbers, and everything captured on it.
struct WalkDetail: View {
    @Environment(CaptureStore.self) private var store
    let walkID: String
    @State private var exportURL: URL?

    var body: some View {
        if let w = store.walks.first(where: { $0.id == walkID }) {
            let items = store.captures(in: w.id)
            let track = store.track(w.id)
            List {
                if !track.isEmpty || items.contains(where: { $0.lat != nil }) {
                    Section {
                        WalkMap(track: track, items: items).frame(height: 260).listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow { fact("Distance", String(format: "%.2f km", w.odoM / 1000))
                                  fact("Time out", Fmt.hm(UInt32(w.durationS))) }
                        GridRow { fact("Moving", Fmt.hm(UInt32(w.movingS)))
                                  fact("Avg speed", w.odoM > 50 && w.movingS > 0
                                       ? String(format: "%.1f km/h", w.odoM / Double(w.movingS) * 3.6)
                                         + "  (" + Fmt.pace(UInt16(min(Double(w.movingS) / (w.odoM / 1000), 3599))) + "/km)" : "--") }
                        GridRow { fact("Started", w.start.formatted(date: .abbreviated, time: .shortened))
                                  fact("Finished", w.active ? "walking…" : w.end.formatted(date: .omitted, time: .shortened)) }
                    }
                    Text(w.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Section("Photos, interviews & notes · \(items.count)") {
                    if items.isEmpty { Text("Nothing captured on this walk.").foregroundStyle(.secondary) }
                    CaptureItems(items: items)
                }
            }
            .navigationTitle(w.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    Button("GPX (track + tags)", systemImage: "map") { exportURL = store.exportGPX(w) }
                    Button("Whole walk (zip)", systemImage: "doc.zipper") { exportURL = store.exportWalkZip(w) }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
            .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
        } else {
            ContentUnavailableView("Walk deleted", systemImage: "figure.walk")
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(v).font(.body.monospacedDigit().bold())
        }
    }
}

struct WalkMap: View {
    let track: [(Date, Double, Double)]
    let items: [Capture]

    var body: some View {
        Map(initialPosition: .automatic) {
            if track.count > 1 {
                MapPolyline(coordinates: track.map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.2) })
                    .stroke(Color.gold, lineWidth: 4)
            }
            ForEach(items.filter { $0.lat != nil }) { c in
                Annotation(c.title, coordinate: CLLocationCoordinate2D(latitude: c.lat!, longitude: c.lon!)) {
                    Image(systemName: c.kind == .photo ? "camera.fill" : c.kind == .audio ? "mic.fill" : "text.quote")
                        .font(.caption).foregroundStyle(.white).padding(6)
                        .background(Circle().fill(Color.cloth)).overlay(Circle().stroke(Color.moGreen, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }
}
