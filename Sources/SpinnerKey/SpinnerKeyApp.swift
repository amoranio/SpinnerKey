import AppKit
import SwiftUI

struct SpinnerKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("SpinnerKey") {
            ConfigView()
                .frame(minWidth: 520, idealWidth: 560, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}

/// SpinnerKey is a settings panel, not a resident app: closing the window quits it.
/// Scheduled rotations are run by launchd, not by this process.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
