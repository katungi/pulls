import AppKit
import QuartzCore
import SwiftUI

enum NotificationEmphasis: Equatable, Sendable {
    case important
    case subtle

    /// Notification Center banners share one width so a stack lines up.
    var width: CGFloat { 360 }

    var cornerRadius: CGFloat { 20 }

    /// Important alerts stay until dismissed. Subtle banners leave on their own.
    var visibleDuration: Duration? {
        switch self {
        case .important: nil
        case .subtle: .seconds(5)
        }
    }

    fileprivate var material: NSVisualEffectView.Material {
        switch self {
        case .important: .popover
        case .subtle: .menu
        }
    }
}

struct PullsNotification: Identifiable, Equatable, Sendable {
    let id: UUID
    var emphasis: NotificationEmphasis
    var title: String
    var message: String
    var symbolName: String

    init(
        id: UUID = UUID(),
        emphasis: NotificationEmphasis,
        title: String,
        message: String,
        symbolName: String
    ) {
        self.id = id
        self.emphasis = emphasis
        self.title = title
        self.message = message
        self.symbolName = symbolName
    }
}

enum DummyNotifications {
    static func make(_ emphasis: NotificationEmphasis) -> PullsNotification {
        switch emphasis {
        case .important:
            let review = MockInbox.pullRequests.first { $0.isUnread && $0.section == .needsReview }
            return PullsNotification(
                emphasis: .important,
                title: "Needs your review",
                message: review?.menuTitle ?? "A pull request needs your review",
                symbolName: "eye.fill"
            )
        case .subtle:
            let pushed = MockInbox.pullRequests.first { $0.activity == .pushed }
            let number = pushed?.number ?? 0
            let author = pushed?.authorName ?? "Someone"
            return PullsNotification(
                emphasis: .subtle,
                title: "PR \(number) updated",
                message: "\(author) pushed a commit",
                symbolName: "arrow.up"
            )
        }
    }
}

/// In-app banners. System notifications can't draw these two treatments, and they would ask for permission.
@MainActor
final class BannerPresenter {
    var onPrepare: (() -> Void)?
    var screenProvider: () -> NSScreen? = { NSScreen.main ?? NSScreen.screens.first }

    private var banners: [UUID: BannerBox] = [:]
    private var notes: [UUID: PullsNotification] = [:]
    private var order: [UUID] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    private var paused: Set<UUID> = []

    func previewAll() {
        // Run now, while the click is still alive. A follow-up task was easy to cancel
        // when the popover closed and took the menu with it.
        onPrepare?()
        NSApp.activate()
        present(DummyNotifications.make(.important))
        present(DummyNotifications.make(.subtle))
    }

    func preview(_ emphasis: NotificationEmphasis) {
        onPrepare?()
        NSApp.activate()
        present(DummyNotifications.make(emphasis))
    }

    private func present(_ note: PullsNotification) {
        if let existing = order.first(where: { banners[$0]?.emphasis == note.emphasis }) {
            removeImmediately(existing)
        }

        let card = NotificationCard(note: note) { [weak self] in
            self?.dismiss(note.id)
        } onHover: { [weak self] hovering in
            self?.setHovered(note.id, hovering)
        }
        let box = BannerBox(note: note, card: card)
        banners[note.id] = box
        notes[note.id] = note
        switch note.emphasis {
        case .important:
            order.insert(note.id, at: 0)
        case .subtle:
            order.append(note.id)
        }

        layout(animated: false)
        // Start visible. Fading up from alpha 0 never commits for an inactive menu-bar app,
        // so the panel stayed ordered in and fully transparent.
        box.panel.alphaValue = 1
        box.panel.orderFrontRegardless()
        let frame = box.panel.frame
        PullsLog.notifications.info(
            "Banner on screen \(box.panel.isVisible, privacy: .public) \(Int(frame.origin.x), privacy: .public),\(Int(frame.origin.y), privacy: .public) \(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public)"
        )
        scheduleDismiss(note)
        switch note.emphasis {
        case .important:
            PullsLog.notifications.info("Presented important notification")
        case .subtle:
            PullsLog.notifications.info("Presented subtle notification")
        }
    }

