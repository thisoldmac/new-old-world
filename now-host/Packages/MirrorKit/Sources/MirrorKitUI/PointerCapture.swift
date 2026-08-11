#if canImport(AppKit)
import AppKit
import SwiftUI

/// Pointer events SwiftUI's `DragGesture` does not expose: mouse-button
/// identity, press-time modifiers, and scroll-wheel deltas. The view draws
/// nothing and observes only events inside its own mirror surface.
struct PointerCaptureView: NSViewRepresentable {
    var onLeftDown: (CGPoint, Int) -> Void
    var onRightDown: (CGPoint, Int) -> Void
    var onScroll: (CGPoint, Int) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.update(from: self)
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.update(from: self)
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CaptureView: NSView {
        private var monitor: Any?
        private var wheelRemainder = 0.0
        private var left: ((CGPoint, Int) -> Void)?
        private var right: ((CGPoint, Int) -> Void)?
        private var scroll: ((CGPoint, Int) -> Void)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(from owner: PointerCaptureView) {
            left = owner.onLeftDown
            right = owner.onRightDown
            scroll = owner.onScroll
            installMonitorIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
            ) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let mods = KeyCaptureView.Mods.from(event.modifierFlags)
                switch event.type {
                case .leftMouseDown:
                    self.left?(point, mods)
                    return event
                case .rightMouseDown:
                    self.right?(point, mods | KeyCaptureView.Mods.control)
                    return nil
                case .scrollWheel:
                    let towardBottom = -Double(event.scrollingDeltaY)
                    if event.hasPreciseScrollingDeltas {
                        self.wheelRemainder += towardBottom / 8.0
                    } else if towardBottom != 0 {
                        self.wheelRemainder += towardBottom > 0 ? 1 : -1
                    }
                    let notches = Int(self.wheelRemainder.rounded(.towardZero))
                    if notches != 0 {
                        self.wheelRemainder -= Double(notches)
                        self.scroll?(point, max(-3, min(3, notches)))
                    }
                    return nil
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            MainActor.assumeIsolated { removeMonitor() }
        }
    }
}
#endif
