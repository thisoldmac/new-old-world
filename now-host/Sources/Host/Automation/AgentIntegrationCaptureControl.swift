import CryptoKit
import Foundation
import NOWAgentIntegration

/// The host's half of the agent capture lane: ask the paired guest for its
/// screen through the existing listener, re-encode the decoded image as PNG,
/// and hand it out one page at a time.
///
/// It owns no listener lifecycle and no capture policy of its own. The
/// request is `GuestListener.requestCapture` — the same call the Screenshots
/// page's button makes, with the same watchdog — and the picture is decoded by
/// the same `CaptureDecoder`. What is new here is only the staging: an image
/// is one answer that cannot fit in one 16 KiB local response, so it is held
/// briefly and read out in pages.
///
/// **Nothing here is remembered as an answer.** A stage exists to be paged
/// out by the call that made it and is dropped when it expires, when the
/// session changes, or when the next capture replaces it. A caller that comes
/// back later gets `now-capture-stale`, never a picture of a moment that has
/// passed — the same freshness contract the process references keep.
@MainActor
final class AgentIntegrationCaptureControl {
    /// One capture, staged for the pages of the call that took it.
    private struct Stage {
        let image: AgentIntegrationCaptureImage
        let png: Data
        let stagedAt: Date
    }

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let clock: @MainActor () -> Date
    private var stage: Stage?

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.clock = clock
    }

    // MARK: - Taking one

    func capture(depth: Int) async -> AgentIntegrationCaptureResult {
        guard AgentIntegrationCapturePolicy.isValidDepth(depth) else {
            return .refused(.init(
                code: "now-capture-depth-invalid",
                message: "\(depth) is not a depth the guest implements"))
        }
        guard let sessionID = currentSessionID() else {
            stage = nil
            return .guestUnavailable
        }
        /* There is exactly one transfer lane on this wire, and the app's own
           Capture button guards it the same way (QuickCaptureReadiness). An
           agent call that ignored it would overwrite the completion the
           person at the machine is waiting on — their button would stay
           "Capturing…" for as long as the app ran. */
        guard !listener.isCapturePending, listener.activeStreamId == nil else {
            return .refused(.busy)
        }

        let delivery = await withCheckedContinuation { continuation in
            listener.requestCapture(depth: depth) {
                continuation.resume(returning: $0)
            }
        }
        /* Re-read rather than trusted: the request took real time on a
           classic Mac, and a session that ended or changed underneath it
           means this picture is of a machine nobody asked about. */
        guard currentSessionID() == sessionID else {
            stage = nil
            return .guestUnavailable
        }

        switch delivery {
        case .failure(let failure):
            return .refused(.guestFailed(failure.message))
        case .success(let capture):
            guard let png = CaptureDecoder.pngData(capture.image) else {
                return .refused(.init(
                    code: "now-capture-encode-failed",
                    message: "The capture could not be encoded as PNG"))
            }
            guard png.count <= AgentIntegrationCapturePolicy.maximumBytes
            else {
                return .refused(.tooLarge)
            }
            let image = AgentIntegrationCaptureImage(
                captureID: UUID(),
                sessionID: sessionID,
                capturedAt: clock(),
                width: capture.format.width,
                height: capture.format.height,
                depth: capture.format.depth,
                transferMs: capture.transferMs,
                wireBytes: capture.wireBytes,
                bytes: png.count,
                sha256: Self.hex(SHA256.hash(data: png)))
            stage = Stage(image: image, png: png, stagedAt: clock())
            return page(captureID: image.captureID, offset: 0)
        }
    }

    // MARK: - Reading it out

    func page(captureID: UUID, offset: Int)
        -> AgentIntegrationCaptureResult {
        guard let sessionID = currentSessionID() else {
            stage = nil
            return .guestUnavailable
        }
        guard let current = stage,
              current.image.captureID == captureID,
              current.image.sessionID == sessionID,
              clock().timeIntervalSince(current.stagedAt)
                <= AgentIntegrationCapturePolicy.stageLifetime else {
            /* A stage that has expired is dropped here rather than left to
               be found again: it is a picture of somebody's screen sitting
               in memory, and the caller that would have read it is gone. */
            if let current = stage,
               clock().timeIntervalSince(current.stagedAt)
                   > AgentIntegrationCapturePolicy.stageLifetime {
                stage = nil
            }
            return .refused(.stale)
        }
        guard offset >= 0, offset < current.png.count,
              offset % AgentIntegrationCapturePolicy.pageBytes == 0 else {
            return .refused(.init(
                code: "now-capture-offset-invalid",
                message: "\(offset) is not a page boundary inside this "
                    + "capture's \(current.png.count) bytes"))
        }
        let end = min(offset + AgentIntegrationCapturePolicy.pageBytes,
                      current.png.count)
        let bytes = current.png[offset..<end]
        /* The last page drops the stage on its way out. Holding it for a
           retry would mean holding every capture any agent ever took until
           its two minutes were up. */
        if end == current.png.count { stage = nil }
        return .captured(.init(
            image: current.image,
            page: .init(offset: offset,
                        base64: Data(bytes).base64EncodedString())))
    }

    // MARK: - Letting go of the lane

    /// Abandons the host's WAIT for a capture in flight.
    ///
    /// The wire's `capture.cancel` is a side effect of that rather than the
    /// point, and it is why this is not exposed as the cancel message: the
    /// listener settles the request locally whether or not the guest honours
    /// the message, and a caller cannot see which happened. The 68K guest
    /// does not implement `capture.cancel` at all and this still releases the
    /// lane there.
    func abandon() -> AgentIntegrationCaptureResult {
        guard currentSessionID() != nil else {
            stage = nil
            return .guestUnavailable
        }
        guard listener.isCapturePending else {
            return .abandoned(.nothingInFlight)
        }
        listener.cancelCapture()
        return .abandoned(.cancelled)
    }

    /// Drops any staged picture. Called when the connection goes: the next
    /// guest is not this one.
    func forgetGuest() {
        stage = nil
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String
        where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
