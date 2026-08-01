import AppKit
import SwiftUI

/// An invisible layer over the mirror drawing that reports every `keyDown`
/// it receives, translated to primitives — never as an `NSEvent`, so the
/// caller (`MirrorModuleModel`) stays platform-independent the way
/// `ActionModel.paneKeystroke` already is.
///
/// **AppKit, not `.onKeyPress`.** `ConsoleInputField` states why this
/// project's SwiftUI key handling goes through AppKit: `.onKeyPress` is
/// macOS 14 and this app supports 13 (`Package.swift: .macOS(.v13)`). This
/// view is a second, narrower instance of the same constraint.
///
/// **`hitTest` always returns nil — this view is deaf to the mouse on
/// purpose.** The drawing beneath already owns its click, through a plain
/// SwiftUI `DragGesture` (`MirrorModuleView.drawing`), and that gesture
/// already dispatches a real act to the guest. Sitting a first-responder
/// AppKit view on TOP of it — which is what an overlay ordinarily is — puts
/// this view in AppKit's hit-testing path ahead of that gesture, and there
/// is no way to prove from here, without running the app, that
/// `nextResponder?.mouseDown(with:)` forwards cleanly through SwiftUI's own
/// gesture machinery rather than swallowing the press. Refusing to
/// intercept the mouse at all sidesteps the question rather than betting on
/// an unverified answer: **`MirrorModuleView.press(at:in:scene:)` calls
/// `focus()` itself, after its own gesture already ran**, which is a
/// call this side can make with total confidence because it never
/// contends for the same event.
///
/// The cost of that safety is that typing needs a click first — there is no
/// "the pane opened, so it already has focus" today. Documented rather
/// than solved: an eager `becomeFirstResponder` on appearance would fight
/// the console field and any other control for keyboard focus at window
/// launch, and there is no way to referee that from here without running
/// the app to see who wins.
struct MirrorKeyCaptureView: NSViewRepresentable {
    /// One keystroke, as `ActionModel.paneKeystroke` takes it — this view's
    /// whole contribution is filling these five fields from a real
    /// `NSEvent`, nothing else.
    var onKey: (_ virtualKeyCode: Int, _ characters: String?,
               _ command: Bool, _ option: Bool, _ control: Bool) -> Void
    /// Set by the caller to a closure that requests focus; this view fills
    /// it in with one that actually can, once it has an `NSView` to ask.
    /// A `Binding` would fire a SwiftUI update on every focus request for
    /// no SwiftUI state that changed; this is a plain out-parameter instead.
    @Binding var focusRequest: (() -> Void)?

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        DispatchQueue.main.async {
            focusRequest = { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
    }

    /// `NSView` and not `NSResponder` alone: `keyDown` only reaches a
    /// responder that is IN the chain, which means it has to be a view
    /// `makeFirstResponder` can install.
    final class CaptureView: NSView {
        var onKey: ((Int, String?, Bool, Bool, Bool) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        /// Deaf to the mouse everywhere in its own bounds — see the type's
        /// header for why this is the load-bearing line in this file. `nil`
        /// removes this view (and any subview) from AppKit's hit-testing
        /// for the point, so the drawing's own `DragGesture` sees every
        /// press exactly as it did before this view existed.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags
            onKey?(Int(event.keyCode), event.characters,
                  flags.contains(.command), flags.contains(.option),
                  flags.contains(.control))
        }

        /// `keyDown`'s pair. The wire's `key` verb posts both halves of the
        /// message itself (`now_input_run_key`); this side is not asked to
        /// post a second one for the key-up, only to not let AppKit's
        /// default handling beep at an unhandled key event. Overridden and
        /// empty rather than omitted, so a future reader sees the decision
        /// rather than an accidental silence.
        override func keyUp(with event: NSEvent) {}
    }
}
