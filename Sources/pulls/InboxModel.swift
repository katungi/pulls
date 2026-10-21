import Foundation
import Observation

struct AuthorTint: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let slate = AuthorTint(red: 0.33, green: 0.48, blue: 0.64)
    static let clay = AuthorTint(red: 0.70, green: 0.43, blue: 0.34)
    static let sage = AuthorTint(red: 0.36, green: 0.50, blue: 0.40)
    static let plum = AuthorTint(red: 0.49, green: 0.38, blue: 0.60)
    static let blue = AuthorTint(red: 0.29, green: 0.52, blue: 0.93)
}

enum AuthorStyle: Equatable, Sendable {
    /// Circular photo-style initials, matching the people in the reference inbox.
    case person
    /// Rounded square, matching the approved row's app avatar.
    case app
}

enum InboxSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case needsReview
    case approved
    case waitingForReviewers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsReview:
            "Needs your review"
        case .approved:
            "Approved"
        case .waitingForReviewers:
            "Waiting for reviewers"
        }
    }

    /// The reference omits the external-link icon on the waiting section.
    var showsExternalLink: Bool {
        switch self {
        case .needsReview, .approved:
            true
        case .waitingForReviewers:
            false
        }
    }
}

enum CIStatus: Hashable, Sendable {
    case passing
    case failing
    case pending

    var label: String {
        switch self {
        case .passing:
            "CI passing"
        case .failing:
            "CI failing"
        case .pending:
            "CI pending"
        }
    }

    var symbolName: String {
        switch self {
        case .passing:
            "checkmark.circle.fill"
        case .failing:
            "xmark.circle.fill"
        case .pending:
            "clock.fill"
        }
    }
}

