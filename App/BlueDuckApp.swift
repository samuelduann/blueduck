import BlueDuckKit
import SwiftUI

@main
struct BlueDuckApp: App {
    @StateObject private var controller = DomainController()

    var body: some Scene {
        Window("BlueDuck", id: "main") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("BlueDuck", systemImage: "externaldrive.badge.icloud") {
            MenuBarContent()
                .environmentObject(controller)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var controller: DomainController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(controller.configs) { config in
            Button("Open \(config.displayName)") {
                Task { await controller.revealInFinder(config) }
            }
        }
        if !controller.configs.isEmpty { Divider() }
        Button("Check for Changes Now") { controller.refreshAll() }
        Button("Manage Buckets…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit BlueDuck") { NSApp.terminate(nil) }
    }
}
