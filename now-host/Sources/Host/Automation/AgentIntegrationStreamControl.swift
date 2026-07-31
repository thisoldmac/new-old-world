import CryptoKit
import Combine
import Foundation
import NOWAgentIntegration

/// The host's half of the agent stream lane: open the bracket the listener
/// already owns, hand out one whole frame at a time, close it — **and end it
/// when the agent that opened it is no longer there.**
///
/// The first three are bookkeeping over machinery that already worked. The
/// fourth is the reason this file exists, and it is the one question a stream
/// asks that no other capability on this surface does.
///
/// ## Every other projection is one bounded call. This one is a bracket.
///
/// A capture ends. A file transfer ends. A census page ends. Each holds the
/// connection's one transfer lane for as long as it takes and then lets go,
/// so an agent that walks away mid-call costs the machine one unfinished
/// operation. A stream does not end: it holds the lane, and a classic Mac
/// keeps grabbing its screen, until somebody says stop. An agent that opens
/// one and disconnects has left a PowerBook working for nobody, and nothing
/// in the request/response model of this surface would ever notice.
///
/// ## So who ends it, and how the host can tell
///
/// **Both of the two mechanisms below, because neither subsumes the other.**
///
/// 1. **The owner is gone.** The bracket records the pid the kernel named on
///    the socket that opened it (`AgentIntegrationLocalCaller`), and the host
///    asks every few seconds whether that process still exists. A companion
///    is launched by its MCP client and lives as long as the conversation
///    does, so this is a real signal and it fires within seconds of the
///    client quitting — which is the case that would otherwise hold the lane
///    until somebody noticed.
///
/// 2. **The owner has stopped watching.** Liveness is not attention: an MCP
///    client left open all afternoon keeps its companion alive, and a stream
///    nobody reads is exactly as expensive as one nobody opened. So the
///    bracket also carries a LEASE, renewed by any stream call from the
///    process that opened it, and expires without one.
///
/// The first catches the process that died; the second catches the process
/// that lived and lost interest. **Neither catches the other**: a dead
/// companion's lease has up to a minute left to run, and a live idle one
/// passes every liveness check there is. Pid recycling is the seam between
/// them — a recycled pid reads as alive, and the lease is what ends that
/// stream anyway.
///
/// ## What is deliberately NOT here
///
/// A maximum duration. An agent that keeps asking for frames is watching, and
/// cutting it off at ten minutes would be arbitrary — the person at the host
/// can end any stream from the page they are already looking at, and that is
/// a better answer than a number this file would have to defend. The cost of
/// that choice is stated rather than hidden: an agent that keeps calling can
/// hold a 1400c's screen lane for as long as it keeps calling.
///
/// Nothing here decides anything about the picture. A frame is decoded,
/// composited and delivered by `Session` and `GuestListener` exactly as it is
/// for the live view; this stages the PNG and pages it out, which is the same
/// thing `AgentIntegrationCaptureControl` does and for the same reason.
@MainActor
final class AgentIntegrationStreamControl {
    /// One frame, staged for the pages of the call that asked for it.
    private struct Stage {
        let image: AgentIntegrationCaptureImage
        let png: Data
        let stagedAt: Date
    }

    /// What this side remembers about a bracket **it** opened.
    private struct Ownership {
        let streamID: Int
        let processID: pid_t
        var leaseExpiresAt: Date
    }

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let clock: @MainActor () -> Date
    /// The caller's pid, injected so a test can drive ownership without
    /// standing up a socket. In the app it is the kernel's answer, read off
    /// the accepted connection by the local server.
    private let callerProcessID: @MainActor () -> pid_t?
    private let isProcessRunning: @Sendable (pid_t) -> Bool
    private let frameTimeout: TimeInterval

