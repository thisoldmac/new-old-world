import Foundation

/// **A press, from intent to verdict — the same decision a third time.**
///
/// `UnknownVisual` says *we do not know this*. `ProvisionalVisual` says *we
/// do not know this yet*, for an item travelling under the pointer. This
/// says it for a button: **shown immediately because the person did it,
/// marked as not-yet-real because the machine has not answered, and settled
/// out loud whichever way it goes.**
///
/// Michelle, 2026-08-07: *"another piece i want to tackle is pressed style
/// for buttons. this can be a mirror-side render first and doesnt need to
/// wait for the guest to respond. Maybe we can even do something like
/// overlay a spinner after a button has been pressed and while waiting for
/// response?"*
///
/// ## Three states, and the middle one is the honest one
///
/// 1. `.pressed` — the human's intent. Drawn on the gesture's own frame,
///    before anything has travelled. This is rule 1 of slice 10.5 restated:
///    do not wait for confirmation to begin showing what the person did.
/// 2. `.waiting` — dispatched, not yet confirmed. This is the spinner, and
///    it is **not a nicety**. `dispatched-but-unconfirmed` is already a real
///    verdict in this tree, measured on a live guest; the UI's job is to
///    render that verdict rather than to invent a timer that means something
///    subtly different.
/// 3. `.settled` — confirmed, refused, timed out, or contradicted. All four
///    are outcomes and all four carry words.
///
/// ## Why the deadline exists, and why it is 8 seconds
///
/// **A spinner that never stops is a silent success wearing a progress
/// indicator** — the exact defect class this arc exists to kill, in its most
/// sympathetic disguise. So the wait is bounded, and what happens at the end
/// is *stated*: `.neverLearned` says we asked and never found out, which is
/// a different claim from "nothing happened" and must not be rendered as
/// one. Simply reverting to unpressed after a silence tells the person their
/// press did not register, and that is a lie about a press that did.
///
/// Eight seconds because Sweep C measured `ctlact part 0` presses on a live
/// guest at **about 5 seconds** to dispatch — roughly 100× a `part 23` — so
/// a deadline at 5 would fire on the ordinary case and call a working press
/// a mystery. It is the smallest bound that leaves the measured worst case
/// room to land, and it is here as a named constant so a better measurement
/// moves it in one edit.
///
/// ## Nothing here promotes itself
///
/// `confirm()` is the only door to `.confirmed`, exactly as `ItemDragSession`
/// has it, and the only caller is an answer that came off the wire. Every
/// other exit — refusal, deadline, contradiction — is a *worse* verdict than
/// confirmed, which is the direction it is safe for this side to move on its
/// own. A press cannot talk itself into having worked.
/// What the guest said about a press.
///
/// Two cases, deliberately the same shape as `ItemDragAnswer` and for the
/// same stated reason: a press has exactly two honest outcomes, and "no
/// answer yet" is a state of the view rather than a value here. The wait,
/// and its bounded end, belong to `PressSession`.
public enum PressAnswer: Equatable, Sendable {
    case confirmed
    /// Said in words a person reads — it goes on the status line beside the
    /// button coming back up.
    case refused(String)
}

public struct PressSession: Equatable {

    /// How long a press may sit unanswered before the wait itself becomes
    /// the finding. See the class comment for the measurement behind it.
    public static let patience: TimeInterval = 8

    /// What the machine finally said, or that it never did.
    public enum Outcome: Equatable, Sendable {
        /// The guest took the press. The one verdict this side cannot reach
        /// on its own.
        case confirmed
        /// The guest answered, and the answer was no.
        case refused(String)
        /// `patience` elapsed with no answer at all.
        ///
        /// **Not a failure and not a success.** The act may well have landed;
        /// what ended is our willingness to keep claiming we are still
        /// finding out. The words say so, because a person who reads
        /// "nothing happened" here has been told something false.
        case neverLearned
        /// The machine's own report contradicted the drawing — the control
        /// we were showing pressed is no longer in the scene.
        ///
        /// The standing rule, applied to our own optimism: when the render
        /// and the machine disagree, the machine is right, **even when the
        /// render looks better**. A pressed highlight hovering where the
        /// guest says there is no longer a button is the mirror showing
        /// something the Mac is not showing.
        case contradicted(String)

        /// Whether the machine itself supplied this verdict. `false` means
        /// this side ran out of evidence, which a caller may want to word
        /// differently — and which nothing may ever round up to success.
        public var cameFromTheGuest: Bool {
            switch self {
            case .confirmed, .refused: return true
            case .neverLearned, .contradicted: return false
            }
        }
    }

