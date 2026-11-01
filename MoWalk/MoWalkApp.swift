import SwiftUI

@main
struct MoWalkApp: App {
    @State private var store = CaptureStore()
    @State private var nav = Navigator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(nav)
                .onOpenURL { url in                       // a GPX shared to Mo'Walk
                    if nav.importGPX(url) != nil { nav.showRoutes = true }
                }
        }
    }
}
