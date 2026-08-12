import Foundation

/* Reducing a modern photo to what a classic screen can hold, as a pure
   unit: RGB bytes in, indexed rows out, no ImageIO and no wire. The
   host does ALL rendering for a cloud.preview (contract, CloudPreview)
   because the modern machine is the only side that can decode a HEIC —
   the classic side's whole job is one CopyBits, and the target tables
   are the CLASSIC SYSTEM ones, because a GWorld built over there with a
   NULL colour table wears exactly them. No palette travels.

   Two depths, two ditherers, both error-diffusing and both integer:
   8-bit goes through Floyd-Steinberg against the system 256-colour
   table, 1-bit through Atkinson against black and white — Atkinson
   diffuses only 6/8 of the error, which is why it reads crisp on a
   1-bit screen; it is the dither those screens' own era chose. Integer
   arithmetic keeps the bytes deterministic, which is what the tests
   hold onto. */
enum ClassicDither {
    /// What a preview.begin describes and the bulk stream carries: raw
    /// indexed rows, top to bottom, rowBytes apart.
    struct Indexed: Equatable, Sendable {
        var width: Int
        var height: Int
        /// 1 or 8; the wire's own enum.
        var depth: Int
        /// width at depth 8, ceil(width / 8) at depth 1 — stated in the
        /// contract rather than derived, so it is stated here too.
        var rowBytes: Int
        var pixels: Data
    }

    // MARK: - The classic system 8-bit table

