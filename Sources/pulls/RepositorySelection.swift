import Foundation
import Observation

struct RepositoryChoice: Identifiable, Equatable, Sendable {
    var id: Int
    var ownerLogin: String
    var name: String
    var isPrivate: Bool
    var isUnavailable: Bool

    var displayName: String {
        ownerLogin.isEmpty ? name : "\(ownerLogin)/\(name)"
    }

    var statusLabel: String {
        let visibility = isPrivate ? "Private" : "Public"
        if isUnavailable {
            return "\(visibility) · Unavailable"
        }
        return visibility
    }

}

extension RepositoryChoice {
    init(stored: StoredRepository, isUnavailable: Bool) {
        self.init(
            id: stored.id,
            ownerLogin: stored.ownerLogin,
            name: stored.name,
            isPrivate: stored.isPrivate,
            isUnavailable: isUnavailable
        )
    }
}

enum RepositoryFilter {
    static func matches(_ choice: RepositoryChoice, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = [
            choice.displayName,
            choice.ownerLogin,
            choice.name,
            choice.statusLabel,
        ].joined(separator: " ").lowercased()
        return haystack.contains(trimmed.lowercased())
    }
}

enum RepositoryMerge {
    /// A successful fetch marks saved repositories that are missing as unavailable. It does not drop them.
    static func choices(stored: [StoredRepository], fetched: [GitHubRepository]) -> [RepositoryChoice] {
        var storedByID: [Int: StoredRepository] = [:]
        for repository in stored {
            storedByID[repository.id] = repository
        }
        var seen = Set<Int>()
        var result: [RepositoryChoice] = []
        for repository in fetched where seen.insert(repository.id).inserted {
            result.append(
                RepositoryChoice(
                    id: repository.id,
                    ownerLogin: repository.ownerLogin,
                    name: repository.name,
                    isPrivate: repository.isPrivate,
                    isUnavailable: false
                )
            )
        }
        let missing = stored
            .filter { !seen.contains($0.id) }
            .sorted { lhs, rhs in
                let owner = lhs.ownerLogin.localizedStandardCompare(rhs.ownerLogin)
                if owner == .orderedSame {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return owner == .orderedAscending
            }
        result.append(contentsOf: missing.map { RepositoryChoice(stored: $0, isUnavailable: true) })
        return result
    }

    /// Unchecked rows are the only ones removed. Unavailable rows stay when they are still checked.
    static func saved(choices: [RepositoryChoice], selectedIDs: Set<Int>) -> [StoredRepository] {
        choices.compactMap { choice in
            guard selectedIDs.contains(choice.id) else { return nil }
            return StoredRepository(
                id: choice.id,
                ownerLogin: choice.ownerLogin,
                name: choice.name,
                isPrivate: choice.isPrivate
            )
        }
    }

    static func canContinue(selectedIDs: Set<Int>) -> Bool {
        !selectedIDs.isEmpty
    }
}

@MainActor
@Observable
final class RepositorySelectionModel {
    var choices: [RepositoryChoice] = []
    var selectedIDs: Set<Int> = []
    var query = ""
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored
    private var hasInitializedSelection = false
    @ObservationIgnored
    private var reloadStored: [StoredRepository] = []
    @ObservationIgnored
    private var reloadList: (() async throws -> [GitHubRepository])?

    var filteredChoices: [RepositoryChoice] {
        choices.filter { RepositoryFilter.matches($0, query: query) }
    }

    var canContinue: Bool {
        RepositoryMerge.canContinue(selectedIDs: selectedIDs) && !isLoading
    }

    func toggle(_ id: Int) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func repositoriesForSave() -> [StoredRepository] {
        RepositoryMerge.saved(choices: choices, selectedIDs: selectedIDs)
    }

    func reload(
        stored: [StoredRepository],
        list: @escaping () async throws -> [GitHubRepository]
    ) async {
        reloadStored = stored
        reloadList = list
        await load()
    }

    func retry() async {
        await load()
    }

    private func load() async {
        guard let reloadList else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await reloadList()
            choices = RepositoryMerge.choices(stored: reloadStored, fetched: fetched)
            if !hasInitializedSelection {
                selectedIDs = Set(reloadStored.map(\.id))
                hasInitializedSelection = true
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? GitHubError)?.userMessage ?? GitHubError.network.userMessage
            // A failed fetch must not relabel saved repositories as unavailable or drop them.
            if choices.isEmpty {
                choices = reloadStored.map { RepositoryChoice(stored: $0, isUnavailable: false) }
                if !hasInitializedSelection {
                    selectedIDs = Set(reloadStored.map(\.id))
                    hasInitializedSelection = true
                }
            }
        }
    }
}
