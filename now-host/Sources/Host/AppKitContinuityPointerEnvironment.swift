import AppKit
import CoreGraphics
import Foundation
import MirrorKit
import MirrorKitUI

@MainActor
final class AppKitContinuityPointerEnvironment:
    ContinuityPointerEnvironment {
    private final class Monitors {
        let generation: UInt64
        var local: Any?
        var global: Any?

        init(generation: UInt64) { self.generation = generation }
    }

    /// AppKit does not declare NSEvent Sendable, although this reference is
    /// immutable and is consumed only after returning to the main actor.
    private final class EventBox: @unchecked Sendable {
        let event: NSEvent
        init(_ event: NSEvent) { self.event = event }
    }

    private var monitorGeneration: UInt64 = 0

    func start(_ handler: @escaping SampleHandler) -> AnyObject {
        monitorGeneration &+= 1
        let generation = monitorGeneration
        let monitors = Monitors(generation: generation)
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp,
        ]
        monitors.local = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            self?.deliver(event, to: handler)
            return event
        }
        monitors.global = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let sample = Self.sample(event)
            let eventBox = EventBox(event)
            Task { @MainActor [weak self] in
                guard let self, self.monitorGeneration == generation else {
                    return
                }
                handler(sample, eventBox.event)
            }
        }
        return monitors
    }

    func stop(_ token: AnyObject) {
        guard let monitors = token as? Monitors else { return }
        if monitors.generation == monitorGeneration {
            monitorGeneration &+= 1
        }
        if let local = monitors.local { NSEvent.removeMonitor(local) }
        if let global = monitors.global { NSEvent.removeMonitor(global) }
        monitors.local = nil
        monitors.global = nil
    }

    func postSyntheticPrimaryButton(down: Bool,
                                    at screenPoint: CGPoint) -> Bool {
        /* AppKit global (bottom-left origin) to CG global (top-left of the
           primary display) — the same flip the tap's samples undo. */
        let flipHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: screenPoint.x,
                            y: flipHeight - screenPoint.y)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: down ? .leftMouseDown : .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        /* The session tap, not the HID one: the point is to correct the
           SESSION's belief about the button, which this app's own consuming
           tap starved. The HID level already carries the truth. */
        event.post(tap: .cgSessionEventTap)
        return true
    }

    func postSyntheticPrimaryButtonAtHID(down: Bool,
                                         at screenPoint: CGPoint) -> Bool {
        let flipHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: screenPoint.x,
                            y: flipHeight - screenPoint.y)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: down ? .leftMouseDown : .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        /* The HID tap, not the session one, and the difference is who gets
           to see it. This release has to reach the window server's own drag
           machinery to END a live session; posted at the session level it
           enters in FRONT of nothing and BEHIND every head-inserted tap on
           this Mac — this app's own consuming tap among them, which
           swallows exactly this event type by design. */
        event.post(tap: .cghidEventTap)
        return true
    }

    func hideCursor(on displayID: UInt32) {
        CGDisplayHideCursor(CGDirectDisplayID(displayID))
    }

    func showCursor(on displayID: UInt32) {
        CGDisplayShowCursor(CGDirectDisplayID(displayID))
    }

    func moveCursor(on displayID: UInt32, to point: CGPoint) {
        CGDisplayMoveCursorToPoint(CGDirectDisplayID(displayID), point)
    }

    func setCursorMovementAssociated(_ associated: Bool) -> Bool {
        /* The association is a property of this process's window-server
           connection, so a crash restores it. A live-but-wedged app is the
           case the caller's teardown paths exist for. */
        CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0) == .success
    }

    func startInputCapture(
        handler: @escaping SampleHandler,
        tapDisabled: @escaping @MainActor (String) -> Void
    ) -> AnyObject? {
        let context = TapContext(
            handler: handler, tapDisabled: tapDisabled,
            /* Sampled once here rather than read per event: NSScreen is main
               actor state and the callback is a bare C function. The value
               only orients the audit trail — ownership is driven by deltas —
               so a rearrangement mid-pass costs a log line, not a click. */
            flipHeight: NSScreen.screens.first?.frame.maxY ?? 0)
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        /* Deliberately no keyDown/keyUp: the keyboard already has its own
           consuming tap, and that tap is what lets the escape chord end
           ownership. A second head-inserted tap would sit in front of it and
           could swallow the chord before the handler that acts on it. */
        let mask = types.reduce(UInt64(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let context = Unmanaged<TapContext>.fromOpaque(refcon)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout
                    || type == .tapDisabledByUserInput {
                    if let port = context.port {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    let reason = type == .tapDisabledByTimeout
                        ? "timeout" : "user input"
                    let notify = context.tapDisabled
                    Task { @MainActor in notify(reason) }
                    return Unmanaged.passUnretained(event)
                }
                /* Swallowing has to be decided synchronously — the tap's
                   watchdog covers this callback, not the main-actor hop.
                   Everything in the mask belongs to the guest for the
                   duration, so it is consumed whether or not it maps to a
                   sample the guest can be told about (scroll, extra
                   buttons): a classic Mac has one button and no wheel, and
                   letting those through is exactly the host click leak this
                   tap exists to close. */
                if let sample = AppKitContinuityPointerEnvironment.sample(
                    event, type: type, flipHeight: context.flipHeight) {
                    let deliver = context.handler
                    /* No NSEvent exists on this path — the tap sees
                       CGEvents, and the CGEvent itself is only valid inside
                       this callback. The caller is told so rather than
                       handed a stand-in. */
                    Task { @MainActor in deliver(sample, nil) }
                }
                return nil
            }, userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
            return nil
        }
        context.port = port
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return TapToken(port: port, source: source, context: context)
    }

    func stopInputCapture(_ token: AnyObject) {
        guard let token = token as? TapToken else { return }
        CGEvent.tapEnable(tap: token.port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), token.source, .commonModes)
        CFMachPortInvalidate(token.port)
    }

    private final class TapContext: NSObject {
        let handler: @MainActor (HostPointerSample, NSEvent?) -> Void
        let tapDisabled: @MainActor (String) -> Void
        let flipHeight: CGFloat
        var port: CFMachPort?

        init(handler: @escaping @MainActor (HostPointerSample, NSEvent?)
                -> Void,
             tapDisabled: @escaping @MainActor (String) -> Void,
             flipHeight: CGFloat) {
            self.handler = handler
            self.tapDisabled = tapDisabled
            self.flipHeight = flipHeight
        }
    }

    private final class TapToken: NSObject {
        let port: CFMachPort
        let source: CFRunLoopSource
        let context: TapContext

        init(port: CFMachPort, source: CFRunLoopSource, context: TapContext) {
            self.port = port
            self.source = source
            self.context = context
        }
    }

    /// Whether the primary button is physically held. Read only where the
    /// event type cannot answer, and injectable so the rule below is
    /// testable without a mouse.
    ///
    /// **`.hidSystemState`, not `.combinedSessionState`, and the difference
    /// is this app's own tap.** The consuming tap swallows the physical
    /// `leftMouseDown` — that is its job — so the session's event state
    /// never learns the button went down: `.combinedSessionState` and
    /// `NSEvent.pressedMouseButtons` both read UP for the whole captured
    /// gesture. The first version of this function asked the session and
    /// so reported this app's own swallowing back to it as a release
    /// (metal, 2026-08-15 02:48 — four crossings abandoned in the same
    /// second, with the button held throughout). Only the HID level sits
    /// beneath the tap.
    nonisolated static func primaryButtonIsHeld() -> Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
    }

    nonisolated static func sample(
        _ event: CGEvent, type: CGEventType, flipHeight: CGFloat,
        primaryHeld: () -> Bool = AppKitContinuityPointerEnvironment
            .primaryButtonIsHeld
    ) -> HostPointerSample? {
        let kind: HostPointerSample.Kind
        let buttonsDown: Bool
        switch type {
        case .leftMouseDown:
            kind = .primaryDown
            buttonsDown = true
        case .leftMouseUp:
            kind = .primaryUp
            /* The type is authoritative HERE and the button state is not: a
               read taken as the release goes by can still say "held" and
               would resurrect a press that has ended. */
            buttonsDown = false
        case .leftMouseDragged:
            kind = .moved
            buttonsDown = true
        case .mouseMoved:
            kind = .moved
            /* **A MOUSE-MOVED IS NOT A RELEASE.** A cursor warp synthesizes
               one whatever the button is doing, and a guest pass issues one
               warp per sample (`pinHostCursor` — 130 to 222 of them in a
               single crossing on metal). Reading the button off the event
               type therefore reports a release the human never made.

               The NSEvent adapter below has always answered this from
               `pressedMouseButtons`, so the two producers of one struct
               disagreed about its most load-bearing field — and only the
               NSEvent one ran, because the tap needs Accessibility and this
               Mac had never granted it. The morning it was granted, three
               guest→host file drags in a row died at
               `the button was released before this Mac saw a real mouse
               event` with the button still down (metal, 2026-08-15). */
            buttonsDown = primaryHeld()
        case .rightMouseDragged, .otherMouseDragged:
            /* The pointer really is moving, so the guest must follow. Asking
               the session keeps the documented rule — only the primary
               button drags, on a machine that has one — while no longer
               calling a primary button that IS held released. */
            kind = .moved
            buttonsDown = primaryHeld()
        default:
            return nil
        }
        let location = event.location
        return HostPointerSample(
            kind: kind,
            /* CGEvent locations are top-left origin against the primary
               display; the rest of this file is AppKit's bottom-left space. */
            location: CGPoint(x: location.x, y: flipHeight - location.y),
            /* Same device orientation as NSEvent.deltaY — positive is down —
               so it is inverted once here, as the monitor adapter does. */
            delta: CGPoint(
                x: event.getDoubleValueField(.mouseEventDeltaX),
                y: -event.getDoubleValueField(.mouseEventDeltaY)),
            buttonsDown: buttonsDown,
            /* Captured before the main-actor hop on the same monotonic clock
               used by the AppKit monitor and the controller timeout logic. */
            eventUptime: ProcessInfo.processInfo.systemUptime)
    }

    /// The tally lives in a class the tap callback mutates directly, on the
    /// main runloop thread the source is attached to. **No main-actor hop**:
    /// the callback fires inside AppKit's own drag-tracking loop, and a
    /// `Task { @MainActor }` scheduled from there is not guaranteed to run
    /// until the loop exits — which is after the very session-end callback
    /// that wants to read it.
    private final class WitnessBox: NSObject, @unchecked Sendable {
        var witness = ContinuityDragWitness(installed: true)
        var port: CFMachPort?
        var source: CFRunLoopSource?
    }

    func startDragWitness() -> AnyObject? {
        let box = WitnessBox()
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        ]
        let mask = types.reduce(UInt64(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            /* Tail-append and listen-only: the question is what the session
               ACTUALLY saw, after every other tap on this Mac has had its
               say, and answering it must not change the answer. */
            tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let box = Unmanaged<WitnessBox>.fromOpaque(refcon)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout
                    || type == .tapDisabledByUserInput {
                    if let port = box.port {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                box.witness.record(ContinuityWitnessedEvent(
                    type: type.rawValue,
                    location: event.location,
                    sourcePID: event.getIntegerValueField(
                        .eventSourceUnixProcessID),
                    sourceStateID: event.getIntegerValueField(
                        .eventSourceStateID),
                    uptime: ProcessInfo.processInfo.systemUptime,
                    hidPrimaryHeld: CGEventSource.buttonState(
                        .hidSystemState, button: .left),
                    sessionPrimaryHeld: CGEventSource.buttonState(
                        .combinedSessionState, button: .left)))
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(box).toOpaque()) else {
            return nil
        }
        box.port = port
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        box.source = source
        /* `.commonModes` covers the event-tracking mode AppKit's drag loop
           runs in. Attached anywhere narrower this would go quiet for exactly
           the interval it exists to observe. */
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return box
    }

    func readDragWitness(_ token: AnyObject) -> ContinuityDragWitness {
        guard let box = token as? WitnessBox else {
            return ContinuityDragWitness(installed: false)
        }
        return box.witness
    }

    func stopDragWitness(_ token: AnyObject) {
        guard let box = token as? WitnessBox, let port = box.port else {
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source = box.source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(port)
        box.port = nil
        box.source = nil
    }

    func showFileEdge(_ edge: ContinuitySharedEdge, catchThickness: CGFloat,
                      callbacks: ContinuityFileEdge.Callbacks) -> AnyObject {
        let fileEdge = ContinuityFileEdge(edge: edge,
                                          catchThickness: catchThickness,
                                          callbacks: callbacks)
        activeFileEdge = fileEdge
        return fileEdge
    }

    func updateFileEdge(_ token: AnyObject, edge: ContinuitySharedEdge,
                        catchThickness: CGFloat,
                        callbacks: ContinuityFileEdge.Callbacks) {
        guard let edgeWindow = token as? ContinuityFileEdge else { return }
        edgeWindow.update(edge: edge)
        edgeWindow.update(catchThickness: catchThickness)
        edgeWindow.update(callbacks: callbacks)
    }

    func setFileEdgeCatching(_ token: AnyObject, _ catching: Bool) {
        (token as? ContinuityFileEdge)?.setCatching(catching)
    }

    func setFileEdgeDropsThroughOwnSession(_ token: AnyObject,
                                           _ dropsThrough: Bool) {
        (token as? ContinuityFileEdge)?.setDropsThroughOwnSession(dropsThrough)
    }

    func catchSurfaceHitTest(_ token: AnyObject, at screenPoint: CGPoint)
        -> ContinuityCatchHitTest {
        guard let edge = token as? ContinuityFileEdge else {
            /* Both zero, so `ownsPoint` is false: no surface is not the
               same as a surface that lost, and the caller must not act as
               though it had one. */
            return ContinuityCatchHitTest(serverTopWindowNumber: 0,
                                          panelWindowNumber: 0)
        }
        return edge.hitTest(at: screenPoint)
    }

    func hideFileEdge(_ token: AnyObject) {
        let fileEdge = token as? ContinuityFileEdge
        fileEdge?.close()
        if activeFileEdge === fileEdge { activeFileEdge = nil }
    }

    func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                       sourceEvent: NSEvent) -> ContinuityDragSeed? {
        guard let edge = activeFileEdge else { return nil }
        return edge.beginFileDrag(item, at: screenPoint,
                                  sourceEvent: sourceEvent)
    }

    private weak var activeFileEdge: ContinuityFileEdge?

    private func deliver(_ event: NSEvent,
                         to handler: @escaping SampleHandler) {
        handler(Self.sample(event), event)
    }

    nonisolated static func sample(
        _ event: NSEvent,
        primaryHeld: () -> Bool = AppKitContinuityPointerEnvironment
            .primaryButtonIsHeld
    ) -> HostPointerSample {
        let kind: HostPointerSample.Kind
        let buttonsDown: Bool
        switch event.type {
        case .leftMouseDown:
            kind = .primaryDown
            buttonsDown = true
        case .leftMouseUp:
            kind = .primaryUp
            buttonsDown = false
        case .leftMouseDragged:
            kind = .moved
            buttonsDown = true
        default:
            kind = .moved
            /* `pressedMouseButtons` alone is not enough here, for the same
               reason as the tap's `.mouseMoved` case above and one layer
               deeper: it reads the session's event state, which this app's
               own consuming tap starves — a swallowed `leftMouseDown`
               never reaches it, so a captured gesture reads button-up on
               every monitor sample. The window server also keeps
               synthesizing plain `mouseMoved` instead of `leftMouseDragged`
               for exactly that reason, which is why this case is the one a
               held post-teardown pointer actually arrives through
               (metal, 2026-08-15 02:48). */
            buttonsDown = NSEvent.pressedMouseButtons != 0 || primaryHeld()
        }
        /* NSEvent's mouse delta is device-oriented: positive Y means down.
           The display arrangement is AppKit-oriented, so invert it once at
           the adapter and keep every geometry function in one coordinate
           system. This remains metal-probe-required on the PowerBook rig. */
        return HostPointerSample(
            kind: kind, location: NSEvent.mouseLocation,
            delta: CGPoint(x: event.deltaX, y: -event.deltaY),
            buttonsDown: buttonsDown,
            eventUptime: ProcessInfo.processInfo.systemUptime)
    }
}
