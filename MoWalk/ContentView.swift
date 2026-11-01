import SwiftUI

extension Color {
    static let cloth  = Color(red: 0x0A / 255, green: 0x28 / 255, blue: 0x19 / 255)
    static let cloth2 = Color(red: 0x14 / 255, green: 0x40 / 255, blue: 0x2A / 255)
    static let moGreen = Color(red: 0x40 / 255, green: 0xBA / 255, blue: 0x89 / 255)
    static let gold   = Color(red: 0xF2 / 255, green: 0xC2 / 255, blue: 0x00 / 255)
}
extension ShapeStyle where Self == Color {
    static var gold: Color { Color.gold }
    static var moGreen: Color { Color.moGreen }
}

enum Fmt {
    /// 754 s/km -> "12:34"
    static func pace(_ s: UInt16) -> String {
        s == 0 || s > 59 * 60 ? "--:--" : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
    /// 3725 s -> "1:02"
    static func hm(_ s: UInt32) -> String { String(format: "%d:%02d", Int(s) / 3600, Int(s) / 60 % 60) }
}

struct ContentView: View {
    @Environment(CaptureStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var showCamera = false
    @State private var showInterview = false
    @State private var showNote = false
    @State private var exportURL: URL?
    @State private var pendingWalkDelete: Walk?

    var body: some View {
        @Bindable var nav = nav
        NavigationStack {
            List {
                if let r = nav.route {
                    Section {
                        Button { nav.showFollow = true } label: {
                            HStack {
                                Image(systemName: nav.offRoute ? "exclamationmark.triangle.fill" : nav.nextTurn?.turn.icon ?? "arrow.up")
                                    .font(.title2).foregroundStyle(nav.offRoute ? .red : .gold).frame(width: 34)
                                VStack(alignment: .leading) {
                                    Text("Following \(r.name)").font(.subheadline.bold()).lineLimit(1)
                                    Text(nav.offRoute ? String(format: "Off route · %.0f m from the path", nav.offM)
                                         : nav.nextTurn.map { String(format: "%@ in %.0f m", $0.turn.words.capitalized, $0.dist) }
                                         ?? "Straight on to the finish")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section { WalkDashboard().listRowInsets(EdgeInsets()).listRowBackground(Color.cloth) }
                Section {
                    HStack(spacing: 10) {
                        CaptureButton(title: "Photo", icon: "camera.fill") { showCamera = true }
                        CaptureButton(title: "Interview", icon: "mic.fill") { showInterview = true }
                        CaptureButton(title: "Note", icon: "square.and.pencil") { showNote = true }
                    }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section(store.walkID == nil ? "Not walking" : "This walk · \(store.captures(in: store.walkID).count)") {
                    if store.walkID == nil {
                        Text("Start a walk and its photos, interviews and notes are filed under it.")
                            .foregroundStyle(.secondary)
                    } else if store.captures(in: store.walkID).isEmpty {
                        Text("Nothing captured yet on this walk.").foregroundStyle(.secondary)
                    }
                    if store.walkID != nil { CaptureItems(items: store.captures(in: store.walkID)) }
                }
                if !store.captures(in: nil).isEmpty {
                    Section("Not on a walk · \(store.captures(in: nil).count)") {
                        CaptureItems(items: store.captures(in: nil))
                    }
                }
                Section("Walks · \(store.walks.count)") {
                    if store.walks.isEmpty {
                        Text("Every walk you record shows up here.").foregroundStyle(.secondary)
                    }
                    ForEach(store.walks) { w in
                        NavigationLink(value: w) { WalkRow(w: w) }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingWalkDelete = w }
                            }
                    }
                }
            }
            .navigationDestination(for: Walk.self) { w in WalkDetail(walkID: w.id) }
            .navigationTitle("Mo'Walk")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { if nav.route != nil { nav.showFollow = true } else { nav.showRoutes = true } } label: {
                        Image(systemName: "location.north.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Everything (zip)", systemImage: "doc.zipper") { exportURL = store.exportZip() }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(store.captures.isEmpty && store.walks.isEmpty)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraView { jpg in
                    let id = store.newID(.photo)
                    try? jpg.write(to: store.dir.appendingPathComponent("\(id).jpg"))
                    store.add(kind: .photo, id: id, file: "\(id).jpg", title: "")
                }.ignoresSafeArea()
            }
            .sheet(isPresented: $showInterview) { InterviewSheet().presentationDetents([.medium]) }
            .sheet(isPresented: $showNote) { NoteSheet().presentationDetents([.height(220)]) }
            .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
            .sheet(isPresented: $nav.showRoutes) { RoutesView() }
            .fullScreenCover(isPresented: $nav.showFollow) { FollowView() }
            .confirmationDialog("Delete this walk?", isPresented: Binding(
                get: { pendingWalkDelete != nil }, set: { if !$0 { pendingWalkDelete = nil } }),
                titleVisibility: .visible, presenting: pendingWalkDelete) { w in
                Button("Delete walk and its \(store.captures(in: w.id).count) items", role: .destructive) { store.deleteWalk(w) }
            } message: { w in
                Text("\(w.title): the track, photos, interviews and notes are removed from the app. Photos stay in your Photos library.")
            }
        }
        .tint(.moGreen)
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

// MARK: - Walk dashboard

struct WalkDashboard: View {
    @Environment(CaptureStore.self) private var store
    @State private var confirmEnd = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let w = store.currentWalk
            let out = w.map { ctx.date.timeIntervalSince($0.start) } ?? 0
            let moving = Double(w?.movingS ?? 0), odo = w?.odoM ?? 0
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(w.map { $0.title.uppercased() } ?? "MO'WALK").font(.caption.bold()).foregroundStyle(.gold)
                    Spacer()
                    Label(store.accuracy > 0 ? String(format: "GPS ±%.0f m", store.accuracy) : "waiting for GPS",
                          systemImage: "location.fill")
                        .font(.caption).foregroundStyle(store.accuracy > 0 && store.accuracy <= 25 ? Color.moGreen : .orange)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(w == nil ? "0.00" : String(format: "%.2f", odo / 1000))
                        .font(.system(size: 52, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    Text("km").font(.title3.bold()).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Fmt.hm(UInt32(out))) out").font(.title3.bold()).foregroundStyle(.gold)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Stat("NOW", w == nil ? "--" : String(format: "%.1f km/h", store.kmhNow))
                              Stat("AVG", moving > 0 && odo > 50 ? String(format: "%.1f km/h", odo / moving * 3.6) : "--") }
                    GridRow { Stat("MOVING", Fmt.hm(UInt32(moving)))
                              Stat("STOPPED", Fmt.hm(UInt32(max(0, out - moving)))) }
                }
                if w == nil {
                    Button { store.startWalk() } label: {
                        Label("Start walk", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.moGreen).controlSize(.large)
                } else {
                    Text("Recording on the phone's GPS. It keeps going with the screen locked.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                    Button(role: .destructive) { confirmEnd = true } label: {
                        Label("End walk", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).tint(.red)
                }
            }
            .padding()
            .background(Color.cloth)
        }
        .confirmationDialog("End this walk?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End walk", role: .destructive) { store.endWalk() }
        } message: { Text("It's saved in Walks. Starting again makes a new walk.") }
    }
}

struct Stat: View {
    let label: String, value: String
    init(_ l: String, _ v: String) { label = l; value = v }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption2.bold()).foregroundStyle(.white.opacity(0.5)).frame(width: 58, alignment: .leading)
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(.white)
        }
    }
}

struct CaptureButton: View {
    let title: String, icon: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) { Image(systemName: icon).font(.title2); Text(title).font(.footnote.bold()) }
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(Color.cloth2, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }.buttonStyle(.plain)
    }
}

