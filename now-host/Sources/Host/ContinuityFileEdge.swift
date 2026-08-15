import AppKit
import MirrorKitUI

/// What a drag session was actually seeded with, as opposed to what
/// triggered it.
///
/// The round-2 metal audit had only the second fact — `host drag seed
/// event: type=6, windowNumber=14932, ourWindow=no` — and that line is
/// about the REAL mouse event a global monitor handed over, which belongs
/// to whatever application the pointer is above. It could never say
/// whether the session AppKit then started was anchored to a window this
/// app owns, and the session that froze its drag image for 101 stand-down
/// samples was the answer nobody had asked for.
struct ContinuityDragSeed: Equatable, Sendable {
    /// `NSEvent.EventType` raw value of the constructed seed.
    var eventType: UInt
    /// What the WINDOW SERVER says is the frontmost window at the seed
    /// point. Reported beside `panelCoversPoint`, which is this process's
    /// own frame arithmetic, because on metal the two disagreed and only
    /// the server's answer routes a mouse event. See
    /// `ContinuityCatchHitTest`.
    var serverTopWindowNumber: Int = 0
    /// Whether this app was active at the instant the seed was built. It is
    /// the third leg of the same diagnosis: a background app's panel that
    /// never went key, an event that never arrived, and an app that was
    /// never front are three different failures that produced one symptom.
    var appActive: Bool = false
    /// The window number the seed carries — the one AppKit anchors to.
    var windowNumber: Int
    /// The catch panel's own number, so the two can be compared in the log
    /// rather than believed.
    var panelWindowNumber: Int
    /// Whether `NSEvent.window` resolved back to the panel. Reported beside
    /// the numbers rather than instead of them: an event built from a
    /// window number is legal whether or not AppKit chooses to resolve it,
    /// and the number is the load-bearing half.
    var resolvedToPanel: Bool
    var clickCount: Int
    /// Whether the panel was key at the instant the seed was built. The
    /// gesture arrives with the button already held and no application
    /// holding the press, so a panel that cannot be addressed is a session
    /// with nowhere to live.
    var panelKey: Bool
    /// Whether the widened panel actually covers the point the drag starts
    /// from. A seed anchored to our window at a point outside it is the
    /// next shape of the same defect.
    var panelCoversPoint: Bool

    /// The one fact this seed exists to make true.
    var ownWindow: Bool {
        panelWindowNumber != 0 && windowNumber == panelWindowNumber
    }

    /// The artifact-level companion to `panelCoversPoint`: not "our frame
    /// contains this point" but "the window server would deliver a mouse
    /// event here to us".
    var serverOwnsPoint: Bool {
        panelWindowNumber != 0 && serverTopWindowNumber == panelWindowNumber
    }

    /// Logged verbatim beside the source event's provenance line, in the
    /// same grammar, so the two can be read against each other.
    var summary: String {
        "type=\(eventType), windowNumber=\(windowNumber), "
            + "ourWindow=\(ownWindow ? "yes" : "no"), "
            + "panelWindow=\(panelWindowNumber), "
            + "resolved=\(resolvedToPanel ? "yes" : "no"), "
            + "clickCount=\(clickCount), "
            + "panelKey=\(panelKey ? "yes" : "no"), "
            + "panelCoversPoint=\(panelCoversPoint ? "yes" : "no"), "
            + "serverTopWindow=\(serverTopWindowNumber), "
            + "serverOwnsPoint=\(serverOwnsPoint ? "yes" : "no"), "
            + "appActive=\(appActive ? "yes" : "no")"
    }
}

