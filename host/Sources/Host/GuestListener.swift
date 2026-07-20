import Foundation
import Network
import CoreGraphics
import Combine

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

    @Published private(set) var state: State = .idle {
        didSet {
            if ProcessInfo.processInfo.environment["NOW_HOST_DEBUG"] != nil {
                FileHandle.standardError.write(
                    Data("[now-host] state -> \(state)\n".utf8))
            }
        }
    }
    @Published private(set) var lastDisconnect: String?
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var health: SessionHealth?

    private var nextCommandId = 1
    private var pendingCommands: [Int: (CommandResult) -> Void] = [:]

    private let identity: HostIdentity
    private let timing: Timing
    private var listener: NWListener?
    private var session: Session?

    init(identity: HostIdentity, timing: Timing = Timing()) {
        self.identity = identity
        self.timing = timing
    }

    private static let logLimit = 100

    func note(_ text: String) {
        if ProcessInfo.processInfo.environment["NOW_HOST_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[now-host] \(text)\n".utf8))
        }
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

    /// The port actually bound (differs from the requested one when 0 was
    /// passed for an ephemeral port — used by tests).
    var boundPort: UInt16? { listener?.port?.rawValue }

    /// Runs one declared command on the connected guest. Completion fires on
    /// the main actor with the guest's result, or a synthesized failure when
    /// no guest is connected / the session dies first.
    func runCommand(_ name: String, args: [String: String]? = nil,
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
        session.sendCommand(CommandRequest(id: id, name: name, args: args))
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

    // MARK: - Files

    struct FileFailure: Error {
        var code: String
        var message: String
    }

    /// One pulled file, still in guest form: `container` says whether the
    /// bytes are a plain data fork or MacBinary. Conversion is the
    /// caller's job (see FileConverter).
    struct FileDelivery {
        var name: String
        var container: String
        var fileType: String?
        var creator: String?
        var modified: Int?
        var bytes: Data
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
        pendingListings[id] = completion
        session.sendFileList(id: id, path: path, cursor: cursor)
        // A guest that answers neither listing nor refusal (a malformed
        // reply its decoder dropped, a wedge) must not leave the browser
        // spinning; fail the request visibly instead.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self,
                  let pending = self.pendingListings
                      .removeValue(forKey: id) else { return }
            pending(.failure(.init(
                code: "timeout",
                message: "The Mac did not answer the listing")))
        }
    }

    /// Pulls a file. `container` nil = the guest's fork rule decides.
    func getFile(path: String, container: String? = nil,
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
        session.sendFileGet(id: id, path: path, container: container)
    }

    /// Abandons the file transfer in flight; the guest drains to the
    /// frame boundary and ends it, same as a capture cancel.
    func cancelFile() {
        session?.cancelFile()
    }

    private var pendingListings:
        [Int: (Result<FileListing, FileFailure>) -> Void] = [:]
    private var pendingFile:
        ((Result<FileDelivery, FileFailure>) -> Void)?

    fileprivate func resolveListing(_ listing: FileListing) {
        pendingListings.removeValue(forKey: listing.id)?(.success(listing))
    }

    fileprivate func failFile(_ refuse: FileRefuse) {
        let failure = FileFailure(code: refuse.code,
                                  message: refuse.reason ?? refuse.code)
        if let completion = pendingListings.removeValue(forKey: refuse.id) {
            completion(.failure(failure))
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
        session.sendCaptureRequest(id: id, depth: depth, tuning: tuning)
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

    /// Abandons the transfer in flight. The guest answers with a failed
    /// capture.end, which is what actually settles the pending completion.
    func cancelCapture() {
        session?.cancelCapture()
    }

    struct CaptureDelivery {
        var image: CGImage
        var format: CaptureFormat
        var transferMs: Int
        var wireBytes: Int
    }

    private var pendingCapture:
        ((Result<CaptureDelivery, CaptureFailure>) -> Void)?

    fileprivate func deliverCapture(
        _ result: Result<CaptureDelivery, CaptureFailure>) {
        let completion = pendingCapture
        pendingCapture = nil
        captureProgress = nil
        completion?(result)
    }

    fileprivate func noteCaptureProgress(_ progress: CaptureProgress?) {
        captureProgress = progress
    }

    private func resolveCommand(_ result: CommandResult) {
        if let completion = pendingCommands.removeValue(forKey: result.id) {
            completion(result)
        }
    }

    private func failPendingCommands(_ reason: String) {
        let pending = pendingCommands
        pendingCommands = [:]
        for (id, completion) in pending {
            completion(CommandResult(
                id: id, ok: false, output: nil,
                error: .init(code: "disconnected", message: reason)))
        }
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
            onLog: { [weak self] text in self?.note(text) },
            onHealth: { [weak self] health in self?.health = health },
            onCommandResult: { [weak self] result in
                self?.resolveCommand(result)
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
            onFileRefuse: { [weak self] refuse in
                self?.failFile(refuse)
            },
            onFileDelivery: { [weak self] result in
                self?.deliverFile(result)
            },
            onClosed: { [weak self] closedSession, reason in
                guard let self else { return }
                self.pending.removeAll { $0 === closedSession }
                guard self.session === closedSession else { return }
                self.streamSessionClosed()
                self.session = nil
                self.health = nil
                self.failPendingCommands(reason)
                self.deliverCapture(.failure(.init(message: reason)))
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
    private let isBusy: () -> String?
    private let onActive: (Session) -> Void
    private let onLog: (String) -> Void
    private let onHealth: (GuestListener.SessionHealth?) -> Void
    private let onCommandResult: (CommandResult) -> Void
    private let onCapture:
        (Result<GuestListener.CaptureDelivery, GuestListener.CaptureFailure>)
        -> Void
    private let onCaptureProgress: (GuestListener.CaptureProgress?) -> Void
    private let onPushedCapture: (GuestListener.CaptureDelivery) -> Void
    private let onStreamFrame: (GuestListener.CaptureDelivery) -> Void
    private let onStreamStopped: (StreamStopped) -> Void
    private let onStreamRequest: (StreamRequest) -> Void
    private let onFileListing: (FileListing) -> Void
    private let onFileRefuse: (FileRefuse) -> Void
    private let onFileDelivery:
        (Result<GuestListener.FileDelivery, GuestListener.FileFailure>) -> Void
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
    /// In-flight file pull: the begin that announced it, and its bytes.
    private var fileBegin: FileBegin?
    private var fileBuffer: [UInt8] = []
    private var fileStart = Date()
    private var health: GuestListener.SessionHealth?

    private let decoder = FrameDecoder()
    private var helloed = false
    private var closed = false
    private(set) var guestName = "guest"
    private var idleTask: Task<Void, Never>?

    init(connection: NWConnection,
         identity: GuestListener.HostIdentity,
         timing: GuestListener.Timing,
         isBusy: @escaping () -> String?,
         onActive: @escaping (Session) -> Void,
         onLog: @escaping (String) -> Void,
         onHealth: @escaping (GuestListener.SessionHealth?) -> Void,
         onCommandResult: @escaping (CommandResult) -> Void,
         onCapture: @escaping (Result<GuestListener.CaptureDelivery,
                                      GuestListener.CaptureFailure>) -> Void,
         onCaptureProgress: @escaping (GuestListener.CaptureProgress?) -> Void,
         onPushedCapture: @escaping (GuestListener.CaptureDelivery) -> Void,
         onStreamFrame: @escaping (GuestListener.CaptureDelivery) -> Void,
         onStreamStopped: @escaping (StreamStopped) -> Void,
         onStreamRequest: @escaping (StreamRequest) -> Void,
         onFileListing: @escaping (FileListing) -> Void,
         onFileRefuse: @escaping (FileRefuse) -> Void,
         onFileDelivery: @escaping (Result<GuestListener.FileDelivery,
                                           GuestListener.FileFailure>)
             -> Void,
         onClosed: @escaping (Session, String) -> Void) {
        self.connection = connection
        self.identity = identity
        self.timing = timing
        self.isBusy = isBusy
        self.onActive = onActive
        self.onLog = onLog
        self.onHealth = onHealth
        self.onCommandResult = onCommandResult
        self.onCapture = onCapture
        self.onCaptureProgress = onCaptureProgress
        self.onPushedCapture = onPushedCapture
        self.onStreamFrame = onStreamFrame
        self.onStreamStopped = onStreamStopped
        self.onStreamRequest = onStreamRequest
        self.onFileListing = onFileListing
        self.onFileRefuse = onFileRefuse
        self.onFileDelivery = onFileDelivery
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
                if let begin = fileBegin {
                    fileBuffer.append(contentsOf: frame.payload)
                    onCaptureProgress(.init(received: fileBuffer.count,
                                            expected: begin.bytes))
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
            protocolError("bad control message: \(error)")
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
        case .fileListing(let listing):
            onFileListing(listing)
        case .fileRefuse(let refuse):
            fileBegin = nil
            fileBuffer = []
            onFileRefuse(refuse)
        case .fileBegin(let begin):
            fileBegin = begin
            fileBuffer = []
            fileBuffer.reserveCapacity(begin.bytes)
            fileStart = Date()
            onCaptureProgress(.init(received: 0, expected: begin.bytes))
        case .fileEnd(let end):
            finishFile(end)
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
              + "\(offer.depth)-bit screenshot (\(offer.bytes / 1024) KB)")
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

    func sendFileGet(id: Int, path: String, container: String?) {
        fileBegin = nil
        fileBuffer = []
        fileStart = Date()
        send(.fileGet(FileGet(id: id, path: path, container: container)))
    }

    func cancelFile() {
        guard let begin = fileBegin else { return }
        send(.fileCancel(FileCancel(transfer: begin.transfer)))
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

    private func finishFile(_ end: FileEnd) {
        guard let begin = fileBegin else { return }
        fileBegin = nil
        let bytes = fileBuffer
        fileBuffer = []
        guard end.ok else {
            onFileDelivery(.failure(.init(
                code: "io-error",
                message: "the guest could not send \(begin.name)")))
            return
        }
        guard bytes.count == begin.bytes else {
            onFileDelivery(.failure(.init(
                code: "io-error",
                message: "\(begin.name) arrived truncated "
                    + "(\(bytes.count) of \(begin.bytes) bytes)")))
            return
        }
        onFileDelivery(.success(.init(
            name: begin.name, container: begin.container,
            fileType: begin.fileType, creator: begin.creator,
            modified: begin.modified, bytes: Data(bytes),
            transferMs: Int(Date().timeIntervalSince(fileStart) * 1000))))
    }

    private func finishCapture(_ end: CaptureEnd) {
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
                onLog("\(guestName)'s screenshot push failed")
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
                onLog("dropped an undecodable stream frame: \(error)")
            } else if pushed {
                onLog("could not decode \(guestName)'s screenshot: \(error)")
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
        onLog(line)
        onActive(self)
    }

    private func refuse(_ reason: String) {
        onLog("Refused a connection: \(reason)")
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

    private func send(_ message: ControlMessage) {
        guard let payload = try? ControlMessageCodec.encode(message),
              let frame = try? FrameCodec.encode(channel: .control,
                                                 payload: payload) else {
            return
        }
        connection.send(content: frame, completion: .idempotent)
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
    private func finish(reason: String, sending farewell: ControlMessage? = nil) {
        guard !closed else { return }
        closed = true
        if helloed {
            onLog(reason)
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
            })
        } else {
            connection.cancel()
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
