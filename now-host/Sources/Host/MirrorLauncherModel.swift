import Combine
import Foundation

/// The Mirror module's model — a **launcher**, and deliberately nothing else.
///
/// Mirror is a separate application living in this repository at `mirror/`.
/// It has its own wire (line-JSON over Open Transport, not NOW's frame
/// codec), its own resident 68K extensions (AXPeek, QDPeek, Portal), and its
/// own agent surface (`MirrorApp --serve`). None of that is NOW's, and none
/// of it is reachable from a NOW guest connection.
///
/// This page used to be the other thing: a port of Mirror's renderer, scene
/// adapter, hit-testing and act plane, drawn inside NOW's own window over
/// NOW's own wire. It did not drive the machine — an empty menu bar, menus
/// that dropped and did nothing, nothing launchable or clickable — while its
/// gate stayed green, because every acceptance number in it was measured
/// against wire verbs by probe scripts and never once through the pane. It
/// is archived at `archive/mirror-port-2026-08-01/`, and the code that
/// replaced it is Mirror itself.
///
/// So the rule for this file: **it starts processes and reports what they
/// said.** No rendering, no scene, no hit-testing, no act, no MCP. A second
/// implementation of Mirror inside NOW is the mistake this module exists to
/// record, not to repeat.
@MainActor
final class MirrorLauncherModel: ObservableObject {

    /// Which of Mirror's two halves a button starts.
    enum Half: String, Identifiable, CaseIterable {
        /// `MirrorApp --window` — the native macOS window that draws the
        /// guest's interface.
        case hostApp
        /// `tools/spin-up.sh` — a throwaway emulator clone with Mirror's own
        /// guest app and INITs staged into it.
        case guestSession

        var id: String { rawValue }
    }

    /// Where Mirror is, or nil with the reason it could not be found.
    @Published private(set) var installation: MirrorInstallation?
    @Published private(set) var locationProblem: String?

    /// The last (or running) process's combined output, newest at the end.
    @Published private(set) var transcript: [String] = []
    /// Which half is running, if any. Both may not run at once from here —
    /// one console, one transcript.
    @Published private(set) var running: Half?
    /// What the last run ended as, in a sentence a person can act on.
    @Published private(set) var outcome: Outcome?

    struct Outcome: Equatable {
        var half: Half
        var status: Int32
        var summary: String
        var succeeded: Bool { status == 0 }
    }

    /// A transcript longer than this is a log, not a page. The tail is the
    /// half that says what happened.
    private static let transcriptLimit = 500

    private let environment: [String: String]
    private var process: Process?

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         executableURL: URL = Bundle.main.bundleURL) {
        self.environment = environment
        let found = MirrorInstallation.locate(
            override: environment[MirrorInstallation.pathOverrideKey],
            startingAt: executableURL)
        installation = found
        locationProblem = found == nil
            ? "Mirror was not found. This app looks for `mirror/` in the "
              + "repository above it, which only works when NOW is run from "
              + "its checkout. Set \(MirrorInstallation.pathOverrideKey) to "
              + "Mirror's directory to point it somewhere else."
            : nil
    }

    /// What would happen if the button were pressed — ready with the exact
    /// command, or blocked with everything that is missing.
    ///
    /// The view asks for this rather than being told, so the reasons are on
    /// screen BEFORE a click rather than as the wreckage after one.
    func plan(_ half: Half) -> MirrorPlan {
        guard let installation else {
            return .blocked([MirrorBlocker(
                what: "Mirror's directory",
                why: locationProblem ?? "not found")])
        }
        return installation.plan(half, environment: environment)
    }

    // MARK: - Running

    func run(_ half: Half) {
        guard running == nil else { return }
        guard case .ready(let invocation) = plan(half) else { return }

        transcript = ["$ \(invocation.displayCommand)"]
        outcome = nil
        running = half

        let task = Process()
        task.executableURL = invocation.executable
        task.arguments = invocation.arguments
        task.currentDirectoryURL = invocation.workingDirectory
        task.environment = environment.merging(invocation.extraEnvironment) {
            _, new in new
        }

        /* One pipe for both streams: the interleaving IS the story with a
           script that narrates its stages on stdout and fails on stderr, and
           two panes would let a reader put the failure beside the wrong
           stage. */
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)
            else { return }
            Task { @MainActor in self?.append(text) }
        }

        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.finish(half, status: status)
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            running = nil
            append("could not start: \(error.localizedDescription)")
            outcome = Outcome(half: half, status: -1,
                              summary: "Nothing started — \(error.localizedDescription)")
        }
    }

    private func append(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        transcript.append(contentsOf: lines.filter { !$0.isEmpty })
        if transcript.count > Self.transcriptLimit {
            transcript.removeFirst(transcript.count - Self.transcriptLimit)
        }
    }

    private func finish(_ half: Half, status: Int32) {
        process = nil
        running = nil
        outcome = Outcome(half: half, status: status,
                          summary: Self.summary(half, status: status))
    }

    /// The exit status in words. A non-zero status says only that something
    /// failed, so this points at the transcript rather than inventing a
    /// cause — the process already said what went wrong and paraphrasing it
    /// is how a reason gets lost.
    nonisolated static func summary(_ half: Half, status: Int32) -> String {
        let name = half == .hostApp ? "MirrorApp" : "spin-up.sh"
        if status == 0 {
            return half == .hostApp
                ? "MirrorApp exited normally (the window was closed)."
                : "spin-up.sh finished. Mirror's emulator session is up."
        }
        return "\(name) exited \(status). The output above is its own."
    }
}

