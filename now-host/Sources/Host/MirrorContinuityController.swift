import Combine
import Foundation
import MirrorKit
import MirrorKitUI
import Network

enum ContinuityOptionTier: Sendable {
    case product
    case diagnostic
}

enum ContinuityOptionID: String, CaseIterable, Sendable {
    case fastPump
    case settleSyntheticDevice
    case wideDoubleTime
    case compressClickWhen
    case interruptPress
    case deepClickLog
    case settleIdleCursor
}

struct ContinuityOptionDescriptor: Identifiable {
    let id: ContinuityOptionID
    let label: String
    let detail: String
    let tier: ContinuityOptionTier
    let defaultEnabled: Bool
    let rearmReason: String
    let keyPath: ReferenceWritableKeyPath<MirrorContinuityController, Bool>
}

/// The one classification and persistence table for every guest-arm option.
/// Contract fields remain accretive, but retired fields never enter this list.
@MainActor
enum ContinuityOptionCatalog {
    static let all: [ContinuityOptionDescriptor] = [
        .init(id: .fastPump, label: "Fast Pump",
              detail: "Ask the guest to yield every tick while diagnosing scheduling.",
              tier: .diagnostic, defaultEnabled: false,
              rearmReason: "Fast Pump changed",
              keyPath: \MirrorContinuityController.fastPump),
        .init(id: .settleSyntheticDevice,
              label: "Settle synthetic pointer state",
              detail: "Keep the guest's pointer manager coherent after host motion.",
              tier: .product, defaultEnabled: true,
              rearmReason: "synthetic-device settlement changed",
              keyPath: \MirrorContinuityController.settleSyntheticDevice),
        .init(id: .wideDoubleTime,
              label: "Preserve the double-click window",
              detail: "Allow for cooperative scheduling delays between click edges.",
              tier: .product, defaultEnabled: true,
              rearmReason: "double-click window changed",
              keyPath: \MirrorContinuityController.wideDoubleTime),
        .init(id: .compressClickWhen,
              label: "Preserve Finder click timing",
              detail: "Keep synthetic click timestamps inside Finder's private window.",
              tier: .product, defaultEnabled: true,
              rearmReason: "click-when compression changed",
              keyPath: \MirrorContinuityController.compressClickWhen),
        .init(id: .interruptPress,
              label: "Keep double-click delivery responsive",
              detail: "Deliver a deferred second press while the guest is busy.",
              tier: .product, defaultEnabled: true,
              rearmReason: "interrupt press delivery changed",
              keyPath: \MirrorContinuityController.interruptPress),
        .init(id: .deepClickLog, label: "Deep click logging",
              detail: "Record click timing and guest low-memory state for diagnosis.",
              tier: .diagnostic, defaultEnabled: false,
              rearmReason: "deep click probe changed",
              keyPath: \MirrorContinuityController.deepClickLog),
        .init(id: .settleIdleCursor,
              label: "Keep guest cursor motion smooth",
              detail: "Settle idle motion even while a guest process starves its pump.",
              tier: .product, defaultEnabled: true,
              rearmReason: "idle cursor settlement changed",
              keyPath: \MirrorContinuityController.settleIdleCursor),
    ]

    static func descriptor(_ id: ContinuityOptionID)
        -> ContinuityOptionDescriptor {
        all.first { $0.id == id }!
    }

    static func options(in tier: ContinuityOptionTier)
        -> [ContinuityOptionDescriptor] {
        all.filter { $0.tier == tier }
    }
}

