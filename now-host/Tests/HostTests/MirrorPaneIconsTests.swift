import CoreGraphics
import Foundation
import XCTest
@testable import Host
import MirrorKit

/// **A desktop icon and a window, pressed in the pane.**
///
/// The sibling of `MirrorGesturePathTests`, which owns the mapping and the
/// control refusals. This one owns the two things the audit asked for: an
/// icon that can be clicked at all, and a window whose boxes and edges do
/// something.
///
/// Every assertion here is about a HOST decision — which icon a point picks
/// out, what leaves as an act, what a person is told when nothing can. **None
/// of it has run against a Macintosh**; there is no emulator and no hardware
/// on this bench. What a real Finder does with `select item "X" of desktop`
/// is measured upstream (`docs/FOLDER-ITEMS.md`, 40/40) and is not re-claimed
/// here.
@MainActor
final class MirrorPaneIconsTests: XCTestCase {

    /// A 640×480 guest: two desktop icons, one of them invisible, one
    /// unplaced, and a document window sitting over a third.
    ///
    /// Written as the document a guest sends, for the reason
    /// `MirrorGesturePathTests` writes its fixture that way: the adapter is
    /// part of the path being tested, and a scene built in memory can carry
    /// values no producer emits.
    private static let document = Data("""
        {"version":1,"seq":7,"capturedAt":1750000000.0,"source":"peek",\
        "screen":{"w":640,"h":480},\
        "apps":[{"psn":"0.8192","name":"SimpleText","front":true}],\
        "windows":[{"id":"w1","app":"SimpleText","psn":"0.8192",\
        "title":"Untitled","kind":20,\
        "rect":{"l":100,"t":100,"r":400,"b":300},"front":true,"z":0,\
        "visible":true,"controls":[]}],\
        "desktopItems":[\
        {"name":"HelloWorld","kind":"file","x":600,"y":40,"placed":true,\
        "alias":false,"invisible":false},\
        {"name":"Ghost","kind":"file","x":600,"y":100,"placed":true,\
        "alias":false,"invisible":true},\
        {"name":"Unplaced","kind":"file","x":600,"y":160,"placed":false,\
        "alias":false,"invisible":false},\
        {"name":"Buried","kind":"folder","x":150,"y":150,"placed":true,\
        "alias":false,"invisible":false}],\
        "meta":{"plane":"peek anchors"}}
        """.utf8)

    private func model(actions: MirrorActionDriver? = nil)
        -> MirrorModuleModel {
        let model = MirrorModuleModel(actions: actions, watch: .manual)
        model.connection = .connected(named: "PowerBook 1400")
        model.show(document: Self.document, irVersion: 1,
                   provenance: .fixture(name: "test.json"))
        return model
    }

    // MARK: - which icon, and whether there is one

    /// **The click goes to the icon, not to the pointer.** A press anywhere
    /// in the icon's box — including its label strip, which is how the Finder
    /// behaves — resolves to that icon by NAME, and the name is what leaves.
    func testAPressAnywhereOnTheIconResolvesItByName() throws {
        let scene = try XCTUnwrap(model().scene)
        // Top-left corner of the box, the middle of it, and the label strip
        // underneath (the icon is 32 px, the label 12 more).
        for point in [(600, 40), (616, 56), (610, 76)] {
            let hit = HitTester.hitTest(scene, x: point.0, y: point.1)
            guard case .desktopItem(let name, let x, let y) = hit else {
                return XCTFail("expected the icon at \(point), got \(hit)")
            }
            XCTAssertEqual(name, "HelloWorld")
            /* The icon's OWN centre, whatever was pressed. It is not sent —
               the act names the item — but it is what makes a press near the
               edge of one icon mean that icon rather than its neighbour. */
            XCTAssertEqual(x, 616)
            XCTAssertEqual(y, 56)
        }
    }

    /// **Unplaced and invisible are not targets, and no point is invented for
    /// them.** An item the Finder has not laid out has coordinates that mean
    /// nothing; an invisible one is not on the screen the person is looking
    /// at. Both fall through to the desktop.
    func testUnplacedAndInvisibleItemsAreNotTargets() throws {
        let scene = try XCTUnwrap(model().scene)
        for point in [(616, 116), (616, 176)] {
            guard case .desktop = HitTester.hitTest(scene, x: point.0,
                                                    y: point.1) else {
                return XCTFail("""
                    an item that is not on the screen was treated as clickable \
                    at \(point). A click computed for it lands on whatever IS \
                    at those coordinates.
                    """)
            }
        }
    }

    /// **A window over an icon wins the point.** The icons are drawn on the
    /// backdrop and tested last, so a folder under a document window is not
    /// reachable through it — which is what the person can see.
    func testAWindowOverAnIconTakesThePoint() throws {
        let scene = try XCTUnwrap(model().scene)
        guard case .content = HitTester.hitTest(scene, x: 166, y: 166) else {
            return XCTFail("the icon was clicked through a window over it")
        }
    }

    // MARK: - what a press on one becomes

