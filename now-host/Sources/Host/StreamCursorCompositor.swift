import AppKit
import CoreGraphics

/// Adds the stream cursor after a frame has been composited. Keeping it out of
/// the retained pixel canvas prevents the previous cursor from burning into a
/// later delta or empty frame.
enum StreamCursorCompositor {
    static func drawSystemArrow(on image: CGImage, at point: CGPoint)
        -> CGImage? {
        let cursor = NSCursor.arrow
        var proposed = NSRect(origin: .zero, size: cursor.image.size)
        guard let arrow = cursor.image.cgImage(
            forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        return draw(arrow, hotSpot: cursor.hotSpot, on: image, at: point)
    }

    static func draw(_ cursor: CGImage, hotSpot: CGPoint,
                     on image: CGImage, at point: CGPoint) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw the retained frame upright first. Guest coordinates and AppKit
        // cursor hot spots are top-left based; Quartz placement is bottom-left
        // based, so restore the CTM and translate only the cursor rectangle.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0,
                                      width: image.width,
                                      height: image.height))
        context.restoreGState()
        context.draw(cursor, in: CGRect(
            x: point.x - hotSpot.x,
            y: CGFloat(image.height) - point.y + hotSpot.y
                - CGFloat(cursor.height),
            width: CGFloat(cursor.width), height: CGFloat(cursor.height)))
        return context.makeImage()
    }
}
