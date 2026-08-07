import Foundation

/// The Swift half of `tools/lane-ports`: it asks, it does not re-derive.
///
/// **Why it shells out rather than reimplementing the hash.** The scheme
/// is a limit stated once (AGENTS.md): the region, the stride, the role
/// names and the probe order all live in `tools/lane-ports`, and a second
/// implementation here would be a second place to be wrong — the shape
/// that produced `contract-coverage.md`'s two honest, contradictory
/// counts. Shelling out is also what the guard beside this already does
/// for `lsof` and `ps`.
///
/// The part that IS Swift is the part worth pinning without a process:
/// `owner(ofPort:in:)` is pure, so the attribution logic the guard's
/// failure text depends on can be tested against fixtures rather than
/// against whatever happens to be running on this Mac.
enum LanePorts {

    /// One lane's claim, as `tools/lane-ports` reports it.
    struct Lane: Decodable, Equatable {
        var block: Int
        var laneRoot: String
        var branch: String?
        var ports: [String: UInt16]
        var qmpSockets: [String]?
        var runDirs: [String]?
        var liveness: Liveness?

        var wire: UInt16? { ports["wire"] }
        var anchor: UInt16? { ports["anchor"] }

        /// Everything this lane owns, so a port can be attributed without
        /// knowing which role it plays.
        func owns(_ port: UInt16) -> Bool { ports.values.contains(port) }

        var label: String {
            let name = branch.flatMap { $0.isEmpty ? nil : $0 } ?? "(detached)"
            return "\(name) at \(laneRoot)"
        }
    }

    struct Liveness: Decodable, Equatable {
        var state: String
        var laneRootExists: Bool
    }

    // MARK: - pure

    /// Which of `lanes` owns `port`. Pure; the whole point of the type.
    static func owner(ofPort port: UInt16, in lanes: [Lane]) -> Lane? {
        lanes.first { $0.owns(port) }
    }

    /// The sentence the machine guard adds to "this port is held".
    ///
    /// Three answers, and they call for three different actions — which
    /// is the entire deficiency this addresses. Before, a red guard said
    /// only that the port was busy, so "another lane's VM" and "my own
    /// orphaned VM" and "a port nobody has a claim on" were one message.
    ///
    /// It stays a FAILURE in all three cases. Knowing whose it is does
    /// not make it safe to measure a machine somebody is using; it makes
    /// the next step obvious instead of a diagnosis.
    static func attribution(ofPort port: UInt16,
                            mine: Lane?,
                            lanes: [Lane]) -> String {
        if let mine, mine.owns(port) {
            return """
                That port is in YOUR OWN lane block (\(mine.block), \
                \(mine.label)), so whatever holds it was started by this \
                lane — most likely a VM orphaned by a crashed session. \
                Reclaim it: `tools/lane-ports reclaim` (guest-clean \
                shutdown through the recorded QMP socket path). Never \
                `kill` what lsof named — under user-mode networking that \
                process IS qemu.
                """
        }
        if let other = owner(ofPort: port, in: lanes) {
            return """
                That port belongs to lane block \(other.block) — \
                \(other.label)\
                \(other.liveness.map { " (\($0.state))" } ?? ""). It is not \
                yours and stopping it would be the collision this scheme \
                exists to remove. Use your own ports: \
                `eval "$(tools/lane-ports --env)"`\
                \(mine.map { " gives you \($0.ports["anchor"].map(String.init) ?? "?")/\($0.ports["wire"].map(String.init) ?? "?")" } ?? "").
                """
        }
        return """
            No lane claims that port — it is outside the derived region \
            or was assigned by hand. Whoever holds it cannot be attributed \
            from here, which is exactly the state that cost 2026-08-06. \
            `tools/lane-ports` gives this lane ports nobody else can pick.
            """
    }

    // MARK: - asking the tool

    /// The repository root, from this file's own path. Tests are always
    /// compiled from the tree they belong to, so this cannot point at
    /// another worktree the way a cwd can.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../now-host/Tests/HostTests/LanePorts.swift
            .deletingLastPathComponent()          // HostTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // now-host
            .deletingLastPathComponent()          // repo root
    }

    private static func run(_ arguments: [String]) -> Data? {
        let tool = repositoryRoot.appendingPathComponent("tools/lane-ports")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            return nil
        }
        let task = Process()
        task.executableURL = tool
        task.arguments = arguments
        task.currentDirectoryURL = repositoryRoot
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return data
    }

    /// This lane's block. `--no-claim` deliberately: a test run should
    /// not create a claim as a side effect of asking a question, or the
    /// registry fills with lanes that never booted anything.
    static func mine() -> Lane? {
        run(["show", "--json", "--no-claim"]).flatMap {
            try? JSONDecoder().decode(Lane.self, from: $0)
        }
    }

    static func all() -> [Lane] {
        run(["list", "--json"]).flatMap {
            try? JSONDecoder().decode([Lane].self, from: $0)
        } ?? []
    }
}
