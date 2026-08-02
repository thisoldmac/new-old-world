import Combine
import Foundation
import Network

/// The Mirror page: the status of ONE Mirror host instance and of the
/// machine it would draw.
///
/// Mirror is a separate application, vendored at `mirror/`. It has its own
/// wire (line-JSON over Open Transport, not NOW's frame codec), its own
/// resident 68K extensions, and its own agent that runs inside the classic
/// Mac. None of that is NOW's, and this page does not reimplement any of
/// it — the port that tried is archived at `archive/mirror-port-2026-08-01/`
/// and is the mistake this module exists to record.
///
/// What it DOES own is a lifecycle and a verdict: is the connected Mac
/// ready for Mirror, can a Mirror instance reach it, is one running, and
/// what happened when it stopped. The old version of this page showed
/// shell commands and a transcript, which made a script document out of an
/// application; nothing here prints an argv.
@MainActor
final class MirrorControlModel: ObservableObject, GuestScopedModel {

    // MARK: - Status

    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }

    /// The three INITs, as far as this side can honestly see them.
    @Published private(set) var initRows: [MirrorInitRow] =
        MirrorInitReport.rows(unknown: "Not checked yet.")
    @Published private(set) var agent: MirrorAgentState = .untried
    @Published private(set) var endpoint: MirrorEndpoint =
        .unavailable(reason: "No Mac is connected.")
    @Published private(set) var reachability: MirrorReachability = .untried
    @Published private(set) var isChecking = false

    /// Where the launch would come from, recomputed whenever the settings
    /// that decide it change.
    @Published private(set) var productResolution: MirrorProductResolution =
        .missing("Not resolved yet.")

    // MARK: - Lifecycle

    @Published private(set) var run: MirrorRunState = .notRunning
    /// The tail of what the child said. Kept because an exit status alone
    /// never explains itself — and kept behind a disclosure in the view,
    /// because it is evidence, not the page.
    @Published private(set) var diagnostics: [String] = []

    // MARK: - Config

    @Published var forwardedAgentPort: Int {
        didSet {
            guard forwardedAgentPort != oldValue else { return }
            defaults.set(forwardedAgentPort, forKey: Keys.forwardedPort)
            recomputeEndpoint()
        }
    }

    @Published var namedAppPath: String {
        didSet {
            guard namedAppPath != oldValue else { return }
            defaults.set(namedAppPath, forKey: Keys.appPath)
            resolveProduct()
        }
    }

    @Published var buildFromSource: Bool {
        didSet {
            guard buildFromSource != oldValue else { return }
            defaults.set(buildFromSource, forKey: Keys.buildFromSource)
        }
    }

    private enum Keys {
        static let forwardedPort = "mirror.forwardedAgentPort"
        static let appPath = "mirror.appPath"
        static let buildFromSource = "mirror.buildFromSource"
    }

    // MARK: - Collaborators

    private let guestProbe: MirrorGuestProbing
    private let endpointProbe: MirrorEndpointProbing
    private let spawner: MirrorSpawning
    private let defaults: UserDefaults
    let checkout: MirrorCheckout?

    /// Guards a slow answer landing after the machine changed: each check
    /// takes a token and only the current one may publish.
    private var checkToken = 0
    private var childPID: Int32?

    /// The two live collaborators default to nil rather than to instances
    /// of themselves: a default argument is evaluated outside this class's
    /// actor, and both of them are main-actor types.
    init(guestProbe: MirrorGuestProbing,
         endpointProbe: MirrorEndpointProbing? = nil,
         spawner: MirrorSpawning? = nil,
         checkout: MirrorCheckout? = MirrorCheckout.locate(
            startingAt: Bundle.main.bundleURL),
         defaults: UserDefaults = .standard) {
        self.guestProbe = guestProbe
        self.endpointProbe = endpointProbe ?? MirrorTCPProbe()
        self.spawner = spawner ?? MirrorProcessSpawner()
        self.checkout = checkout
        self.defaults = defaults
        let stored = defaults.integer(forKey: Keys.forwardedPort)
        forwardedAgentPort = (1...65535).contains(stored)
            ? stored : MirrorEndpoint.defaultForwardedPort
        namedAppPath = defaults.string(forKey: Keys.appPath) ?? ""
        buildFromSource = defaults.bool(forKey: Keys.buildFromSource)
        resolveProduct()
        recomputeEndpoint()
    }

    // MARK: - Reading the machine

    /// Asks the connected Mac everything this page shows about it.
    ///
    /// Three questions, three answers, and each one publishes as it lands
    /// — a page that waits for the slowest of them tells a person nothing
    /// while the wire is busy.
    func check() {
        checkToken += 1
        let token = checkToken
        recomputeEndpoint()

        guard connection.canCapture else {
            initRows = MirrorInitReport.rows(
                unknown: "No Mac is connected.")
            agent = .untried
            reachability = .untried
            return
        }

        isChecking = true
        var outstanding = 2
        func settled() {
            outstanding -= 1
            if outstanding == 0, token == checkToken { isChecking = false }
        }

        guestProbe.listExtensions { [weak self] result in
            guard let self, token == self.checkToken else { return }
            switch result {
            case .success(let entries):
                self.initRows = MirrorInitReport.rows(from: entries)
            case .failure(let failure):
                /* Not "missing". A machine that could not be asked is a
                   machine nothing is known about, and the difference
                   decides whether Launch is refused. */
                self.initRows = MirrorInitReport.rows(unknown: failure.reason)
            }
            settled()
        }

        guestProbe.listProcesses { [weak self] result in
            guard let self, token == self.checkToken else { return }
            switch result {
            case .success(let names):
                self.agent = names.contains {
                    $0.compare(Self.agentProcessName,
                               options: .caseInsensitive) == .orderedSame
                } ? .running : .notRunning
            case .failure(let failure):
                self.agent = .unknown(failure.reason)
            }
            settled()
        }

        probeReachability(token: token)
    }

    /// What Mirror's agent calls itself in the machine's process list.
    static let agentProcessName = "mirror-agent"

    private func probeReachability(token: Int) {
        guard let target = endpoint.target else {
            reachability = .untried
            return
        }
        /* The agent accepts ONE client. Probing while our own instance
           holds the slot would be refused, or would take the slot from it
           — and either answer would be about this page rather than about
           the machine. So the check stands down and says which. */
        if run.holdsTheAgent {
            reachability = .paused(
                "A Mirror instance from this page is connected. Mirror's "
                + "agent accepts one client at a time, so checking now "
                + "would either be refused or take the connection from it.")
            return
        }
        reachability = .checking
        endpointProbe.probe(host: target.host, port: target.port,
                            timeout: 2.0) { [weak self] result in
            guard let self, token == self.checkToken else { return }
            switch result {
            case .success:
                self.reachability = .reachable
            case .failure(let failure):
                self.reachability = .refused(failure.reason)
            }
        }
    }

    private func recomputeEndpoint() {
        endpoint = MirrorEndpoint.derive(peer: guestProbe.activeGuest?.address,
                                         forwardedPort: forwardedAgentPort)
    }

    private func resolveProduct() {
        productResolution = MirrorProduct.resolve(
            named: namedAppPath.isEmpty ? nil : namedAppPath,
            checkout: checkout)
    }

    private func connectionChanged(from old: GuestConnectionState) {
        guard connection != old else { return }
        /* Everything on this page is a claim about one machine. A switch
           or a drop invalidates all of it at once, and an answer already
           in flight belongs to the machine we just left. */
        checkToken += 1
        isChecking = false
        initRows = MirrorInitReport.rows(
            unknown: connection.canCapture
                ? "Not checked yet." : "No Mac is connected.")
        agent = .untried
        reachability = .untried
        recomputeEndpoint()
    }

    // MARK: - Whether a launch can happen

    /// The INITs this side KNOWS are not loaded. An unchecked machine
    /// contributes nothing here, which is what keeps "could not ask" from
    /// reading as "absent".
    var absentInits: [MirrorInit] {
        initRows.filter { $0.state.isKnownAbsent }.map(\.component)
    }

    /// Why Launch will not do anything, or nil.
    ///
    /// Ordered by what a person would fix first: a machine, then a route
    /// to it, then the software on it, then the software here.
    var refusal: MirrorLaunchRefusal? {
        if run.isLive { return .alreadyRunning }
        guard connection.canCapture else { return .noGuest }
        guard let address = endpoint.addressText else {
            return .noEndpoint(endpoint.route)
        }
        if case .refused(let reason) = reachability {
            return .unreachable(address: address, reason: reason)
        }
        let absent = absentInits
        if !absent.isEmpty { return .initsAbsent(absent) }
        if buildFromSource {
            guard checkout != nil else { return .noCheckout }
            return nil
        }
        if case .missing(let reason) = productResolution {
            return .noProduct(reason)
        }
        return nil
    }

    var canLaunch: Bool { refusal == nil }

    // MARK: - Lifecycle

    /// Starts one Mirror instance against the derived endpoint.
    ///
    /// With the dev toggle on this builds first and launches from the
    /// build's own product, rather than from whatever was resolved before
    /// it ran — a build that produces a binary and then launches an older
    /// one is a debugging trap this page would be the cause of.
    func launch() {
        guard refusal == nil, let target = endpoint.target else { return }
        diagnostics = []
        if buildFromSource, let checkout {
            build(checkout, thenLaunchAt: target)
        } else if let product = productResolution.product {
            start(product, at: target)
        }
    }

    private func build(_ checkout: MirrorCheckout,
                       thenLaunchAt target: (host: String, port: Int)) {
        run = .building
        let outcome = spawner.spawn(
            MirrorInvocation.build(checkout),
            onOutput: { [weak self] line in self?.record(line) },
            onExit: { [weak self] status in
                guard let self else { return }
                self.childPID = nil
                guard status == 0 else {
                    self.run = .failed(
                        "Building Mirror failed (exit \(status)). The build's "
                        + "own output is below.")
                    return
                }
                /* Resolved AFTER the build, so the binary launched is the
                   one just produced. */
                self.resolveProduct()
                guard let product = self.productResolution.product else {
                    self.run = .failed(
                        "Mirror built, but no runnable product was found "
                        + "afterwards at \(checkout.releaseProduct.path).")
                    return
                }
                self.start(product, at: target)
            })
        switch outcome {
        case .success(let pid): childPID = pid
        case .failure(let failure):
            run = .failed("Could not start the build — \(failure.reason)")
        }
    }

    private func start(_ product: MirrorProduct,
                       at target: (host: String, port: Int)) {
        run = .launching
        let invocation = MirrorInvocation.liveWindow(
            product, host: target.host, port: target.port,
            machine: machineLabel)
        let outcome = spawner.spawn(
            invocation,
            onOutput: { [weak self] line in self?.record(line) },
            onExit: { [weak self] status in
                guard let self else { return }
                self.childPID = nil
                self.run = .exited(status: status, tail: self.diagnostics)
                /* The agent's one slot is free again, so the paused
                   reachability answer is no longer the true one. */
                self.reachability = .untried
            })
        switch outcome {
        case .success(let pid):
            childPID = pid
            run = .running(pid: pid)
            reachability = .paused(
                "A Mirror instance from this page holds the agent's one "
                + "connection.")
        case .failure(let failure):
            childPID = nil
            run = .failed("Mirror did not start — \(failure.reason)")
        }
    }

    /// Asks the instance to quit, and only escalates if it will not.
    ///
    /// SIGTERM first because Mirror closes its own window and lets go of
    /// the agent's single slot on the way out; a killed instance leaves
    /// that slot held until the guest's own socket times out, which reads
    /// afterwards as an agent that refuses everyone.
    func quit() {
        guard let pid = childPID, run.isLive else { return }
        spawner.terminate(pid: pid, escalateAfter: 5.0)
    }

    private func record(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        diagnostics.append(contentsOf: lines)
        if diagnostics.count > Self.diagnosticsLimit {
            diagnostics.removeFirst(diagnostics.count - Self.diagnosticsLimit)
        }
    }

    /// A tail, not a log. Anything longer belongs in a terminal.
    private static let diagnosticsLimit = 200

    /// What to call the machine on Mirror's command line. The handle a
    /// person types elsewhere in this app, so a Mirror window and a NOW
    /// window name the same Mac the same way.
    var machineLabel: String {
        guestProbe.activeGuest?.id.slug ?? "unknown"
    }
}

