import Foundation

/// **The seam between a resolved drag and a guest that can hold the mouse
/// button down.**
///
/// Three calls, matching the three things the resident's drag vehicle does —
/// press, move, release (`contract/peek_table.h`, P7). It is a protocol and
/// not a set of verbs here on purpose: this side owns targeting, geometry and
/// presentation, and the act plane's own lane owns the wire. A view that
/// reached for `dragpress` directly would put half of one plane in the other,
/// and neither could be tested without the other's machine.
///
/// ## Every answer is the guest's, and none is assumed
///
/// `dragPress` answers **asynchronously and truthfully**. The view begins
/// showing the drag before that answer arrives — rule 1 of the presentation
/// contract — which is precisely why the answer must be real when it comes: a
/// provisional item is promoted only by `.confirmed`, and a driver that
/// synthesised one would turn "we do not know yet" into a plausible wrong
/// claim about what the guest did. That is the failure mode this whole arc
/// exists to remove, and it is cheapest to prevent here, where the boundary
/// is one enum wide.
///
/// The resident's own `kNowPeekDragEndSessionLost` is the same rule from the
/// other side: a drag whose plane was disarmed under it releases the button
/// and is **never reported as completed**. Anything conforming here inherits
/// that obligation — a lost session is `.refused`, not `.confirmed`.
@MainActor
public protocol ItemDragDriver: AnyObject {

    /// Take hold of `subject` at the point the gesture began. `answer` is
    /// called once, with what the guest actually said.
    func dragPress(_ subject: DragTargeting.Subject, at point: Point,
                   answer: @escaping (ItemDragAnswer) -> Void)

    /// The pointer moved. Fire-and-forget: motion has no answer, and a
    /// resident that stopped hearing them ends the drag on its own dead-man
    /// rather than waiting for this side.
    func dragMove(to point: Point)

    /// Let go.
    ///
    /// `plan` is nil when the release is an **abandonment** — the human let
    /// go before the guest confirmed, so there is nothing to drop and the
    /// item is going home. A driver must still release the button: a mouse
    /// left down is the one failure the resident's dead-man exists for, and
    /// this side must not be the reason it has to fire.
    func dragRelease(_ plan: DragTargeting.Plan?,
                     answer: @escaping (ItemDragAnswer) -> Void)
}

/// What the guest said. Two cases, because a drag has exactly two honest
/// outcomes and "no answer yet" is a state of the view rather than a value
/// here.
public enum ItemDragAnswer: Equatable, Sendable {
    case confirmed
    /// Said in words a person reads: it goes on the status line beside the
    /// item snapping back.
    case refused(String)
}
