import AppKit
import Combine
import Foundation
import MirrorKit
import MirrorKitUI

struct HostPointerSample: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case moved
        case primaryDown
        case primaryUp
    }

    let kind: Kind
    /// AppKit global coordinates: origin at the lower-left, positive Y up.
    let location: CGPoint
    /// Mouse motion expressed in the same positive-Y-up coordinate space.
    let delta: CGPoint
    let buttonsDown: Bool
}

@MainActor
protocol ContinuityPointerEnvironment: AnyObject {
    func start(_ handler: @escaping @MainActor (HostPointerSample) -> Void)
        -> AnyObject
    func stop(_ token: AnyObject)
    func hideCursor(on displayID: UInt32)
    func showCursor(on displayID: UInt32)
    func moveCursor(on displayID: UInt32, to point: CGPoint)
    func showFileEdge(_ edge: ContinuitySharedEdge,
                      callbacks: ContinuityFileEdge.Callbacks) -> AnyObject
    func updateFileEdge(_ token: AnyObject, edge: ContinuitySharedEdge,
                        callbacks: ContinuityFileEdge.Callbacks)
    func hideFileEdge(_ token: AnyObject)
    func beginFileDrag(_ item: HostFileDragItem,
                       at screenPoint: CGPoint) -> Bool
}

@MainActor
private final class AppKitContinuityPointerEnvironment:
    ContinuityPointerEnvironment {
    private final class Monitors {
        var local: Any?
        var global: Any?
    }

    private var currentEvent: NSEvent?

    func start(_ handler: @escaping @MainActor (HostPointerSample) -> Void)
        -> AnyObject {
        let monitors = Monitors()
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
            MainActor.assumeIsolated { self?.deliver(event, to: handler) }
        }
        return monitors
    }

    func stop(_ token: AnyObject) {
        guard let monitors = token as? Monitors else { return }
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
        currentEvent = event
        handler(Self.sample(event))
        currentEvent = nil
    }

    private static func sample(_ event: NSEvent) -> HostPointerSample {
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
            buttonsDown: NSEvent.pressedMouseButtons != 0)
    }
}

@MainActor
protocol ContinuityEdgeDriving: AnyObject {
    func pointerMoved(to point: MirrorKit.Point)
    func pointerLeft()
    func primaryDown(at point: MirrorKit.Point, inMenuBar: Bool) -> Bool
    func primaryDragged(to point: MirrorKit.Point) -> Bool
    func primaryUp(at point: MirrorKit.Point) -> Bool
}

@MainActor
final class ContinuityEdgeController: ObservableObject {
    enum State: Equatable {
        case disabled
        case ready
        case arming
        case active
    }

    private struct Ownership {
        let edge: ContinuitySharedEdge
        var guestPoint: CGPoint
        let hostAnchor: CGPoint
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var status = "off"

    private let layout: ContinuityDisplayLayout
    private weak var driver: ContinuityEdgeDriving?
    private let environment: ContinuityPointerEnvironment
    private var monitor: AnyObject?
    private var fileEdge: AnyObject?
    private var layoutSubscription: AnyCancellable?
    private var pending: Ownership?
    private var ownership: Ownership?
    private var cursorHiddenOn: UInt32?
    private var hostFileDrag = false
    private var guestFileCandidate: HostFileDragItem?
    private var guestFileAtPoint: ((MirrorKit.Point) -> HostFileDragItem?)?
    private var hostFilesDropped:
        ((NSPasteboard, MirrorKit.Point) -> Bool)?