/// Why a probe could not answer, in the words the page shows. A typed
/// error rather than a bare `String` because a `Result` needs one, and a
/// sentence a person reads deserves better than being smuggled through
/// `localizedDescription`.
struct MirrorProbeFailure: Error, Equatable, Sendable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Whether Mirror's agent has a process on the machine.
enum MirrorAgentState: Equatable, Sendable {
    case untried
    case running
    case notRunning
    case unknown(String)
}

/// The lifecycle of the one instance this page owns.
enum MirrorRunState: Equatable, Sendable {
    case notRunning
    case building
    case launching
    case running(pid: Int32)
    /// It ran and stopped. The tail is what it last said, which is the
    /// only thing that explains a non-zero status.
    case exited(status: Int32, tail: [String])
    /// It never got as far as running.
    case failed(String)

    /// True while this page has a child of its own.
    var isLive: Bool {
        switch self {
        case .building, .launching, .running: return true
        case .notRunning, .exited, .failed: return false
        }
    }

    /// True while an instance of ours would be occupying the agent's one
    /// client slot. A build is not one of those — it talks to nothing.
    var holdsTheAgent: Bool {
        switch self {
        case .launching, .running: return true
        case .notRunning, .building, .exited, .failed: return false
        }
    }
}

// MARK: - Seams

