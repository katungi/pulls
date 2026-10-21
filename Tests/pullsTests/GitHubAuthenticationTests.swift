import Foundation
import os
import Testing
@testable import pulls

actor ScriptedGitHubTransport: GitHubTransport {
    private var steps: [Result<GitHubHTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Result<GitHubHTTPResponse, Error>]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw GitHubError.unexpectedResponse }
        return try steps.removeFirst().get()
    }
}

actor SleepLog {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: GitHubCredential?

    func read() throws -> GitHubCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credential
    }

    func write(_ credential: GitHubCredential) throws {
        lock.lock()
        defer { lock.unlock() }
        self.credential = credential
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        credential = nil
    }
}

final class RecordingAuthorizer: SystemNotificationAuthorizing, @unchecked Sendable {
    private struct State {
        var calls = 0
        var result = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var result: Bool {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    var callCount: Int {
        state.withLock { $0.calls }
    }

    func requestAuthorization() async -> Bool {
        state.withLock { state in
            state.calls += 1
            return state.result
        }
    }
}

private let clock = Date(timeIntervalSince1970: 1_700_000_000)

private func http(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Result<GitHubHTTPResponse, Error> {
    .success(GitHubHTTPResponse(statusCode: status, data: Data(body.utf8), headerFields: headers))
}

private func formFields(_ request: URLRequest) -> [String: String] {
    guard let body = request.httpBody, let string = String(data: body, encoding: .utf8) else { return [:] }
    var fields: [String: String] = [:]
    for pair in string.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let name = String(parts[0]).removingPercentEncoding ?? ""
        let value = String(parts[1]).removingPercentEncoding ?? ""
        fields[name] = value
    }
    return fields
}

private func makeAPI(
    _ transport: ScriptedGitHubTransport,
    clientID: String = "Iv1.test",
    sleep: SleepLog = SleepLog()
) -> GitHubAPI {
    GitHubAPI(
        transport: transport,
        clientID: clientID,
        now: { clock },
        sleep: { duration in
            await sleep.record(duration)
        }
    )
}

@MainActor
private func makeSession(
    transport: ScriptedGitHubTransport,
    store: InMemoryTokenStore = InMemoryTokenStore(),
    defaults: UserDefaults,
    authorizer: RecordingAuthorizer = RecordingAuthorizer(),
    configuration: GitHubClientConfiguration = GitHubClientConfiguration(clientID: "Iv1.test", ignoredClientSecret: false)
) -> (SessionController, InMemoryTokenStore, RecordingAuthorizer) {
    let session = SessionController(
        api: makeAPI(transport, clientID: configuration.clientID ?? ""),
        configuration: configuration,
        tokenStore: store,
        accountStore: AccountStore(defaults: defaults),
        authorizer: authorizer
    )
    return (session, store, authorizer)
}

private func temporaryDefaults() -> (UserDefaults, String) {
    let name = "app.pulls.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
}

private func sampleDevice() -> DeviceCode {
    DeviceCode(
        deviceCode: "device-code",
        userCode: "WDJB-MJHT",
        verificationURL: URL(string: "https://github.com/login/device")!,
        expiresAt: clock.addingTimeInterval(900),
        interval: .seconds(5)
    )
}

@Test func clientIDResolutionOrderAndSecretAreSeparate() {
    let bundled = Data(#"{"clientId":"bundled","clientSecret":"do-not-keep"}"#.utf8)
    let support = Data(#"{"clientId":"support"}"#.utf8)
    let fromEnvironment = GitHubClientConfigurationLoader.resolve(
        environment: [GitHubClientConfigurationLoader.environmentKey: " from-env "],
        bundledData: bundled,
        applicationSupportData: support
    )
    #expect(fromEnvironment.clientID == "from-env")
    #expect(fromEnvironment.ignoredClientSecret)

    let fromBundle = GitHubClientConfigurationLoader.resolve(
        environment: [:],
        bundledData: bundled,
        applicationSupportData: support
    )
    #expect(fromBundle.clientID == "bundled")
    #expect(fromBundle.ignoredClientSecret)

    let fromSupport = GitHubClientConfigurationLoader.resolve(
        environment: [:],
        bundledData: Data(#"{"clientId":" "}"#.utf8),
        applicationSupportData: support
    )
    #expect(fromSupport.clientID == "support")
    #expect(fromSupport.ignoredClientSecret == false)

    let missing = GitHubClientConfigurationLoader.resolve(environment: [:], bundledData: nil, applicationSupportData: nil)
    #expect(missing.clientID == nil)
    #expect(GitHubScope.parameter == "repo notifications read:user")
    #expect(GitHubAccessCopy.scopeSummary.contains("full control"))
    #expect(GitHubAccessCopy.allowlistSummary.contains("allowlist"))
    #expect(GitHubAccessCopy.allowlistSummary.contains("involve you"))
}

@Test func deviceCodeRejectsNonGitHubVerificationURL() throws {
    let bad = Data(#"{"device_code":"d","user_code":"ABCD-EFGH","verification_uri":"https://evil.example/device","expires_in":900,"interval":5}"#.utf8)
    #expect(throws: GitHubError.unexpectedResponse) {
        try interpretDeviceCode(bad, now: clock)
    }
    #expect(GitHubHosts.canOpen(URL(string: "http://github.com/login/device")!) == false)
    #expect(GitHubHosts.canOpen(URL(string: "https://github.com.evil/login/device")!) == false)
    #expect(GitHubHosts.canOpen(URL(string: "https://github.com/login/device")!))
}

@Test func slowDownUsesHintOrAddsFiveSeconds() {
    #expect(intervalAfterSlowDown(current: .seconds(5), hintedSeconds: 15) == .seconds(15))
    #expect(intervalAfterSlowDown(current: .seconds(5), hintedSeconds: nil) == .seconds(10))
    #expect(intervalAfterSlowDown(current: .seconds(5), hintedSeconds: 0) == .seconds(10))
    #expect(pollingInterval(seconds: nil) == .seconds(5))
}

@Test func tokenErrorsMapPendingSlowDownExpiryAndDenial() throws {
    let pending = try interpretTokenResponse(
        Data(#"{"error":"authorization_pending"}"#.utf8),
        context: .devicePoll,
        now: clock,
        currentInterval: .seconds(5)
    )
    #expect(pending == .pending(.seconds(5)))

    let slowed = try interpretTokenResponse(
        Data(#"{"error":"slow_down","interval":10}"#.utf8),
        context: .devicePoll,
        now: clock,
        currentInterval: .seconds(5)
    )
    #expect(slowed == .pending(.seconds(10)))

    let expired = try interpretTokenResponse(
        Data(#"{"error":"token_expired"}"#.utf8),
        context: .devicePoll,
        now: clock,
        currentInterval: .seconds(5)
    )
    #expect(expired == .expired)

    let denied = try interpretTokenResponse(
        Data(#"{"error":"access_denied"}"#.utf8),
        context: .devicePoll,
        now: clock,
        currentInterval: .seconds(5)
    )
    #expect(denied == .denied)

    let disabled = try interpretTokenResponse(
        Data(#"{"error":"device_flow_disabled"}"#.utf8),
        context: .devicePoll,
        now: clock,
        currentInterval: .seconds(5)
    )
    #expect(disabled == .deviceFlowDisabled)

    let secret = try interpretTokenResponse(
        Data(#"{"error":"incorrect_client_credentials"}"#.utf8),
        context: .refresh,
        now: clock,
        currentInterval: .seconds(5)
    )
    #expect(secret == .refreshRequiresClientSecret)
}

@Test func devicePollWaitsThenStoresNothingOnNetworkFailure() async throws {
    let sleep = SleepLog()
    let transport = ScriptedGitHubTransport([
        .failure(URLError(.notConnectedToInternet)),
    ])
    let api = makeAPI(transport, sleep: sleep)
    do {
        _ = try await api.poll(sampleDevice())
        Issue.record("Expected a network failure")
    } catch let error as GitHubError {
        #expect(error == .network)
    }
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(await sleep.durations == [.seconds(5)])
}

@Test func devicePollHonorsPendingSlowDownAndSuccess() async throws {
    let sleep = SleepLog()
    let transport = ScriptedGitHubTransport([
        http(400, #"{"error":"authorization_pending"}"#),
        http(400, #"{"error":"slow_down","interval":10}"#),
        http(200, #"{"access_token":"gho_test","token_type":"bearer","scope":"repo,notifications,read:user","expires_in":28800,"refresh_token":"ghr_test","refresh_token_expires_in":15897600}"#),
    ])
    let api = makeAPI(transport, sleep: sleep)
    let credential = try await api.poll(sampleDevice())
    #expect(credential.accessToken == "gho_test")
    #expect(credential.refreshToken == "ghr_test")
    #expect(credential.accessTokenExpiresAt == clock.addingTimeInterval(28800))
    #expect(await sleep.durations == [.seconds(5), .seconds(5), .seconds(10)])
    let requests = await transport.requests
    #expect(requests.count == 3)
    let fields = formFields(requests[0])
    #expect(fields["client_id"] == "Iv1.test")
    #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
    #expect(fields["client_secret"] == nil)
    #expect(requests[0].url?.host == "github.com")
}

@Test func deviceCodeRequestOmitsClientSecret() async throws {
    let transport = ScriptedGitHubTransport([
        http(200, #"{"device_code":"device","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
    ])
    let api = makeAPI(transport)
    let device = try await api.requestDeviceCode()
    #expect(device.userCode == "WDJB-MJHT")
    let fields = formFields(await transport.requests[0])
    #expect(fields.keys.sorted() == ["client_id", "scope"])
    #expect(fields["scope"] == "repo notifications read:user")
}

@Test func refreshRequestOmitsClientSecret() async throws {
    let transport = ScriptedGitHubTransport([
        http(200, #"{"access_token":"gho_new","token_type":"bearer","scope":"repo,notifications,read:user","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":15897600}"#),
    ])
    let api = makeAPI(transport)
    let refreshed = try await api.refresh(
        GitHubCredential(
            accessToken: "gho_old",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: clock.addingTimeInterval(-10),
            refreshTokenExpiresAt: nil,
            scope: "repo"
        )
    )
    #expect(refreshed.accessToken == "gho_new")
    #expect(refreshed.refreshToken == "ghr_new")
    let fields = formFields(await transport.requests[0])
    #expect(fields["grant_type"] == "refresh_token")
    #expect(fields["refresh_token"] == "ghr_old")
    #expect(fields["client_secret"] == nil)
    #expect(Set(fields.keys).isDisjoint(with: ["client_secret", "clientSecret"]))
}

@Test func repositoryPagesStayOnGitHubAndCombine() async throws {
    let transport = ScriptedGitHubTransport([
        http(
            200,
            #"[{"id":1,"name":"pulls","full_name":"octo/pulls","private":true,"owner":{"login":"octo"}}]"#,
            headers: ["Link": "<https://api.github.com/user/repos?page=2>; rel=\"next\", <https://api.github.com/user/repos?page=2>; rel=\"last\""]
        ),
        http(
            200,
            #"[{"id":2,"name":"web","full_name":"octo/web","private":false,"owner":{"login":"octo"}}]"#
        ),
    ])
    let api = makeAPI(transport)
    let repos = try await api.listRepositories(accessToken: "gho_secret")
    #expect(repos.map(\.id) == [1, 2])
    #expect(repos[0].isPrivate)
    #expect(repos[0].ownerLogin == "octo")
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.url?.host == "api.github.com" })
    #expect(requests.allSatisfy { $0.url?.absoluteString.contains("gho_secret") == false })
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer gho_secret")
}

@Test func foreignNextLinkIsNotFollowed() async throws {
    let transport = ScriptedGitHubTransport([
        http(
            200,
            #"[{"id":1,"name":"pulls","full_name":"octo/pulls","private":false,"owner":{"login":"octo"}}]"#,
            headers: ["Link": "<https://evil.example/user/repos?page=2>; rel=\"next\""]
        ),
    ])
    let api = makeAPI(transport)
    do {
        _ = try await api.listRepositories(accessToken: "gho_secret")
        Issue.record("Expected the foreign link to be rejected")
    } catch let error as GitHubError {
        #expect(error == .unexpectedLink)
    }
    #expect(await transport.requests.count == 1)
}

@Test func setupRouteFollowsCredentialAndAccount() {
    let empty = StoredAccount(
        userID: 1,
        login: "octo",
        name: nil,
        repositories: [],
        didFinishNotificationStep: false,
        wantsSystemNotifications: false
    )
    var ready = empty
    ready.repositories = [StoredRepository(id: 4, ownerLogin: "octo", name: "pulls", isPrivate: true)]
    ready.didFinishNotificationStep = true
    var notifications = ready
    notifications.didFinishNotificationStep = false

    #expect(setupRoute(hasCredential: false, account: nil) == .connect)
    #expect(setupRoute(hasCredential: true, account: nil) == .repositories)
    #expect(setupRoute(hasCredential: true, account: empty) == .repositories)
    #expect(setupRoute(hasCredential: true, account: notifications) == .notifications)
    #expect(setupRoute(hasCredential: true, account: ready) == .ready)
}

@Test @MainActor func networkFailureKeepsCredentialAndUnauthorizedClearsIt() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let kept = InMemoryTokenStore()
    try kept.write(GitHubCredential(accessToken: "gho_keep", refreshToken: nil, accessTokenExpiresAt: nil, refreshTokenExpiresAt: nil, scope: "repo"))
    let keepTransport = ScriptedGitHubTransport([.failure(GitHubError.network)])
    let (keepSession, _, _) = makeSession(transport: keepTransport, store: kept, defaults: defaults)
    await keepSession.restore()
    #expect(try kept.read()?.accessToken == "gho_keep")
    #expect(keepSession.phase == .signedIn)
    #expect(keepSession.isOffline)

    let rejected = InMemoryTokenStore()
    try rejected.write(GitHubCredential(accessToken: "gho_old", refreshToken: nil, accessTokenExpiresAt: nil, refreshTokenExpiresAt: nil, scope: "repo"))
    let rejectTransport = ScriptedGitHubTransport([
        http(401, #"{"message":"Bad credentials"}"#),
    ])
    let (rejectSession, _, _) = makeSession(transport: rejectTransport, store: rejected, defaults: defaults)
    await rejectSession.restore()
    #expect(try rejected.read() == nil)
    #expect(rejectSession.phase == .signedOut)
}

@Test @MainActor func expiredTokenRefreshesWithoutClientSecret() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = InMemoryTokenStore()
    try store.write(
        GitHubCredential(
            accessToken: "gho_old",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: clock.addingTimeInterval(-30),
            refreshTokenExpiresAt: clock.addingTimeInterval(10_000),
            scope: "repo"
        )
    )
    let transport = ScriptedGitHubTransport([
        http(200, #"{"access_token":"gho_new","token_type":"bearer","scope":"repo,notifications,read:user","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":15897600}"#),
        http(200, #"{"id":7,"login":"octo","name":"Octo"}"#),
    ])
    let (session, _, _) = makeSession(transport: transport, store: store, defaults: defaults)
    await session.restore()
    #expect(session.user?.login == "octo")
    #expect(try store.read()?.accessToken == "gho_new")
    #expect(try store.read()?.refreshToken == "ghr_new")
    let refreshFields = formFields(await transport.requests[0])
    #expect(refreshFields["client_secret"] == nil)
    #expect(refreshFields["grant_type"] == "refresh_token")
    #expect(await transport.requests[1].url?.path == "/user")
}

@Test @MainActor func signOutDeletesCredentialAndKeepsAllowlist() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = InMemoryTokenStore()
    try store.write(GitHubCredential(accessToken: "gho_live", refreshToken: nil, accessTokenExpiresAt: nil, refreshTokenExpiresAt: nil, scope: "repo"))
    let (session, _, _) = makeSession(transport: ScriptedGitHubTransport([]), store: store, defaults: defaults)
    session.adopt(GitHubUser(id: 7, login: "octo", name: nil))
    session.saveRepositories([StoredRepository(id: 4, ownerLogin: "octo", name: "pulls", isPrivate: true)])
    session.signOut()
    #expect(try store.read() == nil)
    #expect(session.phase == .signedOut)
    let saved = AccountStore(defaults: defaults).account(for: 7)
    #expect(saved?.repositories.map(\.id) == [4])
    let data = defaults.data(forKey: AccountStore.storageKey) ?? Data()
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("gho_live"))
    #expect(!json.contains("accessToken"))
}

@Test @MainActor func insufficientScopeDoesNotStoreToken() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = InMemoryTokenStore()
    let sleep = SleepLog()
    let transport = ScriptedGitHubTransport([
        http(200, #"{"access_token":"gho_narrow","token_type":"bearer","scope":"read:user"}"#),
    ])
    let session = SessionController(
        api: makeAPI(transport, sleep: sleep),
        configuration: GitHubClientConfiguration(clientID: "Iv1.test", ignoredClientSecret: false),
        tokenStore: store,
        accountStore: AccountStore(defaults: defaults),
        authorizer: RecordingAuthorizer()
    )
    do {
        _ = try await session.finishDeviceAuthorization(sampleDevice())
        Issue.record("Expected insufficient scope")
    } catch let error as GitHubError {
        #expect(error == .insufficientScope)
    }
    #expect(try store.read() == nil)
}

@Test @MainActor func skipDoesNotRequestSystemNotificationPermission() async {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let authorizer = RecordingAuthorizer()
    let (session, _, _) = makeSession(
        transport: ScriptedGitHubTransport([]),
        defaults: defaults,
        authorizer: authorizer
    )
    session.adopt(GitHubUser(id: 7, login: "octo", name: nil))
    session.saveRepositories([StoredRepository(id: 4, ownerLogin: "octo", name: "pulls", isPrivate: true)])
    let model = OnboardingModel(session: session, step: .notifications)
    model.openURL = { _ in }
    model.skipNotifications()
    #expect(authorizer.callCount == 0)
    #expect(session.account?.didFinishNotificationStep == true)
    #expect(session.account?.wantsSystemNotifications == false)
}

@Test @MainActor func enableNotificationsRequestsPermissionOnce() async {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let authorizer = RecordingAuthorizer()
    authorizer.result = false
    let (session, _, _) = makeSession(
        transport: ScriptedGitHubTransport([]),
        defaults: defaults,
        authorizer: authorizer
    )
    session.adopt(GitHubUser(id: 7, login: "octo", name: nil))
    session.saveRepositories([StoredRepository(id: 4, ownerLogin: "octo", name: "pulls", isPrivate: true)])
    let model = OnboardingModel(session: session, step: .notifications)
    model.openURL = { _ in }
    await model.enableNotifications()
    #expect(authorizer.callCount == 1)
    #expect(model.notificationDenied)
    #expect(session.account?.wantsSystemNotifications == false)
    #expect(session.account?.didFinishNotificationStep == true)
    model.continueAfterDenial()
    #expect(authorizer.callCount == 1)
}

@Test @MainActor func refreshWithoutClientSecretKeepsAWorkingTokenAndDropsADeadOne() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let expired = GitHubCredential(
        accessToken: "gho_old",
        refreshToken: "ghr_old",
        accessTokenExpiresAt: clock.addingTimeInterval(-30),
        refreshTokenExpiresAt: clock.addingTimeInterval(10_000),
        scope: "repo"
    )

    let kept = InMemoryTokenStore()
    try kept.write(expired)
    let keepTransport = ScriptedGitHubTransport([
        http(400, #"{"error":"incorrect_client_credentials"}"#),
        http(200, #"{"id":7,"login":"octo","name":"Octo"}"#),
    ])
    let (keepSession, _, _) = makeSession(transport: keepTransport, store: kept, defaults: defaults)
    await keepSession.restore()
    #expect(keepSession.phase == .signedIn)
    #expect(try kept.read()?.accessToken == "gho_old")
    #expect(keepSession.statusMessage?.contains("client secret") == true)
    #expect(formFields(await keepTransport.requests[0])["client_secret"] == nil)

    let dropped = InMemoryTokenStore()
    try dropped.write(expired)
    let dropTransport = ScriptedGitHubTransport([
        http(400, #"{"error":"incorrect_client_credentials"}"#),
        http(401, #"{"message":"Bad credentials"}"#),
    ])
    let (dropSession, _, _) = makeSession(transport: dropTransport, store: dropped, defaults: defaults)
    await dropSession.restore()
    #expect(dropSession.phase == .signedOut)
    #expect(try dropped.read() == nil)
    #expect(dropSession.statusMessage?.contains("client secret") == true)
}

@Test func pastedAccessTokenRejectsExtraText() {
    #expect(AccessTokenPaste.value(from: "  ghp_exampletoken  ") == "ghp_exampletoken")
    #expect(AccessTokenPaste.value(from: "github_pat_example") == "github_pat_example")
    #expect(AccessTokenPaste.value(from: "ghp_token and some notes") == nil)
    #expect(AccessTokenPaste.value(from: "https://github.com/token") == nil)
    #expect(AccessTokenPaste.value(from: "   ") == nil)
}

@Test @MainActor func pastedAccessTokenReplacesTheSessionWithoutARefreshToken() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = InMemoryTokenStore()
    try store.write(GitHubCredential(accessToken: "gho_old", refreshToken: "ghr_old", accessTokenExpiresAt: nil, refreshTokenExpiresAt: nil, scope: "repo"))
    let transport = ScriptedGitHubTransport([
        http(200, #"{"id":7,"login":"octo","name":"Octo"}"#, headers: ["X-OAuth-Scopes": "repo, read:user"]),
    ])
    let (session, _, _) = makeSession(transport: transport, store: store, defaults: defaults)
    try await session.signIn(withPastedAccessToken: "ghp_exampletoken")
    let saved = try store.read()
    #expect(saved?.accessToken == "ghp_exampletoken")
    #expect(saved?.refreshToken == nil)
    #expect(saved?.scope == "repo, read:user")
    #expect(session.user?.login == "octo")
    #expect(session.phase == .signedIn)
    let authorization = await transport.requests[0].value(forHTTPHeaderField: "Authorization")
    #expect(authorization == "Bearer ghp_exampletoken")
    #expect(await transport.requests[0].url?.host == "api.github.com")
    let data = defaults.data(forKey: AccountStore.storageKey) ?? Data()
    #expect(!String(decoding: data, as: UTF8.self).contains("ghp_exampletoken"))
}

@Test @MainActor func pastedAccessTokenKeepsTheCurrentSessionWhenRejected() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = InMemoryTokenStore()
    let existing = GitHubCredential(accessToken: "gho_old", refreshToken: nil, accessTokenExpiresAt: nil, refreshTokenExpiresAt: nil, scope: "repo")
    try store.write(existing)
    let narrow = ScriptedGitHubTransport([
        http(200, #"{"id":7,"login":"octo","name":"Octo"}"#, headers: ["X-OAuth-Scopes": "read:user"]),
    ])
    let (narrowSession, _, _) = makeSession(transport: narrow, store: store, defaults: defaults)
    narrowSession.adopt(GitHubUser(id: 3, login: "kept", name: nil))
    await #expect(throws: GitHubError.insufficientScope) {
        try await narrowSession.signIn(withPastedAccessToken: "ghp_narrow")
    }
    #expect(try store.read() == existing)
    #expect(narrowSession.user?.login == "kept")

    let rejected = ScriptedGitHubTransport([
        http(401, #"{"message":"Bad credentials"}"#),
    ])
    let (rejectedSession, _, _) = makeSession(transport: rejected, store: store, defaults: defaults)
    await #expect(throws: GitHubError.invalidAccessToken) {
        try await rejectedSession.signIn(withPastedAccessToken: "not a token")
    }
    #expect(await rejected.requests.isEmpty)
    #expect(try store.read() == existing)
}

@Test @MainActor func fineGrainedAccessTokenOmitsScopesAndIsStored() async throws {
    let (defaults, suite) = temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = InMemoryTokenStore()
    let transport = ScriptedGitHubTransport([
        http(200, #"{"id":9,"login":"octo","name":null}"#),
    ])
    let (session, _, _) = makeSession(transport: transport, store: store, defaults: defaults)
    try await session.signIn(withPastedAccessToken: "github_pat_example")
    #expect(try store.read()?.scope == "")
    #expect(session.user?.login == "octo")
}

@Test func keychainRoundTripReplacesAndDeletesCredential() throws {
    let store = KeychainTokenStore(service: "app.pulls.macos.tests.\(UUID().uuidString)")
    defer { try? store.delete() }
    let original = GitHubCredential(
        accessToken: "gho_keychain",
        refreshToken: "ghr_keychain",
        accessTokenExpiresAt: clock.addingTimeInterval(28800),
        refreshTokenExpiresAt: clock.addingTimeInterval(15897600),
        scope: "repo"
    )
    try store.write(original)
    #expect(try store.read() == original)
    var replaced = original
    replaced.accessToken = "gho_replaced"
    try store.write(replaced)
    #expect(try store.read()?.accessToken == "gho_replaced")
    try store.delete()
    #expect(try store.read() == nil)
}
