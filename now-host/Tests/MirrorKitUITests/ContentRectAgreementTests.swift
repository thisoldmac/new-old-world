import CoreGraphics
import XCTest
@testable import MirrorKit
@testable import MirrorKitUI

/// The content inset is one number that two modules must agree on, and
/// nothing checked that they did.
///
/// `SceneGeometry.contentRect` says where a window's interior is in GUEST
/// coordinates — it is what an island capture is asked for and what an island
/// is anchored at. `SceneRenderer` independently insets the same window by
/// `Platinum.contentTop` when it draws the interior. The transform between
/// them is 1:1, so the two insets must be the same number: if they drift, a
/// captured interior is drawn shifted against its own chrome, by exactly the
/// difference and in every window at once.
///
/// **Found by mutation, 2026-08-01.** Changing the 22 in `contentRect` to 20
/// broke no test in the repository. The value had crossed from the mirror
/// prototype as a measured constant, was quoted in a comment as "the same
/// inset the renderer uses", and was held by nothing — so this pins the
/// agreement rather than the number. Either module may be re-measured; they
/// may not be re-measured apart.
final class ContentRectAgreementTests: XCTestCase {

    private func window(kind: Int?,
                        rect: Rect = Rect(l: 100, t: 60, r: 400, b: 300))
        -> Scene.Window {
        Scene.Window(id: "1.2/W#0", app: "App", psn: "1.2", title: "W",
                     kind: kind, rect: rect, front: true, z: 0,
                     visible: true, controls: [], text: nil, items: nil,
                     display: nil, island: nil)
    }

    /// A document window: the top inset is the renderer's chrome height, and
    /// the other three are its 1 px frame.
    func testTheDocumentWindowInsetIsTheRenderersOwnChromeHeight() {
        let win = window(kind: 0)
        let content = SceneGeometry.contentRect(win)
        XCTAssertEqual(CGFloat(content.t - win.rect.t), Platinum.contentTop, """
            The capture inset and the renderer's chrome height disagree by \
            \(CGFloat(content.t - win.rect.t) - Platinum.contentTop) px. \
            Every island would be composited that far off its own window, \
            which reads as a rendering bug in the renderer rather than as a \
            disagreement between two constants.
            """)
        XCTAssertEqual(content.l - win.rect.l, 1)
        XCTAssertEqual(win.rect.r - content.r, 1)
        XCTAssertEqual(win.rect.b - content.b, 1)
    }

    /// A dialog (`kind == 2`) has no title bar and a uniform 6 px frame — the
    /// renderer's own special case, spelled the same way here.
    func testTheDialogInsetIsUniformOnAllFourSides() {
        let win = window(kind: 2)
        let content = SceneGeometry.contentRect(win)
        XCTAssertEqual(content.t - win.rect.t, 6)
        XCTAssertEqual(content.l - win.rect.l, 6)
        XCTAssertEqual(win.rect.r - content.r, 6)
        XCTAssertEqual(win.rect.b - content.b, 6)
    }
}
