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
///
/// ## Owning a window versus sharing one
///
/// Everything above describes a mirror that owns its window. A mirror
/// drawn as one pane of a larger application is a different problem and
/// the old behaviour is silently wrong for it: seizing first responder on
/// appear takes the keyboard away from the host's own sidebar, and a
/// `performKeyEquivalent` that consumes every ⌘ combination but three
/// disables the host's entire menu bar — ⌘⇧M, ⌘0, ⌘/ — with nothing
/// erroring and nothing on screen saying so.
///
/// So focus is a parameter. `.ownsWindow` is what it always did.
/// `.sharesWindow` takes the keyboard only when the host says a person
/// has clicked in, and hands back every character the host names.
public struct KeyCaptureView: NSViewRepresentable {

    /// **Whose keyboard this is.**
    public enum Focus: Equatable, Sendable {
        /// The mirror is the window. It takes first responder as soon as
        /// it appears and keeps it.
        case ownsWindow
        /// The mirror is one pane among the host's own controls. It never
        /// takes the keyboard unasked; `engaged` is the host saying a
        /// person clicked into the mirror, and setting it back to false
        /// hands the keyboard back.
        case sharesWindow(engaged: Bool)
    }

    /// One keystroke, already in the guest's own numbering.
    public var onKey: (_ code: Int, _ char: Int, _ mods: Int) -> Void
    /// Text a person typed, when it arrives as a run rather than as
    /// individual keys (an input method, a paste).
    public var onText: (String) -> Void
    /// A host shortcut that was deliberately NOT forwarded, so the
    /// window can say so instead of appearing to have missed it.
    public var onReserved: (String) -> Void
    public var focus: Focus
    /// The keyboard went somewhere else — the person clicked the host's
    /// sidebar, or tabbed away. Only meaningful while sharing a window,
    /// and it exists so the host can put `engaged` back to false: without
    /// it the host would still believe the mirror had focus and would
    /// re-seize it on the next redraw, which is the focus theft this
    /// whole parameter was added to end.
    public var onFocusLost: () -> Void
    /// The characters the host keeps for its own menu bar, matched on
    /// `charactersIgnoringModifiers` and therefore **without regard to
    /// shift or option**: reserving "m" reserves ⌘M and ⌘⇧M together.
    /// Coarse on purpose — a set that distinguished them would have to
    /// model a menu's whole matching rule, and the cost of over-reserving
    /// is a key the guest does not get, while the cost of
    /// under-reserving is a host menu that silently stops working.
    public var hostReserved: Set<String>

    public init(onKey: @escaping (Int, Int, Int) -> Void,
                onText: @escaping (String) -> Void,
                onReserved: @escaping (String) -> Void,
                focus: Focus = .ownsWindow,
                hostReserved: Set<String> = KeyCaptureView.hostReserved,
                onFocusLost: @escaping () -> Void = {}) {
        self.onKey = onKey
        self.onText = onText
        self.onReserved = onReserved
        self.focus = focus
        self.hostReserved = hostReserved
        self.onFocusLost = onFocusLost
    }

    public func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.owner = self
        return v
    }

    public func updateNSView(_ v: CaptureView, context: Context) {
        v.owner = self
        v.applyFocus()
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

        /// What was last acted on, so focus is driven by CHANGES rather
        /// than reasserted on every redraw. Reasserting is the bug: SwiftUI
        /// updates this view for reasons that have nothing to do with the
        /// keyboard, and a pane that re-takes first responder on each one
        /// yanks it back the instant a person clicks the host's sidebar.
        private var applied: Focus?

        /// **Only `.ownsWindow` may take the keyboard by appearing.**
        ///
        /// A pane that seizes first responder on appear takes it from
        /// whatever the person was actually using — the host's sidebar —
        /// and nothing about that is visible in a screenshot or a test.
        func applyFocus() {
            guard let window else { return }
            let want = owner?.focus ?? .ownsWindow
            guard want != applied else { return }
            applied = want
            switch want {
            case .ownsWindow:
                if window.firstResponder !== self {
                    window.makeFirstResponder(self)
                }
            case .sharesWindow(let engaged):
                if engaged {
                    if window.firstResponder !== self {
                        window.makeFirstResponder(self)
                    }
                } else if window.firstResponder === self {
                    window.makeFirstResponder(nil)
                }
            }
        }

        public override func viewDidMoveToWindow() {
            applied = nil
            super.viewDidMoveToWindow()
            applyFocus()
        }

        public override func resignFirstResponder() -> Bool {
            if case .sharesWindow = owner?.focus ?? .ownsWindow {
                applied = .sharesWindow(engaged: false)
                owner?.onFocusLost()
            }
            return super.resignFirstResponder()
        }

        /// Runs BEFORE menu dispatch, which is the only reason this class
        /// exists. Returning true consumes the event.
        public override func performKeyEquivalent(with event: NSEvent)
            -> Bool {
            guard window?.firstResponder === self,
                  event.modifierFlags.contains(.command) else { return false }
            let letter = (event.charactersIgnoringModifiers ?? "").lowercased()
            if (owner?.hostReserved ?? KeyCaptureView.hostReserved)
                .contains(letter) {
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
