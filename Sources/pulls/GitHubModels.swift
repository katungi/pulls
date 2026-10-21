import Foundation

struct GitHubUser: Equatable, Sendable {
    var id: Int
    var login: String
    var name: String?
}

struct GitHubRepository: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String
    var fullName: String
    var isPrivate: Bool
    var ownerLogin: String
}

struct GitHubCredential: Equatable, Sendable, Codable {
    var accessToken: String
    var refreshToken: String?
    var accessTokenExpiresAt: Date?
    var refreshTokenExpiresAt: Date?
    var scope: String

    /// Refresh a minute early so a request does not fail as the token expires.
    func needsRefresh(at date: Date) -> Bool {
        guard let accessTokenExpiresAt else { return false }
        return accessTokenExpiresAt.timeIntervalSince(date) <= 60
    }

    func refreshTokenIsUsable(at date: Date) -> Bool {
        guard let refreshToken, !refreshToken.isEmpty else { return false }
        guard let refreshTokenExpiresAt else { return true }
        return refreshTokenExpiresAt > date
    }
}

extension GitHubCredential: CustomStringConvertible {
    /// Keeps tokens out of logs if a credential is printed.
    var description: String {
        "GitHubCredential(scope: \(scope))"
    }
}

struct DeviceCode: Equatable, Sendable {
    var deviceCode: String
    var userCode: String
    var verificationURL: URL
    var expiresAt: Date
    var interval: Duration
}

enum GitHubError: Error, Equatable, Sendable {
    case missingClientID
    case deviceFlowDisabled
    case authorizationExpired
    case authorizationDenied
    case invalidClient
    case insufficientScope
    case unauthorized
    case refreshRequiresClientSecret
    case network
    case unexpectedResponse
    case unexpectedLink
    case keychain
    case invalidAccessToken

    var userMessage: String {
        switch self {
        case .missingClientID:
            "Add your GitHub OAuth client ID before connecting."
        case .deviceFlowDisabled:
            "Device flow is turned off for this OAuth App. Enable it in the app's GitHub settings, then try again."
        case .authorizationExpired:
            "The code expired. Request a new one."
        case .authorizationDenied:
            "Authorization was cancelled on GitHub."
        case .invalidClient:
            "GitHub rejected the client ID."
        case .insufficientScope:
            "GitHub did not grant repository access. Connect again and accept the repository permission."
        case .unauthorized:
            "GitHub rejected the saved sign-in. Connect again."
        case .refreshRequiresClientSecret:
            "GitHub refused to refresh this sign-in without a client secret. Pulls will not store a client secret. Connect again."
        case .network:
            "The network request failed. Check your connection and try again."
        case .unexpectedResponse, .unexpectedLink:
            "GitHub returned a response Pulls could not use."
        case .keychain:
            "The Keychain could not store the GitHub token."
        case .invalidAccessToken:
            "Paste one GitHub personal access token, with no extra text."
        }
    }
}

struct GitHubProfile: Equatable, Sendable {
    var user: GitHubUser
    /// Value of `X-OAuth-Scopes`. Fine-grained personal access tokens leave this empty.
    var oauthScopes: String
}

enum AccessTokenPaste {
    /// One token, nothing else. The caller stores the result and does not log it.
    static func value(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }
}

enum GitHubAccessCopy {
    static let scopeSummary = """
    Pulls asks GitHub for three permissions:

    Repositories (repo). This is the only OAuth App permission that can list private repositories. GitHub defines it as full control of repository contents, issues, and pull requests, including some organization resources. Pulls uses it to list repositories you can access. It does not push code or edit repositories.

    Notifications (notifications). This reads your notification inbox. GitHub also allows marking notifications read and changing subscriptions with this permission. Pulls does not change subscriptions.

    Profile (read:user). This reads your login so Pulls can show which account is connected.
    """

    static let allowlistSummary = """
    Choose the repositories Pulls is allowed to look at. This is an allowlist, not a subscription to every event. Future sync will notify you only about pull requests that involve you.
    """

    static let notificationSummary = """
    Enable Notifications is recommended. Pulls will use macOS notifications for pull requests that involve you. That delivery is not active yet.

    Skip leaves system notifications off. The menu's test banners are drawn by Pulls and do not ask macOS for permission.
    """

    static let missingClientID = """
    Add your OAuth client ID before connecting. Copy Config/GitHubOAuth.example.json to Config/GitHubOAuth.json, set clientId, and rebuild. The client ID can also come from PULLS_GITHUB_CLIENT_ID or ~/Library/Application Support/app.pulls.macos/github-oauth.json. Do not put a client secret in the file.
    """

    static let ignoredClientSecret = """
    The config file contains a client secret. Pulls ignores it and will not send it. Remove clientSecret from the file.
    """

    static let personalAccessTokenSummary = """
    A personal access token can list organization repositories this OAuth app has not been approved to see. Create a classic token with the repo scope under GitHub Settings → Developer settings → Personal access tokens. Pulls stores it in the Keychain on this Mac and uses it instead of the current sign-in.
    """
}
