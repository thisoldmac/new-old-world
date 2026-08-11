import Foundation

/// Projects this Mac's file names into names a classic Mac can hold, and
/// resolves them back to the files they came from.
///
/// HFS allows 31 MacRoman bytes and forbids the colon. Everything this
/// file system permits beyond that — length, arbitrary Unicode, colons —
/// must still be listable *and addressable*: a name the listing shows is
/// a name file.get must accept back, or the listing advertises files the
/// other machine cannot have. So projection is deterministic and
/// stateless, and resolution re-projects the real directory instead of
/// remembering a mapping that could drift or be lost.
///
/// The mangled shape is the one classic Mac OS itself used when its
/// 31-character APIs met an HFS+ long name: stem truncated, "#" and a
/// hex fingerprint of the whole original name, extension kept. A person
/// of the era has seen names like this. A name that already fits travels
/// unchanged — apart from Unicode composition, which this file system
/// stores decomposed and MacRoman cannot spell.
enum ClassicName {
    /// HFS's cap, in MacRoman bytes — not Swift characters and not UTF-8
    /// bytes. An accented character is two UTF-8 bytes and one MacRoman
    /// byte, so counting the wire's encoding refuses names the other
    /// machine holds happily.
    static let maxBytes = 31

    /// One name, projected without directory context. A lossless name
    /// returns itself composed; a lossy one carries a four-hex-digit
    /// fingerprint of the full original, so two long names that agree
    /// for 31 bytes stay distinct and a rename visibly changes the
    /// projection.
    static func project(_ name: String) -> String {
        passthrough(name) ?? fingerprinted(name, digits: 4)
    }

    /// A whole directory at once, which is the form the share uses: with
    /// every name in hand, a projection that collides with another entry
    /// (case-insensitively — HFS is) widens its fingerprint instead of
    /// silently naming two files the same thing. Names that fit as-is
    /// are never altered; only mangled names give way.
    static func projectDirectory(_ names: [String]) -> [String: String] {
        var classicByReal: [String: String] = [:]
        var claimed = Set<String>()
        var lossy: [String] = []
        for name in names {
            if let clean = passthrough(name) {
                classicByReal[name] = clean
                claimed.insert(clean.lowercased())
            } else {
                lossy.append(name)
            }
        }
        /* Sorted so which entry widens on a collision does not depend on
           enumeration order: the same directory always projects the same
           way. */
        for name in lossy.sorted(by: {
            $0.precomposedStringWithCanonicalMapping
                < $1.precomposedStringWithCanonicalMapping
        }) {
            var candidate = fingerprinted(name, digits: 4)
            for digits in [8, 16]
                where claimed.contains(candidate.lowercased()) {
                candidate = fingerprinted(name, digits: digits)
            }
            classicByReal[name] = candidate
            claimed.insert(candidate.lowercased())
        }
        return classicByReal
    }

    /// The real name a classic spelling refers to, or nil if nothing in
    /// the directory projects to it. Comparison is on composed forms:
    /// the classic side sends what it was shown, but what it was shown
    /// came through MacRoman and back.
    static func resolve(_ classic: String, among names: [String])
        -> String? {
        let want = classic.precomposedStringWithCanonicalMapping
        let map = projectDirectory(names)
        for name in names
            where map[name]?.precomposedStringWithCanonicalMapping
                == want {
            return name
        }
        return nil
    }

    // MARK: - The projection itself

    /// The composed name when it is already one the other machine can
    /// hold, nil when projecting must change it.
    private static func passthrough(_ name: String) -> String? {
        let nfc = name.precomposedStringWithCanonicalMapping
        guard !nfc.isEmpty, !nfc.contains(":"), !nfc.hasPrefix("."),
              let bytes = nfc.data(using: .macOSRoman),
              bytes.count <= maxBytes else { return nil }
        return nfc
    }

    private static func fingerprinted(_ name: String, digits: Int)
        -> String {
        let nfc = name.precomposedStringWithCanonicalMapping
        guard !nfc.isEmpty else { return "Untitled" }
        var base = nfc.replacingOccurrences(of: ":", with: "-")
        if base.hasPrefix(".") { base = "_" + base.dropFirst() }
        base = String(String.UnicodeScalarView(base.unicodeScalars.map {
            String($0).data(using: .macOSRoman) != nil ? $0 : "_"
        }))

        let mark = "#" + fingerprint(of: nfc, digits: digits)
        let ext = (base as NSString).pathExtension
        let keepExt = !ext.isEmpty && ext.count <= 10
        let stem = keepExt ? (base as NSString).deletingPathExtension : base
        let tail = keepExt ? mark + "." + ext : mark
        /* Truncation happens in MacRoman bytes, because that is the unit
           the limit is stated in. Every byte decodes, so slicing cannot
           produce an invalid name the way slicing UTF-8 can. */
        let tailBytes = tail.data(using: .macOSRoman)!
        let stemBytes = stem.data(using: .macOSRoman)!
        let room = max(0, maxBytes - tailBytes.count)
        let kept = String(data: stemBytes.prefix(room),
                          encoding: .macOSRoman) ?? ""
        return kept + tail
    }

    /// Four, eight or sixteen hex digits of the composed original.
    /// CRC-32 covers the first two widths; the third — needed only when
    /// whole CRC-32s collide inside one directory — switches to FNV-64
    /// rather than pretending CRC-32 has more bits than it has.
    private static func fingerprint(of nfc: String, digits: Int)
        -> String {
        if digits <= 8 {
            let crc = TransferIdentity.crc32(Data(nfc.utf8))
            let mask: UInt32 = digits >= 8
                ? .max : (1 << (4 * UInt32(digits))) - 1
            return String(format: "%0\(digits)X", crc & mask)
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in nfc.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llX", hash)
    }
}