    /// Single click selects, double click opens — **both by identity**, and
    /// the refusal names both halves of what is missing rather than falling
    /// back to a coordinate NOW deliberately does not have.
    func testAnIconIsSelectedAndOpenedByNameAndSaysWhatIsMissing() {
        let model = model()
        model.click(x: 616, y: 56)

        XCTAssertEqual(model.lastAction?.target, "\"HelloWorld\"")
        XCTAssertEqual(model.lastAction?.outcome, .unavailable,
                       "a page with no act lane must not report a dispatch")
        let sentence = model.lastAction?.sentence ?? ""
        XCTAssertTrue(sentence.contains("act lane"), sentence)

        /* And the vocabulary underneath is the identity one, single and
           double. Asserted here rather than only in MirrorKit because the
           audit's row is about the PANE: the pane's own count has to reach
           the model, or a double-click selects twice. */
        let scene = model.scene!
        let hit = HitTester.hitTest(scene, x: 616, y: 56)
        XCTAssertEqual(ActionModel.click(on: hit, in: scene, count: 1),
                       [.finderSelect(item: "HelloWorld",
                                      container: .desktop)])
        XCTAssertEqual(ActionModel.click(on: hit, in: scene, count: 2),
                       [.finderOpen(item: "HelloWorld", container: .desktop)])
    }

    /// **The mirror draws the selection it made**, because the guest's own
    /// selection lives only in the Finder's pixels and is reported nowhere.
    /// A click on the bare desktop clears it, as it does on the Mac; a click
    /// on a window leaves it alone, as that does too.
    func testTheMirrorRemembersWhatItSelectedAndWhatClearsIt() {
        let model = model()
        model.click(x: 616, y: 56)
        XCTAssertEqual(model.selectedItem, "HelloWorld")

        model.click(x: 200, y: 200)          // inside the document window
        XCTAssertEqual(model.selectedItem, "HelloWorld",
                       "a click in a window is not a Finder deselection")

        model.click(x: 500, y: 400)          // bare desktop
        XCTAssertNil(model.selectedItem)
    }

    // MARK: - the window

    /// A drag on the title bar becomes a MOVE, and the geometry is the
    /// window's new content origin — not a pixel path, which is what a NOW
    /// connection cannot carry.
    func testATitleBarDragBecomesAMoveWithTheNewContentOrigin() throws {
        let scene = try XCTUnwrap(model().scene)
        let win = scene.windows[0]
        let actions = ActionModel.windowMove(win, in: scene,
                                             by: (dx: 30, dy: -10))
        /* The rect is the content port grown UP by the title bar, so the
           content origin before the drag is (100, 100 + titleBarHeight). */
        let top = 100 + WindowChrome.titlebarHeight - 10
        XCTAssertEqual(actions, [.windowAct(
            window: ActionModel.target(for: win, in: scene)!,
            op: .move(left: 130, top: top))])
    }

    /// …and a grow-box drag becomes a RESIZE, in content size.
    func testAGrowBoxDragBecomesAResizeInContentSize() throws {
        let scene = try XCTUnwrap(model().scene)
        let win = scene.windows[0]
        let actions = ActionModel.windowResize(win, in: scene,
                                               by: (dx: 40, dy: 20))
        let height = 300 - (100 + WindowChrome.titlebarHeight) + 20
        XCTAssertEqual(actions, [.windowAct(
            window: ActionModel.target(for: win, in: scene)!,
            op: .resize(width: 340, height: height))])
    }

    /// A drag that began on nothing draggable is REPORTED, not swallowed.
    /// Dragging an icon is the ordinary way to arrive here, and NOW has no
    /// verb that moves one — the person has to be told that.
    func testADragThatCannotBeCarriedSaysSoRatherThanNothing() {
        let model = model()
        model.drag(from: (x: 616, y: 56), to: (x: 300, y: 300))
        XCTAssertEqual(model.lastAction?.outcome, .inert)
        XCTAssertTrue((model.lastAction?.sentence ?? "").contains("WINDOW"),
                      model.lastAction?.sentence ?? "")
    }

    /// The window's identity is counted the way the guest counts it: among
    /// the same-titled windows of the same process, in chain order.
    func testTheOccurrenceIsCountedOverSameTitledWindowsOfOneProcess() throws {
        var scene = try XCTUnwrap(model().scene)
        var second = scene.windows[0]
        second.id = "w2"
        second.z = 1
        var other = scene.windows[0]
        other.id = "w3"
        other.z = 2
        other.psn = "0.9999"                 // another program, same title
        scene.windows = [scene.windows[0], second, other]

        XCTAssertEqual(ActionModel.target(for: scene.windows[0],
                                          in: scene)?.occurrence, 0)
        XCTAssertEqual(ActionModel.target(for: second, in: scene)?.occurrence,
                       1)
        XCTAssertEqual(ActionModel.target(for: other, in: scene)?.occurrence,
                       0, "another program's window is not in this count")
    }

    /// A window act with no observation behind it refuses, and names the
    /// missing half: the walk that mints the reference, not the act lane.
    func testAWindowActWithNoObservationLaneNamesTheMissingHalf() async {
        let driver = MirrorActionDriver(
            adapter: AgentIntegrationHostAdapter(
                listener: GuestListener(
                    identity: .init(version: "0.1-test",
                                    name: "Test Host"))),
            windows: nil)
        let outcome = await driver.drive(.windowAct(
            window: .init(id: "w1", psn: "0.8192", title: "Untitled",
                          occurrence: 0),
            op: .close))
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("a window act with nothing to address it "
                               + "produced \(outcome)")
        }
        XCTAssertTrue(reason.contains("observation"), reason)
    }
}