    private func dismiss(_ id: UUID) {
        guard let box = banners[id] else { return }
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            box.panel.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            guard self.banners[id] != nil else { return }
            self.removeImmediately(id)
            self.layout(animated: true)
        }
    }

    private func setHovered(_ id: UUID, _ hovering: Bool) {
        if hovering {
            paused.insert(id)
            dismissTasks[id]?.cancel()
            dismissTasks[id] = nil
        } else {
            paused.remove(id)
            if let note = notes[id] {
                scheduleDismiss(note)
            }
        }
    }

    private func scheduleDismiss(_ note: PullsNotification) {
        dismissTasks[note.id]?.cancel()
        guard let duration = note.emphasis.visibleDuration, !paused.contains(note.id) else { return }
        dismissTasks[note.id] = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.dismiss(note.id)
        }
    }

    private func removeImmediately(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        paused.remove(id)
        notes[id] = nil
        order.removeAll { $0 == id }
        banners[id]?.panel.orderOut(nil)
        banners[id] = nil
    }

    private func layout(animated: Bool) {
        guard let visible = bannerScreen()?.visibleFrame else { return }
        var top = visible.maxY - 10
        for id in order {
            guard let box = banners[id] else { continue }
            let size = box.panel.frame.size
            top -= size.height
            let origin = NSPoint(x: visible.maxX - size.width - 14, y: top)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    box.panel.animator().setFrameOrigin(origin)
                }
            } else {
                box.panel.setFrameOrigin(origin)
            }
            top -= 8
        }
    }

    /// `NSScreen.main` is nil while a menu-bar app has no key window, which is the usual state here.
    private func bannerScreen() -> NSScreen? {
        if let provided = screenProvider() {
            return provided
        }
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.screens.first
    }
}

@MainActor
private struct BannerBox {
    var emphasis: NotificationEmphasis
    var panel: NSPanel
    var hosting: NSHostingController<NotificationCard>

    init(note: PullsNotification, card: NotificationCard) {
        let hosting = BannerHostingController(rootView: card)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.safeAreaRegions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let width = note.emphasis.width
        var fitted = hosting.sizeThatFits(in: CGSize(width: width, height: 600))
        if fitted.height < 24 {
            fitted.height = note.emphasis == .important ? 120 : 72
        }
        let size = NSSize(width: width, height: ceil(fitted.height))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // `.statusBar` is reserved tightly enough that a third-party panel can be dropped.
        // Floating still sits above normal windows, which is where a banner belongs.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let chrome = BannerChrome(radius: note.emphasis.cornerRadius, material: note.emphasis.material)
        chrome.frame = NSRect(origin: .zero, size: size)
        hosting.view.frame = chrome.bounds
        hosting.view.autoresizingMask = [.width, .height]
        chrome.addSubview(hosting.view)
        panel.contentView = chrome

        self.emphasis = note.emphasis
        self.panel = panel
        self.hosting = hosting
    }
}

private final class BannerHostingController: NSHostingController<NotificationCard> {
    override func loadView() {
        let host = FirstMouseHostingView(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize]
        view = host
    }
}

/// First click dismisses the banner instead of only activating the accessory app.
private final class BannerChrome: NSVisualEffectView {
    init(radius: CGFloat, material: NSVisualEffectView.Material) {
        super.init(frame: .zero)
        self.material = material
        // `.withinWindow` still draws when the panel has no window behind it to sample.
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private struct NotificationCard: View {
    var note: PullsNotification
    var onDismiss: () -> Void
    var onHover: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                NotificationAppIcon()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Pulls")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .labelColor))
                        Spacer(minLength: 8)
                        if isHovered {
                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .accessibilityLabel("Close")
                        } else {
                            Text("now")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                    }
                    Text(note.title)
                        .font(.system(size: 13, weight: note.emphasis == .important ? .semibold : .regular))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(note.emphasis == .important ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(note.message)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(note.emphasis == .important ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if note.emphasis == .important {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Close", action: onDismiss)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Review", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: note.emphasis.width, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering)
        }
        .onTapGesture {
            if note.emphasis == .subtle {
                onDismiss()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pulls. \(note.title). \(note.message)")
    }
}

private struct NotificationAppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlAccentColor))
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
