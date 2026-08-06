import Foundation

/// The host's half of scene deltas: hold the last whole document as a set
/// of byte ranges, rebuild the next one from a delta, and refuse to
/// publish a rebuild whose digest is not the one the guest published.
///
/// **Nothing here touches `MirrorReplicaReducer` or `MirrorStateEngine`,
/// and that is the design.** A delta is applied at the DOCUMENT level: it
/// produces exactly the bytes the guest would have sent whole, and those
/// bytes then go through the same decoder and the same reducer a whole
/// scene has always gone through. So the coverage rule that decides what
/// may be deleted stays in one place, unchanged, and a delta cannot
/// become a second, contradictory way to remove state. Patching the
/// replica directly would have needed a second deletion rule, in a second
/// place, that had to agree with the first forever.
///
/// The other half of the argument is the digest. After applying, we hash
/// the rebuilt body over the exactly-specified range the contract names.
/// If it equals `scene.begin`'s `digest`, we hold **byte for byte** the
/// document the guest would have sent — not "probably in sync". If it
/// does not, we discard the rebuild, publish nothing, and ask again
/// without a baseline. See docs/scene-deltas.md.
enum MirrorSceneDelta {

    // MARK: - Errors

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notAnObject
        case missingKey(String)
        case malformed(String)
        /// A `k`-only entry naming a key we do not hold. A provable
        /// producer or transport fault, and the cheapest of these to
        /// catch — it needs no hashing.
        case unknownKey(String)
        case noBaseline
        case baselineMismatch(asked: String, answered: String)
        case digestMismatch(expected: String, computed: String)

