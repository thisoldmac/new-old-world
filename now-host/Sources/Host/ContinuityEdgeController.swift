import AppKit
import Combine
import CoreGraphics
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
    /// Host monotonic uptime, captured before a global monitor hops to the
    /// main actor.
    let eventUptime: TimeInterval

    init(kind: Kind, location: CGPoint, delta: CGPoint, buttonsDown: Bool,
         eventUptime: TimeInterval = 0) {
        self.kind = kind
        self.location = location
        self.delta = delta
        self.buttonsDown = buttonsDown
        self.eventUptime = eventUptime
    }
}

@MainActor
protocol ContinuityPointerEnvironment: AnyObject {
    /// The AppKit event a sample came from, when one exists. It is delivered
    /// BESIDE the sample rather than remembered in a mutable field on the
    /// environment: the CGEvent tap has no NSEvent at all, and the field it
    /// used to be read from was provably nil on exactly the path that needed
    /// it — a smuggled value that failed silently. Explicit and optional
    /// makes the absence a thing the caller must answer for.
    typealias SampleHandler = @MainActor (HostPointerSample, NSEvent?) -> Void

    func start(_ handler: @escaping SampleHandler) -> AnyObject
    func stop(_ token: AnyObject)
    func hideCursor(on displayID: UInt32)
    func showCursor(on displayID: UInt32)
    func moveCursor(on displayID: UInt32, to point: CGPoint)
    /// Detaches the on-screen cursor from the mouse hardware, or re-attaches
    /// it. Deltas keep arriving either way; only the drawn cursor stops
    /// moving. Returns false when the window server refused, which the
    /// caller must report — a cursor left detached is a mouse the human
    /// cannot use.
    func setCursorMovementAssociated(_ associated: Bool) -> Bool
    /// A *consuming* capture of host mouse input, alive only while the guest
    /// owns the pointer. Returns nil when the platform refused (no
    /// Accessibility permission); the caller degrades to the observe-only
    /// monitor rather than failing.
    func startInputCapture(
        handler: @escaping SampleHandler,
        tapDisabled: @escaping @MainActor (String) -> Void
    ) -> AnyObject?
    func stopInputCapture(_ token: AnyObject)
    func showFileEdge(_ edge: ContinuitySharedEdge,
                      callbacks: ContinuityFileEdge.Callbacks) -> AnyObject
    func updateFileEdge(_ token: AnyObject, edge: ContinuitySharedEdge,
                        callbacks: ContinuityFileEdge.Callbacks)
    func hideFileEdge(_ token: AnyObject)
    /// Starts the native drag from a REAL host mouse event. Non-optional on
    /// purpose: AppKit owns a gesture only when it can see the event that
    /// began it, and a synthesized stand-in is the shape that failed
    /// attended testing. A caller with no event must refuse out loud instead
    /// of calling this.
    func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                       sourceEvent: NSEvent) -> Bool
}


@MainActor
protocol ContinuityEdgeDriving: AnyObject {
    var keyboardForwardingEnabled: Bool { get }
    var escapeShortcut: ContinuityEscapeShortcut { get }
    func pointerMoved(to point: MirrorKit.Point)
    func pointerLeft()
    func primaryDown(at point: MirrorKit.Point, inMenuBar: Bool,
                     sourceUptime: TimeInterval?) -> Bool
    func primaryDragged(to point: MirrorKit.Point) -> Bool
    func primaryUp(at point: MirrorKit.Point) -> Bool
    func keyboardEvent(_ sample: HostKeySample) -> Bool
}

@MainActor
final class ContinuityEdgeController: ObservableObject {
    typealias Audit = (HostLog.LogLevel, String) -> Void

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

    private struct PendingCursorWarp {
        let point: CGPoint
        let requestedAt: TimeInterval
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var status = "off"

    private let layout: ContinuityDisplayLayout
    private weak var driver: ContinuityEdgeDriving?
    private let environment: ContinuityPointerEnvironment
    private let keyboardEnvironment: ContinuityKeyboardEnvironment
    private let audit: Audit
    private let uptime: () -> TimeInterval
    private var monitor: AnyObject?
    private var fileEdge: AnyObject?
    private var layoutSubscription: AnyCancellable?
    private var pending: Ownership?
    private var ownership: Ownership?
    private var cursorHiddenOn: UInt32?
    private var inputCapture: AnyObject?
    private var cursorDissociated = false
    private var keyboardMonitor: AnyObject?
    private var pendingCursorWarp: PendingCursorWarp?
    private var suppressedCursorWarps: UInt32 = 0
    private var hostFileDrag = false
    private var guestFileCandidate: HostFileDragItem?
    private var guestFileAtPoint: ((MirrorKit.Point) -> HostFileDragItem?)?
    private var hostFilesDropped:
        ((NSPasteboard, MirrorKit.Point) -> Bool)?

