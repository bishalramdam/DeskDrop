import SwiftUI

@main
struct DeskDropApp: App {
    @StateObject private var store = DropStore()

    var body: some Scene {
        MenuBarExtra("DeskDrop", systemImage: "tray.and.arrow.down.fill") {
            MenuBarView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
