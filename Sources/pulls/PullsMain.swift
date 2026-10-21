import AppKit
import Foundation
import os

enum PullsLog {
    private static let subsystem = "app.pulls.macos"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let inbox = Logger(subsystem: subsystem, category: "inbox")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
}

enum AppInfo {
    /// Fallback matches Resources/Info.plist when the executable is not inside the bundle.
    static let fallbackVersion = "0.1.0"

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallbackVersion
    }

    static var versionLabel: String {
        "Version \(shortVersion)"
    }
}

/// Keeps a strong reference for the lifetime of `NSApplication.run()`.
/// `NSApplication.delegate` is weak, so the delegate has to live on this stack frame.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installQuitMenu()
        let controller = StatusBarController()
        statusBar = controller
        PullsLog.app.info("Pulls launched")
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                controller.presentInbox()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PullsLog.app.info("Pulls terminating")
    }

    /// LSUIElement hides the app menu, so Command-Q has to be installed explicitly.
    private func installQuitMenu() {
        let quit = NSMenuItem(
            title: "Quit Pulls",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        quit.keyEquivalentModifierMask = .command

        let appMenu = NSMenu()
        appMenu.addItem(quit)

        let appItem = NSMenuItem()
        appItem.submenu = appMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}

@main
enum PullsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Covers `swift run`, which has no Info.plist. The bundled app also sets LSUIElement
        // so Launch Services never shows a Dock icon in the first place.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