    init(layout: ContinuityDisplayLayout,
         driver: ContinuityEdgeDriving,
         environment: ContinuityPointerEnvironment? = nil,
         keyboardEnvironment: ContinuityKeyboardEnvironment? = nil,
         audit: Audit? = nil,
         uptime: @escaping () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         }) {
        self.layout = layout
        self.driver = driver
        self.environment = environment
            ?? AppKitContinuityPointerEnvironment()
        self.keyboardEnvironment = keyboardEnvironment
            ?? AppKitContinuityKeyboardEnvironment()
        self.audit = audit ?? { HostLog.shared.write($0, "continuity", $1) }
        self.uptime = uptime
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

    /// Whether the file seam has an owner at all. Both callbacks are a
    /// precondition for creating the AppKit destination, so their absence is
    /// the difference between a drop that refuses and a strip that is not
    /// there — worth being able to ask from outside.
    var fileDraggingConfigured: Bool {
        guestFileAtPoint != nil && hostFilesDropped != nil
    }

    func start() {
        guard monitor == nil else {
            refreshReadyStatus()
            return
        }
        monitor = environment.start { [weak self] sample, sourceEvent in
            self?.received(sample, sourceEvent: sourceEvent)
        }
        refreshFileEdge()
        state = .ready
        refreshReadyStatus()
    }

    func stop(reason: String = "Continuity Mode disabled") {
        if state == .arming || state == .active { driver?.pointerLeft() }
        endOwnership(nextState: .disabled, status: reason)
        if let monitor { environment.stop(monitor) }
        monitor = nil
        pendingCursorWarp = nil
        if let fileEdge { environment.hideFileEdge(fileEdge) }
        fileEdge = nil
    }

    func transportPhaseChanged(_ phase: MirrorContinuityController.Phase) {
        switch phase {
        case .active:
            guard let pending else { return }
            self.pending = nil
            ownership = pending
            /* State and the plain status are settled before the captures are
               armed, so a capture that has to report a missing permission
               overwrites the plain line instead of being overwritten by it. */
            state = .active
            status = hostFileDrag
                ? "Dragging a host file on the guest display"
                : "Pointer is on the guest display"
            if !hostFileDrag {
                hideHostCursor(for: pending)
                startKeyboardCapture()
            }
        case .idle:
            guard state == .arming || state == .active else { return }
            endOwnership(nextState: monitor == nil ? .disabled : .ready,
                         status: nil)
        case .arming:
            break
        }
    }

    func transportEnded(reason: String) {
        endOwnership(
            nextState: monitor == nil ? .disabled : .ready,
            status: "Guest returned pointer control: \(reason)")
    }

    private func received(_ sample: HostPointerSample,
                          sourceEvent: NSEvent?) {
        if consumeExpectedCursorWarp(sample) { return }
        switch state {
        case .disabled:
            return
        case .ready:
            beginEntryIfNeeded(sample)
        case .arming:
            break
        case .active:
            driveGuest(with: sample, sourceEvent: sourceEvent)
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
        suppressedCursorWarps = 0
        state = .arming
        status = "Connecting the guest pointer…"
        driver?.pointerMoved(to: .init(x: Int(guest.x), y: Int(guest.y)))
    }

    private func driveGuest(with sample: HostPointerSample,
                            sourceEvent: NSEvent?) {
        guard var ownership else { return }
        if hostFileDrag,
           sample.kind == .primaryDown || sample.kind == .primaryUp {
            return
        }
        if sample.kind == .primaryDown {
            let point = mirrorPoint(ownership.guestPoint)
            guestFileCandidate = guestFileAtPoint?(point)
            let consumed = driver?.primaryDown(at: point,
                inMenuBar: point.y < HitTester.menubarHeight,
                sourceUptime: sample.eventUptime > 0
                    ? sample.eventUptime : nil) ?? false
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
        let factor = layout.guestScale
        let next = CGPoint(
            x: ownership.guestPoint.x + sample.delta.x / factor,
            y: ownership.guestPoint.y - sample.delta.y / factor)
        if ContinuityDisplayGeometry.crossedBack(
            next, through: ownership.edge.guestSide,
            guestPixels: layout.guestSize) {
            ownership.guestPoint = next
            audit(.info, "shared edge crossing: guest="
                + "\(Int(next.x)),\(Int(next.y)), delta="
                + "\(Int(sample.delta.x)),\(Int(sample.delta.y)), host="
                + "\(Int(sample.location.x)),\(Int(sample.location.y)), "
                + "suppressedWarps=\(suppressedCursorWarps)")
            if sample.buttonsDown, let item = guestFileCandidate {
                returnGuestFileToHost(item, from: ownership,
                                      sourceEvent: sourceEvent)
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
        audit(.info, "returning pointer to host: reason=\(reason), guest="
            + "\(Int(ownership.guestPoint.x)),\(Int(ownership.guestPoint.y)), "
            + "suppressedWarps=\(suppressedCursorWarps)")
        driver?.pointerLeft()
        endOwnership(
            nextState: .ready,
            status: "Returned at the shared edge (\(reason))")
    }

    /// Releases every resource scoped to guest pointer ownership. Callers
    /// remain responsible for transport-specific work such as sending
    /// `pointerLeft` or removing the observation monitor.
    private func endOwnership(nextState: State, status nextStatus: String?) {
        restoreHostCursor(from: ownership ?? pending)
        stopKeyboardCapture()
        pending = nil
        ownership = nil
        hostFileDrag = false
        guestFileCandidate = nil
        state = nextState
        if let nextStatus {
            status = nextStatus
        } else {
            refreshReadyStatus()
        }
    }

    private func startKeyboardCapture() {
        guard keyboardMonitor == nil else { return }
        guard let driver else { return }
        let policy = ContinuityKeyboardCapturePolicy(
            forwardingEnabled: driver.keyboardForwardingEnabled,
            escapeShortcut: driver.escapeShortcut)
        keyboardMonitor = keyboardEnvironment.start(
            policy: policy,
            handler: { [weak self] sample in
                guard let self, self.state == .active,
                      let driver = self.driver else { return }
                if driver.escapeShortcut.matches(sample) {
                    if let ownership = self.ownership {
                        self.returnToHost(
                            ownership, reason: "escape shortcut")
                    }
                    return
                }
                guard driver.keyboardForwardingEnabled else { return }
                if !driver.keyboardEvent(sample) {
                    self.audit(
                        .error,
                        "captured keyboard event could not be queued: "
                            + "action=\(sample.action), code=\(sample.code)")
                }
            }, tapDisabled: { [weak self] reason in
                self?.audit(
                    .warn,
                    "keyboard event tap was disabled by \(reason); "
                        + "re-enabled immediately")
            })
        if keyboardMonitor == nil {
            status = "Pointer is on the guest display; keyboard capture "
                + "needs Accessibility permission"
        }
    }

    func keyboardConfigurationChanged() {
        guard state == .active else { return }
        stopKeyboardCapture()
        startKeyboardCapture()
    }

    private func stopKeyboardCapture() {
        guard let keyboardMonitor else { return }
        keyboardEnvironment.stop(keyboardMonitor)
        self.keyboardMonitor = nil
    }

    /// Hands a held guest item to AppKit as the pointer crosses back.
    ///
    /// `sourceEvent` is the real host mouse event behind the crossing
    /// sample. The consuming CGEvent tap has none — it delivers CGEvents —
    /// so this refuses by name there rather than feeding AppKit a
    /// synthesized gesture, which is what shipped and failed before.
    private func returnGuestFileToHost(_ item: HostFileDragItem,
                                       from ownership: Ownership,
                                       sourceEvent: NSEvent?) {
        let returnPoint = ContinuityDisplayGeometry.hostReturnPoint(
            for: ownership.guestPoint, edge: ownership.edge,
            guestFrame: layout.guestFrame, scale: layout.guestScale)
        driver?.pointerLeft()
        restoreHostCursor(from: ownership)
        self.ownership = nil
        pending = nil
        guestFileCandidate = nil
        state = .ready
        guard let sourceEvent else {
            audit(.error, "cannot hand the guest file to this Mac: the "
                + "crossing sample carried no host mouse event, so AppKit "
                + "has no gesture to start a drag from")
            status = "Could not start the host file drag: this Mac saw no "
                + "mouse event behind the crossing"
            return
        }
        if environment.beginFileDrag(item, at: returnPoint,
                                     sourceEvent: sourceEvent) {
            status = "Copying the guest file to this Mac on release"
        } else {
            audit(.error, "the host file drag was refused by AppKit at "
                + "\(Int(returnPoint.x)),\(Int(returnPoint.y))")
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
        beginHostInputCapture()
        pinHostCursor(for: ownership)
    }

    /// Takes the host's mouse away from the host for the length of the pass:
    /// the cursor stops following the hardware, and the events are consumed
    /// rather than merely observed. Measured on metal 2026-08-13, the
    /// observe-only monitor left every guest click landing a second time as a
    /// real host click at the pinned point.
    private func beginHostInputCapture() {
        if !cursorDissociated {
            /* The pin warps below stay in place but go inert: with the cursor
               detached there is nothing for them to drag, and nothing comes
               back as a phantom delta for the echo filter to miss under
               load. */
            if environment.setCursorMovementAssociated(false) {
                cursorDissociated = true
            } else {
                audit(.warn, "could not detach the host cursor from the "
                    + "mouse; warp-echo suppression is carrying this pass")
            }
        }
        guard inputCapture == nil else { return }
        inputCapture = environment.startInputCapture(
            handler: { [weak self] sample, sourceEvent in
                /* The tap hops to the main actor, so a sample can outlive the
                   pass that captured it. */
                guard let self, self.state == .active else { return }
                self.received(sample, sourceEvent: sourceEvent)
            },
            tapDisabled: { [weak self] reason in
                self?.audit(.warn, "pointer event tap was disabled by "
                    + "\(reason); re-enabled immediately")
            })
        if inputCapture == nil {
            /* Degraded, not broken: the observe-only monitor still drives the
               guest. Name the consequence, because a leak nobody can see is
               how this one survived to be measured on metal. */
            audit(.error, "could not capture host input (Accessibility "
                + "permission); host clicks will also reach host apps")
            status = "Pointer is on the guest display; host clicks also "
                + "reach this Mac without Accessibility permission"
        }
    }

    private func endHostInputCapture() {
        if let inputCapture { environment.stopInputCapture(inputCapture) }
        inputCapture = nil
    }

    private func reassociateHostCursor() {
        guard cursorDissociated else { return }
        if environment.setCursorMovementAssociated(true) {
            cursorDissociated = false
        } else {
            /* Leave the flag set so the next exit tries again: the worst
               failure this whole change can produce is a mouse the human
               cannot move. */
            audit(.error, "could not re-attach the host cursor to the mouse")
        }
    }

    private func pinHostCursor(for ownership: Ownership) {
        let host = ownership.edge.host.frame
        let point = CGPoint(x: ownership.hostAnchor.x - host.minX,
                            y: host.maxY - ownership.hostAnchor.y)
        expectCursorWarp(to: ownership.hostAnchor)
        environment.moveCursor(on: ownership.edge.host.id, to: point)
    }

    /// The single funnel every ownership exit passes through. Input capture
    /// and cursor re-association are torn down OUTSIDE the hidden-cursor
    /// guard on purpose: a host file drag arms neither, and an exit that
    /// skipped the teardown because nothing was hidden would leave the mouse
    /// detached.
    private func restoreHostCursor(from ownership: Ownership?) {
        endHostInputCapture()
        if let id = cursorHiddenOn {
            if let ownership {
                let hostPoint = ContinuityDisplayGeometry.hostReturnPoint(
                    for: ownership.guestPoint, edge: ownership.edge,
                    guestFrame: layout.guestFrame, scale: layout.guestScale)
                let host = ownership.edge.host.frame
                expectCursorWarp(to: hostPoint)
                environment.moveCursor(
                    on: ownership.edge.host.id,
                    to: CGPoint(x: hostPoint.x - host.minX,
                                y: host.maxY - hostPoint.y))
            }
            environment.showCursor(on: id)
            cursorHiddenOn = nil
        }
        /* Last, so the return warp above lands while the cursor is still
           detached and cannot echo back as motion. */
        reassociateHostCursor()
    }

    private func expectCursorWarp(to point: CGPoint) {
        pendingCursorWarp = PendingCursorWarp(
            point: point, requestedAt: uptime())
    }

    private func consumeExpectedCursorWarp(_ sample: HostPointerSample) -> Bool {
        guard sample.kind == .moved, sample.eventUptime > 0,
              let pendingCursorWarp else { return false }
        let age = sample.eventUptime - pendingCursorWarp.requestedAt
        if age < -0.01 { return false }
        if age > 0.25 {
            self.pendingCursorWarp = nil
            return false
        }
        guard abs(sample.location.x - pendingCursorWarp.point.x) <= 1,
              abs(sample.location.y - pendingCursorWarp.point.y) <= 1 else {
            return false
        }
        self.pendingCursorWarp = nil
        suppressedCursorWarps &+= 1
        return true
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
            if let inputCapture { environment.stopInputCapture(inputCapture) }
            if let keyboardMonitor { keyboardEnvironment.stop(keyboardMonitor) }
            if let fileEdge { environment.hideFileEdge(fileEdge) }
            if let id = cursorHiddenOn { environment.showCursor(on: id) }
            /* The last chance to give the mouse back, and unlike the audited
               paths above there is nobody left to report a failure to. */
            if cursorDissociated {
                _ = environment.setCursorMovementAssociated(true)
            }
        }
    }
}
