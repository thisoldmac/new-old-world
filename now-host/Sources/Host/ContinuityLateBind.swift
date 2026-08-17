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
    /// The drop has taken its answer. Nothing may revise the binding after
    /// this: a file already being fetched under one identity cannot become
    /// a different file, and a generation arriving late enough to try is a
    /// generation about the NEXT gesture.
    private(set) var redeemed = false

    init(gesture: UInt64, stub: ContinuityDragStub?) {
        self.gesture = gesture
        self.stub = stub
    }

    func attach(_ provider: NSFilePromiseProvider) {
        self.provider = provider
        providerID = ObjectIdentifier(provider)
        provider.userInfo = stub
    }

    /// Applies a late `.dragged` verdict, or says why it could not.
    func revise(to next: ContinuityDragStub) -> ContinuityLateBind.Outcome {
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
    /// never fill in. Same shape, and the same reason, as
    /// `ContinuityFileDrag.Presentation`.
    @MainActor
    struct Lane {
        /// A drag to start when the cross binds nothing at all.
        var pendingItem: () -> HostFileDragItem?
        /// Which crossing is live, for the log. Nil when none is.
        var gesture: () -> UInt64?
        /// Apply a generation that arrived after the cross.
        var revise: (ContinuitySelectionMark) -> Outcome
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
