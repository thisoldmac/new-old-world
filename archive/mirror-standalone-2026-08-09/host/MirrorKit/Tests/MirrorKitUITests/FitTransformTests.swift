import XCTest
import CoreGraphics
@testable import MirrorKit
@testable import MirrorKitUI

/// The fit transform is the seam between drawn pixels and click targets;
/// if view→guest and guest→view don't invert cleanly the small widgets
/// drift. These pin the round-trip across the letterbox cases.
final class FitTransformTests: XCTestCase {

    func testRoundTripExactFit() {
        // View exactly matches logical → scale 1, no offset.
        let fit = FitTransform(logical: CGSize(width: 800, height: 600),
                               view: CGSize(width: 800, height: 600))
        for (x, y) in [(0, 0), (11, 29), (400, 300), (799, 599)] {
            let round = fit.toGuest(fit.toView(x, y))
            XCTAssertEqual(round.x, x)
            XCTAssertEqual(round.y, y)
        }
    }

    func testRoundTripLetterboxed() {
        // A wide view → horizontal letterbox, non-zero x offset.
        let fit = FitTransform(logical: CGSize(width: 800, height: 600),
                               view: CGSize(width: 1200, height: 600))
        XCTAssertEqual(fit.scale, 1.0, accuracy: 1e-9)
        XCTAssertEqual(fit.offset.x, 200, accuracy: 1e-9)
        for (x, y) in [(0, 0), (11, 29), (799, 599)] {
            let round = fit.toGuest(fit.toView(x, y))
            XCTAssertEqual(round.x, x, "x at (\(x),\(y))")
            XCTAssertEqual(round.y, y, "y at (\(x),\(y))")
        }
    }

    func testRoundTripScaledUp() {
        // View bigger than logical, tight height → scale > 1.
        let fit = FitTransform(logical: CGSize(width: 800, height: 600),
                               view: CGSize(width: 900, height: 640))
        // The corner where the close box lives is the sensitive case.
        for (x, y) in [(11, 29), (16, 31), (5, 5)] {
            let round = fit.toGuest(fit.toView(x, y))
            XCTAssertEqual(round.x, x, "x at (\(x),\(y))")
            XCTAssertEqual(round.y, y, "y at (\(x),\(y))")
        }
    }

    /// The close box center, drawn through the transform then clicked back,
    /// must land inside the same box — the exact bug that made it finicky.
    func testCloseBoxSurvivesTransform() {
        let win = Scene.Window(
            id: "w", app: "SimpleText", psn: "1.2", title: "untitled",
            kind: 8, rect: Rect(l: 4, t: 20, r: 619, b: 581),
            front: true, z: 0, visible: true, controls: [], text: nil,
            items: nil, display: nil)
        let box = WindowChrome.widgetBox(win, .close)!
        let center = WindowChrome.center(box)
        let fit = FitTransform(logical: CGSize(width: 800, height: 600),
                               view: CGSize(width: 900, height: 640))
        let viewPoint = fit.toView(center.x, center.y)
        let back = fit.toGuest(viewPoint)
        XCTAssertTrue(back.x >= box.l && back.x < box.r
                      && back.y >= box.t && back.y < box.b,
                      "close center round-tripped to \(back), box \(box)")
    }
}
