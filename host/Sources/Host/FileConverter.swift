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

/// Classic Mac epoch (1904-01-01) to Foundation's.
enum ClassicDate {
    private static let offset: TimeInterval = 2_082_844_800

    static func date(from macSeconds: Int) -> Date? {
        guard macSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(macSeconds) - offset)
    }
}
