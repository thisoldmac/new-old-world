import Combine
import Foundation
import Security

/// The two agent entry points are product settings owned by NOW, not command
/// line environment belonging to a helper process.
struct MCPTransportPreferences {
    static let defaultHTTPPort: UInt16 = 5254

    enum Keys {
        static let stdioEnabled = "mcp.stdio.enabled"
        static let httpEnabled = "mcp.http.enabled"
        static let httpPort = "mcp.http.port"
        static let httpAuthMode = "mcp.http.authMode"
    }

    let defaults: UserDefaults

    var stdioStartsAutomatically: Bool {
        get {
            defaults.object(forKey: Keys.stdioEnabled) == nil
                ? true : defaults.bool(forKey: Keys.stdioEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.stdioEnabled) }
    }

    var httpStartsAutomatically: Bool {
        get { defaults.bool(forKey: Keys.httpEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.httpEnabled) }
    }

    var httpPort: UInt16 {
        get {
            let raw = defaults.integer(forKey: Keys.httpPort)
            return UInt16(exactly: raw).flatMap { $0 == 0 ? nil : $0 }
                ?? Self.defaultHTTPPort
        }
        nonmutating set { defaults.set(Int(newValue), forKey: Keys.httpPort) }
    }

    /// Missing or unrecognised stored values mean bearer: that is what every
    /// install had before modes existed.
    var httpAuthMode: MCPHTTPAuthMode {
        get {
            defaults.string(forKey: Keys.httpAuthMode)
                .flatMap(MCPHTTPAuthMode.init(rawValue:)) ?? .bearer
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Keys.httpAuthMode)
        }
    }
}

/// The editable transport preferences shown by the MCP module.
///
/// Running state remains in `AgentActivityModel`; these values answer only
/// what should happen at the next app launch and which port a future HTTP
/// listener should bind. Keeping the two models separate prevents pressing
/// Stop from silently changing launch policy.
@MainActor
final class MCPTransportSettingsModel: ObservableObject {
    @Published var stdioStartsAutomatically: Bool {
        didSet {
            preferences.stdioStartsAutomatically = stdioStartsAutomatically
        }
    }
    @Published var httpStartsAutomatically: Bool {
        didSet {
            preferences.httpStartsAutomatically = httpStartsAutomatically
        }
    }
    @Published var httpPort: UInt16 {
        didSet {
            guard httpPort != 0 else {
                httpPort = oldValue
                return
            }
            preferences.httpPort = httpPort
        }
    }
    @Published var httpAuthMode: MCPHTTPAuthMode {
        didSet { preferences.httpAuthMode = httpAuthMode }
    }

    private let preferences: MCPTransportPreferences

    init(defaults: UserDefaults) {
        let preferences = MCPTransportPreferences(defaults: defaults)
        self.preferences = preferences
        stdioStartsAutomatically = preferences.stdioStartsAutomatically
        httpStartsAutomatically = preferences.httpStartsAutomatically
        httpPort = preferences.httpPort
        httpAuthMode = preferences.httpAuthMode
    }
}

enum MCPHTTPTokenStoreError: Error, LocalizedError, Equatable {
    case noApplicationSupport
    case randomGeneration(OSStatus)
    case invalidStoredToken

    var errorDescription: String? {
        switch self {
        case .noApplicationSupport:
            return "Application Support is unavailable for the MCP token."
        case .randomGeneration(let status):
            return "A private MCP token could not be generated (\(status))."
        case .invalidStoredToken:
            return "The saved MCP token is malformed."
        }
    }
}

/// One same-user HTTP secret beside NOW's other private application data.
/// Route-family wrappers below choose distinct files so possession of an API
/// key never grants the agent-only MCP surface (or vice versa).
private struct LocalHTTPSecretStore {
    let url: URL
    let legacyURL: URL?

    static func applicationSupportDirectory(
        fileManager: FileManager
    ) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw MCPHTTPTokenStoreError.noApplicationSupport }
        return support.appendingPathComponent(
            ProductIdentity.displayName, isDirectory: true)
    }

    func loadOrCreate(fileManager: FileManager = .default) throws -> String {
        if fileManager.fileExists(atPath: url.path) {
            return try load(url)
        }
        if let legacyURL,
           fileManager.fileExists(atPath: legacyURL.path) {
            let token = try load(legacyURL)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            do {
                try fileManager.moveItem(at: legacyURL, to: url)
            } catch {
                // A same-directory rename is atomic. If the filesystem
                // refuses it, publish an atomic copy before leaving the old
                // private item in place; never rotate a live client secret.
                try Data((token + "\n").utf8).write(to: url, options: .atomic)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: url.path)
            return token
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MCPHTTPTokenStoreError.randomGeneration(status)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(token.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: url.path)
        return token
    }

    private func load(_ source: URL) throws -> String {
        let token = try String(contentsOf: source, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...512).contains(token.utf8.count) else {
            throw MCPHTTPTokenStoreError.invalidStoredToken
        }
        return token
    }
}

/// The existing bearer secret remains byte-for-byte stable for MCP clients.
/// Its neutral filename is retained because S6 already migrated live clients
/// there; changing it again would silently rotate their credential.
struct MCPHTTPTokenStore {
    private let store: LocalHTTPSecretStore

    init(url: URL? = nil, legacyURL: URL? = nil,
         fileManager: FileManager = .default) throws {
        if let url {
            store = LocalHTTPSecretStore(url: url, legacyURL: legacyURL)
        } else {
            let directory = try LocalHTTPSecretStore
                .applicationSupportDirectory(fileManager: fileManager)
            store = LocalHTTPSecretStore(
                url: directory.appendingPathComponent("now-api-key"),
                legacyURL: directory.appendingPathComponent("mcp-http-token"))
        }
    }

    func loadOrCreate(fileManager: FileManager = .default) throws -> String {
        try store.loadOrCreate(fileManager: fileManager)
    }
}

/// The developer API has a separate credential and therefore cannot be used
/// as an MCP bearer token even when both routes share one listener.
struct NOWAPIKeyStore {
    private let store: LocalHTTPSecretStore

    init(url: URL? = nil, fileManager: FileManager = .default) throws {
        if let url {
            store = LocalHTTPSecretStore(url: url, legacyURL: nil)
        } else {
            let directory = try LocalHTTPSecretStore
                .applicationSupportDirectory(fileManager: fileManager)
            store = LocalHTTPSecretStore(
                url: directory.appendingPathComponent("now-application-api-key"),
                legacyURL: nil)
        }
    }

    func loadOrCreate(fileManager: FileManager = .default) throws -> String {
        try store.loadOrCreate(fileManager: fileManager)
    }
}

struct NOWHTTPRouteCredentials: Equatable {
    let mcpBearerToken: String
    let apiKey: String

    static func load(mcp: MCPHTTPTokenStore,
                     api: NOWAPIKeyStore,
                     fileManager: FileManager = .default) throws -> Self {
        .init(mcpBearerToken: try mcp.loadOrCreate(fileManager: fileManager),
              apiKey: try api.loadOrCreate(fileManager: fileManager))
    }
}
