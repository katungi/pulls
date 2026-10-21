import Foundation

struct StoredRepository: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var ownerLogin: String
    var name: String
    var isPrivate: Bool
}

struct StoredAccount: Codable, Equatable, Sendable {
    var userID: Int
    var login: String
    var name: String?
    var repositories: [StoredRepository]
    var didFinishNotificationStep: Bool
    var wantsSystemNotifications: Bool

    var isSetupComplete: Bool {
        !repositories.isEmpty && didFinishNotificationStep
    }
}

struct AccountFile: Codable, Equatable, Sendable {
    var accounts: [StoredAccount]
    var lastUserID: Int?
}

struct AccountStore {
    var defaults: UserDefaults
    static let storageKey = "accountFile"

    func load() -> AccountFile {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return AccountFile(accounts: [], lastUserID: nil)
        }
        return (try? JSONDecoder().decode(AccountFile.self, from: data))
            ?? AccountFile(accounts: [], lastUserID: nil)
    }

    func account(for userID: Int) -> StoredAccount? {
        load().accounts.first { $0.userID == userID }
    }

    func lastAccount() -> StoredAccount? {
        let file = load()
        guard let id = file.lastUserID else { return nil }
        return file.accounts.first { $0.userID == id }
    }

    func save(_ account: StoredAccount) {
        var file = load()
        if let index = file.accounts.firstIndex(where: { $0.userID == account.userID }) {
            file.accounts[index] = account
        } else {
            file.accounts.append(account)
        }
        file.lastUserID = account.userID
        guard let data = try? JSONEncoder().encode(file) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum SetupRoute: Equatable, Sendable {
    case connect
    case repositories
    case notifications
    case ready
}

func setupRoute(hasCredential: Bool, account: StoredAccount?) -> SetupRoute {
    guard hasCredential else { return .connect }
    guard let account else { return .repositories }
    if account.repositories.isEmpty { return .repositories }
    if !account.didFinishNotificationStep { return .notifications }
    return .ready
}
