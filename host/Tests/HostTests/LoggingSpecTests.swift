import Foundation
import XCTest
@testable import Host

/// The rules docs/logging.md states, checked where they can be.
final class LoggingSpecTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `HH:MM:SS area   [!?] message` — the same shape on both machines,
    /// because the point of the format is that the two files read as one.
    @MainActor
    func testALineMatchesTheFormatTheSpecDefines() throws {
        let log = HostLog.shared
        log.setPersistsToDisk(true)             // the file is a switch now
        let url = try XCTUnwrap(log.url)
        log.write(.warn, "files", "#7 refused: exists (something is there)")
        let line = try XCTUnwrap(
            String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").last.map(String.init))

        let pattern = #"^\d{2}:\d{2}:\d{2} \w+\s+\? #7 refused: exists"#
        XCTAssertNotNil(line.range(of: pattern, options: .regularExpression),
                        "line did not match the spec's format: \(line)")
    }

    /// Rule 2, and the only rule that breaks things silently rather than
    /// loudly: a log call in a per-chunk path costs a disk write per
    /// chunk and starves the transfer it is measuring. The File Sharing
    /// panel proved it by doing exactly that with a progress bar.
    func testNothingLogsInAPerChunkPath() throws {
        let hot = [
            ("guest/src/wire.c", "take_bulk_in"),
            ("guest/src/fileshare.c", "now_files_receive_chunk"),
            ("guest/src/fileshare.c", "batch_write"),
        ]
        for (file, function) in hot {
            let text = try String(
                contentsOf: Self.repoRoot.appendingPathComponent(file),
                encoding: .utf8)
            let body = try XCTUnwrap(functionBody(named: function, in: text),
                                     "could not find \(function) in \(file)")
            XCTAssertFalse(body.contains("now_log("), """
                \(function) runs once per chunk. A log call there is a \
                disk write per chunk, which starves the transfer it is \
                measuring — see docs/logging.md, "What to log".
                """)
        }
    }

    /// Braces-balanced body of a C function, so the check reads the
    /// function rather than a window of lines around its name.
    ///
    /// It must find the DEFINITION, not a forward declaration: taking
    /// the first mention found the `static void take_bulk_in(...);`
    /// prototype and then measured the next function's body instead —
    /// green, and about the wrong code. A definition is the one whose
    /// parameter list is followed by `{` rather than `;`.
    private func functionBody(named name: String, in text: String) -> String? {
        var searchFrom = text.startIndex
        var open: Range<String.Index>?
        while let start = text.range(of: "\(name)(",
                                     range: searchFrom..<text.endIndex) {
            searchFrom = start.upperBound
            // Skip to the end of the parameter list.
            var depth = 1
            var i = start.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "(" { depth += 1 }
                if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            }
            // Then the next meaningful character decides which it is.
            while i < text.endIndex, text[i].isWhitespace {
                i = text.index(after: i)
            }
            guard i < text.endIndex else { break }
            if text[i] == "{" {
                open = i..<text.index(after: i)
                break
            }
        }
        guard let open else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[open.lowerBound...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
