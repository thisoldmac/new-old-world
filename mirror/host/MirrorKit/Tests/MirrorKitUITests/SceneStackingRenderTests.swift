import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// **The scene's window order IS its stacking order, and this is the only
/// gate that says so.**
///
/// The renderer draws `scene.windows.reversed()` — index 0 last, so index 0
/// is on top. That one word is the entire cross-application depth model on
/// this side: classic Mac OS has no chain that spans applications, so the
/// producer's array order is where the layering rides, and a renderer that
/// stopped honouring it would be silently wrong in a way no fixture
/// comparison would name.
///
/// It had no test. The producer's half is `now-guest-ppc/src/scene/
/// front_order.h` and `front_order_test.c`; this is the consumer's.
@MainActor
final class SceneStackingRenderTests: XCTestCase {

    private func window(_ name: String, _ r: Rect, front: Bool,
                        kind: Int) -> Scene.Window {
        var w = Scene.Window(id: "\(name)#0", app: name,
                             psn: "1.\(name.count)", title: name, kind: kind,
                             rect: r, front: front, z: 0, visible: true,
                             controls: [], text: nil, items: nil,
                             display: nil, island: nil)
        /* PROVEN EMPTY, not unreported. A window that reports nothing at
           all is drawn as the "Guest content not reported" hatch, which
           covers the face this test reads - so the fixture would answer
           the same colour whichever window won and prove nothing. */
        w.dialogItems = []
        return w
    }

    private func scene(_ windows: [Scene.Window]) -> Scene {
        Scene(version: 2, seq: 1, source: "mock", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: nil,
              menubar: nil, windows: windows, desktopItems: nil,
              meta: .init(errors: []))
    }

    private func pixel(_ scene: Scene, x: Int, y: Int) throws
        -> (UInt8, UInt8, UInt8) {
        let png = try RenderShot.png(scene: scene)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let bytes = try XCTUnwrap(rep.bitmapData)
        let o = y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8)
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    /// Two overlapping windows, distinguishable by their faces: a
    /// windowKind 2 panel is erased with the dialog grey and an ordinary
    /// document window with white. Whichever is FIRST in the array must own
    /// the overlap, whichever way round the array is written.
    func testTheFirstWindowInTheArrayOwnsTheOverlap() throws {
        let box = Rect(l: 100, t: 100, r: 500, b: 400)
        let panel = window("Date & Time", box, front: true, kind: 2)
        let document = window("Macintosh HD", box, front: false, kind: 20)
        // Well inside the overlap and below both title bars.
        let (x, y) = (300, 300)

        let panelFirst = try pixel(scene([panel, document]), x: x, y: y)
        XCTAssertEqual(panelFirst.0, 221,
                       "the panel is first, so its dialog-grey face wins")

        let documentFirst = try pixel(scene([document, panel]), x: x, y: y)
        XCTAssertEqual(documentFirst.0, 255, """
            reversing the array did not change which window owns the \
            overlap. The producer's order is the ONLY cross-application \
            stacking a scene carries — see now-guest-ppc/src/scene/\
            front_order.h — so a renderer that ignores it draws a machine \
            nobody is looking at.
            """)
    }

    /// An invisible window does not take the overlap from a visible one
    /// behind it, whatever its position in the array. Stated separately
    /// because it is a different rule and the two were one `where` clause.
    func testAnInvisibleWindowDoesNotOwnTheOverlap() throws {
        let box = Rect(l: 100, t: 100, r: 500, b: 400)
        var hidden = window("Date & Time", box, front: true, kind: 2)
        hidden.visible = false
        let document = window("Macintosh HD", box, front: false, kind: 20)
        let px = try pixel(scene([hidden, document]), x: 300, y: 300)
        XCTAssertEqual(px.0, 255,
                       "a hidden panel must not paint over the window "
                       + "the machine is actually showing")
    }
}