// MARK: - Captures (shared by "This walk", "Not on a walk" and a walk's page)

struct CaptureItems: View {
    @Environment(CaptureStore.self) private var store
    let items: [Capture]
    @State private var player = Player()
    @State private var pendingDelete: Capture?

    var body: some View {
        ForEach(items) { c in
            CaptureRow(c: c, player: player)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = c }
                }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = c }
                }
        }
        .confirmationDialog("Delete this item?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete) { c in
            Button("Delete", role: .destructive) { store.delete(c) }
        } message: { c in
            Text(c.kind == .note ? "The note is removed from the app."
                 : "The \(c.kind == .photo ? "photo" : "recording") file is removed from the app"
                   + (c.kind == .photo ? " (the copy in Photos stays)." : "."))
        }
    }
}

struct CaptureRow: View {
    @Environment(CaptureStore.self) private var store
    let c: Capture
    let player: Player

    var body: some View {
        HStack(spacing: 12) {
            thumb.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.subheadline.bold()).lineLimit(2)
                HStack(spacing: 4) {
                    Text(c.time.formatted(date: .omitted, time: .shortened))
                    if let km = c.km { Text("· km \(String(format: "%.1f", km))") }
                    if c.lat == nil { Text("· no position").foregroundStyle(.orange) }
                    if c.consent == true { Text("· consent ✓") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var headline: String {
        switch c.kind {
        case .photo: return c.title.isEmpty ? "Photo" : c.title
        case .audio: return "Interview: \(c.title.isEmpty ? "unnamed" : c.title) (\(Int(c.duration ?? 0) / 60):\(String(format: "%02d", Int(c.duration ?? 0) % 60)))"
        case .note:  return c.title
        }
    }

    @ViewBuilder private var thumb: some View {
        switch c.kind {
        case .photo:
            if let u = store.url(c), let img = UIImage(contentsOfFile: u.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else { Color.cloth2 }
        case .audio:
            Button { if let u = store.url(c) { player.toggle(c.id, url: u) } } label: {
                Image(systemName: player.playingID == c.id ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.cloth2).foregroundStyle(.gold)
            }.buttonStyle(.plain)
        case .note:
            Image(systemName: "text.quote").frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.cloth2).foregroundStyle(.white)
        }
    }
}

// MARK: - Sheets

struct InterviewSheet: View {
    @Environment(CaptureStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @State private var rec = Recorder()
    @State private var name = ""
    @State private var consent = false
    @State private var id = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Interview").font(.title2.bold())
            TextField("Who? (name, team, role)", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Consent asked and given on the recording", isOn: $consent)
            Text(String(format: "%d:%02d", Int(rec.elapsed) / 60, Int(rec.elapsed) % 60))
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
            ProgressView(value: Double(rec.level)).tint(.gold).opacity(rec.isRecording ? 1 : 0.2)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if rec.isRecording {
                    Button(role: .destructive) { finish() } label: {
                        Label("Stop & save", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { begin() } label: {
                        Label("Record", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
            }.controlSize(.large)
        }
        .padding()
        .interactiveDismissDisabled(rec.isRecording)
    }

    private func begin() {
        nav.suppressVoice = true                         // no turn cues on the recording
        id = store.newID(.audio)
        do { try rec.start(to: store.dir.appendingPathComponent("\(id).m4a")) }
        catch { self.error = error.localizedDescription; nav.suppressVoice = false }
    }
    private func finish() {
        let d = rec.stop()
        nav.suppressVoice = false
        store.add(kind: .audio, id: id, file: "\(id).m4a", title: name, consent: consent, duration: d)
        dismiss()
    }
}

struct NoteSheet: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            TextField("What's happening?", text: $text, axis: .vertical)
                .lineLimit(3...5).textFieldStyle(.roundedBorder).focused($focused)
            Button {
                store.add(kind: .note, id: store.newID(.note), file: nil, title: text)
                dismiss()
            } label: { Text("Save note").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .onAppear { focused = true }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items.map(Self.asFile), applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}

    /// A .gpx is XML, so apps like WhatsApp grab it as text and paste it into the chat.
    /// Offer it only as a GPX *file* so it goes as a document attachment.
    private static func asFile(_ item: Any) -> Any {
        guard let url = item as? URL, url.pathExtension.lowercased() == "gpx" else { return item }
        let p = NSItemProvider()
        p.suggestedName = url.deletingPathExtension().lastPathComponent
        p.registerFileRepresentation(forTypeIdentifier: "com.topografix.gpx", fileOptions: [], visibility: .all) { done in
            done(url, false, nil); return nil
        }
        return p
    }
}
