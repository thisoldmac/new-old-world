import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// **The pointer is a claim, and it had no test.**
///
/// `LiveMirror.cursor(for:)` shipped with no coverage at all. What it
/// decides is small and the reason it is small is the whole argument:
/// the arrow is the honest default because 62% of elements carry no
/// determined kind, so a cursor shaped from a guess would be the
/// confident wrong answer plan 018 is about everywhere else. There is
/// exactly one exception — an I-beam over a dialog item the GUEST says
/// is editable text (Michelle, 2026-08-07: "use the normal pointer
/// everywhere and just focus on getting the text cursor over editable
/// text areas").
///
/// Two things are pinned here, and the second is the one its own comment
/// predicts will break: that the exception is the only exception, and
/// that the cursor reads the SAME evidence the renderer and the hit
/// tester read rather than traversing the scene a second time. A second
/// traversal is not wrong on the day it is written; it is wrong the day
/// after, when one of the two is fixed.
@MainActor
final class LiveMirrorCursorTests: XCTestCase {

    /// `cursor(for:)` is a static member of the generic
    /// `LiveMirrorView<Source>` and does not use `Source` for anything —
    /// so asking it a question means naming a driver that has nothing to
    /// do with the answer. That is a wart, and it is very likely why
    /// this function reached production with no test: the cheapest way
    /// to call it was to run the app. It is left alone here on purpose —
    /// pinning behaviour and reshaping an API are different commits —
    /// and this stub is the whole cost of working around it.
    private final class StubSource: MirrorSceneSource {
        var scene: MirrorKit.Scene?
        var status = ""
        func perform(_ actions: [MirrorAction], label: String) {}
        func note(_ message: String) {}
    }
    private typealias View = LiveMirrorView<StubSource>

    /// **`NSCursor.arrow` segfaults in a bare `xctest` process.** Not a
    /// failure and not a slow path — a SIGSEGV before the first
    /// assertion, because AppKit's shared cursors want an
    /// `NSApplication` and there is none under the command-line runner.
    /// Touching `NSApplication.shared` makes one. Worth naming rather
    /// than pattern-matching: it is a plausible reason a pointer test
    /// was never written, and the next person to reach for one will hit
    /// exactly this in exactly this way.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }

    // MARK: - Fixtures

    private func window(_ name: String = "Note") -> MirrorObject.Window {
        MirrorObject.Window(
            id: "\(name)#0", ref: "0x1000", psn: "1.2",
            title: name, rect: Rect(l: 0, t: 0, r: 300, b: 200),
            kind: 2, isFront: true, part: .content)
    }

    private func item(kind: String?) -> MirrorObject {
        .dialogItem(MirrorObject.DialogItem(
            number: 1, ref: "0x2000", title: "",
            rect: Rect(l: 10, t: 10, r: 200, b: 30),
            isEnabled: true, window: window(), semanticKind: kind,
            semanticAction: nil, isSemanticallyActionable: true))
    }

    private func control(kind: String?) -> MirrorObject {
        .control(MirrorObject.Control(
            ref: "0x3000", role: "button", title: "OK",
            rect: Rect(l: 0, t: 0, r: 60, b: 20), value: nil, min: nil,
            max: nil, isEnabled: true, window: window(), part: nil))
    }

    // MARK: - The one exception

    func testEditableTextIsTheOnlyThingThatGetsAnIBeam() {
        XCTAssertEqual(View.cursor(for: item(kind: "editText")),
                       NSCursor.iBeam)
    }

