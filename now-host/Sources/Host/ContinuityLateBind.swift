import AppKit
import Foundation
import MirrorKitUI

/// WHICH FILE THIS GESTURE IS CARRYING, kept answerable until the drop asks.
///
/// **The crossing is not the last moment the Mac can name the file, and on a
/// single-gesture drag it is not even the first.** The identity of a dragged
/// icon is read by the resident inside the Finder's own drag loop, but it is
/// PUBLISHED by the application, which gets no task time while that loop
/// runs. Measured 2026-08-16 (build `cfc5c1a1`): the drag-sourced generation
/// reaches this Mac 14 ticks — about 230 ms — after the drag ENDS, and the
/// crossing is what ends it, because the handback releases the guest press.
/// So the fact arrives a fifth of a second after the cross has already
/// decided, while the `NSDraggingSession` it should have decided still has
/// seconds of human time left in it.
///
/// A frozen stub cannot use that. This box can: the pasteboard is immutable
/// once a session exists, but the promise's `writePromiseTo` callback does
/// not run until the DROP, and it reads whatever this box says then. So the
/// bind is allowed one revision after the cross, and the window closes —
/// firmly, once, and out loud — at redemption.
///
/// It is deliberately a small mutable box rather than a second decision
/// table: `ContinuitySelectionBind.decide` already ranks `.dragged` above
/// every cache case. Nothing here re-argues precedence; it only changes WHEN
/// that verdict may be applied.
@MainActor
final class ContinuityDragBinding {
    /// Which crossing this is. Carried into every line so a revision, its
    /// seed and its redemption can be read as one gesture in a log that
    /// interleaves several.
    let gesture: UInt64
    /// The provider whose `userInfo` mirrors this binding.
    ///
    /// Weak on purpose: the pasteboard owns the provider for the length of
    /// the drag, and a binding outliving the drag must not keep it alive.
    /// `userInfo` is kept in step with `stub` so everything that reads a
    /// promise's identity — this Mac's own delegate, and every test that
    /// asks a provider what it carries — sees the CURRENT answer rather
    /// than the seed.
    private(set) weak var provider: NSFilePromiseProvider?
    /// The same provider's identity, kept separately because the promise
    /// delegate's `writePromiseTo` is nonisolated: under Swift 6 the
    /// provider itself cannot be carried into a main-actor closure, but a
    /// plain identity can, and identity is the whole question there.
    private(set) var providerID: ObjectIdentifier?
    /// What the drop will ask the Mac for, or nil while this gesture is
    /// still waiting to be told.
    private(set) var stub: ContinuityDragStub?
    /// What the crossing STARTED with, kept for the redemption's own line.
    /// The provider's `userInfo` follows every revision, so it cannot answer
    /// "was this a late bind" at the drop — and that is the one question the
    /// next wrong-file report will ask.
    let seed: ContinuityDragStub?
    /// The drop has taken its answer. Nothing may revise the binding after
    /// this: a file already being fetched under one identity cannot become
    /// a different file, and a generation arriving late enough to try is a
    /// generation about the NEXT gesture.
    private(set) var redeemed = false
    /// The pasteboard already carries this file's BYTES, not a promise.
    ///
    /// An eager fetch that wins its race hands AppKit a real `file://` URL,
    /// because a promise-only pasteboard reads as nothing-droppable to every
    /// application that never adopted `NSFilePromiseReceiver` (metal,
    /// 2026-08-15). That is worth keeping — but a pasteboard cannot be
    /// revised once a session exists, so a drag that took the head start has
    /// spent its right to a late bind and says so rather than pretending.
    private(set) var pinned = false

    init(gesture: UInt64, stub: ContinuityDragStub?) {
        self.gesture = gesture
        self.stub = stub
        seed = stub
    }

    func attach(_ provider: NSFilePromiseProvider) {
        self.provider = provider
        providerID = ObjectIdentifier(provider)
        provider.userInfo = stub
    }

    /// The eager fetch won: this drag carries bytes, and bytes cannot be
    /// revised.
    func pin() { pinned = true }

