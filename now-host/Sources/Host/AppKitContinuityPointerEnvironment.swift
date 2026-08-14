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

    private var currentEvent: NSEvent?
    private var monitorGeneration: UInt64 = 0

    func start(_ handler: @escaping @MainActor (HostPointerSample) -> Void)
        -> AnyObject {
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
                self.deliver(sample, sourceEvent: eventBox.event, to: handler)
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
        handler: @escaping @MainActor (HostPointerSample) -> Void,
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
                    Task { @MainActor in deliver(sample) }
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
        let handler: @MainActor (HostPointerSample) -> Void
        let tapDisabled: @MainActor (String) -> Void
        let flipHeight: CGFloat
        var port: CFMachPort?

        init(handler: @escaping @MainActor (HostPointerSample) -> Void,
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

    nonisolated private static func sample(
        _ event: CGEvent, type: CGEventType, flipHeight: CGFloat
    ) -> HostPointerSample? {
        let kind: HostPointerSample.Kind
        let buttonsDown: Bool
        switch type {
        case .leftMouseDown:
            kind = .primaryDown
            buttonsDown = true
        case .leftMouseUp:
            kind = .primaryUp
            buttonsDown = false
        case .leftMouseDragged:
            kind = .moved
            buttonsDown = true
        case .mouseMoved:
            kind = .moved
            buttonsDown = false
        case .rightMouseDragged, .otherMouseDragged:
            /* The pointer really is moving, so the guest must follow — but
               only the primary button drags, on a machine that has one. */
            kind = .moved
            buttonsDown = false
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

    func showFileEdge(_ edge: ContinuitySharedEdge,
                      callbacks: ContinuityFileEdge.Callbacks) -> AnyObject {
        let fileEdge = ContinuityFileEdge(edge: edge, callbacks: callbacks)
        activeFileEdge = fileEdge
        return fileEdge
    }

    func updateFileEdge(_ token: AnyObject, edge: ContinuitySharedEdge,
                        callbacks: ContinuityFileEdge.Callbacks) {
        guard let edgeWindow = token as? ContinuityFileEdge else { return }
        edgeWindow.update(edge: edge)
        edgeWindow.update(callbacks: callbacks)
    }

    func hideFileEdge(_ token: AnyObject) {
        let fileEdge = token as? ContinuityFileEdge
        fileEdge?.close()
        if activeFileEdge === fileEdge { activeFileEdge = nil }
    }

    func beginFileDrag(_ item: HostFileDragItem,
                       at screenPoint: CGPoint) -> Bool {
        guard let edge = activeFileEdge else { return false }
        return edge.beginFileDrag(item, at: screenPoint,
                                  sourceEvent: currentEvent)
    }

    private weak var activeFileEdge: ContinuityFileEdge?

    private func deliver(
        _ event: NSEvent,
        to handler: @escaping @MainActor (HostPointerSample) -> Void
    ) {
        deliver(Self.sample(event), sourceEvent: event, to: handler)
    }

    private func deliver(
        _ sample: HostPointerSample,
        sourceEvent: NSEvent,
        to handler: @escaping @MainActor (HostPointerSample) -> Void
    ) {
        currentEvent = sourceEvent
        handler(sample)
        currentEvent = nil
    }

    nonisolated private static func sample(_ event: NSEvent)
        -> HostPointerSample {
        let kind: HostPointerSample.Kind
        switch event.type {
        case .leftMouseDown:
            kind = .primaryDown
        case .leftMouseUp:
            kind = .primaryUp
        default:
            kind = .moved
        }
        /* NSEvent's mouse delta is device-oriented: positive Y means down.
           The display arrangement is AppKit-oriented, so invert it once at
           the adapter and keep every geometry function in one coordinate
           system. This remains metal-probe-required on the PowerBook rig. */
        return HostPointerSample(
            kind: kind, location: NSEvent.mouseLocation,
            delta: CGPoint(x: event.deltaX, y: -event.deltaY),
            buttonsDown: NSEvent.pressedMouseButtons != 0,
            eventUptime: ProcessInfo.processInfo.systemUptime)
    }
}
