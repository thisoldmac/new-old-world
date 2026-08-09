import XCTest
@testable import MirrorKit

/// **The three states of a press, and the bounded end of the middle one.**
///
/// Every test here has been watched to fail by mutation; the mutation is
/// named above the test it catches, because a guard nobody has seen refuse
/// is a guard nobody has tested.
final class PressSessionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session() -> PressSession {
        PressSession(ref: "w1.c3", title: "Set Time Zone",
                     frame: Rect(l: 100, t: 60, r: 180, b: 80))
    }

    // MARK: - 1. Pressed, not yet dispatched

    /// Rule 1, restated for a button: the mark is on the screen because the
    /// person did it, not because the machine agreed.
    ///
    /// Mutation: start `phase` at `.waiting`. The spinner then appears on a
    /// press that has not travelled, which claims we are waiting for a
    /// machine we have not yet spoken to.
    func testAFreshPressIsDrawnPressedAndIsNotYetWaiting() {
        let s = session()
        XCTAssertEqual(s.phase, .pressed)
        XCTAssertTrue(s.showsPressed,
                      "the press is the person's, and it shows immediately")
        XCTAssertFalse(s.showsSpinner,
                       "nothing has been asked yet — a spinner here would be "
                       + "waiting on a question never sent")
        XCTAssertNil(s.note, "an unsettled press has no verdict to report")
    }

    // MARK: - 2. Dispatched, not yet confirmed — the honest state

    func testDispatchStartsTheWaitAndTheSpinner() {
        var s = session()
        s.dispatch(at: t0)
        XCTAssertEqual(s.phase, .waiting)
        XCTAssertTrue(s.showsSpinner)
        XCTAssertTrue(s.showsPressed,
                      "a button being waited on is still a button held down")
        XCTAssertEqual(s.waitingSince, t0)
    }

    /// The clock starts when the act LEAVES, not when the finger lands.
    ///
    /// Mutation: set `waitingSince` in `init`. The deadline then charges the
    /// guest for however long this side spent resolving the object and
    /// planning the act, and a slow planner reads as a slow Macintosh.
    func testTheClockStartsAtDispatchAndNotAtThePress() {
        var s = session()
        XCTAssertNil(s.waitingSince)
        s.dispatch(at: t0.addingTimeInterval(2))
        XCTAssertEqual(s.waitingSince, t0.addingTimeInterval(2))
        XCTAssertFalse(s.tick(now: t0.addingTimeInterval(2 + 7)),
                       "seven seconds after dispatch is inside the bound, "
                       + "however long the press waited to be sent")
    }

    /// **The live fact this whole design is sized around.**
    ///
    /// Sweep C measured `ctlact part 0` presses on a live guest at about five
    /// seconds to dispatch — roughly 100× a `part 23`. Five seconds of
    /// nothing is precisely when a person concludes the product is broken,
    /// which is where the spinner earns its place; and a deadline at or below
    /// that measurement would fire on the ORDINARY case and report a working
    /// press as a mystery.
    ///
    /// Mutation: set `patience` to 5 (or 4). This test names the measurement
    /// that forbids it.
    func testPatienceOutlastsTheMeasuredWorstCasePress() {
        let measuredCtlActPart0: TimeInterval = 5
        XCTAssertGreaterThan(
            PressSession.patience, measuredCtlActPart0,
            "a `ctlact part 0` press was measured at ~5s on a live guest "
            + "(Sweep C, 2026-08-07); a deadline inside that turns the "
            + "ordinary slow case into a false `neverLearned`")

        var s = session()
        s.dispatch(at: t0)
        XCTAssertFalse(s.tick(now: t0.addingTimeInterval(measuredCtlActPart0)),
                       "the measured worst case must still be inside the wait")
        s.confirm()
        XCTAssertEqual(s.phase, .settled(.confirmed))
    }

    // MARK: - 3. Settled — and the bound that guarantees it

    /// **The spinner has a bounded end, and the end is a sentence.**
    ///
    /// This is the test the whole file exists for. Mutation: delete the
    /// deadline arm from `tick` (`return false` always). The press then
    /// spins forever — a silent success wearing a progress indicator, which
    /// is the defect class in its most sympathetic disguise.
    func testAPressThatNeverSettlesIsNamedRatherThanSpinningForever() {
        var s = session()
        s.dispatch(at: t0)

        // A long way past any answer the guest could still be composing.
        XCTAssertTrue(s.tick(now: t0.addingTimeInterval(PressSession.patience)),
                      "the wait must END on its own — nothing else in the "
                      + "system will stop this spinner")
        XCTAssertEqual(s.phase, .settled(.neverLearned))
        XCTAssertFalse(s.showsSpinner, "the spinner stops")
        XCTAssertFalse(s.showsPressed, "and the button comes back up")
    }

    /// **Reverting without a word would be the lie.**
    ///
    /// A press that quietly un-presses tells the person it never registered.
    /// It did. The words must say we asked and never found out, and must not
    /// say the act failed — it may well have landed.
    ///
    /// Mutation: return nil from `note` for `.neverLearned`, or word it as
    /// "failed". Either one converts an honest unknown into a confident
    /// wrong answer.
    func testTheDeadlineSaysWeAskedAndNeverLearnedRatherThanNothingHappened() {
        var s = session()
        s.dispatch(at: t0)
        s.tick(now: t0.addingTimeInterval(PressSession.patience))
        let note = try? XCTUnwrap(s.note)
        let words = note ?? ""
        XCTAssertTrue(words.contains("never learned"), words)
        XCTAssertTrue(words.contains("may still have happened"),
                      "the act is not known to have failed, and saying so is "
                      + "the difference between an unknown and a false "
                      + "negative — got: \(words)")
        XCTAssertFalse(PressSession.Outcome.neverLearned.cameFromTheGuest,
                       "this verdict is ours, not the machine's")
    }

    /// Every settled state carries words. Silence after a press is
    /// indistinguishable from a broken mirror.
    ///
    /// Mutation: drop any one case from `note`'s switch — it stops compiling,
    /// which is the point of switching exhaustively over the outcome rather
    /// than defaulting.
    func testEveryOutcomeIsLegible() {
        let outcomes: [PressSession.Outcome] = [
            .confirmed, .refused("not actionable"), .neverLearned,
            .contradicted("the dialog closed"),
        ]
        for outcome in outcomes {
            var s = session()
            switch outcome {
            case .confirmed: s.confirm()
            case .refused(let w): s.refuse(w)
            case .neverLearned:
                s.dispatch(at: t0)
                s.tick(now: t0.addingTimeInterval(PressSession.patience))
            case .contradicted(let w): s.contradict(w)
            }
            XCTAssertEqual(s.phase, .settled(outcome))
            let words = s.note ?? ""
            XCTAssertFalse(words.isEmpty,
                           "\(outcome) settled without saying anything")
            XCTAssertTrue(words.contains("Set Time Zone"),
                          "a verdict that does not name the button is not "
                          + "legible on a screen with several — got: \(words)")
        }
    }

    // MARK: - Nothing promotes itself

    /// **The load-bearing rule, inherited from the provisional drag.**
    ///
    /// `SceneRenderer` already carries it in a comment: "Nothing PROMOTES a
    /// provisional drag to this on its own." A press is the same decision.
    /// Every exit this side can reach unaided is a WORSE verdict than
    /// confirmed; the better one requires the machine.
    ///
    /// Mutation: settle `tick`'s deadline as `.confirmed` instead of
    /// `.neverLearned` — a press nobody answered would then report success,
    /// which is the exact shape of the AppleScript lie this arc replaced.
    func testOnlyTheGuestCanConfirmAPress() {
        var timedOut = session()
        timedOut.dispatch(at: t0)
        timedOut.tick(now: t0.addingTimeInterval(600))
        XCTAssertNotEqual(timedOut.phase, .settled(.confirmed))

        var gone = session()
        gone.dispatch(at: t0)
        gone.contradict("the window closed")
        XCTAssertNotEqual(gone.phase, .settled(.confirmed))

        var refused = session()
        refused.refuse("not actionable")
        XCTAssertNotEqual(refused.phase, .settled(.confirmed))

        /* And the door that does work needs no dispatch, because a driver
           may answer before this side has finished the frame it dispatched
           on. */
        var confirmed = session()
        confirmed.confirm()
        XCTAssertEqual(confirmed.phase, .settled(.confirmed))
    }

    /// A verdict is final. A second answer does not reopen the drawing.
    ///
    /// Mutation: drop the `guard !isSettled` from `confirm()`. An answer
    /// arriving after the deadline then re-presses a button the person has
    /// already watched come back up — a ghost, and one that appears seconds
    /// after the gesture with nothing on screen to explain it.
    ///
    /// Note this is a statement about the DRAWING only. Whether a late
    /// confirmation is worth recording is `MirrorOperationOutcome`'s
    /// question, and it has `confirmedAfterTimeout` for exactly that; the
    /// accounting lane keeps the fact, the render does not resurrect.
    func testALateAnswerDoesNotReopenASettledPress() {
        var s = session()
        s.dispatch(at: t0)
        s.tick(now: t0.addingTimeInterval(PressSession.patience))
        XCTAssertEqual(s.phase, .settled(.neverLearned))

        s.confirm()
        XCTAssertEqual(s.phase, .settled(.neverLearned),
                       "the button is already back up; re-pressing it now "
                       + "would be a ghost with nothing on screen to explain "
                       + "it")
        XCTAssertFalse(s.showsPressed)
    }

    /// Dispatch is once. A second one must not restart the clock.
    ///
    /// Mutation: remove the `guard phase == .pressed` from `dispatch`. A view
    /// that calls it on every frame then holds `waitingSince` at now forever
    /// and the deadline never arrives — the spinner-that-never-stops, reached
    /// by a different road than deleting the deadline.
    func testDispatchingTwiceDoesNotRefreshTheDeadline() {
        var s = session()
        s.dispatch(at: t0)
        s.dispatch(at: t0.addingTimeInterval(7))
        XCTAssertEqual(s.waitingSince, t0,
                       "the clock belongs to the first dispatch")
        XCTAssertTrue(s.tick(now: t0.addingTimeInterval(PressSession.patience)))
    }

    // MARK: - The machine is right, even when the render looks better

    /// The standing rule turned on our own optimism.
    ///
    /// Mutation: make `contradict` a no-op. The pressed highlight then hovers
    /// where the guest says there is no longer a button — the mirror showing
    /// something the Mac is not showing, which is the one thing a mirror must
    /// never do.
    func testTheDrawingYieldsWhenTheSceneNoLongerCarriesTheControl() {
        var s = session()
        s.dispatch(at: t0)
        XCTAssertTrue(s.showsPressed)

        s.contradict("the dialog closed")
        XCTAssertFalse(s.showsPressed,
                       "our render loses to the machine's own report")
        XCTAssertFalse(s.showsSpinner)
    }

    /// A contradiction is not a refusal, and the words must not imply one.
    ///
    /// The commonest way for a control to vanish is that the press WORKED and
    /// the dialog dismissed itself. Wording that as failure would report the
    /// success case as an error.
    ///
    /// Mutation: word `.contradicted` as "the guest would not press …" — i.e.
    /// merge it into `.refused`. The happy path then reads as a fault.
    func testAVanishedControlIsNotReportedAsARefusal() {
        var s = session()
        s.contradict("the dialog closed")
        let words = s.note ?? ""
        XCTAssertTrue(words.contains("no longer there"), words)
        XCTAssertFalse(words.contains("would not"),
                       "a control that vanished BECAUSE the press worked "
                       + "must not be reported as the guest declining — "
                       + "got: \(words)")
    }

    // MARK: - The indicator is a promise the code keeps

    /// A determinate indicator must actually reach its end at the deadline it
    /// draws toward, or it is a barber's pole with extra steps.
    ///
    /// Mutation: divide by a hard-coded 30 in `waitProgress` instead of by
    /// `patience`. The bar then crawls to a quarter and the press settles
    /// with the indicator visibly unfinished, which reads as an abort.
    func testTheIndicatorReachesItsEndExactlyWhenTheWaitDoes() {
        var s = session()
        s.dispatch(at: t0)
        XCTAssertEqual(s.waitProgress(now: t0), 0, accuracy: 0.001)
        XCTAssertEqual(
            s.waitProgress(now: t0.addingTimeInterval(PressSession.patience / 2)),
            0.5, accuracy: 0.001)
        XCTAssertEqual(
            s.waitProgress(now: t0.addingTimeInterval(PressSession.patience)),
            1, accuracy: 0.001,
            "full exactly when `tick` settles it, or the indicator is "
            + "drawing toward a deadline the code does not honour")
        XCTAssertTrue(s.tick(now: t0.addingTimeInterval(PressSession.patience)))
    }
}
