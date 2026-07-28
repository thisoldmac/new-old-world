import Foundation
import Network
import CoreGraphics
import Combine
import NOWAgentIntegration

/// The host side of the wire: listens, gates on hello, serves exactly one
/// guest at a time, answers pings, and declares death passively after
/// `timing.idleTimeout` without traffic (the host never pings — see
/// contract/asyncapi.yaml).
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
    private(set) var familyObservations:
        [String: GuestFamilyObservation] = [:]

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
        familyObservations[family] = .init(
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
    private var listener: NWListener?
    private var session: Session?

    init(identity: HostIdentity, timing: Timing = Timing(),
         pacing: Pacing = .classicMac) {
        self.identity = identity
        self.timing = timing
        self.pacing = pacing
    }

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
        session?.close(sending: Bye(code: .shuttingDown, reason: nil))
        session = nil
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
        let live = session
        session = nil
        listener?.cancel()
        listener = nil
        state = .idle

        guard let live else {
            completion()
            return
        }
        var reported = false
        func report() {
            guard !reported else { return }
            reported = true
            completion()
        }
        live.close(sending: Bye(code: .shuttingDown, reason: nil)) {
            report()
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


    /// Answers a listing request from the guest.
    fileprivate func serveList(_ request: FileList) {
        do {
            let page = try share.list(path: request.path,
                                      cursor: request.cursor ?? 1,
                                      limit: 16)
            note("#\(request.id) listed \(page.entries.count) "
                 + "item\(page.entries.count == 1 ? "" : "s") of "
                 + "\(request.path.isEmpty ? "the share root" : request.path)",
                 area: "files")
            session?.send(.fileListing(FileListing(
                id: request.id, path: request.path, entries: page.entries,
                more: page.more, cursor: page.next,
                /* Only the root listing names the place; a subfolder
                   listing already knows where it is. */
                root: request.path.isEmpty ? share.root.path : nil)))
        } catch {
            session?.refuseFile(id: request.id, error: error)
        }
    }

    /// Answers a pull request: the same begin / bulk / end shape the
    /// guest uses, metered the same way.
    fileprivate func serveGet(_ request: FileGet) {
        do {
            let plan = try share.read(
                path: request.path,
                convertText: convertServedText
                    && request.container != "data")
            note("#\(request.id) serving \(plan.name), "
                 + "\(plan.bytes.count) bytes", area: "files")
            session?.serveFile(id: request.id, plan: plan,
                               container: request.container,
                               modified: plan.modified)
        } catch {
            session?.refuseFile(id: request.id, error: error)
        }
    }

    /// A file the guest wants to put into our share. Accepted without
    /// prompting: this side is not necessarily attended either, and the
    /// share is what the human already agreed the other machine may
    /// write into.
    fileprivate func acceptOffer(_ offer: FileOffer) {
        do {
            let url = try share.destination(
                name: offer.name, path: offer.path,
                createParents: offer.createParents ?? true,
                overwrite: offer.overwrite ?? false)
            note("#\(offer.id) accepting \(offer.name), "
                 + "\(offer.bytes) bytes, into the share", area: "files")
            try session?.beginReceiving(offer: offer, to: url)
        } catch {
            session?.refuseFile(id: offer.id, error: error)
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
    fileprivate func serveChange(_ change: ChangeRequest) {
        do {
            switch change {
            case .move(let request):
                let landed = try share.move(from: request.path,
                                            to: request.toPath,
                                            overwrite: request.overwrite
                                                ?? false)
                note("#\(request.id) moved \(request.path) to \(landed)",
                     area: "files")
                session?.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            case .trash(let request):
                let landed = try share.trash(path: request.path)
                /* The other machine putting a file of yours in the
                   Trash is the line most worth having later. */
                note("#\(request.id) trashed \(request.path), it is in the "
                     + "Trash as \(landed)", area: "files")
                session?.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: request.path,
                    trashedAs: landed, code: nil, reason: nil)))
            case .restore(let request):
                let landed = try share.restore(trashedAs: request.trashedAs,
                                               to: request.toPath)
                note("#\(request.id) restored \(request.trashedAs) to "
                     + "\(landed)", area: "files")
                session?.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            case .mkdir(let request):
                let landed = try share.makeFolder(path: request.path)
                note("#\(request.id) made the folder \(landed)",
                     area: "files")
                session?.send(.fileResult(FileResult(
                    id: request.id, ok: true, path: landed,
                    trashedAs: nil, code: nil, reason: nil)))
            }
        } catch {
            let fault = HostShare.WireFault(error)
            note("#\(change.id) change refused: \(fault.code) "
                 + "(\(fault.reason))", area: "files", level: .warn)
            session?.send(.fileResult(FileResult(
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

    fileprivate func noteReceived(_ url: URL) {
        let bytes = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int) ?? nil
        let who: String
        if case .connected(let name) = state { who = name } else {
            who = "the other Mac"
        }
        announceReceivedFile?(who, url, bytes ?? 0)
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
                : "process.front",
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
        sendChange(completion) { session, id in
            session.sendFileMove(FileMove(id: id, path: from, toPath: to,
                                          overwrite: overwrite ? true : nil))
        }
    }

    /// Moves an item to the Trash, and hands back the token that undoes it.
    func trashFile(path: String,
                   completion: @escaping (Result<FileResult,
                                                 FileFailure>) -> Void) {
        sendChange(completion) { session, id in
            session.sendFileTrash(FileTrash(id: id, path: path))
        }
    }

    func restoreFile(trashedAs: String, to path: String,
                     completion: @escaping (Result<FileResult,
                                                   FileFailure>) -> Void) {
        sendChange(completion) { session, id in
            session.sendFileRestore(FileRestore(id: id, trashedAs: trashedAs,
                                                toPath: path))
        }
    }

    func makeFolder(path: String,
                    completion: @escaping (Result<FileResult,
                                                  FileFailure>) -> Void) {
        sendChange(completion) { session, id in
            session.sendFileMkdir(FileMkdir(id: id, path: path))
        }
    }

    /// The shared shape of the four: control-plane, one answer, watchdog.
    private func sendChange(
        _ completion: @escaping (Result<FileResult, FileFailure>) -> Void,
        _ emit: (Session, Int) -> Void) {
        guard let session, case .connected = state else {
            completion(.failure(.init(code: "disconnected",
                                      message: "No Mac is connected")))
            return
        }
        let id = nextCommandId
        nextCommandId += 1
        pendingChanges[id] = completion
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

    /// The reason the guest gave when IT ended the stream ("capture
    /// failed"); nil after a host-requested stop.
    @Published private(set) var streamEndReason: String?

    /// Opens a stream bracket. Frames then arrive on streamFrames until
    /// stopStream() or the guest's own stream.stopped.
    func startStream(depth: Int, minIntervalMs: Int? = nil,
                     tuning: CaptureTuning = .init()) {
        guard let session, case .connected = state,
              activeStreamId == nil else { return }
        let id = nextCommandId
        nextCommandId += 1
        activeStreamId = id
        streamEndReason = nil
        session.beginStream(id: id, depth: depth,
                            minIntervalMs: minIntervalMs, tuning: tuning)
    }

    /// Asks the guest to send its next stream frame whole.
    func refreshStream() {
        guard let id = activeStreamId else { return }
        session?.requestKeyframe(id: id)
    }

    func stopStream() {
        guard let id = activeStreamId else { return }
        session?.requestStreamStop(id: id)
        // Self-heal: a guest that never answers (dead app, dead wire the
        // socket hasn't noticed) must not wedge the bracket open forever.
        stopFallback?.cancel()
        stopFallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self,
                  self.activeStreamId == id else { return }
            self.activeStreamId = nil
            self.streamEndReason = "no answer to stop"
        }
    }

    fileprivate func streamEnded(_ stopped: StreamStopped) {
        guard stopped.id == activeStreamId else { return }
        stopFallback?.cancel()
        stopFallback = nil
        activeStreamId = nil
        streamEndReason = stopped.reason
        captureProgress = nil
    }

    /// The guest asked for a stream: same bracket, host-owned. Accept
    /// unless the lane is taken.
    fileprivate func guestRequestedStream(_ request: StreamRequest) {
        guard activeStreamId == nil else {
            session?.sendError(code: "stream-busy",
                               message: "a stream or transfer is active")
            return
        }
        startStream(depth: request.depth)
    }

    fileprivate func streamSessionClosed() {
        guard activeStreamId != nil else { return }
        stopFallback?.cancel()
        stopFallback = nil
        activeStreamId = nil
        streamEndReason = "connection lost"
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

    struct CaptureDelivery {
        var image: CGImage
        var format: CaptureFormat
        var transferMs: Int
        var wireBytes: Int
    }

    private var pendingCapture:
        ((Result<CaptureDelivery, CaptureFailure>) -> Void)?
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
        // Only now, and only if somebody was actually answered. Clearing
        // the watchdog first looked tidier and was a trap: a waiter this
        // function forgets to route would then have neither an answer nor
        // a timeout, and would hang forever rather than merely slowly.
        // The mutation that removed three of these lines proved it by
        // hanging the suite instead of failing it.
        if routed { clearWatchdog(id) }
    }

    private func failAllPending(_ reason: String) {
        // The next guest is not this one. A capability record that
        // outlived its connection would be the same stale-by-inheritance
        // mistake as reading abilities off a hello name.
        familyObservations = [:]
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

    private func accept(_ connection: NWConnection) {
        let newSession = Session(
            connection: connection, identity: identity, timing: timing,
            pacing: pacing,
            isBusy: { [weak self] in
                guard let session = self?.session else { return nil }
                return session.guestName
            },
            onActive: { [weak self] activated in
                guard let self else { return }
                self.pending.removeAll { $0 === activated }
                self.session = activated
                self.state = .connected(guestName: activated.guestName)
            },
            onLog: { [weak self] text, area, level in
                self?.note(text, area: area, level: level)
            },
            onHealth: { [weak self] health in self?.health = health },
            onCommandResult: { [weak self] result in
                self?.resolveCommand(result)
            },
            onExecOutput: { [weak self] output in
                self?.resolveExecOutput(output)
            },
            onExecResult: { [weak self] result in
                self?.resolveExecResult(result)
            },
            onGuestError: { [weak self] problem in
                self?.recordGuestError(problem)
            },
            onCensusReport: { [weak self] report in
                self?.resolveCensus(report)
            },
            onCapture: { [weak self] result in
                self?.deliverCapture(result)
            },
            onCaptureProgress: { [weak self] progress in
                self?.noteCaptureProgress(progress)
            },
            onPushedCapture: { [weak self] delivery in
                self?.captureProgress = nil
                self?.pushedCaptures.send(delivery)
            },
            onStreamFrame: { [weak self] delivery in
                self?.streamFrames.send(delivery)
            },
            onStreamStopped: { [weak self] stopped in
                self?.streamEnded(stopped)
            },
            onStreamRequest: { [weak self] request in
                self?.guestRequestedStream(request)
            },
            onFileListing: { [weak self] listing in
                self?.resolveListing(listing)
            },
            onFileResult: { [weak self] result in
                self?.resolveChange(result)
            },
            onFileRefuse: { [weak self] refuse in
                self?.failFile(refuse)
            },
            onFileDelivery: { [weak self] result in
                self?.deliverFile(result)
            },
            onFileDone: { [weak self] done in
                guard let self else { return }
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
                guard let self, self.putId == progress.id else { return }
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
                guard let self, self.putId == accept.id else { return }
                self.putAccepted = accept
            },
            onServeList: { [weak self] request in
                self?.serveList(request)
            },
            onServeGet: { [weak self] request in
                self?.serveGet(request)
            },
            onAcceptOffer: { [weak self] offer in
                self?.acceptOffer(offer)
            },
            onServeChange: { [weak self] change in
                self?.serveChange(change)
            },
            onProcessListing: { [weak self] listing in
                self?.resolveProcessListing(listing)
            },
            onSoftwareListing: { [weak self] listing in
                self?.resolveSoftwareListing(listing)
            },
            onProcessResult: { [weak self] result in
                self?.resolveProcessResult(result)
            },
            onReceived: { [weak self] url in
                self?.noteReceived(url)
            },
            onOutboundProgress: { [weak self] sent, total in
                guard let self else { return }
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
                guard let self else { return }
                self.settlePut(.failure(self.putFailure(
                    code: "io-error",
                    message: message,
                    guestCleanup: "unknown-after-local-read-failure")))
            },
            onClosed: { [weak self] closedSession, reason in
                guard let self else { return }
                self.pending.removeAll { $0 === closedSession }
                guard self.session === closedSession else { return }
                self.streamSessionClosed()
                self.session = nil
                self.health = nil
                self.failAllPending(reason)
                self.lastDisconnect = reason
                if self.listener != nil {
                    self.state = .listening(port: self.boundPort ?? 0)
                }
            })
        pending.append(newSession)
        newSession.begin()
    }

    // Sessions that have not passed the hello gate yet. An accepted-but-busy
    // connection lives here just long enough to be refused politely.
    private var pending: [Session] = []
}

/// One connection's lifecycle: awaiting hello -> active -> closed.
@MainActor
final class Session {
    let connection: NWConnection
    private let identity: GuestListener.HostIdentity
    private let timing: GuestListener.Timing
    private let pacing: GuestListener.Pacing
    private let isBusy: () -> String?
    private let onActive: (Session) -> Void
    private let onLog: (String, String, HostLog.LogLevel) -> Void
    private let onHealth: (GuestListener.SessionHealth?) -> Void
    private let onCommandResult: (CommandResult) -> Void
    private let onExecOutput: (ExecOutput) -> Void
    private let onExecResult: (ExecResult) -> Void
    private let onGuestError: (ErrorMessage) -> Void
    private let onCensusReport: (CensusReport) -> Void
    private let onCapture:
        (Result<GuestListener.CaptureDelivery, GuestListener.CaptureFailure>)
        -> Void
    private let onCaptureProgress: (GuestListener.CaptureProgress?) -> Void
    private let onPushedCapture: (GuestListener.CaptureDelivery) -> Void
    private let onStreamFrame: (GuestListener.CaptureDelivery) -> Void
    private let onStreamStopped: (StreamStopped) -> Void
    private let onStreamRequest: (StreamRequest) -> Void
    private let onFileListing: (FileListing) -> Void
    private let onFileResult: (FileResult) -> Void
    private let onFileRefuse: (FileRefuse) -> Void
    private let onFileDelivery:
        (Result<GuestListener.FileDelivery, GuestListener.FileFailure>) -> Void
    private let onFileDone: (FileDone) -> Void
    private let onFileProgress: (FileProgress) -> Void
    private let onFileAccept: (FileAccept) -> Void
    private let onServeList: (FileList) -> Void
    private let onServeGet: (FileGet) -> Void
    private let onAcceptOffer: (FileOffer) -> Void
    private let onServeChange: (GuestListener.ChangeRequest) -> Void
    private let onProcessListing: (ProcessListing) -> Void
    private let onSoftwareListing: (SoftwareListing) -> Void
    private let onProcessResult: (ProcessResult) -> Void
    private let onReceived: (URL) -> Void
    private let onOutboundProgress: (Int, Int) -> Void
    private let onOutboundFailed: (String) -> Void
    private var streamId: Int?
    private let onClosed: (Session, String) -> Void

    /// In-flight bulk transfer (one at a time by contract).
    private var captureBegin: CaptureBegin?
    private var captureBuffer: [UInt8] = []
    private var captureStart = Date()
    private var cancelled = false
    /// The stream's composite: raw pixels + palette that delta frames
    /// patch into. Reset on every keyframe; dropped with the stream.
    private var canvas: [UInt8] = []
    private var canvasPalette: [UInt8] = []
    private var canvasFormat: CaptureFormat?
    /// Non-nil while a host-requested capture is outstanding; a transfer
    /// that begins without it is a guest-initiated push.
    private var solicitedId: Int?
    private var acceptedOfferId: Int?
    /// In-flight file pull: the begin that announced it and the bounded
    /// disk sink receiving its bulk frames.
    private var fileBegin: FileBegin?
    private var fileSink: InboundFileSink?
    private var fileStagingDirectory = FileManager.default.temporaryDirectory
    private var fileStart = Date()
    /// A transfer the host has abandoned. The guest drains to its frame
    /// boundary before stopping, so bytes keep arriving for a transfer
    /// nothing is waiting on; swallow them rather than calling it a
    /// protocol error and closing a healthy session.
    private var discardingTransfer: Int?
    private var health: GuestListener.SessionHealth?

    private let decoder = FrameDecoder()
    private var helloed = false
    private var closed = false
    private(set) var guestName = "guest"
    private var idleTask: Task<Void, Never>?

    init(connection: NWConnection,
         identity: GuestListener.HostIdentity,
         timing: GuestListener.Timing,
         pacing: GuestListener.Pacing,
         isBusy: @escaping () -> String?,
         onActive: @escaping (Session) -> Void,
         onLog: @escaping (String, String, HostLog.LogLevel) -> Void,
         onHealth: @escaping (GuestListener.SessionHealth?) -> Void,
         onCommandResult: @escaping (CommandResult) -> Void,
         onExecOutput: @escaping (ExecOutput) -> Void,
         onExecResult: @escaping (ExecResult) -> Void,
         onGuestError: @escaping (ErrorMessage) -> Void,
         onCensusReport: @escaping (CensusReport) -> Void,
         onCapture: @escaping (Result<GuestListener.CaptureDelivery,
                                      GuestListener.CaptureFailure>) -> Void,
         onCaptureProgress: @escaping (GuestListener.CaptureProgress?) -> Void,
         onPushedCapture: @escaping (GuestListener.CaptureDelivery) -> Void,
         onStreamFrame: @escaping (GuestListener.CaptureDelivery) -> Void,
         onStreamStopped: @escaping (StreamStopped) -> Void,
         onStreamRequest: @escaping (StreamRequest) -> Void,
         onFileListing: @escaping (FileListing) -> Void,
         onFileResult: @escaping (FileResult) -> Void,
         onFileRefuse: @escaping (FileRefuse) -> Void,
         onFileDelivery: @escaping (Result<GuestListener.FileDelivery,
                                           GuestListener.FileFailure>)
             -> Void,
         onFileDone: @escaping (FileDone) -> Void,
         onFileProgress: @escaping (FileProgress) -> Void,
         onFileAccept: @escaping (FileAccept) -> Void,
         onServeList: @escaping (FileList) -> Void,
         onServeGet: @escaping (FileGet) -> Void,
         onAcceptOffer: @escaping (FileOffer) -> Void,
         onServeChange: @escaping (GuestListener.ChangeRequest) -> Void,
         onProcessListing: @escaping (ProcessListing) -> Void,
         onSoftwareListing: @escaping (SoftwareListing) -> Void,
         onProcessResult: @escaping (ProcessResult) -> Void,
         onReceived: @escaping (URL) -> Void,
         onOutboundProgress: @escaping (Int, Int) -> Void,
         onOutboundFailed: @escaping (String) -> Void,
         onClosed: @escaping (Session, String) -> Void) {
        self.connection = connection
        self.identity = identity
        self.timing = timing
        self.pacing = pacing
        self.isBusy = isBusy
        self.onActive = onActive
        self.onLog = onLog
        self.onHealth = onHealth
        self.onCommandResult = onCommandResult
        self.onExecOutput = onExecOutput
        self.onExecResult = onExecResult
        self.onGuestError = onGuestError
        self.onCensusReport = onCensusReport
        self.onCapture = onCapture
        self.onCaptureProgress = onCaptureProgress
        self.onPushedCapture = onPushedCapture
        self.onStreamFrame = onStreamFrame
        self.onStreamStopped = onStreamStopped
        self.onStreamRequest = onStreamRequest
        self.onFileListing = onFileListing
        self.onFileResult = onFileResult
        self.onFileRefuse = onFileRefuse
        self.onFileDelivery = onFileDelivery
        self.onFileDone = onFileDone
        self.onFileProgress = onFileProgress
        self.onFileAccept = onFileAccept
        self.onServeList = onServeList
        self.onServeGet = onServeGet
        self.onAcceptOffer = onAcceptOffer
        self.onServeChange = onServeChange
        self.onProcessListing = onProcessListing
        self.onSoftwareListing = onSoftwareListing
        self.onProcessResult = onProcessResult
        self.onReceived = onReceived
        self.onOutboundProgress = onOutboundProgress
        self.onOutboundFailed = onOutboundFailed
        self.onClosed = onClosed
    }

    func begin() {
        connection.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor in
                switch nwState {
                case .failed, .cancelled:
                    self?.finish(reason: "Connection lost")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receiveLoop()
        resetIdleClock()
    }

    func close(sending bye: Bye) {
        finish(reason: "Closed", sending: .bye(bye))
    }

    /// `close(sending:)` with a receipt: `flushed` fires once the socket has
    /// taken the farewell (or immediately if there was nothing to send).
    /// ⌘Q waits on this — see GuestListener.shutDown.
    func close(sending bye: Bye, flushed: @escaping () -> Void) {
        finish(reason: "Closed", sending: .bye(bye), flushed: flushed)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.resetIdleClock()
                    self.consume(data)
                }
                if done || error != nil {
                    self.finish(reason: "Connection lost")
                } else if !self.closed {
                    self.receiveLoop()
                }
            }
        }
    }

    private func touchHealth(framesDelta: Int = 0, pingsDelta: Int = 0) {
        guard var h = health else { return }
        h.lastTraffic = Date()
        h.framesReceived += framesDelta
        h.pingsAnswered += pingsDelta
        health = h
        onHealth(h)
    }

    private func consume(_ data: Data) {
        let frames: [Frame]
        do {
            frames = try decoder.feed(data)
        } catch {
            protocolError("malformed frame: \(error)")
            return
        }
        touchHealth(framesDelta: frames.count)
        for frame in frames {
            switch frame.header.channel {
            case .control:
                handleControl(frame.payload)
            case .bulk:
                if let discarding = discardingTransfer,
                   Int(frame.header.transfer) == discarding {
                    break
                }
                if let inbound {
                    do {
                        try inbound.sink.append(frame.payload)
                        if let received = inbound.sink.takeProgressReport() {
                            send(.fileProgress(FileProgress(
                                id: inbound.id, received: received)))
                        }
                    } catch {
                        failInboundStream(
                            transfer: Int(frame.header.transfer),
                            error: error)
                    }
                    break
                }
                if let begin = fileBegin {
                    do {
                        try fileSink?.append(frame.payload)
                        let received = fileSink?.receivedBytes ?? 0
                        if fileSink?.takeProgressReport() != nil {
                            send(.fileProgress(FileProgress(
                                id: begin.id, received: received)))
                            onCaptureProgress(.init(
                                received: received,
                                expected: begin.bytes))
                        }
                    } catch {
                        failPulledStream(
                            transfer: Int(frame.header.transfer),
                            error: error)
                    }
                    break
                }
                guard captureBegin != nil else {
                    protocolError("bulk frame with no transfer in flight")
                    return
                }
                captureBuffer.append(contentsOf: frame.payload)
                if let begin = captureBegin, begin.id != streamId {
                    onCaptureProgress(.init(received: captureBuffer.count,
                                            expected: begin.bytes))
                }
            }
            if closed { return }
        }
    }

    private func handleControl(_ payload: Data) {
        let message: ControlMessage
        do {
            message = try ControlMessageCodec.decode(payload)
        } catch {
            /* A frame we cannot read is not a reason to drop a working
               connection. These two halves ship separately: a verb one
               side has learned and the other has not would otherwise
               brick the older peer, and a single missing field would
               take down a transfer that was fine — which is exactly the
               shape of bug this cost us once already, where the visible
               symptom was "the connection dropped and nothing arrived".
               The hello handshake below stays strict; after that, we
               say loudly what we could not read and keep the wire. */
            if !helloed {
                protocolError("bad control message: \(error)")
                return
            }
            onLog("ignored an unreadable control message: \(error)",
                  "wire", .warn)
            return
        }
        guard helloed else {
            guard case .hello(let hello) = message else {
                protocolError("expected hello first")
                return
            }
            gate(hello)
            return
        }
        switch message {
        case .ping(let id):
            send(.pong(id: id))
            touchHealth(pingsDelta: 1)
        case .commandResult(let result):
            onCommandResult(result)
        case .execOutput(let output):
            onExecOutput(output)
        case .execResult(let result):
            onExecResult(result)
        case .execRequest, .execCancel:
            /* Declared asymmetry, the same shape as softwareList above: the
               exec plane has only ever run host-to-guest. This host serves
               no commands, so there is nothing for it to interpret a line
               with, and inventing an answer would make it a third face. */
            break
        case .censusReport(let report):
            onCensusReport(report)
        case .censusRequest(let request):
            serveCensusRefusal(request)
        case .fileListing(let listing):
            onFileListing(listing)
        case .fileResult(let result):
            onFileResult(result)
        case .fileList(let request):
            onServeList(request)
        case .processListing(let listing):
            onProcessListing(listing)
        case .processResult(let result):
            onProcessResult(result)
        case .softwareListing(let listing):
            onSoftwareListing(listing)
        case .softwareList:
            // Declared asymmetry, the process.list rule: the host asks
            // and never serves. Ignoring is the contract's word.
            break
        case .fileGet(let request):
            onServeGet(request)
        case .fileOffer(let offer):
            onAcceptOffer(offer)
        case .fileMove(let request):
            onServeChange(.move(request))
        case .fileTrash(let request):
            onServeChange(.trash(request))
        case .fileRestore(let request):
            onServeChange(.restore(request))
        case .fileMkdir(let request):
            onServeChange(.mkdir(request))
        case .fileAccept(let accept):
            onFileAccept(accept)
            sendAcceptedFile(accept)
        case .fileDone(let done):
            onFileDone(done)
        case .fileProgress(let progress):
            noteOutboundAck(progress)
            onFileProgress(progress)
        case .fileRefuse(let refuse):
            fileBegin = nil
            fileSink?.abort()
            fileSink = nil
            onFileRefuse(refuse)
        case .fileBegin(let begin):
            if inbound?.id == begin.id {
                break                 // a push we already accepted
            }
            do {
                fileSink = try InboundFileSink(
                    directory: fileStagingDirectory,
                    expectedBytes: begin.bytes)
                fileBegin = begin
                fileStart = Date()
                onCaptureProgress(.init(received: 0, expected: begin.bytes))
            } catch {
                failPulledStream(transfer: begin.transfer, error: error)
            }
        case .fileEnd(let end):
            if inbound?.id == end.id {
                finishInbound(end)
            } else {
                finishFile(end)
            }
        case .streamRequest(let request):
            onStreamRequest(request)
        case .streamStopped(let stopped):
            if stopped.id == streamId {
                streamId = nil
                canvas = []
                canvasPalette = []
                canvasFormat = nil
            }
            onStreamStopped(stopped)
        case .captureOffer(let offer):
            answerOffer(offer)
        case .captureBegin(let begin):
            captureBegin = begin
            captureStart = Date()
            captureBuffer = []
            captureBuffer.reserveCapacity(begin.bytes)
            if begin.id != streamId {
                onCaptureProgress(.init(received: 0, expected: begin.bytes))
            }
        case .captureEnd(let end):
            finishCapture(end)
        case .bye(let bye):
            let name = guestName
            finish(reason: byeDescription(bye, guest: name))
        case .hello:
            protocolError("duplicate hello")
        case .error(let problem):
            // The contract's answer to a message a peer does not
            // implement, and the host used to drop it here. NOW-68K
            // implements almost none of the contract, so it sends these
            // routinely — and because nothing routed them, a request that
            // had been REFUSED, instantly and explicitly, reached the
            // caller as a 15s timeout carrying no reason at all. Silence
            // and refusal are different answers; only one of them means
            // "ask again later".
            onLog("guest error: [\(problem.code)] \(problem.message)",
                  "wire", .warn)
            onGuestError(problem)
        default:
            // capture flow arrives with the screenshots slice
            break
        }
    }

    /// One transfer at a time is the contract's rule, so accepting is just
    /// "is the lane free" — the offer's contents don't need vetting: the
    /// bulk plane only carries pixels.
    private func answerOffer(_ offer: CaptureOffer) {
        guard captureBegin == nil, solicitedId == nil, streamId == nil else {
            send(.captureRefuse(CaptureRefuse(
                id: offer.id, reason: "busy: a transfer is in flight")))
            return
        }
        acceptedOfferId = offer.id
        onLog("\(guestName) offers a \(offer.width)x\(offer.height) "
              + "\(offer.depth)-bit screenshot (\(offer.bytes / 1024) KB)",
              "capture", .info)
        send(.captureAccept(CaptureAccept(id: offer.id)))
    }

    func beginStream(id: Int, depth: Int, minIntervalMs: Int?,
                     tuning: GuestListener.CaptureTuning) {
        streamId = id
        send(.streamStart(StreamStart(
            id: id, depth: depth, minIntervalMs: minIntervalMs,
            chunkKb: tuning.chunkKb, paceMs: tuning.paceMs,
            pack: tuning.pack, predictive: tuning.predictive,
            interlace: tuning.interlace)))
    }

    func sendFileList(id: Int, path: String, cursor: Int?) {
        send(.fileList(FileList(id: id, path: path, cursor: cursor)))
    }

    func sendProcessList(id: Int, cursor: Int?) {
        send(.processList(ProcessList(id: id, cursor: cursor)))
    }

    func sendSoftwareList(id: Int, domain: String, cursor: Int?) {
        send(.softwareList(SoftwareList(id: id, domain: domain,
                                        cursor: cursor)))
    }

    func sendProcessDrive(id: Int, psnHigh: Int, psnLow: Int,
                          verb: GuestListener.ProcessVerb) {
        switch verb {
        case .front:
            send(.processFront(ProcessFront(
                id: id, psnHigh: psnHigh, psnLow: psnLow)))
        case .quit:
            send(.processQuit(ProcessQuit(
                id: id, psnHigh: psnHigh, psnLow: psnLow)))
        }
    }

    func sendFileMove(_ m: FileMove) { send(.fileMove(m)) }
    func sendFileTrash(_ m: FileTrash) { send(.fileTrash(m)) }
    func sendFileRestore(_ m: FileRestore) { send(.fileRestore(m)) }
    func sendFileMkdir(_ m: FileMkdir) { send(.fileMkdir(m)) }

    func sendFileGet(id: Int, path: String, container: String?,
                     stagingDirectory: URL) {
        fileBegin = nil
        fileSink?.abort()
        fileSink = nil
        fileStagingDirectory = stagingDirectory
        fileStart = Date()
        send(.fileGet(FileGet(id: id, path: path, container: container)))
    }

    func cancelFile() {
        guard let begin = fileBegin else { return }
        discardingTransfer = begin.transfer
        fileBegin = nil
        fileSink?.abort()
        fileSink = nil
        send(.fileCancel(FileCancel(transfer: begin.transfer)))
    }

    /// Holds an offered file until the guest accepts it. The bytes wait
    /// here rather than riding with the offer: a refusal (busy, a name
    /// collision) must cost nothing but the message.
    private enum OfferedSource {
        case memory(Data, crc32: UInt32?)
        case staged(OutboundFileSource)
    }

    private var pendingOffer: (offer: FileOffer, source: OfferedSource)?
    private var transferSeq: UInt16 = 0

    func sendFileOffer(_ offer: FileOffer, bytes: Data, crc32: UInt32?) {
        pendingOffer = (offer, .memory(bytes, crc32: crc32))
        send(.fileOffer(offer))
    }

    func sendFileOffer(_ offer: FileOffer, source: OutboundFileSource) {
        pendingOffer = (offer, .staged(source))
        send(.fileOffer(offer))
    }

    private func nextTransfer() -> UInt16 {
        transferSeq &+= 1
        if transferSeq == 0 { transferSeq = 1 }
        return transferSeq
    }

    /// An outbound file in flight. Chunks go one at a time, each sent
    /// when the previous one has actually left — queueing a whole file
    /// into the socket at once would give the wire no backpressure,
    /// nothing to report progress from, and nothing to cancel.
    private struct Outbound {
        var id: Int
        var transfer: UInt16
        var source: Source
        var sent: Int
        var cancelled: Bool
        /// Over the WHOLE file, computed once when the transfer was
        /// staged. A resumed file is stitched from two attempts and
        /// this seam is what nothing else checks.
        var crc32: UInt32?
        /// Bytes the guest has said it holds. The window is measured
        /// against this, never against `sent`.
        var acked: Int = 0
        /// Set once the guest has reported at all. Until then there is
        /// nothing to clock against and the window stays open, which is
        /// what an older guest that never reports keeps forever.
        var acking: Bool = false
        /// True while a frame is being withheld for want of window.
        var parked: Bool = false
        /// Prevents an ACK callback from scheduling a second file read while
        /// the dedicated staging executor is servicing the current chunk.
        var reading: Bool = false

        enum Source {
            case memory(Data)
            case staged(OutboundFileSource.Reader)

            var byteCount: Int {
                switch self {
                case .memory(let bytes): bytes.count
                case .staged(let reader): reader.byteCount
                }
            }

            func read(offset: Int, count: Int) async throws -> Data {
                switch self {
                case .memory(let bytes):
                    return Data(bytes[offset..<(offset + count)])
                case .staged(let reader):
                    return try await reader.readAsync(
                        offset: offset, count: count)
                }
            }
        }
    }

    private var outbound: Outbound?

    /// Turns any serving failure into the one refusal the contract has.
    func refuseFile(id: Int, error: Error) {
        let fault = HostShare.WireFault(error)
        /* Logged with the SAME words that go on the wire: a refusal the
           other machine reports and a refusal in this file that read
           differently are two things to reconcile later. */
        onLog("#\(id) refused: \(fault.code) (\(fault.reason))",
              "files", .warn)
        send(.fileRefuse(FileRefuse(id: id, code: fault.code,
                                    reason: fault.reason)))
    }

    /// Serves a file we hold: begin, metered bulk, end — the same path
    /// an outbound put takes, because it is the same journey.
    func serveFile(id: Int, plan: OutboundFile.Plan, container: String?,
                   modified: Int?) {
        let transfer = nextTransfer()
        send(.fileBegin(FileBegin(
            id: id, transfer: Int(transfer), name: plan.name,
            container: container == "macbinary" ? "macbinary"
                                                : plan.container,
            bytes: plan.bytes.count, dataBytes: nil, rsrcBytes: nil,
            fileType: plan.fileType, creator: plan.creator,
            modified: modified)))
        outbound = Outbound(
                            id: id, transfer: transfer,
                            source: .memory(plan.bytes),
                            sent: 0, cancelled: false,
                            crc32: TransferIdentity.crc32(plan.bytes))
        onOutboundProgress(0, plan.bytes.count)
        sendNextOutboundChunk()
    }

    /// An inbound push: open its same-folder temporary file before
    /// accepting, so an unwritable or full destination is refused before
    /// the sender spends time on bytes we cannot keep.
    func beginReceiving(offer: FileOffer, to url: URL) throws {
        let sink = try InboundFileSink(
            directory: url.deletingLastPathComponent(),
            expectedBytes: offer.bytes)
        inbound = Inbound(id: offer.id, url: url, name: offer.name,
                          container: offer.container,
                          expected: offer.bytes,
                          fileType: offer.fileType,
                          modified: offer.modified, sink: sink)
        send(.fileAccept(FileAccept(id: offer.id)))
    }

    private struct Inbound {
        var id: Int
        var url: URL
        var name: String
        var container: String
        var expected: Int
        var fileType: String?
        var modified: Int?
        var sink: InboundFileSink
    }

    private var inbound: Inbound?

    /// Writes a completed push and tells the sender it landed. The
    /// answer waits for the disk, as the guest's does: a put is not
    /// finished until the file exists.
    private func finishInbound(_ end: FileEnd) {
        guard let file = inbound, file.id == end.id else { return }
        inbound = nil
        guard end.ok else {
            file.sink.abort()
            send(.fileDone(FileDone(
                id: end.id, ok: false, code: "io-error",
                reason: "the sender stopped")))
            return
        }
        do {
            let staged = try file.sink.finish(expectedCRC32: end.crc32)
            let outputName = FileConverter.outputName(
                name: file.name, container: file.container)
            let url = file.url.deletingLastPathComponent()
                .appendingPathComponent(outputName)
            try FileConverter.materialize(
                name: file.name, container: file.container,
                fileType: file.fileType, staged: staged, to: url)
            if let seconds = file.modified,
               let date = ClassicDate.date(from: seconds) {
                try? FileManager.default.setAttributes(
                    [.modificationDate: date], ofItemAtPath: url.path)
            }
            onReceived(url)
            onLog("#\(end.id) received \(url.lastPathComponent), "
                  + "\(file.expected) bytes", "files", .info)
            send(.fileDone(FileDone(id: end.id, ok: true, code: nil,
                                    reason: nil)))
        } catch {
            send(.fileDone(FileDone(id: end.id, ok: false,
                                    code: "io-error",
                                    reason: "\(error)")))
        }
    }

    /// How far ahead of the receiver the sender may run.
    ///
    /// The pacing gap only works while the kernel's send buffer is
    /// EMPTY: a paced write leaves TCP nothing to fire on the next ACK,
    /// which is the entire mechanism. Offering bytes faster than the
    /// link carries them builds a backlog in that buffer, and from the
    /// moment it is non-empty TCP sends back-to-back on every ACK no
    /// matter how politely the app is writing. The gap is still in the
    /// code and no longer on the wire — which is why a transfer runs at
    /// 340 KB/s until the buffer fills and then collapses to ~5 KB/s and
    /// never recovers (see docs/large-transfers.md).
    ///
    /// Clocking on the receiver's own count keeps the backlog bounded,
    /// so the gap stays real for the whole transfer. Six 32 KB progress
    /// steps is enough to keep the wire busy across a skipped report —
    /// `received` is cumulative, so one later report reopens the window
    /// whatever was dropped in between.
    /// NOW_WINDOW overrides it (0 = no window at all), because a flow
    /// control rule has to be falsifiable at the wire: the only way to
    /// know what the window costs is to run the same transfer without
    /// it against the same machine.
    static let outboundWindowBytes: Int = {
        if let raw = ProcessInfo.processInfo.environment["NOW_WINDOW"],
           let n = Int(raw) {
            return n
        }
        return 3 * outboundFrameBytes
    }()

    /// Bulk frame size for a host->guest file, deliberately smaller than
    /// the 32 KB the frame header allows.
    ///
    /// The window above cannot be tighter than the rate at which the
    /// receiver acknowledges, and the guest acknowledges once per frame
    /// (`kPutProgressStep`, wire.c). At 32 KB frames the tightest usable
    /// window was 64 KB, which still lets ~1.4 MB reach the wire before
    /// the sender is ever held back. Smaller frames buy a proportionally
    /// tighter window: this is the geometry TimBotTu measured at
    /// ~300 KiB/s sustained on this same PowerBook — 4 KB chunks under a
    /// 12 KiB in-flight cap — rather than a number picked to be small.
    ///
    /// Nothing on the wire changes: kNowMaxPayload is a ceiling, the
    /// guest reassembles a byte stream, and it cannot tell.
    static let outboundFrameBytes: Int = {
        if let raw = ProcessInfo.processInfo.environment["NOW_FRAME"],
           let n = Int(raw), n > 0,
           n <= FrameHeader.maxPayloadLength {
            return n
        }
        return 8192
    }()

    /// Folds a guest progress report into the window and restarts the
    /// sender if it was parked.
    private func noteOutboundAck(_ progress: FileProgress) {
        guard var out = outbound, out.id == progress.id else { return }
        out.acking = true
        out.acked = max(out.acked, progress.received)
        let wasParked = out.parked
        out.parked = false
        outbound = out
        if wasParked { sendNextOutboundChunk() }
    }

    /// Streams an accepted file: begin, the bulk frames, then end.
    /// The host's share of the symmetric census family: a well-formed
    /// refusal for every probe, until a later slice grows an IOKit-backed
    /// census of this Mac. The asymmetry is in the implementation, never
    /// the contract.
    private func serveCensusRefusal(_ request: CensusRequest) {
        send(.censusReport(CensusReport(
            id: request.id, probe: request.probe, outcome: "refused",
            rows: [], more: false, cursor: nil, total: nil,
            note: "the host does not serve a census yet")))
    }

    private func sendAcceptedFile(_ accept: FileAccept) {
        guard let pending = pendingOffer,
              pending.offer.id == accept.id else { return }
        pendingOffer = nil
        let offer = pending.offer
        let source: Outbound.Source
        let checksum: UInt32?
        do {
            switch pending.source {
            case .memory(let bytes, let crc32):
                source = .memory(bytes)
                checksum = crc32
            case .staged(let staged):
                source = .staged(try staged.openReader())
                checksum = staged.crc32
            }
        } catch {
            onOutboundFailed(
                "the private staged upload changed before transfer")
            return
        }
        let transfer = nextTransfer()
        // Resume where the guest says it already is. Trust but bound it:
        // a `have` past the end of the file, or one offered without our
        // token, would silently skip bytes that were never sent.
        var start = 0
        if let have = accept.have, have > 0, have < source.byteCount,
           offer.resumeToken != nil {
            start = have
            onLog("Resuming at \(have) of \(source.byteCount) bytes",
                  "wire", .info)
        }
        send(.fileBegin(FileBegin(
            id: offer.id, transfer: Int(transfer), name: offer.name,
            container: offer.container, bytes: source.byteCount,
            dataBytes: nil, rsrcBytes: nil, fileType: offer.fileType,
            creator: offer.creator, modified: offer.modified,
            offset: start > 0 ? start : nil,
            resumeToken: offer.resumeToken)))
        outbound = Outbound(id: offer.id, transfer: transfer, source: source,
                            sent: start, cancelled: false, crc32: checksum,
                            acked: start)
        onOutboundProgress(start, source.byteCount)
        sendNextOutboundChunk()
    }

    private func sendNextOutboundChunk() {
        guard var out = outbound else { return }
        guard !out.reading else { return }
        if out.cancelled {
            outbound = nil
            send(.fileEnd(FileEnd(id: out.id, transfer: Int(out.transfer),
                                  ok: false, sendMs: nil)))
            return
        }
        guard out.sent < out.source.byteCount else {
            outbound = nil
            // Over the WHOLE file, not the bytes this session sent: a
            // resumed file is stitched from two attempts and the seam is
            // exactly what nothing else checks.
            send(.fileEnd(FileEnd(id: out.id, transfer: Int(out.transfer),
                                  ok: true, sendMs: nil, crc32: out.crc32)))
            return
        }
        // Wait for the receiver to catch up rather than piling bytes into
        // a send buffer it cannot drain. Parking here is what a progress
        // report un-parks; if progress stops altogether the transfer is
        // genuinely dead and the put watchdog says so.
        if out.acking, Self.outboundWindowBytes > 0,
           out.sent - out.acked >= Self.outboundWindowBytes {
            out.parked = true
            outbound = out
            return
        }
        let end = min(out.sent + Self.outboundFrameBytes,
                      out.source.byteCount)
        let last = end == out.source.byteCount
        let readOffset = out.sent
        out.reading = true
        outbound = out
        Task { @MainActor [weak self] in
            let payload: Data
            do {
                payload = try await out.source.read(
                    offset: readOffset, count: end - readOffset)
            } catch {
                guard let self, self.outbound?.id == out.id else { return }
                self.outbound = nil
                self.onOutboundFailed(
                    "the private staged upload could not be read completely")
                return
            }
            guard let self, var current = self.outbound,
                  current.id == out.id,
                  current.transfer == out.transfer,
                  current.sent == readOffset else {
                return
            }
            current.reading = false
            guard let frame = try? FrameCodec.encode(
                channel: .bulk, flags: last ? [.end] : [],
                transfer: current.transfer, payload: payload) else {
                self.outbound = nil
                self.send(.fileEnd(FileEnd(
                    id: current.id, transfer: Int(current.transfer),
                    ok: false, sendMs: nil)))
                return
            }
            current.sent = end
            self.outbound = current
            let progress = current.sent
            let total = current.source.byteCount
            self.sendMetered(frame) { [weak self] error in
                guard let self else { return }
                if let error {
                    // Swallowing this reported a full progress bar for
                    // bytes that never left: the transfer looked
                    // complete while a third of the file had arrived.
                    self.outbound = nil
                    self.onOutboundFailed("the connection refused the "
                                          + "data: \(error)")
                    return
                }
                self.onOutboundProgress(progress, total)
                self.sendNextOutboundChunk()
            }
        }
    }

    /// Hands one frame to TCP in metered pieces (see Pacing).
    ///
    /// The gap is the point: it has to be real quiet time on the wire,
    /// not just a smaller write. Handing the socket the whole frame lets
    /// TCP send back-to-back the moment the window allows, which is what
    /// this peer's card drops. Writing a piece and pausing leaves the
    /// send buffer empty, so TCP has nothing to fire when the next ACK
    /// arrives and the following piece goes out on its own.
    ///
    /// Ordering is safe: NWConnection delivers queued sends in order, so
    /// the pieces reassemble into the same byte stream the guest would
    /// have seen anyway — it never learns the frame was split.
    private func sendMetered(_ frame: Data,
                             completion: @escaping (NWError?) -> Void) {
        guard pacing.bytes > 0, frame.count > pacing.bytes else {
            connection.send(content: frame, completion: .contentProcessed {
                error in
                Task { @MainActor in completion(error) }
            })
            return
        }
        bulkFramePartiallySent = true
        sendPiece(frame, from: frame.startIndex) { [weak self] error in
            guard let self else { completion(error); return }
            // The frame is whole on the wire again, so anything held back
            // can go out — before the next frame starts and closes the
            // window again.
            self.bulkFramePartiallySent = false
            self.drainControlQueue { completion(error) }
        }
    }

    private func sendPiece(_ frame: Data, from offset: Data.Index,
                           completion: @escaping (NWError?) -> Void) {
        let end = min(offset + pacing.bytes, frame.endIndex)
        let last = end >= frame.endIndex
        let started = GuestListener.Pacing.traceEnabled ? Date() : nil
        connection.send(content: frame[offset..<end],
                        completion: .contentProcessed { [weak self] error in
            if let started {
                let ms = Date().timeIntervalSince(started) * 1000
                Task { @MainActor [weak self] in
                    GuestListener.Pacing.trace.append(
                        (atByte: self?.outbound?.sent ?? 0, ms: ms))
                }
            }
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let error { completion(error); return }
                if last { completion(nil); return }
                // Cancellation lands between pieces as well as between
                // frames: a stopped transfer should not keep metering
                // out the rest of a 32 KB frame it has abandoned.
                if self.outbound?.cancelled == true {
                    completion(nil)
                    return
                }
                try? await Task.sleep(
                    nanoseconds: UInt64(self.pacing.gap * 1_000_000_000))
                self.sendPiece(frame, from: end, completion: completion)
            }
        })
    }

    /// Stops an outbound file at the next chunk boundary — never
    /// mid-frame, which would desync the peer's decoder.
    func cancelOutbound() {
        if pendingOffer != nil {
            pendingOffer = nil
        }
        outbound?.cancelled = true
    }

    func clearOutboundRequest(id: Int) {
        if pendingOffer?.offer.id == id {
            pendingOffer = nil
        }
        if outbound?.id == id {
            outbound?.cancelled = true
        }
    }

    func requestStreamStop(id: Int) {
        send(.streamStop(StreamStop(id: id)))
    }

    func sendError(code: String, message: String) {
        send(.error(ErrorMessage(id: nil, code: code, message: message)))
    }

    func requestKeyframe(id: Int) {
        send(.streamRefresh(StreamRefresh(id: id)))
    }

    /// Applies a stream frame to the composite and renders it. Key frames
    /// replace the canvas; deltas patch rects into it; empty frames rerender
    /// it untouched.
    private func compositeStreamFrame(_ begin: CaptureBegin, blob: [UInt8],
                                      format: CaptureFormat) throws
        -> CGImage {
        switch begin.frame ?? "key" {
        case "delta":
            guard canvasFormat != nil, !canvas.isEmpty else {
                throw GuestListener.CaptureFailure(
                    message: "delta frame with no keyframe base")
            }
            var cursor = 0
            for rect in begin.rects ?? [] {
                try CaptureDecoder.applyRect(rect, blob: blob,
                                             cursor: &cursor,
                                             format: format,
                                             canvas: &canvas)
            }
        case "empty":
            guard canvasFormat != nil, !canvas.isEmpty else {
                throw GuestListener.CaptureFailure(
                    message: "empty frame with no keyframe base")
            }
        default:
            // A keyframe replaces the canvas, so a malformed one silently
            // redefines the whole screen. The one malformation seen in the
            // field: a guest exporting an interlaced FIELD — half the rows,
            // same width and stride — through the key path. It resized the
            // canvas to half height and every later delta patched into the
            // shrunken canvas, so the stream stayed half a screen forever.
            // Reject it; the guest's next key frame reconciles us.
            if let base = canvasFormat, !canvas.isEmpty,
               format.width == base.width, format.rowBytes == base.rowBytes,
               format.depth == base.depth, base.height > 1,
               format.height * 2 == base.height {
                throw GuestListener.CaptureFailure(
                    message: "half-height key frame (an interlaced field "
                        + "sent as a key); keeping the canvas")
            }
            let (palette, pixels) = try CaptureDecoder.decodeRows(
                blob, format: format)
            canvas = pixels
            canvasPalette = palette
            canvasFormat = format
        }
        guard let base = canvasFormat else {
            throw GuestListener.CaptureFailure(message: "no stream canvas")
        }
        return try CaptureDecoder.renderImage(pixels: canvas,
                                              palette: canvasPalette,
                                              format: base)
    }

    private func failPulledStream(transfer: Int, error: Error) {
        discardingTransfer = transfer
        fileBegin = nil
        fileSink?.abort()
        fileSink = nil
        send(.fileCancel(FileCancel(transfer: transfer)))
        onFileDelivery(.failure(.init(
            code: "io-error", message: error.localizedDescription)))
    }

    private func failInboundStream(transfer: Int, error: Error) {
        guard let inbound else { return }
        discardingTransfer = transfer
        self.inbound = nil
        inbound.sink.abort()
        send(.fileCancel(FileCancel(transfer: transfer)))
        send(.fileDone(FileDone(
            id: inbound.id, ok: false, code: "io-error",
            reason: error.localizedDescription)))
    }

    private func finishFile(_ end: FileEnd) {
        if discardingTransfer == end.transfer {
            discardingTransfer = nil
            fileBegin = nil
            fileSink?.abort()
            fileSink = nil
            return                    /* the host already gave up on it */
        }
        guard let begin = fileBegin, let sink = fileSink else { return }
        fileBegin = nil
        fileSink = nil
        guard end.ok else {
            sink.abort()
            onFileDelivery(.failure(.init(
                code: "io-error",
                message: "the guest could not send \(begin.name)")))
            return
        }
        let staged: InboundFileSink.StagedFile
        do {
            staged = try sink.finish(expectedCRC32: end.crc32)
        } catch {
            onFileDelivery(.failure(.init(
                code: "io-error",
                message: error.localizedDescription)))
            return
        }
        onFileDelivery(.success(.init(
            name: begin.name, container: begin.container,
            fileType: begin.fileType, creator: begin.creator,
            modified: begin.modified, staged: staged,
            transferMs: Int(Date().timeIntervalSince(fileStart) * 1000))))
    }

    private func finishCapture(_ end: CaptureEnd) {
        if discardingTransfer == end.transfer {
            discardingTransfer = nil
            captureBegin = nil
            captureBuffer = []
            cancelled = false
            return                    /* the host already gave up on it */
        }
        let streaming = streamId != nil && captureBegin?.id == streamId
        let pushed = !streaming && solicitedId == nil
        guard let begin = captureBegin else {
            if !pushed {
                solicitedId = nil
                onCapture(.failure(.init(
                    message: "capture ended without a begin")))
            }
            return
        }
        captureBegin = nil
        acceptedOfferId = nil
        guard end.ok else {
            if streaming {
                cancelled = false
                return               /* an aborted frame; the bracket rules */
            }
            if pushed {
                onLog("\(guestName)'s screenshot push failed", "wire", .info)
            } else {
                solicitedId = nil
                onCapture(.failure(.init(message: cancelled
                    ? "Capture cancelled"
                    : "the guest could not capture the screen")))
            }
            cancelled = false
            return
        }
        let format = CaptureFormat(
            width: begin.width, height: begin.height, depth: begin.depth,
            rowBytes: begin.rowBytes, bytes: begin.bytes,
            paletteBytes: begin.paletteBytes ?? 0,
            packed: (begin.encoding ?? "raw") == "packbits",
            captureMs: begin.captureMs ?? 0, encodeMs: begin.encodeMs ?? 0)
        let blob = captureBuffer
        captureBuffer = []
        do {
            let image: CGImage
            if streaming {
                image = try compositeStreamFrame(begin, blob: blob,
                                                 format: format)
            } else {
                image = try CaptureDecoder.makeImage(blob: blob,
                                                     format: format)
            }
            let ms = Int(Date().timeIntervalSince(captureStart) * 1000)
            let delivery = GuestListener.CaptureDelivery(
                image: image, format: format,
                transferMs: ms, wireBytes: blob.count)
            if streaming {
                onStreamFrame(delivery)
            } else if pushed {
                onPushedCapture(delivery)
            } else {
                solicitedId = nil
                onCapture(.success(delivery))
            }
        } catch {
            if streaming {
                onLog("dropped an undecodable stream frame: \(error)", "wire", .info)
            } else if pushed {
                onLog("could not decode \(guestName)'s screenshot: \(error)", "wire", .info)
            } else {
                solicitedId = nil
                onCapture(.failure(.init(
                    message: "could not decode the capture: \(error)")))
            }
        }
    }

    private func gate(_ hello: Hello) {
        if hello.contract != Contract.revision {
            refuse("contract revision \(hello.contract) != \(Contract.revision)")
            return
        }
        if let connectedName = isBusy() {
            refuse("busy: \(connectedName)")
            return
        }
        helloed = true
        guestName = hello.name ?? "Classic Mac"
        let chunk = min(hello.chunk ?? Contract.defaultChunk,
                        Contract.defaultChunk)
        send(.hello(Hello(contract: Contract.revision, side: "host",
                          version: identity.version, name: identity.name,
                          os: nil, chunk: chunk)))
        let now = Date()
        health = GuestListener.SessionHealth(
            guestName: guestName, guestVersion: hello.version,
            guestOS: hello.os, connectedAt: now, lastTraffic: now,
            pingsAnswered: 0, framesReceived: 1)
        onHealth(health)
        var line = "Connected: \(guestName)"
        if !hello.version.isEmpty {
            line += " (guest \(hello.version)"
            line += hello.os.map { ", OS \($0))" } ?? ")"
        }
        onLog(line, "wire", .info)
        onActive(self)
    }

    private func refuse(_ reason: String) {
        onLog("Refused a connection: \(reason)", "wire", .info)
        finish(reason: "Refused: \(reason)",
               sending: .refuse(Refuse(contract: Contract.revision,
                                       reason: reason)))
    }

    private func protocolError(_ detail: String) {
        finish(reason: "Protocol error: \(detail)",
               sending: .bye(Bye(code: .protocolError, reason: detail)))
    }

    func sendCommand(_ request: CommandRequest) {
        send(.commandRequest(request))
    }

    /// Tells the guest to stop sending. The transfer is settled by the
    /// capture.end that follows, not here — so a guest that already finished
    /// still delivers its image rather than losing it to a late cancel.
    func cancelCapture() {
        guard let begin = captureBegin else { return }
        cancelled = true
        discardingTransfer = begin.transfer
        send(.captureCancel(CaptureCancel(transfer: begin.transfer)))
    }

    func sendCaptureRequest(id: Int, depth: Int?,
                            tuning: GuestListener.CaptureTuning) {
        captureBegin = nil
        captureBuffer = []
        cancelled = false
        solicitedId = id
        captureStart = Date()
        send(.captureRequest(CaptureRequest(
            id: id, depth: depth ?? 0, chunkKb: tuning.chunkKb,
            paceMs: tuning.paceMs, pack: tuning.pack)))
    }

    /// A window-cropped capture of one process. The answer rides the same
    /// capture transport a plain request uses, so the receive state is
    /// primed identically — only the message asking for it differs.
    func sendProcessShot(id: Int, psnHigh: Int, psnLow: Int, depth: Int?) {
        captureBegin = nil
        captureBuffer = []
        cancelled = false
        solicitedId = id
        captureStart = Date()
        send(.processShot(ProcessShot(
            id: id, psnHigh: psnHigh, psnLow: psnLow, depth: depth)))
    }

    /// Control frames waiting for the bulk frame in flight to finish.
    /// See `send(_:)` for why they cannot simply go out.
    private var controlQueue: [Data] = []
    /// True from the first piece of a bulk frame to its last. Metering
    /// splits a frame across many sends with gaps between them, and a
    /// control frame written into one of those gaps lands INSIDE the
    /// frame on the wire.
    private var bulkFramePartiallySent = false

    /// Queues a control frame, holding it back while a bulk frame is
    /// half-written.
    ///
    /// The guest's decoder gives bulk absolute priority: while
    /// `bulk_remaining > 0` every byte it reads is file data, unexamined
    /// (`next_frame`, wire.c). A control frame that arrives mid-frame is
    /// therefore written into the file, and the stream is desynced by
    /// its whole length — the next 8 bytes the guest reads as a header
    /// are file content. That is either an instant protocol error or,
    /// worse, a plausible length that silently swallows the rest.
    ///
    /// The guest already refuses to do this to us
    /// (`bulk_frame_partially_sent`, wire.c); this is the missing mirror.
    /// Waiting costs one frame — ~70 ms at the metered rate — which is
    /// what keeps a cancel or a status request responsive during bulk
    /// without a second connection.
    fileprivate func send(_ message: ControlMessage) {
        guard let payload = try? ControlMessageCodec.encode(message),
              let frame = try? FrameCodec.encode(channel: .control,
                                                 payload: payload) else {
            return
        }
        guard bulkFramePartiallySent else {
            connection.send(content: frame, completion: .idempotent)
            return
        }
        controlQueue.append(frame)
    }

    /// Writes everything held back, at a frame boundary where it is safe.
    /// Each still gets the pacing gap: this peer's card drops a frame
    /// that lands on the heels of another, and a control frame followed
    /// immediately by the next bulk piece is exactly that shape.
    private func drainControlQueue(_ completion: @escaping () -> Void) {
        guard !controlQueue.isEmpty else { completion(); return }
        let frame = controlQueue.removeFirst()
        connection.send(content: frame, completion: .contentProcessed {
            [weak self] _ in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if self.pacing.gap > 0 {
                    try? await Task.sleep(nanoseconds:
                        UInt64(self.pacing.gap * 1_000_000_000))
                }
                self.drainControlQueue(completion)
            }
        })
    }

    private func resetIdleClock() {
        idleTask?.cancel()
        let timeout = timing.idleTimeout
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            guard !Task.isCancelled else { return }
            self?.finish(reason: "Connection lost (no traffic)")
        }
    }

    /// Ends the session. When a farewell message is given it is flushed
    /// before the connection is cancelled — cancel() drops unsent data,
    /// which would eat the very refuse/bye the peer needs to see.
    private func finish(reason: String, sending farewell: ControlMessage? = nil,
                        flushed: (() -> Void)? = nil) {
        guard !closed else {
            flushed?()
            return
        }
        closed = true
        fileSink?.abort()
        fileSink = nil
        inbound?.sink.abort()
        inbound = nil
        if helloed {
            onLog(reason, "wire", .info)
        }
        idleTask?.cancel()
        if let farewell,
           let payload = try? ControlMessageCodec.encode(farewell),
           let frame = try? FrameCodec.encode(channel: .control,
                                              payload: payload) {
            let connection = self.connection
            connection.send(content: frame,
                            completion: .contentProcessed { _ in
                connection.cancel()
                if let flushed {
                    Task { @MainActor in flushed() }
                }
            })
        } else {
            connection.cancel()
            flushed?()
        }
        onClosed(self, reason)
    }

    private func byeDescription(_ bye: Bye, guest: String) -> String {
        switch bye.code {
        case .normal: return "\(guest) disconnected"
        case .shuttingDown: return "\(guest) is shutting down"
        case .protocolError:
            return "Protocol error: \(bye.reason ?? "unspecified")"
        }
    }
}
