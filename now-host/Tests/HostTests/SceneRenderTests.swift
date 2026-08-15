import XCTest
import AppKit
import MirrorKit
import MirrorKitUI

/// NOW's scene, drawn by Mirror's renderer.
///
/// The companion to `SceneIRDecodeTests`: that one proves the document
/// PARSES, this one proves the parsed thing is drawable. They fail
/// separately and for different reasons — a scene can decode into a
/// structurally valid object that renders to an empty rectangle, which
/// is exactly the "connected, chrome-only" state this project spent a
/// day misreading as a bundle defect.
///
/// `RenderShot` rasterizes offscreen, so this needs no window and no
/// display. What it cannot check is whether the picture is RIGHT — only
/// a person looking at it can say that, and one has (2026-08-02: the
/// Finder's menu bar, both windows, About This Computer's controls and
/// the process strip, all from a scene NOW's guest produced).
@MainActor
final class SceneRenderTests: XCTestCase {

    private func scene() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MirrorKit.Scene.self,
                                        from: Data(contentsOf: url))
    }

    func testANowSceneRendersToPixels() throws {
        let png = try RenderShot.png(scene: try scene())

        /* A PNG header alone would pass a size check on an empty canvas,
           so the floor is deliberately well above "it produced a file":
           this scene has a menu bar, three windows and a process strip,
           and that much Platinum chrome does not compress into a few
           hundred bytes. */
        XCTAssertGreaterThan(png.count, 4_000, """
            The render produced only \(png.count) bytes. That is the size \
            of an empty or near-empty canvas - the scene decoded but drew \
            almost nothing, which is the failure mode that reads as "the \
            mirror is connected but blank".
            """)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47],
                       "not a PNG")
    }

    /// The renderer must be fed by the SAME document the wire carries.
    /// Rendering a hand-built Scene would prove the renderer works and
    /// nothing about whether this producer can feed it.
    func testTheRenderedSceneIsTheOneOffTheWire() throws {
        let scene = try scene()
        XCTAssertEqual(scene.source, "peek",
                       "the fixture is no longer a NOW-produced scene - "
                       + "`source` is what says which walk made it")
        XCTAssertTrue(scene.windows.contains { $0.app != "New Old World" },
                      "no foreign window: the render would be of NOW's own "
                      + "application, which is not a mirror of anything")
    }

    /// The checked-in scene is the data half of the 2026-08-01
    /// "almost perfect" visual baseline. Pin the guest's measured menu
    /// identities and coordinates so a later self-scene shortcut cannot
    /// silently replace them with guessed IDs or host text widths.
    func testAlmostPerfectBaselineKeepsGuestMenubarGeometry() throws {
        let scene = try scene()
        let menus = try XCTUnwrap(scene.menubar?.menus)

        /* `left` is optional since 2026-08-07, so an absence spells
           itself here rather than printing as a number. That is the
           point: every menu in this baseline was PLACED by the machine,
           and a producer that stopped saying where one sits would make
           it unpressable — a silent loss of capability that a row of
           zeroes used to hide. */
        XCTAssertEqual(menus.map { "\($0.id):\($0.left.map(String.init) ?? "unplaced")" }, [
            "256:10", "257:38", "258:73", "259:110",
            "261:154", "260:218", "-16490:277", "-16489:716",
        ])
        XCTAssertTrue(menus[0].apple)
        XCTAssertEqual(HitTester.appMenuWidth(scene), 84,
                       "Application-menu width is guest geometry, not a "
                       + "host font estimate")
    }

    /// Pin the draw path, not only its arithmetic. Opening the measured
    /// Application menu must paint the selection starting at guest x=716.
    /// With the regressed character-count width it began at x=730 and this
    /// exact pixel stayed in the application divider.
    func testAlmostPerfectBaselineRendersApplicationMenuAtGuestLeft() throws {
        let scene = try scene()
        let menus = try XCTUnwrap(scene.menubar?.menus)
        let appIndex = try XCTUnwrap(menus.firstIndex {
            $0.id == ObjectResolver.applicationMenuID
        })
        let png = try RenderShot.png(scene: scene, openMenu: appIndex)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let before = try XCTUnwrap(rep.colorAt(x: 715, y: 1))
        let selected = try XCTUnwrap(rep.colorAt(x: 716, y: 1))

        XCTAssertEqual(before.redComponent, 0.6, accuracy: 0.01,
                       "pixel before guest left is the measured divider shadow")
        XCTAssertEqual(before.greenComponent, 0.6, accuracy: 0.01)
        XCTAssertEqual(before.blueComponent, 0.6, accuracy: 0.01)
        XCTAssertLessThan(selected.redComponent, 0.3)
        XCTAssertLessThan(selected.greenComponent, 0.3)
        XCTAssertGreaterThan(selected.blueComponent, 0.5,
                             "guest-left pixel should be selection blue")
    }

    /// **A DITL row that draws nothing must not silence the machine.**
    ///
    /// The renderer excludes the P3 replay under every semantic frame, and
    /// a CONTROL earns that exclusion through `semanticOwnsDisplay`. Dialog
    /// items had no such gate: every visible row excluded the drawing
    /// beneath it whether or not the host drew anything in its place. Date
    /// & Time's twenty DITL rows took its date, its time, both group boxes
    /// and every field with them (2026-08-06) — while the same capture
    /// rendered whole in the fixture harness, whose scenes carry no dialog
    /// items at all, so nothing in the gate could see it.
    ///
    /// A `userItem` is the sharpest case: `drawDialogItem` draws literally
    /// nothing for one, so a render with it over the guest's own text must
    /// be pixel-identical to a render with no item there.
    func testAUserItemDoesNotSilenceTheDrawingUnderIt() throws {
        func render(withItem: Bool) throws -> Data {
            let item = withItem ? #"""
            ,"dialogItems":[{"number":1,"rect":{"l":0,"t":0,"r":180,"b":40},
              "title":"","enabled":true,"visible":true,
              "ref":"item-1",
              "semantic":{"knowledge":"known","kind":"userItem"}}]
            """# : ""
            let document = #"""
            {
              "version":2,"seq":1,"capturedAt":1,"source":"peek",
              "screen":{"w":320,"h":200},
              "apps":[{"psn":"0.3","name":"Panel","front":true}],
              "processes":[{"psn":"0.3","name":"Panel","front":true,
                            "signature":"tim2"}],
              "windows":[{
                "id":"0.3/Panel#0","app":"Panel","psn":"0.3","title":"Panel",
                "rect":{"l":20,"t":40,"r":220,"b":140},
                "front":true,"z":0,"visible":true,"controls":[],
                "ref":"window-ref","kind":2,
                "display":[
                  {"op":"text","ticks":1,"pen":[8,20],"text":"8/ 6/2026"}
                ]\#(item)
              }],
              "meta":{"errors":[],"coverage":[]}
            }
            """#
            let scene = try JSONDecoder().decode(
                MirrorKit.Scene.self, from: Data(document.utf8))
            return try RenderShot.png(scene: scene)
        }

        XCTAssertEqual(try render(withItem: true),
                       try render(withItem: false),
                       "a user item — which draws nothing at all — changed "
                       + "the picture, so it is excluding the guest's own "
                       + "drawing and putting nothing in its place")
    }
}