/// The window server's answer to "whose window is at this point", beside
/// the catch panel's own number.
///
/// It exists because `ContinuityDragSeed.panelCoversPoint` is
/// `window.frame.contains(point)` — a fact about THIS process's idea of its
/// own geometry, true the instant `setFrame` returns — while the routing of
/// a posted `leftMouseDown` is decided by the window server, which is a
/// different machine with a different clock. Measured on this Mac,
/// 2026-08-15, the two disagree in two separate ways:
///
/// - for **15–25 ms and several runloop turns** after every widen, because
///   a frame change reaches the server asynchronously and no synchronous
///   flush (`CATransaction.flush`, `display`, `displayIfNeeded`, a zero-length
///   runloop spin) brings it forward; and
/// - **forever**, when the panel's surface is fully transparent — see
///   `ContinuityFileEdge.hitTestableAlpha`.
///
/// This is the same rule as "the artifact carries it, not the intent": the
/// old code asserted that it had widened the surface, which was true, and
/// inferred that events would arrive there, which was not.
struct ContinuityCatchHitTest: Equatable, Sendable {
    /// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` — the
    /// server's frontmost window at the point.
    var serverTopWindowNumber: Int
    var panelWindowNumber: Int

    var ownsPoint: Bool {
        panelWindowNumber != 0 && serverTopWindowNumber == panelWindowNumber
    }

    var summary: String {
        "serverTopWindow=\(serverTopWindowNumber), "
            + "panelWindow=\(panelWindowNumber), "
            + "ownsPoint=\(ownsPoint ? "yes" : "no")"
    }
}

/// The AppKit half of Continuity file traversal. The controller owns gesture
/// state and guest coordinates; this object owns the real macOS drag source
/// and destination which must exist at the physical display boundary.
@MainActor
final class ContinuityFileEdge: NSObject {
    struct Callbacks {
        var entered: (CGPoint) -> Bool
        var exited: () -> Void
        var dropped: (NSPasteboard) -> Bool
        /// The guest→host session this app itself started has ended, wherever
        /// macOS took it. Nothing else reports that: the promise delegate
        /// speaks only when a destination ACCEPTED the drag, so without this
        /// a drop that went nowhere and a drag still in flight are the same
        /// silence — which is exactly the symptom the first metal round
        /// could not name.
        var dragEnded: (NSDragOperation, CGPoint) -> Void = { _, _ in }
    }

    private final class EdgePanel: NSPanel {
        /// False for the whole of ordinary life: a two-point strip that could
        /// take key would steal focus from whatever it sits on top of. True
        /// for one handoff, so the returning gesture has a window of ours
        /// that AppKit can address.
        var handoffKeyCapable = false
        override var canBecomeKey: Bool { handoffKeyCapable }
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

        /// **This view must never catch its own session.**
        ///
        /// The guest→host handoff widens this same strip and then starts a
        /// drag on top of it, so the first thing the new session crosses is
        /// a destination registered for exactly the types it carries. Left
        /// alone it answers `.copy` — the badge the human saw — arms a
        /// host→guest pass in the controller, and offers to copy the file
        /// straight back to the machine it is leaving. A drop then lands
        /// here rather than in the Finder.
        ///
        /// Identity, not a flag: the session's own source is the only thing
        /// that distinguishes it, and it is available on every callback.
        private func isOwnSession(_ sender: any NSDraggingInfo) -> Bool {
            (sender.draggingSource as AnyObject?) === self
        }

