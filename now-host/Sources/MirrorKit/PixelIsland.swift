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
/// Wire shape is the standard W1 pager (docs/18-file-transfer): the producer
/// verb opens a handle, we page it by offset with `fetch`, `close` it, and
/// verify the declared transport CRC-32. The payload is PackBits-per-row.
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

extension WireClient {

    /// Fetch one screen region's real pixels as an island.
    ///
    /// `depth` 16 asks for the guest's native RGB555 (colour — what icons need);
    /// 8 is grayscale. Rect is GLOBAL screen coords: the `capture` verb clamps
    /// to the main device, whose origin is (0,0) on the single-screen classic
    /// Macs we target, so global == device-pixmap coords.
    ///
    /// Auto-tiled: the guest answers out of one resident transfer buffer, so a
    /// region wider than it fits comes back `too_large`. We band the rect to fit
    /// (same arithmetic as the host oracle's `capture_full`) and stitch — the
    /// caller just asks for a rect.
    public func captureRegion(left: Int, top: Int, right: Int, bottom: Int,
                              scale: Int = 1,
                              depth: Int = 16) throws -> PixelIsland {
        let w = max(0, right - left), h = max(0, bottom - top)
        guard w > 0, h > 0 else {
            throw PixelIslandError.badReply("empty rect")
        }
        // Rows per band that fit kXferBufMax, worst-case PackBits expansion.
        let bytesPerRow = depth == 8 ? w : (depth == 16 ? w * 2 : (w + 7) / 8)
        let perRowMax = bytesPerRow + (bytesPerRow + 126) / 127
        let bandH = max(1, min(h, Self.kXferBufMax / max(1, perRowMax)))

        var stitched = Data(capacity: w * h * 4)
        var y = top
        var firstOrigin: (x: Int, y: Int)? = nil
        var usedScale = scale
        while y < bottom {
            let bh = min(bandH, bottom - y)
            let (payload, opened) = try pull("capture", [
                "rect": ["left": left, "top": y, "right": right, "bottom": y + bh],
                "scale": scale, "depth": depth,
            ])
            let band = try Self.island(from: payload, opened: opened, scale: scale)
            stitched.append(band.rgba)
            if firstOrigin == nil { firstOrigin = (band.originX, band.originY) }
            usedScale = band.scale
            y += bh
        }
        return PixelIsland(width: w / scale, height: stitched.count / max(1, w / scale * 4),
                           rgba: stitched,
                           originX: firstOrigin?.x ?? left,
                           originY: firstOrigin?.y ?? top, scale: usedScale)
    }

    /// The guest's resident transfer buffer bound (docs/18) — a capture band
    /// must fit it or the verb answers `too_large`.
    static let kXferBufMax = 131_072

    /// The generic producer pager: run `verb`, drain its handle, verify the CRC.
    /// Envelope-agnostic — returns the assembled raw bytes plus the open-result.
    /// An open-result with no `handle` is already complete (inline `data`).
    public func pull(_ verb: String,
                     _ args: [String: Any] = [:]) throws
                     -> (payload: Data, opened: [String: Any]) {
        let opened = try request(verb, args).result
        var buf = Data()

        if let handleValue = SceneBuilder.intValue(opened["handle"]) {
            let chunk = SceneBuilder.intValue(opened["chunk"]) ?? 768
            defer { _ = try? request("close", ["handle": handleValue]) }
            while true {
                let page = try request("fetch", ["handle": handleValue,
                                                 "offset": buf.count,
                                                 "maxBytes": chunk]).result
                let before = buf.count
                if let b64 = page["data"] as? String,
                   let d = Data(base64Encoded: b64) {
                    buf.append(d)
                }
                if (page["eof"] as? NSNumber)?.boolValue == true { break }
                // No progress and no eof would spin forever — the guest is
                // misbehaving; take what we have rather than hang the poll.
                if buf.count == before { break }
            }
        } else {
            // Inline: the whole payload rode the open-result.
            if let b64 = opened["data"] as? String,
               let d = Data(base64Encoded: b64) {
                buf = d
            }
        }

        if let want = opened["crc"] as? String {
            let got = String(format: "%08x", Self.crc32(buf))
            guard got == want else {
                throw PixelIslandError.crcMismatch(got: got, want: want,
                                                   bytes: buf.count)
            }
        }
        return (buf, opened)
    }

