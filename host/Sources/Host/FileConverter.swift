import Foundation

/// Turns a file the guest sent into the file a Mac user wants on disk.
/// Registry-shaped rather than a pile of special cases: PICT→PNG and
/// friends become registrants later without touching transfer code.
///
/// The container rule lives on the guest (data-only ships plain,
/// resource-only ships MacBinary); the host's job is what happens to
/// the bytes afterwards — today, text.
enum FileConverter {
    /// Classic type codes that are text regardless of extension.
    private static let textTypes: Set<String> = ["TEXT", "ttro", "utxt"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "c", "h", "cpp", "m", "r", "rsrc.txt", "json",
        "xml", "html", "htm", "css", "js", "md", "log", "ini", "cfg",
        "sh", "py", "swift", "yaml", "yml", "csv", "tsv", "readme",
    ]

    static func isText(fileType: String?, name: String) -> Bool {
        if let fileType, textTypes.contains(fileType) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty && textExtensions.contains(ext) { return true }
        // Extension-less README/ChangeLog style names on the classic side.
        return fileType == nil && ext.isEmpty
            && ["read me", "readme", "changelog"].contains(
                name.lowercased())
    }

    /// Describes what a pull will do, for the UI badge — computed from
    /// the listing alone, before any bytes move.
    static func plan(fileType: String?, name: String,
                     container: String) -> String? {
        if container == "macbinary" { return "MacBinary" }
        if isText(fileType: fileType, name: name) {
            return "converts text"
        }
        return nil
    }

    static func outputName(name: String, container: String) -> String {
        guard container == "macbinary",
              !name.lowercased().hasSuffix(".bin") else { return name }
        let base = (name as NSString).deletingPathExtension
        return "\(base).bin"
    }