        override func draggingEntered(_ sender: any NSDraggingInfo)
            -> NSDragOperation {
            guard !isOwnSession(sender) else { return [] }
            return callbacks.entered(screenPoint(sender)) ? .copy : []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo)
            -> NSDragOperation {
            guard !isOwnSession(sender) else { return [] }
            return callbacks.entered(screenPoint(sender)) ? .copy : []
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            guard let sender, !isOwnSession(sender) else { return }
            callbacks.exited()
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo)
            -> Bool {
            !isOwnSession(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo)
            -> Bool {
            guard !isOwnSession(sender) else { return false }
            return callbacks.dropped(sender.draggingPasteboard)
        }

        /// Builds the seed WITHOUT starting anything.
        ///
        /// Separate from `beginFileDrag` so the one property that had to be
        /// measured on metal — whose window the session is anchored to —
        /// can be asserted here, against a real AppKit panel, without a
        /// live drag session in a test process.
        func makeSeed(at screenPoint: CGPoint, from sourceEvent: NSEvent)
            -> (event: NSEvent, seed: ContinuityDragSeed)? {
            guard let window else { return nil }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            /* Location, timestamp, modifiers and pressure come from the
               caller's real event; the WINDOW NUMBER deliberately does not.
               The real event belongs to whatever application the returning
               pointer is above — on metal, window 14932, which is not ours
               — and an event carrying a foreign window is an event AppKit
               anchors a session to a window this app cannot address. The
               defaults this used to fall back to when the event was nil
               are still gone: a drag seeded from invented timestamps and
               click counts is a different failure, and both are avoided by
               copying every field except the one that must be ours. */
            let event = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: windowPoint,
                modifierFlags: sourceEvent.modifierFlags,
                timestamp: sourceEvent.timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: sourceEvent.eventNumber,
                clickCount: sourceEvent.clickCount,
                pressure: sourceEvent.pressure)
            guard let event else { return nil }
            return (event, ContinuityDragSeed(
                eventType: event.type.rawValue,
                /* The server's own answer, taken at the same instant as the
                   frame arithmetic beside it, so the log can be read for
                   which of the two was wrong instead of assuming they
                   agree. */
                serverTopWindowNumber: NSWindow.windowNumber(
                    at: screenPoint, belowWindowWithWindowNumber: 0),
                appActive: NSApp?.isActive ?? false,
                windowNumber: event.windowNumber,
                panelWindowNumber: window.windowNumber,
                resolvedToPanel: event.window === window,
                clickCount: event.clickCount,
                panelKey: window.isKeyWindow,
                panelCoversPoint: window.frame.contains(screenPoint)))
        }

        func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                           sourceEvent: NSEvent) -> ContinuityDragSeed? {
            guard let window,
                  let (seed, provenance) = makeSeed(at: screenPoint,
                                                    from: sourceEvent)
            else { return nil }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let viewPoint = convert(windowPoint, from: nil)

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
            return provenance
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context:
                                NSDraggingContext) -> NSDragOperation {
            _ = session
            _ = context
            return .copy
        }

