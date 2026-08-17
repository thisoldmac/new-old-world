import Foundation
import Network
import CoreGraphics
import Combine
import NOWAgentIntegration

// One connection, extracted from GuestListener.swift where it shared a
// file with the listener that owns it. The two were never entangled: a
// Session reaches its owner ONLY through the closures it is constructed
// with (onLog, onHealth, onFileListing, ...), never by touching the
// listener directly. That boundary was already the design; this file
// makes it visible, and makes it hold - a stored property the listener
// keeps private is now genuinely out of reach here rather than merely
// unused.

/// One connection's lifecycle: awaiting hello -> active -> closed.
@MainActor
final class Session {
    let connection: NWConnection
    private let identity: GuestListener.HostIdentity
    private let timing: GuestListener.Timing
    private let pacing: GuestListener.Pacing
    /// Asked once, with the guest's own hello, at the gate: nil to serve
    /// this connection, or the reason to refuse it.
    ///
    /// It takes the hello because the answer used to depend on WHO was
    /// dialling. It no longer does — identity is per CONNECTION now, so
    /// no arriving guest can collide with one already here and the only
    /// refusal left is the host's own limit. The hello stays in the
    /// signature because the refusal text is written for the guest that
    /// will read it.
    private let admit: (Hello) -> String?
    /// The peer address, observed off the connection at accept. Handed to
    /// `identify` at the gate, where it anchors the machine id.
    private let address: GuestAddress
    /// Mints this connection's session identity. Asked once, at the gate,
    /// because the machine id it embeds depends on the hello.
    private let identify: (Hello, GuestAddress) -> GuestKey
    private let onActive: (Session) -> Void
    /// Asked when a silence window expires: may this session be closed?
    /// The listener answers no while some other channel proves the machine
    /// is alive. Defaults to yes, which is the behaviour that predates the
    /// resident channel and the behaviour with no resident present.
    private let shouldCloseOnSilence: () -> Bool
    /// Told when this session crosses between answering and starved, so
    /// the face can show which — a starved guest displayed as connected is
    /// how a person concludes the Mirror is broken.
    private let onAnswering: (Session, Bool) -> Void
    private let onLog: (String, String, HostLog.LogLevel) -> Void
    private let onHealth: (GuestListener.SessionHealth?) -> Void
    private let onCommandResult: (CommandResult) -> Void
    private let onExecOutput: (ExecOutput) -> Void
    private let onExecResult: (ExecResult) -> Void
    private let onGuestError: (ErrorMessage) -> Void
    private let onCensusReport: (CensusReport) -> Void
    private let onContinuityReport: (ContinuityReport) -> Void
    private let onContinuityKeyReport: (ContinuityKeyReport) -> Void
    /* A `var` rather than an init parameter, unlike its neighbours. It was
       nil when the stub had no consumer; the listener now sets it, and the
       shape stays because nil remains the honest state for a session that
       is not the active one — the frame still decodes, so an unbound stub
       can never drop a connection. */
    var onContinuitySelection: ((ContinuitySelection) -> Void)?
    /* The one thing a RESIDENT channel says that is not liveness. A `var`
       for the same reason as its neighbour above: nil is honest for a
       channel nobody is listening to, and an unbound frame must never
       drop a machine's heartbeat. */
    var onContinuityDragBegin: ((ContinuityDragBegin) -> Void)?
    private let onCapture:
        (Result<GuestListener.CaptureDelivery, GuestListener.CaptureFailure>)
        -> Void
    private let onCaptureProgress: (GuestListener.CaptureProgress?) -> Void
    private let onScene:
        (Result<GuestListener.SceneDelivery, GuestListener.SceneFailure>)
        -> Void
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
    /// The inverted direction: a guest redeeming THIS host's published
    /// offer. Same message the host sends to redeem the guest's
    /// selection (`onFileDelivery` answers that one); this is the other
    /// sender using it.
    private let onServeContinuityGrab: (ContinuityGrab) -> Void
    private let onAcceptOffer: (FileOffer) -> Void
    private let onServeChange: (GuestListener.ChangeRequest) -> Void
    private let onServeCloud: (GuestListener.CloudAsk) -> Void
    private let onServeChat: (GuestListener.ChatAsk) -> Void
    private let onServeWeb: (GuestListener.WebAsk) -> Void
    private let onServeHostShow: (HostShow) -> Void
    private let onServeUpdate: (UpdateRequest) -> Void
    private let onUpdateResult: (UpdateResult) -> Void
    private let onProcessListing: (ProcessListing) -> Void
    private let onSoftwareListing: (SoftwareListing) -> Void
    private let onProcessResult: (ProcessResult) -> Void
    private let onMirrorInvalidation: (MirrorInvalidate) -> Void
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
    /// In-flight scene: the begin that announced it and the JSON document
    /// its bulk frames are. Held in memory rather than staged to disk like
    /// a file, because a scene is tens of kilobytes and the thing that
    /// wants it is a decoder, not a path.
    private var sceneBegin: SceneBegin?
    private var sceneBuffer: [UInt8] = []
    private var sceneStart = Date()
    /// The id of the outstanding `scene.request`. There is no such thing as
    /// a pushed scene — the guest only walks when asked — so a scene
    /// arriving without this is a stray, not a gift.
    private var sceneSolicitedId: Int?
    /// THE DELTA BASELINE, and its lifetime is exactly right by
    /// construction: a `Session` is one connection, so a reconnect cannot
    /// inherit a baseline and a guest that restarted cannot be quoted one.
    ///
    /// It is held HERE rather than by the Mirror source because nothing
    /// above this layer should have to learn what a digest is. The caller
    /// asks for a scene; this decides whether to name a baseline, and
    /// hands up a whole document either way.
    private var sceneBaseline: MirrorSceneDelta.Baseline?
    /// The `since` the outstanding request quoted, so an answer can be
    /// proved to be about the baseline we named rather than another one.
    private var sceneAskedBaseline: String?
    /// How many deltas this side has applied against the current chain.
    ///
    /// The guest bounds the chain too, at 64. This is a SECOND, INDEPENDENT
    /// bound, and it is deliberately not the same number: a bound that only
    /// the producer enforces is a bound that stops existing the moment the
    /// producer is the thing that is wrong. Re-proving the whole mirror
    /// every fifty scenes costs one document a minute at the cadence the
    /// Mirror actually polls at.
    private var sceneDeltaRun = 0
    static let sceneResyncEvery = 50
    private var acceptedOfferId: Int?
    /// In-flight file pull: the begin that announced it and the bounded
    /// disk sink receiving its bulk frames.
    private var fileBegin: FileBegin?
    private var fileSink: InboundFileSink?
    /// The request that may legitimately produce the next pulled-file
    /// begin. A cancel can happen before the guest assigns a transfer ID;
    /// retain that abandoned request ID so its late begin cannot be mistaken
    /// for a replacement request on the same one-wide lane.
    private var activeFileGetID: Int?
    private var abandonedFileGetIDs: [Int] = []
    private static let abandonedFileGetLimit = 64
    private var fileStagingDirectory = FileManager.default.temporaryDirectory
    private var fileStart = Date()
    /// A transfer the host has abandoned. The guest drains to its frame
    /// boundary before stopping, so bytes keep arriving for a transfer
    /// nothing is waiting on; swallow them rather than calling it a
    /// protocol error and closing a healthy session.
    private var discardingTransfers: Set<Int> = []
    private var health: GuestListener.SessionHealth?

