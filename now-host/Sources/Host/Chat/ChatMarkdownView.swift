import AppKit
import SwiftUI

/* Blocks drawn. Inline spans are Foundation's job — `AttributedString`
   already parses emphasis, links and inline code — so this file only
   owns what Foundation will not do: the vertical rhythm between
   blocks, and code that reads as code. No syntax highlighting: a
   tokenizer per language is a dependency this package does not take,
   and monospace on a settled background is most of the win. */

struct ChatMarkdownText: View {
    let source: String
    /// The blocks a person can copy. A fence still streaming has no
    /// copy button, because half a program is a trap in a pasteboard.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.parse(source).enumerated()),
                    id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .lineSpacing(2)
                .textSelection(.enabled)
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .textSelection(.enabled)
                .padding(.top, 2)
        case .bullets(let items):
            list(items.map { (marker: "•", text: $0) })
        case .numbered(let start, let items):
            list(items.enumerated().map {
                (marker: "\(start + $0.offset).", text: $0.element)
            })
        case .code(let language, let text, let closed):
            ChatCodeBlock(language: language, code: text, complete: closed)
        case .quote(let lines):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.quaternary)
                    .frame(width: 3)
                inline(lines.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    private func list(
        _ rows: [(marker: String, text: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(row.marker)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    inline(row.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func inline(_ text: String) -> Text {
        Text(ChatMarkdownInline.attributed(text))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}

enum ChatMarkdownInline {
    /// Emphasis, links and inline code, with code given a monospaced
    /// face — the one attribute Foundation marks but does not style.
    /// A source it cannot parse comes back as itself: an answer half
    /// through an unbalanced `**` must still be readable.
    static func attributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var text = try? AttributedString(
            markdown: source, options: options)
        else { return AttributedString(source) }
        let coded = text.runs.filter {
            $0.inlinePresentationIntent?.contains(.code) == true
        }.map(\.range)
        for range in coded {
            text[range].font = .system(.body, design: .monospaced)
        }
        return text
    }
}

/// A fenced block: language on a quiet bar, a copy button that says it
/// worked, and the code itself scrolling horizontally rather than
/// wrapping — wrapped code lies about its own indentation.
struct ChatCodeBlock: View {
    let language: String?
    let code: String
    let complete: Bool

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if complete {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied
                                  ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy this code")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.4))
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary))
    }
}
