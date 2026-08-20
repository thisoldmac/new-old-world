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
    /// The same transition posted at the **HID** level instead — beneath
    /// every session tap, including this app's own.
    ///
    /// The session-level sibling above exists to correct what the session
    /// BELIEVES. This one exists to end a real gesture: a drag session
    /// belonging to another application is terminated by a release the
    /// window server itself routes, and a release inserted at the session
    /// level can be swallowed by a tap sitting in front of the drag loop —
    /// including ours. See `endHostDragAtCross`, which uses it to end a
    /// Finder-owned drag at the shared edge, over this app's own
    /// destination, so the OS performs the drop onto us.
    func postSyntheticPrimaryButtonAtHID(down: Bool,
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
    /// Starts a LISTEN-ONLY witness over the session event stream, for the
    /// length of one drag session this app started. Returns nil when the
    /// platform refused, which the report then says out loud rather than
    /// presenting an empty tally as a quiet stream.
    ///
    /// It watches the stream the SESSION sees, because that is the stream an
    /// `NSDraggingSession` is driven by and the one this app is blind to
    /// while it stands down: on metal, every session in the 2026-08-15 15:27
    /// build reported `standDownSamples` of 0 or 1 over two to four seconds
    /// of hand motion, so the monitors this app already had could not have
    /// seen a release if one arrived. It never swallows — the gesture belongs
    /// to AppKit for the duration and a consuming tap here would be competing
    /// with the drag it exists to explain.
    func startDragWitness() -> AnyObject?
    /// The tally so far. Read synchronously rather than delivered through a
    /// callback: a main-actor hop is exactly what goes missing inside a
    /// nested drag-tracking loop, which is the blindness this instrument is
    /// for.
    func readDragWitness(_ token: AnyObject) -> ContinuityDragWitness
    func stopDragWitness(_ token: AnyObject)
    func showFileEdge(_ edge: ContinuitySharedEdge, catchThickness: CGFloat,
                      callbacks: ContinuityFileEdge.Callbacks) -> AnyObject
    func updateFileEdge(_ token: AnyObject, edge: ContinuitySharedEdge,
                        catchThickness: CGFloat,
                        callbacks: ContinuityFileEdge.Callbacks)
    func hideFileEdge(_ token: AnyObject)
    /// See `ContinuityFileEdge.setDropsThroughOwnSession`.
    func setFileEdgeDropsThroughOwnSession(_ token: AnyObject,
                                           _ dropsThrough: Bool)
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
    /// Holds the primary button as a LEVEL in the pointer plane for the life
    /// of a staged carry, without minting a button generation.
    ///
    /// It is not a press and must never become one. A staged carry suppresses
    /// every `.primaryDown` (D5), so the press half of this controller is
    /// deliberately silent while a file is being carried — and the guest's
    /// Drag Manager still needs to read a held button, or its `TrackDrag`
    /// first-samples UP and drops at the entry point (F2 defect B, attended
    /// metal 2026-08-17). The generation is what separates the two readers;
    /// see `MirrorContinuityController.setCarriedButtonLevel`.
    @discardableResult
    func setCarriedButtonLevel(_ held: Bool, gesture: UInt64,
                               reason: String) -> Bool
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
    /// The entry inset and catch-surface deadzone depth. Owned here rather
    /// than read from a static constant so a person can feel a different
    /// size without restarting Continuity — `updateEdgeGeometry` applies a
    /// change to both the live catch surface and the next crossing.
    @Published private(set) var edgeGeometry = ContinuityEdgeGeometry.default

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
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void)
        -> Void
    private var monitor: AnyObject?
    private var fileEdge: AnyObject?
    private var layoutSubscription: AnyCancellable?
    private var pending: Ownership?
    private var ownership: Ownership?
    private var cursorHiddenOn: UInt32?
    /// Mirrors `cursorHiddenOn`'s shape but is deliberately its own
    /// variable, not a second use of that one. `cursorHiddenOn` is
    /// entangled with the warp/pin/associate machinery a host file drag
    /// must never touch (see the `!hostFileDrag` guards throughout this
    /// file) — a foreign `NSDraggingSession` belongs to Finder, and this
    /// app can detach or warp the real cursor for an ordinary crossing but
    /// not for someone else's live drag. This variable remembers only
    /// which display had its cursor VISIBLE LAYER hidden for a host file
    /// drag, so `showHostDragCursor` can restore exactly that and nothing
    /// else — see `hideHostDragCursor`/`showHostDragCursor`.
    private var hostDragCursorHiddenOn: UInt32?
    /// Identifies one host→guest file-drag gesture in the log, so an
    /// attended run can pair a "hid" line with its "restored" line without
    /// guessing from timestamps. Incremented once per arrival — the
    /// `announcedHostDragArrival` false→true edge.
    private var hostFileDragGestureID: UInt64 = 0
    private var inputCapture: AnyObject?
    @Published private(set) var captureFailureReason: CaptureFailureReason?
    private var cursorDissociated = false
    /// Where the last sample put the host pointer, carried only so every
    /// custody line can say WHERE the transition happened. Custody is the
    /// one subsystem whose failures are reported as "the cursor went wild",
    /// and a position-free line cannot answer that.
    private var lastHostSampleLocation: CGPoint = .zero
    /// How many times the cursor has been parked at the anchor since it was
    /// hidden. Counted rather than logged per park: the pin runs on every
    /// sample, and a line each would bury everything else in this log.
    private var cursorParks: UInt32 = 0
    private var keyboardMonitor: AnyObject?
    private var pendingCursorWarp: PendingCursorWarp?
    private var suppressedCursorWarps: UInt32 = 0
    private var hostFileDrag = false
    /// **The host's own drag session is over, and this Mac ended it.**
    ///
    /// Set the instant the synthetic release posted at the crossing is
    /// accepted as a drop by this app's own strip (`hostFileDropped`'s
    /// cross-drop branch). From then on `hostFileDrag` still means "this
    /// controller is steering the guest on behalf of a host file", but there
    /// is no longer a foreign `NSDraggingSession` in flight — so every
    /// restraint this file observes on behalf of one is lifted, and the pass
    /// converges with an ordinary pointer crossing. See
    /// `hostDragSessionOverEdgeIsLive`, which is what the old `!hostFileDrag`
    /// guards now ask instead.
    private var hostDragEndedAtCross = false
    /// A synthetic release has been posted and the drop it should produce has
    /// not arrived yet. Distinguishes the drop this Mac caused from a real
    /// one a person made on the strip.
    private var expectingCrossDrop = false
    /// Why ending the host drag at the crossing was declined for this
    /// gesture, so it is attempted once rather than on every
    /// `draggingUpdated`, and so the log says which fallback is running.
    private var crossEndRefusal: String?
    /// What the ended host drag was carrying, held until the person releases
    /// on the guest. **The drop this Mac accepted at the edge is a staging,
    /// not the transfer** — see `ContinuityHostFileStaging` and
    /// `completeStagedHostDrop`.
    private var stagedHostFiles: NSPasteboard?
    /// The button bookkeeping a staged carry owns, for as long as it is
    /// staged. See `rearmStagedCarryButton` for why it has to exist at all.
    private struct StagedCarryButton {
        /// A synthetic down has been posted to undo this Mac's own
        /// synthetic release, so the person's physical lift is a real HID
        /// transition again.
        var reArmed = false
        /// The HID has since answered "held" at least once. Until it has,
        /// the re-arm is a hope and the HID backstop must not read the
        /// button as released — that reading would be this Mac's own lie
        /// coming back.
        var heldSeen = false
        /// Button samples refused while the carry was staged. Counted, and
        /// reported once, because on 2026-08-16 they were forwarded to the
        /// guest as real clicks (F1 ledger, D5).
        var suppressedPresses: UInt32 = 0
    }
    private var stagedCarry = StagedCarryButton()
    /// See `HostDragHandoff`. Nil until wired, and a nil one is a crossing
    /// that stages and transfers exactly as it did before this lane.
    private var hostDragHandoff: HostDragHandoff?
    /// Whether this gesture's skeleton has already crossed. The handoff is
    /// ONE act per staged carry — the staging point is reached once, but
    /// every later path that could reach it (a re-arm, a converge) must
    /// find the question already answered.
    private var hostDragHandedOff = false
    /// Whether this Mac is currently holding the primary button as a LEVEL in
    /// the guest's pointer plane on this carry's behalf. Mirrored here rather
    /// than asked of the driver so every raise and every clear is one
    /// decision of this lifecycle's, and so the clears can be idempotent —
    /// several exit paths legitimately run for one carry.
    private var carriedButtonHeld = false
    /// The catch strip was widened on the resident's dragBegin, before any
    /// cross. Cleared when the gesture resolves either way.
    private var preWidenedForGuestDrag = false
    /// Whether that level actually reached the wire. A raise made before the
    /// guest confirms ownership sets the field and sends nothing, and the
    /// difference is what decides whether the confirming pass has anything
    /// to re-assert — a second datagram carrying a level already on the
    /// plane is noise, and noise in this lane reads as a second gesture.
    private var carriedButtonOnWire = false
    /// The staged carry outlived `stagedCarryLifetime` and was let go. Kept
    /// past the staging it describes so a physical release arriving
    /// afterwards is answered with the reason it commits nothing, rather
    /// than with the silence of a guard that simply returns.
    private var stagedCarryTimedOut = false
    /// Distinguishes one armed deadline from the next, so a timer fired for
    /// a carry that has since ended cannot let go of the one after it.
    private var stagedCarryDeadlineID: UInt64 = 0
    /// The HID backstop's own clock. The release edge used to be sampled
    /// only from .moved events, so a motionless or instant release after
    /// the re-arm never armed it (review, 2026-08-17); this probe runs the
    /// same check on time instead of motion.
    private var stagedCarryProbeID: UInt64 = 0
    private static let stagedCarryProbeInterval: TimeInterval = 0.25
    /// Where the host drag was ended at the crossing. The re-arm is posted
    /// there — the one point on this Mac known to have been over this app's
    /// own catch surface a moment ago.
    private var stagedCrossPoint: CGPoint = .zero
    /// Snapshots a live drag pasteboard into something that outlives the
    /// session. Injectable because no test has a real drag pasteboard, and
    /// because whether a given drag CAN be staged is the one fact that
    /// decides between ending the host drag at the cross and leaving it
    /// alone.
    var stageHostFiles: @MainActor (NSPasteboard) -> NSPasteboard? =
        ContinuityHostFileStaging.snapshot
    /// Whether a drag session belonging to another application is still in
    /// flight over the shared edge on this Mac's behalf.
    ///
    /// This is the question every `!hostFileDrag` guard in this file was
    /// really asking: not "is a host file crossing" but "is there a foreign
    /// session whose cursor, association and warps are not ours to touch".
    /// Once the crossing has ended that session (`hostDragEndedAtCross`) the
    /// answer is no, and the pass takes the ordinary custody it always
    /// should have had.
    private var hostDragSessionOverEdgeIsLive: Bool {
        hostFileDrag && !hostDragEndedAtCross
    }
    private var guestFileCandidate: HostFileDragItem?
    /// Where on the guest the held gesture began. The cross returns the
    /// pointer here before releasing, so the Finder completes its move where
    /// the item already was. Nil whenever no press is held.
    private var pressOrigin: CGPoint?
    private var guestFileAtPoint: ((MirrorKit.Point) -> HostFileDragItem?)?
    private var guestSelectionItem: (() -> HostFileDragItem?)?
    private var guestSelectionMark: (() -> ContinuitySelectionMark?)?
    /// Starting a crossing with nothing bound, and revising one after the
    /// cross. Nil where the lane is not wired, which is every caller that
    /// predates late bind. See `ContinuityLateBind.Lane`.
    private var lateBind: ContinuityLateBind.Lane?
    /// This cross held two candidates and could not say which the hand
    /// chose, so it refused (`ContinuitySelectionBind.superseded`). A
    /// refusal is a product outcome — a snap-back and a line naming both —
    /// and late bind must not quietly turn it into a session: widening the
    /// window in which a bind may be REVISED is not licence to re-open one
    /// this Mac already declined to make.
    private var crossRefusedAsAmbiguous = false
    /// What the selection lane knew when the press went out, kept until the
    /// cross decides what to bind. See `ContinuitySelectionBind`.
    private struct PressedSelection {
        let mark: ContinuitySelectionMark?
        let downSentAt: TimeInterval
    }
    private var pressedSelection: PressedSelection?
    private var hostFilesDropped:
        ((NSPasteboard, MirrorKit.Point) -> Bool)?
    private var pendingReturnDrag: PendingReturnDrag?
    /// A drag session THIS app started and macOS has not finished. While it
    /// is live every input path here stands down: the gesture belongs to
    /// AppKit, and anything of ours still reacting to the pointer is
    /// competing with the drag it just handed over.
    private var hostDragSessionLive = false
    private var standDownSamples: UInt32 = 0
    /// The listen-only witness over the live drag session, and where and when
    /// it was seeded. See `ContinuityDragWitnessReport`.
    private var dragWitness: AnyObject?
    private var dragSeededAt: TimeInterval = 0
    private var dragSeedPoint: CGPoint = .zero
    /// The arm's own catch-surface reading, kept past the pending state that
    /// produced it so the end-of-session witness can print both times.
    private var catchSurfaceAtArm: ContinuityCatchHitTest?
    /// **A drag belonging to some application on THIS Mac is in flight over
    /// the shared edge right now.** Set the moment the strip sees a foreign
    /// dragging session, cleared when that session leaves, drops, or ends.
    ///
    /// It is deliberately NOT `hostFileDrag`. That flag means "this
    /// controller is steering the guest on behalf of a host drag", and it is
    /// only ever set when `hostFileEntered` finds the controller `.ready`.
    /// This one means "a host drag exists", full stop, and it is true even
    /// when the ordinary pointer lane got to the crossing first.
    ///
    /// THAT RACE IS THE 2026-08-16 17:22 DEFECT. A held drag moves the
    /// pointer across the edge, and the sample stream and the strip's own
    /// `draggingEntered` are two independent reporters of the same gesture
    /// arriving by different routes. When the samples win, the controller is
    /// already `.active`, `hostFileEntered` returns false, `hostFileDrag`
    /// stays false — and the ordinary lane treats a person's held HOST drag
    /// as a press on the GUEST. On that round it bound a stale cached
    /// selection, sent a primary down the guest Finder started dragging
    /// `main.c` under, and ran the entire return pipeline backwards at a
    /// gesture that was travelling the other way. Two features contending
    /// for one crossing, and the loser was the one the person was making.
    ///
    /// So the suppression keys off the EXISTENCE of the host drag rather
    /// than off which reporter won.
    private var hostDragOverThisMac = false
    /// Whether this gesture's identity has already crossed. The strip is
    /// asked on every motion, and the arrival is taken once — it is the
    /// false→true edge that numbers the gesture and hides the host
    /// cursor's visible layer, and `endHostDragVisuals` is what clears it.
    private var announcedHostDragArrival = false
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
        /// The hit test the arm actually succeeded on. Carried forward so the
        /// end-of-session witness can print the arm's own reading beside a
        /// fresh one instead of printing the fresh one under the arm's name.
        var catchSurfaceAtArm: ContinuityCatchHitTest?
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

    /// What the SESSION believes about the primary button — the state an
    /// `NSDraggingSession` is actually driven by, and the one this app's own
    /// tap starves. Read only for the end-of-session report, where the pair
    /// of answers is the point: HID held and session up is this app having
    /// poisoned the field again; both held is a session that ended for some
    /// other reason entirely.
    var sessionPrimaryButtonHeld: () -> Bool = {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    /// This process's own id, so the report can say whether a release the
    /// session saw was one this app posted. Injectable for the same reason
    /// as the two above: no test has a mouse or a window server.
    var hostProcessIdentifier: () -> Int64 = {
        Int64(ProcessInfo.processInfo.processIdentifier)
    }

    init(layout: ContinuityDisplayLayout,
         driver: ContinuityEdgeDriving,
         environment: ContinuityPointerEnvironment? = nil,
         keyboardEnvironment: ContinuityKeyboardEnvironment? = nil,
         accessibility: AccessibilityAuthorization? = nil,
         runningCopy: RunningCopy = .current,
         audit: Audit? = nil,
         uptime: @escaping () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         },
         /// How the staged-carry deadline is armed. Injectable for the same
         /// reason `uptime` is: a bound nobody can make elapse in a test is
         /// a bound nobody has tested.
         schedule: @escaping (TimeInterval,
                              @escaping @MainActor () -> Void) -> Void = {
             delay, body in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                 MainActor.assumeIsolated(body)
             }
         }) {
        self.layout = layout
        self.driver = driver
        self.environment = environment
            ?? AppKitContinuityPointerEnvironment()
        /* Inert, NOT the AppKit tap — see
           `InertContinuityKeyboardEnvironment`. A consuming session-wide key
           tap in a process that is not the running app takes every keystroke
           on the Mac hostage, and defaulting to the real one put exactly that
           inside `xctest`. Production names its environment out loud. */
        self.keyboardEnvironment = keyboardEnvironment
            ?? InertContinuityKeyboardEnvironment()
        self.accessibility = accessibility ?? SystemAccessibilityAuthorization()
        self.runningCopy = runningCopy
        self.audit = audit ?? { HostLog.shared.write($0, "continuity", $1) }
        self.uptime = uptime
        self.schedule = schedule
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

    /// **The handoff seam: the ownership toggle, expressed as two calls.**
    ///
    /// The plan's design invariant (`2026-08-17-036`, "The ownership
    /// toggle"): exactly one machine's drag machinery is live at a time,
    /// and the edge toggles it. This Mac's own `NSDraggingSession` has
    /// already ended at the crossing and the file is staged; `begin` is
    /// where the OTHER machine's Drag Manager takes over.
    ///
    /// **Neither call knows anything about targeting, windows, or
    /// collisions, and that is the acceptance test, not an omission.**
    /// After the handoff the guest sees a normal drag with a promise —
    /// where it lands, what it collides with, and what dialog the Finder
    /// raises are all the receiving OS's business. A parameter here
    /// answering any of those would be this app re-inventing what it just
    /// handed over.
    struct HostDragHandoff {
        /// Derive the promise skeleton from the staged file and send
        /// `continuity.hostDragBegin` at the guest entry point. False when
        /// nothing crossed — no guest listening, nothing nameable on the
        /// staged pasteboard — which is a degraded gesture, not a broken
        /// one, and the caller says so out loud.
        var begin: (NSPasteboard, MirrorKit.Point, UInt64) -> Bool
        /// The carry ended without the guest's drop: let the promise go,
        /// with a reason. Must be safe to call when `begin` never
        /// succeeded, and safe to call twice.
        var abandon: (String, UInt64) -> Void
    }

    /// **How long a staged carry may live unresolved before this Mac lets
    /// it go.**
    ///
    /// The plan's named failure mode: the skeleton never arrives, or the
    /// guest never starts the drag, and it times out into a native
    /// non-drop over there. This is the same bound seen from this side —
    /// without it a gesture that ended somewhere this Mac cannot observe
    /// leaves a staged file and a live promise behind forever.
    ///
    /// Three minutes rather than the offer's own 30 s: this one has to
    /// outlive a LEISURELY HUMAN DRAG (the allowance the plan calls out),
    /// so it is a zombie bound, not a responsiveness bound.
    static let stagedCarryLifetime: TimeInterval = 180

    /// Installs the handoff. Optional: a controller without one still
    /// stages and still transfers on release — the crossing simply never
    /// becomes a native drag on the other side.
    func configureHostDragHandoff(_ handoff: HostDragHandoff) {
        self.hostDragHandoff = handoff
    }

    /// Binds a cross-edge drag to the guest's PUBLISHED SELECTION rather
    /// than to a scene hit test.
    ///
    /// The stub is the truth for this lane, and the reason is not
    /// preference: during a drag the guest cannot be asked anything, so what
    /// the drag binds to has to have arrived over the wire. A scene lookup
    /// would also make edge-mode file drags depend on the Mirror running,
    /// which is the dependency slice 1 spent its whole existence removing.
    /// `guestSelectionItem` returns nil for an unusable selection and is
    /// responsible for saying WHY out loud — a silent nil here is the v1
    /// failure mode.
    ///
    /// THE BINDING IS TAKEN AT THE CROSS, NOT AT THE PRESS, and the mark
    /// closure is what makes that safe. "Arrived over the wire" was read as
    /// "arrived before the press" until 2026-08-15, when a press that
    /// selected its own file bound the generation before it and this Mac
    /// transferred `hello.txt` while `main.c` was being dragged. The press
    /// records what the cache held; the cross compares and decides. See
    /// `ContinuitySelectionBind`.
    ///
    /// AND THE CROSS IS NOT FINAL EITHER. The drag-sourced generation — the
    /// one fact that names an unselected icon — cannot reach this Mac before
    /// the cross, because the Finder's drag loop starves the guest
    /// application of task time and the cross is what ends that loop by
    /// releasing the press. Measured 2026-08-16: it arrives ~230 ms AFTER
    /// the crossing, into an AppKit session with seconds left to live. So
    /// `lateBind.pendingItem` lets a cross with nothing bound start a
    /// session anyway, and `lateBind.revise` lets that one generation replace
    /// what it carries, up to the drop. See `ContinuityDragBinding`.
    func configureSelectionDragging(
        guestSelectionMark: @escaping () -> ContinuitySelectionMark?,
        guestSelectionItem: @escaping () -> HostFileDragItem?,
        lateBind: ContinuityLateBind.Lane? = nil
    ) {
        self.guestSelectionMark = guestSelectionMark
        self.guestSelectionItem = guestSelectionItem
        self.lateBind = lateBind
    }

    /// The Mac published a selection. Called for EVERY arrival, and almost
    /// every one of them is none of this lane's business — the interesting
    /// case is the one that arrives after this Mac has already committed a
    /// crossing.
    ///
    /// Three refusals, each said out loud rather than returned silently:
    ///
    /// - **A cross under a HOST drag binds nothing**, and late bind must not
    ///   be the way that gets undone. `hostDragOverThisMac` is the same flag
    ///   the cross itself keys off (`37241007`); widening the window in
    ///   which a bind can be revised must not widen the window in which a
    ///   refused one can come back.
    /// - **Only a drag-sourced generation may revise.** Everything else is a
    ///   cache of what was selected, and a cache that arrives after the
    ///   crossing has no claim on the gesture at all — `decide` already
    ///   ranks it below a drag, and after the cross it is simply late news.
    /// - **After redemption, nothing.** The drop has asked the Mac for a
    ///   specific generation; a file arriving under one name and being
    ///   swapped for another mid-fetch is the wrong-file bug wearing a new
    ///   hat.
    func noteSelectionPublished(_ mark: ContinuitySelectionMark) {
        /* PRE-WIDEN ON THE MAC'S OWN ANNOUNCEMENT. The resident names the
           drag seconds before any cross, and the widen needs 15-25 ms of
           window-server lag the crossing instant does not have — widened
           only at the cross, the physically held button rubber-banded the
           host desktop until the strip landed (attended, 2026-08-17). A
           drag that ends on the guest narrows again when the next
           selection-sourced mark publishes. */
        if ownership != nil, pendingReturnDrag == nil, !hostDragSessionLive,
           !hostDragOverThisMac {
            if mark.source == .drag, !preWidenedForGuestDrag {
                preWidenedForGuestDrag = true
                setFileEdgeCatching(true)
                audit(.info, "catch surface widened EARLY: the Mac says a "
                    + "drag is in the hand (dragSeq="
                    + "\(mark.dragSeq.map(String.init) ?? "none")), and the "
                    + "widen needs server time a crossing does not have")
            } else if mark.source != .drag, preWidenedForGuestDrag {
                preWidenedForGuestDrag = false
                setFileEdgeCatching(false)
                audit(.info, "catch surface narrowed: the drag ended on the "
                    + "guest without crossing")
            }
        }
        guard let lateBind else { return }
        guard pendingReturnDrag != nil || hostDragSessionLive else { return }
        let gesture = lateBind.gesture().map(String.init) ?? "none"
        if hostDragOverThisMac {
            audit(.info, "not revising this crossing (gesture "
                + "\(gesture)): it carries a drag from this Mac, not "
                + "the guest's, and a cross under a host drag binds nothing "
                + "— generation \(mark.generation) changes nothing here")
            return
        }
        guard mark.source == .drag else {
            audit(.info, "not revising this crossing (gesture "
                + "\(gesture)): generation \(mark.generation) is a "
                + "selection, published after the cross — only the drag "
                + "plane names the file in the hand, and a cache arriving "
                + "late has no claim on a gesture already in flight")
            return
        }
        switch lateBind.revise(mark) {
        case .revised(let gesture, let from, let to):
            audit(.info, "late bind: this crossing now carries \(to) "
                + "(gesture \(gesture), source=drag, epoch=\(mark.epoch), "
                + "dragSeq=\(mark.dragSeq.map(String.init) ?? "none")), "
                + "replacing \(from ?? "nothing at all") — the Mac could "
                + "not say what was in the hand until its own drag loop "
                + "ended, and the drop is what redeems this")
        case .refusedRedeemed(let gesture, let generation):
            audit(.warn, "late bind refused: generation \(generation) "
                + "(source=drag) arrived after the drop redeemed gesture "
                + "\(gesture); the file being fetched is already decided "
                + "and this Mac does not swap one mid-transfer")
        case .unchanged(let gesture, let generation):
            audit(.info, "late bind: gesture \(gesture) already carries "
                + "generation \(generation); nothing to revise")
        case .unusable(let reason):
            audit(.info, "late bind not applied: \(reason)")
        case .noGesture:
            audit(.info, "late bind not applied: no crossing of this Mac's "
                + "is waiting for one")
        }
    }

    /// THE GENERATION FOR A GESTURE WHOSE EPOCH ENDED AT THE CROSS.
    ///
    /// The same arrival as `noteSelectionPublished`, one epoch later and by
    /// a different route: it carries a whole stub rather than a mark,
    /// because an ended epoch has no bindable cache entry to look one up
    /// in. Every guard here is the one next door, for the same reasons; what
    /// is NOT here is a source test, because the guest only ever marks a
    /// drag-sourced mint this way — a poll cannot run without a live epoch.
    ///
    /// A frame with no crossing left to revise is a MISS and says so at
    /// warning level. The gesture it belonged to has already refused or
    /// already taken its answer, and the one thing this must never do is
    /// redeem a drop that stopped waiting.
    func noteSelectionPublishedAfterEpoch(_ stub: ContinuityDragStub) {
        guard let lateBind else { return }
        let gesture = lateBind.gesture().map(String.init) ?? "none"
        guard pendingReturnDrag != nil || hostDragSessionLive else {
            audit(.warn, "a generation minted after epoch \(stub.epoch) "
                + "ended (generation \(stub.generation), dragSeq="
                + "\(stub.dragSeq.map(String.init) ?? "none"), "
                + "name=\(stub.item.name)) arrived with no crossing of this "
                + "Mac's left to carry it — the gesture is over, and a drop "
                + "that stopped waiting is not redeemed late")
            return
        }
        if hostDragOverThisMac {
            audit(.info, "not revising this crossing (gesture \(gesture)): "
                + "it carries a drag from this Mac, not the guest's — "
                + "generation \(stub.generation) changes nothing here")
            return
        }
        switch lateBind.reviseAfterEpoch(stub) {
        case .revised(let gesture, let from, let to):
            audit(.info, "late bind after the epoch: this crossing now "
                + "carries \(to) (gesture \(gesture), source=drag, epoch="
                + "\(stub.epoch) which has ENDED, dragSeq="
                + "\(stub.dragSeq.map(String.init) ?? "none")), replacing "
                + "\(from ?? "nothing at all") — the cross is what ended "
                + "that epoch, so this is the first moment the Mac could "
                + "mint a number for the file in the hand")
        case .refusedRedeemed(let gesture, let generation):
            audit(.warn, "late bind refused: generation \(generation), "
                + "minted after epoch \(stub.epoch) ended, arrived after "
                + "the drop redeemed gesture \(gesture); the file being "
                + "fetched is already decided and this Mac does not swap "
                + "one mid-transfer")
        case .unchanged(let gesture, let generation):
            audit(.info, "late bind: gesture \(gesture) already carries "
                + "generation \(generation); nothing to revise")
        case .unusable(let reason):
            audit(.warn, "late bind after the epoch not applied: \(reason)")
        case .noGesture:
            audit(.warn, "a generation minted after epoch \(stub.epoch) "
                + "ended (generation \(stub.generation), dragSeq="
                + "\(stub.dragSeq.map(String.init) ?? "none"), "
                + "name=\(stub.item.name)) found no crossing waiting for "
                + "it — nothing is redeemed on its account")
        }
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
        /* Self-describing, the way a metal measurement is: the geometry a
           session ran under should be answerable from its own log rather
           than assumed from the default in source. */
        audit(.info, "edge geometry: entryInset=\(Int(edgeGeometry.entryInsetPixels))"
            + "px, deadzoneDepth=\(Int(edgeGeometry.deadzoneDepth))px")
    }

    /// Applies a new entry inset / deadzone depth. Clamped to a sane range
    /// the way a hand-edited reconnect delay is, and pushed to the live
    /// catch surface immediately — see `ContinuityFileEdge.update
    /// (catchThickness:)` for why that is safe mid-handoff.
    func updateEdgeGeometry(_ geometry: ContinuityEdgeGeometry) {
        let clamped = geometry.clamped()
        guard clamped != edgeGeometry else { return }
        edgeGeometry = clamped
        audit(.info, "edge geometry changed: entryInset="
            + "\(Int(clamped.entryInsetPixels))px, deadzoneDepth="
            + "\(Int(clamped.deadzoneDepth))px")
        refreshFileEdge()
    }

    func stop(reason: String = "Continuity Mode disabled") {
        if state == .arming || state == .active { driver?.pointerLeft() }
        endHeldCustody(reason: "Continuity stopped")
        if let dragWitness {
            environment.stopDragWitness(dragWitness)
            self.dragWitness = nil
        }
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
            /* The question is whether a FOREIGN session is live, not whether
               a file is crossing: a pass whose host drag this Mac already
               ended at the edge owns the cursor exactly like an ordinary
               crossing does, and withholding custody from it is what left
               the real pointer visible and clamped at the boundary. */
            if !hostDragSessionOverEdgeIsLive {
                hideHostCursor(for: pending)
                startKeyboardCapture()
                /* The deferred half of `convergeAfterCrossDrop`: a carry
                   whose host drag ended before the guest confirmed
                   ownership takes its custody here, and the button re-arm
                   is part of that custody rather than a step beside it. */
                rearmStagedCarryButton()
            }
            if carriedButtonHeld, !carriedButtonOnWire {
                /* The level was raised against a transport that had nothing
                   to send it on. This is the first datagram it can ride, and
                   the guest's drag reads the plane, not the history. */
                holdCarriedButton(true, reason: "ownership is confirmed, so "
                    + "the carried button reaches the plane the Macintosh's "
                    + "drag is reading", reassert: true)
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
        lastHostSampleLocation = sample.location
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
            guestPixels: layout.guestSize, scale: layout.guestScale,
            insetPixels: edgeGeometry.entryInsetPixels)
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
        /* THE BACKSTOP, AND IT IS NOT OPTIONAL. The flag is cleared by
           `draggingExited`/`performDragOperation`, which are AppKit's word
           about a session belonging to another application — the one class
           of event this controller cannot make arrive. A flag that only a
           foreign callback can clear is a flag that can stick, and a stuck
           one leaves this edge permanently deaf to real guest presses: a
           worse failure than the one the flag exists to fix, and a silent
           one. So it is also cleared by the fact underneath it. The HID is
           asked rather than the sample, for the reason stated at
           `physicalPrimaryButtonHeld` — this app's own tap starves the
           session's button state on exactly this path. */
        /* `!expectingCrossDrop` is not a mood: this Mac has just posted a
           synthetic release at the HID level, so the HID button state reads
           UP while the person's finger is still down. Without this the
           backstop would read its own release as the end of the gesture and
           tell the guest to stop drawing a drag the person is still
           making. */
        if hostDragOverThisMac, !expectingCrossDrop,
           !physicalPrimaryButtonHeld() {
            hostDragOverThisMac = false
            audit(.info, "the host drag over the shared edge is over: the "
                + "button is not held any more and no drag callback said so")
            /* The guest is still drawing a drag for a gesture that has
               ended. Same backstop, same reason: the teardown must not be
               reachable only through the callback that failed to arrive. */
            endHostDragVisuals()
        }
        guard var ownership else { return }
        if stagedCarryTimedOut, sample.kind == .primaryUp {
            /* **NOT SILENCE.** The carry was let go on its own bound while
               this gesture was still physically in flight, so the release
               commits nothing — and a person waiting for a file that will
               never arrive deserves the sentence rather than a guard that
               quietly returns. */
            stagedCarryTimedOut = false
            audit(.warn, "host file drag: the person released on the guest, "
                + "but this Mac had already let the carry go on the "
                + "\(Int(Self.stagedCarryLifetime))s bound, so the release "
                + "commits nothing (gesture=\(hostFileDragGestureID))")
            endHostDragVisuals()
            hostFileDrag = false
            hostDragEndedAtCross = false
            crossEndRefusal = nil
            status = "The file was let go before it could be handed over"
            return
        }
        if stagedHostFiles != nil {
            /* **A STAGED CARRY OWNS THE BUTTON OUTRIGHT.** Everything the
               primary button does between the crossing and the drop is this
               gesture's, and none of it is a click on the guest: the person
               is holding a file, and the only thing they can mean by
               letting go is "put it here". */
            if sample.kind == .primaryUp {
                /* THE RELEASE THE PERSON ACTUALLY MADE, and the only one
                   that decides anything. The release this Mac posted at the
                   edge ended Finder's session and staged the file; this one
                   says where on the guest it goes. */
                completeStagedHostDrop(at: ownership,
                                       release: "the person released on the "
                                        + "guest")
                return
            }
            if sample.kind == .primaryDown {
                /* D5, 2026-08-16: these were forwarded as real guest clicks
                   — three bursts inside the double-click window on the
                   guest desktop, which is how a drag came to open Classilla.
                   The synthetic down this Mac posts to re-arm the button
                   comes back through the same tap and is refused here too,
                   which is the point: WE synthesise the guest-side release,
                   at the commit and only there. */
                stagedCarry.suppressedPresses &+= 1
                if stagedCarry.suppressedPresses == 1 {
                    custodyAudit(.info, "button forwarding suppressed",
                                 "a file is staged, so a press is this "
                                    + "gesture's own and not a click on the "
                                    + "guest")
                }
                return
            }
            if stagedCarryReleasedAtHID() {
                completeStagedHostDrop(at: ownership,
                                       release: "the HID says the button "
                                        + "went up and no event carried it")
                return
            }
        }
        if hostDragSessionOverEdgeIsLive || hostDragOverThisMac,
           sample.kind == .primaryDown || sample.kind == .primaryUp {
            /* SUPPRESSION, HALF ONE: the button. A held button that belongs
               to a host drag is not a press on the guest, and applying it as
               one is how the guest Finder came to be dragging a file of its
               own under somebody else's gesture. `hostDragOverThisMac` is
               the half that was missing; see its own comment. */
            return
        }
        if sample.kind == .primaryDown {
            let point = mirrorPoint(ownership.guestPoint)
            /* The selection stub wins outright where it is configured. It is
               not a better hit test, it is a different question: what the
               person picked, rather than what is under a point in a scene
               this lane may not have.

               THE ANSWER IS STILL TAKEN HERE, AND IT IS NO LONGER FINAL.
               Taken here because the press is the last moment the cache is
               guaranteed to hold anything at all — crossing back ends the
               epoch, and the epoch ending drops the cache — and because the
               promise fetch this starts wants the head start. Not final
               because the press itself can CHANGE what is selected, and the
               guest cannot have been told yet: that gap is what shipped
               the wrong file on 2026-08-15. The cross re-decides against
               what arrived in between; see resolveSelectionBindingAtCross. */
            pressedSelection = nil
            crossRefusedAsAmbiguous = false
            guestFileCandidate = guestSelectionItem != nil
                ? guestSelectionItem?()
                : guestFileAtPoint?(point)
            let selectionMark = guestSelectionMark?()
            let consumed = driver?.primaryDown(at: point,
                inMenuBar: point.y < HitTester.menubarHeight,
                sourceUptime: sample.eventUptime > 0
                    ? sample.eventUptime : nil) ?? false
            if !consumed {
                guestFileCandidate = nil
            } else if guestSelectionItem != nil {
                /* Stamped AFTER the down went out, so the window in which
                   an arriving selection counts as this press's own starts
                   no earlier than the press did. An in-flight publish that
                   crosses the press is then refused rather than adopted,
                   which is the safe way for this clock to be wrong. */
                pressedSelection = .init(
                    mark: selectionMark,
                    downSentAt: ProcessInfo.processInfo.systemUptime)
            }
            pressOrigin = consumed ? ownership.guestPoint : nil
            pinHostCursor(for: ownership)
            return
        }
        if sample.kind == .primaryUp {
            _ = driver?.primaryUp(at: mirrorPoint(ownership.guestPoint))
            guestFileCandidate = nil
            pressedSelection = nil
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
            /* SUPPRESSION, HALF TWO: the return pipeline. A crossing made
               while a host drag is in flight over this Mac carries that
               drag; it does not carry a guest file, and it must bind
               nothing and return nothing. Without this the 17:22 round ran
               resolveSelectionBindingAtCross against a cache from a previous
               epoch, started an AppKit session for `main.c`, and refused its
               own grab `stale-selection` — a whole pipeline's worth of work
               and three refusals, all of it about a file nobody had picked
               up.

               The condition is deliberately the same flag as half one, not
               a second reading of the gesture. Two conditions that must
               agree about one fact are two places to disagree. */
            if stagedHostFiles != nil {
                /* THE GUEST DROP IS THE COMMIT, so a cross back without one
                   is an abort — not a transfer aimed at the edge. Nothing
                   has been copied: the staging is a pasteboard, and letting
                   it go is the whole of the undo. */
                abandonStagedHostFiles(
                    reason: "the drag crossed back to this Mac without a "
                        + "release on the guest")
                returnToHost(ownership, reason: "the carried file came back "
                    + "without a drop on the guest")
                return
            }
            if hostDragOverThisMac {
                audit(.info, "this cross carries a drag from this Mac, not "
                    + "the guest's: binding nothing and starting no return "
                    + "— a held host drag is not a press over there")
                returnToHost(ownership, reason: "shared edge crossed under a "
                    + "host drag")
                return
            }
            if sample.buttonsDown { resolveSelectionBindingAtCross() }
            if sample.buttonsDown, guestFileCandidate == nil,
               pressedSelection != nil, !crossRefusedAsAmbiguous,
               let pending = lateBind?.pendingItem() {
                /* THE SINGLE GESTURE, AND THE ONLY MOMENT IT CAN BE SERVED.
                   Nothing is bound because nothing could be: an icon nobody
                   selected first leaves no cache entry, and the fact that
                   names it is stuck behind the Finder's drag loop, which
                   THIS handback is about to end. Refusing here is what made
                   a person click the file before dragging it. The session
                   starts carrying an unfilled promise instead, and the
                   generation that arrives ~230 ms from now fills it — or
                   the drop refuses by name and no byte moves. */
                audit(.info, "no file is bound to this cross; starting the "
                    + "drag pending a late bind: the Mac cannot name what is "
                    + "in the hand until this release ends its drag loop, "
                    + "and the drop is what redeems whatever it then says")
                returnGuestFileToHost(pending, from: ownership,
                                      sourceEvent: sourceEvent)
            } else if sample.buttonsDown, let item = guestFileCandidate {
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
        /* Same widening as `transportPhaseChanged`: only a LIVE foreign
           session is a reason not to pin. */
        if !hostDragSessionOverEdgeIsLive { pinHostCursor(for: ownership) }
    }

    /// Decide, at the cross, what this held press is carrying.
    ///
    /// Only the selection lane reaches this: the scene lane bound at the
    /// press because a hit test cannot be asked later. Every outcome is one
    /// audited line naming both generations and the age of the arrival —
    /// the next wrong-file report should be answerable from it alone,
    /// which the 17:19 one was not.
    private func resolveSelectionBindingAtCross() {
        guard let guestSelectionItem, let pressed = pressedSelection else {
            return
        }
        let current = guestSelectionMark?()
        let verdict = ContinuitySelectionBind.decide(
            pressed: pressed.mark, current: current,
            downSentAt: pressed.downSentAt)
        let age = { (mark: ContinuitySelectionMark) -> String in
            String(format: "%+.0f ms from the press",
                   (mark.appliedAt - pressed.downSentAt) * 1_000)
        }
        switch verdict {
        case .dragged(let mark):
            /* THE RITUAL IS DEAD HERE. Not the press's selection, not an
               inference from when something arrived — the item the Drag
               Manager handed the Mac at the instant this drag began. It is
               bound whatever the cache says, and the line names what it
               replaced so that a disagreement is visible rather than
               merely resolved: a stale cache and a fresh drag disagreeing
               is the ORDINARY case for a file nobody selected first. */
            audit(.info, "binding this cross to the drag itself: "
                + "epoch=\(mark.epoch), source=\(mark.source.rawValue), "
                + "generation=\(mark.generation), "
                + "dragSeq=\(mark.dragSeq.map(String.init) ?? "none"), "
                + "published \(age(mark)) by the Mac's drag plane, "
                + "replacing "
                + "\(pressed.mark.map { "generation \($0.generation)" } ?? "nothing")"
                + (mark.generation == 0
                   ? " — IDENTITY ONLY: no generation has been minted for "
                     + "this gesture, so the grab waits for the "
                     + "application's frame rather than asking with a zero"
                   : ""))
            guestFileCandidate = guestSelectionItem()
        case .bound(let mark):
            audit(.info, "this cross carries the selection its press was "
                + "made under: epoch=\(mark.epoch), "
                + "generation=\(mark.generation), published \(age(mark))")
        case .unchallenged(let mark):
            audit(.info, "this cross carries the selection its press was "
                + "made under: epoch=\(mark.epoch), "
                + "generation=\(mark.generation), published \(age(mark)) — "
                + "the Mac has published nothing since, which is the "
                + "ordinary shape of a cross that ended its own epoch")
        case .adopted(let mark):
            /* The selection this press itself created. Nothing else could
               have published while the button was held, and binding the
               press's own selection is the whole point of the guest's
               press probe. */
            audit(.info, "binding this press to the selection it made: "
                + "epoch=\(mark.epoch), source=\(mark.source.rawValue), "
                + "generation=\(mark.generation), "
                + "dragSeq=\(mark.dragSeq.map(String.init) ?? "none"), "
                + "published \(age(mark)), replacing "
                + "\(pressed.mark.map { "generation \($0.generation)" } ?? "nothing")")
            guestFileCandidate = guestSelectionItem()
        case .superseded(let pressedMark, let currentMark):
            /* LOUD, AND NOTHING CROSSES. This Mac holds two candidates and
               no way to tell which the hand chose; a file arriving under
               the wrong name is not a smaller failure than a drag that
               refused. The press still releases at its origin, so the
               Finder completes no move — see returnToHost. */
            audit(.warn, "the selection changed under this press; not "
                + "binding generation \(pressedMark.generation): the Mac now "
                + "publishes generation \(currentMark.generation), applied "
                + "\(age(currentMark)) — too early to be this press's own "
                + "doing, so which file is being dragged is not knowable "
                + "from here")
            /* And no late bind may reopen it: see
               `crossRefusedAsAmbiguous`. */
            crossRefusedAsAmbiguous = true
            guestFileCandidate = nil
        case .nothing:
            audit(.info, "no guest file is bound to this cross: the Mac "
                + "published no usable Finder selection under this press")
            guestFileCandidate = nil
        }
    }

    private func mirrorPoint(_ point: CGPoint) -> MirrorKit.Point {
        .init(x: Int(point.x), y: Int(point.y))
    }

    /// The point a held release must land on — and a LOUD line when there
    /// isn't one.
    ///
    /// `pressOrigin ?? ownership.guestPoint` reads as a harmless default and
    /// is not one: the fallback IS the cross point, so losing the origin
    /// silently becomes "the origin was the screen edge" and the Mac
    /// completes a real Finder move there. That is indistinguishable, from
    /// the outside, from the guest ignoring a correct settle — and on
    /// 2026-08-15 a metal round spent its evidence deciding which of the two
    /// it was looking at. Whatever else is true, this side says which.
    private func heldReleaseOrigin(_ ownership: Ownership) -> MirrorKit.Point {
        if let pressOrigin { return mirrorPoint(pressOrigin) }
        audit(.error, "the press origin was lost before the cross: this "
            + "release lands at the cross point "
            + "\(Int(ownership.guestPoint.x)),\(Int(ownership.guestPoint.y)) "
            + "and the Mac will complete a real Finder move to the screen "
            + "edge — the snap-back cannot happen and this is not the guest")
        return mirrorPoint(ownership.guestPoint)
    }

    private func returnToHost(_ ownership: Ownership, reason: String) {
        audit(.info, "returning pointer to host: reason=\(reason), guest="
            + "\(Int(ownership.guestPoint.x)),\(Int(ownership.guestPoint.y)), "
            + "suppressedWarps=\(suppressedCursorWarps), "
            + "buttonsDown=\(hostButtonsDown ? 1 : 0)")
        /* A held button is nobody's until the human lets go. A LIVE foreign
           drag session is the exception: that held gesture is another
           application's, this app never captured it and must not interrupt
           it. A host drag this Mac already ended at the crossing is not that
           — the button is held and belongs to nobody, which is exactly the
           case custody exists for. */
        let held = hostButtonsDown && !hostDragSessionOverEdgeIsLive
        /* The guest was never pressed on a carried-file pass: this lane only
           ever sends `pointerMoved`. Saying a press origin was "lost" there
           would report an absence that is by design as a defect. */
        let guestWasNeverPressed = hostFileDrag || hostDragEndedAtCross
        if held, pressOrigin == nil, !guestWasNeverPressed {
            /* Silence here reads as "there was nothing to do". There was: the
               button is still down on the guest and this return sends no
               release at all, so the Mac keeps the press. Say so. */
            audit(.error, "the press origin was lost before this held return: "
                + "no release is sent, so the Mac keeps the press at "
                + "\(Int(ownership.guestPoint.x)),\(Int(ownership.guestPoint.y))")
        }
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
        /* The defensive half of the hide/show balance, not the ordinary
           one: `hostFileExited`/`hostFileDropped` already call
           `endHostDragVisuals` on the paths that go through them, and
           this repeats there as a no-op (the `announcedHostDragArrival`
           guard). What this line actually catches is every OTHER way
           ownership can end while a host file drag is still announced —
           transport idle, transport ended, `stop()`, and a pointer
           crossing back to host under `hostDragOverThisMac` (which returns
           through `returnToHost` without visiting `hostFileExited` first,
           relying on AppKit's own `draggingExited` to arrive after). None
           of those should be able to leave the host cursor hidden. */
        endHostDragVisuals()
        /* The same defensive reasoning one line up, for the staging: an
           ownership that ends any other way than a guest release must not
           leave a file staged for a gesture nobody is making any more. */
        abandonStagedHostFiles(reason: "guest pointer ownership ended")
        restoreHostCursor(from: ownership ?? pending,
                          keepInputCapture: keepInputCapture)
        stopKeyboardCapture()
        pending = nil
        ownership = nil
        hostFileDrag = false
        hostDragEndedAtCross = false
        expectingCrossDrop = false
        crossEndRefusal = nil
        guestFileCandidate = nil
        pressedSelection = nil
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
        releaseGuestPressAtOrigin(heldReleaseOrigin(ownership),
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
        pressedSelection = nil
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
        waiting.catchSurfaceAtArm = hit
        catchSurfaceAtArm = hit
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
        /* `postedByThisApp` is the field the 2026-08-15 15:27 log needed and
           did not have. Since the catch surface started winning the hit test,
           the synthetic primary down this app posts to re-arm the session no
           longer falls through to the Finder: it is delivered to our own
           panel and comes straight back through the LOCAL monitor as a
           `leftMouseDown` on our window — the first held event this path
           sees, and so the seed. Every session in that build was seeded that
           way (8 of 8, `type=1, ourWindow=yes`) and every one ended before
           the physical release; the build before it seeded from foreign real
           events and its sessions lasted to the release. Whether that is
           cause or coincidence is one metal round away, and only if the line
           says which kind of event it was. */
        let seedPID = sourceEvent.cgEvent?
            .getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        audit(.info, "host drag seed event: type=\(sourceEvent.type.rawValue)"
            + ", windowNumber=\(sourceEvent.windowNumber), "
            + "ourWindow=\(sourceEvent.window == nil ? "no" : "yes"), "
            + "clickCount=\(sourceEvent.clickCount), "
            + ContinuityDragWitnessReport.seedProvenance(
                sourcePID: seedPID, ownPID: hostProcessIdentifier()))
        /* The one call site. The pasteboard cannot change once
           `beginDraggingSession` exists, so whatever an eager fetch decided
           has to be pinned here — the last instant before that call — and
           nowhere else. See `HostFileDragItem.finalized()`. */
        let item = waiting.item.finalized()
        if let seed = environment.beginFileDrag(item, at: point,
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
            beginDragWitness(seededAt: point)
            audit(.info, "host file drag started from a real mouse event at "
                + "\(Int(point.x)),\(Int(point.y)); this app stands down "
                + "until the session ends")
            status = "Copying the guest file to this Mac on release"
            /* The catch surface stays wide for the length of the session.
               Narrowing it here moved the drag source's own window out from
               under a live drag, one frame after starting it. But WIDE is
               not the same question as HIT-TESTABLE: this app's own session
               must never be refused by the surface it just seeded from, so
               the surface stops intercepting anything at all for exactly
               this session's length. See
               `ContinuityFileEdge.setDropsThroughOwnSession`. */
            setFileEdgeDropsThroughOwnSession(true)
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
        /* Read BEFORE the surface narrows. The catch-surface question this
           report asks is "was the drag source's own window still under the
           seed point when the session ended", and narrowing it first would
           make this app the answer. */
        let report = endDragWitness()
        setFileEdgeCatching(false)
        setFileEdgeDropsThroughOwnSession(false)
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
        if let report {
            /* A separate line, deliberately. The one above says what became
               of the FILE; this one says what became of the SESSION, and the
               2026-08-15 rounds could not be diagnosed because those two
               questions shared a sentence that answered only the first. */
            audit(report.isSuspect ? .error : .info, report.summary)
        }
        if operation.isEmpty {
            status = "Nothing on this Mac took the guest file"
        }
        /* The button may already be up by now; if it is not, the gesture is
           back to being nobody's and custody applies again. */
        if hostButtonsDown { beginHeldCustody(reason: "the drag session ended "
            + "with the button still held") }
        refreshReadyStatus()
    }

    private func beginDragWitness(seededAt point: CGPoint) {
        dragSeededAt = uptime()
        dragSeedPoint = point
        dragWitness = environment.startDragWitness()
        if dragWitness == nil {
            /* Said at the START as well as in the report. A witness that
               could not arm is a fact about the next four seconds, and
               learning it only afterwards is learning it too late to move
               the mouse differently. */
            audit(.warn, "no drag-session witness: the listen-only tap was "
                + "refused, so if this session ends early nothing will be "
                + "able to say what ended it")
        }
    }

    /// Closes the witness and turns it into the sentence. Nil when no session
    /// was ever seeded with one.
    private func endDragWitness() -> ContinuityDragWitnessReport? {
        guard let token = dragWitness else {
            return ContinuityDragWitnessReport(
                witness: ContinuityDragWitness(installed: false),
                seededAt: dragSeededAt, endedAt: uptime(),
                hidHeldAtEnd: physicalPrimaryButtonHeld(),
                sessionHeldAtEnd: sessionPrimaryButtonHeld(),
                catchSurfaceAtArm: catchSurfaceAtArm,
                catchSurface: nil, ownPID: hostProcessIdentifier())
        }
        dragWitness = nil
        let witness = environment.readDragWitness(token)
        environment.stopDragWitness(token)
        return ContinuityDragWitnessReport(
            witness: witness,
            seededAt: dragSeededAt, endedAt: uptime(),
            hidHeldAtEnd: physicalPrimaryButtonHeld(),
            sessionHeldAtEnd: sessionPrimaryButtonHeld(),
            catchSurfaceAtArm: catchSurfaceAtArm,
            catchSurface: fileEdge.map {
                environment.catchSurfaceHitTest($0, at: dragSeedPoint)
            },
            ownPID: hostProcessIdentifier())
    }

    private func setFileEdgeCatching(_ catching: Bool) {
        /* Narrowing resolves any early widen, whoever asked for it. */
        if !catching { preWidenedForGuestDrag = false }
        guard let fileEdge else { return }
        environment.setFileEdgeCatching(fileEdge, catching)
    }

    private func setFileEdgeDropsThroughOwnSession(_ dropsThrough: Bool) {
        guard let fileEdge else { return }
        environment.setFileEdgeDropsThroughOwnSession(fileEdge, dropsThrough)
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

    /// Hides the host cursor's VISIBLE LAYER — nothing else — for the
    /// length of a host file drag. Deliberately narrower than
    /// `hideHostCursor`: that call also detaches and pins the real cursor,
    /// and that machinery stays off for a host file drag on purpose (see
    /// the `!hostFileDrag` guards throughout this file) because the drag
    /// session belongs to Finder, not this app, and this app cannot safely
    /// warp or detach the cursor out from under someone else's live
    /// `NSDraggingSession`.
    ///
    /// KNOWN OPEN QUESTION, recorded rather than resolved here: whether
    /// `CGDisplayHideCursor` also suppresses AppKit's drag-image
    /// compositing layer (the native ghost + green `+` badge this call
    /// exists to hide) or only the arrow cursor itself is metal/attended
    /// evidence this change does not have — see docs/open-issues.md. This
    /// makes the attempt; it does not claim the visual defect fixed.
    ///
    /// Idempotent per gesture and independent of `cursorHiddenOn` — see
    /// `hostDragCursorHiddenOn`.
    private func hideHostDragCursor(on displayID: UInt32) {
        guard hostDragCursorHiddenOn == nil else { return }
        environment.hideCursor(on: displayID)
        hostDragCursorHiddenOn = displayID
        audit(.info, "host file drag: hid the host cursor's visible layer "
            + "(gesture=\(hostFileDragGestureID), display=\(displayID))")
    }

    /// The only place that clears `hostDragCursorHiddenOn`. Safe to call
    /// whether or not the cursor is currently hidden by this path — every
    /// exit funnels through here (directly via `endHostDragVisuals`,
    /// or defensively via `endOwnership`/`deinit`) so a hide can never
    /// outlive the gesture that requested it.
    private func showHostDragCursor() {
        guard let id = hostDragCursorHiddenOn else { return }
        environment.showCursor(on: id)
        hostDragCursorHiddenOn = nil
        audit(.info, "host file drag: restored the host cursor's visible "
            + "layer (gesture=\(hostFileDragGestureID))")
    }

    /// **One audited line per custody transition, in one shape.**
    ///
    /// Custody — hiding the cursor, detaching it from the mouse, parking it,
    /// arming and disarming the consuming tap, re-arming the button — used
    /// to write nothing at all. The 2026-08-16 attended round reported a
    /// carry that "locked in" while "the cursor went wild", and the host log
    /// was SILENT across exactly that window: the forensics could name three
    /// candidate mechanisms and rule out none of them. A transition nobody
    /// can see is a transition nobody can diagnose, so this is a deliverable
    /// rather than a garnish, and every call below carries the gesture id and
    /// the pointer position because those are the two facts that pair a line
    /// with the gesture a person remembers making.
    private func custodyAudit(_ level: HostLog.LogLevel, _ event: String,
                              _ detail: String) {
        audit(level, "custody: \(event) — \(detail) "
            + "(gesture=\(hostFileDragGestureID), host="
            + "\(Int(lastHostSampleLocation.x)),"
            + "\(Int(lastHostSampleLocation.y)))")
    }

    private func hideHostCursor(for ownership: Ownership) {
        let id = ownership.edge.host.id
        guard cursorHiddenOn == nil else { return }
        environment.hideCursor(on: id)
        cursorHiddenOn = id
        cursorParks = 0
        custodyAudit(.info, "host cursor hidden",
                     "display=\(id), the pass now speaks for the pointer")
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
                custodyAudit(.info, "pointer detached from the mouse",
                             "the hardware no longer moves the cursor; this "
                                + "pass does")
            } else {
                custodyAudit(.warn, "pointer NOT detached from the mouse",
                             "warp-echo suppression is carrying this pass")
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
            custodyAudit(.info, "consuming tap armed",
                         "host input is captured; no other application sees "
                            + "these events")
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
        if let inputCapture {
            environment.stopInputCapture(inputCapture)
            custodyAudit(.info, "consuming tap disarmed",
                         "host input reaches this Mac's own applications "
                            + "again")
        }
        inputCapture = nil
    }

    private func reassociateHostCursor() {
        guard cursorDissociated else { return }
        if environment.setCursorMovementAssociated(true) {
            cursorDissociated = false
            custodyAudit(.info, "pointer re-attached to the mouse",
                         "the hardware moves the cursor again")
        } else {
            /* Leave the flag set so the next exit tries again: the worst
               failure this whole change can produce is a mouse the human
               cannot move. */
            custodyAudit(.error, "could NOT re-attach the host cursor to the "
                + "mouse", "the next exit will try again; until one succeeds "
                + "the hardware does not move the cursor")
        }
    }

    private func pinHostCursor(for ownership: Ownership) {
        let host = ownership.edge.host.frame
        let point = CGPoint(x: ownership.hostAnchor.x - host.minX,
                            y: host.maxY - ownership.hostAnchor.y)
        expectCursorWarp(to: ownership.hostAnchor)
        /* The first park of a pass, and only the first: this runs on every
           sample, and the count is reported at the restore. What the first
           line is for is the "cursor went wild" report — it names the anchor
           every subsequent park aims at, so a wild cursor is either wild
           AROUND a stated point or the anchor itself is moving. */
        cursorParks &+= 1
        if cursorParks == 1 {
            custodyAudit(.info, "cursor parked at the anchor",
                         "anchor=\(Int(ownership.hostAnchor.x)),"
                            + "\(Int(ownership.hostAnchor.y))")
        }
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
            custodyAudit(.info, "host cursor restored",
                         "display=\(id), parks=\(cursorParks), "
                            + "suppressedWarps=\(suppressedCursorWarps)")
            cursorParks = 0
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
            entered: { [weak self] point, pasteboard in
                self?.hostFileEntered(at: point,
                                      pasteboard: pasteboard) ?? false
            },
            exited: { [weak self] in self?.hostFileExited() },
            dropped: { [weak self] pasteboard in
                self?.hostFileDropped(pasteboard) ?? false
            },
            dragEnded: { [weak self] operation, point in
                self?.hostDragSessionEnded(operation, at: point)
            },
            ghostBlanked: { [weak self] items in
                guard let self else { return }
                audit(.info, "host file drag: asked AppKit to draw this "
                    + "destination's copy of the drag with no image "
                    + "(items=\(items), gesture=\(hostFileDragGestureID)). "
                    + "Whether the window server's ghost for a foreign "
                    + "session actually goes with it is attended-only "
                    + "evidence; items=0 would mean the enumeration found "
                    + "nothing to touch")
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
                                       catchThickness: edgeGeometry.deadzoneDepth,
                                       callbacks: fileEdgeCallbacks)
        } else {
            fileEdge = environment.showFileEdge(
                edge, catchThickness: edgeGeometry.deadzoneDepth,
                callbacks: fileEdgeCallbacks)
        }
    }

    private func hostFileEntered(at hostPoint: CGPoint,
                                 pasteboard: NSPasteboard) -> Bool {
        /* The strip is a destination for FOREIGN drags. A drag this app
           started is refused by identity in the view itself; this is the
           second door onto the same rule, because a host→guest pass armed
           during our own guest→host handoff would steer the guest with the
           file that is on its way here. */
        if hostDragSessionLive || pendingReturnDrag != nil {
            /* Our own handoff, not somebody's held file: this must NOT
               arm the suppression, or the guest→host direction would
               suppress itself at its own crossing. */
            if !announcedOwnDragRefusal {
                announcedOwnDragRefusal = true
                audit(.info, "the shared edge refused an incoming file: this "
                    + "Mac is in the middle of taking one FROM the guest")
            }
            return false
        }
        /* THE FACT, RECORDED BEFORE ANY DECISION ABOUT WHAT TO DO WITH IT.
           Everything below can decline to steer the guest — the controller
           may already be `.active`, or have no shared edge — and none of
           those are reasons to forget that a person is holding a drag over
           this edge right now. That forgetting is the 17:22 defect; see
           `hostDragOverThisMac`. */
        hostDragOverThisMac = true
        /* THE GESTURE IS TAKEN HERE, ONCE. Taken on the false→true edge
           rather than on every `draggingUpdated`, which the strip receives
           on every motion. Taken BEFORE the steering decision below for the
           same reason the flag is set before it: the person is carrying
           this file whether or not this controller ends up driving the
           guest pointer for them. */
        if !announcedHostDragArrival {
            announcedHostDragArrival = true
            hostFileDragGestureID &+= 1
            /* The other machine is about to draw this carry — the handoff's
               own drag, once the crossing hands it over. Hide the host's
               real cursor layer so the two don't read as competing cursors
               — see `hideHostDragCursor`'s doc comment for what this is and
               is not proven to suppress. */
            if let id = layout.sharedEdge?.host.id {
                hideHostDragCursor(on: id)
            } else {
                audit(.warn, "host file drag arrived with no shared edge "
                    + "display to hide the cursor on (gesture="
                    + "\(hostFileDragGestureID))")
            }
        }
        if hostFileDrag {
            /* Every `draggingUpdated` lands here too — the strip is asked on
               every motion — so the arrival is announced ONCE per gesture
               and the rest are steering. */
            endHostDragAtCross(pasteboard, at: hostPoint)
            return state == .arming || state == .active
        }
        guard state == .ready, let edge = layout.sharedEdge else {
            return false
        }
        let guest = ContinuityDisplayGeometry.guestEntryPoint(
            at: hostPoint, edge: edge, guestFrame: layout.guestFrame,
            guestPixels: layout.guestSize, scale: layout.guestScale,
            insetPixels: edgeGeometry.entryInsetPixels)
        let anchor = ContinuityDisplayGeometry.hostReturnPoint(
            for: guest, edge: edge, guestFrame: layout.guestFrame,
            scale: layout.guestScale)
        pending = Ownership(edge: edge, guestPoint: guest,
                            hostAnchor: anchor)
        hostFileDrag = true
        state = .arming
        status = "Connecting the guest file target…"
        driver?.pointerMoved(to: mirrorPoint(guest))
        /* Last, and only once the guest has been aimed from the REAL
           crossing point: the release posted below lands wherever the
           cursor is, and the arm above is the last thing that needs the
           crossing to still be in progress. */
        endHostDragAtCross(pasteboard, at: hostPoint)
        return true
    }

    /// **End the host's own drag AT the handoff, by releasing it onto this
    /// app's own destination.**
    ///
    /// Michelle's ruling, attended, 2026-08-16: each side's OS should end
    /// its own drag at the crossing, the way the guest→host direction
    /// already releases the guest press at the cross. Hiding the host cursor
    /// removed the green `+` badge and nothing else — the native ghost and
    /// the real pointer still caught at the physical screen edge, and
    /// resting there triggered the window server's own edge behaviour
    /// (switching Spaces). None of that is fixable while a foreign
    /// `NSDraggingSession` is still in flight, because the ghost is anchored
    /// to a real cursor that has nowhere further to go. So the session is
    /// not hidden, it is ENDED.
    ///
    /// **The release is posted while the cursor is over our own strip, and
    /// that is the safety property, not an implementation detail.** A
    /// `leftMouseUp` at the HID level terminates the drag wherever it lands;
    /// landing it on the strip means the OS performs the drop onto the
    /// legitimate destination for this gesture — this app, which is already
    /// carrying the file to the guest — rather than onto whatever window
    /// happens to be under an arbitrary point. The strip is widened first
    /// for the same reason: the drop needs room to land on us in the
    /// milliseconds between the post and the window server routing it.
    ///
    /// **What this app accepts there is a STAGING, not the transfer.** The
    /// person has not chosen a place on the guest yet; the guest release is
    /// still the commit. See `hostFileDropped`'s cross-drop branch,
    /// `completeStagedHostDrop`, and `abandonStagedHostFiles`.
    ///
    /// Declined, once per gesture and with the reason logged, when the drag
    /// carries nothing that can outlive its own session (a promise-only
    /// drag) or when the window server refuses the post. The gesture then
    /// runs exactly as it did before this change — ghost, badge and all —
    /// which looks worse, not a broken transfer.
    private func endHostDragAtCross(_ pasteboard: NSPasteboard,
                                    at hostPoint: CGPoint) {
        guard hostFileDrag, !hostDragEndedAtCross, !expectingCrossDrop,
              crossEndRefusal == nil else { return }
        guard let staged = stageHostFiles(pasteboard) else {
            crossEndRefusal = "this drag carries no file this Mac can still "
                + "name once the session ends (a promise-only drag)"
            audit(.warn, "host file drag: NOT ending the host drag at the "
                + "crossing — \(crossEndRefusal ?? ""). The Finder's own "
                + "drag stays in flight for this gesture, ghost and all "
                + "(gesture=\(hostFileDragGestureID))")
            return
        }
        stagedHostFiles = staged
        stagedCarry = .init()
        /* Per-gesture, at the one place a staging begins: a handoff belongs
           to the carry that produced it, and so does the bound on it. */
        hostDragHandedOff = false
        stagedCarryTimedOut = false
        stagedCrossPoint = hostPoint
        expectingCrossDrop = true
        /* Widened before the post, not after: the drop has to have a
           surface of ours to land on at the instant the window server
           routes the release. */
        setFileEdgeCatching(true)
        let posted = environment.postSyntheticPrimaryButtonAtHID(
            down: false, at: hostPoint)
        audit(posted ? .info : .error,
              "host file drag: \(posted ? "posted" : "could not post") a "
                + "synthetic release at the HID level over this Mac's own "
                + "catch surface to END the host drag at the crossing "
                + "(gesture=\(hostFileDragGestureID), at="
                + "\(Int(hostPoint.x)),\(Int(hostPoint.y)), "
                + "inputCapture=\(inputCapture == nil ? "none" : "live")). "
                + "The file is staged; the guest release is still the commit")
        guard posted else {
            stagedHostFiles = nil
            stagedCarry = .init()
            expectingCrossDrop = false
            setFileEdgeCatching(false)
            crossEndRefusal = "the window server refused the synthetic "
                + "release"
            return
        }
    }

    /// The drop this Mac caused, as opposed to one a person made on the
    /// strip. Nothing is transferred here — see `endHostDragAtCross`.
    private func acceptCrossDrop(_ pasteboard: NSPasteboard) -> Bool {
        expectingCrossDrop = false
        hostDragEndedAtCross = true
        _ = pasteboard
        audit(.info, "host file drag: the host drag ENDED at the crossing — "
            + "this Mac's own strip took the drop, so nothing of the "
            + "Finder's is still in flight and the pass now takes ordinary "
            + "pointer custody (gesture=\(hostFileDragGestureID))")
        /* THE TOGGLE, AND IT HAPPENS HERE. Before the converge below, not
           after: the converge re-arms the button, and the guest starts its
           own drag when that applied button says so — a skeleton arriving
           after the press it is meant to explain is a press with nothing to
           drag. */
        handOffToGuest()
        convergeAfterCrossDrop()
        /* Narrowed LAST, after the converge has armed custody and posted the
           button re-arm: the widened strip is what the re-arm's own point
           sits on, and a surface withdrawn before that post is a surface
           that was not there when it mattered. */
        setFileEdgeCatching(false)
        return true
    }

    /// Takes the custody an ordinary crossing would already have had.
    ///
    /// Withheld until now for one reason only — a foreign session this app
    /// could not safely detach the cursor out from under — and that reason
    /// died with the session. From here the real cursor is hidden, detached
    /// and pinned exactly like any other guest pass, which is also what
    /// stops the physical pointer sitting on the screen edge triggering the
    /// window server's own edge behaviours.
    ///
    /// **It is also what consumes the person's eventual physical release.**
    /// The consuming tap `hideHostCursor` starts is what turns that release
    /// into a sample this controller sees (`completeStagedHostDrop`) rather
    /// than an event some host window under the pointer inherits.
    private func convergeAfterCrossDrop() {
        guard let current = ownership else {
            /* Still `.arming`: the transport has not confirmed. Custody is
               armed by `transportPhaseChanged(.active)`, whose guard now
               asks the same widened question. Named here because the gap
               between the synthetic release and that confirmation is the
               one window in which a physical release reaches this Mac. */
            audit(.info, "host file drag: the host drag ended at the "
                + "crossing before the guest confirmed ownership; custody "
                + "is armed when it does (gesture=\(hostFileDragGestureID))")
            return
        }
        hideHostCursor(for: current)
        startKeyboardCapture()
        /* AFTER the tap, never before: the re-arm is a synthetic button
           press, and the only thing that keeps it out of another
           application is the capture `hideHostCursor` just armed. */
        rearmStagedCarryButton()
        status = "Carrying the file on the guest display"
    }

    /// **Hand the gesture to the other machine's Drag Manager.**
    ///
    /// One act per staged carry, at the staging point and nowhere else:
    /// the skeleton for what is staged, sent at the GUEST ENTRY POINT the
    /// crossing already computed. Position and button travel on the
    /// ordinary Continuity datagrams from here, so there is nothing more to
    /// send — and nothing here says where the file should land, because
    /// after this call that is not this Mac's question.
    ///
    /// A refusal is honest degradation, not a failure: the crossing keeps
    /// its staged file and its release still commits through the existing
    /// lane. What must never happen is a silent one.
    private func handOffToGuest() {
        guard !hostDragHandedOff, let staged = stagedHostFiles else { return }
        guard let handoff = hostDragHandoff else {
            audit(.info, "host file drag: no handoff is wired, so the "
                + "crossing stages and transfers on release exactly as it "
                + "did before the native lane "
                + "(gesture=\(hostFileDragGestureID))")
            return
        }
        guard let current = ownership ?? pending else {
            audit(.warn, "host file drag: the staging point was reached with "
                + "no guest entry point to hand off at, so the Macintosh "
                + "starts no drag (gesture=\(hostFileDragGestureID))")
            return
        }
        let point = mirrorPoint(current.guestPoint)
        /* **THE BUTTON IS HELD BEFORE THE BEGIN CROSSES, AND THE ORDER IS
           THE INVARIANT.** The guest's `TrackDrag` samples its input proc
           immediately, and a first sample reading button-UP returns at the
           entry point — the drag that dropped instantly on metal (F2 defect
           B). The correct invariant is not "the begin arrives after a press"
           but "the level is already in the plane when the begin is sent",
           and this Mac writes both, so it can simply guarantee it: the
           datagram plane is UDP and written at the guest's notifier time,
           the begin is TCP and served on a later service pass. */
        holdCarriedButton(true, reason: "a file is being carried on the "
            + "Macintosh, and its Drag Manager reads this level for as long "
            + "as the person holds it")
        let sent = handoff.begin(staged, point, hostFileDragGestureID)
        hostDragHandedOff = sent
        if !sent {
            /* Nothing over there is reading the level, so holding it would
               be this Mac asserting a button into a plane with no drag
               behind it. */
            holdCarriedButton(false, reason: "the handoff never crossed, so "
                + "there is no drag over there to hold a button for")
        }
        let verb = sent ? "handed the drag OVER to"
                        : "could NOT hand the drag over to"
        audit(sent ? .info : .warn,
              "host file drag: \(verb) the Macintosh at "
                + "\(point.x),\(point.y) — from here its Drag Manager owns "
                + "the gesture and this Mac only serves the promise "
                + "(gesture=\(hostFileDragGestureID))")
        if sent { armStagedCarryDeadline() }
    }

    /// **The carry's button, as a level the guest's drag reads and the
    /// guest's resident ignores.**
    ///
    /// Raised once at the handoff and cleared on every path out of a carry:
    /// the commit (the person's release, so the drop lands where they let
    /// go), the abort (cross-back, the bound, a refused handoff), and the
    /// epoch's own teardown underneath all of them
    /// (`clearTransportState`). A level left raised is a guest stuck in a
    /// drag nobody is making, which is why the clears outnumber the raise
    /// and why they are idempotent.
    ///
    /// `reassert` re-sends a level already held: raising one before the
    /// transport is active sets the field with nothing on the wire, and the
    /// pass that confirms ownership is where it becomes a fact.
    private func holdCarriedButton(_ held: Bool, reason: String,
                                   reassert: Bool = false) {
        guard carriedButtonHeld != held || reassert else { return }
        carriedButtonHeld = held
        let onWire = driver?.setCarriedButtonLevel(
            held, gesture: hostFileDragGestureID, reason: reason) ?? false
        carriedButtonOnWire = held && onWire
        guard held, !onWire else { return }
        /* NOT SILENCE: a raise nobody could send is a carry whose drag will
           read an unheld button over there and drop where it entered — the
           exact defect this level exists to end. It is re-asserted when the
           transport confirms; this line is what says the gap happened. */
        audit(.warn, "host file drag: the carried button level could not "
            + "reach the Macintosh yet (no active pointer epoch) — it is "
            + "re-asserted when ownership is confirmed "
            + "(gesture=\(hostFileDragGestureID))")
    }

    /// Bounds the staged carry. See `stagedCarryLifetime` for why the bound
    /// is generous and why it exists at all.
    private func armStagedCarryDeadline() {
        stagedCarryDeadlineID &+= 1
        let id = stagedCarryDeadlineID
        let gesture = hostFileDragGestureID
        schedule(Self.stagedCarryLifetime) { [weak self] in
            self?.stagedCarryDeadlineFired(id: id, gesture: gesture)
        }
        armStagedCarryProbe()
    }

    /// Time-driven twin of driveGuest's HID-backstop branch: the same
    /// check, on a clock, so a release that produces no event AND no
    /// motion still commits instead of waiting out the whole staged-carry
    /// lifetime. Idle probes are cheap (one HID state read); the probe
    /// dies with the staging.
    private func armStagedCarryProbe() {
        stagedCarryProbeID &+= 1
        let id = stagedCarryProbeID
        schedule(Self.stagedCarryProbeInterval) { [weak self] in
            self?.stagedCarryProbeFired(id: id)
        }
    }

    private func stagedCarryProbeFired(id: UInt64) {
        guard id == stagedCarryProbeID, stagedHostFiles != nil else {
            return
        }
        if let ownership, stagedCarryReleasedAtHID() {
            completeStagedHostDrop(at: ownership,
                                   release: "the HID poll says the button "
                                    + "went up and neither an event nor "
                                    + "motion carried it")
            return
        }
        armStagedCarryProbe()
    }

    private func stagedCarryDeadlineFired(id: UInt64, gesture: UInt64) {
        guard id == stagedCarryDeadlineID, stagedHostFiles != nil else {
            return
        }
        stagedCarryTimedOut = true
        audit(.warn, "host file drag: the carry was still staged "
            + "\(Int(Self.stagedCarryLifetime))s after the handoff — the "
            + "Macintosh never dropped it and no release ever reached this "
            + "Mac, so the file is let go rather than held forever "
            + "(gesture=\(gesture))")
        abandonStagedHostFiles(
            reason: "no drop and no release within "
                + "\(Int(Self.stagedCarryLifetime))s of the handoff")
    }

    /// **Undo this Mac's own lie about the button, the way the guest→host
    /// lane already does.**
    ///
    /// `endHostDragAtCross` posts a `leftMouseUp` at `.cghidEventTap` to end
    /// Finder's session. That sets the system's global primary-button state
    /// to UP while the person's finger is still down — so when they
    /// eventually lift, IOHIDSystem sees no transition, emits no
    /// `leftMouseUp`, and the commit gated on that event can never fire. Six
    /// of seven carries on 2026-08-16 died exactly there, and the one that
    /// worked did so only because Michelle pressed the button AGAIN
    /// mid-carry (F1 ledger, D2).
    ///
    /// The guest→host lane has always handled the mirror image of this: its
    /// consuming tap swallows the physical down, so it posts a synthetic
    /// down to re-arm the session's belief before a drag session may begin
    /// (`armSessionButtonIfSurfaceIsReady`, `session button state
    /// re-armed`). This is the same mechanism pointed the other way — a
    /// synthetic DOWN posted after our synthetic UP, at the HID level
    /// because that is the level our release lied to, so the physical lift
    /// is a real transition again.
    ///
    /// **It waits for the consuming tap, and declines without one.** A down
    /// posted at the HID level with no tap in front of it is this app
    /// pressing a button in another application — the same rule
    /// `armSessionButtonIfSurfaceIsReady` refuses to break, and the reason
    /// it holds its own post until the catch surface owns the point.
    private func rearmStagedCarryButton() {
        guard stagedHostFiles != nil, !stagedCarry.reArmed else { return }
        guard inputCapture != nil else {
            custodyAudit(.error, "button re-arm DECLINED",
                         "this Mac has no consuming tap, and a synthetic "
                            + "down with nothing in front of it presses a "
                            + "button in another application. The physical "
                            + "release will not commit this carry")
            return
        }
        let posted = environment.postSyntheticPrimaryButtonAtHID(
            down: true, at: stagedCrossPoint)
        stagedCarry.reArmed = posted
        custodyAudit(posted ? .info : .error,
                     posted ? "button re-armed" : "button re-arm FAILED",
                     "synthetic primary down at "
                        + "\(Int(stagedCrossPoint.x)),"
                        + "\(Int(stagedCrossPoint.y)) undoing this Mac's own "
                        + "release, so the person's physical lift is a real "
                        + "HID transition again")
    }

    /// The backstop for the release, read off the hardware rather than
    /// waited for as an event.
    ///
    /// The event is the ordinary path and this is not a substitute for it —
    /// but the whole D2 defect was a commit gated on an event that the
    /// window server had been talked out of emitting, and one desync of that
    /// shape is enough to stop trusting the event alone. Only armed once the
    /// HID has confirmed the re-arm took: before that, "not held" is this
    /// Mac's own synthetic release coming back as an answer.
    private func stagedCarryReleasedAtHID() -> Bool {
        guard stagedCarry.reArmed else { return false }
        guard !physicalPrimaryButtonHeld() else {
            if !stagedCarry.heldSeen {
                stagedCarry.heldSeen = true
                custodyAudit(.info, "button re-arm confirmed",
                             "the HID reads the primary button held again")
            }
            return false
        }
        return stagedCarry.heldSeen
    }

    /// The person released on the guest: the staged file lands there, and
    /// this is the only place a host→guest transfer is ever started once the
    /// crossing has ended the host drag.
    private func completeStagedHostDrop(at ownership: Ownership,
                                        release: String) {
        guard let staged = stagedHostFiles else { return }
        stagedHostFiles = nil
        let carry = stagedCarry
        stagedCarry = .init()
        /* THE DEADLINE DIES WITH THE CARRY IT BOUNDED. */
        stagedCarryDeadlineID &+= 1
        /* **THE PHYSICAL RELEASE IS THE BUTTON-UP THE OTHER MACHINE'S DRAG
           IS WAITING FOR**, and clearing the level is the whole of sending
           it: the input proc's next sample reports the button released,
           `TrackDrag` returns, and the drop lands where the person let go
           rather than where they crossed. Cleared BEFORE the branch below,
           because it is true of both — the commit ends the carry whether or
           not the gesture was ever handed over. */
        holdCarriedButton(false, reason: "the person let the file go, and "
            + "the release is what the Macintosh's drag drops on")
        let point = mirrorPoint(ownership.guestPoint)
        if hostDragHandedOff {
            /* **THE GUEST'S DROP IS THE COMMIT, AND THIS MAC ADDS NOTHING
               TO IT.** The gesture belongs to the other machine's Drag
               Manager: the person's release becomes its button-up, its
               Finder resolves the drop and asks for the promise, and the
               only thing wanted from this side is that the promise still be
               serveable when it does. So the offer is NOT cleared here —
               the pull happens after this instant, inside that drop. */
            hostDragHandedOff = false
            audit(.info, "host file drag: \(release) at \(point.x),"
                + "\(point.y) while the Macintosh owned the gesture — its "
                + "drop is the commit, and this Mac keeps serving the "
                + "promise until its send proc asks "
                + "(gesture=\(hostFileDragGestureID), "
                + "buttonReArmed=\(carry.reArmed ? 1 : 0), "
                + "suppressedPresses=\(carry.suppressedPresses))")
            endHostDragVisuals()
            hostFileDrag = false
            hostDragEndedAtCross = false
            crossEndRefusal = nil
            status = "The Macintosh is taking the file"
            return
        }
        let accepted = hostFilesDropped?(staged, point) ?? false
        audit(accepted ? .info : .warn,
              "host file drag: \(release) at "
                + "\(point.x),\(point.y) and the staged file was "
                + "\(accepted ? "accepted" : "refused") "
                + "(gesture=\(hostFileDragGestureID), "
                + "buttonReArmed=\(carry.reArmed ? 1 : 0), "
                + "suppressedPresses=\(carry.suppressedPresses))")
        endHostDragVisuals()
        hostFileDrag = false
        hostDragEndedAtCross = false
        crossEndRefusal = nil
        status = accepted
            ? "Copying the file to the guest"
            : "The guest refused the file"
    }

    /// The undo, and it is a small one BY DESIGN: nothing has been copied
    /// while a file is merely staged, so letting the staging go is the whole
    /// of the abort — no partial file on the guest, and nothing left drawn
    /// on this side (`endHostDragVisuals` runs beside this one).
    private func abandonStagedHostFiles(reason: String) {
        guard stagedHostFiles != nil else { return }
        stagedHostFiles = nil
        let carry = stagedCarry
        stagedCarry = .init()
        stagedCarryDeadlineID &+= 1
        /* **AND THE ABORT IS A RELEASE TOO, over there.** The guest's input
           proc reports a point nothing accepts and then this cleared level;
           `TrackDrag` returns `userCanceledErr` and the Manager plays its
           own snap-back. Covers every abort this funnel serves — the
           cross-back, the bound, a teardown — because they all arrive
           here. */
        holdCarriedButton(false, reason: "the carry ended without a drop — "
            + "\(reason)")
        audit(.info, "host file drag: the staged file was let go without a "
            + "transfer — \(reason). Nothing was copied "
            + "(gesture=\(hostFileDragGestureID), "
            + "buttonReArmed=\(carry.reArmed ? 1 : 0), "
            + "suppressedPresses=\(carry.suppressedPresses))")
        guard hostDragHandedOff else { return }
        /* **THE ABORT IS NATIVE ON BOTH SIDES, AND THIS IS THIS SIDE'S
           HALF.** Over there the guest's input proc reports a point nothing
           accepts and then button-up, `TrackDrag` returns
           `userCanceledErr`, and the Drag Manager plays its own snap-back —
           no cancel channel, nothing of ours drawn. Here the whole abort is
           letting the promise go, because nothing was ever copied. */
        hostDragHandedOff = false
        audit(.info, "host file drag: releasing the promise the Macintosh "
            + "was handed — \(reason) (gesture=\(hostFileDragGestureID))")
        hostDragHandoff?.abandon(reason, hostFileDragGestureID)
    }

    private func hostFileExited() {
        /* Cleared FIRST and unconditionally, for the mirror image of the
           reason it is set unconditionally: the drag is gone whether or not
           this controller was steering anything on its behalf. A suppression
           flag that outlives the gesture it describes turns one defect into
           a permanently deaf edge. */
        hostDragOverThisMac = false
        if expectingCrossDrop {
            /* THE FALLBACK OBSERVATION, AND IT IS WORTH AS MUCH AS THE
               SUCCESS. The release was posted and AppKit reported the drag
               LEAVING rather than dropping on us — the drop landed
               somewhere else, or the session ended without one. Nothing was
               staged into a transfer, so the abort below is complete; what
               matters is that the log says which of the two happened. */
            expectingCrossDrop = false
            setFileEdgeCatching(false)
            abandonStagedHostFiles(
                reason: "the release this Mac posted did not come back as a "
                    + "drop on its own strip")
            audit(.warn, "host file drag: the synthetic release did NOT come "
                + "back as a drop on this Mac's own strip — AppKit reported "
                + "the drag leaving instead (gesture="
                + "\(hostFileDragGestureID)). Nothing was transferred")
        }
        endHostDragVisuals()
        guard hostFileDrag, let current = ownership ?? pending else { return }
        returnToHost(current, reason: "host file left the shared edge")
    }

    /// Ends what this Mac is DRAWING for a carried drag — exactly once, on
    /// whichever path gets there first. Every exit from a carried drag runs
    /// through here: leaving the strip, dropping on it, and the
    /// self-healing release.
    ///
    /// Two things, and both are load-bearing. It clears
    /// `announcedHostDragArrival`, which is what makes a second call a
    /// no-op and what lets a later gesture be numbered as its own. And it
    /// restores the host cursor's visible layer, because the moment this
    /// Mac stops speaking for the gesture is the moment the human's own
    /// cursor should be theirs again.
    ///
    /// It used to also call a `departed` closure that told the guest to
    /// stop drawing a PRESENTATION drag. That lane was deleted 2026-08-17
    /// — the guest starts its own native drag from the handoff now, and
    /// ends it itself — so what survives here is this side's own visuals,
    /// which is what the name says.
    private func endHostDragVisuals() {
        guard announcedHostDragArrival else { return }
        announcedHostDragArrival = false
        showHostDragCursor()
    }

    private func hostFileDropped(_ pasteboard: NSPasteboard) -> Bool {
        hostDragOverThisMac = false
        if expectingCrossDrop {
            /* Handled BEFORE the teardown below, because this drop is not
               the end of anything a person is doing: they are still
               carrying the file, on the guest, and this side's drag
               visuals must keep running. */
            return acceptCrossDrop(pasteboard)
        }
        /* Torn down BEFORE the transfer is handed off, not after. The drop
           is the end of the gesture a person is watching, and a guest still
           drawing a drag while its file is being written is the shape of lie
           this project keeps paying for. The transfer's own outcome speaks
           for itself afterwards. */
        endHostDragVisuals()
        guard hostFileDrag, let current = ownership ?? pending,
              let hostFilesDropped else { return false }
        let accepted = hostFilesDropped(
            pasteboard, mirrorPoint(current.guestPoint))
        returnToHost(current, reason: accepted
                     ? "host file released" : "guest target refused the file")
        return accepted
    }

    /// The file-PROMISE lane's own outcome, once AppKit has handed a
    /// promise off to whatever accepted the drag and this Mac's copy of the
    /// guest file either arrives or is refused.
    ///
    /// It exists apart from `hostDragSessionEnded`'s status line because
    /// the two answer different questions at different times, on different
    /// queues. Session-end only knows whether something ACCEPTED the
    /// promise, and settles the status back to ready right after — see the
    /// comment there ("the promise lane owns the outcome from here"). What
    /// happened to the BYTES is redeemed asynchronously by
    /// `ContinuityGrabTransfer`, often well after the session line has
    /// already been overwritten, and a grab refused by the guest
    /// (`stale-selection`, `grant-expired`, …) used to end there: the drag
    /// vanished with nothing on screen to say why. This is that sentence,
    /// in the same register as every other status line here.
    func reportFileGrabOutcome(_ message: String) {
        status = message
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
            if let dragWitness { environment.stopDragWitness(dragWitness) }
            if let keyboardMonitor { keyboardEnvironment.stop(keyboardMonitor) }
            if let fileEdge { environment.hideFileEdge(fileEdge) }
            if let id = cursorHiddenOn { environment.showCursor(on: id) }
            if let id = hostDragCursorHiddenOn { environment.showCursor(on: id) }
            /* The last chance to give the mouse back, and unlike the audited
               paths above there is nobody left to report a failure to. */
            if cursorDissociated {
                _ = environment.setCursorMovementAssociated(true)
            }
        }
    }
}
