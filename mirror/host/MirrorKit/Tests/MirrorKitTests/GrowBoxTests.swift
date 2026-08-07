import XCTest
@testable import MirrorKit

/// **Nothing may offer a grow box the guest has not reported.**
///
/// `WindowChrome.growBox` guarded on `win.kind != 2` until 2026-08-07, and
/// fidelity sweep D measured that discriminator wrong **in both directions at
/// once**, against the guest's own pixels:
///
/// - **Appearance is `kind == 2000`** — it passed the guard, so the render
///   drew a grow box at its bottom-right corner. The machine draws none.
/// - **Extensions Manager is `kind == 2`** — it failed the guard, so it was
///   denied a grow box. The machine draws one, and the window is resizable.
///
/// `kind` says who OWNS a window, not what its frame looks like. That is the
/// third time this file's neighbours have learned it: `hasTitleBar` was
/// corrected off `kind != 2` in August, `zoomBox` was withdrawn for the same
/// reason, and this is the last function in the file that still read it.
///
/// The fabrication was not cosmetic. `HitTester` reported the corner as a
/// target, and `Serve`/`Battery` drag from it — so on a window with no grow
/// box, `mirror.act.window op: resize` dragged inside a live application's
/// content region. Same shape as the zoom act that clicked into the racing
/// stripes.
///
/// So these tests assert the WITHDRAWAL, on both halves of the measured pair,
/// through all three consumers. Restore `guard win.kind != 2` and every one of
/// them names it.
final class GrowBoxTests: XCTestCase {

    /// The pair sweep D measured, and the two other kinds in its corpus.
    /// Posed as a property rather than as two constants: **no window shape
    /// gets a grow box**, so nothing in `Scene.Window` can be reaching the
    /// decision. A discriminator restored on any field fails here.
    func testNoWindowShapeIsGivenAGrowBox() throws {
        for (kind, title) in [(2000 as Int?, "Appearance"),
                              (2, "Extensions Manager"),
                              (2, "Memory"),
                              (8, "SimpleText"),
                              (8, "New Old World"),
                              (20, "Macintosh HD"),
                              (nil, "unreported kind")] {
            let win = try Self.window(kind: kind, title: title)
            XCTAssertNil(
                WindowChrome.growBox(win),
                "\"\(title)\" (kind \(kind.map(String.init) ?? "null")) is "
                    + "offered a grow box. Resizability is a WDEF variant and "
                    + "IR v1 does not carry it — the WindowRecord has no grow "
                    + "flag at all — so no field here can establish one. "
                    + "Sweep D measured `kind` wrong in both directions. If "
                    + "`FindWindow`'s `inGrow` landed, this test and "
                    + "docs/known-wrong.md both need rewriting; if it did "
                    + "not, the fabricated affordance is back and a resize "
                    + "drags inside the content region.")
        }
    }

    /// The hit-tester is the half that turns a fabricated box into a drag.
    /// Sweeping the whole bottom-right corner, not just its centre: a grow
    /// box restored with a different span would still be a drag target.
    func testTheHitTesterFindsNoGrowBoxTargetInAnyCorner() throws {
        for kind in [2000 as Int?, 2, 8, 20, nil] {
            let win = try Self.window(kind: kind, title: "W")
            let scene = try Self.scene(win)
            let r = win.rect
            for dx in 1...WindowChrome.growBoxSpan {
                for dy in 1...WindowChrome.growBoxSpan {
                    let hit = HitTester.hitTest(scene, x: r.r - dx, y: r.b - dy)
                    if case .growBox = hit {
                        return XCTFail(
                            "kind \(kind.map(String.init) ?? "null"): the "
                                + "hit-tester reports a grow box target at "
                                + "(\(r.r - dx), \(r.b - dy)). Nothing may "
                                + "offer one while WindowChrome.growBox "
                                + "cannot establish it.")
                    }
                }
            }
        }
    }

    /// And the corner is not silently swallowed either — it resolves to the
    /// window's content, which is what it actually is. A guard that answered
    /// `nil` by making the corner unreachable would trade one wrong answer
    /// for another.
    func testTheCornerResolvesToTheWindowItself() throws {
        let win = try Self.window(kind: 8, title: "SimpleText")
        let scene = try Self.scene(win)
        let hit = HitTester.hitTest(scene, x: win.rect.r - 4, y: win.rect.b - 4)
        guard case .content(let id, _, _, _, _) = hit else {
            return XCTFail("the bottom-right corner resolved to \(hit); with "
                           + "no grow box it is ordinary window content")
        }
        XCTAssertEqual(id, win.id)
    }

    // MARK: -

    /// Built through the public decoder rather than a memberwise initialiser,
    /// so the fixture is the shape a real scene produces.
    static func window(kind: Int?, title: String) throws -> Scene.Window {
        let kindJSON = kind.map(String.init) ?? "null"
        let json = """
            {"id":"1.0/\(title)#0","app":"\(title)","psn":"1.0",
             "title":"\(title)","kind":\(kindJSON),
             "rect":{"l":100,"t":80,"r":500,"b":400},
             "front":true,"z":0,"visible":true,"controls":[]}
            """
        return try JSONDecoder().decode(
            Scene.Window.self, from: Data(json.utf8))
    }

    /// A real captured scene with our one window in it — the same approach the
    /// other hit tests use, so everything around the window is the guest's own.
    static func scene(_ win: Scene.Window) throws -> Scene {
        guard let url = Bundle.module.url(forResource: "Fixtures",
                                          withExtension: nil) else {
            throw XCTSkip("Fixtures resource directory missing")
        }
        let data = try Data(contentsOf:
            url.appendingPathComponent("02-axtree-front-finder.raw.json"))
        var s = try FixtureEnvelope.scene(from: data)
        s.windows = [win]
        s.desktopItems = []
        return s
    }
}
