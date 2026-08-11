import CoreGraphics

/// The aspect-preserving fit of the logical guest surface into a view,
/// computed ONCE and used both ways: the renderer maps guest→view to draw,
/// the input maps view→guest to hit-test. One definition means a click can't
/// land where the pixel wasn't drawn.
///
/// view→guest rounds (not truncates): `Int()` biases toward zero by up to a
/// pixel and asymmetrically across the origin, which is exactly the kind of
/// corner error that makes a 11 px close box finicky.
public struct FitTransform: Equatable {
    public let logical: CGSize
    public let scale: CGFloat
    public let offset: CGPoint

    public init(logical: CGSize, view: CGSize) {
        self.logical = logical
        let s = min(view.width / logical.width, view.height / logical.height)
        scale = s
        offset = CGPoint(x: (view.width - logical.width * s) / 2,
                         y: (view.height - logical.height * s) / 2)
    }

    /// Guest point → view point.
    public func toView(_ x: Int, _ y: Int) -> CGPoint {
        CGPoint(x: offset.x + CGFloat(x) * scale,
                y: offset.y + CGFloat(y) * scale)
    }

    /// View point → guest point (rounded).
    public func toGuest(_ p: CGPoint) -> (x: Int, y: Int) {
        (Int(((p.x - offset.x) / scale).rounded()),
         Int(((p.y - offset.y) / scale).rounded()))
    }

    /// View point to a guest pixel only when it is over the rendered guest,
    /// excluding letterbox and surrounding host chrome.
    public func toGuestIfInside(_ p: CGPoint) -> (x: Int, y: Int)? {
        let width = logical.width * scale
        let height = logical.height * scale
        guard p.x >= offset.x, p.y >= offset.y,
              p.x < offset.x + width, p.y < offset.y + height else {
            return nil
        }
        return bounded(toGuest(p))
    }

    /// The captured-drag inverse: once a press begins in guest space, motion
    /// beyond an edge remains owned and pins to its nearest guest pixel.
    public func toGuestClamped(_ p: CGPoint) -> (x: Int, y: Int) {
        bounded(toGuest(p))
    }

    private func bounded(_ point: (x: Int, y: Int)) -> (x: Int, y: Int) {
        let maxX = max(0, Int(logical.width) - 1)
        let maxY = max(0, Int(logical.height) - 1)
        return (min(max(0, point.x), maxX), min(max(0, point.y), maxY))
    }
}
