import Foundation

/// Turns a file the guest sent into the file a Mac user wants on disk.
/// Registry-shaped rather than a pile of special cases: PICT→PNG and
/// friends become registrants later without touching transfer code.
///
/// The container rule lives on the guest (data-only ships plain,
/// resource-only ships MacBinary); the host's job is what happens to
/// the bytes afterwards — today, text.
enum FileConverter {
    struct Converted {
        var name: String
        var data: Data
        /// What happened, for the browser's badge and the transfer log.
        var note: String?
    }

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

    /// Converts a delivered file. MacBinary passes through untouched (it
    /// is the honest container for a forked artifact); text gets
    /// MacRoman→UTF-8 and CR→LF; everything else is the raw data fork.
    static func convert(name: String, container: String,
                        fileType: String?, bytes: Data) -> Converted {
        if container == "macbinary" {
            let base = (name as NSString).deletingPathExtension
            let suffixed = name.lowercased().hasSuffix(".bin")
                ? name : "\(base).bin"
            return Converted(name: suffixed, data: bytes,
                             note: "MacBinary (both forks)")
        }
        guard isText(fileType: fileType, name: name),
              let text = String(data: bytes, encoding: .macOSRoman) else {
            return Converted(name: name, data: bytes, note: nil)
        }
        let converted = normalizeLineEndings(text)
        return Converted(name: text.isEmpty ? name : name,
                         data: Data(converted.utf8),
                         note: "MacRoman → UTF-8, CR → LF")
    }

    /// Classic Mac text uses CR line endings; normalize CRLF first so a
    /// file that already came from a modern editor is not doubled.
    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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
        /// What was done, for the badge and the transfer log.
        var note: String?
    }

    /// HFS allows 31 characters, forbids colons (its path separator),
    /// and stores names in MacRoman. Truncation keeps the extension,
    /// because that is what both sides use to recognise the file.
    static func hfsName(_ name: String) -> String {
        var base = name.replacingOccurrences(of: ":", with: "-")
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
        let original = url.lastPathComponent
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

    /// MacBinary II/III: a zero at 0 and 74, a plausible name length,
    /// and the version bytes. Cheap, and wrong only for files that went
    /// out of their way to look like one.
    static func looksLikeMacBinary(_ data: Data) -> Bool {
        guard data.count >= 128 else { return false }
        let b = [UInt8](data.prefix(128))
        return b[0] == 0 && b[74] == 0 && b[1] >= 1 && b[1] <= 63
            && (b[122] == 129 || b[122] == 130)
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
}
