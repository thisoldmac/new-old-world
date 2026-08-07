import Foundation

/* Block-level Markdown, parsed here because a modern model answers in
   it and `Text` renders inline spans only — so a fenced code block
   arrived as three literal backticks and a heading as a hash.
   Deliberately small: the blocks an assistant actually emits, no
   dependency, no HTML, no reference links.

   Two properties matter more than coverage. It parses PARTIAL input,
   because every intermediate state of a streaming answer is drawn — an
   unterminated fence is a code block already, not a paragraph that
   starts with three backticks and turns into one later. And it never
   throws: anything it cannot classify stays a paragraph, so the worst
   failure is prose that renders as prose. */

enum ChatMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered(start: Int, items: [String])
    /// `closed` is false while a fence is still streaming — the copy
    /// button waits for a block that has finished arriving.
    case code(language: String?, text: String, closed: Bool)
    case quote([String])
    case rule
}

enum ChatMarkdown {
    static func parse(_ source: String) -> [ChatMarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let opener = fence(line) {
                flushParagraph()
                index += 1
                var body: [String] = []
                var closed = false
                while index < lines.count {
                    let candidate = lines[index]
                        .trimmingCharacters(in: .whitespaces)
                    if closes(candidate, opener: opener.marker) {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: opener.language,
                                    text: body.joined(separator: "\n"),
                                    closed: closed))
                continue
            }

            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Before the bullet test: "---" is a rule, "- x" an item.
            if isRule(line) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let head = heading(line) {
                flushParagraph()
                blocks.append(head)
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                        .trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var body = candidate.dropFirst()
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                    quoted.append(String(body))
                    index += 1
                }
                blocks.append(.quote(quoted))
                continue
            }

            if bullet(line) != nil {
                flushParagraph()
                var items: [String] = []
                gather(lines, &index, items: &items) { bullet($0) }
                blocks.append(.bullets(items))
                continue
            }

            if let first = numbered(line) {
                flushParagraph()
                var items: [String] = []
                gather(lines, &index, items: &items) { numbered($0)?.text }
                blocks.append(.numbered(start: first.number, items: items))
                continue
            }

            paragraph.append(raw)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Line classification

    /// Consecutive items of one list, plus their lazy continuations —
    /// a wrapped list item arrives indented under its own bullet, and
    /// reading it as a new paragraph broke the list in half.
    private static func gather(
        _ lines: [String], _ index: inout Int, items: inout [String],
        item: (String) -> String?
    ) {
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let text = item(line) {
                items.append(text)
                index += 1
                continue
            }
            let indented = raw.hasPrefix("  ") || raw.hasPrefix("\t")
            guard indented, !line.isEmpty, !items.isEmpty else { break }
            items[items.count - 1] += " " + line
            index += 1
        }
    }

    private static func fence(
        _ line: String
    ) -> (marker: Character, language: String?)? {
        for marker in ["```", "~~~"] {
            guard line.hasPrefix(marker) else { continue }
            let info = line.dropFirst(marker.count)
                .trimmingCharacters(in: .whitespaces)
            return (marker.first!, info.isEmpty ? nil : info)
        }
        return nil
    }

    private static func closes(_ line: String, opener: Character) -> Bool {
        let run = String(repeating: opener, count: 3)
        return line.hasPrefix(run)
            && line.allSatisfy { $0 == opener }
    }

    private static func isRule(_ line: String) -> Bool {
        let bare = line.filter { !$0.isWhitespace }
        guard bare.count >= 3, let first = bare.first,
            "-*_".contains(first)
        else { return false }
        return bare.allSatisfy { $0 == first }
    }

    private static func heading(_ line: String) -> ChatMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return .heading(
            level: hashes.count,
            text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> String? {
        guard let first = line.first, "-*+".contains(first),
            line.dropFirst().hasPrefix(" ")
        else { return nil }
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func numbered(
        _ line: String
    ) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9,
            let number = Int(digits)
        else { return nil }
        var rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")"
        else { return nil }
        rest = rest.dropFirst()
        guard rest.hasPrefix(" ") else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }
}