    /// Where the press is in its life.
    public enum Phase: Equatable, Sendable {
        case pressed
        case waiting
        case settled(Outcome)
    }

    /// The ax2 ref of the control that was pressed — the identity the scene
    /// uses, so "is it still there?" is answerable without matching on
    /// geometry or on a title two controls may share.
    public let ref: String
    /// What to call it to a person.
    public let title: String
    /// Where it is, in the same content-relative coords the renderer draws
    /// controls in.
    public let frame: Rect

    public private(set) var phase: Phase = .pressed
    /// When `.waiting` began. Nil in every other phase, which is what makes
    /// "waiting without a clock" unrepresentable rather than merely
    /// discouraged.
    public private(set) var waitingSince: Date?

    public init(ref: String, title: String, frame: Rect) {
        self.ref = ref
        self.title = title
        self.frame = frame
    }

    // MARK: - Transitions

    /// The press has left for the guest. Starts the clock, and only now:
    /// timing the wait from the gesture would charge the machine for however
    /// long this side spent planning the act.
    public mutating func dispatch(at when: Date) {
        guard phase == .pressed else { return }
        phase = .waiting
        waitingSince = when
    }

    /// **The one door to `.confirmed`.** The only legitimate caller is an
    /// answer that came off the wire.
    public mutating func confirm() {
        guard !isSettled else { return }
        phase = .settled(.confirmed)
        waitingSince = nil
    }

    /// The guest answered no.
    public mutating func refuse(_ why: String) {
        guard !isSettled else { return }
        phase = .settled(.refused(why))
        waitingSince = nil
    }

    /// The machine's own scene no longer carries this control.
    ///
    /// Separate from `refuse` because it is not the guest declining the act —
    /// it is the guest showing us a world our drawing does not fit. A dialog
    /// that closed *because the press worked* arrives here too, which is why
    /// the words must not imply failure.
    public mutating func contradict(_ why: String) {
        guard !isSettled else { return }
        phase = .settled(.contradicted(why))
        waitingSince = nil
    }

    /// Let time pass. Returns true when this call is what settled it, so a
    /// caller can say the words once rather than on every frame.
    ///
    /// A pure function of the session and a clock — no timer, no dispatch
    /// queue — because the bounded end is the part most worth testing and a
    /// test that has to wait eight real seconds is a test nobody runs.
    @discardableResult
    public mutating func tick(now: Date) -> Bool {
        guard phase == .waiting, let since = waitingSince,
              now.timeIntervalSince(since) >= Self.patience else { return false }
        phase = .settled(.neverLearned)
        waitingSince = nil
        return true
    }

    // MARK: - What the view asks

    public var isSettled: Bool {
        if case .settled = phase { return true }
        return false
    }

    /// Whether the button is still drawn in its pressed state. True from the
    /// gesture until the verdict, and false the instant there is one — a
    /// button that stays down after the machine has answered is asserting a
    /// press that is over.
    public var showsPressed: Bool { !isSettled }

    /// Whether the spinner is drawn. `.waiting` only: before dispatch there
    /// is nothing to wait for yet, and the pressed drawing alone is the
    /// honest picture of "we have it, we have not sent it".
    public var showsSpinner: Bool { phase == .waiting }

    /// How far into the wait we are, 0...1, for a determinate indicator.
    ///
    /// **Deliberately determinate.** A barber's pole says "working" forever
    /// and can therefore never be wrong; a bar that fills toward a bound the
    /// code actually honours is a promise the code keeps. The person can see
    /// the answer coming due.
    public func waitProgress(now: Date) -> Double {
        guard let since = waitingSince else { return 0 }
        return Swift.min(1, Swift.max(0,
            now.timeIntervalSince(since) / Self.patience))
    }

    /// **The words, in one place.**
    ///
    /// Every outcome says something, including the two this side reached on
    /// its own — silence after a press is indistinguishable from a broken
    /// mirror, which is the same reason `ItemDragSession.Ending` carries a
    /// `why` rather than just snapping back.
    public var note: String? {
        guard case .settled(let outcome) = phase else { return nil }
        switch outcome {
        case .confirmed:
            return "\(title) — the guest took it"
        case .refused(let why):
            return "the guest would not press \(title): \(why)"
        case .neverLearned:
            return "asked \(title) and never learned the answer after "
                + "\(Int(Self.patience))s — it may still have happened"
        case .contradicted(let why):
            return "\(title) is no longer there: \(why)"
        }
    }
}
