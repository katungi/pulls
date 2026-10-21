import Testing
@testable import pulls

@Test func mockInboxMatchesReference() {
    let pulls = MockInbox.pullRequests

    #expect(pulls.map(\.menuTitle) == [
        "PR 17603: feat(keyboard): Add employees-only preference for keyboard ads",
        "PR 17601: chore(websubmit): switch around flex layout to avoid explicit margin",
        "PR 17591: fix(websubmit): use consistent ordering for reviewer list",
        "PR 17586: refactor: split out reviewer into a reusable component",
        "PR 17254: make server dockerfile use same calling directory as local env",
    ])
    #expect(pulls.map(\.section) == [
        .needsReview,
        .needsReview,
        .needsReview,
        .needsReview,
        .approved,
    ])
    #expect(pulls.filter { $0.section == .waitingForReviewers }.isEmpty)
    #expect(StatusItemTitle.format(count: pulls.count) == "5 PRs")
    #expect(pulls.filter(\.isUnread).count == 2)
    #expect(Set(pulls.map(\.ciStatus)) == [.passing, .failing, .pending])
    #expect(Set(pulls.map(\.activity)) == [
        .reviewRequested,
        .commented,
        .changesRequested,
        .pushed,
        .approved,
    ])
    #expect(pulls.contains { $0.authorStyle == .person })
    #expect(pulls.contains { $0.authorStyle == .app })
}

@Test func dummyNotificationsUseInboxCopy() {
    let important = DummyNotifications.make(.important)
    let subtle = DummyNotifications.make(.subtle)
    let review = MockInbox.pullRequests.first { $0.isUnread && $0.section == .needsReview }
    let pushed = MockInbox.pullRequests.first { $0.activity == .pushed }

    #expect(important.emphasis == .important)
    #expect(important.title == "Needs your review")
    #expect(important.message == review?.menuTitle)
    #expect(subtle.emphasis == .subtle)
    #expect(subtle.title == "PR \(pushed?.number ?? 0) updated")
    #expect(subtle.message == "\(pushed?.authorName ?? "") pushed a commit")
    #expect(NotificationEmphasis.important.width == NotificationEmphasis.subtle.width)
    #expect(NotificationEmphasis.important.visibleDuration == nil)
    #expect(NotificationEmphasis.subtle.visibleDuration != nil)
}

@Test func pullRequestDetailLineIncludesActivityAndAuthor() {
    let review = MockInbox.pullRequests[0]
    #expect(review.isUnread)
    #expect(!MockInbox.pullRequests[2].isUnread)
    #expect(review.detailLine.contains("Review requested"))
    #expect(review.detailLine.contains(review.authorName))
    #expect(review.detailLine.contains(RelativeTimestamp.phrase(since: review.updatedAt)))
    #expect(InboxMetrics.width == 500)
}

@Test func statusItemTitlePluralizes() {
    #expect(StatusItemTitle.format(count: 0) == "0 PRs")
    #expect(StatusItemTitle.format(count: 1) == "1 PR")
    #expect(StatusItemTitle.format(count: 5) == "5 PRs")
}

@Test @MainActor func emptyWaitingSectionStaysAvailable() {
    let model = InboxModel()
    #expect(model.shows(.waitingForReviewers))
    #expect(model.pullRequests(in: .waitingForReviewers).isEmpty)
    #expect(model.statusItemTitle == "5 PRs")
}

@Test @MainActor func hidingApprovedSectionUpdatesStatusTitle() {
    let model = InboxModel()
    model.toggleSection(.approved)
    #expect(!model.shows(.approved))
    #expect(model.statusItemTitle == "4 PRs")
}

@Test @MainActor func selectingPullRequestClearsUnread() {
    let model = InboxModel()
    #expect(model.pullRequests.first?.isUnread == true)
    model.markRead(number: 17603)
    #expect(model.pullRequests.first { $0.number == 17603 }?.isUnread == false)
}
