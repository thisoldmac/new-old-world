import AppKit
import XCTest
import MirrorKit
import MirrorKitUI
@testable import Host

/// **Does the Mirror draw a menu bar the guest really sent?**
///
/// Michelle, 2026-08-06: the first time she hid New Old World on the guest,
/// its window went and NOW stayed frontmost — the machine drew NOW's own menu
/// bar over an empty desktop — and the Mirror drew an EMPTY bar until she
/// cycled applications and back.
///
/// Two wire passes narrowed that to one stretch. The guest reports the bar
/// correctly in that state (28 paired `axsnap`+scene samples, including the
/// one pass where the anchor plane is provably unarmed); `MirrorScene.decode`
/// and `MirrorReplicaReducer` keep it; `MirrorStateEngine.compose` never
/// touches it. What was left was the renderer, and that can be answered
/// without a screen: `RenderShot` rasterises the same `SceneRenderer` the
/// window uses, offscreen.
///
/// The fixtures are the real thing. Both documents came off a live OS 9 guest
/// (build `bf4987c6eca1`) three seconds either side of the hide, which is
/// what makes them worth keeping: a captured scene from a transitional state
/// is the artifact these renderer tests keep needing and rarely have.
@MainActor
final class MirrorMenubarRenderTests: XCTestCase {

    private func fixtureScene(_ name: String) throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json",
                              subdirectory: "Fixtures"),
            "fixture \(name).json is not in the test bundle")
        let body = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url))
        return try MirrorScene.decode(result: ["irVersion": 2, "scene": body])
    }

    /// Ink in the menu-title band: the pixels a person reads as "File Edit
    /// View". Counted left of the clock and the Application menu, so a
    /// right-hand block that always draws cannot stand in for the titles.
    ///
    /// The separation is not marginal — both fixtures measure 705 and the
    /// menu-bar-less control 77 — and the 77 is worth knowing on its own: it
    /// is the Apple glyph `shouldSynthesizeAppleMenu` falls back to when a
    /// scene carries no menus. A Mirror bar showing an apple and nothing else
    /// is exactly what "the menu is empty" looks like.
    private func titleBandInk(_ png: Data) throws -> Int {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        var ink = 0
        for y in 0..<min(19, rep.pixelsHigh) {
            for x in 0..<min(320, rep.pixelsWide) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                // Platinum's bar is near-white; a drawn title is near-black.
                if colour.brightnessComponent < 0.5 { ink += 1 }
            }
        }
        return ink
    }

    /// The state she reported: hidden application, still frontmost, menu bar
    /// on the machine's own screen. If the Mirror's empty bar came from the
    /// renderer, this is where it shows up.
    func testTheMenuBarDrawsWhileTheOwningApplicationIsHidden() throws {
        let scene = try fixtureScene("now-scene-self-hidden-but-front")
        XCTAssertEqual(scene.menubar?.app, "New Old World",
                       "fixture no longer carries the bar it was kept for")
        XCTAssertEqual(scene.menubar?.menus.count, 7)
        XCTAssertTrue(scene.windows.allSatisfy { !$0.front },
                      "fixture is meant to be the hidden state: no front window")

        let ink = try titleBandInk(
            try RenderShot.png(scene: scene, size: CGSize(width: 800,
                                                          height: 600)))
        XCTAssertGreaterThan(ink, 100, """
            The Mirror drew no menu titles for a scene that carries seven \
            menus. This is the reported empty menu bar, and it is the \
            renderer's.
            """)
    }

    /// The settled state, as the control: same machine, same application,
    /// three seconds earlier with its window up.
    func testTheMenuBarDrawsWithTheWindowUpToo() throws {
        let scene = try fixtureScene("now-scene-self-front-visible")
        let ink = try titleBandInk(
            try RenderShot.png(scene: scene, size: CGSize(width: 800,
                                                          height: 600)))
        XCTAssertGreaterThan(ink, 100,
                             "the settled state does not draw its menu bar")
    }

    /// **The negative control, so the counter is not measuring the desktop.**
    ///
    /// Strip the menu bar from the same document and the band must go quiet.
    /// Without this, a test that counts dark pixels near the top of the
    /// screen passes on any scene with a window under the bar — which is the
    /// null reading this codebase has already paid for once.
    func testASceneWithNoMenuBarLeavesTheBandEmpty() throws {
        var scene = try fixtureScene("now-scene-self-hidden-but-front")
        scene.menubar = nil
        let ink = try titleBandInk(
            try RenderShot.png(scene: scene, size: CGSize(width: 800,
                                                          height: 600)))
        XCTAssertLessThan(ink, 100, """
            The title band has ink with no menu bar in the scene, so the \
            counter is reading something else and the two tests above prove \
            nothing.
            """)
    }
}
