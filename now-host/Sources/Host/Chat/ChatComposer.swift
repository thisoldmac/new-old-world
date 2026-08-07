import AppKit
import SwiftUI

/* The composer: one growing text view, one button that is either send
   or stop, and a keyboard model people already have in their fingers —
   Return sends, Shift-Return breaks the line.

   It is an NSTextView and not a SwiftUI TextField because of exactly
   that keyboard model. A vertical-axis TextField owns Return itself
   and offers no hook for the shifted case, so the only way to have
   both is to answer `doCommandBy` — the house rule's "AppKit where
   SwiftUI cannot reach". Everything else here is SwiftUI. */

/// What the trailing button does, and why it cannot. Pure so the rules
/// can be read in one place and tested without a window: the button's
/// disabled state was three inlined boolean expressions that disagreed
/// with the placeholder about whether the pane was usable.
enum ChatComposerState: Equatable {
    /// Why the button is disabled. A reason, not a bare string,
    /// because the field's own editability follows from WHICH reason:
    /// an empty draft is the composer waiting on the person, the other
    /// two are a pane they cannot use yet.
    enum Block: Equatable {
        case noProvider
        case noModel
        case emptyDraft

        var reason: String {
            switch self {
            case .noProvider: return "Set up a provider to start"
            case .noModel: return "Choose a model"
            case .emptyDraft: return "Type a message"
            }
        }

        var acceptsTyping: Bool { self == .emptyDraft }
    }

    case send
    case stop
    case blocked(Block)

    static func state(
        draft: String, isStreaming: Bool, hasModels: Bool, hasSelection: Bool
    ) -> ChatComposerState {
        // Stop outranks everything: a turn in flight can always be
        // stopped, including one started before a provider was removed.
        if isStreaming { return .stop }
        if !hasModels { return .blocked(.noProvider) }
        if !hasSelection { return .blocked(.noModel) }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .blocked(.emptyDraft)
        }
        return .send
    }

    /// Whether the field takes typing at all.
    var acceptsTyping: Bool {
        if case .blocked(let block) = self { return block.acceptsTyping }
        return true
    }
}

struct ChatComposer: View {
    @Binding var draft: String
    let state: ChatComposerState
    let placeholder: String
    let send: () -> Void
    let stop: () -> Void

    @State private var height: CGFloat = ChatComposerField.minHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                field
                button
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.quaternary))
            )
            Text("Return to send, Shift-Return for a new line")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isEnabled: Bool { state.acceptsTyping }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            ChatComposerField(
                text: $draft, height: $height, isEnabled: isEnabled,
                submit: { if case .send = state { send() } })
                .frame(height: height)
            if draft.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var button: some View {
        switch state {
        case .stop:
            action("stop.fill", .red, "Stop the answer", stop)
        case .send:
            action("arrow.up", Color.accentColor, "Send", send)
        case .blocked(let block):
            action("arrow.up", Color.secondary.opacity(0.4), block.reason, {})
                .disabled(true)
        }
    }

    private func action(
        _ symbol: String, _ tint: Color, _ help: String,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - The text view

/// A multi-line field that grows with its content to a cap, reports
/// its height back, and hands Return to the caller.
struct ChatComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isEnabled: Bool
    var submit: () -> Void

    static let minHeight: CGFloat = 22
    /// Roughly eight lines; past that the field scrolls rather than
    /// eating the transcript it exists to talk about.
    static let maxHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true

        let view = KeyTextView()
        view.delegate = context.coordinator
        view.onSubmit = { context.coordinator.parent.submit() }
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 4
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? KeyTextView else { return }
        if view.string != text { view.string = text }
        view.isEditable = isEnabled
        view.isSelectable = true
        context.coordinator.reportHeight(of: view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerField

        init(_ parent: ChatComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            reportHeight(of: view)
        }

        func reportHeight(of view: NSTextView) {
            guard let manager = view.layoutManager,
                let container = view.textContainer
            else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let wanted = min(
                max(used + 4, ChatComposerField.minHeight),
                ChatComposerField.maxHeight)
            guard abs(wanted - parent.height) > 0.5 else { return }
            // The binding drives a SwiftUI frame; writing it inside the
            // layout pass that produced it is what re-entered.
            DispatchQueue.main.async { [parent] in parent.height = wanted }
        }
    }

    /// Return sends; Shift-Return (and Option-Return, which some
    /// muscle memory reaches for) inserts a line break.
    final class KeyTextView: NSTextView {
        var onSubmit: () -> Void = {}

        override func doCommand(by selector: Selector) {
            guard selector == #selector(insertNewline(_:)) else {
                super.doCommand(by: selector)
                return
            }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit()
            }
        }
    }
}
