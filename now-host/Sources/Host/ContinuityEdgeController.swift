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
    /// Posts a synthetic primary button transition into the SESSION event
    /// stream, at `screenPoint` (AppKit global coordinates).
    ///
    /// It exists because the consuming tap leaves the session state wrong:
    /// a swallowed `leftMouseDown` never updates it, so for the whole
    /// captured gesture the window server believes no button is held. Our
    /// own readers ask the HID level instead — but an `NSDraggingSession`
    /// cannot be taught that. It is driven by session-level
    /// `leftMouseDragged`/`leftMouseUp`, so a session begun under a state
    /// that says "up" either completes instantly wherever the cursor
    /// stands or tracks nothing and never sees the release (metal,
    /// 2026-08-15 04:18–04:20: five instant `operation=1` endings and one
    /// three-second session pinned at the seed point, every one "ended
    /// with the button still held").
    func postSyntheticPrimaryButton(down: Bool,
                                    at screenPoint: CGPoint) -> Bool
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
    /// Asks the WINDOW SERVER whether the catch surface is the window at
    /// `screenPoint` — the question `setFileEdgeCatching` cannot answer,
    /// because widening a panel and the server agreeing it was widened are
    /// two events 15–25 ms apart. See `ContinuityCatchHitTest`.
    func catchSurfaceHitTest(_ token: AnyObject, at screenPoint: CGPoint)
        -> ContinuityCatchHitTest
    /// Starts the native drag from a REAL host mouse event. Non-optional on
    /// purpose: AppKit owns a gesture only when it can see the event that
    /// began it, and a synthesized stand-in is the shape that failed
    /// attended testing. A caller with no event must refuse out loud instead
    /// of calling this.
    ///
    /// Returns what the session was actually seeded with, or nil when
    /// nothing was started. The seed is a RETURN VALUE rather than a line
    /// written inside the implementation because the caller is the one that
    /// audits, and round 2 shipped with provenance for the trigger event and
    /// none at all for the seed.
    func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                       sourceEvent: NSEvent) -> ContinuityDragSeed?
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

    /// Why the consuming tap most recently failed to start. It answers two
    /// questions, not one. Is a later retry worth attempting —
    /// `missingPermission` is retried automatically the next time the app
    /// becomes active and the process is now trusted, `relaunchNeeded`
    /// never is, because macOS did not accept the grant this launch and
    /// asking again would just fail the same way. And, since it is
    /// published, whether the Continuity page should be showing the person
    /// a way OUT of the state: the prompt is a one-shot macOS may already
    /// have spent, so a status string is not an affordance and the page
    /// needs to know when to offer the Settings deep link instead.
    enum CaptureFailureReason: Equatable {
        case missingPermission
        case relaunchNeeded
    }

    private let layout: ContinuityDisplayLayout
    private weak var driver: ContinuityEdgeDriving?
    private let environment: ContinuityPointerEnvironment
    private let keyboardEnvironment: ContinuityKeyboardEnvironment
    private let accessibility: AccessibilityAuthorization
    /// Read by the page as well as the log: which copy is speaking is
    /// the one fact that separates "never granted" from "granted, but
    /// to a different copy of this app".
    let runningCopy: RunningCopy
    private let audit: Audit
    private let uptime: () -> TimeInterval
    private var monitor: AnyObject?
    private var fileEdge: AnyObject?
    private var layoutSubscription: AnyCancellable?
    private var pending: Ownership?
    private var ownership: Ownership?
    private var cursorHiddenOn: UInt32?
    private var inputCapture: AnyObject?
    @Published private(set) var captureFailureReason: CaptureFailureReason?
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
        var suspectEchoes = 0
        /// The session's button state has been re-armed. Until it has, no
        /// drag session may begin — and the re-arm itself waits on the
        /// window server, so this is no longer something the crossing can
        /// do and forget in the same breath.
        var armed = false
        /// A real host mouse event that arrived before the catch surface
        /// was ready. Kept rather than dropped: on this path a real event
        /// is the scarce thing, and what is late is the arm.
        var heldEvent: NSEvent?
        var armAttempts = 0
    }

    /// After this many samples without the window server handing the seed
    /// point to the catch surface, say so as an error. It keeps trying —
    /// the release ends it either way — but a silence here reads exactly
    /// like a drag that simply never happened.
    private static let catchSurfaceArmAttemptLimit = 30

    /// The hardware's own answer to "is the primary button physically
    /// held", read at the HID level. Injectable because no test has a
    /// mouse behind it.
    ///
    /// It exists because every OTHER source of that fact is downstream of
    /// this app's own consuming tap: a swallowed `leftMouseDown` never
    /// reaches the session's event state, so `NSEvent.pressedMouseButtons`
    /// and `CGEventSource.buttonState(.combinedSessionState)` both report
    /// the button UP for the whole captured gesture — this app poisons the
    /// very field it then reads. Only `.hidSystemState` sits beneath the
    /// tap (metal, 2026-08-15 02:48: four crossings abandoned in the same
    /// second as the cross, each on the first post-teardown sample).
    var physicalPrimaryButtonHeld: () -> Bool =
        AppKitContinuityPointerEnvironment.primaryButtonIsHeld

    init(layout: ContinuityDisplayLayout,
         driver: ContinuityEdgeDriving,
         environment: ContinuityPointerEnvironment? = nil,
         keyboardEnvironment: ContinuityKeyboardEnvironment? = nil,
         accessibility: AccessibilityAuthorization? = nil,
         runningCopy: RunningCopy = .current,
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
        self.accessibility = accessibility ?? SystemAccessibilityAuthorization()
        self.runningCopy = runningCopy
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
        /* A held button is nobody's until the human lets go. `hostFileDrag`
           is excluded because there the held gesture is a foreign app's drag
           session which this app never captured and must not interrupt. */
        let held = hostButtonsDown && !hostFileDrag
        if held, let origin = pressOrigin {
            /* Metal, 2026-08-15: this was reached with NOTHING bound and so
               did none of it, and the guest Finder put up "an item named
               main.c already exists" — the release completed a real move to
               wherever the pointer had wandered. Not moving somebody's files
               is not a property of the file-transfer feature. */
            audit(.warn, "held press released without a file handoff: "
                + "returning the guest pointer to the press origin first so "
                + "the Mac completes no Finder move — reason=\(reason), "
                + "boundFile=\(guestFileCandidate == nil ? "none" : "held")")
            releaseGuestPressAtOrigin(mirrorPoint(origin),
                                      cross: ownership.guestPoint)
        }
        driver?.pointerLeft()
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
                /* One policy decides, in one place. The tap has already
                   applied it to choose whether to swallow the original; this
                   side must reach the same verdict or the two halves
                   disagree about an event that is already gone. */
                switch policy.disposition(sample) {
                case .chord:
                    if let ownership = self.ownership {
                        self.returnToHost(
                            ownership, reason: "escape shortcut")
                    }
                case .ignored:
                    self.audit(
                        .info,
                        "keyboard sample left on the host: "
                            + "action=\(sample.action.rawValue), "
                            + "code=\(sample.code), forwarding=off")
                case .forwarded, .modifierState:
                    if !driver.keyboardEvent(sample) {
                        self.audit(
                            .error,
                            "captured keyboard event could not be queued: "
                                + "action=\(sample.action), code=\(sample.code)")
                    }
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

    /// Settles the held guest pointer back onto the press origin and only
    /// then releases the button. Two packets, in that order.
    ///
    /// **This is a file-system safety property, not a step of the file
    /// handoff**, and it is one implementation because it was two: the
    /// Finder completes a move to wherever the pointer is when the button
    /// comes up, so releasing at the cross point drops the icon at the
    /// screen edge — cosmetic from the desktop and a REAL relocation when
    /// the drag began inside a Finder window (metal, 2026-08-14). Released
    /// at the origin it completes a no-op move onto the spot the item
    /// already occupies. Living only on the bound path, it was skipped on
    /// 2026-08-15 for a press the Mac had published no selection for, and
    /// the guest Finder offered to replace the file at the cross point.
    ///
    /// The release itself goes down the ordinary driver lane — the same one
    /// a click sends — because there is no second way to end a press. v1
    /// never sent it at all and the item stayed stuck to the Finder's
    /// cursor on the other machine.
    private func releaseGuestPressAtOrigin(_ origin: MirrorKit.Point,
                                           cross: CGPoint) {
        _ = driver?.settleHeldPosition(to: origin)
        audit(.info, "guest pointer returned to the press origin before the "
            + "release: origin=\(origin.x),\(origin.y), cross="
            + "\(Int(cross.x)),\(Int(cross.y))"
            + " — releasing at the cross point completes a Finder move to "
            + "the screen edge")
        _ = driver?.primaryUp(at: origin)
        audit(.info, "guest press released before the cross: guest="
            + "\(origin.x),\(origin.y) — the dragged icon must snap "
            + "back on the Mac")
    }

    /// Hands a held guest item to AppKit as the pointer crosses back.
    ///
    /// The order is the whole mechanism, so it is stated once here and
    /// pinned by a test:
    ///
    /// 0. **Settle to the press origin and release**, before anything else,
    ///    per `releaseGuestPressAtOrigin` — which every held handback does,
    ///    file or no file.
    /// 1. Tear the pass down exactly as an ordinary return does: pointer
    ///    left, cursor restored, tap stopped, ownership dropped.
    /// 2. Only THEN start the native drag, and only from a real event. The
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
        releaseGuestPressAtOrigin(
            mirrorPoint(pressOrigin ?? ownership.guestPoint),
            cross: ownership.guestPoint)
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
                                              returnPoint: returnPoint,
                                              heldEvent: sourceEvent)
        /* The re-arm is ATTEMPTED here and will normally not happen yet:
           the widen two statements up has not reached the window server,
           and posting into that gap is what pressed a button on the Finder
           desktop. See `armSessionButtonIfSurfaceIsReady`. */
        if armSessionButtonIfSurfaceIsReady(), let sourceEvent {
            /* The observe-only monitor path already has one. Nothing waits. */
            startReturnDrag(with: sourceEvent)
            return
        }
        status = "Keep holding the button: finishing the file drag on this Mac"
        audit(.info, "guest file crossed; waiting for the catch surface and "
            + "the first real host mouse event now the tap is down")
    }

    /// Re-arms the SESSION's button state — but only once the window server
    /// agrees the catch surface is the window at the seed point.
    ///
    /// Two separate facts make that wait necessary, and the crossing used to
    /// assume both.
    ///
    /// The tap swallowed the physical `leftMouseDown`, so the window server
    /// believes no button is held: it synthesizes `mouseMoved` instead of
    /// `leftMouseDragged`, treats the physical release as a no-op, and a drag
    /// session begun under that state completes instantly wherever the cursor
    /// stands or tracks nothing at all (metal, 2026-08-15 04:18–04:20, both
    /// shapes in one log). Our own readers ask the HID level; an
    /// `NSDraggingSession` cannot be taught to. Hence a synthetic down.
    ///
    /// But a posted down goes wherever the SERVER thinks the pointer is, and
    /// the server had not yet been told the strip was widened — that takes
    /// 15–25 ms and several runloop turns, and no synchronous flush brings it
    /// forward (measured 2026-08-15). Worse, the strip was fully transparent
    /// and so was never hit-tested at all. Posted anyway, the down landed on
    /// the Finder desktop: a rubber-band selection under the whole handoff,
    /// and the same event handed back through the global monitor as the
    /// "real" one the drag was then seeded from.
    ///
    /// **This app does not press a button on another application.** So the
    /// post waits, and it is retried off the sample stream rather than a
    /// timer — the pointer is mid-crossing and moving, and this path already
    /// depends on further samples arriving for its real event.
    @discardableResult
    private func armSessionButtonIfSurfaceIsReady() -> Bool {
        guard var waiting = pendingReturnDrag else { return false }
        guard !waiting.armed else { return true }
        waiting.armAttempts += 1
        let hit = fileEdge.map {
            environment.catchSurfaceHitTest($0, at: waiting.returnPoint)
        }
        let verdict = hit?.summary ?? "there is no catch surface at all"
        guard hit?.ownsPoint == true else {
            if waiting.armAttempts == 1 {
                audit(.info, "holding the synthetic primary down until the "
                    + "window server puts the catch surface under the seed "
                    + "point: \(verdict) — posted now it would press the "
                    + "button on whatever is underneath")
            } else if waiting.armAttempts == Self.catchSurfaceArmAttemptLimit {
                audit(.error, "the catch surface still does not own the seed "
                    + "point after \(waiting.armAttempts) samples: \(verdict) "
                    + "— this Mac will not press a button into another "
                    + "application, so this file drag will end without "
                    + "starting")
            }
            pendingReturnDrag = waiting
            return false
        }
        audit(.info, "the catch surface owns the seed point: \(verdict), "
            + "samples=\(waiting.armAttempts)")
        if environment.postSyntheticPrimaryButton(down: true,
                                                  at: waiting.returnPoint) {
            audit(.info, "session button state re-armed: synthetic primary "
                + "down posted at \(Int(waiting.returnPoint.x)),"
                + "\(Int(waiting.returnPoint.y)) — the tap swallowed the "
                + "physical one, and the drag session AppKit is about to own "
                + "is driven by session state, not the HID's")
        } else {
            /* Armed anyway: a failed post is not a reason to spin, and the
               drag is better attempted than abandoned silently. */
            audit(.error, "could not re-arm the session button state; the "
                + "host drag session will complete instantly or track "
                + "nothing")
        }
        waiting.armed = true
        pendingReturnDrag = waiting
        return true
    }

    /// The second half of the crossing above, driven by whatever real event
    /// arrives first. Returns true when it consumed the sample.
    private func resumeReturnDrag(with sample: HostPointerSample,
                                  sourceEvent: NSEvent?) -> Bool {
        guard var waiting = pendingReturnDrag else { return false }
        if !sample.buttonsDown || sample.kind == .primaryUp {
            /* The sample's word against the hardware's. A `primaryUp` is
               believed outright — taken as the release goes by, the HID
               read can still say held, and honouring it would keep a press
               alive past its own end. A mere "buttons up" on a motion
               sample is not: the field is derived from event state this
               app's own tap has been starving all pass, and believing the
               first post-teardown echo abandoned four metal handoffs in
               the same second as their crossings (2026-08-15 02:48). */
            let physicallyHeld = physicalPrimaryButtonHeld()
            let eventName = sourceEvent
                .map { "type \($0.type.rawValue)" } ?? "none"
            if physicallyHeld, sample.kind != .primaryUp {
                waiting.suspectEchoes += 1
                if waiting.suspectEchoes == 1 {
                    /* Once, with everything the decision read — the round
                       this rule comes from was undiagnosable because the
                       abandon line named its conclusion and not its
                       evidence. */
                    audit(.warn, "a sample claims the button is up while it "
                        + "is physically held; treating it as an echo of "
                        + "this app's own tap, not a release: "
                        + "kind=\(sample.kind), "
                        + "sampleButtonsDown=\(sample.buttonsDown ? 1 : 0), "
                        + "sourceEvent=\(eventName), hidPrimaryHeld=1")
                }
                pendingReturnDrag = waiting
                return true
            }
            pendingReturnDrag = nil
            setFileEdgeCatching(false)
            audit(.warn, "the guest file drag was abandoned: the button was "
                + "released before this Mac saw a real mouse event to start "
                + "the drag from — kind=\(sample.kind), "
                + "sampleButtonsDown=\(sample.buttonsDown ? 1 : 0), "
                + "sourceEvent=\(eventName), "
                + "hidPrimaryHeld=\(physicallyHeld ? 1 : 0), "
                + "suspectEchoesBefore=\(waiting.suspectEchoes)")
            status = "The file drag ended before this Mac could take it over"
            return true
        }
        if let sourceEvent { waiting.heldEvent = sourceEvent }
        if waiting.heldEvent == nil, !waiting.waitedForRealEvent {
            waiting.waitedForRealEvent = true
            /* Once, not per sample: the tap can deliver a burst, and a
               line per sample would bury the one that matters. */
            audit(.info, "still waiting for a real host mouse event: the "
                + "held sample carried none")
        }
        pendingReturnDrag = waiting
        /* Two things must both be true, and they arrive in either order: a
           real event AppKit can own a gesture from, and a catch surface the
           window server has actually put under the seed point. Whichever is
           late, this returns having consumed the sample and tries again on
           the next one. */
        guard armSessionButtonIfSurfaceIsReady(),
              let event = pendingReturnDrag?.heldEvent else { return true }
        startReturnDrag(with: event)
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
        if let seed = environment.beginFileDrag(waiting.item, at: point,
                                                sourceEvent: sourceEvent) {
            /* The line the round-2 audit did not have. The trigger event is
               a foreign application's by construction — a global monitor
               has no other kind — so it is the SEED that has to be ours,
               and this says which it was rather than leaving both readings
               of `ourWindow=no` open. */
            audit(seed.ownWindow && seed.serverOwnsPoint ? .info : .error,
                  "host drag session seed: \(seed.summary)")
            if !seed.ownWindow {
                audit(.error, "the drag session was anchored to a window "
                    + "this app does not own; the drag image will freeze "
                    + "and nothing will accept the file")
            }
            /* Distinct from the line above, and this is the pair the next
               metal round needs kept apart. `ownWindow` is about the seed
               this app CONSTRUCTED — it can be ours while the window server
               still hands every real event at that point to somebody else,
               which is exactly the shape that shipped: seed ourWindow=yes,
               a Finder marquee underneath it, and a drag image pinned at
               the edge for the length of the session. */
            if !seed.serverOwnsPoint {
                audit(.error, "the window server does not put the catch "
                    + "surface under the seed point, so the gesture at that "
                    + "point belongs to another application; the drag image "
                    + "will stick where it started even if the session "
                    + "tracks")
            }
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
        if inputCapture != nil {
            if captureFailureReason != nil, !hostFileDrag {
                /* Only touched on RECOVERY, not on every ordinary successful
                   start: a plain first-time success has nothing degraded to
                   clear, and clobbering the status here would race whatever
                   else set it for the same crossing. */
                status = "Pointer is on the guest display"
            }
            captureFailureReason = nil
            return
        }
        /* Degraded, not broken: the observe-only monitor still drives the
           guest. Name the consequence, because a leak nobody can see is how
           this one survived to be measured on metal. Which message applies
           depends on whether the process is trusted RIGHT NOW: a still-untrusted
           process can be fixed by granting permission and coming back to
           this app, but a trusted process whose tap still failed to create
           needs a relaunch — macOS reads Accessibility trust at process
           start for this API, and no amount of retrying in place changes
           that. */
        if accessibility.isProcessTrusted() {
            captureFailureReason = .relaunchNeeded
            audit(.error, "could not capture host input even though this "
                + "app is trusted for Accessibility; macOS did not pick up "
                + "the grant for this process and a relaunch is needed")
            status = "Pointer is on the guest display; host input capture "
                + "needs this app relaunched before it can take effect"
        } else {
            captureFailureReason = .missingPermission
            /* The path is the whole point of this line. Accessibility is
               granted to a COPY, so a person looking at a switched-on
               toggle in System Settings and an app insisting the
               permission is missing needs exactly one fact to resolve it:
               which executable is speaking. Without it this exchange is a
               screenshot-and-guess; with it, seeing /Volumes/... is a
               five-second read. */
            audit(.error, "could not capture host input (Accessibility "
                + "permission); host clicks will also reach host apps. "
                + "Accessibility is granted per copy of an app and this "
                + "one is running from \(runningCopy.path)")
            status = "host input capture needs Accessibility permission; "
                + "the pointer still crosses, but host clicks also reach "
                + "host apps and window-drag protection is off"
        }
    }

    /// See `MirrorContinuityController.applicationDidBecomeActive`. Retries
    /// exactly once per activation, only while a tap is both currently
    /// wanted (the cursor is hidden for an active pass, or a button is held
    /// in custody) and absent, and only when the reason it is absent is one
    /// a later attempt can actually fix.
    func retryInputCaptureAfterBecomingActive() {
        guard captureFailureReason == .missingPermission else { return }
        guard inputCapture == nil else { return }
        guard cursorHiddenOn != nil || heldGesture != nil else { return }
        guard accessibility.isProcessTrusted() else { return }
        audit(.info, "Accessibility permission is now granted; picking up "
            + "host input capture without waiting for the next edge "
            + "crossing")
        startConsumingTap()
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
