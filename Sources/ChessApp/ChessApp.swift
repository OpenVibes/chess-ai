import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct ChessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Chess", id: "main") {
            Text("Chess")
                .font(.largeTitle)
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 920, height: 640)
    }
}