    /// Every other dialog item — including the ones a person might argue
    /// LOOK editable, and including the ones whose kind was never
    /// established — gets the arrow. `nil` is the case that matters:
    /// most items on this guest carry no kind, and shaping the pointer
    /// from that absence would be inventing evidence.
    func testEveryOtherDialogItemKeepsTheArrow() {
        for kind in ["staticText", "button", "checkBox", "radioButton",
                     "popupButton", "icon", "userItem", "editable",
                     "EditText", "", nil] {
            XCTAssertEqual(View.cursor(for: item(kind: kind)),
                           NSCursor.arrow,
                           "semanticKind \(kind.map { "\"\($0)\"" } ?? "nil")")
        }
    }

    /// The match is exact, not a prefix or a fuzzy one. `editTextArea`
    /// is not a kind this guest emits, and accepting it would be the
    /// cursor deciding what the guest meant.
    func testTheKindMatchIsExactRatherThanAPrefix() {
        XCTAssertEqual(View.cursor(for: item(kind: "editTextArea")),
                       NSCursor.arrow)
    }

    /// Windows, controls, menus and the desktop all keep the arrow.
    /// Window PARTS especially: a grow box and a title bar do something
    /// different from a click on content, and an earlier draft of this
    /// function shaped the pointer for each. That was removed
    /// deliberately, and a test that only checked the I-beam would let
    /// it come back unnoticed.
    func testNothingButADialogItemEverChangesThePointer() {
        var grow = window(); grow.part = .growBox
        var title = window(); title.part = .titleBar
        let menu = MirrorObject.Menu(id: 2, title: "File", left: 40,
                                     isApple: false)
        let app = MirrorObject.App(psn: "1.1", name: "Finder",
                                   isFront: true)
        let objects: [MirrorObject] = [
            .window(window()), .window(grow), .window(title),
            control(kind: nil),
            .menu(menu),
            .menuItem(MirrorObject.MenuItem(
                menu: menu, index: 1, title: "New", cmd: "N",
                isEnabled: true, isSeparator: false)),
            .app(app),
            .desktop(app),
            .desktop(nil),
            .finderItem(MirrorObject.FinderItem(
                name: "Macintosh HD", container: nil,
                point: Point(x: 10, y: 10))),
        ]
        for object in objects {
            XCTAssertEqual(View.cursor(for: object), NSCursor.arrow,
                           "\(object)")
        }
    }

    /// **The exception is scoped to Dialog Manager items, and the type
    /// system is why.** `MirrorObject.Control` carries no `semanticKind`
    /// at all — only a role and an action — so a control cannot claim to
    /// be editable text on this side even if the guest thought so.
    /// Widening the I-beam past dialog items therefore means widening
    /// the OBJECT first, which is a contract decision rather than a
    /// one-line cursor change. This is here so that someone reaching for
    /// the one-line change discovers that.
    func testAControlCannotEvenClaimToBeEditableText() {
        XCTAssertEqual(View.cursor(for: control(kind: "editText")),
                       NSCursor.arrow)
    }

    // MARK: - The reuse its own comment predicts will break

    /// **The hover resolves through `ObjectResolver`, which resolves
    /// through `HitTester`.** That chain is the claim: z-order across
    /// windows, the title-bar strip a dialog does not have, controls in
    /// content-relative space — all measured once and consulted here,
    /// never re-derived. If a second traversal appears in the hover
    /// path, the pointer will start disagreeing with the click under it
    /// on exactly the geometry that was hardest to get right.
    func testTheHoverPathResolvesThroughTheHitTesterAndNotBesideIt()
        throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let live = try String(
            contentsOf: sources.appendingPathComponent(
                "MirrorKitUI/LiveMirror.swift"), encoding: .utf8)
        // The hover closure only, not the rest of the view: the gesture
        // code below it hit-tests for its own reasons and is allowed to.
        let hover = try XCTUnwrap(
            live.range(of: "onContinuousHover")).lowerBound
        let end = try XCTUnwrap(
            live.range(of: "guard let idx = openMenu")).lowerBound
        let body = String(live[hover..<end])

        XCTAssertTrue(body.contains("ObjectResolver.object("),
                      "the hover must ask the resolver what is under the "
                      + "pointer")
        XCTAssertFalse(body.contains("HitTester.hitTest"),
                       "the hover must not hit-test on its own account; "
                       + "ObjectResolver already does, and two callers of "
                       + "the same geometry become two versions of it")
        for reimplementation in ["for window in scene.windows",
                                 "scene.windows.first(where:",
                                 "scene.windows.reversed()"] {
            XCTAssertFalse(body.contains(reimplementation),
                           "the hover walks the scene itself: "
                           + "\(reimplementation)")
        }

        let resolver = try String(
            contentsOf: sources.appendingPathComponent(
                "MirrorKit/ObjectResolver.swift"), encoding: .utf8)
        XCTAssertTrue(resolver.contains("HitTester.hitTest("),
                      "the resolver is only a reuse of the hit tester "
                      + "while it actually calls it")
    }

    /// The pointer and the act must name the same object, which they do
    /// by both being handed the resolver's answer for the same point.
    /// Asserted over a real scene rather than over the source, because
    /// this is the half a source check cannot see.
    func testThePointerAndTheActAgreeOnWhatIsUnderThePoint() throws {
        var w = Scene.Window(
            id: "Note#0", app: "Note", psn: "1.2", title: "Note", kind: 2,
            rect: Rect(l: 100, t: 100, r: 400, b: 300), front: true, z: 0,
            visible: true, controls: [], text: nil, items: nil,
            display: nil)
        w.ref = "0x1000"
        w.dialogItems = [Scene.DialogItem(
            number: 1, title: "",
            rect: Rect(l: 20, t: 40, r: 200, b: 60), enabled: true,
            visible: true, ref: "0x2000",
            semantic: Scene.Semantics(knowledge: .known,
                                      kind: "editText"))]
        let scene = Scene(
            version: 2, seq: 1, source: "mock", capturedAt: 0,
            screen: .init(w: 800, h: 600), apps: [], processes: nil,
            menubar: nil, windows: [w], desktopItems: nil,
            meta: .init(errors: []))

        // A point inside the item, in the same global coords the hover
        // converts to before asking. A DITL rect is content-relative, so
        // the title bar is added the way `HitTester` adds it — asking
        // the constant rather than writing a number, because that offset
        // is exactly the kind of geometry a second traversal gets wrong.
        let inside = Point(x: 100 + 30, y: 100 + HitTester.titlebar + 50)
        let object = try XCTUnwrap(
            ObjectResolver.object(at: inside, in: scene))
        XCTAssertEqual(View.cursor(for: object), NSCursor.iBeam,
                       "the resolver found \(object)")
    }
}