        /// The only end-of-session fact this app can observe. It fires
        /// whether the drag was dropped, refused or cancelled, which is what
        /// separates "nobody took it" from "somebody took it and the promise
        /// failed" — two outcomes that were previously the same silence.
        func draggingSession(_ session: NSDraggingSession,
                             endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            _ = session
            callbacks.dragEnded(operation, screenPoint)
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
    private var edge: ContinuitySharedEdge
    private var catching = false

    init(edge: ContinuitySharedEdge, callbacks: Callbacks) {
        self.edge = edge
        edgeView = EdgeView(callbacks: callbacks)
        panel = EdgePanel(
            contentRect: Self.frame(for: edge, catching: false),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        panel.contentView = edgeView
        panel.isOpaque = false
        panel.backgroundColor = Self.hitTestableBackground
        /* Redundant with the default, and set anyway: this is the property
           the window server's routing decision is named after, and leaving
           it implicit is how it took a metal round to suspect. */
        panel.ignoresMouseEvents = false
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
        self.edge = edge
        panel.setFrame(Self.frame(for: edge, catching: catching),
                       display: false)
        panel.orderFrontRegardless()
    }

    /// Widens the strip into a catch surface for one handoff, or narrows it
    /// back. See `ContinuityPointerEnvironment.setFileEdgeCatching` for why
    /// two pixels detect a crossing but cannot catch one.
    func setCatching(_ catching: Bool) {
        guard catching != self.catching else { return }
        self.catching = catching
        panel.setFrame(Self.frame(for: edge, catching: catching),
                       display: false)
        /* Key for the handoff instant only. The gesture arrives with the
           button already held and no application holding the press, so the
           window AppKit is asked to start a drag from should be a window
           this app can actually address. It is given back the moment the
           surface narrows. */
        panel.handoffKeyCapable = catching
        panel.orderFrontRegardless()
        if catching { panel.makeKeyAndOrderFront(nil) }
    }

    func update(callbacks: Callbacks) {
        edgeView.callbacks = callbacks
    }

    func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                       sourceEvent: NSEvent) -> ContinuityDragSeed? {
        armForHandoff()
        return edgeView.beginFileDrag(item, at: screenPoint,
                                      sourceEvent: sourceEvent)
    }

    /// The seed's window is only worth having if the window is real at that
    /// instant: wide enough to cover the point, in front, and key.
    ///
    /// The controller already widens on the way in, and this is the second
    /// door onto the same rule rather than a duplicate of it — the ordering
    /// is what failed on metal, and an ordering enforced only by the order
    /// of two calls in a different file is enforced by nothing.
    private func armForHandoff() {
        setCatching(true)
        panel.orderFrontRegardless()
        if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
    }

    /// What the seed WOULD be, without starting a session. Exists for the
    /// test that asserts the anchor window, which cannot run a live drag.
    func makeDragSeed(at screenPoint: CGPoint,
                      from sourceEvent: NSEvent) -> ContinuityDragSeed? {
        armForHandoff()
        return edgeView.makeSeed(at: screenPoint, from: sourceEvent)?.seed
    }

    func close() { panel.close() }

    /// Two points live inside the real host display. That makes the strip a
    /// valid AppKit destination while preserving all but the boundary pixel
    /// pair for the application already under the pointer.
    ///
    /// `catching` trades that courtesy for one handoff. A pointer returning
    /// with a held button is already moving at speed, and the drag has to
    /// begin over a view of ours; a two-point strip is a target the human
    /// has already left by the time the tap dies. Restored the moment the
    /// drag starts or the handoff is abandoned — a permanently wide surface
    /// would eat the edge of whatever app lives there.
    static let catchThickness: CGFloat = 160

    /// **A window the window server cannot see is not a catch surface.**
    ///
    /// The strip was `backgroundColor = .clear` with a content view that
    /// draws nothing, which leaves every pixel at alpha zero — and the
    /// window server routes mouse events straight THROUGH such a window to
    /// whatever is beneath it. `NSWindow.windowNumber(at:)` never returned
    /// this panel, at any delay, deterministically over three rounds
    /// (measured on this Mac, 2026-08-15). Frontness made no difference and
    /// neither did key state; only the alpha did.
    ///
    /// That single fact is the whole of the marquee: the synthetic primary
    /// down this app posts at the seed point fell through the panel onto the
    /// Finder desktop, which took it for a rubber-band selection AND handed
    /// the same event straight back through the global monitor as the "real"
    /// one the drag was then seeded from — the metal log's `host drag seed
    /// event: type=1, windowNumber=30, ourWindow=no`, a `leftMouseDown` we
    /// posted ourselves.
    ///
    /// One part in 255 is enough for the server and is below the threshold
    /// of a visible tint; a fully transparent strip is not a design goal, it
    /// was an accident with teeth.
    static let hitTestableAlpha: CGFloat = 1.0 / 255.0

    static var hitTestableBackground: NSColor {
        NSColor.black.withAlphaComponent(hitTestableAlpha)
    }

    /// Whether the panel is in a state the window server will hit-test at
    /// all. Asserted by a test against a real AppKit panel, because the two
    /// properties it reads are exactly the pair whose defaults look
    /// harmless.
    var catchSurfaceIsHitTestable: Bool {
        (panel.backgroundColor.alphaComponent > 0) && !panel.ignoresMouseEvents
    }

    /// What the window server says is at `screenPoint` right now. See
    /// `ContinuityCatchHitTest` for why this is asked rather than inferred.
    func hitTest(at screenPoint: CGPoint) -> ContinuityCatchHitTest {
        ContinuityCatchHitTest(
            serverTopWindowNumber: NSWindow.windowNumber(
                at: screenPoint, belowWindowWithWindowNumber: 0),
            panelWindowNumber: panel.windowNumber)
    }

    private static func frame(for edge: ContinuitySharedEdge,
                              catching: Bool) -> CGRect {
        let thickness: CGFloat = catching ? catchThickness : 2
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
