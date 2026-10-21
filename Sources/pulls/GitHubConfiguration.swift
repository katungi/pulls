import Foundation

enum AppIdentity {
    /// Matches CFBundleIdentifier. Keychain items and preferences use the same name.
    static let bundleID = "app.pulls.macos"
}

enum GitHubScope {
    /// `repo` is intentionally broad: GitHub has no read-only scope for private repositories.
    static let requested = ["repo", "notifications", "read:user"]

    static var parameter: String {
        requested.joined(separator: " ")
    }

    static func granted(from scope: String) -> Set<String> {
        Set(
            scope
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { $0.lowercased() }
        )
    }

    static func allowsRepositoryList(_ scope: String) -> Bool {
        granted(from: scope).contains("repo")
    }
}

struct GitHubClientConfiguration: Equatable, Sendable {
    var clientID: String?
    var ignoredClientSecret: Bool
}

enum GitHubClientConfigurationLoader {
    static let environmentKey = "PULLS_GITHUB_CLIENT_ID"

    /// Environment, then the bundled file, then Application Support. Empty IDs are skipped.
    static func resolve(
        environment: [String: String],
        bundledData: Data?,
        applicationSupportData: Data?
    ) -> GitHubClientConfiguration {
        let bundled = bundledData.flatMap(parse)
        let support = applicationSupportData.flatMap(parse)
        let ignored = (bundled?.ignoredClientSecret ?? false) || (support?.ignoredClientSecret ?? false)
        if let clientID = normalize(environment[environmentKey]) {
            return GitHubClientConfiguration(clientID: clientID, ignoredClientSecret: ignored)
        }
        if let clientID = bundled?.clientID {
            return GitHubClientConfiguration(clientID: clientID, ignoredClientSecret: ignored)
        }
        if let clientID = support?.clientID {
            return GitHubClientConfiguration(clientID: clientID, ignoredClientSecret: ignored)
        }
        return GitHubClientConfiguration(clientID: nil, ignoredClientSecret: ignored)
    }

    static func loadFromDisk(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> GitHubClientConfiguration {
        let bundled = bundle.url(forResource: "GitHubOAuth", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        let support = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
            .appendingPathComponent("github-oauth.json", isDirectory: false)
        let supportData = support.flatMap { try? Data(contentsOf: $0) }
        return resolve(
            environment: environment,
            bundledData: bundled,
            applicationSupportData: supportData
        )
    }

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Detects a pasted secret without keeping the value.
    static func parse(_ data: Data) -> GitHubOAuthFile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let ignored = object["clientSecret"] != nil || object["client_secret"] != nil
        let raw = (object["clientId"] as? String) ?? (object["client_id"] as? String)
        return GitHubOAuthFile(clientID: normalize(raw), ignoredClientSecret: ignored)
    }
}

struct GitHubOAuthFile: Equatable, Sendable {
    var clientID: String?
    var ignoredClientSecret: Bool
}
