import Foundation

struct GitHubHTTPResponse: Sendable, Equatable {
    var statusCode: Int
    var data: Data
    var headerFields: [String: String]
}

protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse
}

struct URLSessionGitHubTransport: GitHubTransport {
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubError.unexpectedResponse
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let name = key as? String, let text = value as? String else { continue }
                headers[name] = text
            }
            return GitHubHTTPResponse(statusCode: http.statusCode, data: data, headerFields: headers)
        } catch let error as GitHubError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GitHubError.network
        }
    }
}

enum GitHubHosts {
    static func isOAuth(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.user == nil
    }

    static func isAPI(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.github.com"
            && url.user == nil
    }

    /// Pagination must stay on the repository list. A Link header must not receive the token elsewhere.
    static func isRepositoryPage(_ url: URL) -> Bool {
        isAPI(url) && url.path == "/user/repos"
    }

    static func canOpen(_ url: URL) -> Bool {
        isOAuth(url)
    }

    static func verificationURL(from string: String) -> URL? {
        guard let url = URL(string: string), canOpen(url) else { return nil }
        return url
    }
}

enum GitHubEndpoint {
    static let deviceCode = URL(string: "https://github.com/login/device/code")!
    static let accessToken = URL(string: "https://github.com/login/oauth/access_token")!
    static let currentUser = URL(string: "https://api.github.com/user")!

    static var repositories: URL {
        var components = URLComponents(string: "https://api.github.com/user/repos")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "full_name"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
        ]
        return components.url!
    }
}

enum GitHubForm {
    static func body(_ fields: [(String, String)]) -> Data {
        let encoded = fields.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    static func escape(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct GitHubAPI: Sendable {
    var transport: any GitHubTransport
    var clientID: String
    var now: @Sendable () -> Date
    var sleep: @Sendable (Duration) async throws -> Void

    func requestDeviceCode() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw GitHubError.missingClientID }
        let data = try await postForm(
            url: GitHubEndpoint.deviceCode,
            fields: [
                ("client_id", clientID),
                ("scope", GitHubScope.parameter),
            ]
        )
        return try interpretDeviceCode(data, now: now())
    }

    func poll(_ device: DeviceCode) async throws -> GitHubCredential {
        var interval = device.interval
        var loggedPending = false
        while true {
            try Task.checkCancellation()
            if now() >= device.expiresAt {
                throw GitHubError.authorizationExpired
            }
            try await sleep(interval)
            try Task.checkCancellation()
            if now() >= device.expiresAt {
                throw GitHubError.authorizationExpired
            }
            let data = try await postForm(
                url: GitHubEndpoint.accessToken,
                fields: [
                    ("client_id", clientID),
                    ("device_code", device.deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ]
            )
            let result = try interpretTokenResponse(
                data,
                context: .devicePoll,
                now: now(),
                currentInterval: interval
            )
            switch result {
            case .pending(let next):
                if next != interval {
                    PullsLog.github.info("Device authorization slowed down")
                } else if !loggedPending {
                    PullsLog.github.info("Device authorization pending")
                    loggedPending = true
                }
                interval = next
            case .approved(let credential):
                return credential
            case .expired:
                throw GitHubError.authorizationExpired
            case .denied:
                throw GitHubError.authorizationDenied
            case .deviceFlowDisabled:
                throw GitHubError.deviceFlowDisabled
            case .invalidClient:
                throw GitHubError.invalidClient
            case .refreshRequiresClientSecret, .badRefreshToken, .failed:
                throw GitHubError.unexpectedResponse
            }
        }
    }

    /// Device-flow refresh. GitHub requires `client_secret` unless the token came from the device flow, so this request omits it.
    func refresh(_ credential: GitHubCredential) async throws -> GitHubCredential {
        guard !clientID.isEmpty else { throw GitHubError.missingClientID }
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw GitHubError.unauthorized
        }
        let data = try await postForm(
            url: GitHubEndpoint.accessToken,
            fields: [
                ("client_id", clientID),
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
            ]
        )
        let result = try interpretTokenResponse(
            data,
            context: .refresh,
            now: now(),
            currentInterval: .seconds(5)
        )
        switch result {
        case .approved(let refreshed):
            return refreshed
        case .refreshRequiresClientSecret:
            throw GitHubError.refreshRequiresClientSecret
        case .badRefreshToken, .expired:
            throw GitHubError.unauthorized
        case .invalidClient:
            throw GitHubError.invalidClient
        case .pending, .denied, .deviceFlowDisabled, .failed:
            throw GitHubError.unexpectedResponse
        }
    }

    func currentUser(accessToken: String) async throws -> GitHubUser {
        try await profile(accessToken: accessToken).user
    }

    func profile(accessToken: String) async throws -> GitHubProfile {
        let response = try await send(url: GitHubEndpoint.currentUser, bearer: accessToken, form: nil)
        if response.statusCode == 401 {
            throw GitHubError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.unexpectedResponse
        }
        let payload = try decode(UserPayload.self, from: response.data)
        return GitHubProfile(
            user: GitHubUser(id: payload.id, login: payload.login, name: payload.name),
            oauthScopes: header(response, "X-OAuth-Scopes") ?? ""
        )
    }

    func listRepositories(accessToken: String) async throws -> [GitHubRepository] {
        var url = GitHubEndpoint.repositories
        var seen: Set<String> = []
        var pages = 0
        var all: [GitHubRepository] = []
        while true {
            pages += 1
            // A looping Link header must not look like a complete allowlist.
            if pages > 100 || !seen.insert(url.absoluteString).inserted {
                throw GitHubError.unexpectedResponse
            }
            let response = try await send(url: url, bearer: accessToken, form: nil)
            if response.statusCode == 401 {
                throw GitHubError.unauthorized
            }
            guard (200..<300).contains(response.statusCode) else {
                throw GitHubError.unexpectedResponse
            }
            let page = try decode([RepositoryPayload].self, from: response.data)
            all.append(contentsOf: page.map(\.repository))
            guard let next = try nextRepositoryPage(from: header(response, "Link")) else {
                PullsLog.github.info("Loaded \(all.count, privacy: .public) repositories")
                return all
            }
            url = next
        }
    }

    func postForm(url: URL, fields: [(String, String)]) async throws -> Data {
        let response = try await send(url: url, bearer: nil, form: fields)
        guard !response.data.isEmpty else { throw GitHubError.unexpectedResponse }
        return response.data
    }

    func send(url: URL, bearer: String?, form: [(String, String)]?) async throws -> GitHubHTTPResponse {
        let request = try makeRequest(url: url, bearer: bearer, form: form)
        do {
            return try await transport.send(request)
        } catch let error as GitHubError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GitHubError.network
        }
    }

