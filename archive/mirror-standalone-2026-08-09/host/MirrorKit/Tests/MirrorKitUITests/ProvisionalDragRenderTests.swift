import XCTest
import AppKit
import SwiftUI
@testable import MirrorKit
@testable import MirrorKitUI

/// **The anchoring decision, pinned in pixels.**
///
/// `UnknownVisual` anchors its stipple to the CONTEXT, so a static rectangle
/// that shifts a pixel does not make its texture crawl. `ProvisionalVisual`
/// anchors to the RECTANGLE, so an item travelling under the pointer carries
/// its texture instead of swimming through a field nailed to the screen.
///
/// Both are correct and they are opposites, which is exactly the kind of pair
/// a later edit unifies "for consistency" without anything noticing. Nothing
/// else in either file would catch that: the constants are shared, the tile is
/// shared, and the only difference is one `translateBy`. So this reads the
/// pixels.
///
/// The method is the one `UnknownVisualRenderTests` established — render
/// offscreen through the real drawing path, then sample — because a palette
/// asserted in source proves nothing about what a person sees.
@MainActor
final class ProvisionalDragRenderTests: XCTestCase {

    /// Draw one style into a 64x64 sheet with its rectangle at `x`, and hand
    /// back the pixels.
    private func sheet(x: CGFloat, provisional: Bool) throws
        -> NSBitmapImageRep {
        let frame = CGRect(x: x, y: 8, width: 40, height: 40)
        let view = Canvas(rendersAsynchronously: false) { ctx, _ in
            if provisional {
                ProvisionalVisual.drawPlate(in: ctx, frame: frame)
            } else {
                UnknownVisual.drawGround(in: ctx, frame: frame)
            }
        }
        .frame(width: 64, height: 64)
        .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "offscreen render failed")
        return NSBitmapImageRep(cgImage: cg)
    }

    /// The lattice as seen FROM the rectangle: for each cell of a 4x4 block
    /// inset into the rectangle, is it a stipple dot?
    private func latticeRelativeToRect(_ rep: NSBitmapImageRep,
                                       rectX: CGFloat) -> [Bool] {
        var out: [Bool] = []
        for dy in 0..<4 {
            for dx in 0..<4 {
                let color = rep.colorAt(x: Int(rectX) + 4 + dx, y: 8 + 4 + dy)
                let r = Int(((color?.redComponent ?? 0) * 255).rounded())
                /* The dot is 0xDC, the ground 0xEF. Anything between is a
                   blend that should not exist in this drawing at all, and the
                   midpoint separates them cleanly. */
                out.append(r < 0xE5)
            }
        }
        return out
    }

    /// Mutation: delete the `translateBy` from `ProvisionalVisual.drawPlate`.
    /// The provisional plate then inherits the unknown's context anchoring and
    /// the two rows below become identical — which is precisely the swim.
    func testTheProvisionalPlateCarriesItsTextureAndTheUnknownDoesNot() throws {
        let provisionalAt10 = latticeRelativeToRect(
            try sheet(x: 10, provisional: true), rectX: 10)
        let provisionalAt11 = latticeRelativeToRect(
            try sheet(x: 11, provisional: true), rectX: 11)
        XCTAssertEqual(provisionalAt10, provisionalAt11,
                       "the ghost's texture must travel WITH it — a lattice "
                       + "that shifts under the item is the swim this "
                       + "anchoring exists to prevent")

        let unknownAt10 = latticeRelativeToRect(
            try sheet(x: 10, provisional: false), rectX: 10)
        let unknownAt11 = latticeRelativeToRect(
            try sheet(x: 11, provisional: false), rectX: 11)
        XCTAssertNotEqual(unknownAt10, unknownAt11,
                          "the marked unknown stays anchored to the CONTEXT, "
                          + "which is what keeps a static rectangle's texture "
                          + "from crawling — do not unify these two")
    }

    /// The texture is present and in the minority, the same claim the marked
    /// unknown makes about itself. A plate that came out flat would pass the
    /// anchoring test above and say nothing at all.
    func testTheProvisionalPlateIsStippledAndNotFlat() throws {
        let dots = latticeRelativeToRect(try sheet(x: 10, provisional: true),
                                         rectX: 10).filter { $0 }.count
        XCTAssertEqual(dots, 4, "a 25% ordered stipple over 16 cells")
    }

    /// Rule 2 of the presentation contract, at the level of what is drawn: an
    /// unconfirmed item carries the plate, a confirmed one does not.
    ///
    /// Mutation: draw the plate unconditionally in `drawItemDrag`. A drag the
    /// guest confirmed then keeps saying "not yet real" forever. Mutation the
    /// other way: never draw it, and a provisional drag asserts a placement
    /// the guest has not made.
    func testConfirmationChangesWhatIsDrawn() throws {
        let item = Scene.DesktopItem(
            name: "Read Me", kind: "file", type: nil, creator: nil,
            x: 40, y: 60, placed: true, alias: false, invisible: false,
            w: 32, h: 32, origin: .drawn)
        let scene = Scene(version: 2, seq: 1, source: "fixture", capturedAt: 0,
                          screen: .init(w: 200, h: 150), apps: [],
                          processes: nil, menubar: nil, windows: [],
                          desktopItems: nil, meta: .init(errors: []))
        let frame = Rect(l: 100, t: 60, r: 132, b: 104)

        func png(confirmed: Bool) throws -> Data {
            try RenderShot.png(
                scene: scene,
                itemDrag: .init(item: item, frame: frame,
                                confirmed: confirmed))
        }
        let provisional = try png(confirmed: false)
        let confirmed = try png(confirmed: true)
        XCTAssertNotEqual(provisional, confirmed,
                          "a confirmed drag and a provisional one must not "
                          + "look the same — the marking IS the honesty")

        /* And the difference is the plate, in the corner the mark occupies:
           provisional carries ink there, confirmed carries the desktop. */
        let rep = try XCTUnwrap(NSBitmapImageRep(data: provisional))
        let corner = try XCTUnwrap(rep.colorAt(x: 101, y: 61))
        let grey = Int((corner.redComponent * 255).rounded())
        XCTAssertTrue(grey >= 0x70 && grey <= 0xF0,
                      "expected the provisional plate's own greys at the "
                      + "ghost's corner, got \(String(grey, radix: 16))")
    }
}
