import Foundation

/// The testable seam for host→guest cross-edge drag's identity-crossing
/// half — `docs/local/plan-host-to-guest-drag-2026-08-15.md` slice 1.
///
/// Deliberately NOT `ContinuityEdgeController`: that file drives the
/// AppKit drag gesture (slice 3, owned by a sibling lane while this ships).
/// This class calls only `GuestListener.publishContinuityOffer` /
/// `clearContinuityOffer`, so an agent command or a debug console verb can
/// exercise publish-and-serve end to end before any gesture exists, and so
/// the gesture lane can bind to the same two calls later rather than a
/// third path growing beside them.
@MainActor
final class AgentIntegrationContinuityOfferControl {
    enum PublishOutcome {
        case published(ContinuityOffer.Item)
        case guestUnavailable
        case failed(reason: String)
    }

    private let listener: GuestListener
    private let audit: (HostLog.LogLevel, String) -> Void

    init(listener: GuestListener,
        audit: ((HostLog.LogLevel, String) -> Void)? = nil) {
        self.listener = listener
        self.audit = audit ?? { HostLog.shared.write($0, "continuity", $1) }
    }

    /// Publishes one local file as this Mac's offer. `epoch`/`generation`
    /// are the caller's to supply — a live Continuity session's own
    /// numbers when driven from a gesture later, or whatever a test or a
    /// debug console verb wants to assert against now.
    func publish(fileAt url: URL, epoch: UInt32, generation: UInt32)
        -> PublishOutcome {
        guard let key = listener.activeKey else {
            return .guestUnavailable
        }
        do {
            let item = try listener.publishContinuityOffer(
                guestKey: key, epoch: epoch, generation: generation,
                fileAt: url)
            return .published(item)
        } catch {
            audit(.error, "offer publish failed: \(url.lastPathComponent) "
                + "(\(error))")
            return .failed(reason: "\(error)")
        }
    }

    /// Tears down whatever the guest was drawing, under a fresh
    /// generation carrying no item.
    func clear(epoch: UInt32, generation: UInt32) -> Bool {
        guard let key = listener.activeKey else { return false }
        listener.clearContinuityOffer(guestKey: key, epoch: epoch,
                                      generation: generation)
        return true
    }
}
