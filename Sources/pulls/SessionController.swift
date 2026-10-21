import Foundation
import Observation

enum SessionPhase: Equatable, Sendable {
    case signedOut
    case restoring
    case signedIn
}

@MainActor
@Observable
final class SessionController {
    private(set) var phase: SessionPhase = .signedOut
    private(set) var user: GitHubUser?
    private(set) var account: StoredAccount?
    private(set) var isOffline = false
    private(set) var statusMessage: String?
    private(set) var grantedScope: String = ""

    @ObservationIgnored
    private var api: GitHubAPI
    @ObservationIgnored
    let configuration: GitHubClientConfiguration
    @ObservationIgnored
    private let tokenStore: any TokenStoring
    @ObservationIgnored
    private let accountStore: AccountStore
    @ObservationIgnored
    private let authorizer: any SystemNotificationAuthorizing

    init(
        api: GitHubAPI,
        configuration: GitHubClientConfiguration,
        tokenStore: any TokenStoring,
        accountStore: AccountStore,
        authorizer: any SystemNotificationAuthorizing
    ) {
        self.api = api
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.accountStore = accountStore
        self.authorizer = authorizer
    }

    static func makeLive() -> SessionController {
        let configuration = GitHubClientConfigurationLoader.loadFromDisk()
        let api = GitHubAPI(
            transport: URLSessionGitHubTransport(),
            clientID: configuration.clientID ?? "",
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) }
        )
        let defaults = UserDefaults(suiteName: AppIdentity.bundleID) ?? .standard
        return SessionController(
            api: api,
            configuration: configuration,
            tokenStore: KeychainTokenStore(service: AppIdentity.bundleID),
            accountStore: AccountStore(defaults: defaults),
            authorizer: UserNotificationCenterAuthorizer()
        )
    }

    var route: SetupRoute {
        switch phase {
        case .signedOut:
            return .connect
        case .restoring, .signedIn:
            return setupRoute(hasCredential: true, account: account)
        }
    }

    /// Hidden while a saved credential is still being checked, so Connect does not flash on launch.
    var needsOnboarding: Bool {
        if phase == .restoring { return false }
        return route != .ready
    }

    var hasClientID: Bool {
        configuration.clientID?.isEmpty == false
    }

    func restore() async {
        let stored: GitHubCredential
        do {
            guard let credential = try tokenStore.read() else {
                phase = .signedOut
                return
            }
            stored = credential
        } catch {
            PullsLog.auth.error("Could not read the Keychain credential")
            phase = .signedOut
            return
        }
        grantedScope = stored.scope
        if let cached = accountStore.lastAccount() {
            account = cached
            user = GitHubUser(id: cached.userID, login: cached.login, name: cached.name)
        }
        phase = .restoring
        do {
            let credential = try await usableCredential()
            let user = try await api.currentUser(accessToken: credential.accessToken)
            adopt(user)
            PullsLog.auth.info("Restored GitHub session")
        } catch GitHubError.unauthorized {
            rejectCredential(message: GitHubError.unauthorized.userMessage)
        } catch GitHubError.refreshRequiresClientSecret {
            await keepWorkingTokenOrSignOut(stored)
        } catch {
            isOffline = true
            phase = .signedIn
            PullsLog.auth.error("Session restore could not reach GitHub")
        }
    }

    func beginDeviceAuthorization() async throws -> DeviceCode {
        guard hasClientID else { throw GitHubError.missingClientID }
        PullsLog.auth.info("Device flow started")
        return try await api.requestDeviceCode()
    }

    func finishDeviceAuthorization(_ device: DeviceCode) async throws -> GitHubUser {
        let credential = try await api.poll(device)
        guard GitHubScope.allowsRepositoryList(credential.scope) else {
            throw GitHubError.insufficientScope
        }
        do {
            try tokenStore.write(credential)
        } catch {
            throw GitHubError.keychain
        }
        grantedScope = credential.scope
        do {
            let user = try await api.currentUser(accessToken: credential.accessToken)
            adopt(user)
            PullsLog.auth.info("GitHub account connected")
            return user
        } catch GitHubError.unauthorized {
            rejectCredential(message: GitHubError.unauthorized.userMessage)
            throw GitHubError.unauthorized
        }
    }

    func repositoryList() async throws -> [GitHubRepository] {
        do {
            let credential = try await usableCredential()
            return try await listedRepositories(accessToken: credential.accessToken)
        } catch GitHubError.refreshRequiresClientSecret {
            guard let stored = try tokenStore.read() else {
                rejectCredential(message: GitHubError.refreshRequiresClientSecret.userMessage)
                throw GitHubError.refreshRequiresClientSecret
            }
            do {
                let repositories = try await api.listRepositories(accessToken: stored.accessToken)
                statusMessage = GitHubError.refreshRequiresClientSecret.userMessage
                return repositories
            } catch GitHubError.unauthorized {
                rejectCredential(message: GitHubError.refreshRequiresClientSecret.userMessage)
                throw GitHubError.refreshRequiresClientSecret
            }
        } catch GitHubError.unauthorized {
            rejectCredential(message: GitHubError.unauthorized.userMessage)
            throw GitHubError.unauthorized
        }
    }

    private func listedRepositories(accessToken: String) async throws -> [GitHubRepository] {
        do {
            return try await api.listRepositories(accessToken: accessToken)
        } catch GitHubError.unauthorized {
            rejectCredential(message: GitHubError.unauthorized.userMessage)
            throw GitHubError.unauthorized
        }
    }

    func saveRepositories(_ repositories: [StoredRepository]) {
        guard var account, !repositories.isEmpty else { return }
        account.repositories = repositories
        accountStore.save(account)
        self.account = account
    }

    func finishNotificationStep(wantsSystemNotifications: Bool) {
        guard var account else { return }
        account.didFinishNotificationStep = true
        account.wantsSystemNotifications = wantsSystemNotifications
        accountStore.save(account)
        self.account = account
    }

    func enableSystemNotifications() async {
        let granted = await authorizer.requestAuthorization()
        guard granted, var account else { return }
        account.wantsSystemNotifications = true
        accountStore.save(account)
        self.account = account
    }

    func requestSystemNotificationAuthorization() async -> Bool {
        await authorizer.requestAuthorization()
    }

    /// Replaces the saved sign-in only after GitHub accepts the token. A rejected paste leaves the current session in place.
    func signIn(withPastedAccessToken raw: String) async throws {
        guard let token = AccessTokenPaste.value(from: raw) else {
            throw GitHubError.invalidAccessToken
        }
        let profile = try await api.profile(accessToken: token)
        // A classic token lists scopes. A fine-grained token omits them and is limited by its own repository access.
        if !profile.oauthScopes.isEmpty, !GitHubScope.allowsRepositoryList(profile.oauthScopes) {
            throw GitHubError.insufficientScope
        }
        let credential = GitHubCredential(
            accessToken: token,
            refreshToken: nil,
            accessTokenExpiresAt: nil,
            refreshTokenExpiresAt: nil,
            scope: profile.oauthScopes
        )
        do {
            try tokenStore.write(credential)
        } catch {
            throw GitHubError.keychain
        }
        grantedScope = credential.scope
        adopt(profile.user)
        PullsLog.auth.info("Signed in with a pasted GitHub token")
    }

    func signOut() {
        statusMessage = nil
        clearSession()
        PullsLog.auth.info("Signed out")
    }

    func adopt(_ user: GitHubUser) {
        self.user = user
        var account = accountStore.account(for: user.id) ?? StoredAccount(
            userID: user.id,
            login: user.login,
            name: user.name,
            repositories: [],
            didFinishNotificationStep: false,
            wantsSystemNotifications: false
        )
        account.login = user.login
        account.name = user.name
        accountStore.save(account)
        self.account = account
        phase = .signedIn
        isOffline = false
        statusMessage = nil
    }

    private func usableCredential() async throws -> GitHubCredential {
        guard let stored = try tokenStore.read() else { throw GitHubError.unauthorized }
        guard stored.needsRefresh(at: api.now()) else { return stored }
        guard stored.refreshTokenIsUsable(at: api.now()) else { throw GitHubError.unauthorized }
        let refreshed = try await api.refresh(stored)
        try tokenStore.write(refreshed)
        grantedScope = refreshed.scope
        PullsLog.auth.info("Refreshed GitHub access token")
        return refreshed
    }

    /// The access token may still be inside the refresh window. Try it before deleting the Keychain item.
    private func keepWorkingTokenOrSignOut(_ stored: GitHubCredential) async {
        do {
            let user = try await api.currentUser(accessToken: stored.accessToken)
            adopt(user)
            statusMessage = GitHubError.refreshRequiresClientSecret.userMessage
        } catch GitHubError.unauthorized {
            rejectCredential(message: GitHubError.refreshRequiresClientSecret.userMessage)
        } catch {
            isOffline = true
            phase = .signedIn
            PullsLog.auth.error("Session restore could not reach GitHub")
        }
    }

    private func rejectCredential(message: String) {
        clearSession()
        statusMessage = message
        PullsLog.auth.info("Cleared rejected GitHub credential")
    }

    private func clearSession() {
        try? tokenStore.delete()
        user = nil
        account = nil
        grantedScope = ""
        phase = .signedOut
        isOffline = false
    }
}
