import XCTest
@testable import MirrorKitUI

/// **Every bitmap the mirror draws is sampled nearest-neighbour.**
///
/// This gate reads the source, and it does so because nothing else can.
/// A blurred glyph or a smeared 1-pixel Platinum rule is invisible to a
/// similarity score — the pixel suites in this package would stay green
/// while every character of text in the mirror turned to grey mush at
/// 200%. So the property is asserted where it is stated: at the call
/// site, in text.
///
/// The rule it enforces is that a `GraphicsContext` has **no** context-
/// wide interpolation setting, so `.interpolation(.none)` has to be
/// repeated at every `Image` that is drawn. A repeated statement is a
/// list, and a hand-maintained list wants a test that reads it — the same
/// shape of gate as `CommandParityTests` and `MCPCoverageTests`, and for
/// the same reason: this one was originally set on the hand-built
/// `CGImage`s only, so the asset-pack icons, the desktop picture and the
/// glyph sheet were all still smoothing and nobody could see it.
///
/// Watched failing by mutation: deleting `.interpolation(.none)` from the
/// glyph sheet draw in `BitmapFont.swift` fails it naming that file.
final class NearestNeighbourSamplingTests: XCTestCase {

    private static let sources = ["SceneRenderer.swift",
                                  "DisplayReplay.swift",
                                  "BitmapFont.swift",
                                  "UnknownVisual.swift"]

    private func uiSource(_ name: String) throws -> String {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MirrorKitUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MirrorKit
            .appendingPathComponent("Sources/MirrorKitUI")
        return try String(contentsOf: ui.appendingPathComponent(name),
                          encoding: .utf8)
    }

    func testEveryDrawnImageAsksForNearestNeighbour() throws {
        var total = 0
        for name in Self.sources {
            let text = try uiSource(name)
            /* Split on the constructor rather than parsing: what has to
               be true is that the modifier appears in the expression the
               constructor starts, and the next 120 characters is more
               than enough to hold it across a line break while being far
               short of the next statement. */
            let parts = text.components(separatedBy: "Image(decorative:")
            for tail in parts.dropFirst() {
                total += 1
                let window = String(tail.prefix(120))
                XCTAssertTrue(
                    window.contains(".interpolation(.none)"),
                    "\(name) builds an Image without asking for "
                        + "nearest-neighbour sampling. GraphicsContext has "
                        + "no context-wide interpolation setting, so every "
                        + "site states it or that image alone smooths — and "
                        + "a smoothed 1-pixel Platinum rule is invisible to "
                        + "every pixel gate in this package. Near: "
                        + window.prefix(60))
            }
        }
        /* The count is asserted so that DELETING a draw is as loud as
           mis-writing one: a site that quietly disappears takes its
           coverage with it, and this file would otherwise read green
           over an empty list. */
        /* 9 → 8 on 2026-08-07: the pixel-island draw in `SceneRenderer` was
           removed with the rest of the wire-pixel path. The gate did its job
           — the deletion was loud. */
        /* 8 → 9 on 2026-08-11: the attributed Apple menu mark joined the
           semantic renderer. Its call site explicitly requests `.none`. */
        /* 9 → 10 on 2026-08-11: the cross-proved Finder alias transform
           joined the same local renderer and also explicitly requests
           nearest-neighbour sampling. */
        /* 10 → 11 on 2026-08-11: Apple-menu rows now draw their explicit
           profile-joined native `ics8` identity with `.none`. */
        XCTAssertEqual(total, 11,
                       "the number of drawn bitmaps in MirrorKitUI changed. "
                       + "That is fine — check the new one asks for "
                       + "nearest-neighbour, then update this number so the "
                       + "next change is loud too.")
    }
}
