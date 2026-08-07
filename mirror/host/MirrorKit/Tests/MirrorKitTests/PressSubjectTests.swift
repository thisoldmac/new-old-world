import XCTest
@testable import MirrorKit

/// **What may be shown pressed — and the refusals, which are the point.**
///
/// The sibling of `DragTargeting`'s refusal tests. A press mark is a claim
/// that a specific object took the click and is being waited on; where any
/// part of that is unknown, the honest answer is no mark at all and the
/// status line doing the talking.
final class PressSubjectTests: XCTestCase {

    private func window() -> MirrorObject.Window {
        .init(id: "w1", ref: "w.ref", psn: "0:1", title: "Fixture",
              rect: Rect(l: 0, t: 0, r: 300, b: 200), kind: nil,
              isFront: true, part: .content)
    }

    private func control(ref: String = "c.ok", title: String = "OK",
                         rect: Rect? = Rect(l: 10, t: 10, r: 90, b: 30),
                         enabled: Bool = true,
                         part: Scrollbar.Part? = nil) -> MirrorObject {
        .control(.init(ref: ref, role: "button", title: title, rect: rect,
                       value: nil, min: nil, max: nil, isEnabled: enabled,
                       window: window(), part: part))
    }

    private func dialogItem(ref: String? = "d.1", title: String = "OK",
                            kind: String? = "pushButton",
                            enabled: Bool = true) -> MirrorObject {
        .dialogItem(.init(number: 1, ref: ref, title: title,
                          rect: Rect(l: 10, t: 10, r: 90, b: 30),
                          isEnabled: enabled, window: window(),
                          semanticKind: kind, semanticAction: "press",
                          isSemanticallyActionable: true))
    }

    // MARK: - The happy path

    func testAnEnabledButtonWithARefAndARectCanBeShownPressed() throws {
        let s = try XCTUnwrap(PressSubject(control()))
        XCTAssertEqual(s.ref, "c.ok")
        XCTAssertEqual(s.title, "OK")
        XCTAssertEqual(s.frame, Rect(l: 10, t: 10, r: 90, b: 30))
    }

    func testADialogPushButtonCanBeShownPressed() throws {
        let s = try XCTUnwrap(PressSubject(dialogItem()))
        XCTAssertEqual(s.ref, "d.1")
    }

    // MARK: - The refusals

    /// The renderer matches the pressed control by `ref`. An object the guest
    /// never named cannot be the one that lights up.
    ///
    /// Mutation: fall back to the title when `ref` is nil. Two sheets each
    /// carrying an OK then light each other's buttons.
    func testADialogItemWithNoRefIsNotMarked() {
        XCTAssertNil(PressSubject(dialogItem(ref: nil)))
    }

    /// `Scene.Control.rect` is genuinely optional — "nil when the wire had
    /// none". A press drawn at a guessed rectangle marks whatever is there.
    ///
    /// Mutation: substitute the window's rect when the control has none. The
    /// mark then covers the whole window on exactly the controls this side
    /// knows least about.
    func testAControlWithNoRectIsNotMarked() {
        XCTAssertNil(PressSubject(control(rect: nil)))
    }

    func testAnEmptyRectIsNotMarked() {
        XCTAssertNil(PressSubject(control(rect: Rect(l: 5, t: 5, r: 5, b: 5))))
    }

    /// A disabled control will not be acted on, so showing it pressed
    /// promises something that is not going to happen — the same reason
    /// `drawButton` declines to ring a disabled default item.
    ///
    /// Mutation: drop the `isEnabled` guard. A greyed button then presses
    /// convincingly and waits out the full deadline to report that it never
    /// learned anything, which is a worse answer than the immediate silence
    /// it replaced.
    func testADisabledControlIsNotMarked() {
        XCTAssertNil(PressSubject(control(enabled: false)))
        XCTAssertNil(PressSubject(dialogItem(enabled: false)))
    }

    /// A scroll bar's press is a tracking gesture with its own live feedback
    /// from the guest, not a discrete press with a verdict — and marking the
    /// whole bar would mark the wrong extent anyway.
    ///
    /// Mutation: drop the `part == nil` guard. Dragging a thumb then paints
    /// a wait bar across the entire scroll bar for eight seconds.
    func testAScrollbarPartIsNotMarked() {
        XCTAssertNil(PressSubject(control(part: .thumb)))
        XCTAssertNil(PressSubject(control(part: .lineUp)))
    }

    /// Static text and icons are drawn, not pressed. Where the guest supplied
    /// no kind, this declines rather than guessing: 62% of elements carry no
    /// determined kind, and a press mark on a label is the
    /// cursor-over-everything mistake in another costume.
    ///
    /// Mutation: treat a nil `semanticKind` as pressable. Every caption in
    /// every dialog then reports itself as a button under the finger.
    func testUnprovenDialogItemsAreNotMarked() {
        XCTAssertNil(PressSubject(dialogItem(kind: "staticText")))
        XCTAssertNil(PressSubject(dialogItem(kind: "icon")))
        XCTAssertNil(PressSubject(dialogItem(kind: nil)))
    }

    /// Not everything clickable is a thing that stays put and then changes.
    ///
    /// Mutation: return a subject for `.window` using its rect. A click on a
    /// title bar then presses the entire window.
    func testTheDesktopWindowsAndMenusAreNotMarked() {
        XCTAssertNil(PressSubject(.desktop(nil)))
        XCTAssertNil(PressSubject(.window(window())))
        XCTAssertNil(PressSubject(.menu(.init(id: 1, title: "File", left: 0,
                                              isApple: false))))
    }

    /// A control with no title still gets a mark — it has a ref and a rect,
    /// which is what the claim needs — but the words must not be empty, or
    /// the status line reads "the guest would not press : …".
    func testAnUntitledControlStillGetsReadableWords() throws {
        let s = try XCTUnwrap(PressSubject(control(title: "")))
        XCTAssertFalse(s.title.isEmpty,
                       "a verdict has to name something a person can read")
    }
}