        var description: String {
            switch self {
            case .notAnObject: return "the document is not a JSON object"
            case .missingKey(let k): return "the document has no \(k)"
            case .malformed(let w): return "malformed JSON: \(w)"
            case .unknownKey(let k):
                return "the delta reuses \(k), which this consumer does not hold"
            case .noBaseline: return "a delta arrived with no baseline held"
            case .baselineMismatch(let a, let b):
                return "the delta is against \(b); we asked about \(a)"
            case .digestMismatch(let e, let c):
                return "the rebuilt scene hashes \(c); the guest published \(e)"
            }
        }
    }

    // MARK: - The baseline

    /// One entity's bytes and the key it is addressed by.
    struct Entity: Equatable {
        var key: String
        var bytes: [UInt8]
    }

    /// The last whole document, kept as the pieces a delta names rather
    /// than as a parsed model. Keeping BYTES is what makes the rebuild
    /// byte-exact; a re-serialised model would agree in meaning and
    /// disagree in bytes, and the digest is over bytes.
    struct Baseline: Equatable {
        var digest: String
        /// The document's own `version` bytes, kept so a scene.same can
        /// be republished as a whole document without a second walk.
        var version: [UInt8]
        /// The ENVELOPE's major from the scene.begin that carried this
        /// document. Kept beside the body's own stamp rather than derived
        /// from it: the gate that refuses an unknown major reads the
        /// envelope, and a republished scene must present the same number
        /// it was admitted under.
        var irVersion: Int = 2
        var screen: [UInt8]
        var source: [UInt8]
        var apps: [Entity]
        var processes: [Entity]
        var menubar: [UInt8]?
        var windows: [Entity]
        var coverage: [UInt8]
        var errors: [UInt8]
        /// Everything `meta` carries after `coverage` — plane, latencyMs,
        /// phases. Restated verbatim so the rebuilt meta is the meta a
        /// whole document would have carried, and excluded from the
        /// digest because phases move on every walk.
        var metaTail: [UInt8]
    }

    // MARK: - Digest

    /// FNV-1a/32 over the contract's fixed region order. The guest
    /// computes the same number over the same bytes; scene_digest.c is
    /// the other implementation and `scene_digest_test.c` pins the
    /// function against its published vectors on that side.
    static func digest(of b: Baseline) -> String {
        var h: UInt32 = 2_166_136_261
        func fold(_ bytes: [UInt8]) {
            for byte in bytes {
                h ^= UInt32(byte)
                h = h &* 16_777_619
            }
        }
        fold(b.screen)
        fold(b.source)
        fold(joinArray(b.apps))
        fold(joinArray(b.processes))
        // An absent menu bar hashes to something a present-but-empty one
        // cannot collide with: "no menubar reported" and "menubar present
        // with no menus" are different claims about the machine.
        fold(b.menubar ?? Array("-".utf8))
        fold(joinArray(b.windows))
        fold(b.coverage)
        fold(b.errors)
        return String(format: "%08x", h)
    }

    private static func joinArray(_ items: [Entity]) -> [UInt8] {
        var out: [UInt8] = [UInt8(ascii: "[")]
        for (i, item) in items.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out.append(contentsOf: item.bytes)
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    // MARK: - Slicing a whole document

    /// Takes a whole IR document apart into the pieces a delta can name.
    /// Fails rather than guessing: a document we cannot slice is a
    /// document we cannot be a delta consumer for, and the honest
    /// consequence is that the next request omits `since`.
    static func slice(whole document: Data) throws -> Baseline {
        let bytes = [UInt8](document)
        let members = try JSONSpan.members(bytes, in: try JSONSpan.wholeObject(bytes))

        func region(_ key: String) throws -> [UInt8] {
            guard let r = members[key] else { throw Failure.missingKey(key) }
            return Array(bytes[r])
        }
        func entities(_ key: String) throws -> [Entity] {
            guard let r = members[key] else { throw Failure.missingKey(key) }
            return try JSONSpan.elements(bytes, in: r).map { element in
                let sub = Array(bytes[element])
                guard let k = JSONSpan.stringMember(sub, "incarnation") else {
                    // A row with no incarnation is a row the reducer will
                    // not key either. We refuse the whole baseline rather
                    // than invent one, exactly as the guest does.
                    throw Failure.malformed("a \(key) row carries no incarnation")
                }
                return Entity(key: k, bytes: sub)
            }
        }

        guard let metaRange = members["meta"] else { throw Failure.missingKey("meta") }
        let metaMembers = try JSONSpan.members(bytes, in: metaRange)
        guard let errors = metaMembers["errors"],
              let coverage = metaMembers["coverage"] else {
            throw Failure.missingKey("meta.errors/meta.coverage")
        }
        // meta is emitted errors-then-coverage-then-the-rest; the rest is
        // one contiguous span from the end of coverage to the closing
        // brace, which is what makes it restatable verbatim.
        guard coverage.upperBound <= metaRange.upperBound - 1 else {
            throw Failure.malformed("meta ends before coverage does")
        }
        let tail = Array(bytes[coverage.upperBound..<(metaRange.upperBound - 1)])

        var baseline = Baseline(
            digest: "",
            version: try region("version"),
            screen: try region("screen"),
            source: try region("source"),
            apps: try entities("apps"),
            processes: try entities("processes"),
            menubar: members["menubar"].map { Array(bytes[$0]) },
            windows: try entities("windows"),
            coverage: Array(bytes[coverage]),
            errors: Array(bytes[errors]),
            metaTail: tail)
        baseline.digest = digest(of: baseline)
        return baseline
    }

    // MARK: - Applying a delta

    struct Applied {
        var document: Data
        var baseline: Baseline
    }

    /// Republishes the baseline as a whole document at a new moment. This
    /// is what a `scene.same` becomes: the same picture of the machine,
    /// newer, which is exactly what `capturedAt` has always meant.
    static func republish(_ b: Baseline, seq: Int, capturedAt: Double) -> Data {
        assemble(b, seq: Array("\(seq)".utf8),
                 capturedAt: Array(String(format: "%.1f", capturedAt).utf8))
    }

    /// Rebuilds the whole document a delta describes, and proves it.
    ///
    /// `expected` is `scene.begin`'s `digest`. It is checked LAST and it
    /// is checked always: everything before it can be right and the
    /// result still be wrong, which is exactly why the number is on the
    /// wire.
    static func apply(delta: Data, to baseline: Baseline?,
                      askedBaseline: String, expected: String?) throws -> Applied {
        guard let baseline else { throw Failure.noBaseline }
        let bytes = [UInt8](delta)
        let members = try JSONSpan.members(bytes, in: try JSONSpan.wholeObject(bytes))

        if let answered = JSONSpan.stringMember(bytes, "baseline"),
           answered != askedBaseline {
            throw Failure.baselineMismatch(asked: askedBaseline, answered: answered)
        }
        func region(_ key: String) throws -> [UInt8] {
            guard let r = members[key] else { throw Failure.missingKey(key) }
            return Array(bytes[r])
        }
        func plane(_ key: String, _ held: [Entity]) throws -> [Entity] {
            guard let r = members[key] else { throw Failure.missingKey(key) }
            return try JSONSpan.elements(bytes, in: r).map { entry in
                let sub = Array(bytes[entry])
                guard let k = JSONSpan.stringMember(sub, "k") else {
                    throw Failure.malformed("a \(key) entry names no key")
                }
                if let v = try JSONSpan.members(sub, in: 0..<sub.count)["v"] {
                    return Entity(key: k, bytes: Array(sub[v]))
                }
                guard let kept = held.first(where: { $0.key == k }) else {
                    throw Failure.unknownKey(k)
                }
                return kept
            }
        }

        guard let metaRange = members["meta"] else { throw Failure.missingKey("meta") }
        let metaMembers = try JSONSpan.members(bytes, in: metaRange)
        guard let errors = metaMembers["errors"],
              let coverage = metaMembers["coverage"] else {
            throw Failure.missingKey("meta.errors/meta.coverage")
        }
        let tail = Array(bytes[coverage.upperBound..<(metaRange.upperBound - 1)])

        // The menu bar is one entity, so it is one of three words.
        var menubar: [UInt8]?
        if let m = members["menubar"] {
            let sub = Array(bytes[m])
            let inner = try JSONSpan.members(sub, in: 0..<sub.count)
            if let v = inner["v"] {
                menubar = Array(sub[v])
            } else if inner["absent"] != nil {
                menubar = nil
            } else {
                menubar = baseline.menubar
            }
        } else {
            menubar = baseline.menubar
        }

        var rebuilt = Baseline(
            digest: "",
            version: try region("version"),
            screen: try region("screen"),
            source: try region("source"),
            apps: try plane("apps", baseline.apps),
            processes: try plane("processes", baseline.processes),
            menubar: menubar,
            windows: try plane("windows", baseline.windows),
            coverage: Array(bytes[coverage]),
            errors: Array(bytes[errors]),
            metaTail: tail)
        rebuilt.digest = digest(of: rebuilt)

        if let expected, expected != rebuilt.digest {
            throw Failure.digestMismatch(expected: expected, computed: rebuilt.digest)
        }

        guard let seq = members["seq"], let at = members["capturedAt"],
              let version = members["version"] else {
            throw Failure.missingKey("version/seq/capturedAt")
        }
        _ = version
        return Applied(
            document: assemble(rebuilt,
                               seq: Array(bytes[seq]),
                               capturedAt: Array(bytes[at])),
            baseline: rebuilt)
    }

    /// Writes the whole document out of the pieces, in the guest's own
    /// field order. Only the SCALAR head comes from the delta; every
    /// region below it is bytes that were either kept or carried, never
    /// re-serialised.
    static func assemble(_ b: Baseline, seq: [UInt8],
                         capturedAt: [UInt8]) -> Data {
        var out: [UInt8] = []
        out.append(contentsOf: Array("{\"version\":".utf8))
        out.append(contentsOf: b.version)
        out.append(contentsOf: Array(",\"seq\":".utf8))
        out.append(contentsOf: seq)
        out.append(contentsOf: Array(",\"capturedAt\":".utf8))
        out.append(contentsOf: capturedAt)
        out.append(contentsOf: Array(",\"source\":".utf8))
        out.append(contentsOf: b.source)
        out.append(contentsOf: Array(",\"screen\":".utf8))
        out.append(contentsOf: b.screen)
        out.append(contentsOf: Array(",\"apps\":".utf8))
        out.append(contentsOf: joinArray(b.apps))
        out.append(contentsOf: Array(",\"processes\":".utf8))
        out.append(contentsOf: joinArray(b.processes))
        if let menubar = b.menubar {
            out.append(contentsOf: Array(",\"menubar\":".utf8))
            out.append(contentsOf: menubar)
        }
        out.append(contentsOf: Array(",\"windows\":".utf8))
        out.append(contentsOf: joinArray(b.windows))
        out.append(contentsOf: Array(",\"meta\":{\"errors\":".utf8))
        out.append(contentsOf: b.errors)
        out.append(contentsOf: Array(",\"coverage\":".utf8))
        out.append(contentsOf: b.coverage)
        out.append(contentsOf: b.metaTail)
        out.append(contentsOf: Array("}}".utf8))
        return Data(out)
    }
}

