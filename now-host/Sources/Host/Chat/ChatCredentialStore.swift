import Foundation
import Security

/* The first Keychain code in this repository, kept deliberately tiny:
   generic passwords under one service name, one account per credential
   kind, values as opaque Data. Everything above this file talks to the
   protocol; tests use the in-memory store and the Keychain
   implementation stays thin enough to read in one sitting. */

enum ChatCredentialKey: String, CaseIterable {
    case anthropicAPIKey = "anthropic.api-key"
    /// A JSON ChatOAuthTokens blob, not a bare token.
    case anthropicOAuth = "anthropic.oauth"
    case openAIAPIKey = "openai.api-key"
}

protocol ChatCredentialStore: Sendable {
    func read(_ key: ChatCredentialKey) -> Data?
    func write(_ key: ChatCredentialKey, _ data: Data) throws
    func delete(_ key: ChatCredentialKey)
}

extension ChatCredentialStore {
    func readString(_ key: ChatCredentialKey) -> String? {
        read(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func writeString(_ key: ChatCredentialKey, _ value: String) throws {
        try write(key, Data(value.utf8))
    }
}

/// The Anthropic subscription sign-in's stored state. `expiresAt` is
/// absolute so a relaunch can tell a live token from a stale one.
struct ChatOAuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool {
        // A minute of slack: a token that expires mid-request costs a
        // retry; refreshing one minute early costs nothing.
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

struct KeychainChatCredentialStore: ChatCredentialStore {
    /// Beside ProductIdentity's other identifiers; chat credentials
    /// are their own service so clearing them can never touch anything
    /// else this app might one day keep.
    static let service = "dev.newoldworld.now.chat"

    private func query(_ key: ChatCredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    func read(_ key: ChatCredentialKey) -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ key: ChatCredentialKey, _ data: Data) throws {
        var add = query(key)
        add[kSecValueData as String] = data
        // Never synchronizable: an API key belongs to this Mac, not to
        // every device on the account.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                query(key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else {
                throw ChatFault.refuse(
                    code: "no-credentials",
                    reason: "Keychain update failed (\(update))")
            }
            return
        }
        guard status == errSecSuccess else {
            throw ChatFault.refuse(
                code: "no-credentials",
                reason: "Keychain write failed (\(status))")
        }
    }

    func delete(_ key: ChatCredentialKey) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

/// The test seam, and nothing more.
final class InMemoryChatCredentialStore: ChatCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ChatCredentialKey: Data] = [:]

    func read(_ key: ChatCredentialKey) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func write(_ key: ChatCredentialKey, _ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }

    func delete(_ key: ChatCredentialKey) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}
