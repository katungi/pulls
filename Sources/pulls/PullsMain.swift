import AppKit
import Foundation
import os

enum PullsLog {
    private static let subsystem = "app.pulls.macos"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let inbox = Logger(subsystem: subsystem, category: "inbox")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let github = Logger(subsystem: subsystem, category: "github")
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
    private var session: SessionController?
    private var onboarding: OnboardingCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        let session = SessionController.makeLive()
        let onboarding = OnboardingCoordinator(session: session)
        self.session = session
        self.onboarding = onboarding
        let controller = StatusBarController(session: session)
        controller.onFinishSetup = { onboarding.presentSetup() }
        controller.onManageRepositories = { onboarding.presentRepositories() }
        controller.onUsePersonalAccessToken = { onboarding.presentPersonalAccessToken() }
        controller.onSignOut = {
            session.signOut()
            onboarding.presentSetup()
        }
        controller.onEnableSystemNotifications = {
            Task { await session.enableSystemNotifications() }
        }
        statusBar = controller
        PullsLog.app.info("Pulls launched")
        Task {
            await session.restore()
            if session.needsOnboarding {
                onboarding.presentSetup()
            }
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                controller.presentInbox()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PullsLog.app.info("Pulls terminating")
    }

    /// LSUIElement hides the menu bar. Command-Q and Command-V still need real menu items,
    /// because AppKit delivers those shortcuts through the main menu.
    private func installMenus() {
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

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(editItem("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(editItem("Redo", action: Selector(("redo:")), key: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(editItem("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(editItem("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(editItem("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(editItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    /// A nil target sends the action to whichever text field is focused.
    private func editItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        return item
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
