import Foundation
import Network
import CoreGraphics
import Combine
import NOWAgentIntegration

/// The host side of the wire: listens, gates on hello, serves every guest
/// that dials in, answers pings, and declares death passively after
/// `timing.idleTimeout` without traffic (the host never pings — see
/// contract/asyncapi.yaml).
///
/// Several guests share one port and are told apart by `GuestKey`. One of
/// them is ACTIVE: the whole request-shaped API below — runCommand, exec,
/// listFiles, requestCapture — drives that one, so the console, the
/// modules and the agent projection go on meaning "the guest" without
/// knowing there are others. What every connected guest gets regardless
/// of which is active is the half it initiates: our own share is served,
/// its pushes are decoded, its pings are answered.
@MainActor
final class GuestListener: ObservableObject {
    enum State: Equatable {
        case idle
        case listening(port: UInt16)
        case connected(guestName: String)
        case failed(String)
    }

    struct Timing: Sendable {
        var idleTimeout: TimeInterval = 75
    }

    struct HostIdentity: Sendable {
        var version: String
        var name: String
    }

    /// One line of connection history, newest kept at the front by the view.
    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String

        static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
            lhs.at == rhs.at && lhs.text == rhs.text
        }
    }

    /// Live diagnostics for the currently connected guest.
    struct SessionHealth: Equatable {
        var guestName: String
        var guestVersion: String?
        /// The guest's build identity from `hello`, when it reports one.
        /// Nil means it does not — never a guess, and never `guestVersion`
        /// standing in, because two builds sharing a version is the whole
        /// reason this is here (docs/open-issues.md, 2026-07-30).
        var guestBuild: String? = nil
        /// What this machine answered at `hello` about agents driving it.
        /// Nil is "did not say" — a guest older than the field — and is
        /// not consent; the machine that means no says `.disabled`.
        var guestAgentAccess: AgentIntegrationGuestAccess? = nil
        var guestOS: String?
        var connectedAt: Date
        var lastTraffic: Date
        var pingsAnswered: Int
        var framesReceived: Int
    }

    /// How fast we are allowed to hand bulk bytes to TCP.
    ///
    /// The PB1400c drops an inbound frame that arrives back-to-back with
    /// another — its own ACK included. Handing TCP a whole 32 KB frame
    /// leaves the socket buffer permanently non-empty, so TCP fires the
    /// next segment the instant an ACK lands (measured: 0.13 ms after)
    /// and it dies. 48% of segments were being retransmitted, each
    /// costing a 311 ms RTO, which is the whole of the ~4 KB/s inbound
    /// ceiling (finding pb1400c-inbound-first-send-dropped).
    ///
    /// So we meter the writes. This is deliberately NOT the frame size:
    /// protocol framing stays at 32 KB and the guest still reassembles a
    /// byte stream, so nothing on the wire format changes.
    struct Pacing: Sendable, Equatable {
        /// Bytes handed to TCP per write. Sized to sit just under the
        /// 1460-byte MSS so each write is one segment.
        var bytes: Int
        /// Quiet time between writes, so the card is idle when the next
        /// frame lands.
        var gap: TimeInterval

        /// 1448 B per 3 ms tops out near 480 KB/s — twice what this wire
        /// manages in its healthy direction, so the meter never binds.
        static let classicMac = Pacing(bytes: 1448, gap: 0.003)

        /// How long each metered write took the socket to ACCEPT, against
        /// how far into the file it was. A transfer that runs at 340 KB/s
        /// and then 4 KB/s is either a host that stopped offering bytes
        /// or a socket that stopped taking them, and only this separates
        /// them: at 4 KB/s with 1448-byte writes each accept must be
        /// taking ~400 ms, which is backpressure the host did not choose.
        /// Off unless NOW_SEND_TRACE is set — it must cost nothing in
        /// normal operation.
        nonisolated(unsafe) static var trace: [(atByte: Int, ms: Double)] = []
        static let traceEnabled =
            ProcessInfo.processInfo.environment["NOW_SEND_TRACE"] != nil
        /// Hand each frame over whole, as before.
        static let none = Pacing(bytes: 0, gap: 0)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if ProcessInfo.processInfo.environment["NOW_HOST_DEBUG"] != nil {
                FileHandle.standardError.write(
                    Data("[now-host] state -> \(state)\n".utf8))
            }
        }
    }
    @Published private(set) var lastDisconnect: String?
    /// The last `error` the guest sent, kept because with two guests of
    /// very different completeness "the peer does not implement that" is
    /// ordinary traffic, not an incident — and a caller needs to be able
    /// to tell it apart from a request that simply never came back.
    @Published private(set) var lastGuestError: ErrorMessage?
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var health: SessionHealth?

    private var nextCommandId = 1
    private var pendingCommands: [Int: (CommandResult) -> Void] = [:]
    private var nextCensusId = 1
    private var pendingCensus: [Int: (CensusReport) -> Void] = [:]

    /// One exec in flight, from exec.request to its terminal exec.result.
    ///
    /// The text is ACCUMULATED here rather than handed up frame by frame,
    /// and that is a deliberate choice about where the seam sits. A guest
    /// splits exec.output where its buffer ends, not where a line ends
    /// (ExecOutput.text: "a chunk, not a line"), so a caller handed raw
    /// frames would have to reassemble before it could render — and every
    /// caller would have to do it identically. Doing it once, here, means a
    /// console renders text and nothing else.
    ///
    /// It also makes the phase-2 change invisible from above: a guest that
    /// sends fifty frames instead of one arrives at the same completion with
    /// the same string, so nothing above this line knows which it was.
    private struct PendingExec {
        var line: String
        var text: String = ""
        var nextSeq = 0
        /// Set when a frame arrives out of order. Surfaced rather than
        /// smoothed over: a hole in the output of a command someone is about
        /// to act on is worth an ugly line.
        var gap = false
        var completion: (ExecOutcome) -> Void
    }

    private var nextExecId = 1
    private var pendingExec: [Int: PendingExec] = [:]

    /// What an exec settled as. `text` is everything the guest emitted,
    /// reassembled; `ok`/`code` are its terminal word.
    struct ExecOutcome: Equatable, Sendable {
        var text: String
        var ok: Bool
        var code: String?
        var message: String?
        /// True when a frame went missing. The console prints a notice; no
        /// caller has to check it to be correct.
        var gap: Bool = false
    }

    /// What this connection has been observed to implement.
    ///
    /// Two guests of very different completeness share this wire, and the
    /// only truthful way to know which message families the one currently
    /// connected serves is to have asked it: the families are not in
    /// `help`, and nothing in the handshake declares them. So every
    /// family request records its own outcome here as it settles, and the
    /// agent companion reads the accumulated record rather than deciding
    /// anything from the guest's name. Cleared when the connection goes,
    /// because the next guest is not this one.
    /// Read by the agent's capability ledger, which asks about "the
    /// guest" and means the active one.
    var familyObservations: [String: GuestFamilyObservation] {
        activeKey.flatMap { familyObservationsByGuest[$0] } ?? [:]
    }

    /// Kept per guest, because the record is a claim about ONE machine.
    /// Held flat on the listener, it would have been cleared by any
    /// guest's disconnect and read by whichever guest was active — two
    /// ways to say something untrue about a Mac that never refused
    /// anything.
    private var familyObservationsByGuest:
        [GuestKey: [String: GuestFamilyObservation]] = [:]

    /// One family's most recent settled outcome on this connection.
    struct GuestFamilyObservation: Equatable, Sendable {
        var served: Bool
        /// The guest's own refusal code, when it refused.
        var code: String?
        var message: String?
        var observedAt: Date
    }

    /// Records a settled family request. A TIMEOUT is deliberately not
    /// recorded at all: silence proves nothing about what a guest
    /// implements, and writing it down as a refusal would let one wedged
    /// MacTCP stack read as a permanently missing feature.
    private func observeFamily(_ family: String,
                               served: Bool,
                               code: String? = nil,
                               message: String? = nil) {
        if !served, let code, code == "timeout" || code == "disconnected" {
            return
        }
        // Filed against the guest that was asked. A family request only
        // ever goes to the active one, so that is who answered.
        guard let key = activeKey else { return }
        familyObservationsByGuest[key, default: [:]][family] = .init(
            served: served, code: code, message: message,
            observedAt: Date())
    }

    /// Wraps a family request's completion so its outcome is recorded no
    /// matter which way it settles — success, the guest's refusal, or the
    /// watchdog. Recording at the REQUEST site rather than at each of the
    /// several resolution sites is what keeps the record complete.
    private func observing<Value>(
        _ family: String,
        _ completion: @escaping (Result<Value, FileFailure>) -> Void
    ) -> (Result<Value, FileFailure>) -> Void {
        { [weak self] result in
            switch result {
            case .success:
                self?.observeFamily(family, served: true)
            case .failure(let failure):
                self?.observeFamily(
                    family, served: false,
                    code: failure.code, message: failure.message)
            }
            completion(result)
        }
    }

    private let identity: HostIdentity
    private let timing: Timing
    private let pacing: Pacing
    private let maxGuests: Int
    private var listener: NWListener?

    /// Every guest currently past the hello gate, by SESSION identity —
    /// one entry per connection, never per name.
    private var sessions: [GuestKey: Session] = [:]
    /// Which machine each live session is a session WITH. The registry is
    /// the book; this is the page open at each socket.
    private var machineBySession: [GuestKey: GuestRegistry.Record] = [:]
    /// The host's own book of machine handles. See GuestRegistry for
    /// where an id comes from and why it is assigned here.
    let registry: GuestRegistry
    /// Which of them the request-shaped API drives. Nil when none are
    /// connected.
    private(set) var activeKey: GuestKey?

    /// The active session. Every existing caller means this one, so it
    /// stays spelled `session` and stays private — the table is the new
    /// thing, and nothing outside this file has to learn about it yet.
    private var session: Session? {
        activeKey.flatMap { sessions[$0] }
    }

    /// Who is connected, active one first-class rather than implied.
    /// Published so a view can list them; nothing reads it yet.
    @Published private(set) var guests: [ConnectedGuest] = []

    init(identity: HostIdentity, timing: Timing = Timing(),
         pacing: Pacing = .classicMac, maxGuests: Int = 4,
         registry: GuestRegistry? = nil) {
        self.registry = registry ?? GuestRegistry()
        self.identity = identity
        self.timing = timing
        self.pacing = pacing
        /* Bounded because an accepted connection costs a socket, a
           decoder and a health record that live until the idle timeout,
           and "serve several" must not read as "serve any number". The
           refusal says the number, so a human can tell it from a
           collision. */
        self.maxGuests = max(1, maxGuests)
    }

    /// Points the request-shaped API at another connected guest.
    ///
    /// The seam the UI will use; `HostAppState` does NOT call it yet, and
    /// wiring it to a picker is not just a matter of calling it: the
    /// modules cache a process table, a software inventory and a census
    /// per CONNECTION and clear it only when the connection drops, so a
    /// switch would show one guest's rows under the other's name. That
    /// is the next slice, listed in docs/local/multi-guest-plan.md.
    @discardableResult
    func selectGuest(_ key: GuestKey) -> Bool {
        guard sessions[key] != nil, activeKey != key else { return false }
        // Requests already in flight belong to the guest we are leaving
        // and would otherwise settle against whatever answers next.
        failAllPending("Switched to another Mac")
        activeKey = key
        publishActive()
        return true
    }

    /// Republishes everything that means "the active guest" — the state,
    /// its health, and the roster. One place, because the three drifting
    /// apart is how a disconnected guest stays on screen.
    private func publishActive() {
        if let activeKey, let session = sessions[activeKey] {
            state = .connected(guestName: session.guestName)
            health = healthByGuest[activeKey]
        } else if listener != nil {
            state = .listening(port: boundPort ?? 0)
            health = nil
        } else {
            state = .idle
            health = nil
        }
        /* Built from LIVE sessions only. The registry remembers machines
           that are not here, and deliberately cannot put a row on this
           list: that is what stops a stale record shadowing the machine
           actually on the wire. */
        guests = sessions.compactMap { key, live -> ConnectedGuest? in
            guard let record = healthByGuest[key] else { return nil }
            let machine = machineBySession[key]
            return ConnectedGuest(
                key: key,
                id: machine?.id ?? key.machine,
                idIsAutoAssigned: machine?.autoAssigned ?? true,
                idIsAnchored: live.guestAddress.distinguishesMachines,
                name: live.guestName,
                address: live.guestAddress,
                version: record.guestVersion,
                build: record.guestBuild,
                agentAccess: record.guestAgentAccess,
                operatingSystem: record.guestOS,
                connectedAt: record.connectedAt,
                isActive: key == activeKey)
        }.sorted { $0.connectedAt < $1.connectedAt }
    }

    /// This connection's session identity, minted once at the gate.
    ///
    /// The machine id comes from the registry; the UUID makes the session
    /// its own thing, so a caller holding `pb1400c-<uuid>` after a silent
    /// reconnect is told its session ended rather than being retargeted
    /// at the successor while believing it holds continuity.
    private func mintSessionKey(hello: Hello,
                                address: GuestAddress) -> GuestKey {
        let print = GuestRegistry.fingerprint(
            name: hello.name, operatingSystem: hello.os)
        /* Only slots held by a LIVE session count. A machine reconnecting
           into a slot nobody is using re-adopts the id it had. */
        let occupied = Set(machineBySession.values.filter {
            $0.address == address.text && $0.fingerprint == print
        }.map(\.slot))
        let record = registry.identify(
            address: address, name: hello.name, operatingSystem: hello.os,
            occupiedSlots: occupied)
        let key = GuestKey(machine: record.id, session: UUID())
        machineBySession[key] = record
        return key
    }

    /// The connected guest a caller means, by machine id.
    ///
    /// "Whatever is connected to that Mac now" — the convenient mode, and
    /// the right one for a person or an agent that just wants the
    /// machine. It follows a reconnection, which is exactly what a
    /// session id does not do.
    func guest(machine id: GuestID) -> ConnectedGuest? {
        guests.first { $0.id == id }
    }

    /// The connected guest a caller means, by session id.
    ///
    /// Precise: if that session has ended, this is nil and the caller is
    /// owed "that session ended", never its successor's answer. The same
    /// shape as the process and quit references on the agent surface — a
    /// stale reference is refused, not reinterpreted.
    func guest(session text: String) -> ConnectedGuest? {
        guard let key = GuestKey.parse(text) else { return nil }
        return guests.first { $0.key == key }
    }

    /// Names a connected machine, and re-labels its live session's row.
    ///
    /// The session id it was minted with does NOT change — a caller
    /// holding one must keep being able to present it — so a renamed
    /// machine reads as `pb1400c` in the roster while its current session
    /// is still `guest-2-<uuid>`. The next connection carries the new
    /// name into its session id.
    @discardableResult
    func renameGuest(_ key: GuestKey, to proposed: String)
        -> Result<GuestID, GuestRegistry.RenameFailure> {
        guard let record = machineBySession[key] else {
            return .failure(.notFound)
        }
        let outcome = registry.rename(record.id, to: proposed)
        if case .success(let renamed) = outcome {
            for (session, held) in machineBySession where held.id == record.id {
                machineBySession[session]?.id = renamed
                machineBySession[session]?.autoAssigned = false
            }
            publishActive()
        }
        return outcome
    }

    /// Per-guest health, so switching does not have to re-ask the wire
    /// and a background guest's ping count is not lost.
    private var healthByGuest: [GuestKey: SessionHealth] = [:]

    private static let logLimit = 100

    /// A line for the window and the file. `area` is the subsystem the
    /// line belongs to, so a log can be read by subsystem the way the
    /// other machine's can (docs/logging.md).
    func note(_ text: String, area: String = "wire",
              level: HostLog.LogLevel = .info) {
        if ProcessInfo.processInfo.environment["NOW_HOST_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[now-host] \(text)\n".utf8))
        }
        /* The window keeps the last hundred lines; the file keeps all of
           them. Everything worth knowing after the fact — what happened
           before you looked, and what happened after you quit — is only
           in the second one. */
        HostLog.shared.write(level, area, text)
        log.append(LogEntry(at: Date(), text: text))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    func start(port: UInt16) {
        stop()
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)
                ?? NWEndpoint.Port(rawValue: 0)!
            let listener = try NWListener(using: .tcp, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] nwState in
                Task { @MainActor in self?.listenerStateChanged(nwState) }
            }
            listener.start(queue: .main)
        } catch {
            state = .failed("Could not listen: \(error.localizedDescription)")
            note("Could not listen: \(error.localizedDescription)")
        }
    }

    func stop() {
        // Every guest is told, not just the active one: a guest we stop
        // serving without a bye learns nothing for ~65 s and leaks a
        // T_DISCONNECT on OS 9 (contract, connection rules).
        for live in sessions.values {
            live.close(sending: Bye(code: .shuttingDown, reason: nil))
        }
        sessions = [:]
        machineBySession = [:]
        healthByGuest = [:]
        activeKey = nil
        guests = []
        health = nil
        listener?.cancel()
        listener = nil
        state = .idle
    }

    /// `stop()`, but it waits for the farewell to leave.
    ///
    /// This exists for ⌘Q. `stop()` hands `bye` to the connection and returns
    /// immediately; the write completes on a callback. Terminating the process
    /// in the same turn of the run loop therefore kills the socket with the
    /// farewell still queued, and the guest learns nothing until its keepalive
    /// gives up ~65 s later — an unannounced close, which on OS 9 also leaks a
    /// T_DISCONNECT indication (see the contract's connection rules). The
    /// guest is auto-reconnecting the whole time, against a host that is gone.
    ///
    /// So: send, wait for the socket to accept it, then report. Bounded,
    /// because the reason a guest needs telling is often that it has stopped
    /// reading — a quit that hangs on a wedged classic Mac is worse than a
    /// quit that gives up on the farewell. `completion` fires exactly once,
    /// on the main actor, whichever comes first.
    func shutDown(timeout: TimeInterval = 0.5,
                  completion: @escaping () -> Void) {
        let leaving = Array(sessions.values)
        sessions = [:]
        machineBySession = [:]
        healthByGuest = [:]
        activeKey = nil
        guests = []
        health = nil
        listener?.cancel()
        listener = nil
        state = .idle

        guard !leaving.isEmpty else {
            completion()
            return
        }
        var reported = false
        func report() {
            guard !reported else { return }
            reported = true
            completion()
        }
        // Every guest is told; the quit proceeds as soon as the LAST
        // farewell the sockets accept has left, or the timeout below,
        // whichever comes first. One wedged Mac must not hold the others'
        // farewell hostage, so each is sent independently.
        var outstanding = leaving.count
        for live in leaving {
            live.close(sending: Bye(code: .shuttingDown, reason: nil)) {
                outstanding -= 1
                if outstanding == 0 { report() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated {
                if !reported {
                    self.note("Quit without confirming the farewell reached "
                              + "the other Mac")
                }
                report()
            }
        }
    }

    /// The port actually bound (differs from the requested one when 0 was
    /// passed for an ephemeral port — used by tests).
    var boundPort: UInt16? { listener?.port?.rawValue }

    /// Runs one declared command on the connected guest. Completion fires on
    /// the main actor with the guest's result, or a synthesized failure when
    /// no guest is connected / the session dies first.
    /// - Parameters:
    ///   - args: the typed form, for a caller that knows the command — a
    ///     module, an agent.
    ///   - line: the raw form, for the console, which does not: the text a
    ///     human typed after the command name, parsed by the guest with that
    ///     command's own grammar. An EMPTY string is not nil here — its
    ///     presence is what tells the guest a human is asking (see
    ///     CommandRequest.line in the contract), so the console passes "" for
    ///     a bare command and never omits the field.
    func runCommand(_ name: String, args: [String: String]? = nil,
                    line: String? = nil,
                    completion: @escaping (CommandResult) -> Void) {
        guard let session, case .connected = state else {
            completion(CommandResult(
                id: 0, ok: false, output: nil,
                error: .init(code: "not-connected",
                             message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingCommands[id] = completion
        session.sendCommand(CommandRequest(id: id, name: name, args: args,
                                           line: line))
    }

    /// Runs one line on the connected Mac and hands back what it printed.
    ///
    /// The line goes out EXACTLY as given — this function does not trim it,
    /// does not split a verb off it, does not check it against anything, and
    /// has no list to check it against. That is the entire point of the exec
    /// plane: a verb a guest gained this morning is reachable from a host
    /// binary built last month, because this side never learned the old set
    /// in the first place (contract preamble, "Exec").
    ///
    /// The completion fires once, with everything the guest emitted joined
    /// in `seq` order and its terminal ok/code. A guest that streams and a
    /// guest that answers in one shot are indistinguishable from here, which
    /// is what lets the guest gain streaming without this changing.
    ///
    /// The watchdog is 60s rather than the 15s a command.request gets. The
    /// reason is `vprobe`: it measures for ~12 seconds by design, and on a
    /// PowerBook that is a floor rather than a typical case. A console is
    /// also the one surface where a human is watching and can see that
    /// nothing has come back, so a generous bound costs less here than a
    /// premature "timeout" on a command that was working.
    func exec(_ line: String,
              completion: @escaping (ExecOutcome) -> Void) {
        guard let session, case .connected = state else {
            completion(ExecOutcome(text: "", ok: false, code: "disconnected",
                                   message: "No Mac is connected"))
            return
        }
        let id = nextExecId
        nextExecId += 1
        pendingExec[id] = PendingExec(line: line, completion: completion)
        armWatchdog(id: id, seconds: 60) { [weak self] reason in
            guard let self, let pending = self.pendingExec
                .removeValue(forKey: id) else { return }
            /* Whatever DID arrive is handed over, not discarded. A command
               that printed four lines and then wedged has told a human more
               than a bare "timeout" does, and throwing it away to keep the
               failure tidy would be throwing away the diagnosis. */
            pending.completion(ExecOutcome(
                text: pending.text, ok: false, code: "timeout",
                message: reason, gap: pending.gap))
        }
        session.send(.execRequest(ExecRequest(id: id, line: line)))
    }

    /// Cancels an exec by id. Answered by the guest with a terminal
    /// exec.result either way, so the completion still fires exactly once
    /// and this function stores nothing.
    func cancelExec(id: Int) {
        guard let session, case .connected = state else { return }
        session.send(.execCancel(ExecCancel(id: id)))
    }

    /// The id of the exec currently in flight, or nil. There is at most one:
    /// the guests refuse a second with `exec-busy`, because their dispatch is
    /// synchronous and its output sink is a single static.
    var runningExecId: Int? { pendingExec.keys.first }

    /// Answers a prompt a running exec printed.
    ///
    /// The host does NOT try to tell a prompt from ordinary output, and does
    /// not need to: while an exec is in flight a typed line can only be meant
    /// as input, since a second exec would be refused. If the guest was not
    /// in fact waiting it drops the line rather than buffering it, so the
    /// worst case of guessing wrong is that nothing happens — never that a
    /// stale answer lands in the next prompt.
    func provideExecInput(id: Int, text: String) {
        guard let session, case .connected = state else { return }
        session.send(.execInput(ExecInput(id: id, text: text)))
    }

    private func resolveExecOutput(_ output: ExecOutput) {
        guard var pending = pendingExec[output.id] else {
            /* Output for an exec nobody is waiting on: a late frame after a
               timeout already settled it. Dropping is right — the caller has
               been answered and answering twice is worse than losing a line
               nobody is looking at. */
            return
        }
        if output.seq != pending.nextSeq {
            pending.gap = true
        }
        pending.nextSeq = output.seq + 1
        pending.text += output.text
        pendingExec[output.id] = pending
        touchWatchdogs()          /* output is evidence of life */
    }

    private func resolveExecResult(_ result: ExecResult) {
        guard let pending = pendingExec.removeValue(forKey: result.id) else {
            return
        }
        clearWatchdog(result.id)
        pending.completion(ExecOutcome(
            text: pending.text, ok: result.ok, code: result.code,
            message: result.message, gap: pending.gap))
    }

    /// Ask the connected guest for one page of a census probe. The dossier
    /// view will page by passing the report's `cursor` back; the helper is
    /// here now so tests and the later view share one path.
    func requestCensus(probe: String, cursor: Int? = nil,
                       completion: @escaping (CensusReport) -> Void) {
        guard let session, case .connected = state else {
            completion(CensusReport(
                id: 0, probe: probe, outcome: "failed", rows: [],
                more: false, cursor: nil, total: nil,
                note: "No Mac is connected"))
            return
        }
        let id = nextCensusId
        nextCensusId += 1
        pendingCensus[id] = completion
        session.send(.censusRequest(
            CensusRequest(id: id, probe: probe, cursor: cursor)))
    }

    /// A capture that could not be produced or decoded; `message` is written
    /// for a human, since it lands in the Screenshots panel.
    struct CaptureFailure: Error {
        var message: String
    }

    /// The initiator's knobs, riding stream.start / capture.request; nil
    /// fields fall back to the guest's own panel settings.
    struct CaptureTuning: Equatable, Sendable {
        var chunkKb: Int?
        var paceMs: Int?
        var pack: Bool?
        var predictive: Bool?
        var interlace: Bool?
    }

    // MARK: - Serving our own share

    /// What this Mac shares. Symmetric with the guest's share root: the
    /// other machine may browse it, pull from it, and write into it,
    /// without anyone here doing anything.
    let share = HostShare()

    /// Text conversion for files we serve, mirroring the Files module's
    /// setting for the ones we fetch.
    var convertServedText = true


    /* The four serve functions and noteReceived take the connection that
       ASKED, rather than reaching for `session`. With one guest the two
       were the same object and the distinction was invisible; with two,
       reaching for `session` would answer the active guest's socket with
       the other guest's listing. */

    /// Answers a listing request from the guest.
    fileprivate func serveList(_ request: FileList, on session: Session) {
        do {
            let page = try share.list(path: request.path,
                                      cursor: request.cursor ?? 1,
                                      limit: 16)
            note("#\(request.id) listed \(page.entries.count) "
                 + "item\(page.entries.count == 1 ? "" : "s") of "
                 + "\(request.path.isEmpty ? "the share root" : request.path)",
                 area: "files")
            session.send(.fileListing(FileListing(
                id: request.id, path: request.path, entries: page.entries,
                more: page.more, cursor: page.next,
                /* Only the root listing names the place; a subfolder
                   listing already knows where it is. */
                root: request.path.isEmpty ? share.rootDisplayName : nil)))
        } catch {
            session.refuseFile(id: request.id, error: error)
        }
    }

    /// Answers a pull request: the same begin / bulk / end shape the
    /// guest uses, metered the same way.
    fileprivate func serveGet(_ request: FileGet, on session: Session) {
        do {
            let plan = try share.read(
                path: request.path,
                convertText: convertServedText
                    && request.container != "data")
            note("#\(request.id) serving \(plan.name), "
                 + "\(plan.bytes.count) bytes", area: "files")
            session.serveFile(id: request.id, plan: plan,
                              container: request.container,
                              modified: plan.modified)
        } catch {
            session.refuseFile(id: request.id, error: error)
        }
    }

    /// A file the guest wants to put into our share. Accepted without
    /// prompting: this side is not necessarily attended either, and the
    /// share is what the human already agreed the other machine may
    /// write into.
    fileprivate func acceptOffer(_ offer: FileOffer, on session: Session) {
        do {
            let url = try share.destination(
                name: offer.name, path: offer.path,
                createParents: offer.createParents ?? true,
                overwrite: offer.overwrite ?? false)
            note("#\(offer.id) accepting \(offer.name), "
                 + "\(offer.bytes) bytes, into the share", area: "files")
            try session.beginReceiving(offer: offer, to: url)
        } catch {
            session.refuseFile(id: offer.id, error: error)
        }
    }

    /// Set by the app so an arriving file is visible from outside the
    /// window. Kept as a hook so this file stays free of AppKit chrome
    /// and the tests stay silent.
    var announceReceivedFile: ((String, URL, Int) -> Void)?

    /// The four change operations, answered the way the guest answers
    /// them: one file.result, success or not, because the asker is
    /// holding an undo stack and a silent failure leaves it believing
    /// something it can reverse.
    fileprivate func serveChange(_ change: ChangeRequest,
                                on session: Session) {
        do {
            switch change {
            case .move(let request):
                let landed = try share.move(from: request.path,
                                            to: request.toPath,
                                            overwrite: request.overwrite
                                                ?? false)
                note("#\(request.id) moved \(request.path) to \(landed)",
                     area: "files")
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            case .trash(let request):
                let landed = try share.trash(path: request.path)
                /* The other machine putting a file of yours in the
                   Trash is the line most worth having later. */
                note("#\(request.id) trashed \(request.path), it is in the "
                     + "Trash as \(landed)", area: "files")
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: request.path,
                    trashedAs: landed, code: nil, reason: nil)))
            case .restore(let request):
                let landed = try share.restore(trashedAs: request.trashedAs,
                                               to: request.toPath)
                note("#\(request.id) restored \(request.trashedAs) to "
                     + "\(landed)", area: "files")
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            case .mkdir(let request):
                let landed = try share.makeFolder(path: request.path)
                note("#\(request.id) made the folder \(landed)",
                     area: "files")
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            }
        } catch {
            let fault = HostShare.WireFault(error)
            note("#\(change.id) change refused: \(fault.code) "
                 + "(\(fault.reason))", area: "files", level: .warn)
            session.send(.fileResult(FileResult(
                id: change.id, ok: false, path: nil, trashedAs: nil,
                code: fault.code, reason: fault.reason)))
        }
    }

    enum ChangeRequest {
        case move(FileMove), trash(FileTrash)
        case restore(FileRestore), mkdir(FileMkdir)

        var id: Int {
            switch self {
            case .move(let r): return r.id
            case .trash(let r): return r.id
            case .restore(let r): return r.id
            case .mkdir(let r): return r.id
            }
        }
    }

    fileprivate func noteReceived(_ url: URL, from session: Session) {
        let bytes = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int) ?? nil
        // The sender, not the active guest: a notification naming the
        // wrong Mac is worse than one naming none.
        announceReceivedFile?(session.guestName, url, bytes ?? 0)
    }

    // MARK: - Files

    struct FileFailure: Error {
        var code: String
        var message: String
        var putEvidence: PutFailureEvidence?

        init(
            code: String,
            message: String,
            putEvidence: PutFailureEvidence? = nil
        ) {
            self.code = code
            self.message = message
            self.putEvidence = putEvidence
        }
    }

    struct PutFailureEvidence {
        var totalBytes: Int
        var acceptedOffset: Int
        var receiverConfirmedBytes: Int?
        var elapsedMs: Int
        var progressEvidence: String
        var maximumProgressGapMs: Int?
        var guestFreeBytesBefore: Int?
        var guestReservedBytes: Int?
        var guestStaging: String?
        var guestCleanup: String
    }

    /// Host-side evidence that the matching `file.done ok:true` arrived.
    struct PutReceipt {
        var requestID: Int
        var acknowledgedAt: Date
        var totalBytes: Int
        var receiverConfirmedBytes: Int
        var acceptedOffset: Int
        var elapsedMs: Int
        var averageBytesPerSecond: Int
        var progressEvidence: String
        var maximumProgressGapMs: Int?
        var guestFreeBytesBefore: Int?
        var guestReservedBytes: Int?
        var guestStaging: String?
        var finalization: String
        var cleanup: String
        var integrity: String
    }

    /// One pulled file, still in guest form. The bytes remain in a
    /// same-folder temporary file until the caller converts or moves it;
    /// delivery itself never reconstructs the artifact in memory.
    struct FileDelivery {
        var name: String
        var container: String
        var fileType: String?
        var creator: String?
        var modified: Int?
        var staged: InboundFileSink.StagedFile
        var transferMs: Int
        /// The whole-stream CRC-32 the SENDER computed, when it sent one.
        /// The sink has already verified the received bytes against it, so
        /// a value here means checked; **nil means the guest computed none
        /// and the bytes are UNCHECKED**, which a consumer must report as
        /// unchecked rather than as correct (`file.end.crc32` is optional
        /// by contract, and an older guest sends no field at all).
        var crc32: UInt32?
        /// The opaque source token a guest offered in `file.begin`, when it
        /// offered one. Reverse resume is not implemented
        /// (docs/reverse-file-streaming.md), so nothing consumes this — it
        /// is carried because a consumer reporting a receipt should say
        /// what the machine said, not what this host does with it.
        var resumeToken: String?
    }

    /// Lists one page of a folder in the guest's share. Paths are
    /// relative to the guest's share root; "" is the root.
    func listFiles(path: String, cursor: Int? = nil,
                   completion: @escaping (Result<FileListing,
                                                 FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingListings[id] = observing(
            AgentIntegrationCapabilityNames.fileList, completion)
        armWatchdog(id: id, seconds: 15) { [weak self] reason in
            self?.pendingListings.removeValue(forKey: id)?(
                .failure(.init(code: "timeout", message: reason)))
        }
        session.sendFileList(id: id, path: path, cursor: cursor)
    }

    /// Lists one page of the guest's running processes. Symmetric with
    /// listFiles: the same request/listing shape, paged by a 1-based
    /// cursor the guest carries.
    func listProcesses(cursor: Int? = nil,
                       completion: @escaping (Result<ProcessListing,
                                                     FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingProcessListings[id] = observing(
            AgentIntegrationCapabilityNames.processList, completion)
        armWatchdog(id: id, seconds: 15) { [weak self] reason in
            self?.pendingProcessListings.removeValue(forKey: id)?(
                .failure(.init(code: "timeout", message: reason)))
        }
        session.sendProcessList(id: id, cursor: cursor)
    }

    /// Lists one page of the guest's installed software. Symmetric in
    /// meaning with listProcesses; cursor 1 rebuilds the guest's
    /// inventory — for "apps" that is a whole-volume sweep, ~4 s on the
    /// real machine, so the watchdog here is generous.
    func listSoftware(domain: String, cursor: Int? = nil,
                      completion: @escaping (Result<SoftwareListing,
                                                    FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingSoftwareListings[id] = observing(
            AgentIntegrationCapabilityNames.softwareList, completion)
        armWatchdog(id: id, seconds: 30) { [weak self] reason in
            self?.pendingSoftwareListings.removeValue(forKey: id)?(
                .failure(.init(code: "timeout", message: reason)))
        }
        session.sendSoftwareList(id: id, domain: domain, cursor: cursor)
    }

    /// The two drive verbs, one host->guest arrow: bring a process to the
    /// front, or ask it to quit.
    enum ProcessVerb { case front, quit }

    /// Drives a process on the guest by the PSN it named in a listing.
    /// The completion carries the guest's process.result — ok:false is a
    /// real answer (a stale PSN, a Toolbox refusal), not a transport
    /// failure, which arrives as .failure instead.
    func driveProcess(psnHigh: Int, psnLow: Int, verb: ProcessVerb,
                      completion: @escaping (Result<ProcessResult,
                                                    FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        // A guest that answers ok:false has still SERVED the family — it
        // understood the request and refused this particular process. Only
        // a .failure carrying a refusal code says the family is absent,
        // which is why the observation reads the Result and not `ok`.
        pendingProcessResults[id] = observing(
            verb == .quit
                ? AgentIntegrationCapabilityNames.processQuit
                : AgentIntegrationCapabilityNames.processFront,
            completion)
        armWatchdog(id: id, seconds: 15) { [weak self] reason in
            self?.pendingProcessResults.removeValue(forKey: id)?(
                .failure(.init(code: "timeout", message: reason)))
        }
        session.sendProcessDrive(id: id, psnHigh: psnHigh, psnLow: psnLow,
                                 verb: verb)
    }

    /// Moves or renames an item inside the share. One operation, because
    /// on this file system they are one operation.
    func moveFile(from: String, to: String, overwrite: Bool = false,
                  completion: @escaping (Result<FileResult,
                                                FileFailure>) -> Void) {
        sendChange(AgentIntegrationCapabilityNames.fileMove,
                   completion) { session, id in
            session.sendFileMove(FileMove(id: id, path: from, toPath: to,
                                          overwrite: overwrite ? true : nil))
        }
    }

    /// Moves an item to the Trash, and hands back the token that undoes it.
    func trashFile(path: String,
                   completion: @escaping (Result<FileResult,
                                                 FileFailure>) -> Void) {
        sendChange(AgentIntegrationCapabilityNames.fileTrash,
                   completion) { session, id in
            session.sendFileTrash(FileTrash(id: id, path: path))
        }
    }

    func restoreFile(trashedAs: String, to path: String,
                     completion: @escaping (Result<FileResult,
                                                   FileFailure>) -> Void) {
        sendChange(AgentIntegrationCapabilityNames.fileRestore,
                   completion) { session, id in
            session.sendFileRestore(FileRestore(id: id, trashedAs: trashedAs,
                                                toPath: path))
        }
    }

    func makeFolder(path: String,
                    completion: @escaping (Result<FileResult,
                                                  FileFailure>) -> Void) {
        sendChange(AgentIntegrationCapabilityNames.fileMkdir,
                   completion) { session, id in
            session.sendFileMkdir(FileMkdir(id: id, path: path))
        }
    }

    /// The shared shape of the four: control-plane, one answer, watchdog.
    ///
    /// Each carries its own family name, so the capability ledger learns
    /// these four from ORDINARY USE the way it learns the process and
    /// listing families. It matters because the ledger never probes a
    /// mutating family: without the observation, a guest that refused
    /// `file.move` with `not-implemented` would leave the row `unproven`
    /// forever and nothing would ever record that NOW-68K does not serve it.
    private func sendChange(
        _ family: String,
        _ completion: @escaping (Result<FileResult, FileFailure>) -> Void,
        _ emit: (Session, Int) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        /* `resolveChange` below renders an `ok:false` answer as a `.failure`
           carrying the guest's own code, so an ordinary refusal — `exists`,
           `not-found` — reaches the ledger as one too. That is safe rather
           than misleading only because the ledger moves a family to
           `unavailable` for the contract's typed I-do-not-implement-that
           codes alone; anything else leaves it `unproven` while recording
           what the guest said. A guest that refused a duplicate name must
           not read as a guest without the family. */
        pendingChanges[id] = observing(family, completion)
        armWatchdog(id: id, seconds: 20) { [weak self] reason in
            self?.pendingChanges.removeValue(forKey: id)?(
                .failure(.init(code: "timeout", message: reason)))
        }
        emit(session, id)
    }

    /// Pulls a file. `container` nil = the guest's fork rule decides.
    func getFile(path: String, container: String? = nil,
                 stagingDirectory: URL? = nil,
                 completion: @escaping (Result<FileDelivery,
                                               FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingFile = completion
        fileWatchdogId = id
        armWatchdog(id: id, seconds: 20) { [weak self] reason in
            self?.deliverFile(.failure(.init(code: "timeout",
                                             message: reason)))
        }
        session.sendFileGet(
            id: id, path: path, container: container,
            stagingDirectory: stagingDirectory
                ?? FileManager.default.temporaryDirectory)
    }

    /// Sends a file into the guest's share. `path` is the destination
    /// folder relative to the share root ("" is the root); the source is
    /// any file the human picked, since a share bounds what the other
    /// machine may reach unbidden, not what we deliberately send.
    /// Completion fires when the guest confirms the file is written.
    func putFile(name: String, into path: String, container: String,
                 bytes: Data, fileType: String? = nil,
                 creator: String? = nil, modified: Int? = nil,
                 overwrite: Bool = false,
                 completion: @escaping (Result<Void, FileFailure>) -> Void) {
        putFileWithReceipt(
            name: name, into: path, container: container, bytes: bytes,
            fileType: fileType, creator: creator, modified: modified,
            overwrite: overwrite
        ) { result in
            completion(result.map { _ in () })
        }
    }

    /// The approval lane needs the same completion boundary plus the local
    /// request identity and time that back its delivery receipt.
    func putFileWithReceipt(
        name: String,
        into path: String,
        container: String,
        bytes: Data,
        fileType: String? = nil,
        creator: String? = nil,
        modified: Int? = nil,
        overwrite: Bool = false,
        completion: @escaping (Result<PutReceipt, FileFailure>) -> Void
    ) {
        let checksum = TransferIdentity.crc32(bytes)
        startPut(
            name: name, into: path, container: container,
            byteCount: bytes.count, crc32: checksum,
            fileType: fileType, creator: creator, modified: modified,
            createParents: true, overwrite: overwrite, completion: completion
        ) { [weak session] offer in
            session?.sendFileOffer(
                offer, bytes: bytes, crc32: checksum)
        }
    }

    /// V0.5's upload lane uses the same wire state machine, but bytes stay in
    /// the private staged file and are read one bulk frame at a time.
    func putStagedFileWithReceipt(
        name: String,
        into path: String,
        container: String,
        source: OutboundFileSource,
        fileType: String? = nil,
        creator: String? = nil,
        modified: Int? = nil,
        overwrite: Bool = false,
        completion: @escaping (Result<PutReceipt, FileFailure>) -> Void
    ) {
        startPut(
            name: name, into: path, container: container,
            byteCount: source.byteCount, crc32: source.crc32,
            fileType: fileType, creator: creator, modified: modified,
            createParents: false, overwrite: overwrite, completion: completion
        ) { [weak session] offer in
            session?.sendFileOffer(offer, source: source)
        }
    }

    private func startPut(
        name: String,
        into path: String,
        container: String,
        byteCount: Int,
        crc32: UInt32,
        fileType: String?,
        creator: String?,
        modified: Int?,
        createParents: Bool,
        overwrite: Bool,
        completion: @escaping (Result<PutReceipt, FileFailure>) -> Void,
        offer: (FileOffer) -> Void
    ) {
        guard session != nil, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        guard pendingPut == nil else {
            completion(.failure(.init(
                code: "busy",
                message: "Another file transfer is already in progress")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingPut = completion
        putId = id
        putGuestReports = false
        putExpected = byteCount
        putExpectedCRC32 = crc32
        putRequiresCompletionEvidence = !createParents
        putStartedAt = Date()
        putLastProgressAt = nil
        putMaximumProgressGap = 0
        putAccepted = nil
        // Scaled to the work: a megabyte legitimately takes minutes on
        // hardware this old, and a fixed timeout would call a healthy
        // transfer dead. Progress feeds this watchdog, so the clock only
        // runs while nothing is moving.
        let grace = 20.0 + Double(byteCount) / 2048.0
        armWatchdog(id: id, seconds: grace,
                    tracksTraffic: false) { [weak self] reason in
            guard let self, self.pendingPut != nil else { return }
            self.session?.cancelOutbound()
            self.settlePut(.failure(self.putFailure(
                code: "timeout",
                message: reason,
                guestCleanup: "unknown-after-timeout")))
        }
        offer(FileOffer(
            id: id, name: name, path: path, container: container,
            bytes: byteCount, fileType: fileType, creator: creator,
            modified: modified, createParents: createParents,
            overwrite: overwrite,
            resumeToken: TransferIdentity.token(
                bytes: byteCount, crc32: crc32)))
    }

    private var pendingPut: ((Result<PutReceipt, FileFailure>) -> Void)?
    private var putId: Int?
    /// Set once the guest has reported its own received count for the
    /// put in flight. Until then the send counter is all there is.
    private var putGuestReports = false
    /// The offered size, so a guest report (which carries only what it
    /// has taken) can be turned into a fraction.
    private var putExpected = 0
    private var putExpectedCRC32: UInt32?
    private var putRequiresCompletionEvidence = false
    private var putStartedAt: Date?
    private var putLastProgressAt: Date?
    private var putMaximumProgressGap: TimeInterval = 0
    private var putAccepted: FileAccept?

    fileprivate func settlePut(_ result: Result<PutReceipt, FileFailure>) {
        let completion = pendingPut
        if let id = putId {
            clearWatchdog(id)
            session?.clearOutboundRequest(id: id)
        }
        pendingPut = nil
        putId = nil
        putGuestReports = false
        putExpected = 0
        putExpectedCRC32 = nil
        putRequiresCompletionEvidence = false
        putStartedAt = nil
        putLastProgressAt = nil
        putMaximumProgressGap = 0
        putAccepted = nil
        captureProgress = nil
        completion?(result)
    }

    private func putFailure(
        code: String,
        message: String,
        receiverConfirmedBytes: Int? = nil,
        guestCleanup: String
    ) -> FileFailure {
        let now = Date()
        let elapsed = max(
            0, now.timeIntervalSince(putStartedAt ?? now))
        let confirmed = receiverConfirmedBytes
            ?? (putGuestReports ? captureProgress?.received : nil)
        return .init(
            code: code,
            message: message,
            putEvidence: .init(
                totalBytes: putExpected,
                acceptedOffset: putAccepted?.have ?? 0,
                receiverConfirmedBytes: confirmed,
                elapsedMs: Int((elapsed * 1_000).rounded()),
                progressEvidence: putGuestReports
                    ? "guest-progress-before-failure"
                    : "no-guest-progress",
                maximumProgressGapMs: maximumPutGapMs(at: now),
                guestFreeBytesBefore: putAccepted?.freeBytes,
                guestReservedBytes: putAccepted?.reservedBytes,
                guestStaging: putAccepted?.staging,
                guestCleanup: guestCleanup))
    }

    private func maximumPutGapMs(at outcome: Date) -> Int? {
        guard putGuestReports,
              let lastActivity = putLastProgressAt ?? putStartedAt else {
            return nil
        }
        let gap = max(
            putMaximumProgressGap,
            max(0, outcome.timeIntervalSince(lastActivity)))
        return Int((gap * 1_000).rounded())
    }

    /// Which way the one transfer lane is pointing, or nil when it holds no
    /// FILE transfer.
    ///
    /// Read by a caller that must not guess. `cancelFile()` below is a void
    /// method that does nothing at all when nothing is in flight, which is
    /// right for a button — a person can see the bar is gone — and is not
    /// enough for an agent, which has to be able to tell "stopped it" from
    /// "there was nothing to stop" and report which.
    ///
    /// It answers about the FILE lane only. A capture or a live stream holds
    /// the same one-wide lane and neither is ended by `file.cancel`;
    /// `isCapturePending` and `activeStreamId` are their own answers.
    enum FileTransferInFlight {
        /// A file this host is pushing to the guest.
        case outgoing
        /// A file this host is pulling off it.
        case incoming
    }

    var fileTransferInFlight: FileTransferInFlight? {
        if pendingPut != nil { return .outgoing }
        if pendingFile != nil { return .incoming }
        return nil
    }

    /// Abandons the file transfer; settles locally for the same reason
    /// cancelCapture does.
    func cancelFile() {
        // An outbound transfer settles HERE rather than waiting for the
        // wire: if it is stalled, the send that would notice the
        // cancellation is exactly the one that is not completing.
        if pendingPut != nil {
            session?.cancelOutbound()
            settlePut(.failure(putFailure(
                code: "cancelled",
                message: "Cancelled",
                guestCleanup: "unknown-after-cancel")))
            return
        }
        guard pendingFile != nil else { return }
        session?.cancelFile()
        deliverFile(.failure(.init(code: "cancelled",
                                   message: "Download cancelled")))
    }

    /// Requests die of silence, not of duration: any evidence of life
    /// (an answer, a transfer's begin, a chunk of bulk) resets the clock,
    /// so a slow transfer survives and a wedged guest does not.
    private struct Watchdog {
        var lastActivity: Date
        var seconds: TimeInterval
        /// False for pushes: see armWatchdog.
        var tracksTraffic: Bool = true
        /// How this request fails. Held here so expiry lives in ONE
        /// place: a test seam that re-derived it per request kind
        /// silently stopped covering the newest kind.
        var expire: (String) -> Void
        var task: Task<Void, Never>?
    }
    private var watchdogs: [Int: Watchdog] = [:]

    /// `tracksTraffic` decides what counts as this request being alive.
    /// For anything awaiting an answer, inbound bytes are evidence. For
    /// a push they are not: the peer can answer pings perfectly while
    /// the transfer it is receiving has stalled, and a watchdog reset by
    /// heartbeats would never fire. Those are touched by their own
    /// progress instead.
    private func armWatchdog(id: Int, seconds: TimeInterval,
                             tracksTraffic: Bool = true,
                             expire: @escaping (String) -> Void) {
        clearWatchdog(id)
        watchdogs[id] = Watchdog(lastActivity: Date(), seconds: seconds,
                                 tracksTraffic: tracksTraffic,
                                 expire: expire, task: nil)
        watchdogs[id]?.task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let dog = self.watchdogs[id] else { return }
                let remaining = dog.lastActivity
                    .addingTimeInterval(dog.seconds).timeIntervalSinceNow
                if remaining <= 0 {
                    self.watchdogs[id] = nil
                    expire(self.silenceReason())
                    return
                }
                try? await Task.sleep(
                    nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    /// Marks one request as still making progress, for the watchdogs
    /// that do not take the peer's chatter as evidence.
    private func touchWatchdog(_ id: Int) {
        watchdogs[id]?.lastActivity = Date()
    }

    private func touchWatchdogs() {
        let now = Date()
        for id in watchdogs.keys where watchdogs[id]?.tracksTraffic == true {
            watchdogs[id]?.lastActivity = now
        }
    }

    /// Test seam: expire every armed watchdog immediately, so a test can
    /// exercise the timeout path without sleeping through it.
    func expireWatchdogsForTesting() {
        let expiring = watchdogs
        watchdogs = [:]
        let reason = silenceReason()
        for (_, dog) in expiring {
            dog.task?.cancel()
            dog.expire(reason)
        }
    }

    private func clearWatchdog(_ id: Int) {
        watchdogs.removeValue(forKey: id)?.task?.cancel()
    }

    /// Distinguishes "busy" from "gone" using heartbeat freshness — the
    /// two cases a human would act on differently.
    private func silenceReason() -> String {
        let quiet = health.map {
            Date().timeIntervalSince($0.lastTraffic)
        } ?? .greatestFiniteMagnitude
        return quiet > 20
            ? "The classic Mac stopped answering — it may be showing a "
              + "dialog or otherwise busy."
            : "The classic Mac did not answer in time."
    }

    private var pendingListings:
        [Int: (Result<FileListing, FileFailure>) -> Void] = [:]
    private var pendingProcessListings:
        [Int: (Result<ProcessListing, FileFailure>) -> Void] = [:]
    private var pendingProcessResults:
        [Int: (Result<ProcessResult, FileFailure>) -> Void] = [:]
    private var pendingSoftwareListings:
        [Int: (Result<SoftwareListing, FileFailure>) -> Void] = [:]
    private var pendingFile:
        ((Result<FileDelivery, FileFailure>) -> Void)?
    private var pendingChanges:
        [Int: (Result<FileResult, FileFailure>) -> Void] = [:]

    fileprivate func resolveChange(_ result: FileResult) {
        clearWatchdog(result.id)
        guard let completion = pendingChanges.removeValue(forKey: result.id)
        else { return }
        if result.ok {
            completion(.success(result))
        } else {
            completion(.failure(.init(
                code: result.code ?? "io-error",
                message: result.reason ?? result.code ?? "It did not work")))
        }
    }

    fileprivate func resolveListing(_ listing: FileListing) {
        clearWatchdog(listing.id)
        pendingListings.removeValue(forKey: listing.id)?(.success(listing))
    }

    fileprivate func resolveProcessListing(_ listing: ProcessListing) {
        clearWatchdog(listing.id)
        pendingProcessListings.removeValue(forKey: listing.id)?(
            .success(listing))
    }

    fileprivate func resolveSoftwareListing(_ listing: SoftwareListing) {
        clearWatchdog(listing.id)
        pendingSoftwareListings.removeValue(forKey: listing.id)?(
            .success(listing))
    }

    fileprivate func resolveProcessResult(_ result: ProcessResult) {
        clearWatchdog(result.id)
        pendingProcessResults.removeValue(forKey: result.id)?(
            .success(result))
    }

    fileprivate func failFile(_ refuse: FileRefuse) {
        let failure = FileFailure(code: refuse.code,
                                  message: refuse.reason ?? refuse.code)
        clearWatchdog(refuse.id)
        if let completion = pendingListings.removeValue(forKey: refuse.id) {
            completion(.failure(failure))
            return
        }
        if let completion = pendingChanges.removeValue(forKey: refuse.id) {
            completion(.failure(failure))
            return
        }
        if pendingPut != nil {
            settlePut(.failure(putFailure(
                code: failure.code,
                message: failure.message,
                guestCleanup: "unknown-before-accept")))
            return
        }
        let completion = pendingFile
        pendingFile = nil
        captureProgress = nil
        completion?(.failure(failure))
    }

    fileprivate func deliverFile(
        _ result: Result<FileDelivery, FileFailure>) {
        let completion = pendingFile
        pendingFile = nil
        if let id = fileWatchdogId { clearWatchdog(id) }
        fileWatchdogId = nil
        captureProgress = nil
        completion?(result)
    }

    /// Asks the guest for a screen capture. Completion fires with the decoded
    /// image plus the measurements, or a human-readable failure.
    func requestCapture(depth: Int?, tuning: CaptureTuning = .init(),
                        completion: @escaping (Result<CaptureDelivery,
                                                      CaptureFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingCapture = completion
        captureWatchdogId = id
        armWatchdog(id: id, seconds: 20) { [weak self] reason in
            self?.deliverCapture(.failure(.init(message: reason)))
        }
        session.sendCaptureRequest(id: id, depth: depth, tuning: tuning)
    }

    /// Asks the guest to front a process and capture just its window. The
    /// reply is an ordinary capture transfer, so it settles the same
    /// pendingCapture path a plain requestCapture does — only the request
    /// message and the longer wait (the guest fronts and lets the target
    /// repaint first) differ.
    func requestProcessShot(psnHigh: Int, psnLow: Int, depth: Int?,
                            completion: @escaping (Result<CaptureDelivery,
                                                          CaptureFailure>)
                                -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingCapture = completion
        captureWatchdogId = id
        armWatchdog(id: id, seconds: 25) { [weak self] reason in
            self?.deliverCapture(.failure(.init(message: reason)))
        }
        session.sendProcessShot(id: id, psnHigh: psnHigh, psnLow: psnLow,
                                depth: depth)
    }

    /// How far along an in-flight transfer is, for the panel's progress bar.
    struct CaptureProgress: Equatable, Sendable {
        var received: Int
        var expected: Int

        var fraction: Double {
            expected > 0 ? min(1, Double(received) / Double(expected)) : 0
        }
    }

    @Published private(set) var captureProgress: CaptureProgress?

    /// Guest-initiated captures land here — decoded, ready for whichever
    /// module cares. The request path never uses this; a solicited capture
    /// settles its own completion instead.
    let pushedCaptures = PassthroughSubject<CaptureDelivery, Never>()

    /// Live-stream frames. Same decode as any capture; the stream id is
    /// what routed them here instead of pushedCaptures.
    let streamFrames = PassthroughSubject<CaptureDelivery, Never>()

    /// Non-nil while a stream bracket is open.
    @Published private(set) var activeStreamId: Int?

    /// **Who asked for the bracket that is open**, nil when none is.
    ///
    /// The bracket has always been host-owned and has never recorded which of
    /// the three ways it was opened, because for two of them nobody needed to
    /// know: a person who clicks Start Streaming is looking at the page that
    /// says so, and a guest that asked is the machine on the screen. An agent
    /// can now open one too, and both questions that follow need this. The
    /// person at the host has to be able to tell an agent's stream from their
    /// own — a live view that started by itself is otherwise indistinguishable
    /// from a fault — and a bracket that outlives whoever opened it can only
    /// be ended against the answer to "who opened it".
    ///
    /// It is set beside `activeStreamId` and cleared with it, everywhere,
    /// because an origin without a bracket is a claim about a stream that is
    /// not running.
    @Published private(set) var streamOrigin: AgentIntegrationStreamOrigin?

    /// What the bracket was opened with, for whoever has to describe it. The
    /// depth is what was ASKED for — the guest answers with what its screen
    /// actually is, and that arrives on the frame.
    @Published private(set) var streamDepth: Int?
    @Published private(set) var streamMinIntervalMs: Int?
    /// When the open bracket was opened. Nil with the rest of them.
    @Published private(set) var streamOpenedAt: Date?

    /// The reason the guest gave when IT ended the stream ("capture
    /// failed"); nil after a host-requested stop.
    @Published private(set) var streamEndReason: String?

    /// **Whether the guest has ever answered the open bracket with a frame.**
    ///
    /// `stream.start`, `stream.stop` and `stream.refresh` all carry the
    /// bracket's one id, so an `error` bearing that id says only "one of the
    /// three", and which one decides both what may be recorded about the
    /// machine and whether the bracket dies. A frame is the proof that
    /// `stream.start` was served: before one, the refusal can only be of the
    /// open itself; after one, the family is answered and a later refusal
    /// belongs to whichever request came second.
    private var streamAccepted = false

    /// Whether a stop has been asked for and not yet answered. A refusal
    /// while this is set is a refused STOP, which ends the bracket now
    /// instead of on the five-second fallback — but it is not evidence
    /// about `stream.start`, which this guest plainly served.
    private var streamStopRequested = false

    /// Opens a stream bracket. Frames then arrive on streamFrames until
    /// stopStream() or the guest's own stream.stopped.
    ///
    /// **The origin is not defaulted**, deliberately: every caller states who
    /// it is opening on behalf of, so that a fourth way to open one cannot
    /// arrive silently labelled as the person at the host.
    ///
    /// Returns the bracket's id, or nil when there was nothing to open — a
    /// caller that has to report which happened needs that, and a person's
    /// button does not have to read it. It used to return nothing and the two
    /// silent failures (no connection, lane already taken) were
    /// indistinguishable from success.
    @discardableResult
    func startStream(depth: Int, minIntervalMs: Int? = nil,
                     tuning: CaptureTuning = .init(),
                     origin: AgentIntegrationStreamOrigin) -> Int? {
        guard let session, case .connected = state,
              activeStreamId == nil else { return nil }
        let id = nextCommandId
        nextCommandId += 1
        activeStreamId = id
        streamOrigin = origin
        streamDepth = depth
        streamMinIntervalMs = minIntervalMs
        streamOpenedAt = Date()
        streamEndReason = nil
        streamAccepted = false
        streamStopRequested = false
        session.beginStream(id: id, depth: depth,
                            minIntervalMs: minIntervalMs, tuning: tuning)
        return id
    }

    /// Asks the guest to send its next stream frame whole.
    func refreshStream() {
        guard let id = activeStreamId else { return }
        session?.requestKeyframe(id: id)
    }

    func stopStream() {
        guard let id = activeStreamId else { return }
        streamStopRequested = true
        session?.requestStreamStop(id: id)
        // Self-heal: a guest that never answers (dead app, dead wire the
        // socket hasn't noticed) must not wedge the bracket open forever.
        stopFallback?.cancel()
        stopFallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self,
                  self.activeStreamId == id else { return }
            self.forgetStream(
                reason: AgentIntegrationStreamFailure.unacknowledgedStop)
        }
    }

    /// A frame on the open bracket: the machine served `stream.start`.
    ///
    /// Recorded on the FIRST one only, and recorded at all because the
    /// bracket has no completion for `observing(_:)` to wrap — the family
    /// whose answer arrives as a stream of frames rather than as a reply is
    /// exactly the one that would otherwise read `unproven` against a guest
    /// that has been streaming to the screen for a minute.
    private func noteStreamFrame(_ delivery: CaptureDelivery) {
        if !streamAccepted {
            streamAccepted = true
            observeFamily(AgentIntegrationCapabilityNames.streamStart,
                          served: true)
        }
        streamFrames.send(delivery)
    }

    fileprivate func streamEnded(_ stopped: StreamStopped) {
        guard stopped.id == activeStreamId else { return }
        stopFallback?.cancel()
        stopFallback = nil
        forgetStream(reason: stopped.reason)
        captureProgress = nil
    }

    /// Drops every field that describes the open bracket, together.
    ///
    /// One place rather than three, because the three ways a bracket ends
    /// used to clear `activeStreamId` and nothing else — which was correct
    /// while it was the only field, and is the shape of the bug the moment it
    /// is not. An origin left behind describes a stream that is not running.
    private func forgetStream(reason: String?) {
        activeStreamId = nil
        streamOrigin = nil
        streamDepth = nil
        streamMinIntervalMs = nil
        streamOpenedAt = nil
        streamEndReason = reason
        streamAccepted = false
        streamStopRequested = false
    }

    /// **An `error` bearing the open bracket's id.**
    ///
    /// The bracket is opened optimistically — `startStream` sets
    /// `activeStreamId` before the guest has said anything — and its id is
    /// held by no pending map, so until this existed the one answer a guest
    /// without the stream family can give went nowhere: `recordGuestError`
    /// routed six maps, matched none of them, and left the bracket open on a
    /// stream that was never running. The 68K guest refuses `stream.start`
    /// every time (`send_error_reply`, now-guest-68k/src/core/wire68.c), so
    /// this is not an edge case on that machine; it is what happens.
    ///
    /// Returns whether the bracket was closed, which is the caller's test for
    /// "somebody was actually answered".
    private func refuseStream(_ problem: ErrorMessage) -> Bool {
        /* Before the first frame the id can only be the open's, so this is
           evidence about `stream.start` and is written down as such. After
           one it is a refusal of a stop or a refresh — the machine served
           the family, and recording a "no" then would be a claim about a
           guest that is streaming as it is made. */
        if !streamAccepted {
            observeFamily(AgentIntegrationCapabilityNames.streamStart,
                          served: false, code: problem.code,
                          message: problem.message)
        }
        /* A refused REFRESH is the one case that leaves the bracket alone:
           the frames are still coming, and tearing down a working stream
           because the guest cannot serve a keyframe on demand would be a
           worse bug than the one this function fixes. */
        guard !streamAccepted || streamStopRequested else { return false }
        stopFallback?.cancel()
        stopFallback = nil
        /* The guest's own words, not ours. "no answer to stop" was the only
           reason a caller could ever read here, and it is untrue of a
           machine that answered immediately and said why. */
        forgetStream(reason: problem.message)
        captureProgress = nil
        return true
    }

    /// The guest asked for a stream: same bracket, host-owned. Accept
    /// unless the lane is taken.
    fileprivate func guestRequestedStream(_ request: StreamRequest,
                                          from session: Session) {
        // The stream lane is host-wide, so a guest that is not the active
        // one is refused here rather than at the lane: accepting would
        // point the bracket at a different connection than the frames.
        // The refusal goes to the ASKER, whichever it was.
        guard activeStreamId == nil, session === self.session else {
            session.sendError(code: "stream-busy",
                              message: "a stream or transfer is active")
            return
        }
        startStream(depth: request.depth, origin: .guest)
    }

    fileprivate func streamSessionClosed() {
        guard activeStreamId != nil else { return }
        stopFallback?.cancel()
        stopFallback = nil
        forgetStream(reason: "connection lost")
    }

    private var stopFallback: Task<Void, Never>?

    /// Abandons the capture. Cancel means "stop waiting", so it settles
    /// the request locally whether or not a transfer ever started — a
    /// guest stuck before capture.begin has nothing to cancel on the
    /// wire, and that must not leave the button dead.
    func cancelCapture() {
        guard pendingCapture != nil else { return }
        session?.cancelCapture()
        deliverCapture(.failure(.init(message: "Capture cancelled")))
    }

    /// A decoded capture and WHICH machine sent it.
    ///
    /// The sender was previously implied: with one guest there was only one
    /// answer, and with several, a solicited capture still comes from the
    /// machine we asked. A PUSH does not — a guest nobody is driving may
    /// send a screenshot whenever it likes — and without this the
    /// Screenshots module filed it under whoever happened to be active.
    ///
    /// **No contract field was needed and none was added.** Which machine
    /// sent a message is not something the message has to say: it arrived
    /// on that machine's socket, and the host already knows whose socket
    /// that is (`Session.guestKey`, set at hello). Putting a name in the
    /// payload would have created a second, weaker answer to a question the
    /// connection already answers exactly — and one a guest could get
    /// wrong. Both guests are therefore unchanged by this, and neither
    /// differs from the other.
    struct CaptureDelivery {
        var image: CGImage
        var format: CaptureFormat
        var transferMs: Int
        var wireBytes: Int
        /// What the sender calls itself, for anything a person reads.
        var guestName: String = Session.unnamedGuest
        /// The sender's identity, for routing. Nil only for a capture
        /// decoded before a hello, which cannot happen on this path.
        var guestKey: GuestKey?
    }

    private var pendingCapture:
        ((Result<CaptureDelivery, CaptureFailure>) -> Void)?

    /// Whether a capture is already on its way here.
    ///
    /// Read by the agent capture lane, which must not start one while the
    /// person at the machine is waiting on theirs: `requestCapture` REPLACES
    /// `pendingCapture`, so a second request would leave the first
    /// completion — the Screenshots button's — never called. The panel
    /// guards this with its own `isCapturing`; a second initiator needs the
    /// fact from the wire's owner rather than from one pane's state.
    var isCapturePending: Bool { pendingCapture != nil }
    private var captureWatchdogId: Int?
    private var fileWatchdogId: Int?

    fileprivate func deliverCapture(
        _ result: Result<CaptureDelivery, CaptureFailure>) {
        let completion = pendingCapture
        pendingCapture = nil
        if let id = captureWatchdogId { clearWatchdog(id) }
        captureWatchdogId = nil
        captureProgress = nil
        completion?(result)
    }

    // MARK: - Scenes

    /// One walk of the other Mac, as the guest described it.
    ///
    /// The bytes are handed on **undecoded** on purpose. The IR gate's rule
    /// is read the version, refuse an unknown major, THEN decode
    /// (`mirror/docs/IR-V1.md`), and the only way this layer can obey it is
    /// by not decoding at all: it carries the envelope's `irVersion` beside
    /// the body and lets `NOWSceneCodec.decode` — the one place that
    /// implements the order — do both steps. A convenience that parsed here
    /// and passed a document on would have moved the gate behind a parse
    /// while looking like an improvement.
    ///
    /// It also keeps absence intact for free: nothing here reads a plane, so
    /// nothing here can turn an absent one into an empty one.
    struct SceneDelivery {
        /// UTF-8 JSON, exactly the bytes the guest's encoder produced.
        var document: Data
        /// From `scene.begin`, not from the body.
        var irVersion: Int
        var seq: Int?
        var capturedAt: Double?
        var source: String?
        /// How long the guest spent walking, by its own clock.
        var walkMs: Int?
        var transferMs: Int
        var guestName: String = Session.unnamedGuest
        var guestKey: GuestKey?
    }

    /// A scene that could not be had. `message` is written for a human — it
    /// lands on the Mirror page.
    struct SceneFailure: Error {
        var message: String
        /// True when the GUEST declined: it was asked, it answered, and the
        /// answer was no. False for everything this side decided (no Mac,
        /// lane busy, silence, a short transfer).
        ///
        /// The page needs the difference. A refusal is evidence the scene
        /// plane is there and answering, and asking again in a moment is a
        /// sensible thing to suggest; a local refusal says nothing about
        /// the other Mac at all.
        var refusedByGuest: Bool = false
    }

    private var pendingScene:
        ((Result<SceneDelivery, SceneFailure>) -> Void)?
    private var sceneWatchdogId: Int?

    /// Whether a scene is already on its way here.
    var isScenePending: Bool { pendingScene != nil }

    /// **The one transfer lane, as seen from this side.**
    ///
    /// The contract allows one bulk transfer at a time and the guest
    /// enforces it too (`serve_scene` refuses with "a transfer is already in
    /// flight"). Asking anyway would work — the refusal is polite and
    /// cheap — but it would cost a round trip to be told what this side
    /// already knows, and on the file lane it would land a refusal in the
    /// middle of somebody's download.
    ///
    /// A stream is included because a bracket owns the lane for its whole
    /// life, not just while a frame is moving.
    private var transferLaneHolder: String? {
        if activeStreamId != nil { return "a live stream is running" }
        if isCapturePending { return "a screenshot is on its way" }
        switch fileTransferInFlight {
        case .outgoing: return "a file is going to the Mac"
        case .incoming: return "a file is coming from the Mac"
        case nil: break
        }
        if isScenePending { return "a scene is already on its way" }
        return nil
    }

    /// Asks the connected Mac to walk its screen and send back one scene.
    ///
    /// Shaped exactly like `requestCapture` — one request out, one transfer
    /// back, one completion — with one deliberate difference: this **refuses
    /// rather than replaces**. `requestCapture` overwrites its pending
    /// completion because the Screenshots panel guards itself and the last
    /// ask is the one a person is looking at. A scene has more than one
    /// possible caller (a person today, an agent when the projection row
    /// exists), and a second caller silently orphaning the first one's
    /// completion is how a page waits forever.
    func requestScene(staleAfterMs: Int? = nil,
                      tuning: CaptureTuning = .init(),
                      completion: @escaping (Result<SceneDelivery,
                                                    SceneFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(message: "No Mac is connected")))
            return
        }
        if let holder = transferLaneHolder {
            completion(.failure(.init(
                message: "The Mac can move one thing at a time and "
                    + "\(holder). Ask again when it is done.")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingScene = completion
        sceneWatchdogId = id
        /* A walk is not a screen grab: it visits every process and window
           through the extension, on a machine whose whole job used to be
           one thing at a time. 20s matches the capture lane, and the
           watchdog dies of SILENCE rather than duration anyway, so a slow
           walk that is still sending survives it. */
        armWatchdog(id: id, seconds: 20) { [weak self] reason in
            self?.deliverScene(.failure(.init(message: reason)))
        }
        session.sendSceneRequest(id: id, staleAfterMs: staleAfterMs,
                                 tuning: tuning)
    }

    fileprivate func deliverScene(
        _ result: Result<SceneDelivery, SceneFailure>) {
        let completion = pendingScene
        pendingScene = nil
        if let id = sceneWatchdogId { clearWatchdog(id) }
        sceneWatchdogId = nil
        completion?(result)
    }

    fileprivate func noteCaptureProgress(_ progress: CaptureProgress?) {
        captureProgress = progress
        touchWatchdogs()              /* bytes are evidence of life */
    }

    private func resolveCommand(_ result: CommandResult) {
        if let completion = pendingCommands.removeValue(forKey: result.id) {
            completion(result)
        }
    }

    private func resolveCensus(_ report: CensusReport) {
        if let completion = pendingCensus.removeValue(forKey: report.id) {
            completion(report)
        }
    }

    /// Settles everything outstanding. The invariant: a stored completion
    /// is resolved or failed, never dropped — a dropped completion is a
    /// UI that stays busy forever.
    /// An `error` from the guest, surfaced rather than swallowed.
    ///
    /// With two guests of very different completeness, "I do not
    /// implement that" is ordinary traffic and not an incident. What it
    /// must never be is indistinguishable from silence: if the error
    /// carries the id of something a caller is waiting on, that caller is
    /// owed the refusal now, with its reason, instead of a timeout later
    /// with none.
    private func recordGuestError(_ problem: ErrorMessage) {
        lastGuestError = problem
        guard let id = problem.id else { return }
        // EVERY waiter, not just command waiters. The ids are drawn from
        // one sequence and an `error` is the contract's answer to any
        // request the peer does not implement, so whichever kind of
        // request is holding this id is the one owed the refusal. Routing
        // only commands would leave a file or process listing sitting on
        // its 15s watchdog for a question that was already answered.
        //
        // The first version of this routed three of the six maps, which
        // read as "every waiter" until a guest that implements neither
        // `software.list` nor `process.quit` dialled in: those refusals
        // still cost their full watchdog and arrived with no reason, so a
        // companion tool could not tell "not implemented" from "the
        // PowerBook is wedged". Any pending map added later belongs here
        // too — that is what makes an incomplete guest workable.
        let failure = FileFailure(code: problem.code,
                                  message: problem.message)
        var routed = false
        if let waiting = pendingCommands.removeValue(forKey: id) {
            routed = true
            waiting(CommandResult(id: id, ok: false, output: nil,
                                  error: .init(code: problem.code,
                                               message: problem.message)))
        }
        if let waiting = pendingListings.removeValue(forKey: id) {
            routed = true
            waiting(.failure(failure))
        }
        if let waiting = pendingProcessListings.removeValue(forKey: id) {
            routed = true
            waiting(.failure(failure))
        }
        if let waiting = pendingProcessResults.removeValue(forKey: id) {
            routed = true
            waiting(.failure(failure))
        }
        if let waiting = pendingSoftwareListings.removeValue(forKey: id) {
            routed = true
            waiting(.failure(failure))
        }
        if let waiting = pendingChanges.removeValue(forKey: id) {
            routed = true
            waiting(.failure(failure))
        }
        if let waiting = pendingCensus.removeValue(forKey: id) {
            routed = true
            waiting(CensusReport(id: id, probe: "", outcome: "failed",
                                 rows: [], more: false,
                                 note: "[\(problem.code)] \(problem.message)"))
        }
        if let waiting = pendingExec.removeValue(forKey: id) {
            routed = true
            /* A guest too old to know exec.request answers `error`, and this
               is the line that turns that into an immediate, readable
               refusal instead of a 60-second silence. Exactly the case the
               comment above was written for, arriving on schedule. */
            waiting.completion(ExecOutcome(
                text: waiting.text, ok: false, code: problem.code,
                message: problem.message, gap: waiting.gap))
        }
        if id == activeStreamId, refuseStream(problem) {
            routed = true
        }
        /* The case this exists for is the ordinary one: NOW-68K implements
           almost none of the contract and answers `error` for `scene.request`
           the moment it is asked. Without this line the Mirror page would
           spend twenty seconds looking like a wedged Mac to say what the
           guest said instantly. */
        if id == sceneWatchdogId, pendingScene != nil {
            routed = true
            deliverScene(.failure(.init(
                message: "\(problem.message) [\(problem.code)]",
                refusedByGuest: true)))
        }
        // Only now, and only if somebody was actually answered. Clearing
        // the watchdog first looked tidier and was a trap: a waiter this
        // function forgets to route would then have neither an answer nor
        // a timeout, and would hang forever rather than merely slowly.
        // The mutation that removed three of these lines proved it by
        // hanging the suite instead of failing it.
        if routed { clearWatchdog(id) }
    }

    private func failAllPending(_ reason: String) {
        let commands = pendingCommands
        pendingCommands = [:]
        for (id, completion) in commands {
            completion(CommandResult(
                id: id, ok: false, output: nil,
                error: .init(code: "disconnected", message: reason)))
        }
        let execs = pendingExec
        pendingExec = [:]
        for (_, pending) in execs {
            pending.completion(ExecOutcome(
                text: pending.text, ok: false, code: "disconnected",
                message: reason, gap: pending.gap))
        }
        let census = pendingCensus
        pendingCensus = [:]
        for (id, completion) in census {
            completion(CensusReport(
                id: id, probe: "", outcome: "failed", rows: [],
                more: false, cursor: nil, total: nil, note: reason))
        }
        let listings = pendingListings
        pendingListings = [:]
        for (_, completion) in listings {
            completion(.failure(.init(code: "disconnected",
                                      message: reason)))
        }
        let changes = pendingChanges
        pendingChanges = [:]
        for (_, completion) in changes {
            completion(.failure(.init(code: "disconnected",
                                      message: reason)))
        }
        // Every armed request carries its own way of failing, so this
        // does not have to know the kinds — it knew three of the four
        // and a put could outlive its answer forever.
        let dogs = watchdogs
        watchdogs = [:]
        for (_, dog) in dogs {
            dog.task?.cancel()
            dog.expire(reason)
        }
        if let file = pendingFile {
            pendingFile = nil
            file(.failure(.init(code: "disconnected", message: reason)))
        }
        if pendingPut != nil {
            settlePut(.failure(putFailure(
                code: "disconnected",
                message: reason,
                guestCleanup: "unknown-after-disconnect")))
        }
        deliverCapture(.failure(.init(message: reason)))
        deliverScene(.failure(.init(message: reason)))
    }

    private func listenerStateChanged(_ nwState: NWListener.State) {
        switch nwState {
        case .ready:
            note("Listening on port \(boundPort ?? 0)")
            if case .connected = state { return }
            state = .listening(port: boundPort ?? 0)
        case .failed(let error):
            state = .failed(error.localizedDescription)
            note("Listener failed: \(error.localizedDescription)")
        default:
            break
        }
    }

    /// Names the connection a callback arrived on.
    ///
    /// A Session reaches its owner only through the closures it is built
    /// with — and those closures are built BEFORE the Session exists, so
    /// until now they could not say which connection they belonged to and
    /// reached for `session`, meaning "the active one". With one guest
    /// those were the same object and the difference was invisible. With
    /// two they are not, and the difference is the whole slice: an answer
    /// must go back down the socket that asked, and an answer to a
    /// request we never sent must not settle another guest's waiter.
    private final class SessionRef { weak var session: Session? }

    private func accept(_ connection: NWConnection) {
        let origin = SessionRef()
        /* Host-observed, before a byte of the guest's own account of
           itself has been read. This is the fact the machine registry
           anchors on precisely because the guest had no say in it. */
        let address = GuestAddress(endpoint: connection.endpoint)
        /// True when this connection is the one the request-shaped API is
        /// driving — so its answers are the ones our waiters are owed.
        func fromActive() -> Bool {
            origin.session != nil && origin.session === session
        }
        let newSession = Session(
            connection: connection, identity: identity, timing: timing,
            pacing: pacing, address: address,
            admit: { [weak self] _ in
                guard let self else { return "the host is shutting down" }
                /* No identity refusal remains. It used to refuse a hello
                   name already connected, which meant two Macs sharing a
                   name were one guest and the second was turned away —
                   and behind an emulator, where every guest arrives from
                   the loopback address, an address test would repeat that
                   mistake in a new place. Identity is per connection now,
                   so an arriving guest cannot collide with one already
                   here; a duplicate row left by a half-dead socket is
                   cleared by the idle timeout, which is a strictly better
                   failure than refusing a real second machine.

                   The limit is the one refusal left, and it says its
                   number so a human can tell it from anything else. */
                if self.sessions.count >= self.maxGuests {
                    return "too many guests connected "
                        + "(\(self.maxGuests))"
                }
                return nil
            },
            identify: { [weak self] hello, address in
                guard let self else {
                    return GuestKey(machine: GuestID("guest")!,
                                    session: UUID())
                }
                return self.mintSessionKey(hello: hello, address: address)
            },
            onActive: { [weak self] activated in
                guard let self, let key = activated.guestKey else { return }
                self.pending.removeAll { $0 === activated }
                self.sessions[key] = activated
                /* First in is the one being driven; a later arrival is
                   served but does not steal the console out from under
                   whoever is using it. */
                if self.activeKey == nil { self.activeKey = key }
                self.publishActive()
            },
            onLog: { [weak self] text, area, level in
                self?.note(text, area: area, level: level)
            },
            /* Health is per guest and kept for all of them — a guest
               nobody is driving is still connected, still pinging, and
               still worth being able to look at. Only the active one is
               published as `health`. */
            onHealth: { [weak self] health in
                guard let self else { return }
                if let key = origin.session?.guestKey {
                    /* The roster carries a COPY of the parts of this record
                       it displays, so a field that changes after connect
                       has to be pushed into it. Only agent access does:
                       name, version and build are settled at hello and the
                       rest of this record never reaches a roster row.

                       Deliberately not an unconditional publishActive() —
                       this closure runs on every frame, bulk ones included,
                       so rebuilding the array here would do it thousands of
                       times during a screen stream to carry a value that
                       changes when somebody clicks a radio button. */
                    let stale = self.healthByGuest[key]?.guestAgentAccess
                    self.healthByGuest[key] = health
                    if stale != health?.guestAgentAccess {
                        self.publishActive()
                    }
                    guard key == self.activeKey else { return }
                }
                self.health = health
            },
            /* Everything from here to onStreamRequest is an ANSWER to a
               request, and the requests only ever go to the active
               session. An answer from another connection is therefore
               either a late frame from a guest we switched away from or a
               confused guest answering an id it was never given; both
               would settle a waiter that belongs to somebody else, so
               both are dropped. */
            onCommandResult: { [weak self] result in
                guard fromActive() else { return }
                self?.resolveCommand(result)
            },
            onExecOutput: { [weak self] output in
                guard fromActive() else { return }
                self?.resolveExecOutput(output)
            },
            onExecResult: { [weak self] result in
                guard fromActive() else { return }
                self?.resolveExecResult(result)
            },
            onGuestError: { [weak self] problem in
                guard fromActive() else { return }
                self?.recordGuestError(problem)
            },
            onCensusReport: { [weak self] report in
                guard fromActive() else { return }
                self?.resolveCensus(report)
            },
            onCapture: { [weak self] result in
                guard fromActive() else { return }
                self?.deliverCapture(result)
            },
            onCaptureProgress: { [weak self] progress in
                guard fromActive() else { return }
                self?.noteCaptureProgress(progress)
            },
            onScene: { [weak self] result in
                guard fromActive() else { return }
                self?.deliverScene(result)
            },
            /* A push is not an answer: a guest sends it unasked, and a
               background guest pushing a screenshot is a thing it is
               entitled to do. It arrives without saying which Mac it came
               from, which is a gap the Screenshots module will have to
               close when it grows a guest column. */
            onPushedCapture: { [weak self] delivery in
                self?.captureProgress = nil
                self?.pushedCaptures.send(delivery)
            },
            onStreamFrame: { [weak self] delivery in
                guard fromActive() else { return }
                self?.noteStreamFrame(delivery)
            },
            onStreamStopped: { [weak self] stopped in
                guard fromActive() else { return }
                self?.streamEnded(stopped)
            },
            onStreamRequest: { [weak self] request in
                guard let self, let asker = origin.session else { return }
                self.guestRequestedStream(request, from: asker)
            },
            onFileListing: { [weak self] listing in
                guard fromActive() else { return }
                self?.resolveListing(listing)
            },
            onFileResult: { [weak self] result in
                guard fromActive() else { return }
                self?.resolveChange(result)
            },
            onFileRefuse: { [weak self] refuse in
                guard fromActive() else { return }
                self?.failFile(refuse)
            },
            onFileDelivery: { [weak self] result in
                guard fromActive() else { return }
                self?.deliverFile(result)
            },
            onFileDone: { [weak self] done in
                guard let self, fromActive() else { return }
                // Correlate: a late done from a transfer that already
                // timed out must not settle the NEXT one, which is how a
                // failed 128 KB put made a 512 KB put look successful.
                guard self.putId == done.id else { return }
                self.clearWatchdog(done.id)
                if done.ok {
                    let acknowledgedAt = Date()
                    if self.putRequiresCompletionEvidence,
                       (done.received != self.putExpected
                        || done.crc32 != self.putExpectedCRC32
                        || done.finalization != "same-folder-rename"
                        || done.cleanup != "temp-renamed") {
                        self.settlePut(.failure(self.putFailure(
                            code: "corrupt",
                            message:
                                "Guest completion evidence did not match the staged upload",
                            receiverConfirmedBytes: done.received,
                            guestCleanup: done.cleanup ?? "unknown")))
                        return
                    }
                    let startedAt = self.putStartedAt ?? acknowledgedAt
                    let elapsed = max(
                        0, acknowledgedAt.timeIntervalSince(startedAt))
                    let received = done.received ?? self.putExpected
                    self.settlePut(.success(.init(
                        requestID: done.id,
                        acknowledgedAt: acknowledgedAt,
                        totalBytes: self.putExpected,
                        receiverConfirmedBytes: received,
                        acceptedOffset: self.putAccepted?.have ?? 0,
                        elapsedMs: Int((elapsed * 1_000).rounded()),
                        averageBytesPerSecond: elapsed > 0
                            ? Int(Double(received) / elapsed) : received,
                        progressEvidence: self.putGuestReports
                            ? "guest-progress" : "file-done-only",
                        maximumProgressGapMs:
                            self.maximumPutGapMs(at: acknowledgedAt),
                        guestFreeBytesBefore:
                            self.putAccepted?.freeBytes,
                        guestReservedBytes:
                            self.putAccepted?.reservedBytes,
                        guestStaging: self.putAccepted?.staging,
                        finalization: done.finalization
                            ?? "file-done",
                        cleanup: done.cleanup ?? "unknown",
                        integrity: done.crc32 != nil
                            ? "guest-crc32-confirmed"
                            : "file-done-after-crc32")))
                } else {
                    self.settlePut(.failure(self.putFailure(
                        code: done.code ?? "io-error",
                        message: done.reason ?? "the file was not written",
                        receiverConfirmedBytes: done.received,
                        guestCleanup: done.cleanup ?? "unknown")))
                }
            },
            onFileProgress: { [weak self] progress in
                guard let self, fromActive(),
                      self.putId == progress.id else { return }
                // The far side has spoken: stop believing our own send
                // counter for the rest of this put, for the bar and for
                // the watchdog alike.
                self.putGuestReports = true
                let now = Date()
                if let prior = self.putLastProgressAt {
                    self.putMaximumProgressGap = max(
                        self.putMaximumProgressGap,
                        now.timeIntervalSince(prior))
                } else if let started = self.putStartedAt {
                    self.putMaximumProgressGap =
                        now.timeIntervalSince(started)
                }
                self.putLastProgressAt = now
                self.captureProgress = .init(received: progress.received,
                                             expected: self.putExpected)
                self.touchWatchdog(progress.id)
            },
            onFileAccept: { [weak self] accept in
                guard let self, fromActive(),
                      self.putId == accept.id else { return }
                self.putAccepted = accept
            },
            /* Serving OUR share is the half every connected guest gets
               whether or not it is the active one — it is the guest's own
               request, not an answer to ours — and each reply goes back
               down the connection that asked. */
            onServeList: { [weak self] request in
                guard let self, let asker = origin.session else { return }
                self.serveList(request, on: asker)
            },
            onServeGet: { [weak self] request in
                guard let self, let asker = origin.session else { return }
                self.serveGet(request, on: asker)
            },
            onAcceptOffer: { [weak self] offer in
                guard let self, let asker = origin.session else { return }
                self.acceptOffer(offer, on: asker)
            },
            onServeChange: { [weak self] change in
                guard let self, let asker = origin.session else { return }
                self.serveChange(change, on: asker)
            },
            onProcessListing: { [weak self] listing in
                guard fromActive() else { return }
                self?.resolveProcessListing(listing)
            },
            onSoftwareListing: { [weak self] listing in
                guard fromActive() else { return }
                self?.resolveSoftwareListing(listing)
            },
            onProcessResult: { [weak self] result in
                guard fromActive() else { return }
                self?.resolveProcessResult(result)
            },
            onReceived: { [weak self] url in
                guard let self, let sender = origin.session else { return }
                self.noteReceived(url, from: sender)
            },
            onOutboundProgress: { [weak self] sent, total in
                guard let self, fromActive() else { return }
                // Bytes accepted by the local socket, which is not the
                // same claim as bytes received — on this link it runs
                // minutes ahead. Used only until the guest reports for
                // itself; an older guest that never does keeps this as
                // its only signal, which is what it had before.
                guard !self.putGuestReports else { return }
                self.captureProgress = .init(received: sent, expected: total)
                if let id = self.putId { self.touchWatchdog(id) }
            },
            onOutboundFailed: { [weak self] message in
                guard let self, fromActive() else { return }
                self.settlePut(.failure(self.putFailure(
                    code: "io-error",
                    message: message,
                    guestCleanup: "unknown-after-local-read-failure")))
            },
            onClosed: { [weak self] closedSession, reason in
                guard let self else { return }
                self.pending.removeAll { $0 === closedSession }
                guard let key = closedSession.guestKey,
                      self.sessions[key] === closedSession else { return }
                self.sessions[key] = nil
                self.machineBySession[key] = nil
                self.healthByGuest[key] = nil
                // The next guest under this name is not this one. A
                // capability record that outlived its connection would be
                // the same stale-by-inheritance mistake as reading
                // abilities off a hello name.
                self.familyObservationsByGuest[key] = nil
                self.lastDisconnect = reason
                guard self.activeKey == key else {
                    // A background guest left. Nothing was waiting on it,
                    // and the console must not flicker.
                    self.publishActive()
                    return
                }
                self.streamSessionClosed()
                self.failAllPending(reason)
                /* Promote another connected guest rather than reporting
                   "no Mac is connected" while one is sitting right there.
                   Oldest first, so the choice is stable and not whichever
                   the dictionary happened to yield. */
                self.activeKey = self.sessions.min {
                    (self.healthByGuest[$0.key]?.connectedAt ?? .distantFuture)
                        < (self.healthByGuest[$1.key]?.connectedAt
                           ?? .distantFuture)
                }?.key
                self.publishActive()
            })
        origin.session = newSession
        pending.append(newSession)
        newSession.begin()
    }

    // Sessions that have not passed the hello gate yet. An accepted-but-busy
    // connection lives here just long enough to be refused politely.
    private var pending: [Session] = []
}
