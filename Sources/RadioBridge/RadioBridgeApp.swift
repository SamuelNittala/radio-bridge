import SwiftUI

@main
struct RadioBridgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Radio Bridge", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 420, height: 680)
        .windowResizability(.contentMinSize)
    }
}
