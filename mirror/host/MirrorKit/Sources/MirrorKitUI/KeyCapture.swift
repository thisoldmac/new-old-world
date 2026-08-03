#if canImport(AppKit)
import AppKit
import SwiftUI
import MirrorKit

/// **The mirror's keyboard.**
///
/// AppKit rather than SwiftUI, for one reason that decides the whole
/// design: `⌘Q` typed at a mirror must quit the application on the OTHER
/// Macintosh. SwiftUI's `onKeyPress` never sees a command combination —
/// the menu bar claims it first and quits THIS app, which is a
/// spectacular way to lose a session. `performKeyEquivalent(with:)` is
/// the one hook that runs before menu dispatch, so it is the hook.
///
/// ## Which keys are passed and which are not
///
/// Everything the guest could plausibly want, including `⌘` combinations,
/// while the mirror has focus. The exceptions are deliberate and few:
/// `⌘Q`, `⌘W` and `⌘H` are the host's own escape hatches — a person whose
/// keyboard has been captured needs a way out that cannot itself be
/// captured, and "the mirror ate my quit key" is not a bug report anyone
/// enjoys writing. They are listed in `hostReserved` and stated in the
/// window's status line rather than silently swallowed.
///
/// ## Keycodes are the same on both machines
///
/// macOS inherited the classic virtual keycode table unchanged, so
/// `NSEvent.keyCode` is the number a Mac OS 9 `EventRecord` would carry
/// and no translation table is needed. That is worth knowing because a
/// menu shortcut is matched on the CODE, not the character — the finding
/// this project paid a day for.
public struct KeyCaptureView: NSViewRepresentable {

    /// One keystroke, already in the guest's own numbering.
    public var onKey: (_ code: Int, _ char: Int, _ mods: Int) -> Void
    /// Text a person typed, when it arrives as a run rather than as
    /// individual keys (an input method, a paste).
    public var onText: (String) -> Void
    /// A host shortcut that was deliberately NOT forwarded, so the
    /// window can say so instead of appearing to have missed it.
    public var onReserved: (String) -> Void

    public init(onKey: @escaping (Int, Int, Int) -> Void,
                onText: @escaping (String) -> Void,
                onReserved: @escaping (String) -> Void) {
        self.onKey = onKey
        self.onText = onText
        self.onReserved = onReserved
    }

    public func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.owner = self
        return v
    }

    public func updateNSView(_ v: CaptureView, context: Context) {
        v.owner = self
    }

    /// The classic `evtQModifiers` bits, which are NOT AppKit's.
    public enum Mods {
        public static let cmd = 256
        public static let shift = 512
        public static let capsLock = 1024
        public static let option = 2048
        public static let control = 4096

        public static func from(_ flags: NSEvent.ModifierFlags) -> Int {
            var m = 0
            if flags.contains(.command) { m |= cmd }
            if flags.contains(.shift) { m |= shift }
            if flags.contains(.capsLock) { m |= capsLock }
            if flags.contains(.option) { m |= option }
            if flags.contains(.control) { m |= control }
            return m
        }
    }

    /// The three the host keeps. Small on purpose: every one of these is
    /// a key the guest can no longer be sent, and the mirror's own menu
    /// is the place to offer them back.
    public static let hostReserved: Set<String> = ["q", "w", "h"]

    public final class CaptureView: NSView {
        var owner: KeyCaptureView?

        public override var acceptsFirstResponder: Bool { true }
        /// Take focus on the first click rather than swallowing it — a
        /// person clicking into the mirror expects that click to reach
        /// the other Macintosh too.
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        /// Runs BEFORE menu dispatch, which is the only reason this class
        /// exists. Returning true consumes the event.
        public override func performKeyEquivalent(with event: NSEvent)
            -> Bool {
            guard window?.firstResponder === self,
                  event.modifierFlags.contains(.command) else { return false }
            let letter = (event.charactersIgnoringModifiers ?? "").lowercased()
            if KeyCaptureView.hostReserved.contains(letter) {
                owner?.onReserved("⌘" + letter.uppercased())
                return false                 // let the host have it
            }
            send(event)
            return true
        }

        public override func keyDown(with event: NSEvent) {
            /* A run of characters with no modifiers is TEXT - that is
               what an input method or a paste produces, and sending it as
               a run rather than as N keystrokes is both faster on a
               cooperatively-scheduled guest and closer to what happened. */
            let mods = KeyCaptureView.Mods.from(event.modifierFlags)
            let printable = mods & ~KeyCaptureView.Mods.shift
                & ~KeyCaptureView.Mods.capsLock == 0
            if printable, let text = event.characters, text.count > 1 {
                owner?.onText(text)
                return
            }
            send(event)
        }

        private func send(_ event: NSEvent) {
            /* `charactersIgnoringModifiers` is what the CHARACTER should
               be; the CODE is what a menu matches on, and macOS's keyCode
               is already the classic virtual keycode. */
            let scalar = (event.charactersIgnoringModifiers ?? "")
                .unicodeScalars.first
            owner?.onKey(Int(event.keyCode),
                         Int(scalar?.value ?? 0),
                         KeyCaptureView.Mods.from(event.modifierFlags))
        }
    }
}
#endif
