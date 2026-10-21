import Foundation

enum TokenRequestContext: Sendable {
    case devicePoll
    case refresh
}

enum TokenEndpointResult: Equatable, Sendable {
    case pending(Duration)
    case approved(GitHubCredential)
    case expired
    case denied
    case deviceFlowDisabled
    case invalidClient
    case refreshRequiresClientSecret
    case badRefreshToken
    case failed
}

/// A zero or missing interval would poll immediately, which the device flow forbids.
func pollingInterval(seconds: Int?) -> Duration {
    guard let seconds, seconds >= 1 else { return .seconds(5) }
    return .seconds(seconds)
}

/// GitHub's `slow_down` error includes the new interval. When it does not, add five seconds.
func intervalAfterSlowDown(current: Duration, hintedSeconds: Int?) -> Duration {
    if let hintedSeconds, hintedSeconds >= 1 {
        return .seconds(hintedSeconds)
    }
    return .seconds(wholeSeconds(current) + 5)
}

func wholeSeconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds)
}

func interpretDeviceCode(_ data: Data, now: Date) throws -> DeviceCode {
    let payload = try decode(DeviceCodePayload.self, from: data)
    if let error = payload.error {
        switch error {
        case "device_flow_disabled":
            throw GitHubError.deviceFlowDisabled
        case "incorrect_client_credentials":
            throw GitHubError.invalidClient
        default:
            throw GitHubError.unexpectedResponse
        }
    }
    guard
        let deviceCode = payload.deviceCode,
        let userCode = payload.userCode,
        let verification = payload.verificationURI,
        let url = GitHubHosts.verificationURL(from: verification),
        let expiresIn = payload.expiresIn
    else {
        throw GitHubError.unexpectedResponse
    }
    return DeviceCode(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationURL: url,
        expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
        interval: pollingInterval(seconds: payload.interval)
    )
}

func interpretTokenResponse(
    _ data: Data,
    context: TokenRequestContext,
    now: Date,
    currentInterval: Duration
) throws -> TokenEndpointResult {
    let payload = try decode(TokenEndpointPayload.self, from: data)
    if let error = payload.error {
        switch error {
        case "authorization_pending":
            return .pending(currentInterval)
        case "slow_down":
            return .pending(intervalAfterSlowDown(current: currentInterval, hintedSeconds: payload.interval))
        case "expired_token", "token_expired":
            // GitHub's table says `expired_token`; the description says `token_expired`.
            return .expired
        case "access_denied":
            return .denied
        case "device_flow_disabled":
            return .deviceFlowDisabled
        case "incorrect_client_credentials":
            // On refresh, this is GitHub asking for a client secret. Do not send one.
            return context == .refresh ? .refreshRequiresClientSecret : .invalidClient
        case "bad_refresh_token":
            return .badRefreshToken
        case "incorrect_device_code":
            return .expired
        default:
            return .failed
        }
    }
    guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
        return .failed
    }
    let refreshToken = payload.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
    return .approved(
        GitHubCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: payload.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: payload.refreshTokenExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            scope: payload.scope ?? ""
        )
    )
}

private struct DeviceCodePayload: Decodable {
    var deviceCode: String?
    var userCode: String?
    var verificationURI: String?
    var expiresIn: Int?
    var interval: Int?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
        case error
    }
}

private struct TokenEndpointPayload: Decodable {
    var accessToken: String?
    var scope: String?
    var expiresIn: Int?
    var refreshToken: String?
    var refreshTokenExpiresIn: Int?
    var error: String?
    var interval: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
        case interval
    }
}

private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    guard !data.isEmpty else { throw GitHubError.unexpectedResponse }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw GitHubError.unexpectedResponse
    }
}
