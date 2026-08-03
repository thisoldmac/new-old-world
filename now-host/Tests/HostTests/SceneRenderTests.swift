import XCTest
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
}
