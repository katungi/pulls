import AppKit
import SwiftUI

enum InboxMetrics {
    /// Fixed menu width. Long titles truncate instead of stretching the popover.
    static let width: CGFloat = 500
    static let maxListHeight: CGFloat = 420
    static let menuFontSize: CGFloat = 13
    static let sectionFontSize: CGFloat = 12
    static let detailFontSize: CGFloat = 11
    static let rowHeight: CGFloat = 22
    static let avatarSize: CGFloat = 16
    static let textInset: CGFloat = 13
}

struct InboxView: View {
    var model: InboxModel
    var session: SessionController
    var onPreviewNotifications: () -> Void
    var onPreviewNotification: (NotificationEmphasis) -> Void
    var onFinishSetup: () -> Void
    var onManageRepositories: () -> Void
    var onUsePersonalAccessToken: () -> Void
    var onSignOut: () -> Void
    var onEnableSystemNotifications: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.page {
            case .inbox:
                inboxPage
            case .sections:
                sectionsPage
            case .preferences:
                preferencesPage
            }
        }
        .frame(width: InboxMetrics.width, alignment: .top)
        .padding(.vertical, 4)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color.clear)
    }

    private var inboxPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(action: model.showSections) { hovered in
                HStack(spacing: 8) {
                    Text("PR inbox sections")
                        .font(.system(size: InboxMetrics.menuFontSize))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(menuForeground(hovered: hovered, secondary: true))
                }
                .foregroundStyle(menuForeground(hovered: hovered))
            }
            .accessibilityHint("Show inbox sections")

            separator

            FittingScroll(
                maxHeight: InboxMetrics.maxListHeight,
                measuredHeight: model.measuredListHeight,
                onHeight: model.noteMeasuredListHeight
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(InboxSection.allCases.filter { model.shows($0) }) { section in
                        InboxSectionBlock(model: model, section: section, onOpenLink: openInbox)
                        separator
                    }
                }
            }

            MenuRow(isEnabled: !model.isRefreshing, action: { Task { await model.refresh() } }) { hovered in
                HStack(spacing: 8) {
                    Text(model.isRefreshing ? "Refreshing…" : "Refresh")
                        .font(.system(size: InboxMetrics.menuFontSize))
                    Spacer(minLength: 8)
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    }
                }
                .foregroundStyle(menuForeground(hovered: hovered))
            }

            MenuRow(action: openInbox) { hovered in
                Text("Open Pulls")
                    .font(.system(size: InboxMetrics.menuFontSize))
                    .foregroundStyle(menuForeground(hovered: hovered))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MenuRow(action: onPreviewNotifications) { hovered in
                Text("Test notification")
                    .font(.system(size: InboxMetrics.menuFontSize))
                    .foregroundStyle(menuForeground(hovered: hovered))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHint("Shows sample important and subtle notifications")

            if session.needsOnboarding {
                MenuRow(action: onFinishSetup) { hovered in
                    Text("Finish setup")
                        .font(.system(size: InboxMetrics.menuFontSize))
                        .foregroundStyle(menuForeground(hovered: hovered))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            MenuRow(action: model.showPreferences) { hovered in
                HStack(spacing: 8) {
                    Text("Preferences")
                        .font(.system(size: InboxMetrics.menuFontSize))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(menuForeground(hovered: hovered, secondary: true))
                }
                .foregroundStyle(menuForeground(hovered: hovered))
            }

            if session.phase != .signedOut {
                MenuRow(action: onSignOut) { hovered in
                    HStack(spacing: 8) {
                        Text("Sign out")
                            .font(.system(size: InboxMetrics.menuFontSize))
                        Spacer(minLength: 8)
                        if let login = session.user?.login {
                            Text(login)
                                .font(.system(size: InboxMetrics.menuFontSize))
                                .foregroundStyle(menuForeground(hovered: hovered, secondary: true))
                        }
                    }
                    .foregroundStyle(menuForeground(hovered: hovered))
                }
                .accessibilityLabel(signOutLabel)
            }

            MenuRow(action: { NSApp.terminate(nil) }) { hovered in
                HStack(spacing: 8) {
                    Text("Quit Pulls")
                        .font(.system(size: InboxMetrics.menuFontSize))
                    Spacer(minLength: 8)
                    Text("⌘Q")
                        .font(.system(size: InboxMetrics.menuFontSize))
                        .foregroundStyle(menuForeground(hovered: hovered, secondary: true))
                }
                .foregroundStyle(menuForeground(hovered: hovered))
            }
            separator

            if model.usesSampleData {
                Text(SampleDataNotice.title)
                    .font(.system(size: InboxMetrics.sectionFontSize))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, InboxMetrics.textInset)
                    .padding(.top, 2)
                Text(SampleDataNotice.detail)
                    .font(.system(size: InboxMetrics.detailFontSize))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .padding(.horizontal, InboxMetrics.textInset)
                    .padding(.bottom, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(AppInfo.versionLabel)
                .font(.system(size: InboxMetrics.sectionFontSize))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .padding(.horizontal, InboxMetrics.textInset)
                .padding(.top, 2)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var sectionsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(action: model.showInbox) { hovered in
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("PR inbox sections")
                        .font(.system(size: InboxMetrics.menuFontSize))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(menuForeground(hovered: hovered))
            }
            .accessibilityHint("Back to inbox")

            separator

            ForEach(InboxSection.allCases) { section in
                MenuRow(action: { model.toggleSection(section) }) { hovered in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 14, height: 14)
                            .opacity(model.shows(section) ? 1 : 0)
                        Text(section.title)
                            .font(.system(size: InboxMetrics.menuFontSize))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(menuForeground(hovered: hovered))
                }
                .accessibilityLabel(section.title)
                .accessibilityValue(model.shows(section) ? "Shown" : "Hidden")
            }
        }
    }

    private var preferencesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(action: model.showInbox) { hovered in
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Preferences")
                        .font(.system(size: InboxMetrics.menuFontSize))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(menuForeground(hovered: hovered))
            }
            .accessibilityHint("Back to inbox")

            separator

            if let login = session.user?.login {
                Text("Account")
                    .font(.system(size: InboxMetrics.sectionFontSize))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, InboxMetrics.textInset)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                Text(login)
                    .font(.system(size: InboxMetrics.menuFontSize))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .padding(.horizontal, InboxMetrics.textInset)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Signed in as \(login)")

                MenuRow(action: onManageRepositories) { hovered in
                    Text("Repositories…")
                        .font(.system(size: InboxMetrics.menuFontSize))
                        .foregroundStyle(menuForeground(hovered: hovered))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                MenuRow(action: onUsePersonalAccessToken) { hovered in
                    Text("Personal access token…")
                        .font(.system(size: InboxMetrics.menuFontSize))
                        .foregroundStyle(menuForeground(hovered: hovered))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                MenuRow(action: onSignOut) { hovered in
                    Text("Sign out")
                        .font(.system(size: InboxMetrics.menuFontSize))
                        .foregroundStyle(menuForeground(hovered: hovered))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Notifications")
                .font(.system(size: InboxMetrics.sectionFontSize))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .padding(.horizontal, InboxMetrics.textInset)
                .padding(.top, 4)
                .padding(.bottom, 2)

            MenuRow(action: { onPreviewNotification(.important) }) { hovered in
                Text("Preview important")
                    .font(.system(size: InboxMetrics.menuFontSize))
                    .foregroundStyle(menuForeground(hovered: hovered))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MenuRow(action: { onPreviewNotification(.subtle) }) { hovered in
                Text("Preview subtle")
                    .font(.system(size: InboxMetrics.menuFontSize))
                    .foregroundStyle(menuForeground(hovered: hovered))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Important alerts stay until you close them. Subtle banners dismiss on their own.")
                .font(.system(size: InboxMetrics.detailFontSize))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .padding(.horizontal, InboxMetrics.textInset)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .fixedSize(horizontal: false, vertical: true)

            if session.account?.didFinishNotificationStep == true,
               session.account?.wantsSystemNotifications == false {
                MenuRow(action: onEnableSystemNotifications) { hovered in
                    Text("Enable system notifications")
                        .font(.system(size: InboxMetrics.menuFontSize))
                        .foregroundStyle(menuForeground(hovered: hovered))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 3)
            .accessibilityHidden(true)
    }

    private var signOutLabel: String {
        if let login = session.user?.login {
            return "Sign out \(login)"
        }
        return "Sign out"
    }

    private func openInbox() {
        PullsLog.inbox.info("Opening inbox in the browser")
        NSWorkspace.shared.open(InboxDestination.placeholder)
    }
}

private struct InboxSectionBlock: View {
    var model: InboxModel
    var section: InboxSection
    var onOpenLink: () -> Void

    var body: some View {
        let items = model.pullRequests(in: section)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("\(section.title) (\(items.count))")
                    .font(.system(size: InboxMetrics.sectionFontSize))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                if section.showsExternalLink {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onOpenLink)
                        .accessibilityLabel("Open \(section.title)")
                        .accessibilityAddTraits(.isButton)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InboxMetrics.textInset)
            .padding(.top, 3)
            .padding(.bottom, 1)

            ForEach(items) { pullRequest in
                PullRequestRow(pullRequest: pullRequest) {
                    model.markRead(number: pullRequest.number)
                }
            }
        }
    }
}

private struct PullRequestRow: View {
    var pullRequest: PullRequest
    var onSelect: () -> Void

    var body: some View {
        MenuRow(action: onSelect) { hovered in
            HStack(alignment: .center, spacing: 6) {
                AuthorAvatar(pullRequest: pullRequest)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pullRequest.menuTitle)
                        .font(.system(size: InboxMetrics.menuFontSize, weight: pullRequest.isUnread ? .semibold : .regular))
                        .foregroundStyle(menuForeground(hovered: hovered))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(pullRequest.menuTitle)
                    Text(pullRequest.detailLine)
                        .font(.system(size: InboxMetrics.detailFontSize))
                        .foregroundStyle(menuForeground(hovered: hovered, secondary: true))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: pullRequest.activity.symbolName)
                    .font(.system(size: 11))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(menuForeground(hovered: hovered, secondary: true))
                    .frame(width: 14, height: 14)
                    .layoutPriority(1)
                    .help(pullRequest.activity.label)
                    .accessibilityHidden(true)
                Image(systemName: pullRequest.ciStatus.symbolName)
                    .font(.system(size: 11))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(ciForeground(pullRequest.ciStatus, hovered: hovered))
                    .frame(width: 14, height: 14)
                    .layoutPriority(1)
                    .help(pullRequest.ciStatus.label)
                    .accessibilityHidden(true)
                Circle()
                    .fill(unreadIndicator(pullRequest.isUnread, hovered: hovered))
                    .frame(width: 6, height: 6)
                    .frame(width: 10, height: 10)
                    .layoutPriority(1)
                    .help(pullRequest.isUnread ? "Unread" : "")
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3)
        }
        .accessibilityLabel(pullRequest.accessibilitySummary)
    }
}

private struct AuthorAvatar: View {
    var pullRequest: PullRequest

    var body: some View {
        ZStack {
            avatarShape
                .fill(pullRequest.authorTint.color)
            Text(pullRequest.authorInitials)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(width: InboxMetrics.avatarSize, height: InboxMetrics.avatarSize)
        .accessibilityHidden(true)
    }

    private var avatarShape: AnyShape {
        switch pullRequest.authorStyle {
        case .person:
            AnyShape(Circle())
        case .app:
            AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

/// A menu row that uses a tap gesture instead of `Button`.
/// AppKit was closing the popover on mouse-down, so `Button` never received mouse-up.
private struct MenuRow<Label: View>: View {
    var isEnabled: Bool = true
    var action: () -> Void
    @ViewBuilder var label: (Bool) -> Label

    @State private var isHovered = false

    var body: some View {
        label(isHovered && isEnabled)
            .frame(maxWidth: .infinity, minHeight: InboxMetrics.rowHeight, alignment: .leading)
            .padding(.horizontal, 8)
            .background {
                if isHovered && isEnabled {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .selectedContentBackgroundColor))
                }
            }
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture {
                guard isEnabled else { return }
                action()
            }
            .accessibilityAddTraits(.isButton)
    }
}

/// Hugs the list when it is short, and scrolls once it passes `maxHeight`.
private struct FittingScroll<Content: View>: View {
    var maxHeight: CGFloat
    var measuredHeight: CGFloat
    var onHeight: (CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollContentBackground(.hidden)
        .onPreferenceChange(ListHeightKey.self, perform: onHeight)
        .frame(height: min(max(measuredHeight, 1), maxHeight))
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private func menuForeground(hovered: Bool, secondary: Bool = false) -> Color {
    if hovered {
        return Color(nsColor: .selectedMenuItemTextColor)
    }
    return Color(nsColor: secondary ? .secondaryLabelColor : .labelColor)
}

private func unreadIndicator(_ isUnread: Bool, hovered: Bool) -> AnyShapeStyle {
    if !isUnread {
        return AnyShapeStyle(Color.clear)
    }
    if hovered {
        return AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor))
    }
    return AnyShapeStyle(Color(nsColor: .controlAccentColor))
}

private func ciForeground(_ status: CIStatus, hovered: Bool) -> Color {
    if hovered {
        return Color(nsColor: .selectedMenuItemTextColor)
    }
    switch status {
    case .passing:
        return Color(nsColor: .systemGreen)
    case .failing:
        return Color(nsColor: .systemRed)
    case .pending:
        return Color(nsColor: .systemOrange)
    }
}

private extension AuthorTint {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}