/// What the page asks the connected Mac, over NOW's own wire.
@MainActor
protocol MirrorGuestProbing: AnyObject {
    /// The Extensions folder inventory — enabled items and the Extensions
    /// Manager disabled sibling both, which is what lets a disabled INIT
    /// be told from an absent one.
    func listExtensions(
        completion: @escaping (Result<[SoftwareEntry], MirrorProbeFailure>) -> Void)
    /// Process names only. The page asks one question of this list and
    /// carrying PSNs it will never use would invite a second.
    func listProcesses(
        completion: @escaping (Result<[String], MirrorProbeFailure>) -> Void)
    /// The machine being driven, for the address the endpoint derives
    /// from and the handle Mirror is told to call it.
    var activeGuest: ConnectedGuest? { get }
}

/// Whether something is listening, without saying anything to it.
@MainActor
protocol MirrorEndpointProbing: AnyObject {
    func probe(host: String, port: Int, timeout: TimeInterval,
               completion: @escaping (Result<Void, MirrorProbeFailure>) -> Void)
}

/// One child process, abstracted so the lifecycle can be tested without
/// spawning anything.
@MainActor
protocol MirrorSpawning: AnyObject {
    /// Starts it. `onOutput` and `onExit` fire on the main actor; `onExit`
    /// fires exactly once.
    func spawn(_ invocation: MirrorInvocation,
               onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) -> Result<Int32, MirrorProbeFailure>
    /// SIGTERM now; SIGKILL after the grace, and only if it is still there.
    func terminate(pid: Int32, escalateAfter: TimeInterval)
}

