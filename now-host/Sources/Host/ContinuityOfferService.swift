import Foundation

/// Host-side state for `continuity.offer`: what this Mac is currently
/// carrying toward the guest, and for how long it stays serveable after
/// the epoch that named it ends.
///
/// It is `ContinuityGrabTransfer`'s mirror with the roles inverted. That
/// class REDEEMS a guest's selection stub — this host sends
/// `continuity.grab`, the guest serves. This service PUBLISHES an offer
/// and SERVES the guest's `continuity.grab` for it, down the identical
/// `file.begin`/bulk/`file.end` lane (`Session.serveFile`) every other
/// host-served pull already uses. There is one bulk sender on this side
/// and an offer grab uses it, same as `serveGet`.
///
/// Holds ONE offer at a time, v1's own narrowing (the contract's "several
/// items need a promise group, which one item does not") — publishing a
/// new generation simply replaces whatever was there.
@MainActor
final class ContinuityOfferService {
    /// The bound the contract states once (`ContinuityOffer`, asyncapi.yaml
    /// L~2906): the LAST generation of an ending epoch stays serveable this
    /// long, or until a new-epoch offer, whichever comes first. It is the
    /// same NUMBER as the guest's own grant window and a DIFFERENT
    /// constant — read from here, never derived from that one.
    static let offerLifetimeSeconds: TimeInterval = 30

    /// One local file, published under one epoch/generation, for one
    /// guest connection. `guestKey` is not on the wire — the contract
    /// carries no source identity — but this host must not go on serving
    /// a dead connection's offer to whichever guest reconnects next, so it
    /// is tracked here and checked at `linkDropped`.
    struct Offer {
        var guestKey: GuestKey
        var epoch: UInt32
        var generation: UInt32
        var url: URL
        var plan: OutboundFile.Plan
        var item: ContinuityOffer.Item
        /// Set when the epoch that published this offer ends; nil while
        /// still live, so "how long has this been over" is answered from
        /// the moment it actually ended rather than from publish time.
        var endedAt: Date?
    }

    private(set) var current: Offer?
    /// Which host→guest drag handoff this offer is the promise for, when it
    /// is one at all (an agent- or console-published offer is not). Carried
    /// beside the offer rather than inside it because it identifies the
    /// GESTURE, not the item — and its only job is to let the pull's log
    /// line pair with the handoff's.
    private(set) var handoffDragSeq: UInt32?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Publishes a fresh generation, ending whatever came before it
    /// immediately — the contract's own second clause ("or until it
    /// publishes an offer under a new epoch, whichever comes first").
    func publish(guestKey: GuestKey, epoch: UInt32, generation: UInt32,
                url: URL, plan: OutboundFile.Plan,
                item: ContinuityOffer.Item,
                handoffDragSeq: UInt32? = nil) {
        current = Offer(guestKey: guestKey, epoch: epoch,
                        generation: generation, url: url, plan: plan,
                        item: item, endedAt: nil)
        self.handoffDragSeq = handoffDragSeq
    }

    /// The epoch ended (Continuity disarmed) while an item was still
    /// carried. Starts the bounded window rather than clearing the offer
    /// outright — the guest's Finder may still hold the promise. A no-op
    /// once the window has already started, so a second disarm cannot
    /// restart the clock.
    func endEpoch(at date: Date? = nil) {
        guard current != nil, current?.endedAt == nil else { return }
        current?.endedAt = date ?? clock()
    }

    /// **The carry was abandoned: stop serving at once, with no window.**
    ///
    /// `endEpoch`'s bounded window exists because a guest Finder may still
    /// be holding a promise it has every right to redeem. An abort is the
    /// opposite fact — the drag ended without a drop, nothing over there is
    /// holding anything, and a promise left serveable after that is this
    /// Mac offering a file nobody asked for. Returns what was let go, so
    /// the caller's log can name it.
    @discardableResult
    func release() -> Offer? {
        let offer = current
        current = nil
        handoffDragSeq = nil
        return offer
    }

    /// The connection carrying this offer closed. Ends it immediately —
    /// "consent was given to one Macintosh over one connection" — no
    /// window at all, and only for the guest whose link it was.
    func linkDropped(guestKey: GuestKey) {
        guard current?.guestKey == guestKey else { return }
        current = nil
        handoffDragSeq = nil
    }

    enum GrabOutcome {
        case serve(plan: OutboundFile.Plan)
        case refuse(code: String, reason: String)
    }

    /// Answers one `continuity.grab` from `guestKey`. `no-selection` and
    /// `bad-epoch`/`stale-selection` are the identity mismatches
    /// `continuity.grab` already used in the other direction, inverted;
    /// `offer-expired` is the one new word, naming the bounded window
    /// above rather than the guest's own `grant-expired`.
    func grab(guestKey: GuestKey, epoch: UInt32, generation: UInt32)
        -> GrabOutcome {
        guard let offer = current, offer.guestKey == guestKey else {
            return .refuse(code: "no-selection",
                           reason: "This Mac is not carrying anything.")
        }
        guard offer.epoch == epoch else {
            return .refuse(code: "bad-epoch",
                           reason: "This Mac's offer is under a "
                               + "different Continuity epoch.")
        }
        guard offer.generation == generation else {
            return .refuse(code: "stale-selection",
                           reason: "What this Mac is carrying changed "
                               + "before the file could be copied.")
        }
        if let endedAt = offer.endedAt,
           clock().timeIntervalSince(endedAt) > Self.offerLifetimeSeconds {
            current = nil
            handoffDragSeq = nil
            return .refuse(code: "offer-expired",
                           reason: "This Mac stopped carrying that item "
                               + "more than \(Int(Self.offerLifetimeSeconds))s "
                               + "ago.")
        }
        return .serve(plan: offer.plan)
    }
}