/// Owns the optional raw-pointer lane. TCP grants authority; UDP carries
/// replaceable latest state and acknowledgements. Nothing here is reachable
/// from the command or agent surfaces.
@MainActor
final class MirrorContinuityController: ObservableObject,
                                      ContinuityInputDriver,
                                      ContinuityEdgeDriving {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    enum Phase: Equatable {
        case idle
        case arming
        case active
    }

    @Published var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled {
                relinquish(reason: "disabled", keepEnabled: false)
            } else {
                if let host = listener.activeContinuityTarget?.host {
                    localNetworkAccess?.verifyDirectAccess(to: host)
                    status = "requesting Local Network access; move over "
                        + "the Mirror to connect the pointers"
                } else {
                    status = "unavailable: no Mac is connected"
                }
            }
        }
    }

    /* One controller, two consumers, and they are made exclusive HERE
       rather than by each remembering the other exists. Screen-edge mode
       belongs to the Continuity module; the Mirror's in-picture cursor is
       a Mirror feature that borrows this controller as an input driver.
       Both drive the same guest pointer, so edge mode wins: while it is
       active the Mirror's driver hook reads nil. `isEnabled` is derived
       from the two requests and is no longer set directly by either
       owner. */
    @Published private(set) var edgeModeActive = false
    private var mirrorCursorActive = false

    func beginEdgeMode() {
        guard !edgeModeActive else { return }
        /* Asked here, not at launch or construction: the system dialog is
           the loud, one-shot kind, and firing it before the person has
           asked for the feature that needs it is the defect this change
           exists to fix in the other direction — a prompt nobody asked for
           is as unhelpful as no prompt at all. Guarded so a second
           `beginEdgeMode` this launch (after a manual toggle off and on)
           does not re-show a dialog macOS already answered by putting the
           app in the Accessibility pane. */
        /* Every branch below says so out loud. The 2026-08-14 metal round
           could not tell "the prompt never fired" from "the prompt fired
           and macOS suppressed it", because the change that added the
           prompt logged nothing at all about the decision — 31 lines
           naming the missing permission and not one naming what was done
           about it. A decision this cheap to record must never be
           unreadable again. */
        if accessibility.isProcessTrusted() {
            audit(.info, "Accessibility is already granted; host input "
                + "capture needs no permission request")
        } else if hasPromptedForAccessibilityThisLaunch {
            audit(.info, "Accessibility is still missing, but this launch "
                + "has already asked; not re-showing the system prompt. "
                + "Use Open Accessibility Settings on the Continuity page")
        } else {
            hasPromptedForAccessibilityThisLaunch = true
            /* macOS shows this dialog only while TCC holds no decision
               record for this bundle id. An app that has been granted and
               reset even once never sees it again, and the call returns in
               silence — so the audit says ASKED, never SHOWN, and the page
               offers the Settings link regardless. */
            audit(.info, "Accessibility is missing; asking macOS for it "
                + "(the system dialog appears only if macOS holds no "
                + "earlier decision for this app)")
            accessibility.promptForTrust()
            audit(.info, "asked macOS for Accessibility; still trusted="
                + "\(accessibility.isProcessTrusted())")
        }
        edgeModeActive = true
        maintainsOptInAfterGuestExit = true
        isEnabled = true
        edge.start()
    }

    func endEdgeMode(reason: String) {
        guard edgeModeActive else { return }
        edgeModeActive = false
        edge.stop(reason: reason)
        maintainsOptInAfterGuestExit = false
        isEnabled = mirrorCursorActive
    }

    /// The app came back to the foreground. If host input capture is
    /// currently sitting out because it lacked Accessibility permission,
    /// and that permission has since been granted in System Settings, pick
    /// the tap back up without waiting for the next edge crossing — the
    /// person should not have to toggle Continuity off and on to collect
    /// what they just granted.
    func applicationDidBecomeActive() {
        edge.retryInputCaptureAfterBecomingActive()
    }

    /// The affordance that always works. `promptForTrust` is a one-shot
    /// macOS may already have spent — on this project's own Mac it has,
    /// across eleven builds in a day — so the Continuity page carries an
    /// explicit control that opens the Accessibility pane, and it is this.
    /// Unlike the prompt it has no TCC state behind it and cannot be
    /// silently declined.
    func openAccessibilitySettings() {
        audit(.info, "opening System Settings at the Accessibility pane at "
            + "the person's request; trusted="
            + "\(accessibility.isProcessTrusted())")
        accessibility.openAccessibilitySettings()
    }

    func setMirrorCursorActive(_ active: Bool) {
        guard mirrorCursorActive != active else { return }
        mirrorCursorActive = active
        guard !edgeModeActive else { return }
        isEnabled = active
    }

    /// Whether any Mac is currently addressable for pointer control - the
    /// module page's enablement fact, distinct from `isEnabled` (a request)
    /// and `phase` (the live session).
    var hasConnectedTarget: Bool {
        listener.activeContinuityTarget != nil
    }
    @Published private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChanged?(phase)
        }
    }
    @Published private(set) var status = "off"
    @Published var requestedHz = 30 {
        didSet {
            guard requestedHz != oldValue else { return }
            guard [15, 30, 60].contains(requestedHz) else {
                requestedHz = 30
                return
            }
            if !loadingSettings,
               let machine = listener.activeContinuityTarget?.key.machine {
                defaults.set(requestedHz, forKey: rateKey(for: machine))
            }
            if phase != .idle {
                rearmAfterConfigurationChange(reason: "rate changed")
            }
        }
    }
    @Published var autoReconnect = false {
        didSet {
            guard autoReconnect != oldValue, !loadingSettings,
                  let machine = listener.activeContinuityTarget?.key.machine
            else { return }
            defaults.set(autoReconnect, forKey: reconnectKey(for: machine))
        }
    }
    @Published var fastPump = ContinuityOptionCatalog
        .descriptor(.fastPump).defaultEnabled {
        didSet {
            optionDidChange(.fastPump, from: oldValue, to: fastPump)
        }
    }
    @Published var settleSyntheticDevice = ContinuityOptionCatalog
        .descriptor(.settleSyntheticDevice).defaultEnabled {
        didSet {
            optionDidChange(.settleSyntheticDevice, from: oldValue,
                            to: settleSyntheticDevice)
        }
    }
    /* Default on: cooperative scheduling can stretch manager click timing.
       The measurement history lives in docs/continuity-mode.md. */
    @Published var wideDoubleTime = ContinuityOptionCatalog
        .descriptor(.wideDoubleTime).defaultEnabled {
        didSet {
            optionDidChange(.wideDoubleTime, from: oldValue,
                            to: wideDoubleTime)
        }
    }
    /* Default on: Finder also pairs clicks against private timing state, so
       the resident compresses synthetic `when`s at the jGNE boundary. See
       docs/continuity-mode.md for the measurements behind this mechanism. */
    @Published var compressClickWhen = ContinuityOptionCatalog
        .descriptor(.compressClickWhen).defaultEnabled {
        didSet {
            optionDidChange(.compressClickWhen, from: oldValue,
                            to: compressClickWhen)
        }
    }
    /* Default on: the resident's
       interrupt timer delivers a deferred second press itself, because the
       Finder pairs clicks by its own clock at processing time and no
       task-time route can reach the queue while it processes click one. */
    @Published var interruptPress = ContinuityOptionCatalog
        .descriptor(.interruptPress).defaultEnabled {
        didSet {
            optionDidChange(.interruptPress, from: oldValue,
                            to: interruptPress)
        }
    }
    /* Diagnostic spike, default off, logging only: the resident records
       every mouse event at the jGNE boundary with the click-relevant
       low-memory state beside it, latched past epoch exit so native
       comparison clicks land in the same uploadable log. */
    @Published var deepClickLog = ContinuityOptionCatalog
        .descriptor(.deepClickLog).defaultEnabled {
        didSet {
            optionDidChange(.deepClickLog, from: oldValue, to: deepClickLog)
        }
    }
    /* Default on: extend the settle machinery to idle motion so a
       starved pump's frames are drawn from whichever process holds the CPU. */
    @Published var settleIdleCursor = ContinuityOptionCatalog
        .descriptor(.settleIdleCursor).defaultEnabled {
        didSet {
            optionDidChange(.settleIdleCursor, from: oldValue,
                            to: settleIdleCursor)
        }
    }
    @Published var keyboardForwardingEnabled = true {
        didSet {
            guard keyboardForwardingEnabled != oldValue, !loadingSettings,
                  let machine = listener.activeContinuityTarget?.key.machine
            else { return }
            defaults.set(keyboardForwardingEnabled,
                         forKey: keyboardForwardingKey(for: machine))
            if phase == .active { edge.keyboardConfigurationChanged() }
        }
    }
    @Published var escapeShortcut = ContinuityEscapeShortcut.controlOptionEscape {
        didSet {
            guard escapeShortcut != oldValue, !loadingSettings,
                  let machine = listener.activeContinuityTarget?.key.machine
            else { return }
            defaults.set(escapeShortcut.rawValue,
                         forKey: escapeShortcutKey(for: machine))
            if phase == .active { edge.keyboardConfigurationChanged() }
        }
    }
    /* Bounceback recovery delay: how long scheduleReconnect waits before
       re-arming after the pointer returns to the host. Purely a host-side
       timing knob, so unlike the toggles above it never needs to interrupt
       an in-progress epoch on change. */
    @Published var reconnectDelay = 0.75 {
        didSet {
            guard reconnectDelay != oldValue else { return }
            if !loadingSettings,
               let machine = listener.activeContinuityTarget?.key.machine {
                defaults.set(reconnectDelay,
                             forKey: reconnectDelayKey(for: machine))
            }
        }
    }

    /// Bridges to `edge.edgeGeometry`, persisting per machine like the other
    /// Continuity prefs. Two setters rather than a mirrored `@Published`
    /// pair here, because the geometry itself has to live on the edge
    /// controller — it reaches the live catch surface immediately, the way
    /// `edge.updateEdgeGeometry` is written to — and this is the settings
    /// funnel around it, the same shape as `keyboardConfigurationChanged`
    /// pushing a toggle INTO `edge` rather than `edge` owning its own copy.
    func setEdgeEntryInset(_ pixels: CGFloat) {
        var geometry = edge.edgeGeometry
        geometry.entryInsetPixels = pixels
        applyEdgeGeometry(geometry)
    }

    func setEdgeDeadzoneDepth(_ pixels: CGFloat) {
        var geometry = edge.edgeGeometry
        geometry.deadzoneDepth = pixels
        applyEdgeGeometry(geometry)
    }

    private func applyEdgeGeometry(_ geometry: ContinuityEdgeGeometry) {
        edge.updateEdgeGeometry(geometry)
        guard let machine = listener.activeContinuityTarget?.key.machine
        else { return }
        // Persist what was actually APPLIED, not what was asked for —
        // `updateEdgeGeometry` clamps, and a value on disk that the
        // controller itself would refuse on the next launch is a silent
        // drift the same way an un-derived count is.
        defaults.set(edge.edgeGeometry.entryInsetPixels,
                     forKey: edgeEntryInsetKey(for: machine))
        defaults.set(edge.edgeGeometry.deadzoneDepth,
                     forKey: edgeDeadzoneDepthKey(for: machine))
    }

    private func edgeEntryInsetKey(for machine: GuestID) -> String {
        "mirror.continuity.edgeEntryInset.\(machine.slug)"
    }

    private func edgeDeadzoneDepthKey(for machine: GuestID) -> String {
        "mirror.continuity.edgeDeadzoneDepth.\(machine.slug)"
    }

    var isActive: Bool { phase == .active }
    @Published private(set) var isMenuTracking = false

    let layout: ContinuityDisplayLayout
    /// Continuity Mode keeps listening at the configured host edge after
    /// physical guest input ends one ownership epoch. Mirror Cursor retains
    /// its older opt-in behavior and turns itself off unless reconnect was
    /// explicitly requested.
    var maintainsOptInAfterGuestExit = false

    private(set) lazy var edge: ContinuityEdgeController = {
        /* The real event tap is named HERE and nowhere else. The
           controller's own default is inert by design, so this line is the
           whole of the running app's claim on the keyboard;
           `ContinuityEventTapOwnershipTests` fails if it goes missing. */
        let edge = ContinuityEdgeController(
            layout: layout, driver: self,
            keyboardEnvironment: AppKitContinuityKeyboardEnvironment(),
            accessibility: accessibility,
            runningCopy: runningCopy, audit: audit)
        onPhaseChanged = { [weak edge] phase in
            edge?.transportPhaseChanged(phase)
        }
        onOwnershipEnded = { [weak edge] reason in
            edge?.transportEnded(reason: reason)
        }
        return edge
    }()

    private let listener: GuestListener
    private let defaults: UserDefaults
    private let audit: Audit
    /// The guest's published Finder selection, scoped to the epoch that
    /// published it. Owned here because the epoch is owned here.
    private lazy var selectionCache = ContinuitySelectionCache(audit: audit)
    /// Test seam for the resident liveness answer. Production always reads the
    /// listener's exact one-machine match.
    var machineIsAnsweringOverride: ((GuestKey) -> Bool)?
    /// Longer than the resident's 1.5-second lease: one delayed ack does not
    /// churn ownership, but a dead receive path cannot leave the UI active.
    private let acknowledgementTimeout: TimeInterval
    private let starvationAnnounceAfter: TimeInterval
    /// The absolute cap on trusting resident liveness in place of the guest
    /// application's own acknowledgements. Resident liveness is a TCP
    /// connection, and a half-open one can answer "alive" long after the
    /// machine underneath it is not — the same dead-man concern this
    /// project already argues in docs/open-issues.md for other TCP-backed
    /// liveness reads. Minutes-scale rather than seconds-scale: it must
    /// outlast any ordinary held menu or modal a person is expected to
    /// leave open, and exist only as the backstop for the case that
    /// evidence is lying, not as a patience budget a real gesture can spend.
    private let starvationBackstop: TimeInterval
    private weak var localNetworkAccess: LocalNetworkAccessController?
    private let accessibility: AccessibilityAuthorization
    private let runningCopy: RunningCopy
    /// Whether `beginEdgeMode` has already asked macOS's Accessibility
    /// dialog this launch. Instance-scoped rather than a global: this
    /// controller is constructed once per app launch by `HostAppState`, and
    /// a test that wants a second "launch" constructs a second controller.
    private var hasPromptedForAccessibilityThisLaunch = false
    private var target: GuestListener.ContinuityTarget?
    private var armID: Int?
    private var nonceHi: UInt32 = 0
    private var nonceLo: UInt32 = 0
    private var epoch: UInt32 = 0
    private var positionSequence: UInt32 = 0
    private var point = MirrorKit.Point(x: 0, y: 0)
    private var positionDirty = false
    private var buttonGeneration: UInt32 = 0
    private var previousButtonGeneration: UInt32 = 0
    private var previousButtonDown = false
    private var keyGeneration: UInt32 = 0
    /// The modifier word the guest was last told about, used to suppress the
    /// flagsChanged repeats the classic word cannot distinguish. Epoch-scoped
    /// with `keyGeneration`: a new epoch's guest holds nothing, so a stale
    /// baseline here would swallow the first real change of the next session.
    private var lastForwardedModifiers: UInt16 = 0
    private var buttonCycleActive = false
    private var wireButtonDown = false
    /// **The button as a LEVEL, held for the life of a staged carry, with no
    /// generation behind it.**
    ///
    /// One bit in the datagram serves two consumers with different
    /// semantics, and that is the whole of defect B (F2 forensics,
    /// 2026-08-17). The guest's Drag Manager input proc reads the LEVEL —
    /// `flags & primaryDown` — every time the Manager samples it, and a
    /// `TrackDrag` whose first sample reads button-UP returns at once, which
    /// is the drag that dropped at the entry point on metal. The resident
    /// applies a press only on a NEWER `button_generation`
    /// (`now_continuity_logic.c:47-49`), so a level raised without touching
    /// `buttonGeneration` reaches the input proc and reaches nothing else:
    /// no Event Manager click is posted on the guest, and the D5 suppression
    /// that stopped forwarded presses opening Classilla stays exactly as it
    /// is.
    ///
    /// It is deliberately NOT `wireButtonDown`. That field is the click
    /// cycle's own state — acknowledgement, timeout, deferred point, epoch
    /// teardown all hang off it — and a carry has none of those; it has one
    /// question, "is the person still holding the file", answered by the
    /// edge controller's carry lifecycle.
    private var carriedButtonLevel = false
    private var pressAcknowledged = false
    private var deferredButtonPoint: MirrorKit.Point?
    /// The point the last `settleHeldPosition` asked for, held only until the
    /// release that follows it consumes it. See `settledReleasePoint`.
    private var heldSettlePoint: MirrorKit.Point?
    /// Set when a release went out carrying the point a settle had just
    /// asked for — i.e. the cross-edge handback's settle-then-release pair
    /// completed on the wire. Consumed by the epoch teardown, which must not
    /// step on it. See `pointerLeft`.
    private var settledReleasePoint: MirrorKit.Point?
    private var primaryDownInMenuBar = false
    private var primaryCycleDragged = false
    private var menuLatched = false
    private var menuReleaseArmed = false
    private var pointerInside = false
    private var udp: NWConnection?
    /* Network.framework may spend time preparing a physical interface while
       the main actor is also reconciling Mirror scenes. The UDP state machine
       therefore owns a serial queue, and its ready callback puts the first
       state on the wire before handing presentation back to the main actor. */
    private let udpQueue = DispatchQueue(
        label: "dev.newoldworld.mirror.continuity.udp")
    private lazy var keepaliveClock = ContinuityKeepaliveClock(queue: udpQueue)
    private var timer: DispatchSourceTimer?
    private var armTimeout: Task<Void, Never>?
    private var buttonAckTimeout: Task<Void, Never>?
    private var permissionRetry: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var waitingForLocalNetworkAccess = false
    private var permissionRetryCount = 0
    private var suppressEnabledObserver = false
    private var loadingSettings = false
    private var acceptedHz = 30
    private var sentDatagrams: UInt32 = 0
    private var validAcks: UInt32 = 0
    private var lastAcknowledgementUptime: TimeInterval?
    private var acknowledgementStarvedSince: TimeInterval?
    /// One announcement per starvation episode. The status line changes at
    /// `acknowledgementTimeout`, which is short enough that an ordinary
    /// tracking loop trips it; this is the second, louder tier, and it
    /// escalates only once so a two-minute modal is one notification.
    private var starvationAnnounced = false
    /// The silence value at which the "tolerated" audit line last fired,
    /// so an extended hold is narrated periodically — one line per
    /// additional `acknowledgementTimeout` of patience spent — rather than
    /// once at onset (already covered by the line above) or once per timer
    /// tick, which at 60 Hz would flood the log with the same fact.
    private var toleratedSilenceLogMark: TimeInterval = 0
    /// Told once, at `starvationAnnounceAfter`, that this Mac has stopped
    /// answering while the machine underneath it is still alive. Wired to
    /// the same notification-plus-flash seam as a drag refusal, because the
    /// person is looking at their Mac and not at this page.
    var onStarvation: ((String) -> Void)?
    private var lastAuditedButtonGeneration: UInt32 = 0
    private var lastPrimaryDownUptime: TimeInterval?
    private var buttonTransitionSentUptime: TimeInterval?
    private var buttonTransitionSourceUptime: TimeInterval?
    private var onPhaseChanged: ((Phase) -> Void)?
    private var onOwnershipEnded: ((String) -> Void)?

    init(listener: GuestListener,
         defaults: UserDefaults = ProductIdentity.defaults,
         localNetworkAccess: LocalNetworkAccessController? = nil,
         accessibility: AccessibilityAuthorization? = nil,
         runningCopy: RunningCopy = .current,
         acknowledgementTimeout: TimeInterval = 3,
         starvationAnnounceAfter: TimeInterval = 10,
         starvationBackstop: TimeInterval = 300,
         audit: Audit? = nil) {
        let resolvedAudit = audit ?? {
            HostLog.shared.write($0, "continuity", $1)
        }
        self.listener = listener
        self.defaults = defaults
        self.layout = ContinuityDisplayLayout(defaults: defaults,
                                              audit: resolvedAudit)
        self.localNetworkAccess = localNetworkAccess
        self.accessibility = accessibility ?? SystemAccessibilityAuthorization()
        self.runningCopy = runningCopy
        self.acknowledgementTimeout = acknowledgementTimeout
        self.starvationAnnounceAfter = starvationAnnounceAfter
        self.starvationBackstop = starvationBackstop
        self.audit = resolvedAudit
        localNetworkAccess?.onDirectAccessReady = { [weak self] in
            self?.localNetworkAccessBecameReady()
        }
        listener.onContinuityReport = { [weak self] key, report in
            self?.received(report, from: key)
        }
        listener.onContinuityKeyReport = { [weak self] key, report in
            self?.received(report, from: key)
        }
        listener.onContinuitySelection = { [weak self] key, selection in
            self?.received(selection, from: key)
        }
        listener.onContinuityDragBegin = { [weak self] key, begin in
            self?.received(begin, from: key)
        }
        loadSettingsForActiveGuest()
    }

    func pointerMoved(to point: MirrorKit.Point) {
        pointerInside = true
        self.point = point
        positionDirty = true
        guard isEnabled else { return }
        switch phase {
        case .idle: arm()
        case .arming: break
        case .active: break
        }
    }

    /// THE EPOCH-ENDING DATAGRAM IS WITHHELD AFTER A SETTLED RELEASE, AND
    /// THAT IS THE WHOLE OF IT.
    ///
    /// The wire is a latest-state mailbox and the guest reads ONE snapshot of
    /// it per pass, so three datagrams sent inside a millisecond are one
    /// snapshot to an application starved inside the Finder's drag-tracking
    /// loop. On the cross-edge handback the host sends exactly three: the
    /// settle to the press origin, the release carrying that same origin, and
    /// then this one — and this one clears `inside`, which both the resident's
    /// timer task and the application's service honour BEFORE they take the
    /// snapshot's position. The settled origin is thrown away with it, the
    /// release is applied against whatever mid-drag point the guest last
    /// ingested, and the Finder completes a real move to the screen edge.
    ///
    /// Metal, 2026-08-15: origin=522,199 was commanded and logged by this
    /// side; the guest settled at 792,231 — one drag sample short of the
    /// 802,231 cross — and again 524,203 against 799,232. Slow drags only,
    /// because a slow drag is exactly the one where the guest application is
    /// deep enough in the Finder's loop to collapse the three into one.
    ///
    /// Withholding it costs nothing: `relinquish` ends the epoch over the
    /// RELIABLE control stream in the next statement, and the resident's own
    /// lease bounds the gap. What it buys is that the last datagram the guest
    /// can possibly see carries the settled origin beside the release edge —
    /// which is precisely the shape the fast path already had, by accident,
    /// because an unacknowledged press sends no separate settle at all.
    func pointerLeft() {
        pointerInside = false
        guard phase != .idle else { return }
        if phase == .active {
            if let settled = settledReleasePoint {
                settledReleasePoint = nil
                audit(.info, "epoch-ending datagram withheld: the release "
                    + "settled at \(settled.x),\(settled.y) and clearing "
                    + "`inside` in the next packet would let a starved guest "
                    + "drop that point; the reliable disarm ends the epoch")
            } else {
                sendState(inside: false, keepalive: false)
            }
        }
        relinquish(reason: "pointer left Mirror", keepEnabled: true)
    }

    func keyboardEvent(_ sample: HostKeySample) -> Bool {
        guard phase == .active, sample.code <= 127 else { return false }
        /* A modifier message is state, so an unchanged word says nothing the
           guest does not already hold. macOS raises flagsChanged for keys the
           classic word has no bit for — Fn, the numeric-pad flag, left versus
           right of the same modifier — and forwarding those would put a
           packet on the reliable stream for every one of them. Dropping a
           repeat is safe precisely because the payload is absolute: the next
           real change carries the whole word again. */
        if sample.action == .modifiers {
            guard sample.modifiers != lastForwardedModifiers else {
                audit(.info, "modifier change not forwarded, word unchanged: "
                    + "modifiers=0x\(String(sample.modifiers, radix: 16))")
                return true
            }
            audit(.info, "modifier state forwarded: "
                + "was=0x\(String(lastForwardedModifiers, radix: 16)), "
                + "now=0x\(String(sample.modifiers, radix: 16))")
        }
        lastForwardedModifiers = sample.modifiers
        keyGeneration = nextNonzero(keyGeneration)
        guard listener.sendContinuityKey(
            epoch: epoch, generation: keyGeneration,
            action: sample.action, code: sample.code,
            character: sample.character, modifiers: sample.modifiers) != nil
        else {
            audit(.error, "keyboard event lost because the guest session ended")
            return false
        }
        audit(.info, "keyboard event queued: generation=\(keyGeneration), "
            + "action=\(sample.action), code=\(sample.code), "
            + "modifiers=0x\(String(sample.modifiers, radix: 16))")
        return true
    }

    @discardableResult
    func primaryDown(at point: MirrorKit.Point,
                     inMenuBar: Bool = false) -> Bool {
        primaryDown(at: point, inMenuBar: inMenuBar,
                    sourceUptime: nil)
    }

    @discardableResult
    func primaryDown(at point: MirrorKit.Point, inMenuBar: Bool,
                     sourceUptime: TimeInterval?) -> Bool {
        guard phase == .active else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let eventUptime = sourceUptime ?? now
        if let lastPrimaryDownUptime {
            audit(.info, String(
                format: "primary down source interval %.1f ms, deliveryAge=%.1f ms",
                (eventUptime - lastPrimaryDownUptime) * 1_000,
                max(0, now - eventUptime) * 1_000))
        }
        lastPrimaryDownUptime = eventUptime
        if menuLatched, buttonCycleActive, wireButtonDown {
            self.point = point
            positionDirty = true
            deferredButtonPoint = point
            menuReleaseArmed = true
            return true
        }
        /* The host streams edges; it does not classify clicks. The v4 packet
           carries the preceding edge beside the current one, while guest
           timing owns recognition. See docs/continuity-mode.md. */
        if buttonCycleActive, wireButtonDown {
            audit(.warn, "ignored primary down while button is held")
            return true
        }
        beginPrimaryCycle(at: point, inMenuBar: inMenuBar,
                          sourceUptime: eventUptime)
        return true
    }

    private func beginPrimaryCycle(at point: MirrorKit.Point,
                                   releasedAt: MirrorKit.Point? = nil,
                                   inMenuBar: Bool = false,
                                   sourceUptime: TimeInterval? = nil) {
        self.point = point
        positionDirty = true
        advancePositionIfNeeded()
        advanceButton(to: true)
        buttonCycleActive = true
        pressAcknowledged = false
        deferredButtonPoint = releasedAt
        heldSettlePoint = nil
        settledReleasePoint = nil
        primaryDownInMenuBar = inMenuBar
        primaryCycleDragged = false
        menuLatched = false
        menuReleaseArmed = false
        isMenuTracking = inMenuBar
        let sendUptime = ProcessInfo.processInfo.systemUptime
        let source = sourceUptime ?? sendUptime
        sendState(inside: true, keepalive: false)
        audit(.info, String(
            format: "primary down sent: generation=%u, clickPoint=%d,%d, menu=%d, hostSourceMs=%.1f, hostSendMs=%.1f, sourceToSendMs=%.1f",
            buttonGeneration, point.x, point.y, inMenuBar ? 1 : 0,
            source * 1_000, sendUptime * 1_000,
            max(0, sendUptime - source) * 1_000))
        buttonTransitionSourceUptime = source
        buttonTransitionSentUptime = sendUptime
        scheduleButtonAckTimeout(generation: buttonGeneration, down: true)
    }

    @discardableResult
    func primaryDragged(to point: MirrorKit.Point) -> Bool {
        guard phase == .active else { return false }
        guard buttonCycleActive else { return false }
        if !primaryCycleDragged {
            audit(.info, "primary drag began: generation=\(buttonGeneration), "
                + "from=\(self.point.x),\(self.point.y), "
                + "to=\(point.x),\(point.y)")
        }
        primaryCycleDragged = true
        if pressAcknowledged {
            self.point = point
            positionDirty = true
        } else {
            /* Keep the press point stable until the guest confirms its down
               event. The newest held point is sent immediately afterwards. */
            deferredButtonPoint = point
        }
        return true
    }

    /// Sends the held pointer's position NOW, in a packet carrying no button
    /// change, so whatever the caller sends next is a separate wire fact.
    ///
    /// The cross-edge file handoff is the caller this exists for. It returns
    /// the guest pointer to the press origin and then releases; if both rode
    /// one packet the guest could apply the release first and complete the
    /// Finder's move at the shared edge — cosmetic on the desktop, a real
    /// relocation out of a Finder window (metal, 2026-08-14).
    @discardableResult
    func settleHeldPosition(to point: MirrorKit.Point) -> Bool {
        guard phase == .active, buttonCycleActive else { return false }
        primaryDragged(to: point)
        /* Armed on BOTH returns: the deferred path below is the one that
           already worked on metal, and the teardown must treat the two
           identically or the guard only covers the case it was written
           against. See `pointerLeft`. */
        heldSettlePoint = point
        guard pressAcknowledged else {
            /* The press point is deliberately stable until the guest
               confirms its down; `primaryDragged` has parked the origin in
               the deferred slot and the release below carries it. */
            return true
        }
        advancePositionIfNeeded()
        sendState(inside: true, keepalive: false)
        audit(.info, "held position settled before release: "
            + "\(point.x),\(point.y)")
        return true
    }

    @discardableResult
    func primaryUp(at point: MirrorKit.Point) -> Bool {
        guard phase == .active else { return false }
        guard buttonCycleActive else { return false }
        if menuLatched {
            guard menuReleaseArmed else { return true }
            menuLatched = false
            menuReleaseArmed = false
        } else if primaryDownInMenuBar && !primaryCycleDragged {
            /* The raw CDM path otherwise falls back to System 6/7-style
               hold-to-track behavior on this Mac OS 8/9 guest. Keep the
               native tracking loop alive after a stationary host click so
               the next click can select, matching the guest OS's click-open
               model. A real click-drag-release never enters this latch. */
            deferredButtonPoint = point
            menuLatched = true
            return true
        }
        isMenuTracking = false
        deferredButtonPoint = point
        /* The release streams immediately: the wire's previous/current pair
           carries it beside an unacknowledged down, and the resident's
           interrupt-time release path reads both slots. Holding it for the
           press acknowledgement serialized cycles against guest scheduling
           and is what a starved target turned into held drags. */
        sendPrimaryRelease()
        return true
    }

    /// **Raise or clear the carried button LEVEL. It mints no generation,
    /// and that is the entire mechanism.**
    ///
    /// Defect B, attended metal 2026-08-17: a host→guest carry suppresses
    /// every `.primaryDown` for the life of the staging (the D5 fix, which
    /// must stay), so `wireButtonDown` never became true, the datagram never
    /// carried `.primaryDown`, and the guest's `TrackDrag` first-sampled a
    /// released button and returned at the entry point. This is the button
    /// the drag needs and the press the guest must never receive, told
    /// apart: the level goes on the wire, `buttonGeneration` does not move,
    /// so `now_continuity_button_action` answers `Nothing` and the resident
    /// posts no click.
    ///
    /// Returns whether the level is on the wire — false while there is no
    /// active epoch to carry it, which the caller reports rather than
    /// assumes. The field is still set: an epoch armed later sends it with
    /// the next datagram, and `clearTransportState` drops it with the epoch.
    @discardableResult
    func setCarriedButtonLevel(_ held: Bool, gesture: UInt64,
                               reason: String) -> Bool {
        guard carriedButtonLevel != held else { return phase == .active }
        carriedButtonLevel = held
        let live = phase == .active
        audit(live ? .info : .warn,
              "carried button level \(held ? "RAISED" : "cleared"): "
                + "\(reason) (gesture=\(gesture), "
                + "generation=\(buttonGeneration) — NOT advanced, so the "
                + "Macintosh's resident applies nothing and only the drag's "
                + "input proc reads this)"
                + (live ? "" : "; no epoch is active, so nothing is on the "
                   + "wire yet"))
        guard live else { return false }
        sendState(inside: true, keepalive: false)
        return true
    }

    func cancel(reason: String) {
        pointerInside = false
        relinquish(reason: reason, keepEnabled: true)
    }

    /// Called while the outgoing guest is still authoritative, so its epoch
    /// can be explicitly retired before the listener changes focus.
    func sessionWillEnd(reason: String) {
        relinquish(reason: reason, keepEnabled: false)
        setEnabledWithoutTeardown(false)
    }

    /// A disconnect has no peer left to answer, and a focus switch must never
    /// send the old epoch's disarm to the newly selected guest.
    func sessionDidChange() {
        clearTransportState()
        setEnabledWithoutTeardown(false)
        status = "off"
        pointerInside = false
        loadSettingsForActiveGuest()
    }

    private func arm(permissionRetry: Bool = false) {
        if !permissionRetry { permissionRetryCount = 0 }
        guard let target = listener.activeContinuityTarget else {
            status = "unavailable: no Mac is connected"
            return
        }
        let rate = [15, 30, 60].contains(requestedHz) ? requestedHz : 30
        requestedHz = rate
        epoch = nextNonzero(epoch)
        /* A NEW EPOCH ENDS THE LAST ONE'S AFTERLIFE. The window a crossing
           gesture's generation may arrive in is one epoch wide; a record
           kept past the next arm would let a frame from a finished session
           reach a crossing made under this one. */
        endedEpoch = nil
        repeat {
            nonceHi = UInt32.random(in: UInt32.min ... UInt32.max)
            nonceLo = UInt32.random(in: UInt32.min ... UInt32.max)
        } while nonceHi == 0 && nonceLo == 0
        self.target = target
        var armOptions = ContinuityArmOptions()
        for option in ContinuityOptionCatalog.all {
            armOptions[option.id] = self[keyPath: option.keyPath]
        }
        armID = listener.armContinuity(
            nonceHi: nonceHi, nonceLo: nonceLo, epoch: epoch,
            requestedHz: rate, leaseTicks: 90, options: armOptions)
        guard armID != nil else {
            status = "unavailable: no Mac is connected"
            self.target = nil
            return
        }
        audit(.info, "arm requested: epoch=\(epoch), id=\(armID!), "
            + "rate=\(rate) Hz, guest=\(target.key.machine.slug)")
        phase = .arming
        status = "asking the Mac for pointer control…"
        let armedEpoch = epoch
        armTimeout?.cancel()
        armTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled,
                  self.phase == .arming, self.epoch == armedEpoch else {
                return
            }
            if self.maintainsOptInAfterGuestExit {
                self.relinquish(reason: "arm timed out", keepEnabled: true)
                self.status = "The Mac is busy in another interaction and did "
                    + "not schedule its pointer service. Dismiss any alert, "
                    + "then cross the shared edge again."
            } else {
                self.relinquish(reason: "arm timed out", keepEnabled: false)
                self.setEnabledWithoutTeardown(false)
                self.status = "Continuity is unavailable"
            }
        }
    }

    private func received(_ report: ContinuityReport, from key: GuestKey) {
        guard target?.key == key, report.epoch == epoch else {
            audit(.warn, "ignored control report: state=\(report.state), "
                + "reason=\(report.reason ?? "none"), epoch=\(report.epoch), "
                + "expectedEpoch=\(epoch), guest=\(key.machine.slug)")
            return
        }
        audit(.info, "control report: id=\(report.id.map(String.init) ?? "none"), "
            + "epoch=\(report.epoch), state=\(report.state), "
            + "reason=\(report.reason ?? "none"), "
            + "accepted=\(report.acceptedPackets ?? 0), "
            + "stale=\(report.stalePackets ?? 0), "
            + "malformed=\(report.malformedPackets ?? 0), "
            + "appliedPosition=\(report.appliedPositionSequence ?? 0), "
            + "appliedButton=\(report.appliedButtonGeneration ?? 0)")
        guard report.version == ContinuityContract.version else {
            guestEnded(reason: report.version == nil
                ? "the guest is missing Continuity control version "
                    + "\(ContinuityContract.version)"
                : "the guest reported Continuity control version "
                    + "\(report.version!), expected "
                    + "\(ContinuityContract.version)", retryable: false)
            return
        }
        /* The pointer plane's own screen answer. Continuity maps the shared
           edge with this; before the report carried it, the only source was
           Mirror's decoded scene, which required Mirror to have run first. */
        if let width = report.screenWidth, let height = report.screenHeight,
           width > 0, height > 0 {
            layout.updateGuestSize(CGSize(width: width, height: height))
        }
        if report.id == armID {
            guard report.state == "armed", let port = report.udpPort,
                  port > 0, port <= Int(UInt16.max) else {
                guestEnded(reason: reportDescription(report),
                           retryable: isRetryable(report.reason),
                           retryImmediately: report.reason != "guest-input")
                return
            }
            acceptedHz = [15, 30, 60].contains(report.acceptedHz ?? 0)
                ? report.acceptedHz! : requestedHz
            openUDP(host: target!.host, port: UInt16(port))
            return
        }
        /* A control reply is pending, so an uncorrelated terminal snapshot
           cannot settle this epoch. Older guests can publish the preceding
           exit after writing the new epoch but before P9 observes the arm;
           the correlated arm reply that follows is authoritative. */
        if phase == .arming, report.id == nil { return }
        if report.id == nil,
           report.state == "exited" || report.state == "refused" {
            guestEnded(reason: reportDescription(report),
                       retryable: isRetryable(report.reason),
                       retryImmediately: report.reason != "guest-input")
        }
    }

    private func received(_ report: ContinuityKeyReport, from key: GuestKey) {
        guard target?.key == key, report.epoch == epoch else { return }
        guard report.version == ContinuityContract.version else {
            audit(.error, "keyboard report version mismatch: "
                + "\(report.version.map(String.init) ?? "missing")")
            return
        }
        if report.state != .queued {
            audit(.warn, "keyboard event refused: generation="
                + "\(report.generation), reason="
                + "\(report.reason?.rawValue ?? "unknown")")
            status = "Keyboard input was refused: "
                + (report.reason?.rawValue ?? "unknown reason")
        }
    }

    /// The drag this Mac was told about while the button was still down, or
    /// nil once the application's own frame has caught up with it.
    ///
    /// It is the JOIN KEY and nothing else: the resident names a file, the
    /// application later names the same file WITH A GENERATION, and this is
    /// how the two are known to be one gesture rather than two drags of the
    /// same icon. Cleared when the join lands, so a second drag of the same
    /// file cannot be joined to the first one's announcement.
    private var announcedDragSeq: UInt32?

    /// THE RESIDENT NAMING THE FILE MID-GESTURE.
    ///
    /// This is the arrival the whole drag plane was built to get: the
    /// application publishes the same identity, but not until the Finder's
    /// drag loop releases it — 462 ticks after the drag began, measured
    /// 2026-08-16, which is after the crossing that needed it. This frame
    /// comes off the resident's own channel while the loop is still running.
    ///
    /// IT BINDS AN IDENTITY AND NOT A GENERATION. The stub is cached with
    /// generation 0, which every consumer reads as "no generation has been
    /// minted for this gesture yet": the guest mints generations, a
    /// `continuity.grab` names one, and the guest's own check refuses any
    /// number it did not mint. So a drop that somehow beats the
    /// application's frame is refused by name rather than served the wrong
    /// file — and the application's frame arrives in the same fifth of a
    /// second the crossing does, long before a human drop.
    private func received(_ begin: ContinuityDragBegin, from key: GuestKey) {
        guard target?.key == key else {
            audit(.warn, "drag begin ignored: it came from "
                + "\(key.machine.slug), which does not own this epoch")
            return
        }
        guard begin.epoch == epoch, epoch != 0 else {
            audit(.warn, "drag begin ignored: it names epoch "
                + "\(begin.epoch) while this Mac owns epoch \(epoch)")
            return
        }
        guard announcedDragSeq != begin.dragSeq else { return }
        announcedDragSeq = begin.dragSeq
        /* Folderness is UNKNOWN here and is recorded as false rather than
           guessed at: the resident makes no File Manager call, by charter,
           so nothing in this frame can say. A folder drag is refused when
           the application's own frame arrives and says `isFolder`, one
           gesture later — the slice folders were already deferred to. */
        let synthesised = ContinuitySelection(
            version: ContinuityContract.version,
            epoch: begin.epoch,
            generation: 0,
            source: .drag,
            dragSeq: begin.dragSeq,
            item: .init(name: begin.item.name,
                        volumeRef: begin.item.volumeRef,
                        dirID: begin.item.dirID,
                        fileType: begin.item.fileType,
                        creator: begin.item.creator,
                        dataSize: nil,
                        resourceSize: nil,
                        modifiedAt: nil,
                        isFolder: false,
                        icon: nil))
        audit(.info, "drag begin from the resident: dragSeq="
            + "\(begin.dragSeq), epoch=\(begin.epoch), "
            + "name=\(begin.item.name), "
            + "type=\(begin.item.fileType ?? "none"), "
            + "guestTicks=\(begin.ticks.map(String.init) ?? "none") — the "
            + "Mac is still holding this drag; the generation follows on "
            + "the application's own frame")
        selectionCache.apply(synthesised, activeEpoch: epoch)
        if let mark = selectionCache.mark {
            edge.noteSelectionPublished(mark)
        }
    }

    /// The epoch that ended most recently, and who owned it.
    ///
    /// One epoch's worth of memory, held for exactly one purpose: a gesture
    /// that CROSSED published its generation after the cross ended its
    /// epoch, and there is nothing else left by then that can say the frame
    /// belongs to this Mac's own last session.
    private struct EndedEpoch {
        var epoch: UInt32
        var key: GuestKey
        /// The gesture the resident announced mid-drag, if it announced
        /// one. Kept so the join is answerable after the epoch is gone.
        var dragSeq: UInt32?
    }
    private var endedEpoch: EndedEpoch?

    /// A GENERATION FOR AN EPOCH THAT IS OVER, which is the only kind a
    /// crossing single-gesture drag can ever produce.
    ///
    /// It is deliberately NOT run through `selectionCache.apply`: caching it
    /// would make a grab reachable under an epoch nobody is consenting in,
    /// which is the rule the cache's own epoch guard exists to hold. What it
    /// feeds instead is the crossing already in flight — the drop is holding
    /// for exactly this number — and it gets there by the same join the live
    /// case uses, `dragSeq`.
    private func receivedAfterEpoch(_ selection: ContinuitySelection,
                                    from key: GuestKey) {
        /* WHOSE it is stays here, because a GuestKey is this object's own
           notion of who it was talking to; WHETHER it may be used is pure
           and lives in ContinuityAfterEpochAdmission, where every refusal
           can be watched without a machine. */
        guard let ended = endedEpoch, ended.key == key else {
            audit(.warn, "selection after the epoch ignored: it came from "
                + "\(key.machine.slug), and this Mac's last epoch belonged "
                + "to \(endedEpoch.map { $0.key.machine.slug } ?? "nobody")")
            return
        }
        switch ContinuityAfterEpochAdmission.decide(selection,
                                                    lastEpoch: ended.epoch) {
        case .refused(let reason):
            audit(.warn, "selection after the epoch ignored: \(reason)")
        case .join(let stub):
            if let announced = ended.dragSeq,
               announced != stub.dragSeq {
                audit(.info, "drag \(stub.dragSeq.map(String.init) ?? "none") "
                    + "is not the drag this Mac was announced (\(announced)) "
                    + "before epoch \(ended.epoch) ended — the join below "
                    + "decides it, not this line")
            }
            audit(.info, "drag \(stub.dragSeq.map(String.init) ?? "none") "
                + "joined AFTER its epoch: epoch \(stub.epoch) ended at the "
                + "cross and the Mac minted generation \(stub.generation) "
                + "for \(stub.item.name) once its Finder let the application "
                + "run again")
            edge.noteSelectionPublishedAfterEpoch(stub)
        }
    }

    private func received(_ selection: ContinuitySelection, from key: GuestKey) {
        /* THE EPOCH THIS NAMES MAY ALREADY BE OVER, and on the gesture this
           whole plane exists for it always is. Routed before the ownership
           guard below, because that guard reads `target`, which the epoch's
           own ending cleared. */
        if selection.namesEndedEpoch {
            receivedAfterEpoch(selection, from: key)
            return
        }
        guard target?.key == key else {
            audit(.warn, "selection ignored: it came from "
                + "\(key.machine.slug), which does not own this epoch")
            return
        }
        /* THE JOIN, AND WHICH SOURCE WON, said out loud. Two senders
           reported one gesture; this is the second, and it carries the one
           thing the first could not — the generation a grab must name. The
           identity is expected to agree, and a disagreement is a finding
           rather than a preference, so it is logged as one. */
        if selection.resolvedSource == .drag, let seq = selection.dragSeq {
            if seq == announcedDragSeq {
                let announced = selectionCache.stub?.item.name
                announcedDragSeq = nil
                if let announced, announced != selection.item?.name {
                    audit(.warn, "drag \(seq) joined and DISAGREED: the "
                        + "resident named \(announced) mid-gesture and the "
                        + "application named "
                        + "\(selection.item?.name ?? "nothing") — the "
                        + "application's frame wins, because it carries the "
                        + "generation a grab must name")
                } else {
                    audit(.info, "drag \(seq) joined: the resident's "
                        + "mid-gesture identity keeps its name and gains "
                        + "generation \(selection.generation) from the "
                        + "application")
                }
            } else if let announced = announcedDragSeq {
                audit(.info, "drag \(seq) is not the drag this Mac was "
                    + "announced (\(announced)) — a second gesture, bound "
                    + "on its own")
                announcedDragSeq = nil
            }
        }
        selectionCache.apply(selection, activeEpoch: epoch)
        /* AND THE EDGE HEARS ABOUT IT EVEN IF IT ALREADY DECIDED. A
           drag-sourced generation cannot arrive before the crossing — the
           Finder's drag loop starves the guest of task time, and the
           crossing's own release is what ends that loop — so this arrival is
           routinely the FIRST thing this Mac learns about the file it is
           already carrying. The edge refuses it in every case but that one;
           see `noteSelectionPublished`. */
        if let mark = selectionCache.mark {
            edge.noteSelectionPublished(mark)
        }
    }

    /// What a press may be bound to right now, or the named reason it may
    /// not. The epoch is applied HERE rather than by the caller: it is this
    /// object's, and a consent scoped by somebody else's copy of it is the
    /// grant outliving its session.
    func bindableSelection()
        -> Result<ContinuityDragStub, ContinuitySelectionCache.Unusable> {
        selectionCache.bindable(activeEpoch: epoch)
    }

    /// Which selection this Mac currently holds and when it learned of it,
    /// for the cross-time bind decision. Deliberately NOT filtered by
    /// bindability: a folder or an other-epoch stub still marks a change,
    /// and hiding it here would make "the selection moved under this press"
    /// unanswerable in exactly the cases where it moved to something
    /// undraggable.
    var selectionMark: ContinuitySelectionMark? { selectionCache.mark }

    /// The live Continuity epoch, exposed for the one caller outside this
    /// object that must agree with it: a host→guest offer's epoch field.
    /// The guest's own offer table checks `table.epoch != live_epoch`
    /// (`now_continuity_offer.c`) — that live epoch is THIS number, not a
    /// namespace of the offer's own. Publishing under anything else (a
    /// constant, a separately-counted offer epoch) can only ever agree with
    /// the guest by coincidence, once, at epoch 1.
    var currentEpoch: UInt32 { epoch }

    private func openUDP(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            guestEnded(reason: "invalid UDP port", retryable: false)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: nwPort, using: .udp)
        udp = connection
        audit(.info, "opening UDP pointer lane to \(host):\(port)")
        advancePositionIfNeeded()
        let initialState = encodedState(inside: true, keepalive: false)
        let initialSequence = positionSequence
        status = "opening the pointer lane…"
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            /* This send deliberately precedes the actor hop. The resident's
               live-input lease does not start until it accepts this packet,
               and a busy Mirror main actor must not be able to consume the
               startup grace before the first state is even queued. */
            if case .ready = state, let connection {
                connection.send(content: initialState,
                                completion: .contentProcessed {
                    [weak self, weak connection] error in
                    Task { @MainActor in
                        guard let self, let connection,
                              connection === self.udp else { return }
                        if let error {
                            self.audit(.error, "initial UDP state failed: "
                                + "\(String(describing: error)); "
                                + "epoch=\(self.epoch), "
                                + "positionSequence=\(initialSequence)")
                            self.guestEnded(
                                reason: Self.pointerLaneFailure(error))
                        } else {
                            self.audit(.info, "initial UDP state queued: "
                                + "epoch=\(self.epoch), "
                                + "positionSequence=\(initialSequence)")
                        }
                    }
                })
            }
            Task { @MainActor in
                guard let self, let connection,
                      connection === self.udp else { return }
                switch state {
                case .ready:
                    self.waitingForLocalNetworkAccess = false
                    self.permissionRetry?.cancel()
                    self.permissionRetry = nil
                    self.sentDatagrams = 1
                    self.lastAcknowledgementUptime =
                        ProcessInfo.processInfo.systemUptime
                    self.audit(.info, "UDP pointer lane is ready")
                    self.localNetworkAccess?.directAccessBecameReady(
                        host: self.target?.host,
                        path: connection.currentPath.map(
                            String.init(describing:)))
                    self.armTimeout?.cancel()
                    self.armTimeout = nil
                    self.phase = .active
                    self.status = "direct pointer connected at "
                        + "\(self.acceptedHz) Hz"
                    self.keepaliveClock.start(
                        connection: connection,
                        payload: self.encodedState(
                            inside: true, keepalive: true))
                    self.startTimer()
                    self.receiveAck()
                case .failed(let error):
                    self.auditPointerLane("failed", error: error,
                                          connection: connection)
                    if case .posix(.ENETDOWN) = error {
                        self.pointerLaneWaitingForLocalNetworkAccess(
                            error: error, connection: connection)
                    } else {
                        self.guestEnded(reason: Self.pointerLaneFailure(error))
                    }
                case .waiting(let error):
                    self.auditPointerLane("waiting", error: error,
                                          connection: connection)
                    if case .posix(.ENETDOWN) = error {
                        self.pointerLaneWaitingForLocalNetworkAccess(
                            error: error, connection: connection)
                    } else {
                        self.status = Self.pointerLaneWaitingStatus(error)
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: udpQueue)
    }

    func pointerLaneWaitingForLocalNetworkAccess(
        error: NWError = .posix(.ENETDOWN), connection: NWConnection? = nil
    ) {
        waitingForLocalNetworkAccess = true
        armTimeout?.cancel()
        armTimeout = nil
        let host = target?.host ?? "the connected Mac"
        let path = connection?.currentPath.map(String.init(describing:))
            ?? "no current path"
        localNetworkAccess?.directAccessIsWaiting(
            host: host, error: error, path: path)
        status = Self.pointerLaneWaitingStatus(error)
        if localNetworkAccess?.directAccessReady == true {
            schedulePermissionRetry()
        }
    }

    func localNetworkAccessBecameReady() {
        guard waitingForLocalNetworkAccess else { return }
        schedulePermissionRetry()
    }

    private func schedulePermissionRetry() {
        guard permissionRetry == nil, permissionRetryCount < 2 else { return }
        permissionRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled,
                  self.waitingForLocalNetworkAccess, self.isEnabled else {
                return
            }
            self.permissionRetry = nil
            self.permissionRetryCount += 1
            self.relinquish(reason: "Local Network permission changed",
                            keepEnabled: true)
            self.positionDirty = true
            self.status = "Local Network access approved; reconnecting…"
            self.arm(permissionRetry: true)
        }
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.nanoseconds(
            1_000_000_000 / max(1, acceptedHz))
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.phase == .active else { return }
            if let last = self.lastAcknowledgementUptime,
               ProcessInfo.processInfo.systemUptime - last
                    > self.acknowledgementTimeout {
                let silence = ProcessInfo.processInfo.systemUptime - last
                if let key = self.target?.key,
                   self.machineIsAnsweringOverride?(key)
                    ?? self.listener.machineIsAnswering(sessionKey: key) {
                    if self.acknowledgementStarvedSince == nil {
                        self.acknowledgementStarvedSince = last
                        self.toleratedSilenceLogMark = 0
                        self.audit(.warn, String(
                            format: "guest application acknowledgements starved for %.1f s; resident liveness is still answering and the independent lease clock remains armed",
                            silence))
                        self.status = "The Mac is busy in another interaction; "
                            + "pointer safety remains armed"
                    }
                    /* Resident liveness is a TCP read, and a half-open
                       connection can keep answering "alive" long after the
                       machine underneath it stopped being reachable. Trust
                       it for the length of any real gesture, but not
                       forever: past the backstop this stops being patience
                       and becomes the dead-man fallback the seconds-scale
                       watchdog already was before liveness was consulted
                       at all. */
                    guard silence < self.starvationBackstop else {
                        self.audit(.error, String(
                            format: "ack silence %.1f s exceeded the %.0f s "
                                + "backstop despite resident liveness still "
                                + "answering; treating as dead rather than "
                                + "trusting a possibly half-open liveness "
                                + "channel indefinitely",
                            silence, self.starvationBackstop))
                        self.guestEnded(reason: "UDP acknowledgements "
                            + "stopped despite resident liveness "
                            + "(backstop exceeded)")
                        return
                    }
                    if silence - self.toleratedSilenceLogMark
                        >= self.acknowledgementTimeout {
                        self.toleratedSilenceLogMark = silence
                        self.audit(.info, String(
                            format: "ack silence %.1f s tolerated: resident "
                                + "liveness answering (starvation, not death)",
                            silence))
                    }
                    self.announceStarvationIfDue(silence: silence)
                } else {
                    self.guestEnded(reason: "UDP acknowledgements stopped")
                    return
                }
            }
            if self.positionDirty {
                self.advancePositionIfNeeded()
                self.sendState(inside: true, keepalive: false)
                return
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// THE SENTENCE, WRITTEN ONCE.
    ///
    /// What is actually known at this moment is narrow and worth stating
    /// precisely: the guest application has not acknowledged for `silence`
    /// seconds, and the resident — a Time Manager task that answers whether
    /// or not any application is scheduled — is still answering. So the Mac
    /// is running and NOW is not being given time, which under cooperative
    /// scheduling is what a modal alert in *another* application looks like
    /// from here. It is not the only thing that looks like it (a menu held
    /// down does too), which is why this waits ten seconds first and why the
    /// sentence describes rather than diagnoses.
    ///
    /// The second half is the part a person can act on, and it is honest
    /// about the current limitation: Continuity's clicks travel through the
    /// guest application's own task time, so while it is starved NOW cannot
    /// press that alert's button for the person. Dismissing it has to happen
    /// at the Mac. When the resident learns to serve a press without the
    /// application (docs/open-issues.md, the foreign-modal entry), this
    /// sentence is the one that changes.
    static func starvationMessage(silence: TimeInterval) -> String {
        String(
            format: "NOW on the Mac has not answered for %.0f s, but the "
                + "machine itself is still running — which is what another "
                + "application's modal alert looks like from here. Dismiss "
                + "it at the Mac; Continuity cannot click it for you while "
                + "NOW is starved.",
            silence)
    }

    private func announceStarvationIfDue(silence: TimeInterval) {
        guard !starvationAnnounced, silence >= starvationAnnounceAfter else {
            return
        }
        starvationAnnounced = true
        let message = Self.starvationMessage(silence: silence)
        /* The status line and the notification are handed the same string,
           never two drafts of it — the rule announceDragRefusal already
           carries, for the same reason. */
        status = message
        audit(.warn, message)
        onStarvation?(message)
    }

    static func pointerLaneWaitingStatus(_ error: NWError) -> String {
        if case .posix(.ENETDOWN) = error {
            return "Waiting for macOS Local Network access. Approve its "
                + "prompt or enable NOW Continuity in System Settings > "
                + "Privacy & Security > Local Network."
        }
        return "waiting for the pointer lane: \(error.localizedDescription)"
    }

    static func pointerLaneFailure(_ error: NWError) -> String {
        if case .posix(.ENETDOWN) = error {
            return "macOS has not granted the Local Network path; approve "
                + "its prompt or enable NOW Continuity in System Settings > "
                + "Privacy & Security > Local Network"
        }
        return "UDP failed: \(error.localizedDescription)"
    }

    private func auditPointerLane(_ state: String, error: NWError,
                                  connection: NWConnection?) {
        let path = connection?.currentPath.map { String(describing: $0) }
            ?? "no current path"
        audit(
            state == "failed" ? .error : .warn,
            "UDP pointer lane \(state): \(String(describing: error)) — "
                + "\(error.localizedDescription); \(path)")
    }

    private func sendState(inside: Bool, keepalive: Bool) {
        guard let udp, phase == .active else { return }
        let wire = encodedState(inside: inside, keepalive: keepalive)
        keepaliveClock.update(payload: keepalive
            ? wire : ContinuityDatagramCodec.withKeepaliveFlag(wire))
        sentDatagrams &+= 1
        udp.send(content: wire, completion: .idempotent)
    }

    private func encodedState(inside: Bool, keepalive: Bool) -> Data {
        var flags: ContinuityStateDatagram.Flags = []
        if inside { flags.insert(.inside) }
        /* LEVEL OR EDGE, ONE BIT. `wireButtonDown` is the click cycle's
           edge, `carriedButtonLevel` the carry's held level; the guest's
           input proc cannot tell them apart and must not — it wants to know
           whether the button is down, which under a carry it is. What
           separates them is `buttonGeneration`, which only the cycle
           advances. See `carriedButtonLevel`. */
        if wireButtonDown { flags.insert(.primaryDown) }
        /* The carry rides its OWN bit. Folding it into .primaryDown gave a
           stale button_generation a down flag at every fresh epoch, and the
           resident posted the phantom press that clicked and
           marquee-selected at random on 2026-08-17. Only the guest drag's
           input proc reads this level. */
        if carriedButtonLevel { flags.insert(.carriedLevel) }
        if keepalive { flags.insert(.keepalive) }
        let packet = ContinuityStateDatagram(
            nonceHi: nonceHi, nonceLo: nonceLo, epoch: epoch,
            positionSequence: positionSequence,
            h: Int16(clamping: point.x), v: Int16(clamping: point.y),
            buttonGeneration: buttonGeneration, flags: flags,
            requestedHz: UInt16(requestedHz),
            hostStamp: UInt32(truncatingIfNeeded:
                Int(ProcessInfo.processInfo.systemUptime * 60)),
            previousButtonGeneration: previousButtonGeneration,
            previousButtonDown: previousButtonDown)
        return ContinuityDatagramCodec.encode(packet)
    }

    private func receiveAck() {
        guard let udp else { return }
        udp.receiveMessage { [weak self, weak udp] data, _, _, error in
            Task { @MainActor in
                guard let self, udp === self.udp else { return }
                if let error {
                    self.audit(.error, "UDP acknowledgement receive failed: "
                        + "\(String(describing: error)); "
                        + "sent=\(self.sentDatagrams), "
                        + "validAcks=\(self.validAcks)")
                    self.guestEnded(
                        reason: "UDP acknowledgement receive failed: "
                            + error.localizedDescription)
                    return
                }
                if let data {
                    do {
                        let ack = try ContinuityDatagramCodec.decodeAck(data)
                        guard ack.nonceHi == self.nonceHi,
                              ack.nonceLo == self.nonceLo,
                              ack.epoch == self.epoch else {
                            self.audit(.warn, "ignored UDP acknowledgement "
                                + "for another lease: bytes=\(data.count), "
                                + "epoch=\(ack.epoch), expectedEpoch=\(self.epoch)")
                            if udp === self.udp { self.receiveAck() }
                            return
                        }
                        self.validAcks &+= 1
                        if let starved = self.acknowledgementStarvedSince {
                            self.audit(.info, String(
                                format: "guest application acknowledgements recovered after %.1f s",
                                ProcessInfo.processInfo.systemUptime - starved))
                            self.acknowledgementStarvedSince = nil
                            self.toleratedSilenceLogMark = 0
                            self.starvationAnnounced = false
                            self.status = "direct pointer connected at "
                                + "\(self.acceptedHz) Hz"
                        }
                        let hostAckUptime = ProcessInfo.processInfo.systemUptime
                        self.lastAcknowledgementUptime = hostAckUptime
                        if self.validAcks == 1
                            || ack.exitReason != .none
                            || ack.state == .inactive
                            || ack.buttonGeneration
                                != self.lastAuditedButtonGeneration {
                            self.audit(.info, "UDP acknowledgement: "
                                + "state=\(ack.state), "
                                + "reason=\(ack.exitReason), "
                                + "positionSequence=\(ack.positionSequence), "
                                + "buttonGeneration=\(ack.buttonGeneration), "
                                + "arrivalTicks=\(ack.arrivalTicks), "
                                + "applyTicks=\(ack.applyTicks), "
                                + "rejected=\(ack.rejectedPackets)")
                            self.lastAuditedButtonGeneration =
                                ack.buttonGeneration
                        }
                        self.apply(ack)
                    } catch {
                        self.audit(.warn, "rejected UDP acknowledgement: "
                            + "bytes=\(data.count), error=\(String(describing: error))")
                    }
                }
                if udp === self.udp { self.receiveAck() }
            }
        }
    }

    private func apply(_ ack: ContinuityAckDatagram) {
        applyButtonAcknowledgement(ack)
        if ack.exitReason != .none || ack.state == .inactive {
            guestEnded(reason: exitDescription(ack.exitReason),
                       retryImmediately: ack.exitReason != .guestInput)
        }
    }

    private func applyButtonAcknowledgement(_ ack: ContinuityAckDatagram) {
        guard buttonCycleActive,
              ack.buttonGeneration == buttonGeneration else { return }
        if let sent = buttonTransitionSentUptime {
            let direction = wireButtonDown ? "down" : "up"
            let hostAck = ProcessInfo.processInfo.systemUptime
            let source = buttonTransitionSourceUptime ?? sent
            audit(.info, String(
                format: "primary %@ acknowledged: generation=%u, hostSourceMs=%.1f, hostSendMs=%.1f, hostAckMs=%.1f, sourceToAckMs=%.1f, guestArrivalTicks=%u, guestApplyTicks=%u",
                direction, buttonGeneration, source * 1_000, sent * 1_000,
                hostAck * 1_000, max(0, hostAck - source) * 1_000,
                ack.arrivalTicks, ack.applyTicks))
            buttonTransitionSentUptime = nil
            buttonTransitionSourceUptime = nil
        }
        if wireButtonDown {
            guard !pressAcknowledged else { return }
            pressAcknowledged = true
            buttonAckTimeout?.cancel()
            buttonAckTimeout = nil
            if let deferredButtonPoint {
                point = deferredButtonPoint
                self.deferredButtonPoint = nil
                positionDirty = true
                advancePositionIfNeeded()
                sendState(inside: true, keepalive: false)
            }
        } else {
            buttonAckTimeout?.cancel()
            buttonAckTimeout = nil
            resetButtonState(.cycle, reason: "release acknowledged")
        }
    }

    private func sendPrimaryRelease() {
        guard phase == .active, buttonCycleActive, wireButtonDown else {
            return
        }
        if let deferredButtonPoint {
            point = deferredButtonPoint
        }
        deferredButtonPoint = nil
        /* Only a release that carries the settled point earns the teardown's
           silence — an ordinary click's release, or one that wandered off the
           settled point, leaves the epoch ending exactly as it always did. */
        settledReleasePoint = heldSettlePoint == point ? point : nil
        heldSettlePoint = nil
        positionDirty = true
        advancePositionIfNeeded()
        advanceButton(to: false)
        buttonAckTimeout?.cancel()
        buttonAckTimeout = nil
        sendState(inside: true, keepalive: false)
        let sent = ProcessInfo.processInfo.systemUptime
        buttonTransitionSourceUptime = sent
        buttonTransitionSentUptime = sent
        scheduleButtonAckTimeout(generation: buttonGeneration, down: false)
    }

    private func advanceButton(to down: Bool) {
        previousButtonGeneration = buttonGeneration
        previousButtonDown = wireButtonDown
        buttonGeneration = nextNonzero(buttonGeneration)
        wireButtonDown = down
    }

    /* A slow down acknowledgement can mean a starved cooperative guest, not
       a dead one. Force the wire button up and unwind only this cycle; lease
       and liveness still own the epoch. See docs/continuity-mode.md. */
    private func abandonPrimaryCycle(reason: String) {
        /* Streaming edges means there is no buffered cycle to resume; the
           next AppKit down simply becomes the next generation. */
        buttonAckTimeout?.cancel()
        buttonAckTimeout = nil
        if wireButtonDown {
            advanceButton(to: false)
            sendState(inside: true, keepalive: false)
        }
        buttonTransitionSentUptime = nil
        buttonTransitionSourceUptime = nil
        resetButtonState(.cycle, reason: reason)
        audit(.warn, "primary cycle abandoned: \(reason), "
            + "generation=\(buttonGeneration), epoch=\(epoch) stays owned")
    }

    private func scheduleButtonAckTimeout(
        generation: UInt32, down: Bool
    ) {
        buttonAckTimeout?.cancel()
        buttonAckTimeout = Task { @MainActor [weak self] in
            /* Down timeout abandons only the click cycle. Up waits longer,
               then ends the epoch because an unconfirmed release cannot be
               carried safely into another cycle. */
            let timeout: UInt64 = down ? 3_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, !Task.isCancelled,
                  self.phase == .active, self.buttonCycleActive,
                  self.wireButtonDown == down,
                  self.buttonGeneration == generation,
                  !down || !self.pressAcknowledged else { return }
            if down {
                self.audit(.error, "primary down was not acknowledged; "
                    + "abandoning cycle generation=\(generation)")
                self.abandonPrimaryCycle(
                    reason: "down acknowledgement timeout")
                return
            }
            self.audit(.error, "primary up was not acknowledged; "
                + "ending epoch=\(self.epoch), generation=\(generation)")
            self.relinquish(reason: "button up acknowledgement timed out",
                            keepEnabled: true)
            self.scheduleReconnect(reason: "button up timeout",
                                    delay: self.reconnectDelay)
        }
    }

    private func rearmAfterConfigurationChange(reason: String) {
        let shouldRearm = isEnabled && pointerInside
        relinquish(reason: reason, keepEnabled: true)
        if shouldRearm {
            scheduleReconnect(reason: reason, delay: 0.25,
                              requiresOptIn: false)
        }
    }

    /* No default for `delay`: every call site now names it explicitly
       (reconnectDelay for the bounceback path, or an intentionally
       shorter fixed wait for a configuration-change rearm) so the number
       here can never drift out of step with the configured setting. */
    private func scheduleReconnect(reason: String, delay: Double,
                                   requiresOptIn: Bool = true) {
        guard (!requiresOptIn || autoReconnect), isEnabled, pointerInside,
              listener.activeContinuityTarget != nil else { return }
        reconnectTask?.cancel()
        status = "Continuity interrupted; reconnecting…"
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled,
                  (!requiresOptIn || self.autoReconnect),
                  self.isEnabled, self.pointerInside,
                  self.phase == .idle,
                  self.listener.activeContinuityTarget != nil else { return }
            self.reconnectTask = nil
            self.positionDirty = true
            self.audit(.info, "automatic reconnect: reason=\(reason)")
            self.arm()
        }
    }

    private func advancePositionIfNeeded() {
        guard positionDirty else { return }
        positionSequence = nextNonzero(positionSequence)
        positionDirty = false
    }

    private func relinquish(reason: String, keepEnabled: Bool) {
        let oldEpoch = epoch
        let wasOwned = phase != .idle
        let oldPhase = phase
        let oldSent = sentDatagrams
        let oldAcks = validAcks
        let clock = keepaliveClock.stop()
        if phase == .active, buttonCycleActive, wireButtonDown {
            if let deferredButtonPoint { point = deferredButtonPoint }
            positionDirty = true
            advancePositionIfNeeded()
            advanceButton(to: false)
            sendState(inside: false, keepalive: false)
        }
        clearTransportState()
        if wasOwned {
            audit(.info, "ending locally: reason=\(reason), "
                + "phase=\(oldPhase), epoch=\(oldEpoch), "
                + "sent=\(oldSent), validAcks=\(oldAcks), "
                + clockDescription(clock))
            _ = listener.disarmContinuity(
                epoch: oldEpoch, reason: wireDisarmReason(for: reason))
        }
        if !keepEnabled && !suppressEnabledObserver { status = "off" }
        else if keepEnabled { status = "move over the Mirror to reconnect" }
    }

    private func guestEnded(reason: String, retryable: Bool = true,
                            retryImmediately: Bool = true) {
        let clock = keepaliveClock.stop()
        audit(.warn, "guest ended Continuity: reason=\(reason), "
            + "epoch=\(epoch), sent=\(sentDatagrams), "
            + "validAcks=\(validAcks), " + clockDescription(clock))
        clearTransportState()
        onOwnershipEnded?(reason)
        if maintainsOptInAfterGuestExit && retryable && isEnabled {
            status = "Guest returned pointer control: \(reason); move across "
                + "the shared edge to enter again"
            return
        }
        if autoReconnect && retryable && isEnabled {
            if retryImmediately {
                status = "Continuity ended on the Mac: \(reason); reconnecting…"
                scheduleReconnect(reason: reason, delay: reconnectDelay)
            } else {
                status = "Continuity ended on the Mac: \(reason); move the "
                    + "host pointer to reconnect"
            }
        } else {
            status = "Continuity ended on the Mac: \(reason)"
            setEnabledWithoutTeardown(false)
        }
    }

    private func reportDescription(_ report: ContinuityReport) -> String {
        let reason: String
        switch report.reason {
        case "wrong-version": reason = "the Continuity control versions differ"
        case "resident-unavailable":
            reason = "the installed NOW Extension is incompatible or not active; "
                + "replace it and restart the Mac"
        case "guest-input": reason = "the guest mouse moved"
        case "lease-expired": reason = "the input lease expired"
        case "host-left": reason = "the host pointer left"
        case "disarmed": reason = "disarmed"
        case .some(let value): reason = value
        case nil: reason = report.state
        }
        guard report.reason == "lease-expired" else { return reason }
        let accepted = report.acceptedPackets ?? 0
        let stale = report.stalePackets ?? 0
        let malformed = report.malformedPackets ?? 0
        return "\(reason) (\(accepted) accepted, \(stale) stale, "
            + "\(malformed) malformed)"
    }

    private func clockDescription(_ stats: ContinuityKeepaliveClock.Stats)
        -> String {
        let age = stats.lastSendAge.map {
            String(format: "%.0f", $0 * 1_000)
        } ?? "none"
        return String(format:
            "leaseClockSent=%u, delayedTicks=%u, maxGapMs=%.0f, lastAgeMs=%@",
            stats.sent, stats.delayedTicks, stats.maxGap * 1_000, age)
    }

    private func isRetryable(_ reason: String?) -> Bool {
        reason != "unsupported" && reason != "wrong-version"
            && reason != "resident-unavailable"
    }

    /// End one authority epoch without deciding what the UI should say next.
    /// Local relinquish and guest-reported exit must clear the same state: in
    /// particular, click timing cannot cross an epoch boundary and masquerade
    /// as evidence about the next guest double-click.
    private func clearTransportState() {
        /* CAPTURED BEFORE THE CLEAR. The ended-epoch record forty lines
           down needs to know whose epoch this was, and `target = nil`
           below runs first — reading `target` at the record site left
           `endedEpoch` unrecorded on EVERY path, and every after-epoch
           mint died at "belonged to nobody" (attended, 2026-08-17). */
        let endedKey = target?.key
        _ = keepaliveClock.stop()
        timer?.cancel()
        timer = nil
        armTimeout?.cancel()
        armTimeout = nil
        buttonAckTimeout?.cancel()
        buttonAckTimeout = nil
        permissionRetry?.cancel()
        permissionRetry = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        waitingForLocalNetworkAccess = false
        udp?.cancel()
        udp = nil
        phase = .idle
        armID = nil
        target = nil
        positionDirty = false
        sentDatagrams = 0
        validAcks = 0
        lastAcknowledgementUptime = nil
        acknowledgementStarvedSince = nil
        toleratedSilenceLogMark = 0
        starvationAnnounced = false
        lastAuditedButtonGeneration = 0
        lastPrimaryDownUptime = nil
        heldSettlePoint = nil
        settledReleasePoint = nil
        buttonTransitionSentUptime = nil
        buttonTransitionSourceUptime = nil
        previousButtonGeneration = 0
        previousButtonDown = false
        /* THE LEVEL DIES WITH THE EPOCH IT WAS HELD IN. The carry's own
           lifecycle clears it on every exit path (see
           `ContinuityEdgeController.holdCarriedButton` callers); this is
           the floor under those, because a level surviving into the next
           epoch would hand the next drag a button nobody is holding. */
        carriedButtonLevel = false
        resetButtonState(.transport, reason: "authority epoch ended")
        keyGeneration = 0
        lastForwardedModifiers = 0
        /* A grab expires with the epoch by contract. Dropping the stub here
           is that rule made mechanical: the next epoch gets its own
           generation 1 and cannot redeem consent given in the last one. */
        selectionCache.clear(reason: "the Continuity epoch ended")
        /* WHOSE EPOCH JUST ENDED, and it is not a second cache. The target
           is cleared on this line's own account, so without this record the
           frame that carries a crossing gesture's generation — which by
           construction cannot be sent until the epoch is over — arrives
           from a machine this Mac no longer recognises as the owner of
           anything. It names one epoch and one gesture, and it is dropped
           the moment a new epoch is armed. */
        if epoch != 0, let key = endedKey {
            endedEpoch = EndedEpoch(epoch: epoch, key: key,
                                    dragSeq: announcedDragSeq)
        }
        /* The announcement dies with the epoch it was made under. A join
           key outliving its consent would let the NEXT epoch's application
           frame claim a gesture from the last one. */
        announcedDragSeq = nil
    }

    private enum ButtonResetScope {
        case cycle
        case transport
    }

    private func resetButtonState(_ scope: ButtonResetScope, reason: String) {
        precondition(!reason.isEmpty)
        buttonCycleActive = false
        deferredButtonPoint = nil
        primaryDownInMenuBar = false
        primaryCycleDragged = false
        menuLatched = false
        menuReleaseArmed = false
        isMenuTracking = false
        if scope == .transport {
            wireButtonDown = false
            pressAcknowledged = false
        }
    }

    private func setEnabledWithoutTeardown(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        suppressEnabledObserver = true
        isEnabled = enabled
        suppressEnabledObserver = false
    }

    /// A never-before-seen machine has none of the per-machine keys below,
    /// and falls back to `connectionDefaults` — the values Settings'
    /// "Defaults for New Connections" tab edits — rather than a literal
    /// constant. A machine with its own saved settings is unaffected: this
    /// only reads the global keys when the per-machine key is absent.
    private func loadSettingsForActiveGuest() {
        guard let machine = listener.activeContinuityTarget?.key.machine else {
            return
        }
        let seed = connectionDefaults
        let rateStoredKey = rateKey(for: machine)
        let stored = defaults.integer(forKey: rateStoredKey)
        let rate = defaults.object(forKey: rateStoredKey) != nil
                && [15, 30, 60].contains(stored)
            ? stored : seed.rate
        loadingSettings = true
        requestedHz = rate
        let reconnectStoredKey = reconnectKey(for: machine)
        autoReconnect = defaults.object(forKey: reconnectStoredKey) == nil
            ? seed.autoReconnect : defaults.bool(forKey: reconnectStoredKey)
        for option in ContinuityOptionCatalog.all {
            let key = optionKey(option, for: machine)
            self[keyPath: option.keyPath] = defaults.object(forKey: key) == nil
                ? seed.optionEnabled(option) : defaults.bool(forKey: key)
        }
        let keyboardKey = keyboardForwardingKey(for: machine)
        keyboardForwardingEnabled = defaults.object(forKey: keyboardKey) == nil
            ? seed.keyboardForwarding : defaults.bool(forKey: keyboardKey)
        if let raw = defaults.string(forKey: escapeShortcutKey(for: machine)),
           let shortcut = ContinuityEscapeShortcut(rawValue: raw) {
            escapeShortcut = shortcut
        } else {
            escapeShortcut = seed.escapeShortcut
        }
        let delayKey = reconnectDelayKey(for: machine)
        reconnectDelay = defaults.object(forKey: delayKey) == nil
            ? seed.reconnectDelay : clampReconnectDelay(defaults.double(forKey: delayKey))
        let entryInsetKey = edgeEntryInsetKey(for: machine)
        let deadzoneDepthKey = edgeDeadzoneDepthKey(for: machine)
        edge.updateEdgeGeometry(ContinuityEdgeGeometry(
            entryInsetPixels: defaults.object(forKey: entryInsetKey) == nil
                ? ContinuityEdgeGeometry.default.entryInsetPixels
                : defaults.double(forKey: entryInsetKey),
            deadzoneDepth: defaults.object(forKey: deadzoneDepthKey) == nil
                ? ContinuityEdgeGeometry.default.deadzoneDepth
                : defaults.double(forKey: deadzoneDepthKey)))
        loadingSettings = false
    }

    /// The seam Settings' "Defaults for New Connections" tab reads and
    /// writes through — a fresh value each call, over the same
    /// `UserDefaults` this controller itself reads, so an edit made while
    /// this controller is alive is visible the next time a new machine
    /// connects without either side holding a stale copy.
    var connectionDefaults: ContinuityConnectionDefaults {
        ContinuityConnectionDefaults(defaults: defaults)
    }

    /* Guards against a stale or hand-edited defaults value putting the
       reconnect wait outside a sane range: too low spins scheduleReconnect,
       too high reads as a hang after the pointer returns to the host. */
    private func clampReconnectDelay(_ value: Double) -> Double {
        min(max(value, 0.1), 5.0)
    }

    private func rateKey(for machine: GuestID) -> String {
        "mirror.continuity.rate.\(machine.slug)"
    }

    private func reconnectKey(for machine: GuestID) -> String {
        "mirror.continuity.autoReconnect.\(machine.slug)"
    }

    private func optionDidChange(_ id: ContinuityOptionID,
                                 from oldValue: Bool, to newValue: Bool) {
        guard newValue != oldValue else { return }
        let option = ContinuityOptionCatalog.descriptor(id)
        if !loadingSettings,
           let machine = listener.activeContinuityTarget?.key.machine {
            defaults.set(newValue, forKey: optionKey(option, for: machine))
        }
        if phase != .idle {
            rearmAfterConfigurationChange(reason: option.rearmReason)
        }
    }

    private func optionKey(_ option: ContinuityOptionDescriptor,
                           for machine: GuestID) -> String {
        "mirror.continuity.\(option.id.rawValue).\(machine.slug)"
    }

    private func keyboardForwardingKey(for machine: GuestID) -> String {
        "mirror.continuity.keyboardForwarding.\(machine.slug)"
    }

    private func escapeShortcutKey(for machine: GuestID) -> String {
        "mirror.continuity.escapeShortcut.\(machine.slug)"
    }

    private func reconnectDelayKey(for machine: GuestID) -> String {
        "mirror.continuity.reconnectDelay.\(machine.slug)"
    }

    private func wireDisarmReason(for reason: String) -> String {
        switch reason {
        case "disabled": return "disabled"
        case "pointer left Mirror": return "host-left"
        case "Mirror stopped": return "mirror-closed"
        default: return "disconnecting"
        }
    }

    private func exitDescription(_ reason: ContinuityAckDatagram.ExitReason)
        -> String {
        switch reason {
        case .none: return "inactive"
        case .hostLeft: return "host pointer left"
        case .guestInput: return "the guest mouse moved"
        case .leaseExpired: return "the input lease expired"
        case .disarmed: return "disarmed"
        }
    }

    private func nextNonzero(_ value: UInt32) -> UInt32 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

}
