import Foundation

/// CRC-32 (IEEE, the zlib polynomial) and the resume token built from it.
///
/// Both exist for the same question: *is this the same file I was
/// getting before?* A resumed transfer is stitched from two sessions and
/// nothing else checks the seam, so the sender names the file by its
/// content and the receiver refuses to resume onto anything else.
enum TransferIdentity {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()


    /// A checksum taken in pieces.
    ///
    /// Both receivers compute it in arrival-sized chunks. Its equality
    /// with the one-shot form is tested across arbitrary splits.
    struct CRC32 {
        private var value: UInt32 = 0xFFFF_FFFF

        init() {}

        mutating func update(_ bytes: Data) {
            /* Over a raw buffer rather than Data's iterator: this runs
               over whole multi-megabyte files on the main actor, and the
               iterator costs about an order of magnitude per byte. */
            var v = value
            bytes.withUnsafeBytes { raw in
                for byte in raw {
                    v = TransferIdentity.table[Int((v ^ UInt32(byte)) & 0xFF)]
                        ^ (v >> 8)
                }
            }
            value = v
        }

        var checksum: UInt32 { value ^ 0xFFFF_FFFF }
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var c = CRC32()
        c.update(bytes)
        return c.checksum
    }

    /// Names a file by what is in it, not by where it came from.
    ///
    /// Size and CRC together: same token means same length and same
    /// checksum, which is as strong a claim as the checksum itself and
    /// costs nothing extra, since `file.end` needs the CRC anyway. A path
    /// or a modification date would be cheaper and would both lie — an
    /// edited file keeps its path, and a touched one keeps its bytes.
    ///
    /// Collisions are possible in principle. The consequence is bounded:
    /// the receiver verifies the whole file against this same CRC before
    /// accepting it, so a collision costs a wasted transfer, never a
    /// corrupt file.
    static func resumeToken(for bytes: Data) -> String {
        token(bytes: bytes.count, crc32: crc32(bytes))
    }

    /// The same token from a checksum already computed. A caller that
    /// needs the CRC anyway must not pay for a second pass over the
    /// whole file to get the token as well.
    static func token(bytes: Int, crc32: UInt32) -> String {
        String(format: "%d-%08x", bytes, crc32)
    }
}