/// A structural JSON scanner — ranges, not values.
///
/// It exists because the digest is over BYTES: a `JSONSerialization`
/// round trip agrees about meaning and disagrees about bytes, which would
/// make every rebuild fail its own check. So this walks the text and
/// hands back where things are, and the bytes are never re-encoded.
extension MirrorSceneDelta.Baseline {
    /// `source` as the IR carries it, quotes removed.
    var sourceText: String {
        let text = String(decoding: source, as: UTF8.self)
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }
}

enum JSONSpan {
    static func wholeObject(_ b: [UInt8]) throws -> Range<Int> {
        var i = 0
        while i < b.count, isSpace(b[i]) { i += 1 }
        guard i < b.count, b[i] == UInt8(ascii: "{") else {
            throw MirrorSceneDelta.Failure.notAnObject
        }
        return i..<b.count
    }

    /// Top-level members of the object beginning at `range.lowerBound`,
    /// as key → the byte range of the value.
    static func members(_ b: [UInt8], in range: Range<Int>) throws -> [String: Range<Int>] {
        var out: [String: Range<Int>] = [:]
        var i = range.lowerBound
        guard i < range.upperBound, b[i] == UInt8(ascii: "{") else {
            throw MirrorSceneDelta.Failure.notAnObject
        }
        i += 1
        while i < range.upperBound {
            skipSpace(b, &i, range.upperBound)
            if i < range.upperBound, b[i] == UInt8(ascii: "}") { break }
            if i < range.upperBound, b[i] == UInt8(ascii: ",") { i += 1; continue }
            guard i < range.upperBound, b[i] == UInt8(ascii: "\"") else {
                throw MirrorSceneDelta.Failure.malformed("expected a key")
            }
            let keyRange = try value(b, &i, range.upperBound)
            let key = decodeASCII(b, keyRange)
            skipSpace(b, &i, range.upperBound)
            guard i < range.upperBound, b[i] == UInt8(ascii: ":") else {
                throw MirrorSceneDelta.Failure.malformed("expected a colon after \(key)")
            }
            i += 1
            skipSpace(b, &i, range.upperBound)
            out[key] = try value(b, &i, range.upperBound)
        }
        return out
    }

