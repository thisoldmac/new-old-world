import AppKit
import SwiftUI

/// The console's input line, in AppKit because SwiftUI cannot reach the keys
/// it needs: `.onKeyPress` is macOS 14 and this app supports 13, and even
/// there a `TextField` swallows Tab to move focus. ↑/↓ history and Tab
/// completion are the two things a shell must have, so the field is an
/// `NSTextField` whose field editor reports those three commands and nothing
/// else — every other key, and all the editing behaviour, stays AppKit's.
struct ConsoleInputField: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var placeholder: String
    /// Return.
    var onSubmit: () -> Void
    /// ↑ (-1) and ↓ (+1). Returns the line to show, or nil to leave the field
    /// alone — which is what an empty history does.
    var onRecall: (Int) -> String?
    /// Tab. Returns the completed word, or nil to leave it alone.
    var onComplete: (String) -> String?

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                           weight: .regular)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEnabled = isEnabled
        field.placeholderString = placeholder
        // Typing is the whole purpose of this view, so it takes focus when it
        // can — but never steals it back while disabled, which would trap the
        // caret in a field that cannot accept a character.
        if isEnabled, field.window?.firstResponder !== field.currentEditor(),
           field.window?.firstResponder is NSWindow {
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ConsoleInputField

        init(parent: ConsoleInputField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onSubmit()
                textView.string = ""
                return true
            case #selector(NSResponder.moveUp(_:)):
                return replace(textView, with: parent.onRecall(-1))
            case #selector(NSResponder.moveDown(_:)):
                return replace(textView, with: parent.onRecall(1))
            case #selector(NSResponder.insertTab(_:)):
                // Only the word being typed completes, and only when the
                // caret is at the end of it — completing into the middle of a
                // line would rewrite text the human is still looking at.
                let typed = textView.string
                guard let completed = parent.onComplete(typed) else {
                    return true          // eaten: Tab must not move focus
                }
                return replace(textView, with: completed)
            default:
                return false
            }
        }

        private func replace(_ textView: NSTextView, with value: String?)
            -> Bool {
            guard let value else { return true }
            textView.string = value
            textView.setSelectedRange(NSRange(location: value.count, length: 0))
            parent.text = value
            return true
        }
    }
}
