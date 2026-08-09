import XCTest

/// **The seam between the drag gesture and the wire, checked as a pair.**
///
/// Written on 2026-08-07 after Michelle said "drag isnt working on my
/// build". It was not working, it never had, and *nothing was red*.
///
/// `MirrorSceneSource.itemDragDriver` is declared with a protocol default of
/// `nil` — the honest default for a driver that cannot hold the mouse button
/// down. `NOWMirrorSource`, the application's only conformer, never overrode
/// it. So the app compiled, conformed, passed every gate, and answered every
/// item drag with "this mirror cannot hold the mouse button down". A protocol
/// default that returns nil is a legal conformance, which is the same shape as
/// "every other gate can be green while neither guest compiles": **a seam with
/// a default is a seam nothing checks.**
///
/// So this checks the pair rather than either half. Two ends of a bridge and
/// no span is the state it exists to name — in whichever direction it next
/// appears:
///
/// - a conformer with no verbs would send `dragPress` into a lane that
///   cannot carry it, and the view would begin showing a drag on the
///   strength of it (rule 1: the ghost moves before the guest answers);
/// - verbs with no conformer is today, and today reads to a person as a
///   dead feature rather than as the refusal it is.
///
/// It reads source rather than exercising types on purpose: the thing that
/// went wrong is an *absence*, and an absence has no symbol to call.
final class ItemDragSeamTests: XCTestCase {

    /// The app's conformer, and the adapter that owns the act lane.
    private static let conformer =
        "now-host/Sources/Host/NOWMirrorSource.swift"
    private static let actControl =
        "now-host/Sources/Host/Automation/AgentIntegrationActControl.swift"

    func testTheDragSeamIsWholeOrIsWhollyAbsent() throws {
        let hasDriver = try read(Self.conformer)
            .contains("var itemDragDriver:")
        /* `dragpress` is the only one of the three that is an act request,
           so it is the one that has to appear in the act adapter. Looking
           for the verb string is looking for the thing that crosses the
           wire, rather than for a Swift name someone could rename. */
        let hasVerb = try read(Self.actControl).contains("\"dragpress\"")

        if hasDriver == hasVerb { return }

        if hasDriver {
            XCTFail("""
                \(Self.conformer) overrides `itemDragDriver`, but \
                \(Self.actControl) does not serve `dragpress`. The view \
                begins showing a drag BEFORE the guest answers — rule 1 of \
                the presentation contract — so a driver whose lane cannot \
                carry the press would put a moving ghost on screen over a \
                gesture the guest never received. That is exactly the \
                plausible wrong answer this arc exists to remove. Add the \
                verb beside `winact`/`ctlact`, or take the override back out.
                """)
        } else {
            XCTFail("""
                \(Self.actControl) serves `dragpress`, but \(Self.conformer) \
                still takes the `nil` default for `itemDragDriver` — so the \
                verb exists on the wire and no gesture can reach it. This is \
                the state Michelle hit on 2026-08-07, and it was silent \
                because a protocol default that returns nil is a legal \
                conformance. Add the conformer, or say in \
                docs/open-issues.md why the verb ships without one.
                """)
        }
    }

    /// The refusal a person actually meets today, pinned where it is read.
    ///
    /// Not decoration: "nothing happened" and "this mirror cannot hold the
    /// mouse button down" are the same event to the code and completely
    /// different events to a person, and the first is what this looked like
    /// for the four hours before anyone read the guard.
    func testTheAbsentDriverRefusesInWords() throws {
        let view = try read(
            "now-host/Packages/MirrorKit/Sources/MirrorKitUI/LiveMirror.swift")
        XCTAssertTrue(
            view.contains("cannot hold the mouse button"),
            "LiveMirror no longer says why an item drag was refused. A drag "
                + "that drops the gesture in silence is indistinguishable "
                + "from a broken mirror; if the refusal moved, move this "
                + "check with it.")
    }

    func testScrollbarThumbUsesTheResidentDragVehicle() throws {
        let source = try read(Self.conformer)
        XCTAssertTrue(source.contains("var scrollbarDragDriver:"),
                      "thumb dragging fell back to the input-device action "
                        + "NOW cannot serve")
        XCTAssertTrue(source.contains("residentDragPress(window:"))
        XCTAssertTrue(source.contains("residentDragMove(to:"))
        XCTAssertTrue(source.contains("residentDragRelease(answer:"))
        XCTAssertTrue(try read(Self.actControl).contains("\"dragpress\""))
    }

    // MARK: - Reading the source

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(path),
            encoding: .utf8)
    }
}