    func makeRequest(url: URL, bearer: String?, form: [(String, String)]?) throws -> URLRequest {
        if bearer != nil {
            guard GitHubHosts.isAPI(url) else { throw GitHubError.unexpectedLink }
        } else if form != nil {
            guard GitHubHosts.isOAuth(url) else { throw GitHubError.unexpectedLink }
        }
        var request = URLRequest(url: url)
        request.httpMethod = form == nil ? "GET" : "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Pulls", forHTTPHeaderField: "User-Agent")
        if GitHubHosts.isAPI(url) {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GitHubForm.body(form)
        }
        return request
    }
}

func nextRepositoryPage(from linkHeader: String?) throws -> URL? {
    guard let linkHeader, !linkHeader.isEmpty else { return nil }
    var found: URL?
    for part in linkHeader.split(separator: ",") {
        let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let urlPiece = pieces.first, urlPiece.hasPrefix("<"), urlPiece.hasSuffix(">") else { continue }
        guard pieces.dropFirst().contains(where: { isNextRelation(String($0)) }) else { continue }
        let raw = String(urlPiece.dropFirst().dropLast())
        guard let url = URL(string: raw), GitHubHosts.isRepositoryPage(url) else {
            throw GitHubError.unexpectedLink
        }
        found = url
    }
    return found
}

/// Matches `rel="next"` exactly so a value such as `rel="nexting"` is not followed.
private func isNextRelation(_ piece: String) -> Bool {
    let trimmed = piece.trimmingCharacters(in: .whitespaces).lowercased()
    guard trimmed.hasPrefix("rel=") else { return false }
    var value = trimmed.dropFirst(4)
    if value.hasPrefix("\""), value.hasSuffix("\"") {
        value = value.dropFirst().dropLast()
    }
    return value == "next"
}

private func header(_ response: GitHubHTTPResponse, _ name: String) -> String? {
    response.headerFields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

private struct UserPayload: Decodable {
    var id: Int
    var login: String
    var name: String?
}

private struct RepositoryPayload: Decodable {
    var id: Int
    var name: String
    var fullName: String
    var isPrivate: Bool
    var owner: Owner

    var repository: GitHubRepository {
        GitHubRepository(
            id: id,
            name: name,
            fullName: fullName,
            isPrivate: isPrivate,
            ownerLogin: owner.login
        )
    }

    struct Owner: Decodable {
        var login: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case owner
        case fullName = "full_name"
        case isPrivate = "private"
    }
}

private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw GitHubError.unexpectedResponse
    }
}