    /// Writes a staged inbound transfer without reconstructing the whole
    /// file in memory. The destination appears only after the complete
    /// source has been copied or converted and synchronized.
    @discardableResult
    static func materialize(
        name: String, container: String, fileType: String?,
        staged: InboundFileSink.StagedFile, to destination: URL
    ) throws -> String? {
        let source = staged.url
        let parent = destination.deletingLastPathComponent()
        let isTextFile = container != "macbinary"
            && isText(fileType: fileType, name: name)

        /* The common binary case is already a same-folder temp, so a
           rename is the whole finalization and is atomic on this volume. */
        if !isTextFile,
           source.deletingLastPathComponent().standardizedFileURL
            == parent.standardizedFileURL {
            try FileManager.default.moveItem(at: source, to: destination)
            staged.relinquish()
            return container == "macbinary"
                ? "MacBinary (both forks)" : nil
        }

        let multiplier = isTextFile ? 3 : 1
        let required = staged.byteCount.multipliedReportingOverflow(
            by: multiplier)
        guard !required.overflow else {
            throw InboundFileSink.SinkError.invalidLength
        }
        try InboundFileSink.requireAvailableSpace(
            in: parent, bytes: required.partialValue)

        let temporary = parent.appendingPathComponent(
            ".now-\(UUID().uuidString).convert")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var keepTemporary = true
        defer {
            if keepTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            if isTextFile {
                try streamClassicText(from: input, to: output)
            } else {
                while true {
                    let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
            try input.close()
            try output.close()
            try FileManager.default.moveItem(at: temporary, to: destination)
            keepTemporary = false
            staged.discard()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }
        return isTextFile ? "MacRoman → UTF-8, CR → LF"
            : (container == "macbinary" ? "MacBinary (both forks)" : nil)
    }

    /// MacRoman is single-byte, so conversion can split anywhere except
    /// the CRLF pair. Normalize one bounded chunk in memory and write it
    /// once; line-dense files must not turn into one syscall per line.
    private static func streamClassicText(
        from input: FileHandle, to output: FileHandle
    ) throws {
        var pendingCR = false

        while true {
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            var normalized = Data()
            normalized.reserveCapacity(chunk.count + 1)
            for byte in chunk {
                if pendingCR {
                    normalized.append(0x0A)
                    pendingCR = false
                    if byte == 0x0A {
                        continue       // CRLF is one line ending
                    }
                }
                if byte == 0x0D {
                    pendingCR = true
                    continue
                }
                normalized.append(byte)
            }
            guard let text = String(data: normalized,
                                    encoding: .macOSRoman) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            try output.write(contentsOf: Data(text.utf8))
        }
        if pendingCR {
            try output.write(contentsOf: Data([0x0A]))
        }
    }

    /// The other direction, for slice 2: LF/CRLF → CR, UTF-8 → MacRoman
    /// with unmappable characters substituted rather than refused.
    static func toClassicText(_ text: String) -> Data {
        let cr = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r")
        if let exact = cr.data(using: .macOSRoman) { return exact }
        return Data(cr.unicodeScalars.map { scalar -> UInt8 in
            let single = String(scalar)
            if let byte = single.data(using: .macOSRoman)?.first {
                return byte
            }
            return UInt8(ascii: "?")
        })
    }
}

/// Turning a modern file into one the classic Mac can hold: a name HFS
/// accepts, and bytes in the form that machine expects.
enum OutboundFile {
    struct Plan {
        var name: String
        var container: String       // "data" | "macbinary"
        var bytes: Data
        var fileType: String?
        var creator: String?
        /// Classic seconds since 1904, read while the file was. Asking
        /// the file system a second time for what we just had is a
        /// resolve and a stat for a number already in hand.
        var modified: Int?
        /// What was done, for the badge and the transfer log.
        var note: String?
    }

    /// HFS allows 31 characters, forbids colons (its path separator),
    /// and stores names in MacRoman. Truncation keeps the extension,
    /// because that is what both sides use to recognise the file.
    static func hfsName(_ name: String) -> String {
        /* This file system stores names DECOMPOSED: "café" is "cafe"
           plus a combining accent. MacRoman has the accented letter but
           not the combining mark, so mapping character by character
           turns every accented name into "cafe_" — a different name,
           silently. Composing first is what makes the round trip hold. */
        var base = name.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: ":", with: "-")
        if base.hasPrefix(".") { base = "_" + base.dropFirst() }
        base = String(base.unicodeScalars.map { scalar -> Character in
            String(scalar).data(using: .macOSRoman) != nil
                ? Character(scalar) : "_"
        })
        if base.utf8.count <= 31 { return base.isEmpty ? "Untitled" : base }

        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        if ext.isEmpty || ext.count > 10 {
            return String(base.prefix(31))
        }
        let room = 31 - ext.count - 1
        guard room > 0 else { return String(base.prefix(31)) }
        return String(stem.prefix(room)) + "." + ext
    }

    /// Chooses the container and converts the bytes. A .bin file is
    /// already MacBinary — it travels as-is and the guest rebuilds both
    /// forks from it, so the name sheds the extension it only ever wore
    /// to survive the trip out.
    static func plan(url: URL, data: Data, convertText: Bool) -> Plan {
        plan(name: url.lastPathComponent, data: data,
             convertText: convertText)
    }

    /// The approval lane has deliberately forgotten the original path by
    /// redemption time. Conversion needs only the approved leaf name and
    /// immutable bytes, so keep that narrower input shape explicit.
    static func plan(name original: String, data: Data,
                     convertText: Bool) -> Plan {
        if original.lowercased().hasSuffix(".bin"),
           looksLikeMacBinary(data) {
            let inner = (original as NSString).deletingPathExtension
            return Plan(name: hfsName(inner), container: "macbinary",
                        bytes: data, fileType: nil, creator: nil,
                        note: "MacBinary (both forks)")
        }
        if convertText, FileConverter.isText(fileType: nil, name: original),
           let text = String(data: data, encoding: .utf8) {
            return Plan(name: hfsName(original), container: "data",
                        bytes: FileConverter.toClassicText(text),
                        fileType: "TEXT", creator: "ttxt",
                        note: "UTF-8 → MacRoman, LF → CR")
        }
        let (type, creator) = classicType(for: original)
        return Plan(name: hfsName(original), container: "data", bytes: data,
                    fileType: type, creator: creator, note: nil)
    }

    /// Recognises MacBinary I as well as II and III. Requiring the II
    /// version byte rejected every MacBinary I file — which is most of
    /// what an archive site serves — and those then travelled as plain
    /// data, arriving on the classic side as a .bin document with no
    /// resource fork at all.
    ///
    /// The reliable test is not the version byte but the header's own
    /// arithmetic: the fork lengths, padded to 128, must account for the
    /// file. II and III also carry a CRC, which is checked when present.
    static func looksLikeMacBinary(_ data: Data) -> Bool {
        guard data.count >= 128 else { return false }
        return validMacBinaryHeader(
            Data(data.prefix(128)), totalBytes: data.count)
    }

    /// File-backed upload validation uses the same arithmetic without
    /// materializing the staged artifact on the main actor.
    static func validMacBinaryHeader(
        _ header: Data,
        totalBytes: Int
    ) -> Bool {
        guard header.count == 128 else { return false }
        let b = [UInt8](header)
        // Reserved bytes are zero in every version.
        guard b[0] == 0, b[74] == 0, b[82] == 0,
              b[1] >= 1, b[1] <= 63 else { return false }

        func be32(_ i: Int) -> Int {
            (Int(b[i]) << 24) | (Int(b[i + 1]) << 16)
                | (Int(b[i + 2]) << 8) | Int(b[i + 3])
        }
        let dataLen = be32(83)
        let rsrcLen = be32(87)
        guard dataLen >= 0, rsrcLen >= 0,
              dataLen < 0x7FFF_FFFF, rsrcLen < 0x7FFF_FFFF else {
            return false
        }
        func padded(_ n: Int) -> Int { (n + 127) / 128 * 128 }
        let expected = 128 + padded(dataLen) + padded(rsrcLen)
        // Some encoders append a little; none truncate.
        guard totalBytes >= expected, totalBytes - expected < 256 else {
            return false
        }
        if b[122] == 129 || b[122] == 130 {
            let stored = (UInt16(b[124]) << 8) | UInt16(b[125])
            return stored == crc16(b.prefix(124))
        }
        return true                    // MacBinary I: no CRC to check
    }

    /// CRC-16/XMODEM, as MacBinary II specifies.
    private static func crc16<C: Collection>(_ bytes: C) -> UInt16
        where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// Enough of a type map that a transferred file opens by
    /// double-click on the other side; unknown extensions stay generic
    /// rather than claiming something false.
    static func classicType(for name: String) -> (String?, String?) {
        switch (name as NSString).pathExtension.lowercased() {
        case "txt", "text", "md", "log": return ("TEXT", "ttxt")
        case "gif": return ("GIFf", "ogle")
        case "jpg", "jpeg": return ("JPEG", "ogle")
        case "png": return ("PNGf", "ogle")
        case "pict", "pct": return ("PICT", "ttxt")
        case "mov", "qt": return ("MooV", "TVOD")
        case "sit": return ("SIT!", "SIT!")
        case "zip": return ("ZIP ", "SITx")
        case "hqx": return ("TEXT", "SITx")
        default: return (nil, nil)
        }
    }
}

/// Classic Mac epoch (1904-01-01) to Foundation's.
enum ClassicDate {
    private static let offset: TimeInterval = 2_082_844_800

    static func date(from macSeconds: Int) -> Date? {
        guard macSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(macSeconds) - offset)
    }

    /// Foundation's epoch to the classic one, for files travelling the
    /// other way. Dates before 1904 (and any clock nonsense) come back
    /// nil rather than wrapping into a plausible-looking wrong date.
    static func macSeconds(from date: Date) -> Int? {
        let seconds = date.timeIntervalSince1970 + offset
        guard seconds > 0, seconds < 4_294_967_295 else { return nil }
        return Int(seconds)
    }

    /// The deployed classic guest reads optional file dates through
    /// `strtol` into a signed 32-bit `long`. Omit newer values rather
    /// than letting them saturate to January 1972 on receipt.
    static func guestWireSeconds(from date: Date) -> Int? {
        guard let seconds = macSeconds(from: date),
              seconds <= Int(Int32.max) else {
            return nil
        }
        return seconds
    }
}
