import AppKit
import SwiftUI

/// Menu-bar item and the popover that hangs from it.
///
/// The popover is transient so clicks inside it reach SwiftUI.
/// A click on the status item itself is ignored once, or the menu would close and reopen.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: InboxModel
    private let banners: BannerPresenter
    private let hostingController: NSHostingController<InboxView>
    private var escapeMonitor: Any?
    private var ignoreNextStatusClick = false

    override init() {
        let model = InboxModel()
        let banners = BannerPresenter()
        let hosting = InboxHostingController(
            rootView: InboxView(
                model: model,
                onPreviewNotifications: { banners.previewAll() },
                onPreviewNotification: { banners.preview($0) }
            )
        )
        hosting.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        hosting.safeAreaRegions = []
        // The popover already supplies the material. An opaque SwiftUI layer would hide it.
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        self.model = model
        self.banners = banners
        self.hostingController = hosting
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: InboxMetrics.width, height: 420)

        banners.onPrepare = { [weak self] in
            self?.closePopover()
        }
        banners.screenProvider = { [weak self] in
            self?.statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        }

        configureStatusItem()
        observeModel()
        applyStatusItem()
        syncPopoverSize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Pulls"
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .menuBarFont(ofSize: 0)
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.autosaveName = "PullsStatusItem"
    }

    private func observeModel() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.model.statusItemTitle
            _ = self.model.isRefreshing
            _ = self.model.page
            _ = self.model.enabledSections
            _ = self.model.measuredListHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyStatusItem()
                self.syncPopoverSize()
                self.observeModel()
            }
        }
    }

    private func applyStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = model.statusItemTitle
        button.toolTip = model.isRefreshing
            ? "Refreshing pull requests"
            : "Pulls, \(model.statusItemTitle)"
    }

    private func syncPopoverSize() {
        let fitting = hostingController.sizeThatFits(in: CGSize(width: InboxMetrics.width, height: 10_000))
        guard fitting.height > 1 else { return }
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 24
        let height = min(ceil(fitting.height), maxHeight)
        let next = NSSize(width: InboxMetrics.width, height: height)
        guard abs(popover.contentSize.width - next.width) > 0.5
            || abs(popover.contentSize.height - next.height) > 0.5
        else { return }
        popover.contentSize = next
    }

    @objc private func togglePopover(_ sender: Any?) {
        if ignoreNextStatusClick {
            ignoreNextStatusClick = false
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func presentInbox() {
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        syncPopoverSize()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        installEscapeMonitor()
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            statusItem.button?.highlight(false)
            scheduleMonitorRemoval()
        }
    }

    func popoverWillClose(_ notification: Notification) {
        guard let button = statusItem.button, let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            if event.window === button.window {
                ignoreNextStatusClick = true
            }
        default:
            break
        }
    }

    func popoverDidShow(_ notification: Notification) {
        statusItem.button?.highlight(true)
        applyMenuMaterial()
        syncPopoverSize()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        scheduleMonitorRemoval()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        closePopover()
    }

    /// NSPopover's default material is heavier than a menu. The reference inbox is menu vibrancy.
    private func applyMenuMaterial() {
        guard let contentView = popover.contentViewController?.view.window?.contentView else { return }
        retuneMaterial(in: contentView)
    }

    private func retuneMaterial(in view: NSView) {
        if let effect = view as? NSVisualEffectView {
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
        }
        for subview in view.subviews {
            retuneMaterial(in: subview)
        }
    }

    /// Mouse monitors were closing the menu on mouse-down, before Quit and Test notification ran.
    /// Only Escape is watched. Outside clicks are handled by the transient popover.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let isEscape = MainActor.assumeIsolated {
                guard let self, self.popover.isShown, keyCode == 53 else { return false }
                self.closePopover()
                return true
            }
            return isEscape ? nil : event
        }
    }

    private func scheduleMonitorRemoval() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.removeEscapeMonitor()
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

/// The popover's content view has to accept the first click. Otherwise AppKit
/// uses that click only to activate the accessory app, and Quit never runs.
private final class InboxHostingController: NSHostingController<InboxView> {
    override func loadView() {
        let host = FirstMouseHostingView(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        view = host
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
