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

/// A same-user bearer secret beside NOW's other private application data.
/// It is generated only when a person first starts HTTP, written atomically,
/// and mode 0600. The MCP page can copy it but never renders it as ordinary
/// text or writes it to the log.
struct MCPHTTPTokenStore {
    let url: URL

    init(url: URL? = nil, fileManager: FileManager = .default) throws {
        if let url {
            self.url = url
            return
        }
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw MCPHTTPTokenStoreError.noApplicationSupport }
        self.url = support
            .appendingPathComponent(ProductIdentity.displayName,
                                    isDirectory: true)
            .appendingPathComponent("mcp-http-token", isDirectory: false)
    }

    func loadOrCreate(fileManager: FileManager = .default) throws -> String {
        if fileManager.fileExists(atPath: url.path) {
            let token = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (32...512).contains(token.utf8.count) else {
                throw MCPHTTPTokenStoreError.invalidStoredToken
            }
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
}