    /// What this gesture can be redeemed with RIGHT NOW, or nil while the
    /// only account of it is an identity.
    ///
    /// The seed is not consulted as a fallback and does not need to be:
    /// `revise` refuses to replace a live generation with a zero, so the
    /// best number this gesture ever had is the one still in `stub`.
    var grabbable: ContinuityDragStub? {
        guard let stub, stub.generation != 0 else { return nil }
        return stub
    }

    /// Applies a late `.dragged` verdict, or says why it could not.
    func revise(to next: ContinuityDragStub) -> ContinuityLateBind.Outcome {
        /* A ZERO IS NOT AN ARRIVAL. An identity-only stub reaching a
           binding that already carries a minted generation would undo the
           only thing the drop can spend — the same displacement the cache
           refuses one layer up, and the reason a fetched file was thrown
           away on metal 2026-08-16. The name is already bound; there is
           nothing here for a number that does not exist to add. */
        if next.generation == 0, let held = stub, held.generation != 0 {
            return .unusable(reason: "generation 0 names an identity and no "
                + "grant; this crossing already carries generation "
                + "\(held.generation) for \(held.item.name), and a drag "
                + "that has not been minted yet cannot take that away")
        }
        guard !pinned else {
            return .unusable(reason: "this drag already carries the file's "
                + "own bytes — an eager fetch won the race before the Mac "
                + "named anything else, and a pasteboard cannot be revised "
                + "once a session exists")
        }
        guard !redeemed else {
            return .refusedRedeemed(gesture: gesture,
                                    generation: next.generation)
        }
        let previous = stub
        guard previous?.generation != next.generation
                || previous?.epoch != next.epoch else {
            return .unchanged(gesture: gesture, generation: next.generation)
        }
        stub = next
        provider?.userInfo = next
        return .revised(gesture: gesture,
                        from: previous.map {
                            "\($0.item.name) (generation \($0.generation))"
                        },
                        to: "\(next.item.name) (generation \(next.generation))")
    }

    /// Closes the revision window and hands over whatever was named. Nil is
    /// an honest answer — a crossing that started pending a late bind and
    /// was never told anything has no file, and refusing is what it must do.
    func redeem() -> ContinuityDragStub? {
        redeemed = true
        return stub
    }
}

/// What happened to a generation that arrived after the crossing.
///
/// Every case is a sentence the edge controller says out loud: a revision
/// that is not audited is indistinguishable, from a log, from the wrong file
/// simply having been bound in the first place — which is the confusion the
/// whole drag plane exists to end.
enum ContinuityLateBind {
    /// The three calls the late-bind lane needs, named together because a
    /// controller holding only some of them could start a crossing it can
    /// never fill in.
    @MainActor
    struct Lane {
        /// A drag to start when the cross binds nothing at all.
        var pendingItem: () -> HostFileDragItem?
        /// Which crossing is live, for the log. Nil when none is.
        var gesture: () -> UInt64?
        /// Apply a generation that arrived after the cross.
        var revise: (ContinuitySelectionMark) -> Outcome
        /// Apply a generation the Mac minted for a gesture whose EPOCH had
        /// already ended — the crossing case, and the only one that carries
        /// a whole stub rather than a mark.
        ///
        /// It takes the stub because there is no cache to look it up in: an
        /// ended epoch has no bindable selection by construction, so the
        /// frame itself is the only account, and joining it by `dragSeq` is
        /// what stands in for the agreement the cache would have provided.
        var reviseAfterEpoch: (ContinuityDragStub) -> Outcome
    }

    enum Outcome: Equatable {
        /// The bound candidate was replaced. `from` is nil when the crossing
        /// started with nothing at all — the single-gesture case.
        case revised(gesture: UInt64, from: String?, to: String)
        /// The drop already took its answer. The window is shut.
        case refusedRedeemed(gesture: UInt64, generation: UInt32)
        /// The arrival names what is already bound.
        case unchanged(gesture: UInt64, generation: UInt32)
        /// The Mac published something this lane cannot drag — a folder, an
        /// other-epoch stub, a cleared cache. Named rather than swallowed.
        case unusable(reason: String)
        /// No crossing of ours is open.
        case noGesture
    }
}
