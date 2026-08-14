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
    /// Widens the sentinel strip into a catch surface, or narrows it back.
    ///
    /// Two physical pixels are enough to DETECT a crossing and far too few
    /// to CATCH one: the returning pointer is already moving, and the drag
    /// must begin over a real view of ours. The surface is widened for the
    /// length of one handoff — arming to the end of the drag session it
    /// starts — so the rest of the time the boundary pixel pair is all this
    /// app takes from whatever is underneath.
    func setFileEdgeCatching(_ token: AnyObject, _ catching: Bool)
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
    /// Puts a held pointer at `point` in a packet of its own, ahead of
    /// whatever the caller does next.
    ///
    /// `primaryDragged` only marks the position dirty and lets the cadence
    /// clock carry it, so a drag followed immediately by a release rides ONE
    /// packet — the guest sees the new position and the button edge together
    /// and is free to apply them in either order. The one place that
    /// difference is load-bearing is the cross-edge handoff: the Finder
    /// completes a move to wherever the pointer is when the button comes up,
    /// and "wherever the pointer is" must be the press origin, settled
    /// first, on the wire, as its own fact.
    func settleHeldPosition(to point: MirrorKit.Point) -> Bool
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
    /// Where on the guest the held gesture began. The cross returns the
    /// pointer here before releasing, so the Finder completes its move where
    /// the item already was. Nil whenever no press is held.
    private var pressOrigin: CGPoint?
    private var guestFileAtPoint: ((MirrorKit.Point) -> HostFileDragItem?)?
    private var guestSelectionItem: (() -> HostFileDragItem?)?
    private var hostFilesDropped:
        ((NSPasteboard, MirrorKit.Point) -> Bool)?
    private var pendingReturnDrag: PendingReturnDrag?
    /// A drag session THIS app started and macOS has not finished. While it
    /// is live every input path here stands down: the gesture belongs to
    /// AppKit, and anything of ours still reacting to the pointer is
    /// competing with the drag it just handed over.
    private var hostDragSessionLive = false
    private var standDownSamples: UInt32 = 0
    private var announcedOwnDragRefusal = false
    private var heldGesture: HeldGestureCustody?
    /// The last button state any sample reported. The escape chord arrives
    /// through the keyboard tap, which cannot see the mouse, and a handback
    /// taken with the button down is the one that needs custody.
    private var hostButtonsDown = false

    /// The host pointer came back while the physical button was still held.
    ///
    /// Nothing in macOS owns that press: the consuming tap swallowed its
    /// mouse-down, so no application holds the gesture and the first thing
    /// under the returning pointer inherits it — on metal, a host window
    /// touching the shared edge got DRAGGED. Custody keeps the tap alive so
    /// the held button reaches nothing at all, and ends at the physical
    /// release. The file handoff is the one exception, and it is the second
    /// half of the same rule rather than a hole in it: there the gesture is
    /// claimed by a drag session, which needs the real events the tap would
    /// swallow — so the catch surface is armed in front of the pointer
    /// FIRST, and the only window that can inherit the press is ours.
    private struct HeldGestureCustody {
        let reason: String
        var swallowed: UInt32 = 0
    }

    /// A crossing whose guest press has been released and whose host drag is
    /// waiting for the first REAL mouse event.
    ///
    /// It cannot start before that event exists. AppKit owns a gesture only
    /// from an event it can see, and the crossing sample itself arrives
    /// through the consuming CGEvent tap, which has none by construction. The
    /// button is still physically held, so real events resume the moment the
    /// tap dies — this is the half-instant in between, made a state rather
    /// than a hope.
    private struct PendingReturnDrag {
        let item: HostFileDragItem
        let returnPoint: CGPoint
        var waitedForRealEvent = false
    }

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

    /// Binds a press to the guest's PUBLISHED SELECTION rather than to a
    /// scene hit test.
    ///
    /// The stub is the truth for this lane, and the reason is not
    /// preference: during a drag the guest cannot be asked anything, so what
    /// the press binds to has to have arrived before the press. A scene
    /// lookup would also make edge-mode file drags depend on the Mirror
    /// running, which is the dependency slice 1 spent its whole existence
    /// removing. The closure returns nil for an unusable selection and is
    /// responsible for saying WHY out loud — a silent nil here is the v1
    /// failure mode.
    func configureSelectionDragging(
        guestSelectionItem: @escaping () -> HostFileDragItem?
    ) {
        self.guestSelectionItem = guestSelectionItem
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
        endHeldCustody(reason: "Continuity stopped")
        hostDragSessionLive = false
        announcedOwnDragRefusal = false
        endOwnership(nextState: .disabled, status: reason)
        if let monitor { environment.stop(monitor) }
        monitor = nil
        pendingCursorWarp = nil
        if pendingReturnDrag != nil {
            audit(.warn, "the guest file drag was abandoned: Continuity "
                + "stopped before this Mac could start it")
            pendingReturnDrag = nil
        }
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
        hostButtonsDown = sample.buttonsDown
        if hostDragSessionLive {
            /* Counted rather than logged per sample: a burst would bury the
               line that matters, and the count at the end is the evidence
               that this gate was doing something. */
            standDownSamples &+= 1
            return
        }
        if consumeExpectedCursorWarp(sample) { return }
        if pendingReturnDrag != nil,
           resumeReturnDrag(with: sample, sourceEvent: sourceEvent) {
            return
        }
        if heldGesture != nil {
            holdGesture(sample)
            return
        }
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
            /* The selection stub wins outright where it is configured. It is
               not a better hit test, it is a different question: what the
               person picked, asked before the press, rather than what is
               under a point in a scene this lane may not have. */
            guestFileCandidate = guestSelectionItem != nil
                ? guestSelectionItem?()
                : guestFileAtPoint?(point)
            let consumed = driver?.primaryDown(at: point,
                inMenuBar: point.y < HitTester.menubarHeight,
                sourceUptime: sample.eventUptime > 0
                    ? sample.eventUptime : nil) ?? false
            if !consumed { guestFileCandidate = nil }
            pressOrigin = consumed ? ownership.guestPoint : nil
            pinHostCursor(for: ownership)
            return
        }
        if sample.kind == .primaryUp {
            _ = driver?.primaryUp(at: mirrorPoint(ownership.guestPoint))
            guestFileCandidate = nil
            pressOrigin = nil
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
            + "suppressedWarps=\(suppressedCursorWarps), "
            + "buttonsDown=\(hostButtonsDown ? 1 : 0)")
        driver?.pointerLeft()
        /* A held button is nobody's until the human lets go. `hostFileDrag`
           is excluded because there the held gesture is a foreign app's drag
           session which this app never captured and must not interrupt. */
        let held = hostButtonsDown && !hostFileDrag
        if held { beginHeldCustody(reason: reason) }
        endOwnership(
            nextState: .ready,
            status: held
                ? "Let go of the button to use this Mac again"
                : "Returned at the shared edge (\(reason))",
            keepInputCapture: held)
    }

    /// Takes the held press out of circulation. See `HeldGestureCustody`.
    private func beginHeldCustody(reason: String) {
        guard heldGesture == nil else { return }
        heldGesture = HeldGestureCustody(reason: reason)
        startConsumingTap()
        audit(inputCapture == nil ? .warn : .info,
              "host pointer came back with the button held (\(reason)); "
                + (inputCapture == nil
                    ? "this Mac has no input capture, so the held press will "
                        + "reach whatever is under the pointer"
                    : "this Mac's input stays captured until the button is "
                        + "released, so no window inherits the press"))
    }

    private func holdGesture(_ sample: HostPointerSample) {
        guard var custody = heldGesture else { return }
        guard sample.buttonsDown, sample.kind != .primaryUp else {
            endHeldCustody(reason: "the button was released")
            return
        }
        custody.swallowed &+= 1
        heldGesture = custody
    }

    private func endHeldCustody(reason: String) {
        guard let custody = heldGesture else { return }
        heldGesture = nil
        audit(.info, "held-button custody ended: reason=\(reason), "
            + "began=\(custody.reason), swallowed=\(custody.swallowed)")
        endHostInputCapture()
        reassociateHostCursor()
        refreshReadyStatus()
    }

    /// Releases every resource scoped to guest pointer ownership. Callers
    /// remain responsible for transport-specific work such as sending
    /// `pointerLeft` or removing the observation monitor.
    private func endOwnership(nextState: State, status nextStatus: String?,
                              keepInputCapture: Bool = false) {
        restoreHostCursor(from: ownership ?? pending,
                          keepInputCapture: keepInputCapture)
        stopKeyboardCapture()
        pending = nil
        ownership = nil
        hostFileDrag = false
        guestFileCandidate = nil
        pressOrigin = nil
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
    /// The order is the whole mechanism, so it is stated once here and
    /// pinned by a test:
    ///
    /// 0. **Put the guest pointer back where the press began**, in a packet
    ///    of its own, before anything else. The Finder completes a move to
    ///    wherever the pointer is when the button comes up: releasing at the
    ///    cross point drops the icon at the screen edge, which is cosmetic
    ///    from the desktop and a REAL file relocation when the drag started
    ///    inside a Finder window (metal, 2026-08-14). Released at the origin
    ///    it completes a no-op move onto the spot the item already occupies.
    /// 1. **Release the guest button.** v1 never did, and the item
    ///    stayed stuck to the Finder's cursor on the other machine. It goes
    ///    down the ordinary driver lane — the same release an ordinary
    ///    click sends — because there is no second way to end a press.
    /// 2. Tear the pass down exactly as an ordinary return does: pointer
    ///    left, cursor restored, tap stopped, ownership dropped.
    /// 3. Only THEN start the native drag, and only from a real event. The
    ///    crossing sample usually arrives through the consuming tap, which
    ///    has no NSEvent by construction; the physical button is still held,
    ///    so the first real `mouseDragged` after the tap dies is the gesture
    ///    AppKit can own. The strip widens into a catch surface BEFORE the
    ///    tap dies, so the window under the returning pointer is ours and
    ///    not whatever it is about to inherit the press, and it stays wide
    ///    until the session ends — narrowing it at the start moved the drag
    ///    source's own window out from under a live drag.
    private func returnGuestFileToHost(_ item: HostFileDragItem,
                                       from ownership: Ownership,
                                       sourceEvent: NSEvent?) {
        let returnPoint = ContinuityDisplayGeometry.hostReturnPoint(
            for: ownership.guestPoint, edge: ownership.edge,
            guestFrame: layout.guestFrame, scale: layout.guestScale)
        let origin = mirrorPoint(pressOrigin ?? ownership.guestPoint)
        _ = driver?.settleHeldPosition(to: origin)
        audit(.info, "guest pointer returned to the press origin before the "
            + "release: origin=\(origin.x),\(origin.y), cross="
            + "\(Int(ownership.guestPoint.x)),\(Int(ownership.guestPoint.y))"
            + " — releasing at the cross point completes a Finder move to "
            + "the screen edge")
        _ = driver?.primaryUp(at: origin)
        audit(.info, "guest press released before the cross: guest="
            + "\(origin.x),\(origin.y) — the dragged icon must snap "
            + "back on the Mac")
        driver?.pointerLeft()
        /* The catch surface is armed BEFORE the tap comes down, not after.
           Between those two instants the physical button is held and no
           application owns it, so whatever is under the pointer inherits
           the gesture — the same defect that drags a host window on an
           ordinary held handback. Widened first, the window under the
           pointer is ours. */
        setFileEdgeCatching(true)
        restoreHostCursor(from: ownership)
        stopKeyboardCapture()
        self.ownership = nil
        pending = nil
        guestFileCandidate = nil
        pressOrigin = nil
        state = .ready
        pendingReturnDrag = PendingReturnDrag(item: item,
                                              returnPoint: returnPoint)
        if let sourceEvent {
            /* The observe-only monitor path already has one. Nothing waits. */
            startReturnDrag(with: sourceEvent)
            return
        }
        status = "Keep holding the button: finishing the file drag on this Mac"
        audit(.info, "guest file crossed with no host mouse event yet; "
            + "waiting for the first real one now the tap is down")
    }

    /// The second half of the crossing above, driven by whatever real event
    /// arrives first. Returns true when it consumed the sample.
    private func resumeReturnDrag(with sample: HostPointerSample,
                                  sourceEvent: NSEvent?) -> Bool {
        guard var waiting = pendingReturnDrag else { return false }
        if !sample.buttonsDown || sample.kind == .primaryUp {
            pendingReturnDrag = nil
            setFileEdgeCatching(false)
            audit(.warn, "the guest file drag was abandoned: the button was "
                + "released before this Mac saw a real mouse event to start "
                + "the drag from")
            status = "The file drag ended before this Mac could take it over"
            return true
        }
        guard let sourceEvent else {
            if !waiting.waitedForRealEvent {
                waiting.waitedForRealEvent = true
                pendingReturnDrag = waiting
                /* Once, not per sample: the tap can deliver a burst, and a
                   line per sample would bury the one that matters. */
                audit(.info, "still waiting for a real host mouse event: the "
                    + "held sample carried none")
            }
            return true
        }
        startReturnDrag(with: sourceEvent)
        return true
    }

    private func startReturnDrag(with sourceEvent: NSEvent) {
        guard let waiting = pendingReturnDrag else { return }
        pendingReturnDrag = nil
        let point = waiting.returnPoint
        /* The seed's provenance, before anything is done with it. A global
           monitor delivers events belonging to OTHER applications, so the
           window this gesture came from is the first thing to know when a
           session starts and then does nothing — and the first metal round
           had no line saying which it was. */
        audit(.info, "host drag seed event: type=\(sourceEvent.type.rawValue)"
            + ", windowNumber=\(sourceEvent.windowNumber), "
            + "ourWindow=\(sourceEvent.window == nil ? "no" : "yes"), "
            + "clickCount=\(sourceEvent.clickCount)")
        if environment.beginFileDrag(waiting.item, at: point,
                                     sourceEvent: sourceEvent) {
            /* Custody passes to AppKit here, which is the OTHER half of the
               held-button rule: nothing of ours may keep reacting to a
               pointer that now belongs to a drag session. */
            heldGesture = nil
            hostDragSessionLive = true
            standDownSamples = 0
            audit(.info, "host file drag started from a real mouse event at "
                + "\(Int(point.x)),\(Int(point.y)); this app stands down "
                + "until the session ends")
            status = "Copying the guest file to this Mac on release"
            /* The catch surface stays wide for the length of the session.
               Narrowing it here moved the drag source's own window out from
               under a live drag, one frame after starting it. */
            return
        }
        audit(.error, "the host file drag was refused by AppKit at "
            + "\(Int(point.x)),\(Int(point.y))")
        status = "Could not start the host file drag"
        setFileEdgeCatching(false)
        endHeldCustody(reason: "AppKit refused the drag")
    }

    /// macOS finished with the session this app started, however it ended.
    private func hostDragSessionEnded(_ operation: NSDragOperation,
                                      at screenPoint: CGPoint) {
        guard hostDragSessionLive else { return }
        hostDragSessionLive = false
        announcedOwnDragRefusal = false
        setFileEdgeCatching(false)
        let took = operation.isEmpty ? "nobody" : "\(operation.rawValue)"
        audit(operation.isEmpty ? .warn : .info,
              "host file drag session ended at "
                + "\(Int(screenPoint.x)),\(Int(screenPoint.y)): "
                + "operation=\(took), standDownSamples=\(standDownSamples)"
                + (operation.isEmpty
                    ? " — nothing accepted the file, so no promise was ever "
                        + "asked for"
                    : " — the promise lane owns the outcome from here"))
        standDownSamples = 0
        if operation.isEmpty {
            status = "Nothing on this Mac took the guest file"
        }
        /* The button may already be up by now; if it is not, the gesture is
           back to being nobody's and custody applies again. */
        if hostButtonsDown { beginHeldCustody(reason: "the drag session ended "
            + "with the button still held") }
        refreshReadyStatus()
    }

    private func setFileEdgeCatching(_ catching: Bool) {
        guard let fileEdge else { return }
        environment.setFileEdgeCatching(fileEdge, catching)
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
        startConsumingTap()
    }

    /// The consuming tap on its own, without touching the cursor. Held-button
    /// custody wants exactly this half: the events must stop reaching other
    /// applications, and the human must still be able to move the pointer.
    private func startConsumingTap() {
        guard inputCapture == nil else { return }
        inputCapture = environment.startInputCapture(
            handler: { [weak self] sample, sourceEvent in
                /* The tap hops to the main actor, so a sample can outlive the
                   pass that captured it — but not the custody that outlives
                   the pass ON PURPOSE. A capture still swallowing events
                   whose samples this controller drops is the worst of both:
                   the human's input reaches nothing, and nothing here can
                   see the release that would give it back. */
                guard let self,
                      self.state == .active || self.heldGesture != nil
                        || self.pendingReturnDrag != nil else { return }
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
    private func restoreHostCursor(from ownership: Ownership?,
                                   keepInputCapture: Bool = false) {
        if !keepInputCapture { endHostInputCapture() }
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
            },
            dragEnded: { [weak self] operation, point in
                self?.hostDragSessionEnded(operation, at: point)
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
        /* The strip is a destination for FOREIGN drags. A drag this app
           started is refused by identity in the view itself; this is the
           second door onto the same rule, because a host→guest pass armed
           during our own guest→host handoff would steer the guest with the
           file that is on its way here. */
        if hostDragSessionLive || pendingReturnDrag != nil {
            if !announcedOwnDragRefusal {
                announcedOwnDragRefusal = true
                audit(.info, "the shared edge refused an incoming file: this "
                    + "Mac is in the middle of taking one FROM the guest")
            }
            return false
        }
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