    private var stage: Stage?
    private var ownership: Ownership?
    private var watchdog: Task<Void, Never>?
    /// The most recent frame the open bracket has delivered, and whether it
    /// has been handed out. A frame request arms this and waits.
    private var frameWaiters: [CheckedContinuation<
        GuestListener.CaptureDelivery?, Never>] = []
    private var frameWatch: AnyCancellable?
    private var streamWatch: AnyCancellable?

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         clock: @escaping @MainActor () -> Date = { Date() },
         callerProcessID: @escaping @MainActor () -> pid_t? = {
             AgentIntegrationLocalCaller.processID
         },
         isProcessRunning: @escaping @Sendable (pid_t) -> Bool = {
             AgentIntegrationLocalCaller.isRunning($0)
         },
         frameTimeout: TimeInterval =
            AgentIntegrationStreamPolicy.frameTimeout) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.clock = clock
        self.callerProcessID = callerProcessID
        self.isProcessRunning = isProcessRunning
        self.frameTimeout = frameTimeout
        frameWatch = listener.streamFrames.sink { [weak self] delivery in
            self?.receive(delivery)
        }
        /* The bracket can end without this side asking: the guest stops it,
           the connection drops, the person clicks Stop. Ownership that
           outlived the bracket would have this file ending somebody else's
           next stream on a lease that belonged to a bracket that is gone.

           **This and the same-bracket guard in `endIfOwnerIsGone` overlap,
           and the mutations say exactly how.** Deleting either one alone
           leaves every test green; deleting BOTH fails
           `testAPersonsStreamIsNeverEndedByTheOwnershipRule`, so what is
           proven is the property rather than either line. They are kept
           apart anyway because they answer at different moments and only
           this one is prompt: the guard notices at the next five-second
           tick, and this releases the watchdog the instant the bracket
           closes. It is also the only one of the two that can be shown to
           matter on its own — with it gone, a second agent bracket inherits
           the first's ownership record if `start` is ever made not to
           overwrite one (mutation M4). */
        streamWatch = listener.$activeStreamId.sink { [weak self] id in
            guard let self, id != self.ownership?.streamID else { return }
            self.releaseOwnership()
        }
    }

    // MARK: - Opening it

    func start(depth: Int, minIntervalMs: Int)
        -> AgentIntegrationStreamResult {
        guard AgentIntegrationCapturePolicy.isValidDepth(depth) else {
            return .refused(.init(
                code: "now-capture-depth-invalid",
                message: "\(depth) is not a depth the guest implements"))
        }
        guard AgentIntegrationStreamPolicy.isValidInterval(minIntervalMs)
        else {
            return .refused(
                AgentIntegrationStreamFailure.intervalOutOfRange(
                    minIntervalMs))
        }
        guard let sessionID = currentSessionID() else {
            return .guestUnavailable
        }
        /* The lane is one transfer wide across captures, files and streams
           alike, so a stream cannot start on top of any of them. The
           refusal names WHICH, because "busy" alone sends an agent looking
           for a fault in a host that is working — and the commonest holder
           by far is a person watching their own Mac. */
        if let origin = listener.streamOrigin {
            return .refused(AgentIntegrationStreamFailure.busy(origin))
        }
        guard !listener.isCapturePending,
              listener.fileTransferInFlight == nil else {
            return .refused(.init(
                code: "now-stream-busy",
                message: "The connection's one transfer lane is already "
                    + "carrying a capture or a file."))
        }

        guard let streamID = listener.startStream(
            depth: depth, minIntervalMs: minIntervalMs, origin: .agent)
        else {
            /* The listener refused, and the only reasons it can are that
               nothing is connected or the lane was taken between the checks
               above and this line. Both are the machine's availability
               rather than a refusal of this call. */
            return .guestUnavailable
        }
        /* An owner the kernel would not name is NO owner, and the bracket is
           still opened: refusing to stream because a lookup missed would be
           punishing a working agent for a race in the accept path. What such
           a bracket loses is its liveness check — the lease still ends it,
           which is why the two mechanisms are worth having separately. */
        if let processID = callerProcessID() {
            ownership = Ownership(
                streamID: streamID,
                processID: processID,
                leaseExpiresAt: clock().addingTimeInterval(
                    AgentIntegrationStreamPolicy.lease))
            armWatchdog()
        }
        return .bracket(bracket(state: .open, sessionID: sessionID))
    }

    // MARK: - Reading a frame off it

    /// Ask the guest for a whole frame and answer with its first page.
    ///
    /// **It always sends `stream.refresh` and waits for the frame that
    /// follows**, rather than handing back the newest frame already in hand.
    /// The already-held one is free and would be the faster answer; it would
    /// also be a picture of an unknown moment, possibly before the caller's
    /// previous call. An agent watching a machine act on what it just asked
    /// for needs "after you asked" to be true, and that is exactly what the
    /// keyframe request buys.
    func nextFrame() async -> AgentIntegrationStreamResult {
        guard let sessionID = currentSessionID() else {
            stage = nil
            return .guestUnavailable
        }
        guard listener.activeStreamId != nil else {
            return .refused(AgentIntegrationStreamFailure.notOpen)
        }
        renewLease()

        listener.refreshStream()
        guard let delivery = await awaitFrame() else {
            return .refused(AgentIntegrationStreamFailure.noFrame)
        }
        /* Re-read rather than trusted, for the reason the capture lane
           re-reads it: the wait took real time on a classic Mac, and a
           session that changed underneath means this frame is of a machine
           nobody asked about. */
        guard currentSessionID() == sessionID else {
            stage = nil
            return .guestUnavailable
        }
        guard let png = CaptureDecoder.pngData(delivery.image) else {
            return .refused(AgentIntegrationStreamFailure.encodeFailed)
        }
        guard png.count <= AgentIntegrationCapturePolicy.maximumBytes else {
            return .refused(AgentIntegrationStreamFailure.tooLarge)
        }
        let image = AgentIntegrationCaptureImage(
            captureID: UUID(),
            sessionID: sessionID,
            capturedAt: clock(),
            width: delivery.format.width,
            height: delivery.format.height,
            depth: delivery.format.depth,
            transferMs: delivery.transferMs,
            wireBytes: delivery.wireBytes,
            bytes: png.count,
            sha256: Self.hex(SHA256.hash(data: png)))
        stage = Stage(image: image, png: png, stagedAt: clock())
        return page(frameID: image.captureID, offset: 0)
    }

    func page(frameID: UUID, offset: Int) -> AgentIntegrationStreamResult {
        guard let sessionID = currentSessionID() else {
            stage = nil
            return .guestUnavailable
        }
        /* Renewed FIRST, before anything can refuse the request. It sat
           below the stage guard until a mutation showed what that meant: a
           page fetch that missed — a stage that had expired, an offset off
           the boundary — did not renew, so an agent reading a large frame
           slowly could lose the bracket underneath the read.

           The rule the placement encodes: **the lease is about presence,
           not about success.** An owner that calls at all is there, and a
           refused call is still a call. The bracket's cost is paid for
           frames, and this is not the gate on frames. */
        renewLease()
        guard let current = stage,
              current.image.captureID == frameID,
              current.image.sessionID == sessionID,
              clock().timeIntervalSince(current.stagedAt)
                <= AgentIntegrationCapturePolicy.stageLifetime else {
            if let current = stage,
               clock().timeIntervalSince(current.stagedAt)
                   > AgentIntegrationCapturePolicy.stageLifetime {
                stage = nil
            }
            return .refused(AgentIntegrationStreamFailure.staleFrame)
        }
        guard offset >= 0, offset < current.png.count,
              offset % AgentIntegrationCapturePolicy.pageBytes == 0 else {
            return .refused(.init(
                code: "now-stream-frame-offset-invalid",
                message: "\(offset) is not a page boundary inside this "
                    + "frame's \(current.png.count) bytes"))
        }
        let end = min(offset + AgentIntegrationCapturePolicy.pageBytes,
                      current.png.count)
        let bytes = current.png[offset..<end]
        if end == current.png.count { stage = nil }
        /* The bracket is reported on every page beside the picture, exactly
           as the capture's image record is: a bracket that closed mid-fetch
           is a fact the caller has to be able to see without asking again. */
        return .frame(.init(
            bracket: bracket(
                state: listener.activeStreamId == nil ? .closed : .open,
                sessionID: sessionID),
            chunk: .init(
                image: current.image,
                page: .init(offset: offset,
                            base64: Data(bytes).base64EncodedString()))))
    }

    // MARK: - Closing it

    /// Close the bracket, whoever opened it.
    ///
    /// Not restricted to its owner, and that is a decision rather than an
    /// omission: ending a stream is the one direction that needs no standing.
    /// The person at the host can already end any of them from the Screenshots
    /// page, a guest can end its own, and an agent refused the ability to stop
    /// a stream it can see would be an agent that can only make the situation
    /// worse.
    func stop() -> AgentIntegrationStreamResult {
        guard let sessionID = currentSessionID() else {
            stage = nil
            return .guestUnavailable
        }
        guard listener.activeStreamId != nil else {
            return .refused(AgentIntegrationStreamFailure.notOpen)
        }
        let closing = bracket(state: .closed, sessionID: sessionID)
        listener.stopStream()
        releaseOwnership()
        /* Reported closed HERE rather than after the guest acknowledges,
           and the difference is only about who says so: the host's bracket
           is shut the moment it asks, `stopStream` self-heals if the guest
           never answers, and a caller made to wait for `stream.stopped`
           would be waiting on the machine to agree about the host's own
           lane. */
        return .bracket(closing)
    }

    /// Drops the staged frame and any ownership. Called when the connection
    /// goes: the next guest is not this one.
    func forgetGuest() {
        stage = nil
        releaseOwnership()
        resumeWaiters(with: nil)
    }

    // MARK: - The ownership rule

    private func renewLease() {
        guard var current = ownership,
              current.processID == callerProcessID() else { return }
        current.leaseExpiresAt = clock().addingTimeInterval(
            AgentIntegrationStreamPolicy.lease)
        ownership = current
    }

    private func releaseOwnership() {
        ownership = nil
        watchdog?.cancel()
        watchdog = nil
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(
                        AgentIntegrationStreamPolicy.ownerCheckInterval
                            * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard await self.endIfOwnerIsGone() else { return }
            }
        }
    }

    /// Returns whether the bracket is still open and still owned — false when
    /// there is nothing left to watch, so the watchdog can stop.
    @discardableResult
    func endIfOwnerIsGone() -> Bool {
        guard let current = ownership else { return false }
        guard listener.activeStreamId == current.streamID else {
            releaseOwnership()
            return false
        }
        let running = isProcessRunning(current.processID)
        let leased = clock() < current.leaseExpiresAt
        guard !running || !leased else { return true }
        HostLog.shared.write(
            .info, "agent",
            running
                ? "ending the agent's live stream: no call from pid "
                    + "\(current.processID) in "
                    + "\(Int(AgentIntegrationStreamPolicy.lease)) s"
                : "ending the agent's live stream: pid "
                    + "\(current.processID) is gone")
        listener.stopStream()
        releaseOwnership()
        return false
    }

    // MARK: - Waiting for one frame

    private func awaitFrame() async -> GuestListener.CaptureDelivery? {
        let timeout = Task { [frameTimeout] in
            try? await Task.sleep(
                nanoseconds: UInt64(frameTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.resumeWaiters(with: nil) }
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            frameWaiters.append(continuation)
        }
    }

    private func receive(_ delivery: GuestListener.CaptureDelivery) {
        resumeWaiters(with: delivery)
    }

    private func resumeWaiters(with delivery: GuestListener.CaptureDelivery?) {
        let waiting = frameWaiters
        frameWaiters = []
        for continuation in waiting {
            continuation.resume(returning: delivery)
        }
    }

    // MARK: - Describing it

    private func bracket(state: AgentIntegrationStreamBracket.State,
                         sessionID: UUID) -> AgentIntegrationStreamBracket {
        AgentIntegrationStreamBracket(
            streamID: listener.activeStreamId ?? ownership?.streamID ?? 0,
            sessionID: sessionID,
            state: state,
            origin: listener.streamOrigin ?? .agent,
            openedAt: listener.streamOpenedAt ?? clock(),
            depth: listener.streamDepth
                ?? AgentIntegrationCapturePolicy.defaultDepth,
            minIntervalMs: listener.streamMinIntervalMs
                ?? AgentIntegrationStreamPolicy.defaultMinIntervalMs,
            /* Reported only for a bracket this side owns. A person's stream
               has no lease, and a nil here is the honest way to say so —
               inventing one would tell an agent that somebody else's live
               view is about to end. */
            leaseExpiresAt: state == .open
                ? ownership?.leaseExpiresAt : nil,
            closedReason: state == .closed
                ? listener.streamEndReason : nil)
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String
        where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
