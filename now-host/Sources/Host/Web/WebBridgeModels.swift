import Foundation

enum WebBridgeLifecycle: Equatable {
    case unavailable(String)
    case stopped
    case starting
    case ready(address: String, port: Int)
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }
}

enum WebBrowserProfile: String, CaseIterable, Identifiable, Codable {
    case classilla
    case macweb
    case generic68k

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classilla: return "Classilla"
        case .macweb: return "MacWeb"
        case .generic68k: return "Generic 68K"
        }
    }
}

enum WebRenderingLens: String, CaseIterable, Identifiable, Codable {
    case compatible
    case reader
    case ai

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compatible: return "Compatible Page"
        case .reader: return "Reader"
        case .ai: return "AI Layout"
        }
    }
}

enum WebFetchEngine: String, CaseIterable, Identifiable, Codable {
    case staticHTML = "static"
    case playwright

    var id: String { rawValue }
    var title: String {
        switch self {
        case .staticHTML: return "Static HTML"
        case .playwright: return "Playwright / Chromium"
        }
    }
}

struct WebBridgeConfiguration: Encodable, Equatable {
    let host: String
    let port: Int
    let engine: String
    let settleMilliseconds: Int
    let allowedClients: [String]
    let allowPrivateDestinations: Bool
    let aiPlanCommand: [String]

    enum CodingKeys: String, CodingKey {
        case host, port, engine
        case settleMilliseconds = "settle_ms"
        case allowedClients = "allowed_clients"
        case allowPrivateDestinations = "allow_private_destinations"
        case aiPlanCommand = "ai_plan_command"
    }
}

@MainActor
final class WebBridgeModel: ObservableObject {
    @Published private(set) var lifecycle: WebBridgeLifecycle
    @Published private(set) var recentOutput: [String] = []
    @Published var helperRoot: String { didSet { save(helperRoot, key: .root) } }
    @Published var bindAddress: String { didSet { save(bindAddress, key: .host) } }
    @Published var port: Int { didSet { defaults.set(port, forKey: Key.port.rawValue) } }
    @Published var allowedClient: String {
        didSet { save(allowedClient, key: .allowedClient) }
    }
    @Published var profile: WebBrowserProfile {
        didSet { save(profile.rawValue, key: .profile) }
    }
    @Published var lens: WebRenderingLens {
        didSet { save(lens.rawValue, key: .lens) }
    }
    @Published var engine: WebFetchEngine {
        didSet { save(engine.rawValue, key: .engine) }
    }
    @Published var handlersEnabled: Bool {
        didSet { defaults.set(handlersEnabled, forKey: Key.handlers.rawValue) }
    }
    @Published var allowPrivateDestinations: Bool {
        didSet {
            defaults.set(allowPrivateDestinations,
                         forKey: Key.allowPrivate.rawValue)
        }
    }
    @Published var aiPlannerExecutable: String {
        didSet { save(aiPlannerExecutable, key: .aiPlanner) }
    }

    private let defaults: UserDefaults
    private var outputRemainder = ""
    private var temporaryConfigURL: URL?
    private lazy var process: WebBridgeProcessController = {
        let controller = WebBridgeProcessController()
        controller.output = { [weak self] in self?.acceptOutput($0) }
        controller.terminated = { [weak self] status, requested in
            guard let self else { return }
            self.removeTemporaryConfiguration()
            if requested {
                self.lifecycle = .stopped
            } else if status == 0 {
                self.lifecycle = .stopped
            } else {
                self.lifecycle = .failed("Helper exited with status \(status).")
            }
        }
        return controller
    }()

