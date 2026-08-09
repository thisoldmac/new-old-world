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

enum ChatCredentialInteraction: Equatable, Sendable {
    /// A person initiated the operation, so Keychain may ask them to
    /// authorize this signed app.
    case allow
    /// Background discovery and page refresh must never put up system UI.
    case forbid
}

enum ChatCredentialRead: Equatable, Sendable {
    case value(Data)
    case missing
    case authorizationRequired
    case unavailable(OSStatus)

    var data: Data? {
        guard case .value(let data) = self else { return nil }
        return data
    }

    var isAvailable: Bool {
        data != nil
    }

    var string: String? {
        data.flatMap { String(data: $0, encoding: .utf8) }
    }

    var statusReason: String? {
        switch self {
        case .value, .missing:
            return nil
        case .authorizationRequired:
            return "Authorize saved credentials"
        case .unavailable(errSecMissingEntitlement):
            return "Saved credentials require a Developer-signed build"
        case .unavailable(let status):
            return "Keychain unavailable (\(status))"
        }
    }
}

protocol ChatCredentialStore: Sendable {
    func read(_ key: ChatCredentialKey, interaction: ChatCredentialInteraction)
        -> ChatCredentialRead
    func write(_ key: ChatCredentialKey, _ data: Data) throws
    func delete(_ key: ChatCredentialKey)
}

extension ChatCredentialStore {
    func readString(
        _ key: ChatCredentialKey, interaction: ChatCredentialInteraction
    ) -> ChatCredentialRead {
        switch read(key, interaction: interaction) {
        case .value(let data):
            guard String(data: data, encoding: .utf8) != nil else {
                return .unavailable(errSecDecode)
            }
            return .value(data)
        case .missing:
            return .missing
        case .authorizationRequired:
            return .authorizationRequired
        case .unavailable(let status):
            return .unavailable(status)
        }
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

    private func query(
        _ key: ChatCredentialKey, dataProtection: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
        }
        return query
    }

    func read(_ key: ChatCredentialKey, interaction: ChatCredentialInteraction)
        -> ChatCredentialRead {
        let protected = read(
            query(key, dataProtection: true), interaction: interaction)
        switch protected {
        case .missing:
            break
        case .value, .authorizationRequired, .unavailable:
            return protected
        }

        // Items written before the Data Protection migration live in the
        // login keychain. A passive refresh may use one only when its old
        // ACL already permits that without UI. The first explicit access
        // moves it into this app's signed access group and retires the old
        // copy after the new write is safely present.
        let legacy = read(
            query(key, dataProtection: false), interaction: interaction)
        guard case .value(let data) = legacy,
              interaction == .allow else { return legacy }
        do {
            try writeDataProtection(key, data)
            SecItemDelete(query(key, dataProtection: false) as CFDictionary)
        } catch {
            // The readable legacy value is still intact. Migration failure
            // must not turn a usable credential into apparent absence.
        }
        return .value(data)
    }

    private func read(
        _ base: [String: Any], interaction: ChatCredentialInteraction
    ) -> ChatCredentialRead {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if interaction == .forbid {
            query[kSecUseAuthenticationUI as String] =
                kSecUseAuthenticationUIFail
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                return .unavailable(errSecDecode)
            }
            return .value(data)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .authorizationRequired
        default:
            return .unavailable(status)
        }
    }

    func write(_ key: ChatCredentialKey, _ data: Data) throws {
        try writeDataProtection(key, data)
        // A successful new write owns the value. Best-effort retirement of
        // the legacy duplicate cannot jeopardize it or put up UI from an
        // OAuth refresh running behind a page update.
        var legacy = query(key, dataProtection: false)
        legacy[kSecUseAuthenticationUI as String] =
            kSecUseAuthenticationUIFail
        SecItemDelete(legacy as CFDictionary)
    }

    private func writeDataProtection(
        _ key: ChatCredentialKey, _ data: Data
    ) throws {
        var add = query(key, dataProtection: true)
        add[kSecValueData as String] = data
        // This Mac only in the product sense: it never synchronizes through
        // iCloud, and it is readable only while this Mac is unlocked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                query(key, dataProtection: true) as CFDictionary,
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
        SecItemDelete(query(key, dataProtection: true) as CFDictionary)
        SecItemDelete(query(key, dataProtection: false) as CFDictionary)
    }
}

/// A single passive operation's view of Keychain. It performs one
/// noninteractive read per credential, then lets provider status and model
/// discovery reuse those outcomes without re-entering Keychain. Writes still
/// flow to the source so an OAuth refresh is not stranded in the snapshot.
final class SnapshotChatCredentialStore: ChatCredentialStore,
    @unchecked Sendable {
    private let lock = NSLock()
    private let source: ChatCredentialStore
    private var values: [ChatCredentialKey: ChatCredentialRead]

    init(
        source: ChatCredentialStore, interaction: ChatCredentialInteraction
    ) {
        self.source = source
        values = Dictionary(uniqueKeysWithValues:
            ChatCredentialKey.allCases.map {
                ($0, source.read($0, interaction: interaction))
            })
    }

    func read(_ key: ChatCredentialKey, interaction: ChatCredentialInteraction)
        -> ChatCredentialRead {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? .missing
    }

    func write(_ key: ChatCredentialKey, _ data: Data) throws {
        try source.write(key, data)
        lock.lock()
        defer { lock.unlock() }
        values[key] = .value(data)
    }

    func delete(_ key: ChatCredentialKey) {
        source.delete(key)
        lock.lock()
        defer { lock.unlock() }
        values[key] = .missing
    }
}

/// The test seam, and nothing more.
final class InMemoryChatCredentialStore: ChatCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ChatCredentialKey: Data] = [:]

    func read(_ key: ChatCredentialKey, interaction: ChatCredentialInteraction)
        -> ChatCredentialRead {
        lock.lock()
        defer { lock.unlock() }
        return values[key].map(ChatCredentialRead.value) ?? .missing
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
