import AppKit
import MirrorKitUI

/// The AppKit half of Continuity file traversal. The controller owns gesture
/// state and guest coordinates; this object owns the real macOS drag source
/// and destination which must exist at the physical display boundary.
@MainActor
final class ContinuityFileEdge: NSObject {
    struct Callbacks {
        var entered: (CGPoint) -> Bool
        var exited: () -> Void
        var dropped: (NSPasteboard) -> Bool
    }

    private final class EdgePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class EdgeView: NSView, NSDraggingSource {
        var callbacks: Callbacks

        init(callbacks: Callbacks) {
            self.callbacks = callbacks
            super.init(frame: .zero)
            registerForDraggedTypes(
                [.fileURL]
                + NSFilePromiseReceiver.readableDraggedTypes.map {
                    NSPasteboard.PasteboardType($0)
                })
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo)
            -> NSDragOperation {
            callbacks.entered(screenPoint(sender)) ? .copy : []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo)
            -> NSDragOperation {
            callbacks.entered(screenPoint(sender)) ? .copy : []
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            _ = sender
            callbacks.exited()
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo)
            -> Bool {
            _ = sender
            return true
        }

        override func performDragOperation(_ sender: any NSDraggingInfo)
            -> Bool {
            callbacks.dropped(sender.draggingPasteboard)
        }

        func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                           sourceEvent: NSEvent?) -> Bool {
            guard let window else { return false }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let viewPoint = convert(windowPoint, from: nil)
            let seed = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: windowPoint,
                modifierFlags: sourceEvent?.modifierFlags ?? [],
                timestamp: sourceEvent?.timestamp
                    ?? ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: sourceEvent?.eventNumber ?? 0,
                clickCount: sourceEvent?.clickCount ?? 1,
                pressure: sourceEvent?.pressure ?? 1)
            guard let seed else { return false }

            let dragging = NSDraggingItem(pasteboardWriter: item.writer)
            let size = item.image.size
            dragging.setDraggingFrame(
                NSRect(x: viewPoint.x - size.width / 2,
                       y: viewPoint.y - size.height / 2,
                       width: size.width, height: size.height),
                contents: item.image)
            let session = beginDraggingSession(
                with: [dragging], event: seed, source: self)
            session.draggingFormation = .none
            session.animatesToStartingPositionsOnCancelOrFail = true
            return true
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context:
                                NSDraggingContext) -> NSDragOperation {
            _ = session
            _ = context
            return .copy
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            _ = session
            return true
        }

        private func screenPoint(_ sender: any NSDraggingInfo) -> CGPoint {
            guard let window else { return .zero }
            return window.convertPoint(toScreen: sender.draggingLocation)
        }
    }

    private let panel: EdgePanel
    private let edgeView: EdgeView

    init(edge: ContinuitySharedEdge, callbacks: Callbacks) {
        edgeView = EdgeView(callbacks: callbacks)
        panel = EdgePanel(
            contentRect: Self.frame(for: edge),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        panel.contentView = edgeView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.orderFrontRegardless()
    }

    func update(edge: ContinuitySharedEdge) {
        panel.setFrame(Self.frame(for: edge), display: false)
        panel.orderFrontRegardless()
    }

    func update(callbacks: Callbacks) {
        edgeView.callbacks = callbacks
    }

    func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                       sourceEvent: NSEvent?) -> Bool {
        edgeView.beginFileDrag(item, at: screenPoint,
                               sourceEvent: sourceEvent)
    }

    func close() { panel.close() }

    /// Two points live inside the real host display. That makes the strip a
    /// valid AppKit destination while preserving all but the boundary pixel
    /// pair for the application already under the pointer.
    private static func frame(for edge: ContinuitySharedEdge) -> CGRect {
        let thickness: CGFloat = 2
        switch edge.guestSide {
        case .left:
            return CGRect(x: edge.host.frame.maxX - thickness,
                          y: edge.overlap.lowerBound,
                          width: thickness,
                          height: edge.overlap.upperBound
                            - edge.overlap.lowerBound)
        case .right:
            return CGRect(x: edge.host.frame.minX,
                          y: edge.overlap.lowerBound,
                          width: thickness,
                          height: edge.overlap.upperBound
                            - edge.overlap.lowerBound)
        case .bottom:
            return CGRect(x: edge.overlap.lowerBound,
                          y: edge.host.frame.maxY - thickness,
                          width: edge.overlap.upperBound
                            - edge.overlap.lowerBound,
                          height: thickness)
        case .top:
            return CGRect(x: edge.overlap.lowerBound,
                          y: edge.host.frame.minY,
                          width: edge.overlap.upperBound
                            - edge.overlap.lowerBound,
                          height: thickness)
        }
    }
}