    private let decoder = FrameDecoder()
    private var helloed = false
    /// What this connection is for, settled at the gate. `.session` until
    /// a hello says otherwise, so nothing can acquire the resident
    /// exemptions by arriving before its own handshake.
    private(set) var role: ConnectionRole = .session
    /// What this machine calls itself and where it dialled from, joined.
    /// The only thing a guest session and its machine's resident channel
    /// can both be recognised by — see `gate`.
    private(set) var machineFingerprint: String?
    private var closed = false
    private(set) var guestName = "guest"
    /// Set from the peer's hello. Nil is deliberately distinct from true:
    /// older guests ignore Mirror descriptors and must not receive them.
    private(set) var mirrorTransfer: Bool?
    /// What a guest that sent no name is called. One constant, because
    /// GuestKey folds by it too and a second spelling would let an
    /// unnamed guest be admitted twice under two different keys.
    nonisolated static let unnamedGuest = "Guest"
    /// Set at the gate. Nil until then.
    private(set) var guestKey: GuestKey?
    /// Where this connection came from, known from accept.
    var guestAddress: GuestAddress { address }
    private var idleTask: Task<Void, Never>?

    init(connection: NWConnection,
         identity: GuestListener.HostIdentity,
         timing: GuestListener.Timing,
         pacing: GuestListener.Pacing,
         address: GuestAddress,
         admit: @escaping (Hello) -> String?,
         identify: @escaping (Hello, GuestAddress) -> GuestKey,
         onActive: @escaping (Session) -> Void,
         shouldCloseOnSilence: @escaping () -> Bool = { true },
         onAnswering: @escaping (Session, Bool) -> Void = { _, _ in },
         onLog: @escaping (String, String, HostLog.LogLevel) -> Void,
         onHealth: @escaping (GuestListener.SessionHealth?) -> Void,
         onCommandResult: @escaping (CommandResult) -> Void,
         onExecOutput: @escaping (ExecOutput) -> Void,
         onExecResult: @escaping (ExecResult) -> Void,
         onGuestError: @escaping (ErrorMessage) -> Void,
         onCensusReport: @escaping (CensusReport) -> Void,
         onContinuityReport: @escaping (ContinuityReport) -> Void,
         onContinuityKeyReport: @escaping (ContinuityKeyReport) -> Void,
         onCapture: @escaping (Result<GuestListener.CaptureDelivery,
                                      GuestListener.CaptureFailure>) -> Void,
         onCaptureProgress: @escaping (GuestListener.CaptureProgress?) -> Void,
         onScene: @escaping (Result<GuestListener.SceneDelivery,
                                    GuestListener.SceneFailure>) -> Void,
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
         onServeContinuityGrab: @escaping (ContinuityGrab) -> Void
             = { _ in },
         onAcceptOffer: @escaping (FileOffer) -> Void,
         onServeChange: @escaping (GuestListener.ChangeRequest) -> Void,
         onServeCloud: @escaping (GuestListener.CloudAsk) -> Void
             = { _ in },
         onServeChat: @escaping (GuestListener.ChatAsk) -> Void
             = { _ in },
         onServeWeb: @escaping (GuestListener.WebAsk) -> Void
             = { _ in },
         onServeHostShow: @escaping (HostShow) -> Void
             = { _ in },
         onServeUpdate: @escaping (UpdateRequest) -> Void = { _ in },
         onUpdateResult: @escaping (UpdateResult) -> Void = { _ in },
         onProcessListing: @escaping (ProcessListing) -> Void,
         onSoftwareListing: @escaping (SoftwareListing) -> Void,
         onProcessResult: @escaping (ProcessResult) -> Void,
         onMirrorInvalidation: @escaping (MirrorInvalidate) -> Void = { _ in },
         onReceived: @escaping (URL) -> Void,
         onOutboundProgress: @escaping (Int, Int) -> Void,
         onOutboundFailed: @escaping (String) -> Void,
         onClosed: @escaping (Session, String) -> Void) {
        self.connection = connection
        self.identity = identity
        self.timing = timing
        self.pacing = pacing
        self.address = address
        self.admit = admit
        self.identify = identify
        self.onActive = onActive
        self.shouldCloseOnSilence = shouldCloseOnSilence
        self.onAnswering = onAnswering
        self.onLog = onLog
        self.onHealth = onHealth
        self.onCommandResult = onCommandResult
        self.onExecOutput = onExecOutput
        self.onExecResult = onExecResult
        self.onGuestError = onGuestError
        self.onCensusReport = onCensusReport
        self.onContinuityReport = onContinuityReport
        self.onContinuityKeyReport = onContinuityKeyReport
        self.onCapture = onCapture
        self.onCaptureProgress = onCaptureProgress
        self.onScene = onScene
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
        self.onServeContinuityGrab = onServeContinuityGrab
        self.onAcceptOffer = onAcceptOffer
        self.onServeChange = onServeChange
        self.onServeCloud = onServeCloud
        self.onServeChat = onServeChat
        self.onServeWeb = onServeWeb
        self.onServeHostShow = onServeHostShow
        self.onServeUpdate = onServeUpdate
        self.onUpdateResult = onUpdateResult
        self.onProcessListing = onProcessListing
        self.onSoftwareListing = onSoftwareListing
        self.onProcessResult = onProcessResult
        self.onMirrorInvalidation = onMirrorInvalidation
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
    func close(sending bye: Bye,
               flushed: @escaping @MainActor @Sendable () -> Void) {
        finish(reason: "Closed", sending: .bye(bye), flushed: flushed)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.resetIdleClock()
                    self.noteAnswering()
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

    /// The machine changed its mind about agent control; the host's copy
    /// changes with it.
    ///
    /// This writes the SAME field `hello.agent` wrote, deliberately. It is
    /// what the projection layer's consent check reads before every call
    /// (`HostProjectionDispatch.consentDenial`, through session health), so
    /// storing it here is the enforcement — a revision kept anywhere else
    /// would update a label while the old tier went on being permitted,
    /// which is the defect this message exists to close.
    ///
    /// Not acknowledged: the contract gives the guest no answer to wait
    /// for. It IS logged, because a permission changing under a person who
    /// is driving this machine should be findable afterwards, and the log
    /// is where the connect-time answer was already written.
    private func applyAgentAccess(_ answer: AgentIntegrationGuestAccess) {
        guard var h = health else { return }
        let previous = h.guestAgentAccess
        guard previous != answer else { return }
        h.guestAgentAccess = answer
        health = h
        onHealth(h)
        /* Named "now" rather than "changed to": the sentence a person reads
           while wondering why an agent stopped being able to act should say
           what is true, not require diffing it against an earlier line. */
        let was = previous.map { $0.displayName } ?? "not stated"
        onLog("\(guestName) now says agent \(answer.displayName)"
              + " (was \(was))", "wire", .info)
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
                if discardingTransfers.contains(Int(frame.header.transfer)) {
                    break
                }
                /* A scene rides the same one-wide lane as a capture and a
                   file, and is routed FIRST because it is the only user of
                   that lane that can say which transfer it is: it matches on
                   the transfer id `scene.begin` announced. The other two
                   branches below claim bulk by "am I open", which is exactly
                   right while one transfer is open at a time and is why an
                   exact match has to be tried before them rather than after,
                   where a still-open capture would swallow a scene's bytes. */
                if let begin = sceneBegin,
                   Int(frame.header.transfer) == begin.transfer {
                    sceneBuffer.append(contentsOf: frame.payload)
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
        /* **A liveness channel carries liveness and nothing else.** The
           contract allows it hello, ping and bye; anything more would be a
           resident component claiming a lane it has no business in, and a
           receiver that quietly served it would let a bug on the guest
           turn the machine's heartbeat into a second, unaccountable
           command path. Refused by name so the guest's own log says which
           rule it broke. */
        if role == .resident {
            switch message {
            case .ping(let id):
                send(.pong(id: id))
                touchHealth(pingsDelta: 1)
            case .bye(let bye):
                onLog(byeDescription(bye, guest: guestName), "wire", .info)
                finish(reason: "Closed by guest")
            case .continuityDragBegin(let begin):
                /* THE ONE EXCEPTION, and the contract argues it where
                   both sides read it: this fact is known inside the
                   Finder's drag loop and the application gets no task
                   time until that loop ends, so no scheduled sender can
                   state it in time. It is still not a command — nothing
                   is answered, and an unbound handler drops it. */
                onContinuityDragBegin?(begin)
            default:
                protocolError("a resident liveness channel may send only "
                              + "hello, ping, bye and continuity.dragBegin")
            }
            return
        }
        switch message {
        case .ping(let id):
            send(.pong(id: id))
            touchHealth(pingsDelta: 1)
        case .agentAccess(let revision):
            applyAgentAccess(revision.agent)
        case .commandResult(let result):
            onCommandResult(result)
        case .execOutput(let output):
            onExecOutput(output)
        case .execResult(let result):
            onExecResult(result)
        case .execRequest, .execCancel, .execInput:
            /* Declared asymmetry, the same shape as softwareList above: the
               exec plane has only ever run host-to-guest. This host serves
               no commands, so there is nothing for it to interpret a line
               with, and inventing an answer would make it a third face. */
            break
        case .censusReport(let report):
            onCensusReport(report)
        case .censusRequest(let request):
            serveCensusRefusal(request)
        case .continuityReport(let report):
            onContinuityReport(report)
        case .continuityKeyReport(let report):
            onContinuityKeyReport(report)
        case .continuitySelection(let selection):
            onContinuitySelection?(selection)
        case .continuityArm, .continuityDisarm, .continuityKey:
            /* Declared asymmetry: authority is host-to-guest. A guest may
               report that its resident relinquished ownership, but it may
               never arm the host's input lane or disarm another session. */
            break
        case .continuityGrab(let grab):
            /* THE INVERTED USE: the guest sends this too, to redeem an
               offer THIS host published — `operations.guestReportsContinuity`
               in the contract. It used to be lumped with the arm/disarm/key
               family above under "a grant is something the guest gives,
               never something it collects"; that rule stood only until the
               offer direction existed to need the opposite of it. */
            onServeContinuityGrab(grab)
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
        case .mirrorInvalidate(let hint):
            onMirrorInvalidation(hint)
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
        /* The cloud family: the guest asking about THIS Mac's iCloud.
           One direction by definition — the host never sends these, so
           their answers (.cloudReport and friends) stay in the default
           arm the way every unserved inbound does. */
        case .cloudServices(let request):
            onServeCloud(.services(request))
        case .cloudList(let request):
            onServeCloud(.list(request))
        case .cloudDetail(let request):
            onServeCloud(.detail(request))
        case .cloudGet(let request):
            onServeCloud(.get(request))
        /* The chat family: the guest asking to talk to THIS Mac's
           model harness. One direction by definition like cloud — the
           host never sends the requests, so the answers (.chatCatalog,
           .chatDelta, .chatStatus, .chatResult) stay in the default
           arm with every other unserved inbound. */
        case .chatModels(let request):
            onServeChat(.models(request))
        case .chatSend(let request):
            onServeChat(.send(request))
        case .chatCancel(let request):
            onServeChat(.cancel(request))
        case .chatReset(let request):
            onServeChat(.reset(request))
        case .webRequest(let request):
            onServeWeb(.request(request))
        case .webCancel(let request):
            onServeWeb(.cancel(request))
        case .webResponseBegin, .webResponseChunk, .webResponseEnd:
            // Host-owned answers; a guest never serves this Mac's renderer.
            break
        case .cloudPreview(let request):
            onServeCloud(.preview(request))
        /* The host-surface family: the guest asking THIS Mac to bring
           one of its own windows forward. One direction by definition
           like cloud and chat — the host never sends host.show, and its
           answer (.hostShown) stays in the default arm with every other
           inbound this side does not serve. */
        case .hostShow(let request):
            onServeHostShow(request)
        case .updateRequest(let request):
            onServeUpdate(request)
        case .updateResult(let result):
            onUpdateResult(result)
        case .updateOffer:
            /* Host-owned family: a guest never publishes artifacts. */
            break
        case .previewBegin, .previewEnd:
            /* Declared asymmetry: previews answer cloud.preview, and
               this host never asks one — its screen can decode the
               photo itself. Ignoring is the contract's word. */
            break
        case .fileAccept(let accept):
            onFileAccept(accept)
            sendAcceptedFile(accept)
        case .fileDone(let done):
            onFileDone(done)
        case .fileProgress(let progress):
            noteOutboundAck(progress)
            onFileProgress(progress)
        case .fileRefuse(let refuse):
            if removeAbandonedFileGet(refuse.id) {
                break
            }
            if activeFileGetID == refuse.id {
                activeFileGetID = nil
                fileBegin = nil
                fileSink?.abort()
                fileSink = nil
            }
            onFileRefuse(refuse)
        case .fileBegin(let begin):
            if inbound?.id == begin.id {
                break                 // a push we already accepted
            }
            if removeAbandonedFileGet(begin.id) {
                discardingTransfers.insert(begin.transfer)
                send(.fileCancel(FileCancel(transfer: begin.transfer)))
                break
            }
            guard activeFileGetID == begin.id else {
                /* SAID OUT LOUD, because this is the shape of failure that
                   reached metal once already: the guest serves the file,
                   this side cancels it for naming a pull we are not
                   awaiting, and the caller learns nothing until its
                   watchdog fires twenty seconds later with `timeout` — a
                   word that points at the wire rather than at us. */
                onLog("\(guestName) began sending \(begin.name) for request "
                      + "\(begin.id), which this Mac is not awaiting"
                      + (activeFileGetID.map { " (awaiting \($0))" }
                         ?? " (awaiting nothing)")
                      + "; cancelling transfer \(begin.transfer)",
                      "files", .error)
                discardingTransfers.insert(begin.transfer)
                send(.fileCancel(FileCancel(transfer: begin.transfer)))
                break
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
        case .sceneBegin(let begin):
            /* No progress is reported. A scene is tens of kilobytes and
               tens of milliseconds; a progress bar for it would flash
               once, and publishing into `captureProgress` would put a
               scene's bytes on the Screenshots panel's bar. */
            sceneBegin = begin
            sceneBuffer = []
            sceneBuffer.reserveCapacity(begin.bytes)
        case .sceneEnd(let end):
            finishScene(end)
        case .sceneSame(let same):
            finishSceneSame(same)
        case .bye(let bye):
            let name = guestName
            finish(reason: byeDescription(bye, guest: name))
        case .hello:
            protocolError("duplicate hello")
        case .refuse(let refusal):
            /* The other half of the revision gate. A guest refuses the
               hello it was just answered when it cannot speak this
               revision — the contract binds the rule to whoever RECEIVES
               a hello, not to the host alone — and `refuse` is worded
               "never swallowed" for a reason: this used to land in the
               default arm below, so a peer that had said exactly why it
               was leaving reached a person as a link that simply went
               away. The refusal carries the GUEST's revision, which is
               the number a stale side needs to be told. */
            onLog("Refused by the guest: \(refusal.reason) "
                  + "(it speaks contract \(refusal.contract), "
                  + "this host \(Contract.revision))", "wire", .warn)
            finish(reason: "Refused by the guest: \(refusal.reason)")
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

    /// Arms this side to RECEIVE the answer to one pull, whatever asked for
    /// it. Every ask that expects bytes back goes through here, because the
    /// arming is four facts that must move together and forgetting one of
    /// them is silent: `file.begin` is matched against `activeFileGetID`,
    /// and a begin that matches nothing is cancelled and discarded without
    /// a word. Two of the four asks used to inline this and both dropped
    /// the id, so `continuity.grab` and every Mirror pull answered into a
    /// closed door — the guest served the file, this side cancelled it, and
    /// the only symptom was the caller's 20-second watchdog.
    private func beginFileGet(id: Int, stagingDirectory: URL) {
        activeFileGetID = id
        fileBegin = nil
        fileSink?.abort()
        fileSink = nil
        fileStagingDirectory = stagingDirectory
        fileStart = Date()
    }

    func sendFileGet(id: Int, path: String, container: String?,
                     stagingDirectory: URL) {
        beginFileGet(id: id, stagingDirectory: stagingDirectory)
        send(.fileGet(FileGet(id: id, path: path, container: container)))
    }

    func sendMirrorFileGet(id: Int, source: MirrorFileSource,
                           container: String?, stagingDirectory: URL) {
        beginFileGet(id: id, stagingDirectory: stagingDirectory)
        send(.fileGet(FileGet(id: id, path: "", container: container,
                              mirrorSource: source)))
    }

    /// Redeems one drag gesture's consent for the item a selection
    /// generation named. The answer is the ordinary file lane, so the staging
    /// and sink reset here are identical to `sendMirrorFileGet` on purpose:
    /// there is one bulk receiver on this side and a grab uses it.
    func sendContinuityGrab(id: Int, epoch: UInt32, generation: UInt32,
                            container: String?, stagingDirectory: URL) {
        beginFileGet(id: id, stagingDirectory: stagingDirectory)
        send(.continuityGrab(.init(version: ContinuityContract.version,
                                   id: id, epoch: epoch,
                                   generation: generation,
                                   container: container)))
    }

    /// Publishes what this Mac is carrying toward the guest — or, with
    /// `item` nil, tears down whatever drag the guest was drawing under
    /// the prior generation. Unlike every `sendFileGet`/`sendContinuityGrab`
    /// sibling above, this arms nothing: it is a push, not a pull, so there
    /// is no reply to await and no `activeFileGetID` to set.
    func sendContinuityOffer(epoch: UInt32, generation: UInt32,
                             item: ContinuityOffer.Item?) {
        send(.continuityOffer(.init(version: ContinuityContract.version,
                                    epoch: epoch, generation: generation,
                                    item: item)))
    }

    /// Hands the gesture over: the guest starts a real Drag Manager drag
    /// with a promise at `pos`. Arms nothing here for the same reason
    /// `sendContinuityOffer` does not — it is a push, and the pull that
    /// follows is the guest's own `continuity.grab` against the offer this
    /// message's skeleton describes.
    func sendContinuityHostDragBegin(
        epoch: UInt32, dragSeq: UInt32,
        pos: ContinuityHostDragBegin.Position,
        item: ContinuityHostDragBegin.Item
    ) {
        send(.continuityHostDragBegin(
            .init(version: ContinuityContract.version, epoch: epoch,
                  dragSeq: dragSeq, pos: pos, item: item)))
    }

    func sendDevelopmentProjectFileGet(id: Int, projectID: String,
                                       path: String,
                                       stagingDirectory: URL) {
        beginFileGet(id: id, stagingDirectory: stagingDirectory)
        send(.fileGet(FileGet(id: id, path: path, container: "macbinary",
                              developmentProject: projectID)))
    }

    func cancelFile() {
        guard let begin = fileBegin else {
            if let id = activeFileGetID {
                abandonedFileGetIDs.append(id)
                if abandonedFileGetIDs.count > Self.abandonedFileGetLimit {
                    abandonedFileGetIDs.removeFirst(
                        abandonedFileGetIDs.count
                            - Self.abandonedFileGetLimit)
                }
                activeFileGetID = nil
            }
            fileSink?.abort()
            fileSink = nil
            return
        }
        discardingTransfers.insert(begin.transfer)
        activeFileGetID = nil
        fileBegin = nil
        fileSink?.abort()
        fileSink = nil
        send(.fileCancel(FileCancel(transfer: begin.transfer)))
    }

    private func removeAbandonedFileGet(_ id: Int) -> Bool {
        guard let index = abandonedFileGetIDs.firstIndex(of: id) else {
            return false
        }
        abandonedFileGetIDs.remove(at: index)
        return true
    }

    /// Holds an offered file until the guest accepts it. The bytes wait
    /// here rather than riding with the offer: a refusal (busy, a name
    /// collision) must cost nothing but the message.
    private enum OfferedSource {
        case memory(Data, crc32: UInt32?)
        case staged(OutboundFileSource)
    }

    private var pendingOffer: (offer: FileOffer, source: OfferedSource)?
    /// An accept can arrive while a cancelled staged read is still returning.
    /// Keep the replacement behind the old transfer's terminal frame instead
    /// of overwriting the one outbound slot and orphaning that old transfer.
    private var deferredAccept: FileAccept?
    private var transferSeq: UInt16 = 0

    func sendFileOffer(_ offer: FileOffer, bytes: Data, crc32: UInt32?) {
        pendingOffer = (offer, .memory(bytes, crc32: crc32))
        send(.fileOffer(offer))
    }

    func sendFileOffer(_ offer: FileOffer, source: OutboundFileSource) {
        pendingOffer = (offer, .staged(source))
        send(.fileOffer(offer))
    }

    func sendUpdateOffer(_ offer: UpdateOffer) {
        send(.updateOffer(offer))
    }

    func refuseUpdate(id: Int, reason: String) {
        send(.fileRefuse(FileRefuse(id: id, code: "not-available",
                                    reason: reason)))
    }

    func sendUpdateArtifact(_ artifact: UpdateProvider.Artifact,
                            request: UpdateRequest) {
        let name = artifact.manifest.component == .application
            ? "New Old World Update" : "NOW Extension Update"
        let fileType = artifact.manifest.component == .application
            ? "APPL" : "INIT"
        let creator = artifact.manifest.component == .application
            ? "NOWo" : "NOWx"
        let offer = FileOffer(
            id: request.id, name: name, path: "", container: "macbinary",
            bytes: artifact.manifest.bytes, fileType: fileType,
            creator: creator, modified: nil, createParents: false,
            overwrite: true,
            resumeToken: TransferIdentity.token(
                bytes: artifact.manifest.bytes, crc32: artifact.crc32),
            purpose: "update.\(artifact.manifest.component.rawValue)",
            sha256: artifact.manifest.sha256)
        sendFileOffer(offer, bytes: artifact.bytes, crc32: artifact.crc32)
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

    /* --- serving a preview -----------------------------------------
       The begin / bulk / end shape serveFile takes, without the file
       family's resume, window or receipt machinery: a preview is
       bounded small (the serve clamps its box), evicted by the guest on
       the next selection, and worthless the moment a newer one is
       asked — so the simplest honest sender is chunks driven off the
       socket's own completion, which is real backpressure at this
       size. While one is in flight the transfer lane reads held
       (GuestListener.transferLaneHolder asks previewInFlight). */

    private struct PreviewOutbound {
        var id: Int
        var transfer: UInt16
        var data: Data
        var sent: Int
    }

    private var previewOutbound: PreviewOutbound?

    var previewInFlight: Bool { previewOutbound != nil }

    func servePreview(id: Int, pixels: ClassicDither.Indexed) {
        let transfer = nextTransfer()
        send(.previewBegin(PreviewBegin(
            id: id, transfer: Int(transfer), width: pixels.width,
            height: pixels.height, depth: pixels.depth,
            rowBytes: pixels.rowBytes, bytes: pixels.pixels.count)))
        previewOutbound = PreviewOutbound(id: id, transfer: transfer,
                                          data: pixels.pixels, sent: 0)
        sendNextPreviewChunk()
    }

    private func sendNextPreviewChunk() {
        guard let out = previewOutbound else { return }
        guard out.sent < out.data.count else {
            previewOutbound = nil
            send(.previewEnd(PreviewEnd(id: out.id,
                                        transfer: Int(out.transfer),
                                        ok: true)))
            return
        }
        let end = min(out.sent + Self.outboundFrameBytes, out.data.count)
        let last = end == out.data.count
        let payload = out.data.subdata(in: out.sent..<end)
        guard let frame = try? FrameCodec.encode(
            channel: .bulk, flags: last ? [.end] : [],
            transfer: out.transfer, payload: payload) else {
            previewOutbound = nil
            send(.previewEnd(PreviewEnd(id: out.id,
                                        transfer: Int(out.transfer),
                                        ok: false)))
            return
        }
        previewOutbound?.sent = end
        sendMetered(frame) { [weak self] error in
            guard let self else { return }
            if error != nil {
                /* The connection is what failed; there is nobody left
                   to tell, so the state just clears. */
                self.previewOutbound = nil
                return
            }
            self.sendNextPreviewChunk()
        }
    }

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

    /// The same refusal, for a caller that already has its own vocabulary
    /// rather than a thrown `Error` — the offer family's `bad-epoch`,
    /// `stale-selection`, `no-selection` and `offer-expired`, none of
    /// which `HostShare.WireFault` (a filesystem's own words) can name.
    func refuseFile(id: Int, code: String, reason: String) {
        onLog("#\(id) refused: \(code) (\(reason))", "files", .warn)
        send(.fileRefuse(FileRefuse(id: id, code: code, reason: reason)))
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
        outboundProgressAt = Date()
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
        guard outbound == nil else {
            deferredAccept = accept
            return
        }
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
            startDeferredOutboundIfNeeded()
            return
        }
        guard out.sent < out.source.byteCount else {
            outbound = nil
            // Over the WHOLE file, not the bytes this session sent: a
            // resumed file is stitched from two attempts and the seam is
            // exactly what nothing else checks.
            send(.fileEnd(FileEnd(id: out.id, transfer: Int(out.transfer),
                                  ok: true, sendMs: nil, crc32: out.crc32)))
            startDeferredOutboundIfNeeded()
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
                self.outboundProgressAt = Date()
                self.onOutboundProgress(progress, total)
                self.sendNextOutboundChunk()
            }
        }
    }

    private func startDeferredOutboundIfNeeded() {
        guard outbound == nil, let accept = deferredAccept else { return }
        deferredAccept = nil
        sendAcceptedFile(accept)
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
                             completion: @escaping @MainActor @Sendable
                                (NWError?) -> Void) {
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
                           completion: @escaping @MainActor @Sendable
                              (NWError?) -> Void) {
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
                // Once the first byte of a protocol frame is on the wire,
                // finish that frame. A control message inserted here would
                // be consumed as bulk bytes and desynchronise the peer.
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
            deferredAccept = nil
        }
        outbound?.cancelled = true
        sendNextOutboundChunk()
    }

    func clearOutboundRequest(id: Int) {
        if pendingOffer?.offer.id == id {
            pendingOffer = nil
            if deferredAccept?.id == id { deferredAccept = nil }
        }
        if outbound?.id == id {
            outbound?.cancelled = true
            sendNextOutboundChunk()
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
        discardingTransfers.insert(transfer)
        activeFileGetID = nil
        fileBegin = nil
        fileSink?.abort()
        fileSink = nil
        send(.fileCancel(FileCancel(transfer: transfer)))
        onFileDelivery(.failure(.init(
            code: "io-error", message: error.localizedDescription)))
    }

    private func failInboundStream(transfer: Int, error: Error) {
        guard let inbound else { return }
        discardingTransfers.insert(transfer)
        self.inbound = nil
        inbound.sink.abort()
        send(.fileCancel(FileCancel(transfer: transfer)))
        send(.fileDone(FileDone(
            id: inbound.id, ok: false, code: "io-error",
            reason: error.localizedDescription)))
    }

    private func finishFile(_ end: FileEnd) {
        if discardingTransfers.remove(end.transfer) != nil {
            return                    /* the host already gave up on it */
        }
        guard let begin = fileBegin, let sink = fileSink else { return }
        guard begin.id == end.id else { return }
        activeFileGetID = nil
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
            transferMs: Int(Date().timeIntervalSince(fileStart) * 1000),
            crc32: end.crc32, resumeToken: begin.resumeToken)))
    }

    private func finishCapture(_ end: CaptureEnd) {
        if discardingTransfers.remove(end.transfer) != nil {
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
            var image: CGImage
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
                transferMs: ms, wireBytes: blob.count,
                // Stamped here because here is where the socket is known.
                guestName: guestName, guestKey: guestKey)
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

    /// Settles a scene transfer.
    ///
    /// **The failure is whole**, on both halves. The guest sends no bulk at
    /// all behind an `ok:false` — a partial walk is never delivered as a
    /// complete scene — and this refuses a body that is not the length its
    /// begin announced for the same reason: half a JSON document does not
    /// parse, and calling it a scene would hand the decoder a fault to
    /// report where the truth is a truncated transfer.
    private func finishScene(_ end: SceneEnd) {
        guard sceneSolicitedId == end.id else {
            /* Nothing here asked for this. Dropping it is deliberate: a
               scene nobody requested has no completion to settle, and
               inventing a push path for it would mean a page could change
               under a person who did not ask. */
            sceneBegin = nil
            sceneBuffer = []
            onLog("ignored a scene nobody asked for", "wire", .info)
            return
        }
        let begin = sceneBegin
        sceneBegin = nil
        sceneSolicitedId = nil
        let blob = sceneBuffer
        sceneBuffer = []
        guard end.ok else {
            onScene(.failure(.init(
                message: end.reason ?? "the Mac would not walk its screen",
                refusedByGuest: true)))
            return
        }
        guard let begin else {
            onScene(.failure(.init(message: "the scene ended without a begin",
                                   refusedByGuest: false)))
            return
        }
        guard blob.count == begin.bytes else {
            onScene(.failure(.init(
                message: "the scene arrived short: \(blob.count) of "
                    + "\(begin.bytes) bytes",
                refusedByGuest: false)))
            return
        }
        let asked = sceneAskedBaseline
        sceneAskedBaseline = nil
        var document = Data(blob)
        var form = GuestListener.SceneForm.whole
        if begin.delta == true {
            /* THE ONE PLACE A DELTA IS APPLIED, and it produces a whole
               document. Everything below this line - the decoder, the
               reducer, the engine's retention and removal rules - is the
               path a whole scene has always taken, unchanged. */
            do {
                let applied = try MirrorSceneDelta.apply(
                    delta: document, to: sceneBaseline,
                    askedBaseline: asked ?? "",
                    expected: begin.digest)
                document = applied.document
                sceneBaseline = applied.baseline
                sceneBaseline?.irVersion = begin.irVersion
                sceneDeltaRun += 1
                form = .delta
            } catch {
                /* Discard the rebuild and publish NOTHING from it. The
                   state already on screen stands, because it is the last
                   one that was proven; dropping the baseline makes the
                   next request ask for the truth. This is the whole of
                   the recovery story and it needs no negotiation. */
                sceneBaseline = nil
                sceneDeltaRun = 0
                onScene(.failure(.init(
                    message: "could not apply the scene delta: \(error) — "
                        + "asking for a whole scene next",
                    refusedByGuest: false)))
                return
            }
        } else {
            /* A whole document becomes the next baseline, when it can. A
               scene we cannot slice - a row with no incarnation, say - is
               simply not one we can be a delta consumer for, and the
               honest consequence is that the next request omits `since`
               rather than that anything fails. */
            sceneBaseline = try? MirrorSceneDelta.slice(whole: document)
            sceneBaseline?.irVersion = begin.irVersion
            sceneDeltaRun = 0
        }
        onScene(.success(.init(
            document: document,
            /* The ENVELOPE's major, carried through untouched. The gate
               that reads it runs at the decoder, on this number, before
               the document below is parsed — so nothing on the way here
               may substitute the body's own stamp for it. */
            irVersion: begin.irVersion,
            seq: begin.seq,
            capturedAt: begin.capturedAt,
            source: begin.source,
            walkMs: begin.walkMs,
            settlements: begin.settlements,
            transferMs: Int(Date().timeIntervalSince(sceneStart) * 1000),
            wireBytes: blob.count, wholeBytes: begin.wholeBytes, form: form,
            guestName: guestName, guestKey: guestKey)))
    }

    /// Asks for one scene. Primes the receive state the same way
    /// `sendCaptureRequest` does, because the answer arrives the same way.
    func sendSceneRequest(id: Int, staleAfterMs: Int?, semantics: Bool,
                          interaction: Bool,
                          tuning: GuestListener.CaptureTuning,
                          full: Bool = false) {
        sceneBegin = nil
        sceneBuffer = []
        sceneSolicitedId = id
        sceneStart = Date()
        /* We quote the digest of the last scene we FULLY APPLIED, never a
           sequence number. A sequence says which document the guest thinks
           we have; a digest says which one we actually hold, and those
           differ exactly when this side mis-applied a delta - the failure
           the whole scheme has to survive. A guest that does not recognise
           it answers whole, so the recovery path is the ordinary path. */
        var full = full
        if sceneDeltaRun >= Session.sceneResyncEvery {
            full = true
            sceneDeltaRun = 0
        }
        let since = full ? nil : sceneBaseline?.digest
        sceneAskedBaseline = since
        send(.sceneRequest(SceneRequest(
            id: id, chunkKb: tuning.chunkKb, paceMs: tuning.paceMs,
            staleAfterMs: staleAfterMs, semantics: semantics,
            interaction: interaction, since: since,
            full: full ? true : nil)))
    }

    /// A gap invalidation cannot safely build on the last digest. Removing
    /// the baseline makes the next ordinary request a whole-scene repair.
    func invalidateSceneBaseline() {
        sceneBaseline = nil
        sceneAskedBaseline = nil
        sceneDeltaRun = 0
    }

    /// The no-change answer. Nothing arrived on the bulk lane and nothing
    /// needed to: we republish the baseline at the new moment, which is
    /// what `capturedAt` has meant since it was added — same scene, newer
    /// moment.
    private func finishSceneSame(_ same: SceneSame) {
        guard sceneSolicitedId == same.id else {
            onLog("ignored a scene.same nobody asked for", "wire", .info)
            return
        }
        sceneSolicitedId = nil
        sceneBegin = nil
        sceneBuffer = []
        let asked = sceneAskedBaseline
        sceneAskedBaseline = nil
        guard let baseline = sceneBaseline, let asked, same.digest == asked else {
            /* A guest that answers "the same" about a baseline we did not
               name is confused about what it just compared. We drop our
               baseline so the next request asks for the truth, rather than
               publishing a scene on the strength of an agreement neither
               side can point at. */
            sceneBaseline = nil
            onScene(.failure(.init(
                message: "the guest said nothing changed since "
                    + "\(same.digest), which is not the \(asked ?? "nothing") "
                    + "we asked about",
                refusedByGuest: false)))
            return
        }
        onScene(.success(.init(
            document: MirrorSceneDelta.republish(baseline, seq: same.seq,
                                                 capturedAt: same.capturedAt),
            irVersion: baseline.irVersion,
            seq: same.seq, capturedAt: same.capturedAt,
            source: baseline.sourceText,
            walkMs: same.walkMs, settlements: same.settlements,
            transferMs: Int(Date().timeIntervalSince(sceneStart) * 1000),
            wireBytes: 0, wholeBytes: nil, form: .unchanged,
            guestName: guestName, guestKey: guestKey)))
    }

    private func gate(_ hello: Hello) {
        if hello.contract != Contract.revision {
            refuse("contract revision \(hello.contract) != \(Contract.revision)")
            return
        }
        /* **An unknown role is a NEWER sender, and is refused rather than
           served as a session.** Serving it would hand a liveness-only
           channel a command lane it cannot answer — and the host would
           then read its silence as a wedged Macintosh, which is the exact
           confusion this whole slice exists to remove. */
        guard let role = hello.role.map({ ConnectionRole(rawValue: $0) })
            ?? .session else {
            refuse("unknown connection role \"\(hello.role ?? "")\"")
            return
        }
        self.role = role
        if let reason = admit(hello) {
            refuse(reason)
            return
        }
        helloed = true
        mirrorTransfer = hello.mirrorTransfer
        /* **What a resident channel is associated BY.** Not the minted
           GuestID: `mintSessionKey` deliberately hands a second dial from
           a live name+address a DIFFERENT machine id (the emulator
           loopback guard), so a resident could never share its own
           application's id. The stable thing both dials agree on is what
           the machine calls itself and where it dialled from. */
        machineFingerprint = GuestRegistry.fingerprint(
            name: hello.name, operatingSystem: hello.os)
            + "|" + address.text
        guestName = hello.name ?? Self.unnamedGuest
        /* Settled before onActive, so the listener files this session
           under the same key the gate just minted. Per connection, so
           two Macs calling themselves the same thing are two guests.
           **A resident channel is deliberately given none of this**: it is
           not a machine, and minting it an identity would put a second,
           phantom Macintosh in the registry and the guest list for every
           real one running the extension. */
        let key = role == .resident ? nil : identify(hello, address)
        guestKey = key
        let chunk = min(hello.chunk ?? Contract.defaultChunk,
                        Contract.defaultChunk)
        send(.hello(Hello(contract: Contract.revision, side: "host",
                          version: identity.version, name: identity.name,
                          os: nil, chunk: chunk)))
        let now = Date()
        health = GuestListener.SessionHealth(
            guestName: guestName, guestVersion: hello.version,
            guestBuild: hello.build,
            extensionVersion: hello.extensionVersion,
            extensionBuild: hello.extensionBuild,
            guestAgentAccess: hello.agent,
            guestOS: hello.os,
            connectedAt: now, lastTraffic: now,
            pingsAnswered: 0, framesReceived: 1)
        onHealth(health)
        /* The handle, what the machine calls itself, and where it dialled
           from — together, once, in the host's own log. A person reading
           it afterwards needs the pairing to know which Mac this was. */
        var line = "Connected: \(key?.machine.slug ?? "resident") — "
            + "\(guestName) at \(address.text)"
        if !hello.version.isEmpty {
            line += " (guest \(hello.version)"
            /* The build, not just the version: a version is hand-edited and
               a stale build reports the same one, which is how an hour went
               to the wrong half of the system on 2026-07-30. Omitted rather
               than filled in when the guest reports none — the 68K guest
               does not. */
            if let build = hello.build, !build.isEmpty {
                line += " build \(build)"
            }
            line += hello.os.map { ", OS \($0))" } ?? ")"
        }
        /* What the machine said about agents driving it, in the same line a
           person reads to find out what connected. Written only when it
           said something: a guest older than the field gets no clause,
           because "agent: —" would be this log inventing an answer nobody
           gave. Outside the version parenthesis on purpose — this is not a
           property of the build, it is the machine's position. */
        if let access = hello.agent {
            line += " — agent \(access.displayName)"
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
        discardingTransfers.insert(begin.transfer)
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
    /// Internal rather than fileprivate: this is the ONE thing the
    /// listener that owns a session reaches in to do — put a control
    /// message on the wire. It read as fileprivate only because the two
    /// types shared a file; every other direction of that conversation
    /// already runs through injected closures, and still does.
    func send(_ message: ControlMessage) {
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
    private func drainControlQueue(
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) {
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

    /// When an outbound transfer last had bytes taken by the socket. It is
    /// this session's own evidence of a live peer, and it is a DIFFERENT
    /// kind of evidence from an inbound frame: the guest said nothing, but
    /// its TCP window kept opening, which a dead machine's does not.
    ///
    /// It exists for the promise pull. On the native drag lane the pull
    /// happens INSIDE the guest's drop — a nested Toolbox loop, where the
    /// application answers nothing on the control channel — so a multi-MB
    /// file is minutes of one-way traffic with no frame coming back. The
    /// idle clock read that as a dead guest and closed the connection out
    /// from under the very transfer it was watching.
    private var outboundProgressAt: Date?

    private func resetIdleClock() {
        idleTask?.cancel()
        let timeout = timing.idleTimeout
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            guard !Task.isCancelled, let self else { return }
            /* **A TRANSFER IN FLIGHT IS NOT SILENCE.** Asked before the
               verdict below, because it is a stronger fact than any of the
               reasoning there: bytes of ours are still being taken by this
               connection, right now, for a file the guest asked for. */
            if self.outbound != nil, let progress = self.outboundProgressAt,
               Date().timeIntervalSince(progress) < timeout {
                self.resetIdleClock()
                return
            }
            /* **Silence is not death, and this is the one place that used
               to assume it was.** A cooperatively-scheduled Macintosh
               starves every application while one blocks — measured
               2026-08-05 at over 90 s, past this very timeout — so a
               guest that has stopped sending may be a perfectly healthy
               machine showing a dialog. The listener knows whether
               anything else on that machine is still answering; it owns
               the verdict, and this owns the clock. */
            guard self.shouldCloseOnSilence() else {
                if self.isAnswering {
                    self.isAnswering = false
                    self.onLog("no traffic for \(Int(timeout))s, but the "
                               + "machine is still answering — starved, "
                               + "not gone", "wire", .warn)
                    self.onAnswering(self, false)
                }
                /* Re-armed rather than abandoned: the verdict is asked
                   again every window, so a machine that later goes for
                   real is still noticed — one timeout later, not never. */
                self.resetIdleClock()
                return
            }
            self.finish(reason: "Connection lost (no traffic)")
        }
    }

    /// Whether this session's guest has answered anything within a silence
    /// window. False means STARVED — the machine is alive on some other
    /// channel and this application is not being scheduled — which is a
    /// different thing from disconnected and must not be shown as one.
    private(set) var isAnswering = true

    private func noteAnswering() {
        guard !isAnswering else { return }
        isAnswering = true
        onLog("the guest is answering again", "wire", .info)
        onAnswering(self, true)
    }

    /// Ends the session. When a farewell message is given it is flushed
    /// before the connection is cancelled — cancel() drops unsent data,
    /// which would eat the very refuse/bye the peer needs to see.
    private func finish(reason: String, sending farewell: ControlMessage? = nil,
                        flushed: (@MainActor @Sendable () -> Void)? = nil) {
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
