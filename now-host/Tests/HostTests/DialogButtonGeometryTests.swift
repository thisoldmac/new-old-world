import XCTest
import AppKit
import MirrorKit
import MirrorKitUI

/// **A dialog button a person can see must be a dialog button a person can
/// press.**
///
/// ## The defect these pin
///
/// Michelle, driving the round-6 stack on 2026-08-07: *"the button labels
/// are now correct, but the buttons still dont work and the modal is
/// otherwise blank"*. The status line read *"click a control: the guest did
/// not provide complete, authoritative semantics for that control"*, and the
/// modal was Mail's Internet-setup alert — **Yes / No / Set Up Now** — which
/// she could not dismiss, on a VM she had been handed headless.
///
/// The refusal named the CDEF work, and the CDEF work was not the cause.
/// `scene-mail-internet-alert.json` is that alert captured from a live
/// emulated G4 (guest build `e715b0a6a5d7`, lane block 230) at the same
/// moment as a QMP screendump, and the guest is right about all of it: its
/// six DITL items name 1 / 2 / 3 as enabled `pushButton`s, `knowledge:
/// known`, `action: press`, each with a reference. `Semantics.
/// authorizesAction` is true for every one. Nothing needed widening.
///
/// **The click never reached them.** The scene's window rect is the content
/// port grown UP by `titlebarHeight` — the guest's own convention, whether
/// or not anything is drawn in that band. `HitTester` read it that way.
/// `SceneRenderer` did not: for a titleless dialog it treated the band as
/// chrome it could shrink to its 6-pixel border, so it drew the content 14
/// pixels high and 6 right. Fourteen is more than half a push button. Aiming
/// at the middle of a drawn button hit-tested ABOVE every dialog item, fell
/// through to the user pane spanning the whole dialog — an `unknown` control
/// with no action — and was refused for having no semantics.
///
/// One number, two copies. `WindowChrome.contentOrigin` is now the only one.
@MainActor
final class DialogButtonGeometryTests: XCTestCase {