    /// Elements of the array whose value range is `range`.
    static func elements(_ b: [UInt8], in range: Range<Int>) throws -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = range.lowerBound
        guard i < range.upperBound, b[i] == UInt8(ascii: "[") else {
            throw MirrorSceneDelta.Failure.malformed("expected an array")
        }
        i += 1
        while i < range.upperBound {
            skipSpace(b, &i, range.upperBound)
            if i < range.upperBound, b[i] == UInt8(ascii: "]") { break }
            if i < range.upperBound, b[i] == UInt8(ascii: ",") { i += 1; continue }
            out.append(try value(b, &i, range.upperBound))
        }
        return out
    }

    /// A top-level string member of a small object, by key. Nested
    /// occurrences are not found, which is the point: a window's own
    /// `incarnation` must never be confused with one inside it.
    static func stringMember(_ b: [UInt8], _ key: String) -> String? {
        guard let range = try? wholeObject(b),
              let m = try? members(b, in: range),
              let v = m[key], v.count >= 2, b[v.lowerBound] == UInt8(ascii: "\"")
        else { return nil }
        return decodeASCII(b, v)
    }

    // MARK: -

    /// Consumes one JSON value starting at `i` and returns its range,
    /// leaving `i` just past it.
    private static func value(_ b: [UInt8], _ i: inout Int, _ end: Int) throws -> Range<Int> {
        let start = i
        guard i < end else { throw MirrorSceneDelta.Failure.malformed("value ran off the end") }
        switch b[i] {
        case UInt8(ascii: "\""):
            i += 1
            while i < end {
                if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                if b[i] == UInt8(ascii: "\"") { i += 1; return start..<i }
                i += 1
            }
            throw MirrorSceneDelta.Failure.malformed("unterminated string")
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var inString = false
            while i < end {
                let c = b[i]
                if inString {
                    if c == UInt8(ascii: "\\") { i += 2; continue }
                    if c == UInt8(ascii: "\"") { inString = false }
                } else if c == UInt8(ascii: "\"") {
                    inString = true
                } else if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                    depth += 1
                } else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { i += 1; return start..<i }
                }
                i += 1
            }
            throw MirrorSceneDelta.Failure.malformed("unbalanced object or array")
        default:
            while i < end, !isDelimiter(b[i]) { i += 1 }
            guard i > start else { throw MirrorSceneDelta.Failure.malformed("empty value") }
            return start..<i
        }
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d
    }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        c == UInt8(ascii: ",") || c == UInt8(ascii: "}") || c == UInt8(ascii: "]")
            || isSpace(c)
    }

    private static func skipSpace(_ b: [UInt8], _ i: inout Int, _ end: Int) {
        while i < end, isSpace(b[i]) { i += 1 }
    }

    /// A quoted span as a Swift string, quotes stripped. Keys and
    /// incarnations are ASCII by contract; anything else is not a key we
    /// would match anyway.
    private static func decodeASCII(_ b: [UInt8], _ r: Range<Int>) -> String {
        var inner = r
        if b[r.lowerBound] == UInt8(ascii: "\"") {
            inner = (r.lowerBound + 1)..<(r.upperBound - 1)
        }
        return String(decoding: b[inner], as: UTF8.self)
    }
}
