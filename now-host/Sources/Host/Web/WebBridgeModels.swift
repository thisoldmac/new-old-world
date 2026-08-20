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
    let defaultProfile: String
    let defaultLens: String
    let handlersEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case host, port, engine
        case settleMilliseconds = "settle_ms"
        case allowedClients = "allowed_clients"
        case allowPrivateDestinations = "allow_private_destinations"
        case aiPlanCommand = "ai_plan_command"
        case defaultProfile = "default_profile"
        case defaultLens = "default_lens"
        case handlersEnabled = "handlers_enabled"
    }
}

@MainActor
final class WebBridgeModel: ObservableObject {
    @Published private(set) var lifecycle: WebBridgeLifecycle
    @Published private(set) var recentOutput: [String] = []
    @Published var helperRoot: String { didSet { save(helperRoot, key: .root) } }
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
    /// Persisted launch policy, separate from current runtime state.
    /// (`MCPTransportPreferences.swift`), but defaulted OFF: the bundled
    /// Python helper is heavier to have running unasked than a same-process
    /// MCP transport, and a person who wants the relay every launch can
    /// say so once.
    @Published var startsAutomatically: Bool {
        didSet {
            defaults.set(startsAutomatically, forKey: Key.startsAutomatically.rawValue)
        }
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
        case profile = "web.profile"
        case lens = "web.lens"
        case engine = "web.engine"
        case handlers = "web.handlers"
        case allowPrivate = "web.allowPrivateDestinations"
        case aiPlanner = "web.aiPlannerExecutable"
        case startsAutomatically = "web.startsAutomatically"
    }

    /// Read by `App.swift`'s launch hook, mirroring how the MCP transports'
    /// autostart is checked before their runtime exists — this lets launch
    /// consult the preference without forcing the module's runtime (and its
    /// listener registration) into existence when the answer is "no".
    static let startsAutomaticallyDefaultsKey = Key.startsAutomatically.rawValue

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: ProductIdentity.preferencesSuite) ?? .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        let initialRoot = defaults.string(forKey: Key.root.rawValue)
            ?? Self.defaultHelperRoot(environment: environment)
        helperRoot = initialRoot
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
        // Default off: absence of the key must mean
        // "do not start", not "start" — UserDefaults.bool already reads
        // false for an unset key, so no unset-vs-false disambiguation is
        // needed here.
        startsAutomatically = defaults.bool(
            forKey: Key.startsAutomatically.rawValue)
        lifecycle = Self.helperExists(at: initialRoot)
            ? .stopped
            : .unavailable("Choose the folder containing the NOW Web helper.")
    }

    var configuration: WebBridgeConfiguration {
        WebBridgeConfiguration(
            host: "127.0.0.1",
            port: 0,
            engine: engine.rawValue,
            settleMilliseconds: 3000,
            allowedClients: ["127.0.0.1", "::1"],
            allowPrivateDestinations: allowPrivateDestinations,
            aiPlanCommand: plannerCommand,
            defaultProfile: profile.rawValue,
            defaultLens: lens.rawValue,
            handlersEnabled: handlersEnabled)
    }

    private var plannerCommand: [String] {
        let path = aiPlannerExecutable.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &directory),
           directory.boolValue {
            return ["/usr/bin/env", "python3", "-m", "nowweb.model_planner",
                    "--model", path]
        }
        return [path]
    }

    var canStart: Bool {
        guard !process.isRunning, Self.helperExists(at: helperRoot) else {
            return false
        }
        return true
    }

    var rendererEndpoint: URL? {
        guard case .ready(let address, let port) = lifecycle else { return nil }
        return URL(string: "http://\(address):\(port)")
    }

    func start() {
        guard !process.isRunning else { return }
        guard canStart else {
            lifecycle = .failed("The bundled Web renderer is unavailable.")
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

}