    private func alert() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "scene-mail-internet-alert",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MirrorKit.Scene.self,
                                        from: Data(contentsOf: url))
    }

    private func modal(_ scene: MirrorKit.Scene) throws
        -> MirrorKit.Scene.Window {
        try XCTUnwrap(scene.windows.first { $0.app == "Mail" && $0.kind == 2 })
    }

    // MARK: - The premise, from the machine

    /// Said out loud so a later recapture cannot quietly remove the thing
    /// these tests are about — and so nobody looks for the cause in the
    /// dialog plane again.
    func testTheGuestAlreadyAuthorisesAllThreeButtons() throws {
        let win = try modal(try alert())
        let items = try XCTUnwrap(win.dialogItems)

        XCTAssertTrue(win.title.isEmpty,
                      "the alert has no title; that is what makes it the "
                      + "titleless-dialog case")
        for (number, title) in [(1, "Set Up Now"), (2, "No"), (3, "Yes")] {
            let item = try XCTUnwrap(items.first { $0.number == number })
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.semantic.kind, "pushButton")
            XCTAssertEqual(item.semantic.action, "press")
            XCTAssertEqual(item.semantic.knowledge, .known)
            XCTAssertTrue(item.enabled)
            XCTAssertNotNil(item.ref)
            XCTAssertTrue(item.semantic.authorizesAction,
                          "the DITL route already authorises this button. If "
                          + "this fails, the cause really is classification "
                          + "and these tests are pointed at the wrong half")
        }
    }

    /// And the control that swallowed the click: a user pane spanning the
    /// whole dialog, honestly `unknown`, which is what a click that misses
    /// every item lands on.
    func testAUserPaneSpansTheWholeDialogAndAuthorisesNothing() throws {
        let win = try modal(try alert())
        let pane = try XCTUnwrap(win.controls.first { $0.role == "userPane" })
        let rect = try XCTUnwrap(pane.rect)

        XCTAssertEqual(rect.l, 0)
        XCTAssertEqual(rect.t, 0)
        XCTAssertEqual(rect.r, win.rect.r - win.rect.l)
        XCTAssertEqual(rect.b, win.rect.b - win.rect.t)
        XCTAssertNil(pane.semantic?.action,
                     "a user pane answers to nothing; a click resolved to it "
                     + "is a click that missed what it was aimed at")
    }

    // MARK: - The regression, measured against the pixels

    /// **Where the renderer PUTS a button is where a click must find it.**
    ///
    /// The drawn box is not asserted from `WindowChrome` — that would test
    /// the fix against itself. It is measured: render the alert, render it
    /// again with that one dialog item deleted, and take the bounding box of
    /// every pixel that changed. That box is the button, as a person sees
    /// it. The click goes to its centre.
    func testEachDrawnButtonIsTheButtonAClickReaches() throws {
        let scene = try alert()
        let win = try modal(scene)

        for number in [1, 2, 3] {
            let box = try XCTUnwrap(
                drawnBox(of: number, in: scene, window: win.id),
                "dialog item \(number) drew no pixels at all")
            let x = (box.l + box.r) / 2
            let y = (box.t + box.b) / 2

            guard case .dialogItem(_, let hit) =
                HitTester.hitTest(scene, x: x, y: y) else {
                return XCTFail("""
                    A click at (\(x), \(y)) — the centre of where item \
                    \(number) is DRAWN — resolved to \
                    \(HitTester.hitTest(scene, x: x, y: y)) rather than to a \
                    dialog item. The renderer and the hit tester disagree \
                    about where this window's content begins.
                    """)
            }
            XCTAssertEqual(hit.number, number,
                           "clicking item \(number) where it is drawn "
                           + "answered item \(hit.number)")

            let object = try XCTUnwrap(ObjectResolver.resolve(
                .dialogItem(windowID: win.id, item: hit), in: scene))
            let plan = InteractionPolicy.plan(for: .init(
                object: object,
                gesture: .click(count: 1, mods: 0, at: .init(x: x, y: y))))
            guard case .dialogItem(let ref, let planned) = plan else {
                return XCTFail("the mirror refused a button it drew: \(plan)")
            }
            XCTAssertEqual(planned, number)
            XCTAssertEqual(ref, try XCTUnwrap(
                win.dialogItems?.first { $0.number == number }?.ref))
        }
    }

    /// The same invariant stated as geometry, so a failure says WHICH number
    /// moved rather than only that some pixel missed. Both halves must read
    /// `WindowChrome.contentOrigin`; this fails the moment either re-derives
    /// it from a literal.
    func testContentOriginIsTheGuestsRectConventionForADialogToo() throws {
        let scene = try alert()
        let win = try modal(scene)
        let origin = WindowChrome.contentOrigin(win)

        XCTAssertEqual(origin.x, win.rect.l)
        XCTAssertEqual(origin.y, win.rect.t + WindowChrome.titlebarHeight,
                       "a titleless dialog's rect is grown up by the same "
                       + "band as any other window's. Shrinking it to the "
                       + "drawn border is what moved the content 14 pixels")
        XCTAssertFalse(WindowChrome.hasTitleBar(win))
    }

    // MARK: - The refusal, when there genuinely is one

    /// A refusal has to name the missing FACT. "The guest did not provide
    /// complete, authoritative semantics" is a verdict a person can do
    /// nothing with — and Michelle read exactly that off a modal she could
    /// not dismiss.
    func testARefusedControlSaysWhatWasUnavailable() throws {
        let scene = try alert()
        let win = try modal(scene)
        // A button-family control the CDEF route honestly cannot classify:
        // `unknown`, `cdef: 23`, which is push button / check box / radio
        // button behind one id.
        let button = try XCTUnwrap(win.controls.first { $0.title == "Yes" })
        XCTAssertEqual(button.semantic?.cdef, 23)
        XCTAssertEqual(button.semantic?.knowledge, .unknown)

        let object = try XCTUnwrap(ObjectResolver.resolve(
            .control(windowID: win.id, control: button), in: scene))
        let plan = InteractionPolicy.plan(for: .init(
            object: object, gesture: .click(count: 1, mods: 0,
                                            at: .init(x: 0, y: 0))))
        guard case .unsupported(let why) = plan else {
            return XCTFail("""
                A control with `knowledge: unknown` and no action was \
                authorised. That is the confidently-wrong classification the \
                CDEF refusal exists to prevent — do not widen it back.
                """)
        }
        XCTAssertTrue(why.contains("CDEF 23"), why)
        XCTAssertTrue(why.contains("button family"), why)
        XCTAssertTrue(why.contains("variation code"), why)
        XCTAssertTrue(why.contains("by position"),
                      "the refusal must name the route that still works — "
                      + "`ctlact` with a point reaches this control: \(why)")
        XCTAssertFalse(why.contains("did not provide complete"),
                       "the old verdict-shaped sentence is back: \(why)")
    }

    // MARK: - Measuring the drawn box

    /// The bounding box of every pixel that changes when one dialog item is
    /// removed from the scene — i.e. where the renderer draws it, read off
    /// the render rather than recomputed from the geometry under test.
    private func drawnBox(of number: Int, in scene: MirrorKit.Scene,
                          window: String) throws -> Rect? {
        var without = scene
        for w in without.windows.indices where without.windows[w].id == window {
            without.windows[w].dialogItems?.removeAll { $0.number == number }
        }
        let a = try pixels(try RenderShot.png(scene: scene))
        let b = try pixels(try RenderShot.png(scene: without))
        guard a.width == b.width, a.height == b.height else { return nil }
        var box: Rect?
        for y in 0..<a.height {
            for x in 0..<a.width where a.data[y * a.width + x]
                != b.data[y * b.width + x] {
                if var found = box {
                    found.l = min(found.l, x); found.t = min(found.t, y)
                    found.r = max(found.r, x + 1); found.b = max(found.b, y + 1)
                    box = found
                } else {
                    box = Rect(l: x, t: y, r: x + 1, b: y + 1)
                }
            }
        }
        return box
    }

    private func pixels(_ png: Data) throws
        -> (width: Int, height: Int, data: [UInt32]) {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let cg = try XCTUnwrap(rep.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt32](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceRGB()
        try data.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, data)
    }
}