    /* The standard 'clut' 8 layout: indices 0..214 are the 6x6x6 cube
       of levels FF,CC,99,66,33,00 (index 0 white; the cube's own black
       slot at 215 is NOT here — black lives at 255), then four 10-step
       ramps at the levels the cube skips (EE,DD,BB,AA,88,77,55,44,22,11):
       reds 215..224, greens 225..234, blues 235..244, greys 245..254,
       and black at 255. Generated rather than typed: 768 hand-copied
       bytes would be 768 chances to be wrong, where the generating rule
       is checkable against any dump of the real table. */
    static let systemCLUT8: [(r: UInt8, g: UInt8, b: UInt8)] = {
        var table: [(r: UInt8, g: UInt8, b: UInt8)] = []
        let cube: [UInt8] = [0xFF, 0xCC, 0x99, 0x66, 0x33, 0x00]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 where !(r == 5 && g == 5 && b == 5) {
                    table.append((cube[r], cube[g], cube[b]))
                }
            }
        }
        let ramp: [UInt8] = [0xEE, 0xDD, 0xBB, 0xAA, 0x88,
                             0x77, 0x55, 0x44, 0x22, 0x11]
        for level in ramp { table.append((level, 0, 0)) }
        for level in ramp { table.append((0, level, 0)) }
        for level in ramp { table.append((0, 0, level)) }
        for level in ramp { table.append((level, level, level)) }
        table.append((0, 0, 0))
        return table
    }()

    /// Nearest table index for one (already clamped) colour. The cube's
    /// nearest entry falls out of per-channel rounding — the channels
    /// are independent there — so only the 41 non-cube entries (the
    /// ramps and black) need scanning.
    static func nearestIndex(r: Int, g: Int, b: Int) -> UInt8 {
        // Cube candidate: nearest of the six levels per channel. Level
        // spacing is 0x33 = 51, levels descend from 0xFF.
        func levelIndex(_ v: Int) -> Int { min(5, max(0, (255 - v + 25) / 51)) }
        let ri = levelIndex(r), gi = levelIndex(g), bi = levelIndex(b)
        var best = ri * 36 + gi * 6 + bi
        if best == 215 { best = 255 }         // the cube's black slot
        func dist2(_ index: Int) -> Int {
            let entry = systemCLUT8[index]
            let dr = r - Int(entry.r), dg = g - Int(entry.g)
            let db = b - Int(entry.b)
            return dr * dr + dg * dg + db * db
        }
        var bestDist = dist2(best)
        for index in 215...255 where dist2(index) < bestDist {
            best = index
            bestDist = dist2(index)
        }
        return UInt8(best)
    }

    // MARK: - 8-bit: Floyd-Steinberg against the system table

    /// `rgb` is packed 3 bytes per pixel, row-major, width * height * 3
    /// bytes. Rows out are one byte per pixel (rowBytes == width).
    static func dither8(rgb: [UInt8], width: Int, height: Int) -> Indexed {
        precondition(rgb.count == width * height * 3, "rgb size mismatch")
        var pixels = Data(count: width * height)
        // Diffusion carry, one channel-triple per pixel, sixteenths so
        // the 7/16-3/16-5/16-1/16 split stays integral.
        var carryNow = [Int](repeating: 0, count: width * 3)
        var carryNext = [Int](repeating: 0, count: width * 3)
        pixels.withUnsafeMutableBytes {
            (out: UnsafeMutableRawBufferPointer) -> Void in
            for y in 0..<height {
                for x in 0..<width {
                    let at = (y * width + x) * 3
                    func channel(_ c: Int) -> Int {
                        let v = Int(rgb[at + c]) + carryNow[x * 3 + c] / 16
                        return min(255, max(0, v))
                    }
                    let r = channel(0), g = channel(1), b = channel(2)
                    let index = nearestIndex(r: r, g: g, b: b)
                    out[y * width + x] = index
                    let entry = systemCLUT8[Int(index)]
                    let err = [r - Int(entry.r), g - Int(entry.g),
                               b - Int(entry.b)]
                    for c in 0..<3 {
                        let e = err[c]
                        if x + 1 < width {
                            carryNow[(x + 1) * 3 + c] += e * 7
                            carryNext[(x + 1) * 3 + c] += e * 1
                        }
                        if x > 0 { carryNext[(x - 1) * 3 + c] += e * 3 }
                        carryNext[x * 3 + c] += e * 5
                    }
                }
                carryNow = carryNext
                carryNext = [Int](repeating: 0, count: width * 3)
            }
        }
        return Indexed(width: width, height: height, depth: 8,
                       rowBytes: width, pixels: pixels)
    }

    // MARK: - 1-bit: Atkinson against black and white

    /// Rows out are packed bits, MSB first, 1 = black 0 = white — the
    /// classic 1-bit convention. rowBytes == ceil(width / 8).
    static func dither1(rgb: [UInt8], width: Int, height: Int) -> Indexed {
        precondition(rgb.count == width * height * 3, "rgb size mismatch")
        let rowBytes = (width + 7) / 8
        var pixels = Data(count: rowBytes * height)
        // Atkinson spreads eighths of the error two rows deep.
        var carry = [[Int]](repeating: [Int](repeating: 0, count: width),
                            count: 3)
        pixels.withUnsafeMutableBytes {
            (out: UnsafeMutableRawBufferPointer) -> Void in
            for y in 0..<height {
                for x in 0..<width {
                    let at = (y * width + x) * 3
                    // Rec. 601 luma in integer form.
                    let gray = (Int(rgb[at]) * 77 + Int(rgb[at + 1]) * 151
                                + Int(rgb[at + 2]) * 28) >> 8
                    let value = min(255, max(0, gray + carry[0][x] / 8))
                    let black = value < 128
                    if black {
                        out[y * rowBytes + x / 8] |= UInt8(0x80 >> (x % 8))
                    }
                    // 6/8 of the error moves on; Atkinson drops the rest.
                    let err = value - (black ? 0 : 255)
                    if x + 1 < width { carry[0][x + 1] += err }
                    if x + 2 < width { carry[0][x + 2] += err }
                    if x > 0 { carry[1][x - 1] += err }
                    carry[1][x] += err
                    if x + 1 < width { carry[1][x + 1] += err }
                    carry[2][x] += err
                }
                carry.removeFirst()
                carry.append([Int](repeating: 0, count: width))
            }
        }
        return Indexed(width: width, height: height, depth: 1,
                       rowBytes: rowBytes, pixels: pixels)
    }

    /// The dispatch the serving path uses; depth is the wire's enum, so
    /// anything else is the caller's bug, not a runtime case.
    static func dither(rgb: [UInt8], width: Int, height: Int,
                       depth: Int) -> Indexed {
        depth == 1 ? dither1(rgb: rgb, width: width, height: height)
                   : dither8(rgb: rgb, width: width, height: height)
    }

    /// Aspect-preserving fit of (width x height) inside (maxWidth x
    /// maxHeight), never scaling up. The same arithmetic the guest's
    /// blit uses to center what arrives; stated once per side.
    static func fit(width: Int, height: Int, maxWidth: Int,
                    maxHeight: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        if width <= maxWidth && height <= maxHeight {
            return (width, height)
        }
        var w = maxWidth
        var h = height * w / width
        if h > maxHeight {
            h = maxHeight
            w = width * h / height
        }
        return (max(1, w), max(1, h))
    }
}
