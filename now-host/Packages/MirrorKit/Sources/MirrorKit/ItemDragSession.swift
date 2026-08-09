import Foundation

/// **The presentation contract, as state a test can drive.**
///
/// Michelle's four rules for slice 10.5:
///
/// 1. Do not wait for confirmation to begin showing the drag — the item moves
///    with the pointer immediately.
/// 2. Until the select is confirmed, the item shows as **provisional**.
/// 3. Releasing before confirmation **snaps the item back home**.
/// 4. A failed select response **also snaps it back home**.
///
/// Rule 2 is a drawing (`ProvisionalVisual`). The other three are behaviour,
/// and behaviour in a SwiftUI `@State` is behaviour nothing can drive without
/// a window on screen. So the transitions live here, in the renderer-free
/// core, and `LiveMirrorView` is the shell that feeds them a pointer — which
/// is what makes the tests below about the code that actually runs rather
/// than about a second implementation of it.
///
/// **Nothing here can promote itself.** `confirm()` is the only way to
/// `confirmed`, and the only caller is an `ItemDragAnswer.confirmed` that came
/// off the wire. That is the whole of rule 2's honesty: a provisional drag
/// stays provisional until a guest says otherwise, and there is no code path
/// that guesses.
public struct ItemDragSession: Equatable {

    /// What is in flight.
    public let subject: DragTargeting.Subject
    /// The box the Finder drew, in global guest coords. Home.
    public let home: Rect
    /// Where the ghost is now.
    public private(set) var frame: Rect
    /// The guest has taken the press. Set by `confirm()` and nothing else.
    public private(set) var confirmed = false

    /// Where inside the box the pointer took hold, so the item does not jump
    /// to put its corner under the cursor at pickup.
    private let grabX: Int
    private let grabY: Int

    public init(subject: DragTargeting.Subject, home: Rect,
                grabbedAt press: Point) {
        self.subject = subject
        self.home = home
        self.frame = home
        self.grabX = press.x - home.l
        self.grabY = press.y - home.t
    }

    /// Rule 1: this is called on the gesture's own frame, not on a response.
    public mutating func move(to p: Point) {
        let l = p.x - grabX, t = p.y - grabY
        frame = Rect(l: l, t: t,
                     r: l + (home.r - home.l), b: t + (home.b - home.t))
    }

    /// The guest took the press. The one door to `confirmed`.
    public mutating func confirm() { confirmed = true }

    /// How a drag finishes.
    public enum Ending: Equatable {
        /// The plan travels to the guest, and the ghost stays on screen until
        /// the driver answers — the next scene is what will show the item in
        /// its new place.
        case drop(DragTargeting.Plan)
        /// The ghost goes home, and the reason goes on the status line.
        /// Silence here would read as the drag having worked.
        case snapBack(why: String)
    }

    /// What a release means.
    ///
    /// `plan` is what the targeting layer made of where the pointer ended —
    /// passed in rather than computed here so that this stays a pure function
    /// of the session and one outcome, which is what makes rules 3 and 4
    /// checkable side by side.
    public func release(_ plan: Result<DragTargeting.Plan,
                                       DragTargeting.Refusal>) -> Ending {
        guard confirmed else {
            /* RULE 3, and it comes FIRST. A release before confirmation is
               not a drop that happened to land badly — there was never a
               press on the guest to drop with, so where the pointer ended is
               not a question worth asking. Testing the destination first
               would produce a refusal about the target and hide the fact that
               nothing had been picked up at all. */
            return .snapBack(why: "let go before the guest confirmed — "
                             + "\(subject.name) went back")
        }
        switch plan {
        case .success(let p):
            return .drop(p)
        case .failure(let refusal):
            return .snapBack(why: "\(refusal.message) — \(subject.name) "
                             + "went back")
        }
    }

    /// **Rule 4.** The guest answered the press with a refusal, mid-gesture.
    ///
    /// Its own function rather than a case of `release` because it is not a
    /// release: the human may still be holding the button, and the item goes
    /// home under their pointer. The resident's own
    /// `kNowPeekDragEndSessionLost` arrives here too — a drag whose plane was
    /// disarmed beneath it releases the button and is never reported as
    /// completed, which is this ending and not `drop`.
    public func refused(_ why: String) -> Ending {
        .snapBack(why: "the guest would not take \(subject.name): \(why)")
    }
}
