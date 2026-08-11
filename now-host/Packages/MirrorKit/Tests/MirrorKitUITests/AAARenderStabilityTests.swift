import XCTest
import AppKit
import SwiftUI
@testable import MirrorKit
@testable import MirrorKitUI

/// **One scene, one picture — the property every pixel-exact test here
/// assumes and nothing checked.**
///
/// `AAA` in the name is load-bearing. XCTest runs classes alphabetically, so
/// this class holds the process's FIRST rasterizations, which is the only
/// place the defect it guards is visible: `ImageRenderer` does not hand back
/// the same pixels for the same view until it has warmed, and every render
/// test in this tree was passing because it was not first. That is luck, and
/// it inverts the day someone reorders a file or runs one test alone.
///
/// What was measured (2026-08-07, `RenderShot`'s note carries the detail):
/// eight pixels of the fixture below moved between a cold render and a
/// settled one — seven by 1/255 on antialiased control edges, one by 15/255
/// on the grow box's diagonal. It was not MirrorKit lazy state: warming
/// `AssetPack`, `FontBook`, `DesktopPattern` and `IconAtlas` first changed
/// nothing, and a `Canvas` with no MirrorKit in it drifted the same way. It
/// was `ImageRenderer`'s own backing store, and `RenderShot` no longer uses
/// it.
///
/// **The limitation, said out loud, because it is why nobody caught this.**
/// Coldness is a property of the PROCESS, not of the test. Run in the full
/// suite this class is first and the guard is real; run under a `--filter`
/// that admits something else first, or invoked after any other render, it
/// passes whether or not `RenderShot` borrows a warming buffer. So a mutation
/// of the rasterization path must be watched under
/// `swift test --filter AAARenderStabilityTests` — where it does fail — and
/// a green here from a warm process proves nothing. There is no way to make
/// a warm process cold again from inside itself, which is precisely why this
/// went unnoticed under twenty render-test files that all looked strict.
@MainActor
final class AAARenderStabilityTests: XCTestCase {

    /// Two push buttons in a window: a rounded-rect stroke, a title bar, a
    /// grow box and the unknown-desktop lattice. Every primitive family that
    /// was measured to drift is in this one picture, so the guard does not
    /// depend on which of them warms first.
    private func fixture() -> MirrorKit.Scene {
        func button(_ ref: String, _ title: String, x: Int)
            -> MirrorKit.Scene.Control {
            MirrorKit.Scene.Control(ref: ref, role: "button", title: title,
                                    rect: Rect(l: x, t: 40, r: x + 120, b: 60),
                                    enabled: true, visible: true, semantic: nil)
        }
        let window = MirrorKit.Scene.Window(
            id: "w1", app: "Fixture", psn: "0:1", title: "Fixture",
            rect: Rect(l: 20, t: 20, r: 340, b: 140),
            front: true, z: 0, visible: true,
            controls: [button("c.ok", "OK", x: 20),
                       button("c.cancel", "Cancel", x: 160)])
        return MirrorKit.Scene(version: 2, seq: 1, source: "fixture",
                               capturedAt: 0, screen: .init(w: 360, h: 160),
                               apps: [], processes: nil, menubar: nil,
                               windows: [window], desktopItems: nil,
                               meta: .init(errors: []))
    }

    /// A shot, as **raw pixel bytes taken at render time**, plus the rep for
    /// naming a coordinate afterwards.
    ///
    /// The snapshot is not fussiness and it is the second trap in this
    /// story. `NSBitmapImageRep(cgImage:)` does not copy: collect a handful
    /// of them and read their pixels at the end and they can all answer from
    /// ONE buffer, so ten different renders compare equal and a guard built
    /// that way passes the mutation it was written to catch. Watched here:
    /// the same ten renders that differ 8 pixels when their bytes are taken
    /// as they are made read 0 differences when only the reps are kept.
    private func shot() throws -> (bytes: Data, rep: NSBitmapImageRep) {
        let image = try RenderShot.cgImage(scene: fixture())
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        return (bytes, NSBitmapImageRep(cgImage: image))
    }

    /// **The gate.** A shot taken cold and a shot taken warm, of one scene,
    /// must be the same picture.
    ///
    /// It compares across the WHOLE warm-up and not just the first two
    /// renders, because the drift does not start at render two: renders one
    /// and two agree, and the third or fourth is where it moves. A guard that
    /// only checked the first pair passed the mutation below — watched doing
    /// exactly that before this was widened.
    ///
    /// Mutation: in `RenderShot.cgImage`, return `renderer.cgImage` instead
    /// of rendering into a context of our own, and run this class alone. It
    /// fails naming the pixel — watched failing at (160, 90), 17 against 16.
    func testAAAOneSceneIsOnePictureFromTheProcessesFirstRender() throws {
        let cold = try shot()
        var shots = [cold]
        for _ in 0..<9 { shots.append(try shot()) }
        for (i, later) in shots.enumerated().dropFirst() where later.bytes != cold.bytes {
            return nameTheDifference(cold.rep, later.rep,
                                     "the process's first shot and its "
                                     + "render \(i + 1)")
        }
    }

    /// `png` and `cgImage` must be the same picture — the encode is a
    /// re-presentation, not a second render. This is the other half of the
    /// original defect: a guard that compared encoded PNG BYTES was green
    /// alone and red in the suite, because an encoder's output is not a
    /// function of the pixels alone.
    func testABPNGCarriesTheSamePixels() throws {
        let direct = try shot()
        let encoded = try XCTUnwrap(
            NSBitmapImageRep(data: try RenderShot.png(scene: fixture())))
        for y in 0..<direct.rep.pixelsHigh {
            for x in 0..<direct.rep.pixelsWide
            where direct.rep.colorAt(x: x, y: y) != encoded.colorAt(x: x, y: y) {
                return nameTheDifference(direct.rep, encoded, "cgImage and png")
            }
        }
    }

    private func nameTheDifference(_ a: NSBitmapImageRep,
                                   _ b: NSBitmapImageRep,
                                   _ what: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide, file: file, line: line)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh, file: file, line: line)
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) {
                guard let ca = a.colorAt(x: x, y: y),
                      let cb = b.colorAt(x: x, y: y), ca != cb else { continue }
                return XCTFail(
                    "\(what) must be the same picture — differs at "
                    + "(\(x), \(y)): \(Int(ca.redComponent * 255)) vs "
                    + "\(Int(cb.redComponent * 255)). A renderer whose output "
                    + "depends on how many renders came first cannot carry a "
                    + "fixture corpus.",
                    file: file, line: line)
            }
        }
        XCTFail("\(what) differ in bytes but in no pixel this could name — "
                + "the comparison is looking at the wrong thing",
                file: file, line: line)
    }
}