// MARK: - Live implementations

/// The wire half, over `GuestListener`.
@MainActor
final class MirrorGuestWireProbe: MirrorGuestProbing {
    private let listener: GuestListener

    init(listener: GuestListener) { self.listener = listener }

    var activeGuest: ConnectedGuest? {
        listener.guests.first { $0.isActive }
    }

    func listExtensions(
        completion: @escaping (Result<[SoftwareEntry], MirrorProbeFailure>) -> Void) {
        page(domain: MirrorInitReport.domain, cursor: nil, soFar: [],
             completion: completion)
    }

    private func page(domain: String, cursor: Int?, soFar: [SoftwareEntry],
                      completion: @escaping (Result<[SoftwareEntry],
                                            MirrorProbeFailure>) -> Void) {
        listener.listSoftware(domain: domain, cursor: cursor) { result in
            switch result {
            case .success(let listing):
                let all = soFar + listing.entries
                if listing.more, let next = listing.cursor {
                    self.page(domain: domain, cursor: next, soFar: all,
                              completion: completion)
                } else {
                    completion(.success(all))
                }
            case .failure(let failure):
                completion(.failure(MirrorProbeFailure(failure.message)))
            }
        }
    }

    func listProcesses(
        completion: @escaping (Result<[String], MirrorProbeFailure>) -> Void) {
        processPage(cursor: nil, soFar: [], completion: completion)
    }

