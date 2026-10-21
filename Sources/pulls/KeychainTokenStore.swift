import Foundation
import Security

protocol TokenStoring: Sendable {
    func read() throws -> GitHubCredential?
    func write(_ credential: GitHubCredential) throws
    func delete() throws
}

struct KeychainTokenStore: TokenStoring, Sendable {
    var service: String = AppIdentity.bundleID
    var account: String = "github.oauth.credential"

    func read() throws -> GitHubCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw GitHubError.keychain
        }
        do {
            return try decoder().decode(GitHubCredential.self, from: data)
        } catch {
            throw GitHubError.keychain
        }
    }

    func write(_ credential: GitHubCredential) throws {
        let data: Data
        do {
            data = try encoder().encode(credential)
        } catch {
            throw GitHubError.keychain
        }
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else if existing == errSecItemNotFound {
            var add = query
            for (key, value) in attributes {
                add[key] = value
            }
            status = SecItemAdd(add as CFDictionary, nil)
        } else {
            throw GitHubError.keychain
        }
        guard status == errSecSuccess else { throw GitHubError.keychain }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubError.keychain
        }
    }

    /// The login keychain accepts this ad-hoc signed app. The token is not synced and stays on this Mac.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