    // MARK: - Decode

    /// Decode one capture band into tight RGBA8. Mirrors `capture_codec.py`
    /// (the host oracle): PackBits per row, then per-format expansion. A 16-bit
    /// classic screen arrives big-endian RGB555 — expanded to RGB8 without
    /// inventing colour beyond what the guest framebuffer holds.
    static func island(from payload: Data, opened: [String: Any],
                       scale: Int) throws -> PixelIsland {
        guard let width = SceneBuilder.intValue(opened["width"]),
              let height = SceneBuilder.intValue(opened["height"]),
              width > 0, height > 0 else {
            throw PixelIslandError.badReply("missing width/height")
        }
        let format = (opened["format"] as? String) ?? "gray8"
        let sourceRowBytes: Int
        switch format {
        case "gray8":    sourceRowBytes = SceneBuilder.intValue(opened["rowBytes"]) ?? width
        case "mono1":    sourceRowBytes = SceneBuilder.intValue(opened["rowBytes"]) ?? (width + 7) / 8
        case "rgb555be": sourceRowBytes = SceneBuilder.intValue(opened["rowBytes"]) ?? width * 2
        default: throw PixelIslandError.unsupportedFormat(format)
        }

        let want = sourceRowBytes * height
        let source: Data
        if (opened["compression"] as? String ?? "packbits") == "packbits" {
            source = try unpackBits(payload, expected: want)
        } else {
            source = payload
        }
        guard source.count >= want else {
            throw PixelIslandError.truncated(got: source.count, want: want)
        }

        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            source.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    let row = y * sourceRowBytes
                    for x in 0..<width {
                        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
                        switch format {
                        case "gray8":
                            let v = src[row + x]; r = v; g = v; b = v
                        case "mono1":
                            // QuickDraw mono: a set bit is BLACK.
                            let byte = src[row + x / 8]
                            let on = (byte >> (7 - UInt8(x % 8))) & 1
                            let v: UInt8 = on == 1 ? 0 : 255
                            r = v; g = v; b = v
                        default:  // rgb555be
                            let hi = UInt16(src[row + x * 2])
                            let lo = UInt16(src[row + x * 2 + 1])
                            let p = (hi << 8) | lo
                            // 5 bits -> 8: replicate the high bits (x*255/31).
                            let r5 = UInt8((p >> 10) & 0x1F)
                            let g5 = UInt8((p >> 5) & 0x1F)
                            let b5 = UInt8(p & 0x1F)
                            r = (r5 << 3) | (r5 >> 2)
                            g = (g5 << 3) | (g5 >> 2)
                            b = (b5 << 3) | (b5 >> 2)
                        }
                        let o = (y * width + x) * 4
                        out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = 255
                    }
                }
            }
        }

        let origin = (opened["origin"] as? [Any])?.compactMap(SceneBuilder.intValue)
        return PixelIsland(width: width, height: height, rgba: rgba,
                           originX: origin?.first ?? 0,
                           originY: (origin?.count ?? 0) > 1 ? origin![1] : 0,
                           scale: SceneBuilder.intValue(opened["scale"]) ?? scale)
    }

    /// Apple PackBits RLE, decoded until `expected` bytes are produced.
    static func unpackBits(_ data: Data, expected: Int) throws -> Data {
        var out = Data(capacity: expected)
        var i = data.startIndex
        while out.count < expected && i < data.endIndex {
            let control = data[i]
            i = data.index(after: i)
            if control < 128 {                       // literal run
                let count = Int(control) + 1
                let end = data.index(i, offsetBy: count, limitedBy: data.endIndex)
                    ?? data.endIndex
                out.append(data[i..<end])
                i = end
            } else if control > 128 {                // repeat run
                guard i < data.endIndex else { break }
                out.append(contentsOf: repeatElement(data[i], count: 257 - Int(control)))
                i = data.index(after: i)
            }                                        // 128 = no-op
        }
        guard out.count == expected else {
            throw PixelIslandError.truncated(got: out.count, want: expected)
        }
        return out
    }

    /// CRC-32 (zlib polynomial) — the transport's declared checksum.
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