/// Mirror on disk, and what each half of it needs before it can start.
///
/// Split out of the model and kept free of Process and SwiftUI so the
/// interesting half — which prerequisite is missing, and what the command
/// actually is — can be tested without spawning anything.
struct MirrorInstallation: Equatable {

    /// Mirror's own root: the directory holding `host/`, `guest/`, `tools/`.
    let root: URL

    /// For a host app that cannot see the repository — an installed `.app`
    /// has no checkout above it, and guessing a path is worse than saying
    /// plainly that the directory was not found.
    static let pathOverrideKey = "NOW_MIRROR_PATH"

    /// The file that proves a directory IS Mirror rather than merely named
    /// it. A marker inside the thing being located, not a name match.
    private static let marker = "host/MirrorKit/Package.swift"

    static func locate(override: String?,
                       startingAt start: URL,
                       fileManager: FileManager = .default) -> MirrorInstallation? {
        func isMirror(_ url: URL) -> Bool {
            fileManager.fileExists(
                atPath: url.appendingPathComponent(marker).path)
        }
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            return isMirror(url) ? MirrorInstallation(root: url) : nil
        }
        /* Walk up from the running binary looking for a repository with a
           `mirror/` in it. `swift run` puts the executable at
           now-host/.build/<config>/Host, and the Xcode app is deeper still,
           so the walk is bounded generously rather than by a counted number
           of components anyone would have to keep correct. */
        var dir = start.standardizedFileURL
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("mirror")
            if isMirror(candidate) {
                return MirrorInstallation(root: candidate.standardizedFileURL)
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    var package: URL { root.appendingPathComponent("host/MirrorKit") }
    var spinUp: URL { root.appendingPathComponent("tools/spin-up.sh") }
    var stopScript: URL { root.appendingPathComponent("tools/stop-mirror.sh") }
    /// Mirror's session scratch. `spin-up.sh` writes the ports it chose here,
    /// which is the only place the agent port is knowable from — it picks a
    /// FREE pair rather than a fixed one, precisely so two sessions cannot
    /// collide.
    var runDirectory: URL { root.appendingPathComponent("run") }

    /// `spin-up.sh` reads this to be told the lab outright rather than
    /// search for it. The launcher passes its own answer down, so the
    /// preflight and the run cannot disagree about which lab was meant.
    static let labRootKey = "MIRROR_LAB_ROOT"

    /// The file that proves a directory is the lab. Same marker the script
    /// walks for, so both stop at the same place.
    private static let labMarker = "tools/lib.sh"

    /// The lab checkout `spin-up.sh` borrows its emulator instruments from,
    /// resolved the way the script resolves it. It used to be Mirror's
    /// parent, and that stopped being true the day Mirror was vendored into
    /// NOW: the parent is then `now/`, which carries none of the
    /// instruments. So walk up from the parent until a directory actually
    /// holds one. `nil` means no lab above Mirror at all.
    ///
    /// This must keep agreeing with the script. An answer of its own would
    /// have the page check a prerequisite the script never looks for — or,
    /// the worse direction, pass a preflight the run then fails.
    func lab(_ environment: [String: String],
             _ fileManager: FileManager = .default) -> URL? {
        /* Taken as given, exactly as the script takes it: an override that
           names the wrong directory is then caught by the instrument check
           below, which says which piece is missing and where it looked. */
        if let override = environment[Self.labRootKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
        }
        var dir = root.deletingLastPathComponent().standardizedFileURL
        while true {
            if fileManager.fileExists(
                atPath: dir.appendingPathComponent(Self.labMarker).path) {
                /* Always a directory URL, whichever branch produced it, and
                   without consulting the filesystem to decide: URL spells
                   the same directory with or without a trailing slash, and
                   the two do not compare equal. */
                return URL(fileURLWithPath: dir.path, isDirectory: true)
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent == dir { return nil }
            dir = parent
        }
    }

    func plan(_ half: MirrorLauncherModel.Half,
              environment: [String: String],
              fileManager: FileManager = .default) -> MirrorPlan {
        switch half {
        case .hostApp: return hostAppPlan(environment, fileManager)
        case .guestSession: return guestSessionPlan(environment, fileManager)
        }
    }

    // MARK: - The host app

    private func hostAppPlan(_ environment: [String: String],
                             _ fileManager: FileManager) -> MirrorPlan {
        var blockers: [MirrorBlocker] = []
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        if !fileManager.isExecutableFile(atPath: swift.path) {
            blockers.append(MirrorBlocker(
                what: "A Swift toolchain",
                why: "no executable at /usr/bin/swift. MirrorApp is built "
                   + "from source with `swift run`; install the Xcode "
                   + "command line tools."))
        }
        /* The window needs a machine to mirror, and the port is not a
           constant: spin-up.sh picks a free pair and records it. Launching
           without one gets MirrorApp's usage text on stderr and an exit — a
           button that does that is a button that fails silently. */
        let session = Self.session(in: runDirectory, fileManager: fileManager)
        if session == nil {
            blockers.append(MirrorBlocker(
                what: "A running Mirror guest session",
                why: "no \(runDirectory.appendingPathComponent("ports").path). "
                   + "MirrorApp draws one specific machine and takes its port "
                   + "on the command line; start Mirror's guest first."))
        }
        guard blockers.isEmpty, let session else { return .blocked(blockers) }

        /* The flags spin-up.sh itself prints and uses. `--scope all` matters:
           `front` walks only the front application, so every other app's
           windows are missing from the scene, which reads as a rendering
           fault and was mistaken for one once (mirror/docs/TEST-DRIVE.md). */
        var arguments = ["run", "--package-path", package.path, "MirrorApp",
                         "--host", "127.0.0.1", "--port", String(session.agentPort),
                         "--machine", "mac99", "--scope", "all"]
        if let qmp = session.qmpSocket {
            arguments += ["--qmp", qmp.path]
        }
        arguments += ["--window", "--display", "--islands",
                      "--interval", "0.7"]
        return .ready(MirrorInvocation(executable: swift,
                                       arguments: arguments,
                                       workingDirectory: root))
    }

    /// What `spin-up.sh` left behind: the ports it chose and the QMP socket
    /// it is listening on.
    struct Session: Equatable {
        var anchorPort: Int
        var agentPort: Int
        var qmpSocket: URL?
    }

    static func session(in runDirectory: URL,
                        fileManager: FileManager = .default) -> Session? {
        let portsFile = runDirectory.appendingPathComponent("ports")
        guard let text = try? String(contentsOf: portsFile, encoding: .utf8)
        else { return nil }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int($0) }
        guard fields.count >= 2 else { return nil }
        let qmp = runDirectory.appendingPathComponent("qmp.sock")
        return Session(anchorPort: fields[0], agentPort: fields[1],
                       qmpSocket: fileManager.fileExists(atPath: qmp.path)
                           ? qmp : nil)
    }

    // MARK: - The guest session

    private func guestSessionPlan(_ environment: [String: String],
                                  _ fileManager: FileManager) -> MirrorPlan {
        var blockers: [MirrorBlocker] = []

        if !fileManager.isExecutableFile(atPath: spinUp.path) {
            blockers.append(MirrorBlocker(
                what: "Mirror's spin-up script",
                why: "nothing executable at \(spinUp.path)."))
        }

        /* Everything below hangs off the lab, so resolve it first and say so
           when there isn't one — the script's own first failure, and the
           only one it can report without a directory to look in. */
        let lab = self.lab(environment, fileManager)
        if lab == nil {
            blockers.append(MirrorBlocker(
                what: "The TimBotTu lab checkout",
                why: "no directory above \(root.deletingLastPathComponent().path) "
                   + "carries \(Self.labMarker). spin-up.sh borrows the "
                   + "emulator and its tools from the lab and finds it by "
                   + "walking up; set \(Self.labRootKey) to the checkout "
                   + "that has them."))
        }

        /* The two the script checks and names itself, checked here with the
           same defaults so the reason arrives before the run rather than as
           its first line of output. Without a lab there is no default path
           to name, and the blocker above already says why. */
        let qemu = environment["TIMBOTTU_QEMU"].map(URL.init(fileURLWithPath:))
            ?? lab?.appendingPathComponent("qemu/build/qemu-system-ppc")
        if let qemu, !fileManager.isExecutableFile(atPath: qemu.path) {
            blockers.append(MirrorBlocker(
                what: "qemu-system-ppc",
                why: "not executable at \(qemu.path). Set TIMBOTTU_QEMU."))
        }
        let base = environment["MIRROR_BASE"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Lab/Assets/os91-qemu/os91-runner.qcow2")
        if !fileManager.fileExists(atPath: base.path) {
            blockers.append(MirrorBlocker(
                what: "The Mac OS 9.1 base image",
                why: "no file at \(base.path). Set MIRROR_BASE."))
        }

        /* The instruments the script BORROWS rather than ships: it cds to
           the lab and sources its emulator library from there. A directory
           can carry the marker and still be missing the rest — most easily
           when MIRROR_LAB_ROOT names the wrong one — and the failure mode
           without this check is a wall of bash errors about files the
           reader has no reason to have heard of. */
        if let lab {
            let borrowed = ["tools/lib.sh", "tools/qmp", "mcp-classic"]
                .filter { !fileManager.fileExists(
                    atPath: lab.appendingPathComponent($0).path) }
            if !borrowed.isEmpty {
                blockers.append(MirrorBlocker(
                    what: "The lab instruments spin-up.sh borrows",
                    why: "missing under \(lab.path): "
                       + borrowed.joined(separator: ", ")
                       + ". That directory is where the lab was resolved to; "
                       + "set \(Self.labRootKey) to the TimBotTu checkout "
                       + "the instruments actually live in."))
            }
        }

        /* Mirror's guest halves are built artifacts, and its .gitignore keeps
           build output out of the tree — so a fresh checkout has none of them
           and the Retro68 toolchain is what produces them. */
        let artifacts = [
            "guest/extensions/axpeek/build/AXPeek.bin",
            "guest/extensions/qdpeek/build/QDPeek.bin",
            "guest/extensions/portal/build/Portal.bin",
            "guest/app/build/mirror-agent.bin",
        ].filter { !fileManager.fileExists(
            atPath: root.appendingPathComponent($0).path) }
        if !artifacts.isEmpty {
            blockers.append(MirrorBlocker(
                what: "Mirror's built guest pieces",
                why: "missing under \(root.path): "
                   + artifacts.joined(separator: ", ")
                   + ". They are Retro68 builds (68K INITs and a PPC agent) "
                   + "and are not committed; see mirror/guest/app/README.md."))
        }

        // `lab` is non-nil whenever there are no blockers; the bind is what
        // lets the invocation carry it.
        guard blockers.isEmpty, let lab else { return .blocked(blockers) }
        return .ready(MirrorInvocation(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [spinUp.path],
            workingDirectory: root,
            extraEnvironment: [
                // The cocoa window beside the mirror — the comparison is the
                // whole point of a test drive (mirror/docs/TEST-DRIVE.md).
                "MIRROR_DISPLAY": "1",
                /* Hand the script the lab this preflight actually checked.
                   Both sides resolve it the same way, so this changes no
                   outcome today — it removes the possibility of a later
                   drift between them being discovered as a green preflight
                   in front of a failed run. */
                Self.labRootKey: lab.path,
            ]))
    }
}

/// A command, resolved. Carries its own display form so the page can show
/// exactly what it is about to run before it runs it.
struct MirrorInvocation: Equatable {
    var executable: URL
    var arguments: [String]
    var workingDirectory: URL
    var extraEnvironment: [String: String] = [:]

    var displayCommand: String {
        let env = extraEnvironment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return (env + [executable.path] + arguments).joined(separator: " ")
    }
}

/// One missing prerequisite, named with what would fix it.
struct MirrorBlocker: Equatable, Identifiable {
    var what: String
    var why: String
    var id: String { what }
}

enum MirrorPlan: Equatable {
    case ready(MirrorInvocation)
    case blocked([MirrorBlocker])

    var blockers: [MirrorBlocker] {
        if case .blocked(let list) = self { return list }
        return []
    }

    var invocation: MirrorInvocation? {
        if case .ready(let invocation) = self { return invocation }
        return nil
    }
}
