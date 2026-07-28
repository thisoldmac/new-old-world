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
    /// It takes the hello because the answer now depends on WHO is
    /// dialling — the host serves several guests at once and refuses only
    /// a machine that is already connected. The predicate that took no
    /// argument could only answer "is anybody here", which is the same
    /// answer for the guest already connected and for the other Mac on
    /// the desk.
    private let admit: (Hello) -> String?
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
    /// What a guest that sent no name is called. One constant, because
    /// GuestKey folds by it too and a second spelling would let an
    /// unnamed guest be admitted twice under two different keys.
    static let unnamedGuest = "Classic Mac"
    /// Set at the gate, from the hello. Nil until then.
    private(set) var guestKey: GuestKey?
    private var idleTask: Task<Void, Never>?

    init(connection: NWConnection,
         identity: GuestListener.HostIdentity,
         timing: GuestListener.Timing,
         pacing: GuestListener.Pacing,
         admit: @escaping (Hello) -> String?,
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
        self.admit = admit
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
        if let reason = admit(hello) {
            refuse(reason)
            return
        }
        helloed = true
        guestName = hello.name ?? Self.unnamedGuest
        /* Settled before onActive, so the listener files this session
           under the same key the gate just admitted it by. */
        guestKey = GuestKey(hello: hello)
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