    init(layout: ContinuityDisplayLayout,
         driver: ContinuityEdgeDriving,
         environment: ContinuityPointerEnvironment? = nil) {
        self.layout = layout
        self.driver = driver
        self.environment = environment
            ?? AppKitContinuityPointerEnvironment()
        layoutSubscription = layout.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.refreshFileEdge()
                self?.refreshReadyStatus()
            }
        }
    }

    /// Installs the copy-only file seam without changing pointer or wire
    /// ownership. The guest resolver binds one exact scene item at mouse-down;
    /// the host callback resolves the live guest target at native drop time.
    func configureFileDragging(
        guestFileAtPoint:
            @escaping (MirrorKit.Point) -> HostFileDragItem?,
        hostFilesDropped:
            @escaping (NSPasteboard, MirrorKit.Point) -> Bool
    ) {
        self.guestFileAtPoint = guestFileAtPoint
        self.hostFilesDropped = hostFilesDropped
        refreshFileEdge()
    }

    func start() {
        guard monitor == nil else {
            refreshReadyStatus()
            return
        }
        monitor = environment.start { [weak self] sample in
            self?.received(sample)
        }
        refreshFileEdge()
        state = .ready
        refreshReadyStatus()
    }

    func stop(reason: String = "Continuity Mode disabled") {
        if state == .arming || state == .active { driver?.pointerLeft() }
        restoreHostCursor(from: ownership ?? pending)
        pending = nil
        ownership = nil
        hostFileDrag = false
        guestFileCandidate = nil
        if let monitor { environment.stop(monitor) }
        monitor = nil
        if let fileEdge { environment.hideFileEdge(fileEdge) }
        fileEdge = nil
        state = .disabled
        status = reason
    }

    func transportPhaseChanged(_ phase: MirrorContinuityController.Phase) {
        switch phase {
        case .active:
            guard let pending else { return }
            self.pending = nil
            ownership = pending
            if !hostFileDrag { hideHostCursor(for: pending) }
            state = .active
            status = hostFileDrag
                ? "Dragging a host file on the guest display"
                : "Pointer is on the guest display"
        case .idle:
            guard state == .arming || state == .active else { return }
            restoreHostCursor(from: ownership ?? pending)
            pending = nil
            ownership = nil
            hostFileDrag = false
            guestFileCandidate = nil
            state = monitor == nil ? .disabled : .ready
            refreshReadyStatus()
        case .arming:
            break
        }
    }

    func transportEnded(reason: String) {
        restoreHostCursor(from: ownership ?? pending)
        pending = nil
        ownership = nil
        hostFileDrag = false
        guestFileCandidate = nil
        state = monitor == nil ? .disabled : .ready
        status = "Guest returned pointer control: \(reason)"
    }

    private func received(_ sample: HostPointerSample) {
        switch state {
        case .disabled:
            return
        case .ready:
            beginEntryIfNeeded(sample)
        case .arming:
            break
        case .active:
            driveGuest(with: sample)
        }
    }

    private func beginEntryIfNeeded(_ sample: HostPointerSample) {
        guard sample.kind == .moved, !sample.buttonsDown,
              let edge = layout.sharedEdge,
              isCrossingOutward(sample, edge: edge) else { return }
        let guest = ContinuityDisplayGeometry.guestEntryPoint(
            at: sample.location, edge: edge, guestFrame: layout.guestFrame,
            guestPixels: layout.guestSize, scale: layout.guestScale)
        let anchor = ContinuityDisplayGeometry.hostReturnPoint(
            for: guest, edge: edge, guestFrame: layout.guestFrame,
            scale: layout.guestScale)
        pending = Ownership(edge: edge, guestPoint: guest,
                            hostAnchor: anchor)
        state = .arming
        status = "Connecting the guest pointer…"
        driver?.pointerMoved(to: .init(x: Int(guest.x), y: Int(guest.y)))
    }

    private func driveGuest(with sample: HostPointerSample) {
        guard var ownership else { return }
        if hostFileDrag,
           sample.kind == .primaryDown || sample.kind == .primaryUp {
            return
        }
        if sample.kind == .primaryDown {
            let point = mirrorPoint(ownership.guestPoint)
            guestFileCandidate = guestFileAtPoint?(point)
            let consumed = driver?.primaryDown(at: point,
                                               inMenuBar: false) ?? false
            if !consumed { guestFileCandidate = nil }
            pinHostCursor(for: ownership)
            return
        }
        if sample.kind == .primaryUp {
            _ = driver?.primaryUp(at: mirrorPoint(ownership.guestPoint))
            guestFileCandidate = nil
            pinHostCursor(for: ownership)
            return
        }
        let factor = CGFloat(layout.guestScale.rawValue)
        let next = CGPoint(
            x: ownership.guestPoint.x + sample.delta.x / factor,
            y: ownership.guestPoint.y - sample.delta.y / factor)
        if ContinuityDisplayGeometry.crossedBack(
            next, through: ownership.edge.guestSide,
            guestPixels: layout.guestSize) {
            ownership.guestPoint = next
            if sample.buttonsDown, let item = guestFileCandidate {
                returnGuestFileToHost(item, from: ownership)
            } else {
                returnToHost(ownership, reason: "shared edge crossed")
            }
            return
        }
        ownership.guestPoint = CGPoint(
            x: min(max(0, next.x), max(0, layout.guestSize.width - 1)),
            y: min(max(0, next.y), max(0, layout.guestSize.height - 1)))
        self.ownership = ownership
        let point = mirrorPoint(ownership.guestPoint)
        if hostFileDrag {
            driver?.pointerMoved(to: point)
        } else if sample.buttonsDown {
            _ = driver?.primaryDragged(to: point)
        } else {
            driver?.pointerMoved(to: point)
        }
        if !hostFileDrag { pinHostCursor(for: ownership) }
    }

    private func mirrorPoint(_ point: CGPoint) -> MirrorKit.Point {
        .init(x: Int(point.x), y: Int(point.y))
    }

    private func returnToHost(_ ownership: Ownership, reason: String) {
        driver?.pointerLeft()
        restoreHostCursor(from: ownership)
        self.ownership = nil
        pending = nil
        hostFileDrag = false
        guestFileCandidate = nil
        state = .ready
        status = "Returned at the shared edge (\(reason))"
    }

    private func returnGuestFileToHost(_ item: HostFileDragItem,
                                       from ownership: Ownership) {
        let returnPoint = ContinuityDisplayGeometry.hostReturnPoint(
            for: ownership.guestPoint, edge: ownership.edge,
            guestFrame: layout.guestFrame, scale: layout.guestScale)
        driver?.pointerLeft()
        restoreHostCursor(from: ownership)
        self.ownership = nil
        pending = nil
        guestFileCandidate = nil
        state = .ready
        if environment.beginFileDrag(item, at: returnPoint) {
            status = "Copying the guest file to this Mac on release"
        } else {
            status = "Could not start the host file drag"
        }
    }

    private func isCrossingOutward(_ sample: HostPointerSample,
                                   edge: ContinuitySharedEdge) -> Bool {
        let p = sample.location
        let threshold: CGFloat = 2
        switch edge.guestSide {
        case .left:
            return edge.overlap.contains(p.y)
                && p.x >= edge.host.frame.maxX - threshold
                && sample.delta.x > 0
        case .right:
            return edge.overlap.contains(p.y)
                && p.x <= edge.host.frame.minX + threshold
                && sample.delta.x < 0
        case .bottom:
            return edge.overlap.contains(p.x)
                && p.y >= edge.host.frame.maxY - threshold
                && sample.delta.y > 0
        case .top:
            return edge.overlap.contains(p.x)
                && p.y <= edge.host.frame.minY + threshold
                && sample.delta.y < 0
        }
    }

    private func hideHostCursor(for ownership: Ownership) {
        let id = ownership.edge.host.id
        guard cursorHiddenOn == nil else { return }
        environment.hideCursor(on: id)
        cursorHiddenOn = id
        pinHostCursor(for: ownership)
    }

    private func pinHostCursor(for ownership: Ownership) {
        let host = ownership.edge.host.frame
        let point = CGPoint(x: ownership.hostAnchor.x - host.minX,
                            y: host.maxY - ownership.hostAnchor.y)
        environment.moveCursor(on: ownership.edge.host.id, to: point)
    }

    private func restoreHostCursor(from ownership: Ownership?) {
        guard let id = cursorHiddenOn else { return }
        if let ownership {
            let hostPoint = ContinuityDisplayGeometry.hostReturnPoint(
                for: ownership.guestPoint, edge: ownership.edge,
                guestFrame: layout.guestFrame, scale: layout.guestScale)
            let host = ownership.edge.host.frame
            environment.moveCursor(
                on: ownership.edge.host.id,
                to: CGPoint(x: hostPoint.x - host.minX,
                            y: host.maxY - hostPoint.y))
        }
        environment.showCursor(on: id)
        cursorHiddenOn = nil
    }

    private var fileEdgeCallbacks: ContinuityFileEdge.Callbacks {
        .init(
            entered: { [weak self] point in
                self?.hostFileEntered(at: point) ?? false
            },
            exited: { [weak self] in self?.hostFileExited() },
            dropped: { [weak self] pasteboard in
                self?.hostFileDropped(pasteboard) ?? false
            })
    }

    private func refreshFileEdge() {
        guard monitor != nil, guestFileAtPoint != nil,
              hostFilesDropped != nil, let edge = layout.sharedEdge else {
            if let fileEdge { environment.hideFileEdge(fileEdge) }
            fileEdge = nil
            return
        }
        if let fileEdge {
            environment.updateFileEdge(fileEdge, edge: edge,
                                       callbacks: fileEdgeCallbacks)
        } else {
            fileEdge = environment.showFileEdge(
                edge, callbacks: fileEdgeCallbacks)
        }
    }

    private func hostFileEntered(at hostPoint: CGPoint) -> Bool {
        if hostFileDrag { return state == .arming || state == .active }
        guard state == .ready, let edge = layout.sharedEdge else {
            return false
        }
        let guest = ContinuityDisplayGeometry.guestEntryPoint(
            at: hostPoint, edge: edge, guestFrame: layout.guestFrame,
            guestPixels: layout.guestSize, scale: layout.guestScale)
        let anchor = ContinuityDisplayGeometry.hostReturnPoint(
            for: guest, edge: edge, guestFrame: layout.guestFrame,
            scale: layout.guestScale)
        pending = Ownership(edge: edge, guestPoint: guest,
                            hostAnchor: anchor)
        hostFileDrag = true
        state = .arming
        status = "Connecting the guest file target…"
        driver?.pointerMoved(to: mirrorPoint(guest))
        return true
    }

    private func hostFileExited() {
        guard hostFileDrag, let current = ownership ?? pending else { return }
        returnToHost(current, reason: "host file left the shared edge")
    }

    private func hostFileDropped(_ pasteboard: NSPasteboard) -> Bool {
        guard hostFileDrag, let current = ownership ?? pending,
              let hostFilesDropped else { return false }
        let accepted = hostFilesDropped(
            pasteboard, mirrorPoint(current.guestPoint))
        returnToHost(current, reason: accepted
                     ? "host file released" : "guest target refused the file")
        return accepted
    }

    private func refreshReadyStatus() {
        guard state != .disabled else { return }
        if let edge = layout.sharedEdge {
            status = "Ready at \(edge.host.name)'s \(hostSide(edge)) edge"
        } else {
            status = "Place the guest display against a host display edge"
        }
    }

    private func hostSide(_ edge: ContinuitySharedEdge) -> String {
        switch edge.guestSide {
        case .left: return "right"
        case .right: return "left"
        case .bottom: return "top"
        case .top: return "bottom"
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let monitor { environment.stop(monitor) }
            if let fileEdge { environment.hideFileEdge(fileEdge) }
            if let id = cursorHiddenOn { environment.showCursor(on: id) }
        }
    }
}