    private func processPage(cursor: Int?, soFar: [String],
                             completion: @escaping (Result<[String],
                                                   MirrorProbeFailure>) -> Void) {
        listener.listProcesses(cursor: cursor) { result in
            switch result {
            case .success(let listing):
                let all = soFar + listing.processes.map(\.name)
                if listing.more, let next = listing.cursor {
                    self.processPage(cursor: next, soFar: all,
                                     completion: completion)
                } else {
                    completion(.success(all))
                }
            case .failure(let failure):
                completion(.failure(MirrorProbeFailure(failure.message)))
            }
        }
    }
}

/// A connect attempt and nothing more: it opens, learns whether anything
/// is there, and closes without writing a byte. Mirror's agent speaks its
/// own protocol and a probe that said hello in it would be a second
/// implementation of Mirror's client.
@MainActor
final class MirrorTCPProbe: MirrorEndpointProbing {

    func probe(host: String, port: Int, timeout: TimeInterval,
               completion: @escaping (Result<Void, MirrorProbeFailure>) -> Void) {
        guard let raw = UInt16(exactly: port), raw > 0,
              let nwPort = NWEndpoint.Port(rawValue: raw) else {
            completion(.failure(MirrorProbeFailure("\(port) is not a port")))
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var settled = false
        func finish(_ result: Result<Void, MirrorProbeFailure>) {
            guard !settled else { return }
            settled = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(result)
        }
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(MirrorProbeFailure(Self.words(error))))
                case .waiting(let error):
                    /* `waiting` is not a maybe here: nothing is listening
                       and Network is holding the attempt open in case
                       something starts. For a readiness check that is a no. */
                    finish(.failure(MirrorProbeFailure(Self.words(error))))
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(MirrorProbeFailure(
                "nothing answered within \(Int(timeout)) seconds")))
        }
    }

    private static func words(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "the connection was refused"
            case .EHOSTUNREACH: return "that Mac is unreachable"
            case .ETIMEDOUT: return "the attempt timed out"
            default: return String(describing: code)
            }
        default:
            return String(describing: error)
        }
    }
}

/// The real child. Output on one pipe, because a build's stages and its
/// errors interleave and two panes would let a reader put a failure beside
/// the wrong stage.
@MainActor
final class MirrorProcessSpawner: MirrorSpawning {

    private var live: [Int32: Process] = [:]

    func spawn(_ invocation: MirrorInvocation,
               onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) -> Result<Int32, MirrorProbeFailure> {
        let task = Process()
        task.executableURL = invocation.executable
        task.arguments = invocation.arguments
        task.currentDirectoryURL = invocation.workingDirectory

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in onOutput(text) }
        }
        task.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self.live.removeValue(forKey: finished.processIdentifier)
                onExit(status)
            }
        }
        do {
            try task.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure(MirrorProbeFailure(error.localizedDescription))
        }
        live[task.processIdentifier] = task
        return .success(task.processIdentifier)
    }

    func terminate(pid: Int32, escalateAfter grace: TimeInterval) {
        guard let task = live[pid] else { return }
        task.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, let still = self.live[pid], still.isRunning else {
                return
            }
            kill(pid, SIGKILL)
        }
    }
}
