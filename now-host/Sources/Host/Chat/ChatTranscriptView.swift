import AppKit
import SwiftUI

/* One row of the conversation. The asymmetry is deliberate and is the
   whole reading model: the model's words are the page — full width,
   markdown, no container — and the person's are a short tinted bubble
   that says "you said this" without competing for the column. Tool use
   stays a small capsule between them, because it is evidence, not
   speech.

   Row actions live under the row and appear on hover, except on the
   last one where they stay: the action a person reaches for most is
   "answer that again", and it should not require finding the row
   first. */

struct ChatMessageRow: View {
    let row: ChatDisplayRow
    let isLast: Bool
    let isStreaming: Bool
    let retry: () -> Void
    let resend: (String) -> Void

    @State private var hovering = false
    @State private var editing: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content
            if showsActions { actions }
        }
        .frame(maxWidth: .infinity,
               alignment: row.kind == .person ? .trailing : .leading)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .person:
            if let draft = editing {
                editor(draft)
            } else {
                Text(row.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12,
                                         style: .continuous)
                            .fill(Color.accentColor.opacity(0.14)))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
        case .model:
            HStack(alignment: .bottom, spacing: 4) {
                ChatMarkdownText(source: row.text)
                if isLast && isStreaming { ChatStreamingCaret() }
            }
        case .tool(let name, let ok):
            toolCapsule(name: name, ok: ok)
        case .note:
            Label(row.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    // MARK: - Row actions

    private var showsActions: Bool {
        guard editing == nil, !isStreaming else { return false }
        switch row.kind {
        case .person, .model: return hovering || isLast
        case .tool, .note: return false
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            action(copied ? "checkmark" : "doc.on.doc",
                   copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    copied = false
                }
            }
            switch row.kind {
            case .person:
                action("pencil", "Edit and ask again") {
                    editing = row.text
                }
            case .model:
                action("arrow.clockwise", "Answer again", retry)
            default:
                EmptyView()
            }
        }
        .opacity(hovering || isLast ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func action(
        _ symbol: String, _ help: String, _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func editor(_ draft: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: Binding(
                get: { editing ?? draft },
                set: { editing = $0 }))
                .font(.body)
                .frame(minHeight: 60)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary))
            HStack(spacing: 8) {
                Button("Cancel") { editing = nil }
                Button("Ask Again") {
                    let text = editing ?? draft
                    editing = nil
                    resend(text)
                }
                .keyboardShortcut(.defaultAction)
                .disabled((editing ?? draft)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: - Tool use

    private func toolCapsule(name: String, ok: Bool?) -> some View {
        HStack(spacing: 5) {
            switch ok {
            case .none:
                ProgressView().controlSize(.mini)
            case .some(true):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .some(false):
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.orange)
            }
            Text(ChatToolTitle.of(name)).font(.caption)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .foregroundStyle(.secondary)
        .help(name)
    }
}

/// "now_capture_screen" reads as "Capture screen"; the raw name stays
/// in the tooltip.
enum ChatToolTitle {
    static func of(_ name: String) -> String {
        let stripped = name.hasPrefix("now_")
            ? String(name.dropFirst(4)) : name
        let words = stripped.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// The block that says text is still arriving. It sits after the last
/// word rather than in a corner, because the question it answers is
/// "is it still going" and the eye is already at the last word.
struct ChatStreamingCaret: View {
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 7, height: 15)
            .opacity(dim ? 0.2 : 1)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.55).repeatForever()
                ) { dim = true }
            }
    }
}
