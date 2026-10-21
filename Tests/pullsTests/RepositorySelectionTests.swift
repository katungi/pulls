import Foundation
import Testing
@testable import pulls

private func stored(id: Int, owner: String = "octo", name: String = "pulls", isPrivate: Bool = true) -> StoredRepository {
    StoredRepository(id: id, ownerLogin: owner, name: name, isPrivate: isPrivate)
}

private func fetched(id: Int, owner: String = "octo", name: String, isPrivate: Bool = false) -> GitHubRepository {
    GitHubRepository(id: id, name: name, fullName: "\(owner)/\(name)", isPrivate: isPrivate, ownerLogin: owner)
}

@Test func selectionStartsEmptyAndRequiresOneRepository() {
    let choices = RepositoryMerge.choices(
        stored: [],
        fetched: [fetched(id: 1, name: "one"), fetched(id: 2, name: "two")]
    )
    #expect(choices.count == 2)
    #expect(choices.allSatisfy { $0.isUnavailable == false })
    #expect(RepositoryMerge.saved(choices: choices, selectedIDs: []).isEmpty)
    #expect(RepositoryMerge.canContinue(selectedIDs: []) == false)
    #expect(RepositoryMerge.canContinue(selectedIDs: [1]))
}

@Test func missingRepositoryStaysSelectedUntilDeselected() {
    let storedRepos = [stored(id: 9, name: "gone"), stored(id: 1, name: "one")]
    let choices = RepositoryMerge.choices(stored: storedRepos, fetched: [fetched(id: 1, name: "one", isPrivate: true)])
    let missing = choices.first { $0.id == 9 }
    #expect(missing?.isUnavailable == true)
    #expect(missing?.displayName == "octo/gone")
    #expect(missing?.statusLabel == "Private · Unavailable")
    let selected: Set<Int> = [9, 1]
    #expect(RepositoryMerge.saved(choices: choices, selectedIDs: selected).map(\.id) == [1, 9])
    #expect(RepositoryMerge.saved(choices: choices, selectedIDs: [1]).map(\.id) == [1])
}

@Test func searchMatchesOwnerNameAndUnavailable() {
    let choice = RepositoryChoice(stored: stored(id: 3, owner: "acme", name: "api"), isUnavailable: true)
    #expect(RepositoryFilter.matches(choice, query: " acme "))
    #expect(RepositoryFilter.matches(choice, query: "API"))
    #expect(RepositoryFilter.matches(choice, query: "unavailable"))
    #expect(RepositoryFilter.matches(choice, query: "nope") == false)
    #expect(RepositoryFilter.matches(choice, query: " "))
}

@Test @MainActor func reloadKeepsUnavailableRepositoriesAndDoesNotSelectAll() async {
    let model = RepositorySelectionModel()
    await model.reload(stored: [stored(id: 9, name: "gone")]) {
        [fetched(id: 1, name: "one"), fetched(id: 2, name: "two")]
    }
    #expect(model.selectedIDs == [9])
    #expect(model.choices.contains { $0.id == 9 && $0.isUnavailable })
    #expect(model.choices.filter { !$0.isUnavailable }.count == 2)
    model.toggle(1)
    model.toggle(9)
    #expect(model.repositoriesForSave().map(\.id) == [1])
}

@Test @MainActor func failedReloadDoesNotMarkSavedRepositoriesUnavailable() async {
    let model = RepositorySelectionModel()
    await model.reload(stored: [stored(id: 9, name: "gone")]) {
        throw GitHubError.network
    }
    #expect(model.errorMessage == GitHubError.network.userMessage)
    #expect(model.choices == [RepositoryChoice(stored: stored(id: 9, name: "gone"), isUnavailable: false)])
    #expect(model.selectedIDs == [9])
    #expect(model.repositoriesForSave().map(\.id) == [9])
}

@Test @MainActor func phaseTwoKeepsSamplePullRequests() {
    let model = InboxModel()
    #expect(model.usesSampleData)
    #expect(model.pullRequests.map(\.number) == MockInbox.pullRequests.map(\.number))
    #expect(SampleDataNotice.title == "Sample data")
    #expect(SampleDataNotice.detail.contains("GitHub sync comes later"))
}
