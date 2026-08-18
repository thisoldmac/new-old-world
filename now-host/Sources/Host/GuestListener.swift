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
        /// The connection that produced the line. Nil is listener-wide
        /// activity such as binding a port or refusing an unadmitted peer.
        let sessionID: String?

        static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
            lhs.at == rhs.at && lhs.text == rhs.text
                && lhs.sessionID == rhs.sessionID
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
        /// Active NOW Extension identity as observed by the guest app.
        /// Nil remains unknown: it can mean no resident or an older guest.
        var extensionVersion: String? = nil
        var extensionBuild: String? = nil
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

    /// **The event bus every page learns from.** Owned here because this is
    /// where the truth changes; injectable so a test can watch one listener
    /// without the app's.
    ///
    /// The publishes below hang off `didSet` on the properties that ARE the
    /// state rather than off the functions that assign them. There are five
    /// call sites that clear `captureProgress` and four that move
    /// `activeKey`, and the version of this that announced from the call
    /// sites would be one forgotten assignment away from a page that never
    /// repaints — the failure being fixed here, reintroduced in the fix.
    let events: HostEventBus
    let workTimeline = MirrorWorkTimeline()
    private(set) lazy var workScheduler = GuestWorkScheduler(
        sessionID: activeKey?.text ?? "disconnected",
        clocks: { [weak self] clocks in self?.workTimeline.replace(clocks) })

    @Published private(set) var state: State = .idle {
        didSet {
            if ProcessInfo.processInfo.environment["NOW_HOST_DEBUG"] != nil {
                FileHandle.standardError.write(
                    Data("[now-host] state -> \(state)\n".utf8))
            }
            // Only a real move. `publishActive()` reassigns the same state
            // on every roster change, and a page that repainted for each
            // would repaint once per ping.
            if state != oldValue { events.publish(.linkStateChanged(state)) }
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
    private var nextContinuityId = 1

    /// Reports belong to the session that emitted them. The controller
    /// compares this key to the arm it owns before accepting either a
    /// correlated answer or an unsolicited guest-side takeover.
    var onContinuityReport: ((GuestKey, ContinuityReport) -> Void)?
    var onContinuityKeyReport: ((GuestKey, ContinuityKeyReport) -> Void)?
    /// The guest's unsolicited Finder-selection stub. It arrives from the
    /// active session only, like the two reports above: a background Mac's
    /// selection is not what the pointer is standing on.
    var onContinuitySelection: ((GuestKey, ContinuitySelection) -> Void)?
    /// The RESIDENT's account of a drag that is still in flight, delivered
    /// under the guest key of the application it belongs to.
    ///
    /// The frame arrives on a channel that is deliberately not a session and
    /// has no `GuestKey` of its own, so the key is resolved here by machine
    /// fingerprint — the same join, and the same ambiguity rule, that
    /// `machineIsAnswering` uses: exactly one live session for that machine,
    /// or nothing is delivered. Two Macs calling themselves the same thing
    /// from one address are indistinguishable, and binding one machine's
    /// drag to the other's crossing would put a file on somebody's desktop
    /// that nobody dragged.
    var onContinuityDragBegin: ((GuestKey, ContinuityDragBegin) -> Void)?

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
    /// One per port this host binds — one per machine profile that owns a
    /// port, plus the default every unscoped machine dials.
    private var listeners: [NWListener] = []
    /// Ports that would not bind, with the reason. Kept rather than thrown
    /// away because a profile whose port is held looks exactly like a
    /// profile whose Mac is switched off.
    private(set) var failedPorts: [UInt16: String] = [:]
    /// Ports actually accepting connections. A socket exists from the
    /// moment it is made and answers nothing until it is ready, so this is
    /// a different question from `boundPorts` — and it is the one a person
    /// asking "can my Mac dial in yet" means.
    private(set) var readyPorts: Set<UInt16> = []

    /// Every guest currently past the hello gate, by SESSION identity —
    /// one entry per connection, never per name.
    private var sessions: [GuestKey: Session] = [:]

    /// Whether this exact session still holds a live connection. A guest
    /// key names one dial-in, so a machine that dropped and redialled
    /// answers false here for its old key — which is the question the
    /// Mirror's lane needs answered, not "is some Mac connected".
    func isConnected(_ key: GuestKey) -> Bool { sessions[key] != nil }

    /// **Liveness channels, by machine FINGERPRINT — never by machine id.**
    ///
    /// A resident component outlives the application it reports for, which
    /// is the whole point of it, so it must survive the guest session
    /// redialling underneath it. It cannot be filed by `GuestID`:
    /// `mintSessionKey` deliberately gives a second dial from a live
    /// name+address a *different* id — the guard that stops two Macs
    /// behind one emulator's loopback becoming one guest — so a resident
    /// would never share its own application's id.
    ///
    /// These are NOT guests. They never enter `sessions`, never become
    /// `activeKey`, are never offered a command, take no registry slot and
    /// do not count against `maxGuests` — a Macintosh running the
    /// extension must not appear twice in a host's guest list.
    private var residents: [String: Session] = [:]

    /// Whether something other than this session proves its machine is
    /// alive — the one inference a resident channel licenses.
    ///
    /// **Ambiguous means NO.** Two machines that call themselves the same
    /// thing from one address are indistinguishable here, and one of them
    /// vouching for the other's wedged session would hold a dead guest
    /// open forever — strictly worse than the timeout it replaced. So a
    /// resident speaks only when exactly one live session matches it, and
    /// otherwise the old behaviour stands.
    func machineIsAnswering(sessionKey key: GuestKey) -> Bool {
        guard let session = sessions[key],
              let print = session.machineFingerprint,
              residents[print] != nil else { return false }
        let matching = sessions.values.filter {
            $0.machineFingerprint == print
        }
        return matching.count == 1
    }

    /// The one live session for a machine fingerprint, or nil.
    ///
    /// AMBIGUOUS MEANS NO, for the reason `machineIsAnswering` above says at
    /// length: two sessions matching one fingerprint cannot be told apart
    /// here, and guessing which of them a resident speaks for is a wrong
    /// file rather than a missing one.
    func sessionKey(forMachine fingerprint: String) -> GuestKey? {
        let matching = sessions.filter {
            $0.value.machineFingerprint == fingerprint
        }
        return matching.count == 1 ? matching.first?.key : nil
    }

    /// Whether the guest for this key is answering, or is STARVED — alive
    /// on another channel and not being scheduled. Nil when there is no
    /// such session at all, which is the third answer and not a variant
    /// of the second.
    func isAnswering(_ key: GuestKey) -> Bool? { sessions[key]?.isAnswering }
    /// Which machine each live session is a session WITH. The registry is
    /// the book; this is the page open at each socket.
    private var machineBySession: [GuestKey: GuestRegistry.Record] = [:]
    /// The host's own book of machine handles. See GuestRegistry for
    /// where an id comes from and why it is assigned here.
    let registry: GuestRegistry
    private let updateProvider: UpdateProvider
    /// Which of them the request-shaped API drives. Nil when none are
    /// connected.
    private(set) var activeKey: GuestKey? {
        didSet {
            guard activeKey != oldValue else { return }
            workScheduler.reset(sessionID: activeKey?.text ?? "disconnected")
            events.publish(.focusChanged(to: activeKey))
        }
    }

    /// The active session. Every existing caller means this one, so it
    /// stays spelled `session` and stays private — the table is the new
    /// thing, and nothing outside this file has to learn about it yet.
    private var session: Session? {
        activeKey.flatMap { sessions[$0] }
    }

    /// Who is connected, active one first-class rather than implied.
    /// Published so a view can list them; nothing reads it yet.
    @Published private(set) var guests: [ConnectedGuest] = [] {
        didSet {
            guard guests != oldValue else { return }
            events.publish(.rosterChanged)
        }
    }

    init(identity: HostIdentity, timing: Timing = Timing(),
         pacing: Pacing = .classicMac, maxGuests: Int = 4,
         registry: GuestRegistry? = nil,
         updateProvider: UpdateProvider? = nil,
         /* Optional rather than defaulted to a fresh bus, because a default
            argument is evaluated where the CALLER stands and this type is
            main-actor-isolated. */
         events: HostEventBus? = nil) {
        self.events = events ?? HostEventBus()
        self.registry = registry ?? GuestRegistry()
        self.updateProvider = updateProvider ?? .live()
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
    func selectGuest(_ key: GuestKey,
                     beforeSwitch: (() -> Void)? = nil) -> Bool {
        guard sessions[key] != nil, activeKey != key else { return false }
        /* The outgoing guest is still the command target here. A caller
           ending guest-owned state gets one ordered chance to release it
           before pending requests are failed and focus moves. */
        beforeSwitch?()
        // Requests already in flight belong to the guest we are leaving
        // and would otherwise settle against whatever answers next.
        failAllPending("Switched to another \(MachineNaming.commonNoun)")
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
        } else if !listeners.isEmpty {
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
                displayName: machine?.displayName,
                listenPort: machine?.listenPort,
                address: live.guestAddress,
                version: record.guestVersion,
                build: record.guestBuild,
                extensionVersion: record.extensionVersion,
                extensionBuild: record.extensionBuild,
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
                                address: GuestAddress,
                                listenPort: UInt16?) -> GuestKey {
        let print = GuestRegistry.fingerprint(
            name: hello.name, operatingSystem: hello.os)
        /* Only slots held by a LIVE session count. A machine reconnecting
           into a slot nobody is using re-adopts the id it had. */
        let occupied = Set(machineBySession.values.filter {
            $0.address == address.text && $0.fingerprint == print
                && $0.listenPort == listenPort
        }.map(\.slot))
        let record = registry.identify(
            address: address, name: hello.name, operatingSystem: hello.os,
            occupiedSlots: occupied, listenPort: listenPort)
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
            events.publish(.guestRenamed(key, id: renamed))
        }
        return outcome
    }

    /// Retitles a machine without changing the stable id held by callers.
    @discardableResult
    func renameGuestDisplayName(_ key: GuestKey, to proposed: String)
        -> Result<String, GuestRegistry.DisplayNameFailure> {
        guard let record = machineBySession[key] else {
            return .failure(.notFound)
        }
        let outcome = registry.renameDisplayName(record.key, to: proposed)
        if case .success(let renamed) = outcome {
            for (session, held) in machineBySession
                where held.key == record.key {
                machineBySession[session]?.displayName = renamed
            }
            publishActive()
        }
        return outcome
    }

    /// Closes one exact live session and removes its durable registry entry.
    /// A guest configured to reconnect may immediately return; this is a
    /// remove operation, not an implicit deny-list.
    @discardableResult
    func removeGuest(_ key: GuestKey) -> Bool {
        guard let live = sessions[key] else { return false }
        if let record = machineBySession[key] {
            _ = registry.forget(record.key)
        }
        note("Removed \(machineBySession[key]?.lastName ?? live.guestName)",
             session: key)
        live.close(sending: Bye(code: .shuttingDown,
                                reason: "Removed by the host"))
        return true
    }

    /// Per-guest health, so switching does not have to re-ask the wire
    /// and a background guest's ping count is not lost.
    private var healthByGuest: [GuestKey: SessionHealth] = [:]

    /// The selected row's health without moving the active request plane.
    /// Connections uses this to inspect a background guest without showing
    /// the driven guest's counters under the wrong name.
    func health(for key: GuestKey) -> SessionHealth? {
        healthByGuest[key]
    }

    private static let logLimit = 100

    /// A line for the window and the file. `area` is the subsystem the
    /// line belongs to, so a log can be read by subsystem the way the
    /// other machine's can (docs/logging.md).
    func note(_ text: String, area: String = "wire",
              level: HostLog.LogLevel = .info,
              session: GuestKey? = nil) {
        if ProcessInfo.processInfo.environment["NOW_HOST_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[now-host] \(text)\n".utf8))
        }
        /* The window keeps the last hundred lines; the file keeps all of
           them. Everything worth knowing after the fact — what happened
           before you looked, and what happened after you quit — is only
           in the second one. */
        HostLog.shared.write(level, area, text)
        log.append(LogEntry(at: Date(), text: text, sessionID: session?.text))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    /// Binds one port. The single-guest desk, and every test that wants an
    /// ephemeral port: `start(port: 0)` still means "any free port, tell me
    /// which" and `boundPort` still answers.
    func start(port: UInt16) {
        start(ports: [port])
    }

    /// **Binds one port per machine profile.**
    ///
    /// Several listeners rather than one, because the port is what tells two
    /// Macs apart when nothing else can: behind an emulator every guest
    /// arrives from the loopback address wearing the same fingerprint, and
    /// the host was left ordering them by who dialled first. A profile that
    /// owns a port is a profile the host recognises before the hello.
    ///
    /// A port that will not bind does NOT fail the run. The others are still
    /// serving real machines, and a desk losing every Mac because one port
    /// is held by something else is a worse answer than losing the one. The
    /// refusal is noted per port and reported in `failedPorts`, so it is
    /// visible rather than silent — a machine that cannot arrive and a
    /// machine that has not arrived look identical from the roster.
    func start(ports: [UInt16]) {
        stop()
        var wanted: [UInt16] = []
        for port in ports where !wanted.contains(port) { wanted.append(port) }
        if wanted.isEmpty { wanted = [SettingsModel.defaultPort] }
        for port in wanted {
            do {
                let nwPort = NWEndpoint.Port(rawValue: port)
                    ?? NWEndpoint.Port(rawValue: 0)!
                let listener = try NWListener(using: .tcp, on: nwPort)
                listeners.append(listener)
                /* The accepting listener names its own port. Reading the
                   bound port off `self` here — which is what one listener
                   allowed — would file every guest under whichever listener
                   happened to be first in the list, so the port could not
                   distinguish anything it was configured to distinguish. */
                listener.newConnectionHandler = {
                    [weak self, weak listener] connection in
                    let accepted = listener?.port?.rawValue
                    Task { @MainActor in
                        self?.accept(connection, on: accepted)
                    }
                }
                listener.stateUpdateHandler = {
                    [weak self, weak listener] nwState in
                    let requested = listener?.port?.rawValue ?? port
                    Task { @MainActor in
                        self?.listenerStateChanged(nwState, port: requested)
                    }
                }
                listener.start(queue: .main)
            } catch {
                failedPorts[port] = error.localizedDescription
                note("Could not listen on \(port): "
                     + "\(error.localizedDescription)")
            }
        }
        if listeners.isEmpty {
            let reason = failedPorts.values.first ?? "no port to bind"
            state = .failed("Could not listen: \(reason)")
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
        for listener in listeners { listener.cancel() }
        listeners = []
        failedPorts = [:]
        readyPorts = []
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
        for listener in listeners { listener.cancel() }
        listeners = []
        failedPorts = [:]
        readyPorts = []
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
                    self.note("Quit without confirming the farewell "
                              + "reached \(MachineNaming.simpleReference)")
                }
                report()
            }
        }
    }

    /// Every port actually bound, in the order they were asked for — the
    /// host's default first, then each profile's own.
    var boundPorts: [UInt16] { listeners.compactMap { $0.port?.rawValue } }

    /// The FIRST port bound (differs from the requested one when 0 was
    /// passed for an ephemeral port — used by tests).
    ///
    /// It is the host's default port, never a profile's: `start(ports:)` is
    /// given the default first. Deliberately not "the port", because with
    /// several profiles there is no such thing — a caller that means one
    /// machine's port must ask that machine.
    var boundPort: UInt16? { boundPorts.first }

    struct ContinuityTarget: Equatable {
        var key: GuestKey
        var host: String
    }

    var activeContinuityTarget: ContinuityTarget? {
        guard let key = activeKey, let live = sessions[key] else { return nil }
        return ContinuityTarget(key: key, host: live.guestAddress.text)
    }

    @discardableResult
    func armContinuity(nonceHi: UInt32, nonceLo: UInt32, epoch: UInt32,
                       requestedHz: Int, leaseTicks: Int,
                       options: ContinuityArmOptions = .init()) -> Int? {
        guard let session else { return nil }
        let id = nextContinuityId
        nextContinuityId &+= 1
        session.send(.continuityArm(.init(
            version: ContinuityContract.version,
            id: id, nonceHi: nonceHi, nonceLo: nonceLo, epoch: epoch,
            requestedHz: requestedHz, leaseTicks: leaseTicks,
            fastPump: options.fastPump,
            settleSyntheticDevice: options.settleSyntheticDevice,
            wideDoubleTime: options.wideDoubleTime,
            compressClickWhen: options.compressClickWhen,
            interruptPress: options.interruptPress,
            deepClickLog: options.deepClickLog,
            settleIdleCursor: options.settleIdleCursor)))
        return id
    }

    @discardableResult
    func disarmContinuity(epoch: UInt32, reason: String) -> Int? {
        guard let session else { return nil }
        let id = nextContinuityId
        nextContinuityId &+= 1
        session.send(.continuityDisarm(.init(
            version: ContinuityContract.version,
            id: id, epoch: epoch, reason: reason)))
        return id
    }

    @discardableResult
    func sendContinuityKey(epoch: UInt32, generation: UInt32,
                           action: ContinuityKey.Action, code: UInt16,
                           character: UInt8, modifiers: UInt16) -> Int? {
        guard let session else { return nil }
        let id = nextContinuityId
        nextContinuityId &+= 1
        session.send(.continuityKey(.init(
            version: ContinuityContract.version, id: id, epoch: epoch,
            generation: generation, action: action, code: code,
            character: character, modifiers: modifiers)))
        return id
    }

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
    /// The stringly form, kept because most arguments ARE text and every
    /// existing caller passes one. A value that must cross as a JSON
    /// number uses `typed:` below — see `CommandArg` for what sending a
    /// quoted number cost.
    func runCommand(_ name: String, args: [String: String]? = nil,
                    line: String? = nil,
                    completion: @escaping (CommandResult) -> Void) {
        runCommand(name, typed: args?.mapValues(CommandArg.text),
                   line: line, completion: completion)
    }

    func updateAvailability(_ component: UpdateProvider.Component,
                            installedVersion: String?,
                            installedBuild: String?)
        -> UpdateProvider.Availability {
        updateProvider.availability(
            for: component, installedVersion: installedVersion,
            installedBuild: installedBuild)
    }

    /// The host-side human update action. It addresses the active session
    /// explicitly and never turns an unknown/current/older artifact into an
    /// install. The guest binds the command back to the exact offer before
    /// it accepts any bytes.
    func installUpdate(_ component: UpdateProvider.Component,
                       for key: GuestKey,
                       installedVersion: String?, installedBuild: String?,
                       completion: @escaping (CommandResult) -> Void) {
        guard activeKey == key, sessions[key] != nil else {
            completion(.init(
                id: 0, ok: false,
                error: .init(code: "not-addressed",
                             message: "Drive this Mac before replacing its software.")))
            return
        }
        guard case .replacement = updateProvider.availability(
            for: component, installedVersion: installedVersion,
            installedBuild: installedBuild) else {
            completion(.init(
                id: 0, ok: false,
                error: .init(code: "not-available",
                             message: "No different validated build is available.")))
            return
        }
        runCommand("update", typed: [
            "component": .text(component.rawValue),
            "hostApproved": .flag(true),
        ], completion: completion)
    }

    /// **The bound, and why it is this one.**
    ///
    /// Until 2026-08-06 this armed no watchdog at all: every other
    /// request family here dies of silence and this one, the family the
    /// Mirror's whole content join and both Finder complements travel on,
    /// waited on a foreign machine forever. An unbounded wait on a
    /// cooperatively scheduled Macintosh is a defect on its own terms
    /// (plan 014 §B) — a wedged guest left a completion stored and the
    /// caller busy with nothing to report.
    ///
    /// Twenty seconds, and deliberately not shorter. The guest's own
    /// script ceiling is `kNowScriptDefaultMs` — **15 s**
    /// (`input_args.h`) — and the host does not override it, so anything
    /// below that would truncate scripts the guest is still working on
    /// and is about to answer with a typed refusal that says why. This
    /// bound therefore fires only when the guest has gone silent
    /// altogether, which is the failure it exists for, and it matches the
    /// 20 s the other answer-bearing families here already use.
    ///
    /// It is not the fix for the slow cycle and was never proposed as
    /// one: measured live on 2026-08-06, one ordinary cycle's guest
    /// round-trips were 5–12 ms for the content join, ~340 ms for the
    /// visibility census and 1.3–1.6 s for a Finder roster read. Three of
    /// those at any workable bound still exceeds the plane lease. Taking
    /// them out of the cycle is the fix; this stops a silent machine
    /// holding a completion.
    ///
    /// A timeout is COUNTED as well as reported, because a cycle that
    /// gave up has to be able to say so — see `commandTimeouts`.
    static let commandWatchdogSeconds: TimeInterval = 20

    /// The bound `ConnectionsModel` arms while waiting for `update.result`
    /// after `installUpdate` starts one. Kept beside
    /// `commandWatchdogSeconds` because it answers the same question for
    /// the same family, but it is NOT that watchdog scaled up: the initial
    /// `runCommand("update", …)` call above resolves almost instantly
    /// (the guest replies "Downloading" the moment it accepts, long
    /// before any bytes move), so `commandWatchdogSeconds` only ever
    /// covers that instant acknowledgment. The real completion —
    /// download, then a synchronous Trash-move-and-install on a
    /// cooperatively scheduled guest where a blocked Toolbox call blocks
    /// the entire event loop, including ping replies — rides
    /// `.updateFinished` alone, with nothing bounding the wait before
    /// this existed. Flat rather than scaled off artifact size: this is a
    /// rare, human-attended action rather than a polling hot path, and 3
    /// minutes is a generous ceiling absent measured install times on
    /// real hardware — this path is exactly the fBsyErr-adjacent code
    /// this project has been bitten by trusting without a metal run.
    static let updateResultWatchdogSeconds: TimeInterval = 180

    /// How many `command.request`s have died of silence on this listener.
    /// Monotonic for the listener's life; a caller that wants "did THIS
    /// cycle give up" samples it either side and reports the difference
    /// (`MirrorCycleClocks.guestTimeouts`). A truncation nobody can see
    /// in the record is the thing this whole plan exists to stop.
    private(set) var commandTimeouts = 0

    func runCommand(_ name: String, typed args: [String: CommandArg]?,
                    line: String? = nil,
                    watchdogSeconds: TimeInterval? = nil,
                    completion: @escaping (CommandResult) -> Void) {
        guard let session, case .connected = state else {
            completion(CommandResult(
                id: 0, ok: false, output: nil,
                error: .init(code: "not-connected",
                             message: "No \(MachineNaming.commonNoun) is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingCommands[id] = completion
        armWatchdog(id: id,
                    seconds: watchdogSeconds ?? Self.commandWatchdogSeconds) {
            [weak self] reason in
            guard let self,
                  let waiting = self.pendingCommands
                      .removeValue(forKey: id) else { return }
            self.commandTimeouts += 1
            /* The guest's own vocabulary is not available here — it never
               said anything — so the code is `timeout` and the message is
               the listener's account of the silence, the same pair every
               other family reports. */
            waiting(CommandResult(id: id, ok: false, output: nil,
                                  error: .init(code: "timeout",
                                               message: reason)))
        }
        session.sendCommand(CommandRequest(id: id, name: name, args: args,
                                           line: line))
    }

    /// Scheduled command entry for product work that is not already inside
    /// an admitted slice. Act dispatch uses the direct method above because
    /// NOWMirrorSource has already admitted that exact gesture.
    func runScheduledCommand(
        _ name: String, typed args: [String: CommandArg]?,
        line: String? = nil,
        purpose: GuestWorkPurpose, workClass: GuestWorkClass,
        coalescingKey: String? = nil,
        watchdogSeconds: TimeInterval? = nil,
        completion: @escaping (CommandResult) -> Void
    ) {
        workScheduler.submitCallback(
            purpose, as: workClass, coalescingKey: coalescingKey,
            onCancel: {
                completion(.init(
                    id: 0, ok: false,
                    error: .init(code: "session-changed",
                                 message: "The Mac changed before the command was sent")))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.runCommand(name, typed: args, line: line,
                                watchdogSeconds: watchdogSeconds) { result in
                    completion(result)
                    finish()
                }
            }
    }

    func runScheduledCommand(
        _ name: String, args: [String: String]? = nil,
        line: String? = nil, purpose: GuestWorkPurpose,
        workClass: GuestWorkClass, coalescingKey: String? = nil,
        watchdogSeconds: TimeInterval? = nil,
        completion: @escaping (CommandResult) -> Void
    ) {
        runScheduledCommand(
            name, typed: args?.mapValues(CommandArg.text), line: line,
            purpose: purpose,
            workClass: workClass, coalescingKey: coalescingKey,
            watchdogSeconds: watchdogSeconds
        ) { result in
            completion(result)
        }
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
    /// The watchdog is 60s rather than the 20s a `command.request` gets
    /// (`commandWatchdogSeconds`). The number in this sentence used to be
    /// 15, and it described nothing: `command.request` armed no watchdog
    /// at all until 2026-08-06, and the 15 s belonged to `file.list`,
    /// `process.list` and `process.drive` — a different message family
    /// that happens to draw its ids from the same sequence. A comment
    /// that names a bound the code does not have is worse than none: it
    /// is what let an unbounded wait sit here unnoticed.
    ///
    /// The reason for 60 is `vprobe`: it measures for ~12 seconds by
    /// design, and on a
    /// PowerBook that is a floor rather than a typical case. A console is
    /// also the one surface where a human is watching and can see that
    /// nothing has come back, so a generous bound costs less here than a
    /// premature "timeout" on a command that was working.
    func exec(_ line: String,
              completion: @escaping (ExecOutcome) -> Void) {
        workScheduler.submitCallback(
            .console, as: .humanInteractive,
            onCancel: {
                completion(.init(text: "", ok: false,
                                 code: "session-changed",
                                 message: "The Mac changed before the command was sent"))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.execAdmitted(line) { outcome in
                    completion(outcome)
                    finish()
                }
            }
    }

    private func execAdmitted(
        _ line: String, completion: @escaping (ExecOutcome) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(ExecOutcome(text: "", ok: false, code: "disconnected",
                                   message: "No \(MachineNaming.commonNoun) is connected"))
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
        workScheduler.submitCallback(
            .command("census \(probe)"), as: .foreground,
            onCancel: {
                completion(.init(
                    id: 0, probe: probe, outcome: "failed", rows: [],
                    more: false, cursor: nil, total: nil,
                    note: "The Mac changed before the census page was sent"))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.requestCensusAdmitted(probe: probe, cursor: cursor) {
                    report in
                    completion(report)
                    finish()
                }
            }
    }

    private func requestCensusAdmitted(
        probe: String, cursor: Int?,
        completion: @escaping (CensusReport) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(CensusReport(
                id: 0, probe: probe, outcome: "failed", rows: [],
                more: false, cursor: nil, total: nil,
                note: "No \(MachineNaming.commonNoun) is connected"))
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

    // MARK: - continuity.offer / the inverted continuity.grab

    /// What this Mac is carrying toward the guest, and the lifetime bound
    /// on serving it after Continuity ends. See ContinuityOfferService.swift.
    let continuityOfferService = ContinuityOfferService()

    /// Publishes ONE local file as this Mac's offer for `epoch`/`generation`,
    /// converting it exactly as `serveGet` converts a Files pull — same
    /// `OutboundFile.plan`, so the bytes a later grab serves are the bytes
    /// whose facts were already announced on the wire, never re-derived.
    ///
    /// Driven from a testable seam (an agent command or a debug console
    /// verb), never from the drag gesture itself: this function does not
    /// know or care whether a person's hand is on a mouse.
    @discardableResult
    func publishContinuityOffer(guestKey: GuestKey, epoch: UInt32,
                                generation: UInt32, fileAt url: URL,
                                handoffDragSeq: UInt32? = nil)
        throws -> ContinuityOffer.Item {
        guard let session = sessions[guestKey] else {
            throw HostShare.ShareError.notFound
        }
        let data = try Data(contentsOf: url)
        let plan = OutboundFile.plan(url: url, data: data,
                                     convertText: convertServedText)
        let original = url.lastPathComponent
        let item = ContinuityOffer.Item(
            name: plan.name, nameAdjusted: ClassicName.adjustment(for: original),
            fileType: plan.fileType, creator: plan.creator,
            dataSize: plan.bytes.count, resourceSize: nil,
            modifiedAt: plan.modified.map(UInt32.init), isFolder: false,
            icon: nil)
        continuityOfferService.publish(guestKey: guestKey, epoch: epoch,
                                       generation: generation, url: url,
                                       plan: plan, item: item,
                                       handoffDragSeq: handoffDragSeq)
        note("offer #\(epoch)/\(generation) published: \(item.name), "
             + "\(item.dataSize) bytes", area: "continuity",
             session: guestKey)
        session.sendContinuityOffer(epoch: epoch, generation: generation,
                                    item: item)
        return item
    }

    /// **THE HANDOFF, AS ONE ACT: publish the promise, then start the
    /// guest's own drag on it.**
    ///
    /// Publishing and handing off are one call because they are one fact —
    /// the skeleton the guest advertises and the bytes a later
    /// `continuity.grab` serves are derived from a single
    /// `OutboundFile.Plan` (`ContinuityHostDragSkeleton`). Two calls would
    /// be two reads of the file and a window in which the guest could
    /// promise something this Mac is not holding.
    ///
    /// After this returns, the host's remaining duty is exactly one thing:
    /// keep serving that offer until the guest's send proc asks for it.
    /// Position and button ride the ordinary datagrams; where the file
    /// lands is not this side's business.
    @discardableResult
    func beginHostDrag(guestKey: GuestKey, epoch: UInt32,
                       generation: UInt32, fileAt url: URL,
                       dragSeq: UInt32,
                       pos: ContinuityHostDragBegin.Position)
        throws -> ContinuityHostDragBegin.Item {
        try publishContinuityOffer(guestKey: guestKey, epoch: epoch,
                                   generation: generation, fileAt: url,
                                   handoffDragSeq: dragSeq)
        guard let session = sessions[guestKey],
              let plan = continuityOfferService.current?.plan else {
            throw HostShare.ShareError.notFound
        }
        let item = ContinuityHostDragSkeleton.item(for: plan)
        note("drag handoff #\(dragSeq): \(item.name) "
             + "type=\(item.fileType ?? "-") creator=\(item.creator ?? "-") "
             + "data=\(item.dataSize) rsrc=\(item.resourceSize) at "
             + "\(pos.h),\(pos.v) — the Macintosh's Drag Manager owns the "
             + "gesture from here", area: "continuity", session: guestKey)
        session.sendContinuityHostDragBegin(epoch: epoch, dragSeq: dragSeq,
                                            pos: pos, item: item)
        return item
    }

    /// Tells the guest the drag is over — an absent item under a fresh
    /// generation, the contract's own instruction to tear down whatever
    /// the guest was drawing. Does not itself end the offer's lifetime
    /// window; a separate epoch end does that (`endContinuityOfferEpoch`).
    func clearContinuityOffer(guestKey: GuestKey, epoch: UInt32,
                              generation: UInt32) {
        guard let session = sessions[guestKey] else { return }
        session.sendContinuityOffer(epoch: epoch, generation: generation,
                                    item: nil)
    }

    /// **The host→guest carry ended without a drop: let the promise go.**
    ///
    /// The abort half of `beginHostDrag`. The guest's own drag has already
    /// ended natively over there (its input proc reports a point nothing
    /// accepts, then button-up, and the Drag Manager plays its own
    /// snap-back) — so nothing is holding this promise and it stops being
    /// serveable this instant, rather than after `endEpoch`'s window.
    ///
    /// Named `reason` because every one of these lines has to be readable
    /// on its own in an attended run: a promise that stopped being served
    /// and no sentence saying why is the shape of defect this lane keeps
    /// paying for.
    func endHostDragOffer(dragSeq: UInt32, reason: String) {
        guard let offer = continuityOfferService.release() else {
            note("drag handoff #\(dragSeq) ended with no promise still "
                 + "held (\(reason))", area: "continuity")
            return
        }
        note("drag handoff #\(dragSeq): the promise for \(offer.item.name) "
             + "was let go without a pull — \(reason). Nothing was copied",
             area: "continuity", level: .warn)
    }

    /// Continuity ended while an item was still carried: starts the
    /// bounded serveable window rather than dropping the offer outright.
    func endContinuityOfferEpoch() {
        continuityOfferService.endEpoch()
    }

    /// Answers a `continuity.grab` the ASKING guest sent — the inverted
    /// use, serving this host's own published offer down the ordinary
    /// file lane, same as `serveGet` serves a Files pull.
    fileprivate func serveContinuityGrab(_ grab: ContinuityGrab,
                                         on session: Session) {
        guard let key = session.guestKey else {
            session.refuseFile(id: grab.id, code: "no-selection",
                               reason: "This Mac does not recognise that "
                                   + "connection.")
            return
        }
        switch continuityOfferService.grab(guestKey: key, epoch: grab.epoch,
                                           generation: grab.generation) {
        case .refuse(let code, let reason):
            note("#\(grab.id) offer grab refused: \(code) (\(reason))",
                 area: "continuity", level: .warn, session: key)
            session.refuseFile(id: grab.id, code: code, reason: reason)
        case .serve(let plan):
            /* THE PROMISE PULL, and on the native lane it happens INSIDE
               the guest's drop — the one moment this Mac's only remaining
               duty is being discharged. Tagged with the handoff it belongs
               to so an attended run can read the whole gesture off this
               log alone: handoff sent, pull served, and how much. */
            let handoff = continuityOfferService.handoffDragSeq
                .map { "drag handoff #\($0): " } ?? ""
            note("#\(grab.id) \(handoff)serving offered \(plan.name), "
                 + "\(plan.bytes.count) bytes", area: "continuity",
                 session: key)
            session.serveFile(id: grab.id, plan: plan,
                              container: grab.container,
                              modified: plan.modified)
        }
    }

    /// The cloud services this Mac may offer a guest. Lazy and a var so
    /// a test can hand it a registry of fakes; the real providers cost
    /// nothing until a guest asks or the iCloud page looks.
    lazy var cloud: CloudRegistry = {
        let registry = CloudRegistry()
        registry.register(DriveCloudProvider(share: share))
        registry.register(PhotosCloudProvider())
        registry.register(ContactsCloudProvider())
        return registry
    }()

    /// The chat harness's wire face, or nil for a host that has none
    /// wired (tests, mostly). Nil means chat.* asks go unanswered,
    /// which is the honest pre-family silence the contract describes.
    weak var chatService: ChatWireService?
    /// The host-side renderer for the guest application's loopback proxy.
    /// Nil is honest unavailability and is answered by the guest's timeout.
    weak var webService: WebWireService?

    enum WebAsk {
        case request(WebRequest)
        case cancel(WebCancel)

        var id: Int {
            switch self {
            case .request(let request): return request.id
            case .cancel(let cancel): return cancel.id
            }
        }
    }

    func serveWeb(_ ask: WebAsk, on asker: Session) {
        guard let webService else {
            asker.send(.webResponseEnd(WebResponseEnd(
                id: ask.id, ok: false, code: "unavailable",
                reason: "Open Web Proxy on this Mac first")))
            return
        }
        webService.serve(ask, on: asker)
    }

    /// Brings one of THIS Mac's own windows forward, set by the app that
    /// owns them. Nil for a headless listener (tests, the companion
    /// process), which refuses `host.show` with a reason rather than
    /// going quiet — see HostSurfaceService.swift.
    var hostSurfaceOpener: HostSurfaceOpener?

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
                 area: "files", session: session.guestKey)
            session.send(.fileListing(FileListing(
                id: request.id, path: request.path, entries: page.entries,
                more: page.more, cursor: page.next,
                freeBytes: try? self.share.availableBytes(path: request.path),
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
                 + "\(plan.bytes.count) bytes", area: "files",
                 session: session.guestKey)
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
                 + "\(offer.bytes) bytes, into the share", area: "files",
                 session: session.guestKey)
            try session.beginReceiving(offer: offer, to: url)
        } catch {
            session.refuseFile(id: offer.id, error: error)
        }
    }


    /// The four change operations, answered the way the guest answers
    /// them: one file.result, success or not, because the asker is
    /// holding an undo stack and a silent failure leaves it believing
    /// something it can reverse.
    fileprivate func serveChange(_ change: ChangeRequest,
                                on session: Session) {
        /* Anything that leaves the block below without throwing has
           moved, trashed, restored or created something in OUR shared
           folder. Announced once, from the one exit, rather than in each
           of the four arms — four publishes is four chances for a fifth
           operation to arrive without one. */
        var served: String?
        defer {
            if let path = served {
                events.publish(.fileTreeChanged(session.guestKey,
                                                side: .host, path: path))
            }
        }
        do {
            switch change {
            case .move(let request):
                let landed = try share.move(from: request.path,
                                            to: request.toPath,
                                            overwrite: request.overwrite
                                                ?? false)
                note("#\(request.id) moved \(request.path) to \(landed)",
                     area: "files", session: session.guestKey)
                served = landed
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            case .trash(let request):
                let landed = try share.trash(path: request.path)
                /* The other machine putting a file of yours in the
                   Trash is the line most worth having later. */
                note("#\(request.id) trashed \(request.path), it is in the "
                     + "Trash as \(landed)", area: "files",
                     session: session.guestKey)
                served = landed
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: request.path,
                    trashedAs: landed, code: nil, reason: nil)))
            case .restore(let request):
                let landed = try share.restore(trashedAs: request.trashedAs,
                                               to: request.toPath)
                note("#\(request.id) restored \(request.trashedAs) to "
                     + "\(landed)", area: "files",
                     session: session.guestKey)
                served = landed
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            case .mkdir(let request):
                let landed = try share.makeFolder(path: request.path)
                note("#\(request.id) made the folder \(landed)",
                     area: "files", session: session.guestKey)
                served = landed
                session.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            }
        } catch {
            let fault = HostShare.WireFault(error)
            note("#\(change.id) change refused: \(fault.code) "
                 + "(\(fault.reason))", area: "files", level: .warn,
                 session: session.guestKey)
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
        /* The SENDER, not the active guest: a notification naming the
           wrong Mac is worse than one naming none. This used to be an
           assignment hook the app set (`announceReceivedFile`), which
           meant exactly one thing could ever hear it — the notifier — and
           the shared folder's own view could not. */
        events.publish(.fileReceived(session.guestKey, url: url,
                                     bytes: bytes ?? 0,
                                     guestName: session.guestName))
        events.publish(.fileTreeChanged(
            session.guestKey, side: .host,
            path: url.deletingLastPathComponent().path))
    }

    // MARK: - Files

    struct FileFailure: Error, Sendable {
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

    struct PutFailureEvidence: Sendable {
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
    struct PutReceipt: Sendable {
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
        var relaunchRequired = false
    }

    /// One pulled file, still in guest form. The bytes remain in a
    /// same-folder temporary file until the caller converts or moves it;
    /// delivery itself never reconstructs the artifact in memory.
    struct FileDelivery: Sendable {
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
                   workClass: GuestWorkClass = .foreground,
                   completion: @escaping (Result<FileListing,
                                                 FileFailure>) -> Void) {
        workScheduler.submitCallback(
            .files, as: workClass,
            onCancel: {
                completion(.failure(.init(
                    code: "session-changed",
                    message: "The Mac changed before the file page was sent")))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.listFilesAdmitted(path: path, cursor: cursor) { result in
                    completion(result)
                    finish()
                }
            }
    }

    private func listFilesAdmitted(
        path: String, cursor: Int?,
        completion: @escaping (Result<FileListing, FileFailure>) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
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
        workScheduler.submitCallback(
            .processes, as: .foreground,
            onCancel: {
                completion(.failure(.init(
                    code: "session-changed",
                    message: "The Mac changed before the process page was sent")))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.listProcessesAdmitted(cursor: cursor) { result in
                    completion(result)
                    finish()
                }
            }
    }

    private func listProcessesAdmitted(
        cursor: Int?,
        completion: @escaping (Result<ProcessListing, FileFailure>) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
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
        workScheduler.submitCallback(
            .software, as: .bulk,
            onCancel: {
                completion(.failure(.init(
                    code: "session-changed",
                    message: "The Mac changed before the software page was sent")))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.listSoftwareAdmitted(domain: domain, cursor: cursor) {
                    result in
                    completion(result)
                    finish()
                }
            }
    }

    private func listSoftwareAdmitted(
        domain: String, cursor: Int?,
        completion: @escaping (Result<SoftwareListing, FileFailure>) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
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
        workScheduler.submitCallback(
            .interaction(verb == .front ? "front process" : "quit process"),
            as: .humanInteractive,
            onCancel: {
                completion(.failure(.init(
                    code: "session-changed",
                    message: "The Mac changed before the process action was sent")))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.driveProcessAdmitted(
                    psnHigh: psnHigh, psnLow: psnLow, verb: verb) { result in
                        completion(result)
                        finish()
                    }
            }
    }

    private func driveProcessAdmitted(
        psnHigh: Int, psnLow: Int, verb: ProcessVerb,
        completion: @escaping (Result<ProcessResult, FileFailure>) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
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
                                      message: "No \(MachineNaming.commonNoun) is connected")))
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
    ///
    /// One waiter, like `getMirrorFile` and `grabContinuityFile`: there is
    /// one bulk receiver below this (`Session.activeFileGetID`, one
    /// `fileBegin`, one sink), so a second overlapping ask cannot be served
    /// even if this layer accepted it. Without the guard it did accept it —
    /// `pendingFile` is a single slot with no request-id key, so the second
    /// ask overwrote the first waiter, `deliverFile` handed the SECOND
    /// caller the FIRST caller's bytes, and the loser's completion was
    /// never called at all. For a drag-out that means
    /// `GuestFilePromiseExporter.active` never clears and every later
    /// drag-out in the session is refused by its own idle guard, while
    /// Finder keeps the unresolved promise's placeholder on screen. Four
    /// callers reach here (Files download, Files drag-out promises, the
    /// Census ROM dump and Mirror asset ingestion) and only the first two
    /// share `FilesModuleModel.transfer` as a mutex, so the overlap was
    /// reachable from ordinary use.
    func getFile(path: String, container: String? = nil,
                 stagingDirectory: URL? = nil,
                 completion: @escaping (Result<FileDelivery,
                                               FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
            return
        }
        guard pendingFile == nil else {
            completion(.failure(.init(
                code: "busy",
                message: "Another file transfer is already in progress")))
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

    /// Pulls an item selected from the live Mirror scene. The guest resolves
    /// this human-originated identity independently of the Files share; no
    /// general absolute-path read is exposed to automation or projections.
    func getMirrorFile(source: MirrorFileSource, container: String? = nil,
                       stagingDirectory: URL? = nil,
                       completion: @escaping (Result<FileDelivery,
                                                   FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
            return
        }
        guard session.mirrorTransfer == true else {
            completion(.failure(.init(
                code: "unsupported",
                message: "The connected guest does not support Mirror file transfer; replace and restart the guest application.")))
            return
        }
        guard pendingFile == nil else {
            completion(.failure(.init(
                code: "busy",
                message: "Another file transfer is already in progress")))
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
        session.sendMirrorFileGet(
            id: id, source: source, container: container,
            stagingDirectory: stagingDirectory
                ?? FileManager.default.temporaryDirectory)
    }

    /// Redeems one drag gesture over `continuity.grab`.
    ///
    /// Everything about the ANSWER is the Mirror get above — one pending
    /// waiter, one watchdog, the same `deliverFile` — because the grab is
    /// served down the ordinary file lane. What differs is the ASK: no path
    /// and no source, only the generation the guest itself published, which
    /// is what keeps a read outside the share bounded by what a person
    /// selected by hand.
    func grabContinuityFile(
        epoch: UInt32, generation: UInt32, container: String? = nil,
        stagingDirectory: URL,
        completion: @escaping (Result<FileDelivery, FileFailure>) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(.failure(.init(
                code: "disconnected",
                message: "No \(MachineNaming.commonNoun) is connected")))
            return
        }
        /* GENERATION 0 IS NOT A GENERATION. It is what a stub carries when
           the only thing this Mac has heard about the gesture is the
           resident's mid-drag announcement — an identity, sent before any
           generation was minted. The Macintosh mints them and refuses every
           number it did not, so asking with a zero would spend the one
           grab this transfer gets on a certain `stale-selection`. Refused
           here instead, by name, so the reason names the race rather than
           the symptom. */
        guard generation != 0 else {
            completion(.failure(.init(
                code: "drag-not-yet-named",
                message: "the Mac named this file mid-drag but has not "
                    + "published the generation a grab must ask for yet")))
            return
        }
        guard pendingFile == nil else {
            completion(.failure(.init(
                code: "busy",
                message: "Another file transfer is already in progress")))
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
        session.sendContinuityGrab(
            id: id, epoch: epoch, generation: generation,
            container: container, stagingDirectory: stagingDirectory)
    }

    /// Same one-waiter rule as `getFile` above, for the same reason: this is
    /// the same lane and the same single `pendingFile` slot.
    func getDevelopmentProjectFile(projectID: String, path: String,
                                   stagingDirectory: URL,
                                   completion: @escaping (
                                    Result<FileDelivery, FileFailure>) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
            return
        }
        guard pendingFile == nil else {
            completion(.failure(.init(
                code: "busy",
                message: "Another file transfer is already in progress")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingFile = completion
        fileWatchdogId = id
        armWatchdog(id: id, seconds: 20) { [weak self] reason in
            self?.deliverFile(.failure(.init(code: "timeout", message: reason)))
        }
        session.sendDevelopmentProjectFileGet(
            id: id, projectID: projectID, path: path,
            stagingDirectory: stagingDirectory)
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

    /// Copies a host file to the exact release target represented by Mirror.
    /// It shares the checked bulk lane but is deliberately separate from the
    /// Files share path and never requests move or overwrite semantics.
    func putMirrorFile(
        name: String,
        target: MirrorFileDrop,
        container: String,
        bytes: Data,
        fileType: String? = nil,
        creator: String? = nil,
        modified: Int? = nil,
        completion: @escaping (Result<Void, FileFailure>) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(.failure(.init(
                code: "disconnected",
                message: "No \(MachineNaming.commonNoun) is connected")))
            return
        }
        guard session.mirrorTransfer == true else {
            completion(.failure(.init(
                code: "unsupported",
                message: "The connected guest does not support Mirror file transfer; replace and restart the guest application.")))
            return
        }
        let checksum = TransferIdentity.crc32(bytes)
        startPut(
            name: name, into: "", container: container,
            byteCount: bytes.count, crc32: checksum,
            fileType: fileType, creator: creator, modified: modified,
            createParents: false, overwrite: false,
            developmentCandidate: nil, mirrorDrop: target
        ) { result in
            completion(result.map { _ in () })
        } offer: { [weak session] offer in
            session?.sendFileOffer(offer, bytes: bytes, crc32: checksum)
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
            createParents: true, overwrite: overwrite,
            developmentCandidate: nil, completion: completion
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
            createParents: false, overwrite: overwrite,
            developmentCandidate: nil, completion: completion
        ) { [weak session] offer in
            session?.sendFileOffer(offer, source: source)
        }
    }

    /// Project publication uses the ordinary checked bulk lane but gives the
    /// guest a candidate identity instead of a Files-share path. This method
    /// is intentionally internal to the host coordinator; no projection or
    /// local-protocol request carries its destination field.
    func putDevelopmentCandidateFileWithReceipt(
        candidateID: String,
        name: String,
        into path: String,
        bytes: Data,
        completion: @escaping (Result<PutReceipt, FileFailure>) -> Void
    ) {
        workScheduler.submitCallback(
            .bulk("publish project candidate"), as: .bulk,
            onCancel: {
                completion(.failure(.init(
                    code: "session-changed",
                    message: "The Mac changed before the candidate file was sent")))
            }
        ) { [weak self] _, finish in
            guard let self else { finish(); return }
            self.putDevelopmentCandidateFileAdmitted(
                candidateID: candidateID, name: name, into: path,
                bytes: bytes
            ) { result in
                completion(result)
                finish()
            }
        }
    }

    private func putDevelopmentCandidateFileAdmitted(
        candidateID: String,
        name: String,
        into path: String,
        bytes: Data,
        completion: @escaping (Result<PutReceipt, FileFailure>) -> Void
    ) {
        let checksum = TransferIdentity.crc32(bytes)
        startPut(
            name: name, into: path, container: "macbinary",
            byteCount: bytes.count, crc32: checksum,
            fileType: nil, creator: nil, modified: nil,
            createParents: true, overwrite: false,
            developmentCandidate: candidateID, completion: completion
        ) { [weak session] offer in
            session?.sendFileOffer(offer, bytes: bytes, crc32: checksum)
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
        developmentCandidate: String?,
        mirrorDrop: MirrorFileDrop? = nil,
        completion: @escaping (Result<PutReceipt, FileFailure>) -> Void,
        offer: (FileOffer) -> Void
    ) {
        guard session != nil, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No \(MachineNaming.commonNoun) is connected")))
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
                bytes: byteCount, crc32: crc32),
            developmentCandidate: developmentCandidate,
            mirrorDrop: mirrorDrop))
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

    /// Best-effort stop of an update artifact still crossing the wire.
    /// `installUpdate` never sets `pendingPut`/`putId` — the artifact goes
    /// out via `sendUpdateArtifact` in reaction to the GUEST's own
    /// `update.request`, not through `putFile`'s host-initiated push
    /// bookkeeping — so this calls `cancelOutbound()` directly rather than
    /// routing through `cancelFile()`'s pendingPut branch, which would
    /// never fire for an update. It settles nothing locally: unlike
    /// `cancelFile`, the caller (`ConnectionsModel.cancelUpdate`) owns
    /// `pendingUpdates`/`updateNotices` and settles those itself the same
    /// way a watchdog timeout does, through `finishUpdate`.
    ///
    /// A no-op once the guest already has every byte and is running
    /// `now_update_install` synchronously — nothing on the wire can
    /// interrupt a Toolbox call already in flight on a cooperatively
    /// scheduled guest. That window is exactly what
    /// `updateResultWatchdogSeconds` exists to bound instead.
    func cancelUpdateTransfer(for key: GuestKey) {
        guard activeKey == key else { return }
        session?.cancelOutbound()
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
        let who = MachineNaming.title(session?.guestName)
        return quiet > 20
            ? "\(who) stopped answering — it may be showing a dialog or "
              + "otherwise busy."
            : "\(who) did not answer in time."
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
            /* The guest's disk is no longer what the last listing said.
               Published before the completion so a page that reloads on
               the event does not race the caller's own handler. */
            events.publish(.fileTreeChanged(
                activeKey, side: .guest,
                path: result.path ?? ""))
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
        /* A front or a quit that the guest SERVED changed its process
           table. Neither guest pushes that fact, so this is the only
           moment the host can know it — and it is the moment an agent's
           `process.quit` becomes visible on a page nobody clicked. */
        guard result.ok else { return }
        events.publish(.processListChanged(activeKey))
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
        if pendingPut != nil, putId == refuse.id {
            settlePut(.failure(putFailure(
                code: failure.code,
                message: failure.message,
                guestCleanup: "unknown-before-accept")))
            return
        }
        guard fileWatchdogId == refuse.id else { return }
        let completion = pendingFile
        pendingFile = nil
        fileWatchdogId = nil
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
        workScheduler.submitCallback(
            .capture, as: .foreground,
            onCancel: {
                completion(.failure(.init(
                    message: "The Mac changed before the capture was sent")))
            }) { [weak self] _, finish in
                guard let self else { finish(); return }
                self.requestCaptureAdmitted(depth: depth, tuning: tuning) {
                    result in
                    completion(result)
                    finish()
                }
            }
    }

    private func requestCaptureAdmitted(
        depth: Int?, tuning: CaptureTuning,
        completion: @escaping (Result<CaptureDelivery, CaptureFailure>) -> Void
    ) {
        guard let session, case .connected = state else {
            completion(.failure(.init(message: "No \(MachineNaming.commonNoun) is connected")))
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
            completion(.failure(.init(message: "No \(MachineNaming.commonNoun) is connected")))
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

    /// The in-flight transfer's byte counter — a VALUE several callers read
    /// (the agent transfer lane asks "is one running"), which is why it is
    /// still a property here and not only an event. The event is how a page
    /// finds out it moved; this is how a caller finds out where it got to.
    @Published private(set) var captureProgress: CaptureProgress? {
        didSet {
            guard captureProgress != oldValue else { return }
            if let progress = captureProgress {
                events.publish(.transferProgressed(
                    activeKey, received: progress.received,
                    expected: progress.expected))
            } else {
                events.publish(.transferEnded(activeKey))
            }
        }
    }

    /// Non-nil while a stream bracket is open.
    @Published private(set) var activeStreamId: Int? {
        didSet {
            guard activeStreamId != oldValue else { return }
            events.publish(.streamStateChanged(activeKey, id: activeStreamId))
        }
    }

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
        events.publish(.streamFrame(delivery.guestKey ?? activeKey,
                                    delivery))
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
    /// (`archive/mirror-standalone-2026-08-09/docs/IR-V1.md`), and the only way this layer can obey it is
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
        /// Guest application-owned settlements reconciled against this scene.
        /// nil means an older guest, never an implicit success.
        var settlements: [ActSettlement]?
        var transferMs: Int
        /// What actually crossed the bulk lane for this scene: the whole
        /// document's bytes, the delta's bytes, or zero for a no-change
        /// answer. Recorded rather than inferred, because "deltas save
        /// bytes" is a measurement and this is the number that makes it
        /// one.
        var wireBytes: Int = 0
        /// What the WHOLE document would have measured, on a delta. nil on
        /// every other form.
        var wholeBytes: Int?
        /// Which of the three answers this was.
        var form: SceneForm = .whole
        var guestName: String = Session.unnamedGuest
        var guestKey: GuestKey?
    }

    /// The three answers a scene.request can have. They differ in what
    /// crossed the wire and in nothing else: every one of them delivers a
    /// whole document to everything above this layer, which is why the
    /// reducer never learned that deltas exist.
    enum SceneForm: String, Sendable {
        case whole
        case delta
        case unchanged
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
    /// The exact socket the outstanding scene belongs to. The active picker
    /// may change while a pinned Mirror remains open; without this identity a
    /// late scene from the old active guest could settle the new guest's wait.
    private var pendingSceneGuestKey: GuestKey?
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
    /// Whether a cloud.get from this asker could take the transfer lane
    /// now: nil when it can, else the reason to refuse busy. The
    /// delivery rides the put machinery, which drives the ACTIVE
    /// session — an ask from any other guest cannot be served without
    /// answering the wrong socket.
    func transferLaneObstruction(for asker: Session) -> String? {
        if asker !== session {
            return "another \(MachineNaming.commonNoun) is being driven "
                + "right now"
        }
        if let holder = transferLaneHolder {
            return "the transfer lane is busy: " + holder
        }
        return nil
    }

    private var transferLaneHolder: String? {
        if activeStreamId != nil { return "a live stream is running" }
        if isCapturePending { return "a screenshot is on its way" }
        if session?.previewInFlight == true {
            return "a preview is on its way"
        }
        switch fileTransferInFlight {
        case .outgoing:
            return "a file is going to \(MachineNaming.simpleReference)"
        case .incoming:
            return "a file is coming from \(MachineNaming.simpleReference)"
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
    func requestScene(for requestedKey: GuestKey? = nil,
                      staleAfterMs: Int? = nil, semantics: Bool = true,
                      interaction: Bool = true,
                      tuning: CaptureTuning = .init(),
                      completion: @escaping (Result<SceneDelivery,
                                                    SceneFailure>) -> Void) {
        guard let targetKey = requestedKey ?? activeKey,
              let targetSession = sessions[targetKey] else {
            completion(.failure(.init(
                message: "No \(MachineNaming.commonNoun) is connected")))
            return
        }
        guard !isScenePending else {
            completion(.failure(.init(
                message: "A scene is already on its way. Ask again when it arrives.")))
            return
        }
        /* Existing callers drive the active session and keep the full local
           lane guard. A pinned background Mirror has its own guest-side lane;
           this host has no background transfer ledger yet, so it sends one
           addressed request and lets that guest return the typed busy refusal
           rather than consulting another guest's lane state. */
        if requestedKey == nil, let holder = transferLaneHolder {
            completion(.failure(.init(
                message: MachineNaming.title(targetSession.guestName)
                    + " can move one thing at a time and "
                    + "\(holder). Ask again when it is done.")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingScene = completion
        pendingSceneGuestKey = targetKey
        sceneWatchdogId = id
        /* A walk is not a screen grab: it visits every process and window
           through the extension, on a machine whose whole job used to be
           one thing at a time. 20s matches the capture lane, and the
           watchdog dies of SILENCE rather than duration anyway, so a slow
           walk that is still sending survives it. */
        armWatchdog(id: id, seconds: 20) { [weak self] reason in
            self?.deliverScene(.failure(.init(message: reason)))
        }
        targetSession.sendSceneRequest(id: id, staleAfterMs: staleAfterMs,
                                       semantics: semantics,
                                       interaction: interaction,
                                       tuning: tuning)
    }

    func invalidateSceneBaseline(for key: GuestKey) {
        sessions[key]?.invalidateSceneBaseline()
    }

    fileprivate func deliverScene(
        _ result: Result<SceneDelivery, SceneFailure>,
        from guestKey: GuestKey? = nil) {
        if let guestKey, guestKey != pendingSceneGuestKey { return }
        let completion = pendingScene
        pendingScene = nil
        pendingSceneGuestKey = nil
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
            /* Cleared BEFORE the completion runs. The completion is where
               the next cycle's work starts, and a watchdog left armed on
               a settled id is one `nextCommandId` wrap away from expiring
               somebody else's request. */
            clearWatchdog(result.id)
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
        events.publish(.guestReportedError(activeKey, problem))
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

    private func listenerStateChanged(_ nwState: NWListener.State,
                                      port: UInt16) {
        switch nwState {
        case .ready:
            failedPorts[port] = nil
            readyPorts.insert(port)
            note("Listening on port \(port)")
            if case .connected = state { return }
            state = .listening(port: boundPort ?? port)
        case .failed(let error):
            /* One port failing is not the host failing. Another profile's
               listener may be serving a real machine right now, and taking
               the whole app to `.failed` over a port something else holds
               would take that machine off the desk to report a problem it
               does not have. The state falls over only when nothing is
               left listening at all. */
            failedPorts[port] = error.localizedDescription
            readyPorts.remove(port)
            note("Listener on \(port) failed: \(error.localizedDescription)")
            if boundPorts.isEmpty {
                state = .failed(error.localizedDescription)
            }
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

    private func accept(_ connection: NWConnection,
                        on acceptedPort: UInt16? = nil) {
        let origin = SessionRef()
        /* Host-observed, before a byte of the guest's own account of
           itself has been read. This is the fact the machine registry
           anchors on precisely because the guest had no say in it. And
           with a listener per profile the PORT is host-observed in the
           same sense and for the same reason: the guest chose which one to
           dial, but it cannot claim to have arrived on another. */
        let address = GuestAddress(endpoint: connection.endpoint)
        let listenPort = acceptedPort ?? boundPort
        /// True when this connection is the one the request-shaped API is
        /// driving — so its answers are the ones our waiters are owed.
        func fromActive() -> Bool {
            origin.session != nil && origin.session === session
        }
        let newSession = Session(
            connection: connection, identity: identity, timing: timing,
            pacing: pacing, address: address,
            admit: { [weak self] hello in
                guard let self else { return "the host is shutting down" }
                /* A liveness channel is not a guest and is not counted as
                   one. Bounding it by `maxGuests` would mean a host at its
                   limit refusing the very channel that tells it which of
                   its guests are still there. */
                if hello.role == ConnectionRole.resident.rawValue {
                    return nil
                }
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
                return self.mintSessionKey(
                    hello: hello, address: address, listenPort: listenPort)
            },
            onActive: { [weak self] activated in
                guard let self else { return }
                self.pending.removeAll { $0 === activated }
                /* Filed by FINGERPRINT and returned early — before the
                   `guestKey` a resident deliberately does not have. It
                   must never reach the guest bookkeeping below, or the
                   console, the modules and the agent projection would all
                   be offered a connection that cannot answer a single
                   command. */
                if activated.role == .resident {
                    guard let print = activated.machineFingerprint else {
                        return
                    }
                    self.residents[print]?.close(
                        sending: Bye(code: .normal,
                                     reason: "replaced by a newer resident "
                                         + "channel from this machine"))
                    self.residents[print] = activated
                    self.note("Resident liveness channel for "
                              + activated.guestName,
                              area: "wire", level: .info)
                    return
                }
                guard let key = activated.guestKey else { return }
                self.sessions[key] = activated
                for offer in self.updateProvider.offers {
                    activated.sendUpdateOffer(offer)
                }
                /* First in is the one being driven; a later arrival is
                   served but does not steal the console out from under
                   whoever is using it. */
                if self.activeKey == nil { self.activeKey = key }
                self.publishActive()
                self.events.publish(.guestConnected(key))
            },
            /* **The verdict on silence, asked of the machine rather than
               assumed from the quiet.** Nothing changes without a resident
               channel: no channel, no proof, close as before — which is
               what keeps the resident component optional. */
            shouldCloseOnSilence: { [weak self, origin] in
                guard let self, let key = origin.session?.guestKey
                else { return true }
                return !self.machineIsAnswering(sessionKey: key)
            },
            onAnswering: { [weak self] session, answering in
                guard let self, let key = session.guestKey,
                      self.sessions[key] === session else { return }
                self.note(answering
                          ? "\(key.machine.slug) is answering again"
                          : "\(key.machine.slug) is starved — the machine "
                            + "is alive but this application is not being "
                            + "scheduled",
                          area: "wire", level: answering ? .info : .warn)
                self.publishActive()
            },
            onLog: { [weak self] text, area, level in
                self?.note(text, area: area, level: level,
                           session: origin.session?.guestKey)
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
                guard let self else { return }
                let originKey = origin.session?.guestKey
                guard fromActive() || originKey == self.pendingSceneGuestKey
                else { return }
                self.recordGuestError(problem)
            },
            onCensusReport: { [weak self] report in
                guard fromActive() else { return }
                self?.resolveCensus(report)
            },
            onContinuityReport: { [weak self] report in
                guard let self, fromActive(),
                      let key = origin.session?.guestKey else { return }
                self.onContinuityReport?(key, report)
            },
            onContinuityKeyReport: { [weak self] report in
                guard let self, fromActive(),
                      let key = origin.session?.guestKey else { return }
                self.onContinuityKeyReport?(key, report)
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
                guard let self, let key = origin.session?.guestKey else {
                    return
                }
                self.deliverScene(result, from: key)
            },
            /* A push is not an answer: a guest sends it unasked, and a
               background guest pushing a screenshot is a thing it is
               entitled to do. It arrives without saying which Mac it came
               from, which is a gap the Screenshots module will have to
               close when it grows a guest column. */
            onPushedCapture: { [weak self] delivery in
                self?.captureProgress = nil
                self?.events.publish(
                    .captureArrived(delivery.guestKey, delivery))
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
                            : "file-done-after-crc32",
                        relaunchRequired: done.relaunchRequired == true)))
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
            onServeContinuityGrab: { [weak self] grab in
                guard let self, let asker = origin.session else { return }
                self.serveContinuityGrab(grab, on: asker)
            },
            onAcceptOffer: { [weak self] offer in
                guard let self, let asker = origin.session else { return }
                self.acceptOffer(offer, on: asker)
            },
            onServeChange: { [weak self] change in
                guard let self, let asker = origin.session else { return }
                self.serveChange(change, on: asker)
            },
            onServeCloud: { [weak self] ask in
                guard let self, let asker = origin.session else { return }
                self.serveCloud(ask, on: asker)
            },
            onServeChat: { [weak self] ask in
                guard let self, let asker = origin.session else { return }
                self.serveChat(ask, on: asker)
            },
            onServeWeb: { [weak self] ask in
                guard let self, let asker = origin.session else { return }
                self.serveWeb(ask, on: asker)
            },
            onServeHostShow: { [weak self] request in
                guard let self, let asker = origin.session else { return }
                self.serveHostShow(request, on: asker)
            },
            onServeUpdate: { [weak self] request in
                guard let self, let asker = origin.session else { return }
                guard let artifact = self.updateProvider.artifact(
                    for: request) else {
                    asker.refuseUpdate(
                        id: request.id,
                        reason: "that published build is no longer available")
                    return
                }
                self.note("#\(request.id) serving \(request.component) "
                          + "update \(request.build)", area: "update",
                          session: asker.guestKey)
                asker.sendUpdateArtifact(artifact, request: request)
            },
            onUpdateResult: { [weak self] result in
                guard let self, let guest = origin.session else { return }
                let detail = result.ok
                    ? (result.action ?? "installed")
                    : (result.reason ?? result.code ?? "failed")
                self.note("#\(result.id) \(result.component) update: \(detail)",
                          area: "update",
                          level: result.ok ? .info : .warn,
                          session: guest.guestKey)
                if let key = guest.guestKey {
                    self.events.publish(.updateFinished(key, result))
                }
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
            onMirrorInvalidation: { [weak self] hint in
                guard let self, let key = origin.session?.guestKey else {
                    return
                }
                self.events.publish(.mirrorInvalidated(key, hint))
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
                if let print = closedSession.machineFingerprint,
                   self.residents[print] === closedSession {
                    /* The machine stopped proving it is alive. Any of its
                       sessions still silent will now be closed at their
                       next silence window rather than held — the verdict
                       is asked again every window for exactly this. */
                    self.residents[print] = nil
                    self.note("Resident liveness channel closed for "
                              + "\(closedSession.guestName) — \(reason)",
                              area: "wire", level: .info)
                    return
                }
                guard let key = closedSession.guestKey,
                      self.sessions[key] === closedSession else { return }
                /* "The LINK dropping ends it immediately" — the offer's
                   own contract clause, distinct from the epoch-end window
                   above: consent was given to one Macintosh over one
                   connection, and this connection is gone. */
                self.continuityOfferService.linkDropped(guestKey: key)
                // A conversation is per connection; a turn still
                // streaming to a dead socket is cancelled, not leaked.
                self.chatService?.sessionClosed(key: key)
                self.webService?.sessionClosed(key: key)
                self.sessions[key] = nil
                self.machineBySession[key] = nil
                self.healthByGuest[key] = nil
                // The next guest under this name is not this one. A
                // capability record that outlived its connection would be
                // the same stale-by-inheritance mistake as reading
                // abilities off a hello name.
                self.familyObservationsByGuest[key] = nil
                self.lastDisconnect = reason
                self.events.publish(
                    .guestDisconnected(key, reason: reason))
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
        /* Set after construction because the Session declares it as a var:
           the stub's consumer is the drag lane, and a required parameter
           would put an empty closure at every construction site and read as
           a wired-up capability. */
        newSession.onContinuitySelection = { [weak self, weak newSession] sel in
            guard let self, let key = newSession?.guestKey,
                  key == self.activeKey else { return }
            self.onContinuitySelection?(key, sel)
        }
        /* The resident channel's one non-liveness frame, routed to the
           application it speaks for. Same active-session gate as the stub
           above: a background Mac's drag is not what this pointer is
           standing on. */
        newSession.onContinuityDragBegin = { [weak self, weak newSession] begin in
            guard let self, let print = newSession?.machineFingerprint,
                  let key = self.sessionKey(forMachine: print),
                  key == self.activeKey else { return }
            self.onContinuityDragBegin?(key, begin)
        }
        origin.session = newSession
        pending.append(newSession)
        newSession.begin()
    }

    // Sessions that have not passed the hello gate yet. An accepted-but-busy
    // connection lives here just long enough to be refused politely.
    private var pending: [Session] = []
}