    private enum Key: String {
        case root = "web.helperRoot"
        case host = "web.bindAddress"
        case port = "web.port"
        case allowedClient = "web.allowedClient"
        case profile = "web.profile"
        case lens = "web.lens"
        case engine = "web.engine"
        case handlers = "web.handlers"
        case allowPrivate = "web.allowPrivateDestinations"
        case aiPlanner = "web.aiPlannerExecutable"
    }

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: ProductIdentity.preferencesSuite) ?? .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        let initialRoot = defaults.string(forKey: Key.root.rawValue)
            ?? Self.defaultHelperRoot(environment: environment)
        helperRoot = initialRoot
        bindAddress = defaults.string(forKey: Key.host.rawValue) ?? "127.0.0.1"
        let storedPort = defaults.integer(forKey: Key.port.rawValue)
        port = storedPort == 0 ? 5180 : storedPort
        allowedClient = defaults.string(forKey: Key.allowedClient.rawValue) ?? ""
        profile = WebBrowserProfile(rawValue:
            defaults.string(forKey: Key.profile.rawValue) ?? "") ?? .classilla
        lens = WebRenderingLens(rawValue:
            defaults.string(forKey: Key.lens.rawValue) ?? "") ?? .compatible
        engine = WebFetchEngine(rawValue:
            defaults.string(forKey: Key.engine.rawValue) ?? "") ?? .staticHTML
        handlersEnabled = defaults.object(forKey: Key.handlers.rawValue) == nil
            ? true : defaults.bool(forKey: Key.handlers.rawValue)
        allowPrivateDestinations = defaults.bool(
            forKey: Key.allowPrivate.rawValue)
        aiPlannerExecutable = defaults.string(
            forKey: Key.aiPlanner.rawValue) ?? ""
        lifecycle = Self.helperExists(at: initialRoot)
            ? .stopped
            : .unavailable("Choose the folder containing the NOW Web helper.")
    }

    var configuration: WebBridgeConfiguration {
        WebBridgeConfiguration(
            host: bindAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            engine: engine.rawValue,
            settleMilliseconds: 3000,
            allowedClients: allowedClient.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                ? [] : [allowedClient.trimmingCharacters(in: .whitespacesAndNewlines)],
            allowPrivateDestinations: allowPrivateDestinations,
            aiPlanCommand: aiPlannerExecutable.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                ? [] : [aiPlannerExecutable.trimmingCharacters(
                    in: .whitespacesAndNewlines)])
    }

    var canStart: Bool {
        guard !process.isRunning, (1...65535).contains(port),
              Self.helperExists(at: helperRoot), !bindAddress.isEmpty else {
            return false
        }
        return true
    }

    var proxyInstruction: String {
        if Self.isLoopback(bindAddress) {
            return "Host loopback is not reachable from the classic Mac. "
                + "Choose this Mac's LAN address before starting Direct mode."
        }
        return "Set the classic browser's HTTP proxy to \(bindAddress):\(port)."
    }

    var startURL: String {
        let encoded = "https%3A%2F%2Fexample.com"
        return "http://\(bindAddress):\(port)/go?u=\(encoded)"
            + "&profile=\(profile.rawValue)&lens=\(lens.rawValue)"
            + "&handlers=\(handlersEnabled ? "on" : "off")"
    }

    var exposesLANWithoutPeerRestriction: Bool {
        !Self.isLoopback(bindAddress)
            && allowedClient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func usePrimaryLANAddress() {
        if let address = HostAddressDetector.primaryIPv4() {
            bindAddress = address
        }
    }

    func start() {
        guard !process.isRunning else { return }
        guard canStart else {
            lifecycle = .failed("The helper path, bind address or port is invalid.")
            return
        }
        do {
            let configURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("now-web-\(ProcessInfo.processInfo.processIdentifier).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configURL,
                                                     options: .atomic)
            temporaryConfigURL = configURL
            recentOutput = []
            outputRemainder = ""
            lifecycle = .starting
            try process.start(Self.launchSpec(
                helperRoot: URL(fileURLWithPath: helperRoot,
                                isDirectory: true),
                configURL: configURL))
        } catch {
            removeTemporaryConfiguration()
            lifecycle = .failed("Could not start the Web helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard process.isRunning else {
            lifecycle = Self.helperExists(at: helperRoot) ? .stopped
                : .unavailable("Choose the folder containing the NOW Web helper.")
            return
        }
        lifecycle = .stopping
        process.stop()
    }

    func helperPathDidChange() {
        guard !process.isRunning else { return }
        lifecycle = Self.helperExists(at: helperRoot) ? .stopped
            : .unavailable("Choose the folder containing the NOW Web helper.")
    }

    /// Internal so readiness parsing can be tested without spawning a process.
    func acceptOutput(_ text: String) {
        outputRemainder += text
        let parts = outputRemainder.components(separatedBy: .newlines)
        outputRemainder = parts.last ?? ""
        for line in parts.dropLast() where !line.isEmpty {
            recentOutput.append(line)
            if recentOutput.count > 20 { recentOutput.removeFirst() }
            guard line.hasPrefix("NOW_WEB_READY ") else { continue }
            let fields = line.split(separator: " ")
            guard fields.count == 3,
                  fields[1] == "now-web-bridge/1",
                  let separator = fields[2].lastIndex(of: ":"),
                  let readyPort = Int(fields[2][fields[2].index(after: separator)...])
            else {
                lifecycle = .failed("The helper reported an incompatible readiness record.")
                process.stop()
                return
            }
            let address = String(fields[2][..<separator])
            lifecycle = .ready(address: address, port: readyPort)
        }
    }

    private func save(_ value: String, key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func removeTemporaryConfiguration() {
        if let temporaryConfigURL {
            try? FileManager.default.removeItem(at: temporaryConfigURL)
        }
        temporaryConfigURL = nil
    }

    private static func helperExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath:
            URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("nowweb/__main__.py").path)
    }

    private static func defaultHelperRoot(
        environment: [String: String]
    ) -> String {
        if let explicit = environment["NOW_WEB_BRIDGE_ROOT"], !explicit.isEmpty {
            return explicit
        }
        if let resource = Bundle.main.resourceURL?
            .appendingPathComponent("WebBridge", isDirectory: true),
           helperExists(at: resource.path) {
            return resource.path
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                      isDirectory: true)
        for candidate in [cwd.appendingPathComponent("web-bridge"),
                          cwd.deletingLastPathComponent()
                            .appendingPathComponent("web-bridge")] {
            if helperExists(at: candidate.path) { return candidate.path }
        }
        return ""
    }

    private static func launchSpec(helperRoot: URL,
                                   configURL: URL) -> WebBridgeLaunchSpec {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = helperRoot.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return WebBridgeLaunchSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "nowweb", "--config", configURL.path],
            environment: environment,
            currentDirectoryURL: helperRoot)
    }

    private static func isLoopback(_ address: String) -> Bool {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "localhost" || value == "::1"
            || value.hasPrefix("127.")
    }
}
