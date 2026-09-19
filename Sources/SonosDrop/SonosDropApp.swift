import SwiftUI
import SonosDropCore

@main
struct SonosDropApp: App {
    let model: QueueModel
    let ui = MenuBarUIState()

    init() {
        let client = SonosClient()
        model = QueueModel(client: client, discovery: Discovery(client: client), server: MediaServer())
    }

    var body: some Scene {
        MenuBarExtra("SonosDrop", systemImage: "hifispeaker.2.fill") {
            MenuBarView(model: model, ui: ui)
                .frame(width: 320, height: 480)
                .task { await model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
