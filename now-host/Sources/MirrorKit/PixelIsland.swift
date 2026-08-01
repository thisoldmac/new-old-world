import Foundation

/// M3 pixel islands (QDPEEK-SPEC): the honest fallback for content that cannot
/// be replayed from semantic ops.
///
/// The mirror renders meaning, not pixels — but some guest content has no
/// meaning to read. The OS 9 Finder composites its window icon views in an
/// offscreen GWorld and CopyBits the finished composite into the window, so a
/// window's icons emit **no** per-icon op and **no** label — only one
/// content-sized blit whose pixels QDPeek deliberately never carries (finding
/// `finder-window-icons-are-offscreen-blits`). Geometry alone can't draw them.
/// For exactly those rects we fetch the guest's real pixels and composite them
/// as an island; everything around them (chrome, menus, desktop, document text)
/// stays semantic.
///
/// **The fetch is no longer here.** This file used to carry
/// `extension WireClient` — a W1 pager (`fetch`/`close`, PackBits-per-row,
/// transport CRC-32) against the TimBotTu toolkit worker's `capture` verb. It
/// was deleted rather than adapted, for two reasons that both point the same
/// way: NOW's guest does not serve that protocol, and NOW's host already
/// decodes its own capture payloads in `Host/CaptureDecoder` off
/// `GuestListener.requestCapture`. Keeping this one would have been a second
/// PackBits decoder beneath a second transport, which is the exact defect the
/// fold-in's stop condition names.
///
/// What survives is what a decoder produces and a renderer consumes: the
/// island value, and the two operations the scroll fast path needs
/// (`shifted`, `patched`). `SceneIslands` decides *when* one is fetched;
/// nothing in this module decides *how*.
public struct PixelIsland: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Tight RGBA8, row-major, `width * height * 4` bytes — ready for CGImage.
    public let rgba: Data
    /// Pixel-space map back to the guest: `global = origin + local * scale`.
    public let originX: Int
    public let originY: Int
    public let scale: Int

    public init(width: Int, height: Int, rgba: Data,
                originX: Int, originY: Int, scale: Int) {
        self.width = width; self.height = height; self.rgba = rgba
        self.originX = originX; self.originY = originY; self.scale = scale
    }
}

public extension PixelIsland {
    /// The MoveBits scroll fast-path (QDPEEK-SPEC refinement 1). A scroll is a
    /// screen→screen blit: the guest moved pixels we ALREADY hold, so move the
    /// rendered region instead of re-fetching it. Returns the shifted island
    /// plus the band the move exposed — that band is genuinely new content and
    /// is the only thing worth asking the guest for.
    func shifted(dx: Int, dy: Int) -> (island: PixelIsland, exposed: Rect?) {
        guard dx != 0 || dy != 0 else { return (self, nil) }
        var moved = Data(count: rgba.count)                 // exposed = black
        moved.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            rgba.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    let sy = y - dy                          // source row
                    guard sy >= 0, sy < height else { continue }
                    // Horizontal overlap for this row, clamped both sides.
                    let x0 = max(0, dx), x1 = min(width, width + dx)
                    guard x1 > x0 else { continue }
                    let count = (x1 - x0) * 4
                    let srcOff = (sy * width + (x0 - dx)) * 4
                    let dstOff = (y * width + x0) * 4
                    memcpy(out.baseAddress!.advanced(by: dstOff),
                           src.baseAddress!.advanced(by: srcOff), count)
                }
            }
        }
        // The band the content vacated (island-local coords).
        var exposed: Rect?
        if dy > 0 { exposed = Rect(l: 0, t: 0, r: width, b: min(height, dy)) }
        else if dy < 0 { exposed = Rect(l: 0, t: max(0, height + dy), r: width, b: height) }
        return (PixelIsland(width: width, height: height, rgba: moved,
                            originX: originX, originY: originY, scale: scale),
                exposed)
    }

    /// Patch a freshly-fetched band into this island at island-local (x, y).
    func patched(with band: PixelIsland, atX x: Int, y: Int) -> PixelIsland {
        var out = rgba
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            band.rgba.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for row in 0..<band.height {
                    let ty = y + row
                    guard ty >= 0, ty < height else { continue }
                    let w = min(band.width, width - x)
                    guard w > 0, x >= 0 else { continue }
                    memcpy(dst.baseAddress!.advanced(by: (ty * width + x) * 4),
                           src.baseAddress!.advanced(by: (row * band.width) * 4),
                           w * 4)
                }
            }
        }
        return PixelIsland(width: width, height: height, rgba: out,
                           originX: originX, originY: originY, scale: scale)
    }
}

public enum PixelIslandError: Error, CustomStringConvertible {
    case badReply(String)
    case truncated(got: Int, want: Int)
    case crcMismatch(got: String, want: String, bytes: Int)
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case .badReply(let m): return "capture: \(m)"
        case .truncated(let g, let w):
            return "capture raster truncated: \(g) of \(w) bytes"
        case .crcMismatch(let g, let w, let n):
            return "capture crc \(g) != declared \(w) (\(n) bytes)"
        case .unsupportedFormat(let f): return "unsupported capture format \(f)"
        }
    }
}
