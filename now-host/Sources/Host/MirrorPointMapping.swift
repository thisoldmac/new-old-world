import CoreGraphics
import MirrorKit
import MirrorKitUI

/// **View coordinates → the other Mac's coordinates.**
///
/// The renderer fits the guest's logical screen into whatever box the pane
/// gives it, centred, preserving aspect (`SceneRenderer.draw` builds a
/// `FitTransform` and translates/scales by it). A gesture arrives in the
/// box's coordinates. Between the two is a scale and a letterbox offset, and
/// **getting that wrong is worse than not having clicks at all**: a click
/// that lands near-but-wrong looks like the Macintosh misbehaving, and the
/// person debugs the wrong machine.
///
/// So this inverts the SAME transform the drawing used rather than
/// re-deriving one. `FitTransform`'s own header says why they are one type:
/// *"One definition means a click can't land where the pixel wasn't drawn."*
///
/// **Outside the drawing is not a point on the Mac.** With a 4:3 guest in a
/// wide pane, a third of the box can be letterbox. Clamping a click there to
/// the nearest edge would invent a press on a screen edge nobody pressed, so
/// it answers nil and the page says the point was not on the screen.
enum MirrorPointMapping {

    /// The point on the guest's screen under a point in the drawing, or nil
    /// when the point is in the letterbox rather than on the screen.
    ///
    /// `size` must be the size the Canvas was given — the same box, or the
    /// offset is computed against a rectangle the drawing never used.
    static func guestPoint(_ point: CGPoint, in size: CGSize,
                           scene: MirrorKit.Scene) -> (x: Int, y: Int)? {
        let logical = SceneRenderer(scene: scene).logicalSize
        guard logical.width > 0, logical.height > 0,
              size.width > 0, size.height > 0 else { return nil }
        let fit = FitTransform(logical: logical, view: size)
        let guest = fit.toGuest(point)
        /* Half-open, matching the hit tester's own `contains` (`x >= l && x <
           r`): a rounded point at exactly the logical width is the first
           column that is NOT on the screen. */
        guard guest.x >= 0, guest.x < Int(logical.width),
              guest.y >= 0, guest.y < Int(logical.height) else { return nil }
        return guest
    }
}