enum RelativeTimestamp {
    static func phrase(since date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum ReviewActivity: Hashable, Sendable {
    case reviewRequested
    case commented
    case changesRequested
    case pushed
    case approved

    var label: String {
        switch self {
        case .reviewRequested:
            "Review requested"
        case .commented:
            "New comment"
        case .changesRequested:
            "Changes requested"
        case .pushed:
            "New push"
        case .approved:
            "Approved"
        }
    }

    var symbolName: String {
        switch self {
        case .reviewRequested:
            "eye"
        case .commented:
            "bubble.left"
        case .changesRequested:
            "arrow.uturn.backward"
        case .pushed:
            "arrow.up"
        case .approved:
            "checkmark"
        }
    }
}

enum InboxPage: Equatable, Sendable {
    case inbox
    case sections
    case preferences
}

struct PullRequest: Identifiable, Equatable, Sendable {
    let number: Int
    let title: String
    let authorName: String
    let authorInitials: String
    let authorTint: AuthorTint
    let authorStyle: AuthorStyle
    let section: InboxSection
    let ciStatus: CIStatus
    let activity: ReviewActivity
    let updatedAt: Date
    var isUnread: Bool

    var id: Int { number }

    var menuTitle: String {
        "PR \(number): \(title)"
    }

    /// Latest activity, who did it, and how long ago. Shown under the title.
    var detailLine: String {
        "\(activity.label) · \(authorName) · \(RelativeTimestamp.phrase(since: updatedAt))"
    }

    var accessibilitySummary: String {
        var parts = [menuTitle, detailLine, ciStatus.label]
        if isUnread {
            parts.append("Unread")
        }
        return parts.joined(separator: ", ")
    }
}

enum StatusItemTitle {
    static func format(count: Int) -> String {
        count == 1 ? "1 PR" : "\(count) PRs"
    }
}

enum MockInbox {
    /// Titles and section placement are copied from the reference inbox.
    static let pullRequests: [PullRequest] = [
        PullRequest(
            number: 17603,
            title: "feat(keyboard): Add employees-only preference for keyboard ads",
            authorName: "Alex Kim",
            authorInitials: "AK",
            authorTint: .slate,
            authorStyle: .person,
            section: .needsReview,
            ciStatus: .passing,
            activity: .reviewRequested,
            updatedAt: Date(timeIntervalSinceNow: -4 * 60),
            isUnread: true
        ),
        PullRequest(
            number: 17601,
            title: "chore(websubmit): switch around flex layout to avoid explicit margin",
            authorName: "Mina Lee",
            authorInitials: "ML",
            authorTint: .clay,
            authorStyle: .person,
            section: .needsReview,
            ciStatus: .pending,
            activity: .commented,
            updatedAt: Date(timeIntervalSinceNow: -18 * 60),
            isUnread: true
        ),
        PullRequest(
            number: 17591,
            title: "fix(websubmit): use consistent ordering for reviewer list",
            authorName: "Jordan Ruiz",
            authorInitials: "JR",
            authorTint: .sage,
            authorStyle: .person,
            section: .needsReview,
            ciStatus: .failing,
            activity: .changesRequested,
            updatedAt: Date(timeIntervalSinceNow: -60 * 60),
            isUnread: false
        ),
        PullRequest(
            number: 17586,
            title: "refactor: split out reviewer into a reusable component",
            authorName: "Sam Patel",
            authorInitials: "SP",
            authorTint: .plum,
            authorStyle: .person,
            section: .needsReview,
            ciStatus: .passing,
            activity: .pushed,
            updatedAt: Date(timeIntervalSinceNow: -3 * 60 * 60),
            isUnread: false
        ),
        PullRequest(
            number: 17254,
            title: "make server dockerfile use same calling directory as local env",
            authorName: "GitHub App",
            authorInitials: "GH",
            authorTint: .blue,
            authorStyle: .app,
            section: .approved,
            ciStatus: .passing,
            activity: .approved,
            updatedAt: Date(timeIntervalSinceNow: -26 * 60 * 60),
            isUnread: false
        ),
    ]
}

enum SampleDataNotice {
    static let title = "Sample data"
    static let detail = "These pull requests are built in. GitHub sync comes later."
}

enum InboxDestination {
    /// Phase 2 replaces this with the signed-in review inbox. Constant https URL, no user input.
    static let placeholder = URL(string: "https://github.com")!
}

@MainActor
@Observable
final class InboxModel {
    private(set) var pullRequests: [PullRequest]
    var enabledSections: Set<InboxSection>
    var page: InboxPage
    private(set) var isRefreshing = false
    /// Height of the scrolling PR list, capped by the view. Drives the popover size.
    private(set) var measuredListHeight: CGFloat = 240

    /// Phase 2 still renders the built-in sample list. Real pull-request sync comes later.
    var usesSampleData: Bool { true }

    init(pullRequests: [PullRequest] = MockInbox.pullRequests) {
        self.pullRequests = pullRequests
        self.enabledSections = Set(InboxSection.allCases)
        self.page = .inbox
    }

    var visiblePullRequests: [PullRequest] {
        pullRequests.filter { enabledSections.contains($0.section) }
    }

    var statusItemTitle: String {
        StatusItemTitle.format(count: visiblePullRequests.count)
    }

    func pullRequests(in section: InboxSection) -> [PullRequest] {
        pullRequests.filter { $0.section == section }
    }

    func shows(_ section: InboxSection) -> Bool {
        enabledSections.contains(section)
    }

    func toggleSection(_ section: InboxSection) {
        if enabledSections.contains(section) {
            enabledSections.remove(section)
        } else {
            enabledSections.insert(section)
        }
    }

    func showSections() {
        page = .sections
    }

    func showInbox() {
        page = .inbox
    }

    func showPreferences() {
        page = .preferences
    }

    func noteMeasuredListHeight(_ height: CGFloat) {
        let next = min(max(height, 1), InboxMetrics.maxListHeight)
        guard abs(next - measuredListHeight) > 0.5 else { return }
        measuredListHeight = next
    }

    /// Opening a row is the read receipt. The popover stays up so the weight change is visible.
    func markRead(number: Int) {
        guard let index = pullRequests.firstIndex(where: { $0.number == number }) else { return }
        pullRequests[index].isUnread = false
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        PullsLog.inbox.info("Refreshing inbox")
        try? await Task.sleep(for: .milliseconds(650))
        isRefreshing = false
        PullsLog.inbox.info("Inbox refresh finished")
    }
}
