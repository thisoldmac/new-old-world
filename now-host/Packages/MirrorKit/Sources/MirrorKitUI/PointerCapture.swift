#if canImport(AppKit)
import AppKit
import SwiftUI

/// One host-owned drag stub. The pasteboard writer is normally an
/// `NSFilePromiseProvider`; the image is the guest item's original icon.
public struct HostFileDragItem {
    public var writer: NSPasteboardWriting
    public var image: NSImage

    public init(writer: NSPasteboardWriting, image: NSImage) {
        self.writer = writer
        self.image = image
    }
}

/// The host owns a cross-machine file drag only on the semantic Mirror
/// surface. Mirror Cursor is a different input owner, so an active raw
/// pointer lane leaves the gesture to the guest.
enum HostFileDragPolicy {
    static let movementThreshold = 6

    static func claimsPress(filePromiseAvailable: Bool,
                            mirrorCursorActive: Bool) -> Bool {
        filePromiseAvailable && !mirrorCursorActive
    }

    static func hasBegun(from start: (x: Int, y: Int),
                         to current: (x: Int, y: Int)) -> Bool {
        abs(current.x - start.x) + abs(current.y - start.y)
            >= movementThreshold
    }
}

/// Pointer events SwiftUI's `DragGesture` does not expose: mouse-button
/// identity, press-time modifiers, and scroll-wheel deltas. The view draws
/// nothing and observes only events inside its own mirror surface.
struct PointerCaptureView: NSViewRepresentable {
    var onMove: (CGPoint) -> Void
    var onExit: () -> Void
    var onLeftDown: (CGPoint, Int) -> Bool
    /// Returns a native file-promise item at the moment the host should take
    /// ownership. Nil keeps the captured guest gesture in progress.
    var onLeftDragged: (CGPoint, Int) -> HostFileDragItem?
    var onLeftUp: (CGPoint, Int) -> Bool
    var onCancel: () -> Void
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
        view.stopObserving()
    }

    final class CaptureView: NSView, NSDraggingSource {
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var wheelRemainder = 0.0
        private var pointerInside = false
        private var capturedLeft = false
        private var move: ((CGPoint) -> Void)?
        private var exit: (() -> Void)?
        private var leftDown: ((CGPoint, Int) -> Bool)?
        private var leftDragged: ((CGPoint, Int) -> HostFileDragItem?)?
        private var leftUp: ((CGPoint, Int) -> Bool)?
        private var cancel: (() -> Void)?
        private var right: ((CGPoint, Int) -> Void)?
        private var scroll: ((CGPoint, Int) -> Void)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(from owner: PointerCaptureView) {
            move = owner.onMove
            exit = owner.onExit
            leftDown = owner.onLeftDown
            leftDragged = owner.onLeftDragged
            leftUp = owner.onLeftUp
            cancel = owner.onCancel
            right = owner.onRightDown
            scroll = owner.onScroll
            installMonitorIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
            installObserversIfNeeded()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged,
                           .leftMouseUp, .rightMouseDown, .scrollWheel]
            ) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let isInside = self.bounds.contains(point)
                if isInside {
                    self.pointerInside = true
                } else if self.pointerInside && !self.capturedLeft {
                    self.pointerInside = false
                    self.exit?()
                }
                let mods = KeyCaptureView.Mods.from(event.modifierFlags)
                switch event.type {
                case .mouseMoved:
                    if isInside { self.move?(point) }
                    return event
                case .leftMouseDown:
                    guard isInside else { return event }
                    self.move?(point)
                    self.capturedLeft = self.leftDown?(point, mods) ?? false
                    return self.capturedLeft ? nil : event
                case .leftMouseDragged:
                    guard self.capturedLeft else { return event }
                    if let item = self.leftDragged?(point, mods) {
                        self.capturedLeft = false
                        if !isInside {
                            self.pointerInside = false
                            self.exit?()
                        }
                        self.beginHostDrag(item, at: point, event: event)
                        return nil
                    }
                    return nil
                case .leftMouseUp:
                    guard self.capturedLeft else { return event }
                    _ = self.leftUp?(point, mods)
                    self.capturedLeft = false
                    if !isInside {
                        self.pointerInside = false
                        self.exit?()
                    }
                    return nil
                case .rightMouseDown:
                    guard isInside else { return event }
                    self.right?(point, mods | KeyCaptureView.Mods.control)
                    return nil
                case .scrollWheel:
                    guard isInside else { return event }
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

        private func installObserversIfNeeded() {
            guard observers.isEmpty, let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    /* NotificationCenter does not express queue actor
                       isolation in its closure type. The explicit .main
                       delivery above is the runtime guarantee. */
                    MainActor.assumeIsolated { self?.cancelCapture() }
                })
            observers.append(center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelCapture() }
                })
        }

        private func cancelCapture() {
            pointerInside = false
            capturedLeft = false
            cancel?()
        }

        /// AppKit owns the gesture from this call onward. In particular, the
        /// Mirror edge is not part of initiation: the first threshold-crossing
        /// drag event may still be well inside this view.
        private func beginHostDrag(_ item: HostFileDragItem, at point: CGPoint,
                                   event: NSEvent) {
            let dragging = NSDraggingItem(pasteboardWriter: item.writer)
            let size = item.image.size
            dragging.setDraggingFrame(
                NSRect(x: point.x - size.width / 2,
                       y: point.y - size.height / 2,
                       width: size.width, height: size.height),
                contents: item.image)
            let session = beginDraggingSession(
                with: [dragging], event: event, source: self)
            session.draggingFormation = .none
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context:
                                NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            true
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func stopObserving() {
            cancelCapture()
            removeMonitor()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
        }

        deinit {
            MainActor.assumeIsolated { stopObserving() }
        }
    }
}
#endif
