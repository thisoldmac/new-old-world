import Foundation
import MirrorKit
import MirrorKitUI
import NOWAgentIntegration

/// The live NOW adapter uses MirrorKit's compatibility gate rather than
/// maintaining a second version constant. The duplicate used to accept only
/// v1 after MirrorKit and the guest had both moved to v2, leaving the real
/// Mirror window blank while every package-level IR test passed.
enum NOWMirrorSceneDecoder {
    static func decode(irVersion: Int,
                       document: Data) throws -> MirrorKit.Scene {
        /* Gate BEFORE JSONSerialization. An unknown major paired with garbage
           must still be an unsupported-major answer, not a parse failure. */
        try IR.requireSupportedMajor(NSNumber(value: irVersion))
        let body = try JSONSerialization.jsonObject(with: document)
        return try MirrorScene.decode(result: [
            "irVersion": irVersion,
            "scene": body,
        ])
    }

    static var readableMajors: String {
        IR.supportedMajors.sorted().map { "v\($0)" }
            .joined(separator: ", ")
    }

    /// **Read straight off the document, beside MirrorKit's decode rather
    /// than through it.**
    ///
    /// `meta.phases` is NOW's producer telling this host where its own
    /// second went. MirrorKit's `Scene.Meta` is a sibling project's type
    /// and does not carry it; teaching it to would be a change to the
    /// sibling for the benefit of one consumer, and this repository's rule
    /// for crossing that boundary is audited extraction, not convenience.
    /// So the key is read here, from the same bytes, and never reaches the
    /// rendered scene - it is a measurement about the walk, not a fact
    /// about the machine, and it belongs in the measurement record.
    ///
    /// Failure is silence. A document that does not carry phases and a
    /// document whose phases will not parse both mean "no breakdown for
    /// this cycle", which is the same claim absence already makes.
    static func phases(from document: Data) -> NOWSceneDocument.Phases? {
        struct Envelope: Decodable {
            struct Meta: Decodable { var phases: NOWSceneDocument.Phases? }
            var meta: Meta?
        }
        return try? JSONDecoder().decode(Envelope.self,
                                         from: document).meta?.phases
    }
}

/// The smallest continuity rule needed before the full state engine exists.
///
/// A scene is a bounded observation, not a deletion transaction. In
/// particular, Carbon may publish the system Apple menu's live identity and
/// geometry before its dynamic rows are available. Replacing a complete
/// guest-provided menu with that empty shell made the dropdown flash between
/// correct and blank as applications changed focus. Keep only the last rows
/// the guest actually supplied; all identity and geometry continue to come
/// from the newest scene, and the caller surfaces the expected-stale state.
enum NOWMirrorSceneContinuity {
    struct Acceptance {
        var scene: MirrorKit.Scene
        var retainedAppleItems: Bool
    }

    static func accept(_ incoming: MirrorKit.Scene,
                       after previous: MirrorKit.Scene?) -> Acceptance {
        var scene = incoming
        guard let index = scene.menubar?.menus.firstIndex(where: \.apple),
              scene.menubar?.menus[index].items.isEmpty == true,
              let retained = previous?.menubar?.menus.first(where: {
                  $0.apple && !$0.items.isEmpty
              }) else {
            return .init(scene: scene, retainedAppleItems: false)
        }

        scene.menubar?.menus[index].items = retained.items
        return .init(scene: scene, retainedAppleItems: true)
    }
}

/// The asynchronous seams that make one scene/content cycle. Production
/// binds these to the listener and content adapter; tests can hold each
/// completion to prove lifecycle and cadence behavior without a live socket.
@MainActor
struct NOWMirrorCycleIO {
    var activeKey: () -> GuestKey?
    /// Whether the named session still holds a live connection. The lane
    /// reads it when a cycle fails, so a guest that died is noticed by
    /// the next poll rather than learned from a queue that never drains.
    var isGuestConnected: (GuestKey) -> Bool
    /// Whether that session is ANSWERING, as opposed to starved — alive on
    /// another channel and not being scheduled. Nil when there is no such
    /// session, which is a third answer rather than a shade of the second.
    var isGuestAnswering: (GuestKey) -> Bool?
    var isScenePending: () -> Bool
    var requestScene: (
        GuestKey, Bool, Bool,
        @escaping (Result<GuestListener.SceneDelivery,
                          GuestListener.SceneFailure>) -> Void
    ) -> Void
    var guestChanged: () -> Void
    var disableContent: (@escaping (String?) -> Void) -> Void
    var joinContent: (
        MirrorKit.Scene,
        @escaping (NOWMirrorContentPlane.Update) -> Void
    ) -> Void

    static func live(listener: GuestListener,
                     content: NOWMirrorContentPlane) -> Self {
        .init(
            activeKey: { listener.activeKey },
            isGuestConnected: { listener.isConnected($0) },
            isGuestAnswering: { listener.isAnswering($0) },
            isScenePending: { listener.isScenePending },
            requestScene: { key, semantics, interaction, completion in
                listener.requestScene(
                    for: key, semantics: semantics,
                    interaction: interaction, completion: completion)
            },
            guestChanged: { content.guestChanged() },
            disableContent: { content.disable(completion: $0) },
            joinContent: { content.join(into: $0, completion: $1) })
    }
}

/// **The one door a guest command leaves through.**
///
/// Production binds it to `GuestListener.runCommand`; a test holds it to
/// read the exact verb and args a plan became, and answers when it
/// chooses — which is also the only honest way to have an act HOLD the
/// mutation lane on purpose. It exists because `serve` had no seam at
/// all: every fix to it was verified one level below where it lives, and
/// a mutation reinstating the Finder-activate defect left nine tests
/// green (2026-08-05).
typealias GuestCommandSend = @MainActor (
    _ verb: String,
    _ args: [String: CommandArg]?,
    _ completion: @escaping (CommandResult) -> Void) -> Void

/// **Mirror's live view, driven by NOW's own wire.**
///
/// The one object that makes `LiveMirrorView` — Mirror's gesture routing,
/// menu tracking, drag modes and double-click timing — run against a
/// Macintosh NOW is connected to. It conforms to `MirrorSceneSource` and
/// owns three things: a poll, a dispatch, and a sentence for a person.
///
/// ## Why this is not the archived port
///
/// `archive/mirror-port-2026-08-01` had the same shape and could not
/// click. Three things were missing under it, all fixed before this file
/// was written and all of them measurable:
///
/// - controls reached the consumer in **global** coordinates where the IR
///   is content-relative, so a click resolved to a neighbour;
/// - `windows[].rect` was the content region where the IR wants the box,
///   so everything was one title bar out;
/// - `Scene.Window` dropped the guest's `ref`, so no window act could be
///   addressed at all.
///
/// A fourth was not a defect but a mismatch: `ActionModel` resolved a
/// scroll arrow to a QMP press, which no PowerBook has. `ActionPlanes`
/// is why this class reports `.residentActPlane` and gets a Control
/// Manager part instead.
///
/// ## The poll is sequential, and that is not a detail
///
/// The contract allows ONE bulk transfer at a time and the guest enforces
/// it, so a free-running timer would spend its failures on "a transfer is
/// already in progress" — noise that reads exactly like a broken guest.
/// The next request is armed when the last one lands.

/// **What `perform` did with an interaction.**
///
/// Four endings, and for a year three of them were the same value. The
/// Mirror window never needed to tell them apart — a person reads the
/// status line and then looks at the screen — so `perform` answered
/// `String?`, a sentence when the act never left and `nil` otherwise.
/// `MirrorDriveService` had to serve a caller with no screen and no
/// status line, and reconstructed the missing distinction by checking
/// whether a broker record had appeared. It was wrong twice on
/// 2026-08-05, both times in the same direction: **the host knew, and
/// told the agent something else.**
///
/// The distinction is only recoverable at the point that made it, which
/// is why it is a return value rather than a second opinion computed
/// downstream.
enum MirrorPerformDisposition: Equatable {
    /// Declined this side. Nothing reached the guest and nothing is
    /// coming; the sentence is the one a person would have read.
    case refused(String)
    /// In the broker's lane under this id, with a typed postcondition. A
    /// record for it exists in the journal already.
    case brokered(String)
    /// Arrived while an observation was in flight, so it is held: no
    /// record yet, and one is coming through this same door when the
    /// cycle clears. Indistinguishable from `.direct` by journal
    /// inspection alone, which is exactly the 2026-08-05 defect.
    case held
    /// Dispatched with no typed postcondition. Seven of the fourteen
    /// plans are like this by construction, and nothing will ever settle
    /// them — a caller that mistook a `.held` act for one of these would
    /// stop waiting for a settlement that was on its way.
    case direct

    /// The sentence, for the callers that only ever wanted that.
    var refusal: String? {
        if case .refused(let why) = self { return why }
        return nil
    }
}

@MainActor
final class NOWMirrorSource: ObservableObject, MirrorSceneSource {

    @Published private(set) var scene: MirrorKit.Scene?

    /// **What the machine last DID, not what the poll last saw.**
    ///
    /// These were one string, and a poll every 0.75s overwrote the answer
    /// to a click before a person could read it - so a refusal, which is
    /// the most useful thing this surface produces, flashed and was gone.
    /// The poll line is ambient; an act's answer is an event, and events
    /// stay put.
    @Published private(set) var lastAct: String = ""
    @Published private(set) var ambient: String = "not started"

    /// What the window shows: the act while it is still worth reading,
    /// then the ambient line again.
    /// The one line under the Mirror, with the lane's depth on it.
    ///
    /// A person driving cannot tell a gesture that is being served slowly
    /// from one that has not left yet, and on 2026-08-04 that ambiguity
    /// is most of what made a metal drive unreadable. The FIFO knows, and
    /// it costs one clause to say so. Only when something is actually
    /// waiting: a permanent "0 queued" would be noise on the surface a
    /// person is trying to read the Macintosh through.
    var status: String {
        let base = lastAct.isEmpty ? ambient : lastAct
        var line = base
        if actTimeline.depth > 1 {
            line += "   ·   \(actTimeline.depth - 1) waiting"
        }
        /* **Carried on the act line too, not just the ambient one.** An
           act's answer replaces the ambient text for four seconds, which
           is exactly the window in which a person clicks again — so a
           Mirror that only said "not answering" in its idle line would go
           quiet about it at the moment it is most needed. */
        if isStarved, !line.contains("not answering") {
            line += "   ·   the Mac is not answering"
        }
        return line
    }

    /// Acts in the mutation lane right now — the one holding it plus the
    /// ones waiting. What the cancel affordance shows against.
    var waitingActs: Int { mutationBroker?.depth ?? 0 }

    /// **The third state.** The pinned Macintosh is connected and is not
    /// being scheduled — starved by something holding its processor, which
    /// on a cooperative machine is one blocked callee away at any time.
    ///
    /// Distinct from disconnected on purpose: everything the Mirror is
    /// showing remains TRUE, just frozen, and an act sent now will be
    /// served when the machine comes back rather than refused.
    var isStarved: Bool {
        guard let pinnedGuestKey else { return false }
        return cycleIO.isGuestAnswering(pinnedGuestKey) == false
    }

    /// A person or an agent abandoning the wait. Ends the in-flight act
    /// and everything queued behind it; the journal records each with a
    /// typed `cancelled` outcome whose reason says whether anything was
    /// sent. The lane is immediately free for the next act.
    @discardableResult
    func cancelPendingActs() -> Int {
        guard let mutationBroker, mutationBroker.depth > 0 else {
            report("nothing is waiting to cancel")
            return 0
        }
        let ended = mutationBroker.cancelAll()
        actTimeline.depth = mutationBroker.depth
        ActLog.note(action: "(cancel)",
                    outcome: "cancelled \(ended) act"
                        + (ended == 1 ? "" : "s"), ms: 0)
        report("cancelled \(ended) act" + (ended == 1 ? "" : "s"))
        return ended
    }

    /// NOW addresses elements by reference and has no positional click
    /// verb — `contract/asyncapi.yaml` states that omission deliberately.
    /// Both halves matter: the first is what makes this mirror drivable on
    /// metal, the second is what makes a click on bare desktop a named
    /// refusal instead of a silence.
    nonisolated var planes: ActionPlanes { .residentActPlane }

    private let listener: GuestListener
    private let engineRegistry: MirrorStateEngineRegistry?
    private let act: AgentIntegrationActControl
    /// The nonce `dragpress` minted for the gesture in flight, and the only
    /// thing `dragmove` and `dragrelease` can be addressed with. Nil
    /// between gestures — and nil is not "released": the resident's own
    /// dead-man is what guarantees the button comes up, never this field.
    fileprivate var dragSession: Int?
    private var dragPressInFlight = false
    private var pendingDragPoint: MirrorKit.Point?
    private var pendingDragRelease: ((ItemDragAnswer) -> Void)?
    private let cycleIO: NOWMirrorCycleIO
    private let sendCommand: GuestCommandSend
    private let interval: TimeInterval
    private let planePolicy: @MainActor (GuestKey) -> Set<MirrorPlaneID>
    private let finderComplementPolicy: @MainActor (GuestKey) -> Bool
    private let finderRefreshOverride: (@MainActor (
        MirrorKit.Scene, Int, @escaping () -> Void
    ) -> Void)?
    private let visibilityRefreshOverride: (@MainActor (
        MirrorKit.Scene, Int, @escaping () -> Void
    ) -> Void)?
    private let lifecycleDidChange: @MainActor () -> Void
    /// **Published, because it is now a control and not an internal flag.**
    ///
    /// Running used to be implied by an open window, and the window's own
    /// `isOpen` was the `@Published` a button watched. Under start/stop
    /// this is the thing the button IS, so a plain stored property would
    /// have rendered the label once and then frozen — the control saying
    /// "Start" over a poll that had been running for a minute.
    @Published private(set) var running = false
    private var runGeneration = 0
    /// The deferred lifecycle refresh a stop schedules eleven seconds out,
    /// held so a restart inside that window can cancel it. Without this a
    /// Stop→Start pair leaves a refresh from the DEAD run to land on the
    /// live one and repaint the plane card with the stopped state.
    private var deferredLifecycleRefresh: Task<Void, Never>?
    private var cycleGeneration: Int?
    private var pollRequestedAfterCycle = false
    private var rearmTask: Task<Void, Never>?
    private var pending: Bool { cycleGeneration != nil }

    /// Icons, per container, and the layout they were read for.
    ///
    /// **Why the host fetches these at all.** NOW's scene walk reads the
    /// Toolbox's own structures - windows, controls, menus - and a Finder
    /// icon is none of those. It is a file the Finder draws, and the
    /// Finder is the only thing that knows where. So they come from the
    /// Finder, by AppleScript, and are merged into the scene here.
    ///
    /// Cached against `FinderItems.layoutKey`, which changes when a window
    /// moves or resizes. Scrolling is a local projection of the same roster:
    /// `finderScrollOrigins` records the control values at capture and
    /// `withIcons` translates the cached boxes by the current delta.
    private var icons: [String: [MirrorKit.Scene.DesktopItem]] = [:]
    private var finderPresentations:
        [String: MirrorKit.Scene.FinderPresentation] = [:]
    private var finderScrollOrigins: [String: Point] = [:]
    /// Completed semantic reads are tracked per visible container. One
    /// unreadable desktop or background folder must not make a successfully
    /// rendered front window re-run its AppleScripts forever.
    private var finderLayouts: [String: String] = [:]
    private var finderArtByPath: [String: [String: (String, String)]] = [:]
    private var finderArtCompletePaths = Set<String>()
    private var desktopIconLayout: String = "<none>"
    private var fetchingIcons = false
    private var finderReadNoticeShown = false
    private var iconTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    /// The process roster the last visibility census was read for, and
    /// when. See `refreshVisibilityIfStale` — this census used to be the
    /// only unconditional multi-round-trip in the lane.
    private var visibilityKey: String = "<none>"
    private var visibilityReadAt: Date?
    private var actGeneration = 0
    private var settlementTracker = MirrorSettlementTracker()
    private var planCorrelation: String?
    private var planSettlement = "unknown"
    /// Whether the last served plan's refusal is known never to have
    /// reached the machine. It decides whether the broker keeps the lane
    /// open waiting for evidence, so it is read from the act lane's typed
    /// answer rather than from the refusal's wording.
    private var planRefusalReach = AgentIntegrationProjectionFailure
        .Reach.unknown
    private var mutationBroker: MirrorMutationBroker?
    /// The lane for the acts the broker never sees — control clicks, moves,
    /// resizes, keystrokes. They used to dispatch concurrently into a guest
    /// with one act cell, which refused all but one of them. See
    /// ``MirrorDirectActLane``.
    private let directActLane = MirrorDirectActLane()
    /// These timelines describe exactly one session. Durable history lives in
    /// the act log; the in-memory projection resets at every session boundary.
    let actTimeline = MirrorActTimeline()
    let cycleTimeline = MirrorCycleTimeline()
    private var cycleAsked: (at: Date, semantics: Bool, interaction: Bool)?
    private var cycleDelivered: Date?
    private var cycleOutcome = "no-reply"
    /// The failure's own sentence, kept beside the outcome word so it can
    /// reach a face that has no status line. See `MirrorCycleClocks.reason`.
    private var cycleReason: String?
    /// This cycle's guest-side breakdown, if the producer reported one.
    /// Cleared with the rest of the cycle so a slow scene's phases can
    /// never be charged to the next cycle that failed to answer.
    private var cyclePhases: NOWSceneDocument.Phases?
    /// This cycle's own split of the `decode_ms` bracket. See
    /// `MirrorCycleClocks.ownWork`.
    private var cycleOwnWork: TimeInterval?
    private var cycleContentJoin: TimeInterval?
    /// The listener's lifetime timeout count as this cycle ASKED. The
    /// difference at publish is how many guest commands this cycle gave
    /// up on, and it goes on the line: `command.request` gained a bound
    /// on 2026-08-06 and a bound nobody can see in the record is just a
    /// truncation (`MirrorCycleClocks.guestTimeouts`).
    private var cycleTimeoutsAtStart = 0
    private var lastCyclePublishedAt: Date?
    private var mutationWaiting = false
    private var sceneGuestKey: GuestKey?
    private(set) var pinnedGuestKey: GuestKey?
    private(set) var shadowEngine: MirrorStateEngine?

    init(listener: GuestListener,
         engineRegistry: MirrorStateEngineRegistry? = nil,
         act: AgentIntegrationActControl,
         interval: TimeInterval = 0.75,
         planePolicy: @escaping @MainActor (GuestKey) -> Set<MirrorPlaneID> = {
             _ in
             Set(MirrorPlaneID.allCases)
         },
         finderComplementPolicy: @escaping @MainActor (GuestKey) -> Bool = {
             _ in true
         },
         finderRefreshOverride: (@MainActor (
             MirrorKit.Scene, Int, @escaping () -> Void
         ) -> Void)? = nil,
         visibilityRefreshOverride: (@MainActor (
             MirrorKit.Scene, Int, @escaping () -> Void
         ) -> Void)? = nil,
         cycleIO: NOWMirrorCycleIO? = nil,
         sendCommand: GuestCommandSend? = nil,
         lifecycleDidChange: @escaping @MainActor () -> Void = {}) {
        self.listener = listener
        self.engineRegistry = engineRegistry
        self.act = act
        let content = NOWMirrorContentPlane(listener: listener)
        self.cycleIO = cycleIO ?? .live(listener: listener, content: content)
        self.sendCommand = sendCommand ?? { verb, args, completion in
            listener.runCommand(verb, typed: args, completion: completion)
        }
        self.interval = interval
        self.planePolicy = planePolicy
        self.finderComplementPolicy = finderComplementPolicy
        self.finderRefreshOverride = finderRefreshOverride
        self.visibilityRefreshOverride = visibilityRefreshOverride
        self.lifecycleDidChange = lifecycleDidChange
    }

    // MARK: - The poll

    func start() {
        guard !running else { return }
        /* A stop schedules a lifecycle refresh eleven seconds out to catch
           the resident's leases lapsing. If a person starts again inside
           that window, that refresh describes a run that no longer exists
           and repaints the plane card as stopped over a live poll. */
        deferredLifecycleRefresh?.cancel()
        deferredLifecycleRefresh = nil
        runGeneration &+= 1
        iconTask?.cancel()
        iconTask = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        fetchingIcons = false
        finderReadNoticeShown = false
        guard let key = cycleIO.activeKey() else {
            ambient = "no Mac is connected"
            return
        }
        pinnedGuestKey = key
        shadowEngine = engineRegistry?.engine(for: key)
        _ = shadowEngine?.setEnabledPlanes(planePolicy(key))
        scene = shadowEngine?.snapshot?.scene ?? scene
        mutationBroker = shadowEngine.map { engine in
            MirrorMutationBroker(journal: engine.operations,
                                 clocks: { [weak self] in
                self?.actTimeline.record($0)
                self?.actTimeline.depth = self?.mutationBroker?.depth ?? 0
            })
        }
        actTimeline.depth = 0
        running = true
        cycleGeneration = nil
        pollRequestedAfterCycle = false
        cycleIO.guestChanged()
        ambient = "asking for a scene…"
        lifecycleDidChange()
        poll()
    }

    func stop() {
        let stoppingKey = pinnedGuestKey
        let canRelease = stoppingKey != nil
            && stoppingKey == cycleIO.activeKey()
        guard canRelease else {
            endSession(message: "stopped; pinned Mac was not active",
                       clearContentImmediately: true)
            return
        }
        endSessionReleasingContent(message: "stopped")
    }

    /// Escape hatch for semantic state that may have gone stale without a
    /// structural scene change. The live session and its ownership leases stay
    /// intact; only host projections are discarded and repopulated.
    func rebuildGuestState() {
        guard running else { return }
        iconTask?.cancel()
        iconTask = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        fetchingIcons = false
        finderReadNoticeShown = false
        icons.removeAll()
        finderPresentations.removeAll()
        finderScrollOrigins.removeAll()
        finderLayouts.removeAll()
        finderArtByPath.removeAll()
        finderArtCompletePaths.removeAll()
        desktopIconLayout = "<none>"
        visibilityKey = "<none>"
        visibilityReadAt = nil
        ambient = "discarded cached guest state; rebuilding…"
        note("manual rebuild discarded Finder rosters and application state")
        poll()
    }

    /// Called immediately before the listener changes focus, while the
    /// outgoing guest can still receive the content owner's explicit stop.
    func activeGuestWillChange() {
        guard let pinnedGuestKey,
              pinnedGuestKey == cycleIO.activeKey() else { return }
        endSessionReleasingContent(
            message: "the selected Mac is changing; Mirror session ended")
    }

    private func endSessionReleasingContent(message: String) {
        endSession(message: message, clearContentImmediately: false)
        let stoppingGeneration = runGeneration
        /* P1/P2 and P4 are application-owned claims with a ten-second
           resident lease; stopping the poll stops renewing them, so they
           retire without a foreign-context teardown command. P3 is different:
           its content lease is deliberately long, so release it explicitly
           and report a refusal instead of claiming the Mirror is clean. */
        cycleIO.disableContent { [weak self] failure in
            guard let self else { return }
            /* A stop can settle after a person has started this source for a
               newer session. The old content release must not tear down or
               relabel that new binding. */
            guard !self.running,
                  self.runGeneration == stoppingGeneration else {
                return
            }
            self.ambient = failure.map {
                "\(message); Content claim release refused: \($0)"
            } ?? message
            self.lifecycleDidChange()
        }
    }

    /// End the pinned session when the listener's active connection changes.
    /// A later resume is a fresh start even when it is the same physical Mac.
    func activeGuestDidChange() {
        guard let pinnedGuestKey,
              pinnedGuestKey != cycleIO.activeKey() else { return }
        endSession(
            message: cycleIO.activeKey() == nil
                ? "the Mac disconnected; Mirror session ended"
                : "the selected Mac changed; Mirror session ended",
            clearContentImmediately: true)
    }

    /// The one destructive boundary for a Mirror session. A host restart used
    /// to be the only operation that cleared all of this state, which made
    /// every reproduction after a stop or redial inherit old frames, engines,
    /// queue state, and measurements.
    private func endSession(message: String,
                            clearContentImmediately: Bool) {
        let endedKey = pinnedGuestKey
        runGeneration &+= 1
        running = false
        cycleGeneration = nil
        pollRequestedAfterCycle = false
        rearmTask?.cancel()
        rearmTask = nil
        deferredLifecycleRefresh?.cancel()
        deferredLifecycleRefresh = nil
        iconTask?.cancel()
        iconTask = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        fetchingIcons = false
        finderReadNoticeShown = false
        if clearContentImmediately { cycleIO.guestChanged() }

        mutationBroker?.sessionChanged()
        directActLane.reset()
        mutationBroker = nil
        if let endedKey { engineRegistry?.remove(endedKey) }
        pinnedGuestKey = nil
        shadowEngine = nil

        scene = nil
        sceneGuestKey = nil
        icons.removeAll()
        finderPresentations.removeAll()
        finderScrollOrigins.removeAll()
        finderLayouts.removeAll()
        finderArtByPath.removeAll()
        finderArtCompletePaths.removeAll()
        desktopIconLayout = "<none>"
        visibilityKey = "<none>"
        visibilityReadAt = nil
        settlementTracker = MirrorSettlementTracker()
        planCorrelation = nil
        planSettlement = "unknown"
        planRefusalReach = .unknown
        mutationWaiting = false
        dragSession = nil
        dragPressInFlight = false
        pendingDragPoint = nil
        pendingDragRelease = nil
        cycleAsked = nil
        cycleDelivered = nil
        cycleOutcome = "no-reply"
        cycleReason = nil
        cyclePhases = nil
        cycleOwnWork = nil
        cycleContentJoin = nil
        lastCyclePublishedAt = nil
        lastAct = ""
        actGeneration &+= 1
        actTimeline.reset()
        cycleTimeline.reset()
        ambient = message
        lifecycleDidChange()

        deferredLifecycleRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 11_000_000_000)
            guard let self, !Task.isCancelled, !self.running else { return }
            self.lifecycleDidChange()
        }
    }

    private func poll() {
        guard running, cycleGeneration == nil else { return }
        guard !mutationWaiting else { return rearm() }
        guard let pinnedGuestKey else {
            ambient = "the Mirror has no pinned Mac"
            return
        }
        /* The lane is shared with streams, captures and file transfers.
           Asking while one holds it earns a refusal that says nothing
           about the Macintosh, so we wait a beat instead of spending a
           request on it. */
        guard !cycleIO.isScenePending() else { return rearm() }
        let generation = runGeneration
        cycleGeneration = generation
        let planes = planePolicy(pinnedGuestKey)
        cycleAsked = (at: Date(),
                      semantics: planes.contains(.semantics),
                      interaction: planes.contains(.interaction))
        cycleDelivered = nil
        cycleOutcome = "no-reply"
        cycleReason = nil
        cycleTimeoutsAtStart = listener.commandTimeouts
        cycleIO.requestScene(
            pinnedGuestKey, planes.contains(.semantics),
            planes.contains(.interaction)) { [weak self] result in
            guard let self else { return }
            self.cycleDelivered = Date()
            guard self.isCurrentCycle(generation) else { return }
            switch result {
            case .success(let delivery):
                guard delivery.guestKey == self.pinnedGuestKey else {
                    self.ambient = "ignored a scene from a different Mac"
                    self.cycleOutcome = "wrong-mac"
                    self.finishCycle(generation)
                    return
                }
                self.cycleOutcome = "ok"
                /* Content is a bounded command answer issued only after the
                   scene transfer settles. Rearming the structural poll here
                   would create a second cadence and race the one command
                   whose records belong to this exact scene. */
                self.apply(delivery.settlements)
                self.accept(delivery, generation: generation)
                return
            case .failure(let failure):
                /* The last scene STANDS. A poll that failed is a gap in
                   knowledge, not evidence the windows went away, and
                   blanking the mirror on one is how a momentary busy lane
                   looks like a crash. */
                /* **Three states, not two.** A Macintosh that is alive and
                   not being scheduled is neither connected nor gone, and
                   showing it as either is a lie a person acts on: as
                   connected, they conclude the Mirror is broken; as gone,
                   they go and check a machine that is fine. It is the
                   commonest failure this surface has — one modal produces
                   it — so it gets its own sentence and says what to do. */
                /* **Before the branch, because every branch below it
                   loses something.** `starved`, `declined` and `failed`
                   are three words for five or more distinct conditions,
                   and the sentence that tells them apart is already
                   written here — it just used to go only to `ambient`,
                   which the agent socket cannot read. */
                self.cycleReason = failure.message
                if self.isStarved {
                    self.ambient = "the Mac is not answering — it is still "
                        + "there, but something on it is not letting go "
                        + "(a dialog, or a long operation). Acts will wait."
                    self.cycleOutcome = "starved"
                } else {
                    self.ambient = failure.refusedByGuest
                        ? "the Mac declined: \(failure.message)"
                        : failure.message
                    self.cycleOutcome = failure.refusedByGuest
                        ? "declined" : "failed"
                }
                self.noticeDeadGuest()
            }
            self.finishCycle(generation)
        }
    }

    /// **A window that is drawn is not necessarily a window that was
    /// seen, and the status line has to say which.**
    ///
    /// The reducer already knows: a window whose owning process reported
    /// `unavailable/not-observed` is RETAINED rather than deleted — an
    /// unobserved process cannot testify that its window is gone — and it
    /// is marked `.expectedStale` and un-actionable when it is. Nothing
    /// carried that fact to the person. On 2026-08-06 the line read
    /// `5 windows · walk 0ms · transfer 36ms · same` while three of those
    /// five were retentions of a machine the guest could not observe at
    /// all, and `same` was the guest correctly reporting that its blind
    /// document had not changed. Every word was true and the sentence was
    /// a lie by omission.
    ///
    /// Menu retention already had this vocabulary one line away
    /// (`Apple menu expected-stale`); windows now share it.
    private func observationPhrase(_ count: Int) -> String {
        Self.observationPhrase(count, replica: shadowEngine?.replica,
                               coverage: shadowEngine?.snapshot?
                                   .scene.meta.coverage)
    }

    /// Nonisolated because it reads only its arguments: the phrase is a
    /// pure function of a replica, and a test that had to hop the main
    /// actor to check a string would be testing the hop.
    ///
    /// `awaiting icons` joins it for the same reason `expected-stale` did.
    /// The scene cycle no longer waits for the Finder roster, so a frame
    /// can be drawn for a layout whose icons have not been read — and a
    /// folder window with no items in it reads as an empty folder rather
    /// than as a question nobody has asked yet. The claim is already in
    /// `meta.coverage`; this is it in the one line a person reads.
    nonisolated static func observationPhrase(
        _ count: Int, replica: MirrorReplica?,
        coverage: [MirrorKit.Scene.CoverageClaim]? = nil) -> String {
        let stale = replica?.windows.values.filter {
            $0.freshness == .expectedStale
        }.count ?? 0
        let iconsPending = coverage?.contains {
            $0.scope == "finder-items" && $0.status != .complete
        } ?? false
        var phrase = "\(count) windows"
        if stale > 0 { phrase += ", \(stale) expected-stale" }
        if iconsPending { phrase += ", awaiting icons" }
        return phrase
    }

    private func accept(_ delivery: GuestListener.SceneDelivery,
                        generation: Int) {
        guard isCurrentCycle(generation) else { return }
        let ownWorkStarted = Date()
        do {
            var decoded = try NOWMirrorSceneDecoder.decode(
                irVersion: delivery.irVersion, document: delivery.document)
            cyclePhases = NOWMirrorSceneDecoder.phases(
                from: delivery.document)
            guard isCurrentCycle(generation), let key = pinnedGuestKey else {
                return
            }
            let planes = planePolicy(key)
            _ = shadowEngine?.setEnabledPlanes(planes)
            _ = shadowEngine?.accept(decoded)
            observeOperations()
            let sameGuest = delivery.guestKey != nil
                && delivery.guestKey == sceneGuestKey
            let continuity = NOWMirrorSceneContinuity.accept(
                decoded, after: sameGuest ? scene : nil)
            sceneGuestKey = delivery.guestKey
            decoded = continuity.scene
            decoded = withIcons(decoded)
            _ = shadowEngine?.enrichFinder(decoded)
            scene = projectedScene(fallback: decoded)
            /* Everything above is this host's own CPU on the delivery;
               everything below it is a guest round-trip. That is the
               line `dc_own_ms` draws. */
            cycleOwnWork = Date().timeIntervalSince(ownWorkStarted)
            let menuStatus = continuity.retainedAppleItems
                ? " · Apple menu expected-stale" : ""
            guard pinnedGuestKey == cycleIO.activeKey() else {
                shadowEngine?.compareVisible(decoded)
                scene = projectedScene(fallback: decoded)
                ambient = observationPhrase(decoded.windows.count)
                    + " · pinned Mac "
                    + "is in the background; content and actions paused"
                    + menuStatus
                finishCycle(generation)
                lifecycleDidChange()
                return
            }
            if !planes.contains(.content) {
                cycleIO.disableContent { [weak self] failure in
                    guard let self else { return }
                    guard self.isCurrentCycle(generation) else { return }
                    self.shadowEngine?.compareVisible(decoded)
                    self.scene = self.projectedScene(fallback: decoded)
                    self.ambient =
                        self.observationPhrase(decoded.windows.count)
                        + " · "
                        + (failure.map {
                            "content release refused: \($0)"
                        } ?? "content off") + menuStatus
                    self.finishCycle(generation)
                    self.lifecycleDidChange()
                    self.refreshComplements(decoded)
                }
                return
            }
            let contentStarted = Date()
            cycleIO.joinContent(decoded) { [weak self] update in
                guard let self else { return }
                guard self.isCurrentCycle(generation) else { return }
                self.cycleContentJoin = Date()
                    .timeIntervalSince(contentStarted)
                _ = self.shadowEngine?.enrichContent(update.scene)
                self.observeOperations()
                self.shadowEngine?.compareVisible(update.scene)
                self.scene = self.projectedScene(fallback: update.scene)
                /* THE WIRE COST, beside the walk and the transfer,
                   because the whole argument for deltas is a byte
                   count and a claim is not a measurement. "same"
                   means no bulk lane was used at all. */
                let wire: String
                switch delivery.form {
                case .unchanged:
                    wire = "same"
                case .delta:
                    wire = "delta \(delivery.wireBytes)B"
                        + (delivery.wholeBytes.map { "/\($0)B" } ?? "")
                case .whole:
                    wire = "whole \(delivery.wireBytes)B"
                }
                self.ambient =
                    self.observationPhrase(update.scene.windows.count)
                    + " · walk "
                    + "\(delivery.walkMs.map { "\($0)ms" } ?? "?") · transfer "
                    + "\(delivery.transferMs)ms · \(wire) · \(update.sentence)"
                    + menuStatus
                /* **The cycle ENDS here, before the Finder complements.**
                   They used to be inside it, and that is what cost this
                   project a whole evening of refused acts — see
                   `refreshComplements`. */
                self.finishCycle(generation)
                self.lifecycleDidChange()
                self.refreshComplements(update.scene)
            }
            return
        } catch IR.CompatError.unknownMajor {
            ambient = "this Mac speaks scene IR v\(delivery.irVersion); "
                + "this build reads \(NOWMirrorSceneDecoder.readableMajors)"
        } catch {
            /* Named rather than swallowed: this is the seam that has cost
               this project the most, and a mirror that silently keeps
               drawing a stale scene while the producer emits something
               unreadable is the failure wearing its best clothes. */
            ambient = "the scene did not decode as IR "
                + "v\(delivery.irVersion): \(error)"
        }
        finishCycle(generation)
    }

    /// **The lane must survive its guest.** Measured 2026-08-05: the
    /// session ended with a socket left CLOSED while the host still
    /// believed it had a guest, and six operations settled
    /// `sessionChanged` at once only when the session was finally torn
    /// down by hand — the queue had been the only thing that knew. The
    /// wire already notices a death (socket close, the 75 s idle clock);
    /// this is the missing hop: when a cycle fails and the pinned
    /// session no longer holds a connection, the lane ends its acts NOW,
    /// once, each typed `sessionChanged` — rather than each waiting out
    /// its own timeout against a machine that is gone.
    private func noticeDeadGuest() {
        guard let pinned = pinnedGuestKey,
              !cycleIO.isGuestConnected(pinned),
              let mutationBroker, mutationBroker.depth > 0 else { return }
        let ended = mutationBroker.depth
        mutationBroker.sessionChanged()
        directActLane.reset()
        actTimeline.depth = mutationBroker.depth
        ActLog.note(action: "(guest lost)",
                    outcome: "ended \(ended) act"
                        + (ended == 1 ? "" : "s")
                        + ": the pinned Mac is no longer connected", ms: 0)
        report("the Mac disconnected — \(ended) act"
               + (ended == 1 ? " was" : "s were") + " ended")
    }

    private func isCurrentCycle(_ generation: Int) -> Bool {
        running && runGeneration == generation
            && cycleGeneration == generation
    }

    /// Drain one cycle exactly once. A policy toggle made while scene or
    /// content was in flight earns one immediate follow-up; the ordinary
    /// interval owns every other continuation.
    private func finishCycle(_ generation: Int) {
        guard isCurrentCycle(generation) else { return }
        recordCycleClocks()
        cycleGeneration = nil
        if pollRequestedAfterCycle {
            pollRequestedAfterCycle = false
            poll()
        } else {
            rearm()
        }
    }

    /// One measurement per cycle, whatever it produced. A cycle that
    /// declined or never answered still spent the guest's time, and a
    /// baseline made only of successful walks describes a machine that
    /// is never busy.
    private func recordCycleClocks() {
        guard let asked = cycleAsked else { return }
        let published = Date()
        /* **Counts belong to the cycle that produced them.** `scene` is
           the last PROVEN one and it deliberately stands through a
           failure — so reading its windows and elements here put the last
           good walk's numbers in the row of a cycle that never asked. On
           2026-08-07 a live drive showed 14 such rows, each carrying a
           window and element count beside three zeroed clocks, which
           reads as data and is not. `-` is the honest answer: this cycle
           published no scene, so it counted nothing. */
        let producedScene = cycleOutcome == "ok" ? scene : nil
        cycleTimeline.record(.init(
            requestedAt: asked.at,
            deliveredAt: cycleDelivered,
            publishedAt: published,
            idleBefore: lastCyclePublishedAt.map {
                asked.at.timeIntervalSince($0)
            },
            semantics: asked.semantics,
            interaction: asked.interaction,
            outcome: cycleOutcome,
            reason: cycleReason,
            windows: producedScene?.windows.count,
            /* Controls, dialog items AND the Finder's own items: what a
               walk actually had to enumerate. The third term was missing
               until 2026-08-05, so a whole drive against a desktop showing
               seventeen icons measured 60 cycles of `elements 0` — the
               same omission the snapshot projection had, found in the same
               pairing. An instrument with the producer's blind spot
               cannot measure the blind spot. */
            elements: producedScene?.windows.reduce(0) {
                $0 + $1.controls.count + ($1.dialogItems?.count ?? 0)
                    + ($1.items?.count ?? 0)
            },
            phases: cyclePhases,
            ownWork: cycleOwnWork,
            contentJoin: cycleContentJoin,
            guestTimeouts: listener.commandTimeouts - cycleTimeoutsAtStart))
        lastCyclePublishedAt = published
        cycleAsked = nil
        /* Cleared with the rest of the cycle, for the reason `cyclePhases`
           is: a reason left standing would be charged to the next cycle
           that failed differently. */
        cycleReason = nil
        cyclePhases = nil
        cycleOwnWork = nil
        cycleContentJoin = nil
    }

    private func rearm() {
        guard running else { return }
        rearmTask?.cancel()
        rearmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds:
                    UInt64(self.interval * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled else { return }
            self.rearmTask = nil
            self.poll()
        }
    }

    // MARK: - Icons

    /// The scene as the guest described it, plus the icons the Finder
    /// knows about. Absence stays absence: a container never fetched
    /// carries no `items` key rather than an empty one, because "no
    /// icons here" and "nobody looked" are different facts.
    private func withIcons(_ scene: MirrorKit.Scene) -> MirrorKit.Scene {
        /* **Said on the way past, because this is the one place that
           knows.** The cycle no longer waits for the roster, so a frame
           can be published for a layout whose icons have not been read —
           and a folder window drawn with no items is indistinguishable
           from an empty folder. The layout key is exactly the question
           "was this roster read for what is on screen", so the claim is
           made from it rather than from a flag somebody has to remember
           to clear. */
        let foldersComplete = scene.windows
            .filter(FinderItems.isFolderWindow)
            .allSatisfy { window in
                guard let key = Self.finderWindowKey(window) else {
                    return false
                }
                return finderLayouts[key] == FinderItems.layoutKey(window)
            }
        shadowEngine?.noteFinderItems(complete: foldersComplete)
        var out = scene
        if let desktop = icons[Self.desktopKey] { out.desktopItems = desktop }
        out.windows = out.windows.map { win in
            guard FinderItems.isFolderWindow(win) else { return win }
            var w = win
            /* Finder P3 is permanently outside this rendering path. Even
               before the first roster page arrives, the host owns a blank
               Finder interior rather than briefly presenting cached guest
               pixels and replacing them seconds later. */
            w.display = nil
            w.displayEpoch = nil
            guard let key = Self.finderWindowKey(win),
                  let items = icons[key] else { return w }
            let now = FinderItems.scrollPosition(win)
            let captured = finderScrollOrigins[key] ?? now
            let dx = captured.x - now.x
            let dy = captured.y - now.y
            w.items = items.map { item in
                var shifted = item
                shifted.x += dx
                shifted.y += dy
                return shifted
            }
            w.finder = finderPresentations[key]
            return w
        }
        return out
    }

    private static let desktopKey = "\u{0}desktop"

    private static func finderWindowKey(_ window: MirrorKit.Scene.Window)
        -> String? {
        guard let address = window.addr else { return nil }
        return "\(window.incarnation ?? window.psn):\(address)"
    }

    private static func iconLayoutKey(_ scene: MirrorKit.Scene) -> String {
        let folders = scene.windows.filter(FinderItems.isFolderWindow)
        return (["desktop"] + folders.map(FinderItems.layoutKey))
            .joined(separator: "|")
    }

    static func desktopIconLayoutKey(_ scene: MirrorKit.Scene)
        -> String {
        /* The scene alternates between the raw resident desktop roster and
           this source's enriched roster. Including those names made each
           projection invalidate the other and reread Finder forever. */
        "\(scene.screen.w)x\(scene.screen.h)"
    }

    /// People look at the front Finder window before the desktop behind it.
    /// A Finder Apple event costs real cooperative time on the guest, so
    /// ordering is product behaviour: the visible interior must not wait for
    /// lower-priority desktop enrichment to finish first.
    static func prioritizedFinderWindows(_ scene: MirrorKit.Scene)
        -> [MirrorKit.Scene.Window] {
        scene.windows.enumerated()
            .filter { FinderItems.isFolderWindow($0.element) }
            .sorted {
                if $0.element.front != $1.element.front {
                    return $0.element.front
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// **The Finder complements are SESSION work, not cycle work.**
    ///
    /// Both of these are AppleScript to the Finder, and a Finder Apple
    /// event costs ~1–2 s of Finder time on a healthy Mac OS 9 guest (see
    /// `FinderItems`) — far more when the Finder is being starved. They
    /// used to run INSIDE the structural cycle, which held the cycle open
    /// until they had all settled, so the scene poll's period was
    /// whatever the Finder felt like today.
    ///
    /// Measured 2026-08-06 on Michelle's session, guest build
    /// `711abdbd25ec`: `decode_ms` 324 at five windows and **12,457 at
    /// six**, with a modal up starving the Finder. Nothing in this host's
    /// own decode is involved — decoding, reducing and projecting the
    /// captured six-window document costs 4 ms (`MirrorDecodeCostTests`).
    /// The whole 12.4 s was Finder round-trips held inside the bracket.
    ///
    /// And it did not merely read badly. The anchor plane's owner lease is
    /// **600 ticks — ten seconds** (`peek.c :: kNowPeekOwnerLeaseTicks`),
    /// renewed by `scene.request`. A 13-second cycle is a cycle that lets
    /// the lease expire every single time, so the same log reads
    /// `requested=15 active=8` with structure, semantics and interaction
    /// all back to `requested`, and every act that needs an anchor refuses
    /// `element-not-found: the anchor plane is absent or not armed`. The
    /// cure for that is not a longer lease; it is not going quiet.
    ///
    /// So the cycle publishes and rearms, and these run beside it. What
    /// the cycle-hold was really buying — that a roster read for one
    /// layout never lands on a different one — is bought directly instead,
    /// by re-checking the layout key at apply time, which is the actual
    /// correctness condition rather than a proxy for it.
    private func refreshComplements(_ scene: MirrorKit.Scene) {
        guard let key = pinnedGuestKey,
              finderComplementPolicy(key) else {
            iconTask?.cancel()
            iconTask = nil
            visibilityTask?.cancel()
            visibilityTask = nil
            fetchingIcons = false
            return
        }
        let run = runGeneration
        refreshIconsIfStale(scene, generation: run) { [weak self] in
            guard let self, self.isCurrentRun(run) else { return }
            self.refreshVisibilityIfStale(scene, generation: run) {}
        }
    }

    /// A complement outlives the cycle that asked for it, so it is guarded
    /// by the RUN — the pinned session — and not by `cycleGeneration`,
    /// which is nil again before any of this lands.
    private func isCurrentRun(_ generation: Int) -> Bool {
        running && runGeneration == generation
    }

    private func refreshIconsIfStale(_ scene: MirrorKit.Scene,
                                     generation: Int,
                                     completion: @escaping () -> Void) {
        if let finderRefreshOverride {
            finderRefreshOverride(scene, generation, completion)
            return
        }
        let folders = Self.prioritizedFinderWindows(scene)
        let staleFolders = folders.filter { window in
            guard let surface = Self.finderWindowKey(window) else {
                return true
            }
            return finderLayouts[surface] != FinderItems.layoutKey(window)
        }
        let desktopLayout = Self.desktopIconLayoutKey(scene)
        let desktopIsStale = desktopIconLayout != desktopLayout
        /* The leading "desktop" is not decoration. The key used to be just
           the folder windows joined, so a machine with NO Finder window
           open produced "" - which equals the initial value of iconLayout,
           so the guard never fired and the DESKTOP's own icons were never
           fetched at all. Watched: a mirror with a bare desktop drew no
           icons, ever, while every folder window drew its own. */
        let key = Self.iconLayoutKey(scene)
        guard !staleFolders.isEmpty || desktopIsStale else {
            return completion()
        }
        guard !fetchingIcons else {
            if !finderReadNoticeShown {
                finderReadNoticeShown = true
                note("Reading Finder contents; a previous complete roster "
                     + "remains visible when one exists")
            }
            return completion()
        }
        fetchingIcons = true
        finderReadNoticeShown = false
        let started = Date()
        iconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var fresh: [String: [MirrorKit.Scene.DesktopItem]] = [:]
            var presentations:
                [String: MirrorKit.Scene.FinderPresentation] = [:]
            var complete = true
            let duplicateTitles = Dictionary(grouping: folders, by: \.title)
                .filter { $0.value.count > 1 }.keys
            for win in staleFolders {
                guard !duplicateTitles.contains(win.title) else {
                    self.note("could not read Finder window \(win.title) - "
                              + "duplicate titles are ambiguous to Finder "
                              + "AppleScript; retained prior exact snapshot")
                    complete = false
                    continue
                }
                guard let surfaceKey = Self.finderWindowKey(win) else {
                    self.note("could not read Finder window \(win.title) - "
                              + "no exact WindowRecord identity")
                    complete = false
                    continue
                }
                let quoted = win.title.replacingOccurrences(of: "\"",
                                                            with: "\\\"")
                let containerStarted = Date()
                if let snapshot = await self.readFinderSurface(
                    container: "window \"\(quoted)\"",
                    generation: generation,
                    rosterReady: { [weak self] roster in
                        guard let self,
                              self.isCurrentRun(generation),
                              let current = self.scene,
                              Self.iconLayoutKey(current) == key else { return }
                        var presentation = roster.presentation
                        if !win.front {
                            presentation.selectedNames.removeAll()
                        }
                        self.icons[surfaceKey] = roster.items
                        self.finderPresentations[surfaceKey] = presentation
                        let currentWindow = current.windows.first {
                            Self.finderWindowKey($0) == surfaceKey
                        }
                        self.finderScrollOrigins[surfaceKey] =
                            FinderItems.scrollPosition(currentWindow ?? win)
                        self.publishFinderComplements(for: key)
                    }) {
                    fresh[surfaceKey] = snapshot.items
                    var presentation = snapshot.presentation
                    /* Finder's `selection` is global and describes the front
                       container. Never join those names onto a background
                       window where a same-named file would become selected. */
                    if !win.front { presentation.selectedNames.removeAll() }
                    presentations[surfaceKey] = presentation
                    self.finderLayouts[surfaceKey] =
                        FinderItems.layoutKey(win)
                    ActLog.note(
                        action: "finder snapshot\n    "
                            + BaselineLine.line("container", [
                                ("window", surfaceKey),
                                ("path", presentation.path),
                                ("view", presentation.view.rawValue),
                                ("pages", String(presentation.pages)),
                                ("items", String(snapshot.items.count)),
                                ("selected", String(
                                    presentation.selectedNames.count)),
                            ]),
                        outcome: presentation.complete ? "complete" : "partial",
                        ms: Int(Date().timeIntervalSince(containerStarted)
                            * 1000))
                } else {
                    complete = false
                }
            }
            /* Desktop enrichment is useful, but it is behind every visible
               Finder window in the latency queue. The old desktop-first
               order made Macintosh HD stay blank for nine seconds while the
               host learned about icons a person could already see behind it. */
            if desktopIsStale {
                if let d = await self.readIcons(container: "desktop",
                                                generation: generation) {
                    /* A background Finder has transiently answered with a
                       complete-looking empty desktop. Replacing a previously
                       nonempty semantic snapshot makes every icon disappear
                       until restart. Empty is accepted on the first read; it
                       cannot erase stronger retained evidence mid-session.
                       Rebuild State is the explicit way to discard it. */
                    if d.isEmpty,
                       self.icons[Self.desktopKey]?.isEmpty == false {
                        self.note("Finder reported an empty desktop while a "
                                  + "complete roster was retained; kept the "
                                  + "last complete desktop snapshot")
                        complete = false
                    } else {
                        fresh[Self.desktopKey] = d
                        self.desktopIconLayout = desktopLayout
                    }
                } else {
                    complete = false
                }
            }
            /* A canceled read can outlive a guest switch. Do not let its
               unwind clear the replacement run's in-flight bookkeeping. */
            guard !Task.isCancelled,
                  self.isCurrentRun(generation) else { return }
            self.fetchingIcons = false
            self.finderReadNoticeShown = false
            self.iconTask = nil
            ActLog.note(action: "complements\n    "
                        + BaselineLine.line("finder", [
                            ("containers", String(folders.count + 1)),
                            ("complete", complete ? "yes" : "no"),
                            ("ms", String(Int(Date()
                                .timeIntervalSince(started) * 1000))),
                        ]),
                        outcome: complete ? "ok" : "partial",
                        ms: Int(Date().timeIntervalSince(started) * 1000))
            /* Window identity and geometry must still match. Scroll is not
               part of this key: the roster is translated against the live
               scrollbar values in `withIcons`, so a scroll neither discards
               the directory nor starts another AppleScript read. */
            if let current = self.scene,
               Self.iconLayoutKey(current) != key {
                self.note("the Finder roster arrived for a layout the "
                          + "machine has already left; discarded rather "
                          + "than drawn at stale positions")
                return completion()
            }
            for (container, items) in fresh {
                self.icons[container] = items
            }
            for (container, presentation) in presentations {
                self.finderPresentations[container] = presentation
            }
            self.publishFinderComplements(for: key)
            completion()
        }
    }

    /// Publish the semantic facts already proved for this layout. This is
    /// deliberately callable before icon-art enrichment finishes: names,
    /// bounds, order and selection make a useful Finder; type/creator art is
    /// a later visual improvement and may not hold the interior blank.
    private func publishFinderComplements(for layoutKey: String) {
        guard let current = scene,
              Self.iconLayoutKey(current) == layoutKey else { return }
        let enriched = withIcons(current)
        _ = shadowEngine?.enrichFinder(enriched)
        observeOperations()
        shadowEngine?.compareVisible(enriched)
        scene = projectedScene(fallback: enriched)
    }

    /// The session engine is the visible replica owner once it exists. The
    /// fallback keeps isolated source fixtures usable when they deliberately
    /// construct no registry; production always installs one in HostAppState.
    /// Diagnostics still compare the legacy candidate before this projection
    /// is selected, so cutover drift remains inspectable without two owners
    /// competing to draw the window.
    private func projectedScene(fallback: MirrorKit.Scene) -> MirrorKit.Scene {
        Self.projectedScene(snapshot: shadowEngine?.snapshot,
                            fallback: fallback)
    }

    /// Policy is a projection switch as well as a resident claim. The state
    /// engine keeps every plane, so this can redraw immediately from retained
    /// evidence while the next ordinary poll performs any guest arm/release.
    func planePolicyDidChange() {
        guard let key = pinnedGuestKey, let engine = shadowEngine else { return }
        let changed = engine.setEnabledPlanes(planePolicy(key))
        if changed, let projected = engine.snapshot?.scene { scene = projected }
        guard running else { return }
        if cycleGeneration != nil {
            pollRequestedAfterCycle = true
            return
        }
        rearmTask?.cancel()
        rearmTask = nil
        poll()
    }

    private func observeOperations() {
        guard let engine = shadowEngine else { return }
        mutationBroker?.observe(engine.settlementEvidence())
    }

    static func projectedScene(snapshot: MirrorProjection?,
                               fallback: MirrorKit.Scene) -> MirrorKit.Scene {
        snapshot?.scene ?? fallback
    }

    /// Vectorised, bounded pages rather than one Apple event per icon. A
    /// single all-items result exceeded the guest's 1 KiB script-result cap
    /// in Control Panels and silently lost later rows such as Date & Time.
    /// Sixteen ordinary HFS names plus positions/kinds fit below that bound;
    /// an unusually long page retries at the measured-safe eight rows. Every
    /// page carries the same total so a partial read is refused.
    nonisolated private static let iconPageSize = 16
    nonisolated private static let iconFallbackPageSize = 8

    /// **`bounds of`, not `position of`** — the whole of the list-view defect.
    ///
    /// `position` is the Finder's live layout in an ICON view and the SAVED
    /// icon grid in a list view, and this script had no idea which it was
    /// looking at. So a window drawing ten rows at a 19-px pitch reported ten
    /// icons on a three-column grid, every rect was wrong, and nothing could
    /// be selected — Michelle's "unable to select items in list view".
    ///
    /// `bounds` is the box the Finder actually drew, in every view, and it
    /// carries the position as its top-left; there is nothing `position`
    /// answered that this does not. Measured 2026-08-07 on mac99 / OS 9.1
    /// against a screendump — the full table is in `FinderItems`'s header,
    /// along with the `view of window` vocabulary that was measured in the
    /// same pass and is deliberately NOT read here.
    static func iconItemsScript(container: String, offset: Int,
                                limit: Int = iconPageSize) -> String {
        """
        tell application "Finder"
        set viewWord to ""
        set containerPath to ""
        set selectedNames to {}
        try
        set viewWord to view of \(container)
        end try
        try
        set containerPath to (item of \(container)) as text
        end try
        try
        set selectedNames to name of every item of selection
        end try
        set ns to name of every item of \(container)
        set ps to bounds of every item of \(container)
        set ks to kind of every item of \(container)
        end tell
        set totalCount to count ns
        set out to "N" & tab & totalCount & return & "V" & tab & viewWord & \
        return & "P" & tab & containerPath & return
        set firstIndex to \(offset + 1)
        set lastIndex to \(offset + limit)
        if lastIndex > totalCount then set lastIndex to totalCount
        if firstIndex <= lastIndex then
        repeat with i from firstIndex to lastIndex
        set p to item i of ps
        set chosen to selectedNames contains (item i of ns)
        set out to out & "I" & tab & (item i of ns) & tab & (item 1 of p) & \
        tab & (item 2 of p) & tab & (item 3 of p) & tab & (item 4 of p) & \
        tab & (item i of ks) & tab & chosen & return
        end repeat
        end if
        return out
        """
    }

    /// Type/creator enrichment is paged independently from geometry. It is
    /// cached by directory path, so changing a Finder view can redraw from the
    /// roster immediately instead of repeating this slower Apple event.
    static func iconTypesScript(container: String, offset: Int,
                                limit: Int) -> String {
        """
        tell application "Finder"
        set fs to every file of \(container)
        set totalCount to count fs
        set out to "N" & tab & totalCount & return
        set firstIndex to \(offset + 1)
        set lastIndex to \(offset + limit)
        if lastIndex > totalCount then set lastIndex to totalCount
        if firstIndex <= lastIndex then
        repeat with i from firstIndex to lastIndex
        set f to item i of fs
        set out to out & "F" & tab & (name of f) & tab & (file type of f) & \
        tab & (creator type of f) & tab & "" & return
        end repeat
        end if
        end tell
        return out
        """
    }

    struct FinderSurfaceRead {
        var items: [MirrorKit.Scene.DesktopItem]
        var presentation: MirrorKit.Scene.FinderPresentation
    }

    func readIcons(container: String, generation: Int? = nil)
        async -> [MirrorKit.Scene.DesktopItem]? {
        await readFinderSurface(container: container, generation: generation)?
            .items
    }

    func readFinderSurface(container: String, generation: Int? = nil)
        async -> FinderSurfaceRead? {
        await readFinderSurface(container: container, generation: generation,
                                rosterReady: nil)
    }

    func readFinderSurface(
        container: String, generation: Int? = nil,
        rosterReady: (@MainActor (FinderSurfaceRead) -> Void)?
    )
        async -> FinderSurfaceRead? {
        /* Two vectorised passes, not one per icon. The first names every
           item and where the Finder drew it; the second asks the FILES
           for their type and creator, which is what picks the real icon
           out of the atlas - without them every document, application
           and control panel renders as the same generic page, which is
           what the mirror did until this was measured against a
           screenshot of the machine.

           Files only, deliberately: `file type of` a folder or a disk is
           an error that fails the whole script, and their kind already
           chooses the right art.

           The two passes are two SCRIPTS, not one, because AppleScript
           fails a script whole. Fused, any error in the type pass took
           the names and positions down with it and the window rendered
           as an empty box - which is what Macintosh HD did for an entire
           drive while Control Panels beside it drew 33 items. Losing the
           right icon art is a blemish; losing the contents is not a
           mirror. */
        var roster: [MirrorKit.Scene.DesktopItem] = []
        var expectedTotal: Int?
        var expectedPath: String?
        var expectedView: MirrorKit.Scene.FinderPresentation.View?
        var selectedNames = Set<String>()
        var pages = 0
        var offset = 0
        var pageSize = Self.iconPageSize
        while expectedTotal == nil || offset < expectedTotal! {
            guard complementIsCurrent(generation) else { return nil }
            let source = Self.iconItemsScript(container: container,
                                              offset: offset,
                                              limit: pageSize)
            /* `osaFailureIsAnError` because THIS pass is the one that must
               succeed. A script that raises answers `ok: true` with an
               empty output row and its reason in `osaErr`; without the
               opt-in that code was read, matched and then thrown away, so
               the empty answer fell through to the roster guard and every
               failure - a raise, a refusal, a Finder that cannot name its
               own desktop - reported "incomplete or changing item roster".
               `desktopItems` has never read on any drive and that sentence
               is all the mirror ever said about why. */
            let read = await readingFinderComplement(
                source, osaFailureIsAnError: true)
            guard complementIsCurrent(generation) else { return nil }
            let total = read.value.flatMap(Self.iconPageTotal)
            /* Sixteen compact rows fit ordinary folders in one or two guest
               turns. A directory with unusually long names may cross the
               measured 1 KiB result cap; retry that same page at the proven
               eight-row size rather than trading safety for speed. */
            if read.truncated && pageSize > Self.iconFallbackPageSize {
                pageSize = Self.iconFallbackPageSize
                continue
            }
            guard let text = read.value, !read.truncated, let total,
                  expectedTotal == nil || expectedTotal == total,
                  total <= FinderItems.maxItemsPerWindow else {
                note("could not read the items of \(container) - "
                     + Self.rosterPageRefusal(error: read.error,
                                              truncated: read.truncated,
                                              total: total,
                                              expected: expectedTotal))
                return nil
            }
            expectedTotal = total
            let metadata = Self.finderPageMetadata(text)
            if let expectedPath, expectedPath != metadata.path { return nil }
            if let expectedView, expectedView != metadata.view { return nil }
            expectedPath = metadata.path
            expectedView = metadata.view
            selectedNames.formUnion(metadata.selectedNames)
            pages += 1
            let page = Self.parseIcons(text)
            let expectedCount = min(pageSize, total - offset)
            guard page.count == expectedCount else {
                note("could not read the items of \(container) - page "
                     + "\(pages) was incomplete")
                return nil
            }
            roster.append(contentsOf: page)
            offset += page.count
            rosterReady?(.init(
                items: roster,
                presentation: .init(
                    path: expectedPath ?? "",
                    view: expectedView ?? .unknown,
                    selectedNames: selectedNames,
                    pages: pages,
                    complete: offset >= total)))
            if total == 0 { break }
        }

        let semantic = FinderSurfaceRead(
            items: roster,
            presentation: .init(path: expectedPath ?? "",
                                view: expectedView ?? .unknown,
                                selectedNames: selectedNames,
                                pages: pages, complete: true))

        let artPath = semantic.presentation.path.isEmpty
            ? container : semantic.presentation.path
        var typesByName = finderArtByPath[artPath] ?? [:]
        if !finderArtCompletePaths.contains(artPath) {
            var artOffset = 0
            var artTotal: Int?
            var artComplete = true
            while artTotal == nil || artOffset < artTotal! {
                guard complementIsCurrent(generation) else { return nil }
                let read = await readingFinderComplement(
                    Self.iconTypesScript(container: container,
                                         offset: artOffset,
                                         limit: Self.iconFallbackPageSize))
                guard complementIsCurrent(generation) else { return nil }
                guard let value = read.value, !read.truncated,
                      let total = Self.iconPageTotal(value) else {
                    note("\(container): items read, but not all icon art - "
                         + (read.truncated ? "guest result truncated"
                            : (read.error ?? "no reason given")))
                    artComplete = false
                    break
                }
                artTotal = total
                let page = Self.parseIconTypes(value)
                for (name, type) in page { typesByName[name] = type }
                artOffset += page.count
                if total == 0 { break }
                if page.isEmpty { artComplete = false; break }
            }
            finderArtByPath[artPath] = typesByName
            if artComplete { finderArtCompletePaths.insert(artPath) }
        }

        /* THE THIRD PASS, and its own script for the second pass's reason.
           An alias whose original is on an unmounted volume raises, and
           AppleScript fails a script whole - fused with the type pass, one
           stale alias on the desktop would cost every item its icon art.
           Each resolution is also wrapped individually, so one bad alias
           costs only itself. */
        let aliases = roster.filter(\.alias).map(\.name)
        var targetsByName: [String: MirrorKit.Scene.DesktopItem.AliasTarget] = [:]
        if !aliases.isEmpty {
            guard complementIsCurrent(generation) else { return nil }
            let read = await readingFinderComplement(
                Self.aliasTargetsScript(container: container))
            guard complementIsCurrent(generation) else { return nil }
            if read.value == nil || read.truncated {
                note("\(container): \(aliases.count) alias(es) read, but not "
                     + "what they point at - "
                     + "\(read.truncated ? "guest result truncated" : "\(read.error ?? "no reason given")")")
            }
            targetsByName = Dictionary(
                Self.parseAliasTargets(read.truncated ? ""
                                       : (read.value ?? "")),
                uniquingKeysWith: { first, _ in first })
        }
        return FinderSurfaceRead(
            items: Self.applyingArt(roster, types: typesByName,
                                    aliasTargets: targetsByName),
            presentation: semantic.presentation)
    }

    static func finderPageMetadata(_ raw: String)
        -> (path: String, view: MirrorKit.Scene.FinderPresentation.View,
            selectedNames: Set<String>) {
        let text = unquote(raw)
        var path = ""
        var view: MirrorKit.Scene.FinderPresentation.View = .unknown
        var selected = Set<String>()
        for line in text.components(separatedBy: CharacterSet.newlines) {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2 else { continue }
            switch f[0] {
            case "P": path = f[1]
            case "V": view = .init(rawValue: f[1]) ?? .unknown
            case "I" where f.count >= 8:
                if f[7].lowercased() == "true" { selected.insert(f[1]) }
            default: break
            }
        }
        return (path, view, selected)
    }

    private func complementIsCurrent(_ generation: Int?) -> Bool {
        guard !Task.isCancelled else { return false }
        return generation.map(isCurrentRun) ?? true
    }

    /// What every alias in a container points at.
    ///
    /// `original item` is the Finder's own resolution, so it follows a
    /// renamed or moved target the way a double-click does. It raises for
    /// a broken alias and for one whose volume is not mounted, which is
    /// why every row is wrapped: a missing row means "unresolved", and
    /// unresolved keeps the old prediction rather than inventing one.
    static func aliasTargetsScript(container: String) -> String {
        """
        tell application "Finder"
        set out to ""
        repeat with a in (every alias file of \(container))
        try
        set t to original item of a
        set out to out & "A" & tab & (name of a) & tab & (name of t) & tab & \
        (file type of t as string) & tab & (creator type of t as string) & \
        tab & (kind of t) & return
        end try
        end repeat
        end tell
        return out
        """
    }

    /// The alias pass, parsed from its OWN blob for `parseIconTypes`'
    /// reason: each script answers in source form and carries its own
    /// quotes.
    static func parseAliasTargets(_ raw: String)
        -> [(String, MirrorKit.Scene.DesktopItem.AliasTarget)] {
        let text = unquote(raw)
        return text.components(separatedBy: CharacterSet.newlines)
            .compactMap { line in
                let f = line.components(separatedBy: "\t")
                guard f.count >= 6, f[0] == "A", !f[1].isEmpty else {
                    return nil
                }
                let kind = f[5].lowercased()
                return (f[1], .init(
                    name: f[2],
                    kind: kind.contains("folder") ? "folder"
                        : kind.contains("disk") ? "disk"
                        : kind.contains("application") ? "application"
                        : "file",
                    type: osType(fromAppleScript: f[3]),
                    creator: osType(fromAppleScript: f[4])))
            }
    }

    /// The item roster and the type pass, joined by name — the one place a
    /// file's type and creator are attached to the icon that will be drawn
    /// with them.
    static func applyingArt(
        _ items: [MirrorKit.Scene.DesktopItem],
        types: [String: (String, String)],
        aliasTargets: [String: MirrorKit.Scene.DesktopItem.AliasTarget] = [:])
        -> [MirrorKit.Scene.DesktopItem] {
        items.map { item in
            var out = item
            if let pair = types[item.name] {
                out.type = osType(fromAppleScript: pair.0)
                out.creator = osType(fromAppleScript: pair.1)
            }
            /* Only onto an item the ROSTER called an alias. The alias pass
               asks the Finder for `every alias file`, and joining its rows
               onto anything else would let a name collision give a plain
               document a target it does not have. */
            if item.alias { out.aliasTarget = aliasTargets[item.name] }
            return out
        }
    }

    /// One AppleScript-rendered *type class*, back to the four-character
    /// OSType it names — `«class APPL»` → `APPL`, `string` → `TEXT`.
    ///
    /// The Finder's `file type` and `creator type` are `type class` values,
    /// not text, and the script concatenates them into its output line with
    /// `&`. AppleScript coerces them the only way it knows: to its own
    /// SOURCE rendering. So the wire carried `«class APPL»`, the host took
    /// the first four characters, and every icon on every desktop reported a
    /// type of `«cla` — which names no file type at all. It cost icon ART
    /// rather than contents, which is why nothing ever failed over it, and
    /// why it survived long enough to be found twice.
    ///
    /// Note what this is NOT: the mangling is inside the string the guest
    /// built, so it is not `OSADoScript`'s source-form result and asking the
    /// guest for a different result form would change nothing. The two real
    /// cures are this one and making the script hand back four characters
    /// itself; this one is chosen first because it needs no guest rebuild
    /// and can be proven against the roster fixture already committed, and
    /// the other is in the ledger because it cannot be proven from here.
    ///
    /// Unrecognised renderings answer **nil**, never a guess. A wrong OSType
    /// is a wrong icon confidently drawn; nil is the generic-by-kind art the
    /// mirror already falls back to.
    static func osType(fromAppleScript raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        /* `«class APPL»`, and the `«constant ...»` an enumerated value
           renders as. The code is always the last space-separated word. */
        if text.hasPrefix("«"), text.hasSuffix("»") {
            let inner = text.dropFirst().dropLast()
            guard let code = inner.components(separatedBy: " ").last,
                  code.count == 4 else { return nil }
            return code
        }
        /* AppleScript renders a code it has a WORD for as that word, and its
           vocabulary is every registered term, not just the type names — the
           OS 9 desktop this was measured on answered `text returned` for
           SimpleText's `ttxt`. So this table cannot be closed by
           construction; it inverts the renderings that are reachable as a
           file's type or creator, and anything else falls through to nil. */
        if let code = appleScriptTypeWords[text] { return code }
        /* Already four characters: a guest that learns to coerce properly
           passes through unharmed. */
        return text.count == 4 ? text : nil
    }

    /// AppleScript's own word for a four-character code, inverted. Every
    /// entry is a rendering that can appear as a file's type or creator on a
    /// Mac OS 8/9 desktop; `TEXT` and `ttxt` alone cover most documents.
    nonisolated private static let appleScriptTypeWords: [String: String] = [
        "string": "TEXT",
        "text": "TEXT",
        "styled text": "styl",
        "Unicode text": "utxt",
        "international text": "itxt",
        "picture": "PICT",
        "alias": "alis",
        "text returned": "ttxt",
        "version": "vers",
        "script": "scpt",
        "boolean": "bool",
        "integer": "long",
        "small integer": "shor",
        "real": "doub",
        "small real": "sing",
        "date": "ldt ",
        "data": "rdat",
        "list": "list",
        "record": "reco",
        "constant": "enum",
        "type class": "type",
    ]

    /// Why a roster page was refused, in the guest's OWN words wherever it
    /// gave any.
    ///
    /// Five distinct failures used to share one sentence — "incomplete or
    /// changing item roster" — which is the truth of exactly one of them.
    /// A raised script, a Finder that cannot name its desktop, a reply this
    /// side could not parse and a container over the cap all read the same
    /// from the host, so `desktopItems` failing on every drive since it
    /// shipped has produced no information at all about the cause. The
    /// generic line survives only for the case it describes: a total this
    /// side agreed with, pages that would not add up to it.
    static func rosterPageRefusal(error: String?, truncated: Bool,
                                  total: Int?, expected: Int?) -> String {
        /* The guest's reason outranks the shape of its answer: a truncated
           reply to a script that RAISED is truncated because it is empty. */
        if let error { return error }
        if truncated { return "guest result truncated" }
        guard let total else {
            return "the guest answered without an item total"
        }
        if let expected, expected != total {
            return "the item count changed mid-read "
                + "(\(expected), then \(total))"
        }
        if total > FinderItems.maxItemsPerWindow {
            return "\(total) items is past the "
                + "\(FinderItems.maxItemsPerWindow)-item cap"
        }
        return "incomplete or changing item roster"
    }

    static func iconPageTotal(_ raw: String) -> Int? {
        let text = unquote(raw)
        for line in text.components(separatedBy: CharacterSet.newlines) {
            let fields = line.components(separatedBy: "\t")
            if fields.count == 2, fields[0] == "N" {
                return Int(fields[1])
            }
        }
        return nil
    }

    // MARK: - Retained process visibility

    nonisolated private static let visibilityPageSize = 8

    /// `visible` must be bound to a variable before it is concatenated. Read
    /// inline, the Finder hands back an object specifier rather than the
    /// boolean, and `&` refuses it — measured on Mac OS 9.1 (mac99,
    /// 2026-08-05): `-1700 Can't make visible of «class prcs» "tbt-worker"
    /// of application "Finder" into a string`. The error aborts the whole
    /// script, so the census returned NO rows at all and every process read
    /// `visible: null` while the coverage claim said only that the census
    /// "did not uniquely cover every application" — a total failure wearing
    /// the same words as a partial one. `set vis to ...` forces the
    /// specifier to resolve; the same read then coerces.
    static func visibilityScript(offset: Int,
                                 limit: Int = visibilityPageSize) -> String {
        """
        tell application "Finder"
        set ps to every application process
        set totalCount to count ps
        set out to "N" & tab & totalCount & return
        set firstIndex to \(offset + 1)
        set lastIndex to \(offset + limit)
        if lastIndex > totalCount then set lastIndex to totalCount
        if firstIndex <= lastIndex then
        repeat with i from firstIndex to lastIndex
        set candidate to item i of ps
        set nm to name of candidate
        set vis to visible of candidate
        set out to out & "V" & tab & nm & tab & (vis as string) & return
        end repeat
        end if
        end tell
        return out
        """
    }

    static func parseVisibility(_ raw: String)
        -> (total: Int?, byName: [String: Bool], rowCount: Int,
            unique: Bool) {
        let text = unquote(raw)
        var total: Int?
        var byName: [String: Bool] = [:]
        var rowCount = 0
        var unique = true
        for line in text.components(separatedBy: CharacterSet.newlines) {
            let fields = line.components(separatedBy: "\t")
            if fields.count == 2, fields[0] == "N" {
                total = Int(fields[1])
            } else if fields.count == 3, fields[0] == "V" {
                let normalized = fields[2].lowercased()
                guard normalized == "true" || normalized == "false" else {
                    continue
                }
                rowCount += 1
                if byName[fields[1]] != nil { unique = false }
                byName[fields[1]] = normalized == "true"
            }
        }
        return (total, byName, rowCount, unique)
    }

    /// **A census the machine has not changed is not evidence, it is
    /// spending.**
    ///
    /// This ran on EVERY poll — several Finder Apple events, four times a
    /// second on a cooperative Mac OS 9 guest, for an answer that changes
    /// only when an application starts, quits, hides or shows. The icon
    /// roster beside it has been keyed against its own staleness since it
    /// was written; this one never was, and it is the only unconditional
    /// multi-round-trip in the lane.
    ///
    /// Two triggers, because the two ways the answer changes are not
    /// alike. A roster change (a process appeared or went away) is visible
    /// in the scene the guest just sent, so it refreshes at once. A
    /// hide/show leaves the roster identical and is invisible until we
    /// ask — so a floor interval asks anyway, and an act that MEANT to
    /// change visibility marks the census dirty (`invalidateVisibility`)
    /// rather than waiting for the floor.
    private static let visibilityFloor: TimeInterval = 3

    private func visibilityRosterKey(_ scene: MirrorKit.Scene) -> String {
        scene.apps.map { "\($0.psn)/\($0.name)" }.sorted()
            .joined(separator: "|")
    }

    /// The next census must actually go to the guest: an act has just
    /// tried to change what this measures, and a cached answer would
    /// report the machine as it was before the act.
    func invalidateVisibility() {
        visibilityKey = "<dirty>"
        visibilityReadAt = nil
    }

    private func refreshVisibilityIfStale(_ scene: MirrorKit.Scene,
                                          generation: Int,
                                          completion: @escaping () -> Void) {
        let key = visibilityRosterKey(scene)
        let aged = visibilityReadAt.map {
            Date().timeIntervalSince($0) >= Self.visibilityFloor
        } ?? true
        guard key != visibilityKey || aged else { return completion() }
        visibilityKey = key
        visibilityReadAt = Date()
        refreshVisibility(scene, generation: generation,
                          completion: completion)
    }

    private func refreshVisibility(_ scene: MirrorKit.Scene,
                                   generation: Int,
                                   completion: @escaping () -> Void) {
        if let visibilityRefreshOverride {
            visibilityRefreshOverride(scene, generation, completion)
            return
        }
        let started = Date()
        visibilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var observed: [String: Bool] = [:]
            var expectedTotal: Int?
            var offset = 0
            var complete = true
            while expectedTotal == nil || offset < expectedTotal! {
                guard self.complementIsCurrent(generation) else { return }
                let read = await self.readingFinderComplement(
                    Self.visibilityScript(offset: offset),
                    osaFailureIsAnError: true)
                guard self.complementIsCurrent(generation) else { return }
                if let error = read.error {
                    self.note("visibility census refused at offset "
                              + "\(offset): \(error)")
                }
                let page = read.value.map(Self.parseVisibility)
                guard !read.truncated, read.error == nil,
                      let page, let total = page.total,
                      expectedTotal == nil || expectedTotal == total,
                      page.unique,
                      page.rowCount == min(Self.visibilityPageSize,
                                           total - offset) else {
                    complete = false
                    break
                }
                expectedTotal = total
                for (name, visible) in page.byName {
                    if observed[name] != nil { complete = false }
                    observed[name] = visible
                }
                offset += page.rowCount
                if total == 0 { break }
            }
            /* A canceled read can outlive a guest switch. Do not let its
               unwind clear the replacement run's task reference. */
            guard !Task.isCancelled,
                  self.isCurrentRun(generation) else { return }
            self.visibilityTask = nil
            ActLog.note(action: "complements\n    "
                        + BaselineLine.line("visibility", [
                            ("processes", expectedTotal.map(String.init)
                                ?? "-"),
                            ("complete", complete ? "yes" : "no"),
                            ("ms", String(Int(Date()
                                .timeIntervalSince(started) * 1000))),
                        ]),
                        outcome: complete ? "ok" : "partial",
                        ms: Int(Date().timeIntervalSince(started) * 1000))
            _ = self.shadowEngine?.enrichVisibility(
                observed, complete: complete
                    && observed.count == expectedTotal,
                sequence: scene.seq)
            self.scene = self.projectedScene(fallback: scene)
            self.observeOperations()
            completion()
        }
    }

    /// OSADoScript's SOURCE-form wrapper, removed once.
    static func unquote(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else {
            return raw
        }
        return String(raw.dropFirst().dropLast())
    }

    /// OSADoScript renders its result in SOURCE form, so a text result
    /// arrives wrapped in quotes and its lines are separated by CR -
    /// classic AppleScript's terminator, and the reason `linefeed` is not
    /// used to build it (that identifier does not exist in OS 9's
    /// AppleScript and fails the whole script with osaErr -1753).
    /// One roster row, with the Finder's kind string reduced to the four
    /// words `Scene.DesktopItem.kind` is allowed to hold.
    static func rosterItem(name: String, kind rawKind: String,
                           x: Int, y: Int, w: Int?, h: Int?)
        -> MirrorKit.Scene.DesktopItem {
        let kind = rawKind.lowercased()
        return .init(
            name: name,
            kind: kind.contains("folder") ? "folder"
                : kind.contains("disk") ? "disk"
                : kind.contains("application") ? "application" : "file",
            type: nil, creator: nil,
            x: x, y: y, placed: true,
            alias: kind.contains("alias"), invisible: false,
            w: w, h: h)
    }

    static func parseIcons(_ raw: String) -> [MirrorKit.Scene.DesktopItem] {
        let text = unquote(raw)
        var items: [MirrorKit.Scene.DesktopItem] = []
        var types: [String: (String, String)] = [:]

        for line in text.components(separatedBy: CharacterSet.newlines)
        where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5 else { continue }
            switch f[0] {
            case "I":
                /* Seven fields since the roster moved to `bounds`: name,
                   l, t, r, b, kind. A five-field row is an older capture
                   carrying a bare position, and is still read — with no
                   size, which every reader answers with the 32x32 it used
                   to assume. A row that is neither is a partial read and
                   is dropped rather than half-believed. */
                guard f.count >= 7, let l = Int(f[2]), let t = Int(f[3]),
                      let r = Int(f[4]), let b = Int(f[5]) else {
                    guard let x = Int(f[2]), let y = Int(f[3]) else { continue }
                    items.append(Self.rosterItem(name: f[1], kind: f[4],
                                                 x: x, y: y, w: nil, h: nil))
                    continue
                }
                items.append(Self.rosterItem(name: f[1], kind: f[6],
                                             x: l, y: t,
                                             w: r - l, h: b - t))
            case "F":
                /* The Finder answers with the type as a `type class`, which
                   reaches the wire as AppleScript's rendering of it rather
                   than as four characters - `osType(fromAppleScript:)` is
                   where that is undone. A file whose type is unset comes
                   back empty rather than absent, which is a real answer,
                   and the atlas treats it as one. */
                types[f[1]] = (f[2], f[3])
            default:
                continue
            }
        }
        return applyingArt(items, types: types)
    }

    /// The type pass on its own, unquoted before anything is joined to it.
    ///
    /// It must be parsed from its OWN blob. Appending it to a page's output
    /// and parsing the pair together leaves the page's closing quote and the
    /// type pass's opening quote inside the text, so the first `F` row reads
    /// as `"F` and is silently dropped — one desktop item losing its art with
    /// nothing to show for it.
    static func parseIconTypes(_ raw: String)
        -> [(String, (String, String))] {
        let text = unquote(raw)
        return text.components(separatedBy: CharacterSet.newlines)
            .compactMap { line in
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 4, fields[0] == "F" else { return nil }
                return (fields[1], (fields[2], fields[3]))
            }
    }

    // MARK: - The dispatch

    private func pinnedActionRefusal() -> String? {
        guard let pinnedGuestKey else {
            return "The Mirror has no pinned Mac. Start it before acting."
        }
        guard pinnedGuestKey == listener.activeKey else {
            return "The Mirror is pinned to \(pinnedGuestKey.machine.slug); "
                + "select that Mac before acting."
        }
        return nil
    }

    func note(_ message: String) {
        /* Notes are the things that happened INSTEAD of an act, so they
           belong in the act log beside the acts - a drag that was never
           sent is exactly as important as one that was refused. */
        ActLog.note(action: "(note)", outcome: message, ms: 0)
        report(message)
    }

    /// Say it, and keep saying it for long enough to be read. Four
    /// seconds is about how long a person takes to look down after a
    /// click that did not do what they expected.
    private func report(_ message: String) {
        guard !message.isEmpty else { return }
        lastAct = message
        actGeneration += 1
        let mine = actGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.actGeneration == mine else { return }
            self.lastAct = ""
        }
    }

    /// **The object-first entry point.** A person acted on a THING; this
    /// decides what that means and sends it.
    ///
    /// It overrides the protocol's default rather than using it, for one
    /// reason: the default expresses a plan in the action vocabulary, and
    /// no action case can name a file. `finderSelect` and `finderOpen`
    /// are the whole argument for objects, and they are served here.
    func perform(_ interaction: Interaction) {
        _ = perform(interaction, source: .human)
    }

    /// **The press feedback's answer, and the half of it this side can give.**
    ///
    /// `LiveMirrorView` draws a button pressed from the gesture onward and
    /// needs something to end that drawing. The protocol's default never
    /// answers, so every press would run to `PressSession.patience` and
    /// report that it never learned — honest, but a poor answer for the
    /// cases this side settles immediately.
    ///
    /// **Refusals are answered here; confirmations are not, and that
    /// asymmetry is deliberate rather than unfinished.** A `.refused`
    /// disposition means nothing reached the guest and nothing is coming —
    /// the sentence is already the whole truth, so the button comes back up
    /// at once with the reason beside it. The other three dispositions all
    /// mean the act LEFT, and none of them is evidence that it worked:
    /// `.direct` is dispatched with no typed postcondition and *nothing will
    /// ever settle it*, `.held` has a record still coming, and `.brokered`
    /// settles later through the broker's lane. Answering `.confirmed` for
    /// any of them would be reporting dispatch as success, which is the exact
    /// shape of the AppleScript lie this whole surface replaced.
    ///
    /// So a press that reaches the guest currently ends at the deadline,
    /// saying we asked and never learned. That is the true state of this
    /// side's knowledge today; routing the broker's settlement back into
    /// `PressAnswer.confirmed` is the follow-on, and it is the same missing
    /// plumbing `ItemDragDriver` is waiting on (docs/open-issues.md).
    func perform(_ interaction: Interaction,
                 answer: @escaping (PressAnswer) -> Void) {
        let disposition = perform(interaction, source: .human)
        if let why = disposition.refusal { answer(.refused(why)) }
    }

    /// The one dispatch path, with the face that asked for it. `MirrorKit`'s
    /// `MirrorSceneSource` conformance above is the gesture door; this is the
    /// same door with the caller named.
    ///
    /// **It answers what it DID, because the two faces do not hear the
    /// same things.** A person reads `report` on the Mirror's status line
    /// and watches the screen; a headless caller has neither and gets only
    /// this value. It used to be `String?` — a sentence when the act never
    /// left, and `nil` otherwise — and `nil` covered three unrelated
    /// endings that `MirrorDriveService` then had to guess between by
    /// looking for a broker record. Both faces' 2026-08-05 defects were
    /// that guess being wrong:
    ///
    /// - `finderOpen` at a guest whose interaction plane had never armed
    ///   logged `NOT DISPATCHED: Interaction policy is off` and answered
    ///   MCP `dispatched`. Fixed by returning the sentence at all.
    /// - A `finderOpen` that arrived mid-observation was HELD, so no
    ///   record existed yet, and the same absence was read as the direct
    ///   path: MCP was told `id: "direct"` — never settles, stop waiting —
    ///   for an act that went on to settle `confirmed`. That is this type.
    @discardableResult
    func perform(_ interaction: Interaction,
                 source: MirrorOperationSource) -> MirrorPerformDisposition {
        if let refusal = pinnedActionRefusal() {
            let label = InteractionBridge.label(for: interaction)
            ActLog.note(action: label,
                        outcome: "NOT DISPATCHED: \(refusal)", ms: 0)
            report(refusal)
            return .refused(refusal)
        }
        guard currentPlanePolicy.contains(.interaction) else {
            let label = InteractionBridge.label(for: interaction)
            let why = "Interaction is off; the Mirror is read-only."
            ActLog.note(action: label,
                        outcome: "NOT DISPATCHED: Interaction policy is off",
                        ms: 0)
            report("\(label): \(why)")
            return .refused(why)
        }
        let plan = InteractionPolicy.plan(for: interaction, planes: planes)
        switch plan {
        case .nothing(let why):
            /* Not a failure, and not silence either. A click on something
               inert still has to LOOK like it was seen, or a person
               concludes the mirror is dead. */
            ActLog.note(action: InteractionBridge.label(for: interaction),
                        outcome: "NOT DISPATCHED (nothing): \(why)", ms: 0)
            report(why)
            return .refused(why)
        case .unsupported(let why):
            ActLog.note(action: InteractionBridge.label(for: interaction),
                        outcome: "NOT DISPATCHED (unsupported): \(why)", ms: 0)
            report("\(InteractionBridge.label(for: interaction)): \(why)")
            return .refused(why)
        default:
            let label = InteractionBridge.label(for: interaction)
            if let engine = shadowEngine,
               let operation = MirrorActionExecutor.operation(
                    for: interaction, plan: plan, engine: engine,
                    source: source),
               let mutationBroker {
                if pending {
                    mutationWaiting = true
                    report(label + " — queued behind the current observation")
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        while self.pending {
                            try? await Task.sleep(nanoseconds: 25_000_000)
                        }
                        self.mutationWaiting = false
                        /* **Carry the face through the wait.** This called
                           the one-argument overload, which defaults to
                           `.human` — so an MCP act that happened to arrive
                           while an observation was in flight was journalled
                           as a person's, undoing the 2026-08-05 fix by a
                           path older than it. Caught live the same day: an
                           `finderOpen` driven entirely over the agent
                           socket settled `confirmed` and recorded
                           `source: human`. The journal is what tells a
                           hand-driven act from an agent-driven one after
                           the fact, and this was the only act in it. */
                        _ = self.perform(interaction, source: source)
                    }
                    /* Held, not refused — it re-enters this door when the
                       observation clears, and the caller has an operation
                       coming. **Saying so is the whole of the second
                       2026-08-05 defect.** This returned `nil`, which the
                       drive service could only read as "no record
                       appeared, so it took the direct path" — and told MCP
                       `id: "direct"`, meaning *nothing will ever settle
                       this, stop waiting*. The act it said that about
                       settled `confirmed` a few seconds later. */
                    return .held
                }
                report(label + " — queued")
                let accepted = mutationBroker.enqueue(operation,
                                                      label: label,
                                                      execute: {
                    [weak self] in
                    guard let self else {
                        return .init(complaint: "the Mirror closed",
                                     effectMayHaveLanded: false)
                    }
                    /* **The picture was old, and by now the host knows
                       it.** A person clicks a scene up to a poll old, and
                       an act that queued behind others dispatches seconds
                       later — by which time newer scenes have arrived. If
                       the target is not in the newest one, sending it
                       would spend a round trip to be told what this side
                       can already see, and the guest's refusal would then
                       be one more thing to attribute. Refuse here
                       instead, and say which half moved. */
                    if let stale = self.staleTargetComplaint(for: plan) {
                        ActLog.note(action: "attempt \(label)  plan=\(plan)",
                                    outcome: "NOT DISPATCHED: \(stale)",
                                    ms: 0)
                        return .init(complaint: stale,
                                     effectMayHaveLanded: false)
                    }
                    let started = Date()
                    let complaint = await self.serve(plan)
                    ActLog.note(action: "attempt \(label)  plan=\(plan)",
                                outcome: complaint ?? self.planSettlement,
                                ms: Int(Date().timeIntervalSince(started)
                                    * 1000))
                    return .init(
                        complaint: complaint,
                        effectMayHaveLanded: Self.effectMayHaveLanded(
                            complaint: complaint,
                            reach: self.planRefusalReach))
                }, report: { [weak self] operation, complaint in
                    self?.reportOperation(operation, label: label,
                                          complaint: complaint)
                })
                actTimeline.depth = mutationBroker.depth
                if !accepted {
                    let full = "not dispatched: operation journal full"
                    report(label + " — " + full)
                    return .refused(full)
                }
                /* The broker appended synchronously, so this id is already
                   in the journal — the caller can read the record rather
                   than search for one that resembles what it asked for. */
                return .brokered(operation.id)
            }
            if shadowEngine != nil,
               MirrorActionExecutor.requiresTypedSettlement(
                    for: interaction, plan: plan) {
                let reason = "the displayed guest state has no stable identity "
                    + "for this operation; it was not sent"
                ActLog.note(action: "unresolved \(label)  plan=\(plan)",
                            outcome: "NOT DISPATCHED: \(reason)", ms: 0)
                report(label + " — " + reason)
                return .refused(reason)
            }
            /* The same re-read the brokered path makes, for the acts that
               never queue. Their staleness is only the poll's own lag
               rather than a lane wait, but a click on a window that has
               closed is the same click and deserves the same sentence. */
            if let stale = staleTargetComplaint(for: plan) {
                ActLog.note(action: "\(label)  plan=\(plan)",
                            outcome: "NOT DISPATCHED: \(stale)", ms: 0)
                report("\(label) — \(stale)")
                return .refused(stale)
            }
            /* **ONE DIRECT ACT ON THE WIRE AT A TIME.** This was a bare
               `Task`, so four quick clicks were four acts racing into a
               guest whose act plane has one request cell — and it refused
               all but one of them with `act-busy`. Michelle hit that nine
               times in ninety seconds working a scroll bar on 2026-08-07,
               and every one of those clicks was a control click, which is
               precisely the kind that never reaches the broker's lane.
               The guest's own interlock says a caller told "busy" can
               decide; this is that side deciding. See
               ``MirrorDirectActLane``. */
            let enqueuedAt = Date()
            let depthAtEntry = directActLane.depth
            report(label + (depthAtEntry > 0 ? " — queued" : "…"))
            let admitted = directActLane.submit { [weak self] in
                guard let self else { return }
                let started = Date()
                let complaint = await self.serve(plan)
                if let correlation = self.planCorrelation {
                    self.track(correlation, label: label)
                }
                /* **The other half of the acts.** Only a handful of plans
                   need a typed postcondition and therefore the FIFO; move,
                   resize, select, control clicks, keystrokes and most menu
                   commands dispatch straight from here. Measuring only the
                   brokered ones would have described a machine whose
                   commonest gestures are free — and the acts that filled
                   the 2026-08-04 PowerBook log were almost all of this
                   kind. There is no settle time because nothing here claims
                   an observed effect.

                   **There IS now a queue wait**, and it is reported: since
                   2026-08-07 these acts take a lane of their own rather
                   than racing each other into the guest's single act cell,
                   so `enqueuedAt` is when the click was taken and
                   `dispatchStartedAt` is when the wire was free for it.
                   The gap between them is the wait this path used to spend
                   as an `act-busy` refusal instead. */
                self.actTimeline.record(.init(
                    kind: .released, operationID: "direct",
                    label: label,
                    outcome: complaint == nil ? .dispatched : .refused,
                    queueDepthAtEntry: depthAtEntry,
                    enqueuedAt: enqueuedAt, dispatchStartedAt: started,
                    dispatchReturnedAt: Date(), settledAt: nil,
                    releasedAt: Date()))
                ActLog.note(action: "\(label)  plan=\(plan)",
                            outcome: complaint ?? self.planSettlement,
                            ms: Int(Date().timeIntervalSince(started) * 1000))
                if let complaint {
                    self.report("\(label) — \(complaint)")
                } else if !Self.isConfirmedSettlement(self.planSettlement) {
                    self.report("\(label) — \(self.planSettlement)")
                } else {
                    self.report(label + " ✓")
                }
                self.poll()                  // show the effect now
            }
            if !admitted {
                /* The lane is full, and this is the one case where a direct
                   act IS refused to dispatch: it was provably never sent,
                   so the sentence has to say that rather than let a person
                   read it as the machine declining. */
                let full = "not sent: \(directActLane.capacity) acts are "
                    + "already waiting for this Mac, which serves one at a "
                    + "time; try again when it has caught up"
                ActLog.note(action: "\(label)  plan=\(plan)",
                            outcome: "NOT DISPATCHED: \(full)", ms: 0)
                report("\(label) — \(full)")
                return .refused(full)
            }
            /* The direct path's own answer arrives asynchronously and is
               NOT a refusal to dispatch — the act left. A complaint from
               the guest is settlement news, and this return says only
               whether the act got out of the door. Nothing will ever
               settle it: these plans carry no typed postcondition, which
               is a property of the PLAN and not of how busy the cycle
               was. */
            return .direct
        }
    }

    private func reportOperation(_ operation: MirrorOperation,
                                 label: String, complaint: String?) {
        let outcome: String
        switch operation.outcome {
        case .queued:
            outcome = "queued"
        case .dispatched:
            outcome = "awaiting guest confirmation"
        case .awaitingEvidenceAfterRefusal:
            outcome = "awaiting guest confirmation; attempt reported: "
                + (complaint ?? operation.reason ?? "refused")
        case .refused:
            outcome = operation.reason ?? complaint ?? "refused"
        case .timedOut:
            outcome = "timed out without authoritative confirmation"
        case .confirmed:
            outcome = "confirmed by a later guest scene"
        case .confirmedAfterTimeout:
            outcome = "confirmed by a later guest scene after timeout"
        case .confirmedAfterRefusal:
            outcome = "confirmed by a later guest scene; attempt had reported: "
                + (operation.reason ?? "refused")
        case .sessionChanged:
            outcome = "cancelled because the guest session changed"
        case .cancelled:
            outcome = operation.reason ?? "cancelled"
        }
        ActLog.note(action: "operation \(operation.id) \(label)",
                    outcome: operation.outcome.rawValue, ms: 0)
        report(operation.outcome == .confirmed
               || operation.outcome == .confirmedAfterTimeout
               || operation.outcome == .confirmedAfterRefusal
               ? label + " ✓ — " + outcome
               : label + " — " + outcome)
        poll()
    }

    /// Kept for the action vocabulary, which the agent-shaped half of
    /// MirrorKit still speaks. Nothing in NOW's own path uses it.
    func perform(_ actions: [MirrorAction], label: String) {
        guard !actions.isEmpty else { return }
        if let refusal = pinnedActionRefusal() {
            ActLog.note(action: label,
                        outcome: "NOT DISPATCHED: \(refusal)", ms: 0)
            report(refusal)
            return
        }
        guard currentPlanePolicy.contains(.interaction) else {
            report("\(label): Interaction is off; the Mirror is read-only.")
            return
        }
        for action in actions {
            let verdict = ActionModel.availability(action, planes: planes)
            guard verdict == .available else {
                report("\(label): \(sentence(for: verdict))")
                return
            }
        }
        /* THE SAME LANE the object-first door takes, and for the same
           reason: this was a bare `Task` too, so an action sequence raced
           whatever else the person had just clicked into the guest's single
           act cell. Every gesture that reaches the machine goes through one
           lane or it is not serialized at all. */
        report(label + (directActLane.depth > 0 ? " — queued" : "…"))
        let admitted = directActLane.submit { [weak self] in
            guard let self else { return }
            self.planCorrelation = nil
            self.planSettlement = "unknown"
            for action in actions {
                if let outcome = await self.send(action) {
                    if let correlation = self.planCorrelation {
                        self.track(correlation, label: label)
                    }
                    self.report("\(label) — \(outcome)")
                    return
                }
            }
            if let correlation = self.planCorrelation {
                self.track(correlation, label: label)
            }
            self.report(Self.isConfirmedSettlement(self.planSettlement)
                        ? label + " ✓"
                        : "\(label) — \(self.planSettlement)")
            self.poll()
        }
        if !admitted {
            let full = "not sent: \(directActLane.capacity) acts are already "
                + "waiting for this Mac, which serves one at a time; try "
                + "again when it has caught up"
            ActLog.note(action: label,
                        outcome: "NOT DISPATCHED: \(full)", ms: 0)
            report("\(label) — \(full)")
        }
    }

    /// Bulk Finder interactions come from host-owned interior state rather
    /// than one `MirrorGesture`, but they still use the same serialized act
    /// lane and the same stale-roster refusal as every object-first gesture.
    private func performFinderPlan(_ plan: InteractionPlan, label: String,
                                   cursor: MirrorKit.Point? = nil) {
        if let refusal = pinnedActionRefusal() {
            report(refusal)
            return
        }
        guard currentPlanePolicy.contains(.interaction) else {
            report("\(label): Interaction is off; the Mirror is read-only.")
            return
        }
        if let stale = staleTargetComplaint(for: plan) {
            report("\(label) — \(stale)")
            return
        }
        let enqueuedAt = Date()
        let depthAtEntry = directActLane.depth
        report(label + (depthAtEntry > 0 ? " — queued" : "…"))
        let admitted = directActLane.submit { [weak self] in
            guard let self else { return }
            self.planCorrelation = nil
            self.planSettlement = "unknown"
            let started = Date()
            let complaint = await self.serve(plan)
            if complaint == nil, let cursor,
               let window = self.finderContainerReference(for: plan),
               let cursorComplaint = await self.act.cursorPlace(
                    window: window, h: cursor.x, v: cursor.y) {
                self.note("\(label) succeeded; cursor follow refused: "
                          + cursorComplaint)
            }
            self.actTimeline.record(.init(
                kind: .released, operationID: "direct", label: label,
                outcome: complaint == nil ? .dispatched : .refused,
                queueDepthAtEntry: depthAtEntry,
                enqueuedAt: enqueuedAt, dispatchStartedAt: started,
                dispatchReturnedAt: Date(), settledAt: nil,
                releasedAt: Date()))
            ActLog.note(action: "\(label)  plan=\(plan)",
                        outcome: complaint ?? self.planSettlement,
                        ms: Int(Date().timeIntervalSince(started) * 1000))
            if complaint == nil,
               case .finderRename(_, _, let container) = plan,
               case .window(let title) = container,
               let window = self.scene?.windows.first(where: {
                   $0.title == title && FinderItems.isFolderWindow($0)
               }), let key = Self.finderWindowKey(window) {
                /* The directory identity and geometry did not change, but
                   one roster name did. Force exactly that container's next
                   semantic read; leaving the layout key complete would keep
                   drawing the pre-rename name forever. */
                self.finderLayouts[key] = nil
            }
            self.report(complaint.map { "\(label) — \($0)" }
                        ?? "\(label) — \(self.planSettlement)")
            self.poll()
        }
        if !admitted {
            report("\(label) — not sent: the act queue is full")
        }
    }

    private func finderContainerReference(for plan: InteractionPlan)
        -> String? {
        guard let scene else { return nil }
        let container: InteractionPlan.FinderContainer
        switch plan {
        case .finderSetSelection(_, let value),
             .finderOpenItems(_, let value),
             .finderRename(_, _, let value),
             .finderSelect(_, let value),
             .finderOpen(_, let value):
            container = value
        default:
            return nil
        }
        switch container {
        case .desktop:
            return scene.windows.last(where: HitTester.isDesktopBackdrop)?.ref
        case .window(let title):
            let matches = scene.windows.filter {
                $0.title == title && FinderItems.isFolderWindow($0)
            }
            return matches.count == 1 ? matches[0].ref : nil
        }
    }

    private var currentPlanePolicy: Set<MirrorPlaneID> {
        pinnedGuestKey.map(planePolicy) ?? [.structure]
    }

    // MARK: - Serving a plan

    /// **Whether the mutation lane must keep waiting after an attempt.**
    ///
    /// The one line that decides how long a refusal holds the FIFO, so it
    /// is a function with a name rather than an expression inside a
    /// closure — it was an expression, and it was `complaint?.contains(
    /// "was not sent") != true`, which is how a refusal the machine
    /// raised before it armed anything came to hold the lane for fifteen
    /// seconds and then be confirmed by another act's effect.
    ///
    /// An attempt that did not complain went to the machine and settles
    /// from observation. A refusal settles now only when this side can
    /// prove nothing was sent; every other refusal keeps waiting, because
    /// an act that may have landed must not be written off.
    static func effectMayHaveLanded(
        complaint: String?,
        reach: AgentIntegrationProjectionFailure.Reach) -> Bool {
        guard complaint != nil else { return true }
        return reach != .notSent
    }

    /// The newest scene this side has, checked against the plan's target
    /// at the moment the plan is about to be sent.
    private func staleTargetComplaint(for plan: InteractionPlan) -> String? {
        Self.staleTargetComplaint(for: plan, in: scene)
    }

    /// **What a person clicked, re-read against what the machine last
    /// said.**
    ///
    /// The Mirror draws a scene that is already a poll old, so a click can
    /// name a window that has since closed — and an act that waits its turn
    /// in the FIFO is dispatched seconds later still, against a scene the
    /// host has by then replaced. This is the re-read, and it is
    /// deliberately narrow:
    ///
    /// - **Only windows, and only by the reference the guest minted.**
    ///   Window references are interned on the guest, so an unchanged
    ///   window keeps its token across republishes
    ///   (`now_obs_intern`/`identity_same`); a reference the newest scene
    ///   no longer carries therefore means the window is gone, not that
    ///   its name changed. Element references are not checked here — a
    ///   control lives inside a window the structural walk may have
    ///   published without its controls, and "absent" would then be a
    ///   statement about the walk rather than the machine.
    /// - **Only when there is a scene to check against.** No scene is not
    ///   evidence of absence.
    /// - **Finder items, only against a roster the scene actually holds.**
    ///   A Finder act names its item by name rather than by a minted
    ///   reference, and the container's roster is all-or-nothing
    ///   (`readIcons` refuses a partial or changing read rather than
    ///   returning some of it), so a published roster missing the name is
    ///   real absence. An unread container is nil and claims nothing. This
    ///   arm exists because the alternative was measured: driving
    ///   `finderOpen "Date & Time"` against the desktop, where it does not
    ///   live, correctly opened nothing and still burned the full 15 s
    ///   timeout holding the one mutation lane. A null result that costs
    ///   the same as a hung one teaches a caller nothing.
    ///
    /// It never claims an effect and never re-aims: a stale target is
    /// refused with the reason, exactly as `MirrorDriveService` refuses a
    /// name the published snapshot does not carry.
    static func staleTargetComplaint(for plan: InteractionPlan,
                                     in scene: MirrorKit.Scene?) -> String? {
        guard let scene else { return nil }
        if let ref = windowReference(in: plan) {
            guard !scene.windows.contains(where: { $0.ref == ref }) else {
                return nil
            }
            return "the scene moved on — that window is no longer on the "
                + "machine, so the act was not sent. Read it again."
        }
        if let (items, container) = finderItemReferences(in: plan),
           let published = MirrorActionExecutor.publishedItems(of: container,
                                                               in: scene),
           let missing = items.first(where: { name in
               !published.contains(where: { $0.name == name })
           }) {
            let place: String
            switch container {
            case .desktop: place = "on the desktop"
            case .window(let title): place = "in \(title)"
            }
            return "the Finder shows no item named \(missing) \(place), so "
                + "the act was not sent. Read it again."
        }
        return nil
    }

    /// The Finder item a plan acts on, or nil for a plan that names none.
    static func finderItemReferences(in plan: InteractionPlan)
        -> ([String], InteractionPlan.FinderContainer)? {
        switch plan {
        case .finderOpen(let item, let container),
             .finderSelect(let item, let container):
            return ([item], container)
        case .finderSetSelection(let items, let container),
             .finderOpenItems(let items, let container):
            return (items, container)
        case .finderRename(let item, _, let container):
            return ([item], container)
        default:
            return nil
        }
    }

    static func finderItemReference(in plan: InteractionPlan)
        -> (String, InteractionPlan.FinderContainer)? {
        guard let (items, container) = finderItemReferences(in: plan),
              let first = items.first else { return nil }
        return (first, container)
    }

    /// The window reference a plan acts on, or nil for a plan that does
    /// not name one.
    static func windowReference(in plan: InteractionPlan) -> String? {
        switch plan {
        case .windowAct(let ref, _):
            return ref
        case .activateWindow(_, let ref):
            return ref
        default:
            return nil
        }
    }

    /// Returns nil when it went, or a sentence for a person when it did
    /// not. Every branch answers one or the other; none stays quiet.
    private func serve(_ plan: InteractionPlan) async -> String? {
        planCorrelation = nil
        planSettlement = "unknown"
        planRefusalReach = .unknown
        switch plan {
        case .controlPart(let ref, let part, _):
            return readingResident(await act.controlAct(.init(element: ref,
                                                              part: part)))

        case .dialogItem(let ref, let item):
            /* Direct human-input path first. The broker vocabulary keeps this
               distinct from ctlact, and the guest revalidates the DITL item
               against the observation-minted backing control. */
            return await run("ditemact", ["element": .text(ref),
                                          "item": .number(item)], act: true)

        case .windowAct(let ref, let what):
            return readingResident(await act.windowAct(Self.request(ref, what)))

        case .menuCommand(let menuID, let index, let left):
            guard let process = Self.frontProcess(in: scene) else {
                planRefusalReach = .notSent
                return "the current scene has no unique front process; "
                    + "the menu act was not sent"
            }
            return readingResident(await act.menuAct(
                .init(menu: menuID, item: index,
                      titleLeft: left, process: process)))

        case .keystroke(let code, let char, let mods):
            let complaint = reading(await act.key(
                .init(code: code, char: char, mods: mods)))
            if let settlement = Self.dispatchOnlySettlement(
                ifSuccessful: complaint) {
                planSettlement = settlement
            }
            return complaint

        case .setText(let ref, let text):
            return readingResident(await act.setElementText(element: ref,
                                                             text: text))

        case .typeText(let text):
            /* NOW has no `type` verb: text reaches the guest as the
               keystrokes it is made of, which is also what a real
               keyboard would have sent. */
            for ch in text.unicodeScalars {
                let code = ActionModel.keycodes[
                    Character(String(ch).lowercased())] ?? 0
                if let complaint = reading(await act.key(
                    .init(code: code, char: Int(ch.value), mods: 0))) {
                    return complaint
                }
            }
            planSettlement = "dispatched-but-unconfirmed"
            return nil

        case .activateApp(let psn):
            let result = await activate(psn)
            if result == nil { planSettlement = "confirmed" }
            return result

        case .activateWindow(let psn, let ref):
            if let complaint = await activate(psn) { return complaint }
            return readingResident(await act.windowAct(
                Self.request(ref, .select)))

        case .applicationVisibility(let visibility):
            let result = await applicationVisibility(visibility)
            if result == nil {
                /* Even Show All's mutation script is only attempt evidence.
                   The typed operation settles from the separately retained
                   visibility census for a later structural generation. */
                planSettlement = "dispatched-but-unconfirmed"
            }
            return result

        case .openAppleMenuItem(let name):
            let read = await readingOutput(
                "script", ["source": .text(Self.appleMenuItemScript(name))])
            if let error = read.error { return error }
            planSettlement = "dispatched-but-unconfirmed"
            return Self.visibilityDispatchOutcome(read.value)

        case .finderSelect(let item, let container):
            /* UNCHANGED, deliberately. Fronting the Finder here starves the
               guest application — see finderDeselect below — but a select
               fronting the Finder is a DECIDED behaviour, measured on a
               live machine 2026-08-05 and guarded by
               `testTheFinderComesForwardForASelectionAndNotOverANewApplication`
               with the reason "a selection nobody can see is not a
               selection". That is a real trade-off between visibility and
               scheduling, and it is not one to resolve from a log at 3am.
               Michelle's call. */
            return await finder(
                "select \(reference(item, in: container))")
        case .finderOpen(let item, let container):
            /* Leave the Finder where it is when the thing being opened
               comes up as its own application — otherwise the `activate`
               below the phrase covers it the instant it appears. No scene
               means no classification, and the old behaviour is the
               honest default: a folder open is the case the Finder must
               be in front for. */
            let ownApp = scene.map {
                MirrorActionExecutor.opensAsItsOwnApplication(
                    item, in: container, scene: $0) == true
            } ?? false
            return await finder(
                "open \(reference(item, in: container))",
                activate: !ownApp)
        case .finderSetSelection(let items, let container):
            let refs = items.map { reference($0, in: container) }
                .joined(separator: ", ")
            return await finder("select {\(refs)}")
        case .finderOpenItems(let items, let container):
            guard !items.isEmpty else { return nil }
            let refs = items.map { reference($0, in: container) }
                .joined(separator: ", ")
            /* The selection command already made Finder visible. Activating
               it after opening would cover an application that one of these
               items launched, the same failure the single-item path avoids. */
            return await finder("open {\(refs)}", activate: false)
        case .finderRename(let item, let newName, let container):
            let escaped = newName.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return await finder(
                "set name of \(reference(item, in: container)) to \"\(escaped)\"",
                activate: false)
        case .finderDeselect:
            /* CLEARING a selection has nothing to show, so the visibility
               argument that justifies fronting on a select does not reach
               here — this case simply inherited the `activate: true`
               default alongside its sibling.

               Fronting is not free. It backgrounds the guest application,
               which is the ONLY context permitted to give back its own
               content-plane port hooks: `content_uninstall_context` skips
               every row whose a5 is not the caller's, and the jGNE filter
               that drives it runs in whatever process happens to pump.

               Measured on the PowerBook 1400c, 2026-08-08: 22 hooks
               installed against 1 uninstalled, four ports still hooked
               with `a5 0x0`, and the guest logging "not scheduled for 14s"
               while the host fronted the Finder at it. Michelle saw that
               as the guest app repeatedly hiding itself. */
            return await finder("select {}", activate: false)

        case .nothing, .unsupported:
            return nil                       // handled before we get here
        }
    }

    /// **How an icon is reached without a positional click.**
    ///
    /// The Finder addresses its own items by name, and NOW can carry an
    /// AppleScript, so an object with a name is actionable on a guest
    /// whose contract has no click-at-a-point verb at all. This is the
    /// case the object model exists for.
    private func reference(
        _ item: String,
        in container: InteractionPlan.FinderContainer) -> String {
        let escaped = item.replacingOccurrences(of: "\"", with: "\\\"")
        switch container {
        case .desktop:
            return "item \"\(escaped)\" of desktop"
        case .window(let title):
            let w = title.replacingOccurrences(of: "\"", with: "\\\"")
            /* `item "X" of window "T"` and NOT `target of window "T"`.
               Measured on OS 9.1's Finder, 2026-08-02: the target form
               fails with osaErr -1753 on both `window` and `Finder
               window`, while resolving the item inside the window
               directly answers with its full path. Naming the WINDOW
               rather than a path is also what stays true when the same
               folder is open twice. */
            return "item \"\(escaped)\" of window \"\(w)\""
        }
    }

    /// **`activate` is right for a selection and wrong for an open**, and
    /// the difference is what a person sees afterwards.
    ///
    /// Selecting an icon while another application is frontmost changes
    /// nothing anybody can see, so the Finder comes forward — that is why
    /// this was always here. But `activate` runs AFTER the phrase, so an
    /// open that raises a NEW application's window is covered by the
    /// Finder the instant it appears. Measured 2026-08-05: control panels
    /// "open quickly, but still immediately push them behind Finder".
    ///
    /// The rule separating the two is the one the owner prediction
    /// already uses. A thing that opens a FINDER window wants the Finder
    /// in front; a thing that opens as its OWN application wants to be
    /// left in front itself.
    static func finderScript(_ phrase: String,
                             activate: Bool = true) -> String {
        """
        tell application "Finder"
        \(phrase)\(activate ? "\nactivate" : "")
        end tell
        """
    }

    private func finder(_ phrase: String,
                        activate: Bool = true) async -> String? {
        let source = Self.finderScript(phrase, activate: activate)
        let complaint = await run("script", ["source": .text(source)])
        if let settlement = Self.dispatchOnlySettlement(
            ifSuccessful: complaint) {
            planSettlement = settlement
        }
        return complaint
    }

    private func activate(_ psn: String) async -> String? {
        let parts = psn.split(separator: ".")
        guard parts.count == 2, let hi = Int(parts[0]), let lo = Int(parts[1])
        else { return "that process reference is not a PSN" }
        /* NUMBERS. As strings these crossed as "0"-parsing zeros and
           `activate` fronted process 0.0 - see CommandArg. */
        let read = await readingOutput(
            "activate", ["serialHi": .number(hi), "serialLo": .number(lo)],
            row: "Frontmost")
        if let error = read.error { return error }
        return Self.activationOutcome(read.value)
    }

    static func activationOutcome(_ raw: String?) -> String? {
        guard raw.map(unquote) == "yes, re-read from the machine" else {
            return "activation was not confirmed by a front-process re-read"
        }
        return nil
    }

    /// Visibility mutation is a normal guest-OS operation, not a resident
    /// foreign-memory effect. The script targets the process that is front at
    /// execution time; the scene identity guard below binds that transient
    /// role to the exact process the person clicked. A race stays pending
    /// because the later retained census settles by PSN incarnation.

    static func appleMenuItemScript(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Finder"
        open item "\(escaped)" of folder "Apple Menu Items" of system folder
        end tell
        return "dispatched"
        """
    }



    private func applicationVisibility(
        _ action: InteractionPlan.ApplicationVisibility) async -> String? {
        switch action {
        case .hide(let psn, let incarnation, let name, _, _, _):
            /* **The route that actually works, as of 2026-08-05.** Hiding
               went through the Finder's AppleScript object model, which is
               READ-ONLY for `visible` and refuses (`-10000`, `-10006`,
               `osaErr -1753`) — so Hide has never once worked from this
               face. The guest now serves it directly through the Process
               Manager's own `ShowHideProcess`, weak-linked, and answers
               with an `IsProcessVisible` read-back rather than a claim.
               Watched working on an emulated Power Mac G4 that day, both
               directions, with the Finder's desktop icons disappearing
               from the framebuffer as the third witness.

               The guest verb takes a NAME because that is what a person
               has; the psn/incarnation check above it is still what makes
               this act about the exact application the scene displayed. */
            guard let app = scene?.apps.first(where: { $0.psn == psn }),
                  app.front, app.incarnation == incarnation else {
                return "the Application-menu target changed before dispatch"
            }
            let read = await readingOutput("hide",
                                           ["target": .text(name)],
                                           row: "Outcome")
            /* The census that would notice this is rate-limited against a
               roster that a hide does not change, so the act says so
               rather than leaving the answer up to a floor interval. */
            invalidateVisibility()
            if let error = read.error {
                /* The guest's own outcome vocabulary is typed, so a
                   refusal here says which half moved without guessing. */
                planRefusalReach = .notSent
                return "hide: \(error)"
            }
            return Self.hideDispatchOutcome(read.value)

        case .hideOthers(let exceptPSN, let incarnation, _, _, _, _):
            guard let scene,
                  let front = scene.apps.first(where: { $0.psn == exceptPSN }),
                  front.front, front.incarnation == incarnation else {
                return "the Application-menu target changed before dispatch"
            }
            let others = HitTester.switchableApps(scene).filter {
                $0.psn != exceptPSN
            }
            for app in others {
                let read = await readingOutput(
                    "hide", ["target": .text(app.name)], row: "Outcome")
                if let error = read.error {
                    invalidateVisibility()
                    return "Hide Others stopped at \(app.name): \(error)"
                }
                if let complaint = Self.hideDispatchOutcome(read.value) {
                    invalidateVisibility()
                    return "Hide Others stopped at \(app.name): \(complaint)"
                }
            }
            invalidateVisibility()
            return nil

        case .showAll:
            guard let scene else { return "the application roster is absent" }
            for app in HitTester.switchableApps(scene) {
                let read = await readingOutput(
                    "hide", ["target": .text("--show \(app.name)")],
                    row: "Outcome")
                if let error = read.error {
                    invalidateVisibility()
                    return "Show All stopped at \(app.name): \(error)"
                }
                if let complaint = Self.showDispatchOutcome(read.value) {
                    invalidateVisibility()
                    return "Show All stopped at \(app.name): \(complaint)"
                }
            }
            invalidateVisibility()
            return nil

        }
    }

    /// **The guest's own word for what happened to the flag**, mapped to
    /// this side's complaint-or-nil.
    ///
    /// Only `hidden` is a success here, and it is a stronger one than this
    /// surface usually gets: the guest called `ShowHideProcess` and then
    /// read the state back with `IsProcessVisible` before answering, so
    /// the word is an observation rather than a dispatch. The typed
    /// postcondition still settles from a later scene — that rule is older
    /// than this route and survives it — but a caller is no longer waiting
    /// on the ONLY evidence.
    ///
    /// `unconfirmed` is deliberately a complaint. It means the call was
    /// accepted and the flag did NOT move, which is the exact shape of the
    /// old AppleScript lie and must never read as success again.
    static func hideDispatchOutcome(_ raw: String?) -> String? {
        guard let raw else { return "the guest reported no hide outcome" }
        let outcome = unquote(raw).trimmingCharacters(in: .whitespaces)
        switch outcome {
        case "hidden":
            return nil
        case "unconfirmed":
            return "hide: the call was accepted and the application is "
                + "still visible"
        case "unavailable":
            return "hide: this Mac's CarbonLib does not export "
                + "ShowHideProcess (it needs CarbonLib 1.5 or later)"
        case "":
            return "the guest reported no hide outcome"
        default:
            return "hide: \(outcome)"
        }
    }

    static func showDispatchOutcome(_ raw: String?) -> String? {
        guard let raw else { return "the guest reported no show outcome" }
        let outcome = unquote(raw).trimmingCharacters(in: .whitespaces)
        switch outcome {
        case "shown": return nil
        case "unconfirmed":
            return "show: the call was accepted and the application is still hidden"
        case "": return "the guest reported no show outcome"
        default: return "show: \(outcome)"
        }
    }



    static func visibilityDispatchOutcome(_ raw: String?) -> String? {
        guard let raw else { return "visibility dispatch outcome unavailable" }
        let observed = unquote(raw)
        return observed == "dispatched" ? nil : observed
    }

    /// Runs a verb and returns one labelled row from its own reply, or
    /// nil when the guest refused. Used for `script`, whose ANSWER is the
    /// point rather than its dispatch.
    private func runReadingOutput(_ verb: String,
                                  _ args: [String: CommandArg],
                                  row: String = "output") async -> String? {
        await readingOutput(verb, args, row: row).value
    }

    /// The same call, keeping the guest's refusal instead of discarding
    /// it. `runReadingOutput` answering `nil` cost a whole drive: the
    /// Macintosh HD window rendered as an empty box for an hour and the
    /// mirror had nothing to say about why, because "the script failed"
    /// and "nobody asked" were the same value.
    /// `osaFailureIsAnError` extends that lesson to the guest's OTHER
    /// refusal. A script that raises returns `ok: true` with an empty
    /// `output` row and its reason in `osaErr`, so a caller reading only
    /// `output` cannot tell "the Finder refused the question" from "the
    /// answer is empty" — the same collapse, one label further in. It cost
    /// the visibility census entirely: every row failed, the read looked
    /// like an empty success, and the coverage claim blamed name ambiguity
    /// (measured Mac OS 9.1, 2026-08-05).
    ///
    /// It is opt-in because one caller is built on a script that is EXPECTED
    /// to raise: the Finder art pass is split from the item pass precisely so
    /// its error takes down only the types, and promoting that to an error
    /// would refetch every roster forever.
    /// Automatic Finder enrichment has a typed purpose on the wire. The
    /// guest can therefore refuse this class before opening OSA without
    /// disabling a deliberate Script command or a user-requested Finder act.
    private func readingFinderComplement(
        _ source: String, osaFailureIsAnError: Bool = false
    ) async -> (value: String?, error: String?, truncated: Bool) {
        await readingOutput(
            "script",
            ["source": .text(source),
             "purpose": .text("mirror-finder-complement")],
            osaFailureIsAnError: osaFailureIsAnError)
    }

    private func readingOutput(_ verb: String,
                               _ args: [String: CommandArg],
                               row: String = "output",
                               osaFailureIsAnError: Bool = false)
        async -> (value: String?, error: String?, truncated: Bool) {
        await withCheckedContinuation { continuation in
            sendCommand(verb, args) { result in
                guard result.ok else {
                    let e = result.error
                    return continuation.resume(returning: (
                        nil,
                        "\(e?.code ?? "error"): \(e?.message ?? "no reason")",
                        false))
                }
                var value: String?
                var truncated = false
                var osaErr: String?
                for cells in result.output?[verb] ?? [] where cells.first == row {
                    value = cells.count > 1 ? cells.last : ""
                }
                for cells in result.output?[verb] ?? []
                where cells.first == "truncated" {
                    truncated = cells.last?.lowercased() == "true"
                }
                for cells in result.output?[verb] ?? []
                where cells.first == "osaErr" {
                    osaErr = cells.count > 1 ? cells.last : nil
                }
                if osaFailureIsAnError, let osaErr,
                   Self.isOSAFailure(osaErr) {
                    return continuation.resume(returning: (
                        nil, "the guest's AppleScript raised osaErr \(osaErr)",
                        truncated))
                }
                continuation.resume(returning: (value, nil, truncated))
            }
        }
    }

    /// Absent means an older guest that does not report the row at all, and
    /// an unreported error must not read as a reported success — but neither
    /// may a missing row invent one, so only a value that parses and is
    /// non-zero counts as a failure.
    static func isOSAFailure(_ raw: String) -> Bool {
        guard let code = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return code != 0
    }

    /// The verbs with no typed projection on this host yet. Reads the
    /// guest's own reply rather than assuming a send is a success.
    private func run(_ verb: String,
                     _ args: [String: CommandArg], act isAct: Bool = false)
        async -> String? {
        await withCheckedContinuation { continuation in
            sendCommand(verb, args) { result in
                if result.ok {
                    if isAct {
                        let rows = AgentIntegrationActControl.rows(
                            from: result, verb: verb)
                        self.planCorrelation = rows["Correlation"]
                        self.planSettlement = rows["Settlement"] ?? "unknown"
                    }
                    return continuation.resume(returning: nil)
                }
                let error = result.error
                if isAct {
                    self.planCorrelation = error?.correlation
                    self.planSettlement = error?.settlement ?? "unknown"
                }
                continuation.resume(returning:
                    "\(error?.code ?? "error"): \(error?.message ?? "")")
            }
        }
    }

    /// Sends one act. Returns nil when it was dispatched, or a sentence
    /// for a person when it was not.
    /// Every act, and what became of it, on one line in a file.
    ///
    /// Written because a whole day of driving could not tell DISPATCHED
    /// from FAILED. A title-bar drag that did nothing, a popup that
    /// "did not answer in time", a Hide that looked like it worked and
    /// had not, a keystroke that vanished after Tab, and two window acts
    /// that reported `outcome-unknown` while plainly working - each of
    /// those was resolved by guessing or by a screendump, and several
    /// wrong calls came straight out of the gap. The mirror's status
    /// line shows one act and then scrolls away; this keeps them.
    ///
    /// It is a DIAGNOSTIC, not a test channel. Rule 1 still stands: the
    /// mirror is driven and judged by driving it. This says what the
    /// driving did, the way a screendump says what the machine drew.
    private func send(_ action: MirrorAction) async -> String? {
        let started = Date()
        let outcome = await dispatch(action)
        ActLog.note(action: "\(action)",
                    outcome: outcome ?? planSettlement,
                    ms: Int(Date().timeIntervalSince(started) * 1000))
        return outcome
    }

    private func dispatch(_ action: MirrorAction) async -> String? {
        switch action {
        case .controlPart(let ref, let part, _):
            return readingResident(await act.controlAct(
                .init(element: ref, part: part)))

        case .axdo(let ref, _, _, let text):
            if let text {
                return readingResident(await act.setElementText(element: ref,
                                                                text: text))
            }
            /* A plain control click is part 10, the Control Manager's
               button part - the same number `ctlact` names first in its
               own refusal text. */
            return readingResident(await act.controlAct(.init(element: ref,
                                                              part: 10)))

        case .windowAct(let ref, let what):
            return readingResident(await act.windowAct(Self.request(ref, what)))

        case .menuInvoke(let menuID, let itemIndex, let titleLeft):
            guard let process = Self.frontProcess(in: scene) else {
                return "the current scene has no unique front process; "
                    + "the menu act was not sent"
            }
            return readingResident(await act.menuAct(
                .init(menu: menuID, item: itemIndex,
                      titleLeft: titleLeft, process: process)))

        case .key(let code, let char, let mods):
            let complaint = reading(await act.key(
                .init(code: code, char: char, mods: mods)))
            if let settlement = Self.dispatchOnlySettlement(
                ifSuccessful: complaint) {
                planSettlement = settlement
            }
            return complaint

        default:
            /* Everything left is an act this driver declared it cannot
               serve, so `availability` refused it above and we never
               arrive. Stated anyway: a default that quietly returned nil
               would report a click as dispatched if that guard ever
               moved. */
            return "no lane on this host carries \(action)"
        }
    }

    /// Internal and static so it can be tested without a machine: this
    /// is the whole translation from Mirror's vocabulary to NOW's window
    /// act, and it is exactly the kind of per-action key rule that
    /// `AgentIntegrationWindowActRequest.geometryKeys` refuses when it is
    /// got wrong.
    static func request(_ ref: String,
                        _ what: MirrorAction.WindowAct)
        -> AgentIntegrationWindowActRequest {
        switch what {
        case .select:
            return .init(window: ref, action: .select)
        case .close:
            return .init(window: ref, action: .close)
        case .zoom:
            /* The zoom box takes no geometry: the standard state is the
               application's to compute, and a host that supplied one
               would be deciding what the window is FOR. */
            return .init(window: ref, action: .zoom)
        case .move(let left, let top):
            return .init(window: ref, action: .move, left: left, top: top)
        case .resize(let width, let height):
            return .init(window: ref, action: .resize,
                         width: width, height: height)
        }
    }

    static func frontProcess(in scene: MirrorKit.Scene?)
        -> AgentIntegrationProcessSerial? {
        guard let front = scene?.processes?.filter(\.front),
              front.count == 1 else { return nil }
        let halves = front[0].psn.split(separator: ".")
        guard halves.count == 2,
              let high = Int(halves[0]), let low = Int(halves[1]) else {
            return nil
        }
        return .init(high: high, low: low)
    }

    /// The one presentation gate for the green checkmark. A resident firing
    /// a patch, a command returning `ok`, and a timeout that later settles
    /// are all useful evidence, but only the application-owned settlement
    /// record can say the effect was observed in a later scene.
    static func isConfirmedSettlement(_ settlement: String?) -> Bool {
        settlement == "confirmed"
    }

    static func dispatchOnlySettlement(ifSuccessful complaint: String?)
        -> String? {
        complaint == nil ? "dispatched-but-unconfirmed" : nil
    }

    /// The guest's own answer, or nil when it dispatched. Never a
    /// paraphrase: a refusal is the most useful thing this surface
    /// produces, because the alternative is a person clicking and
    /// getting silence.
    private func reading<Value>(
        _ result: AgentIntegrationProjectedResult<Value>) -> String? {
        switch result {
        case .completed:
            return nil
        case .refused(let failure):
            planRefusalReach = failure.reach
            return "\(failure.code): \(failure.message)"
        case .unavailable(let why):
            /* Nobody to ask usually means nothing was sent — but not
               always: a guest that went away DURING an act says so with
               its own reach, and that act may be running on a Macintosh
               this side can no longer see. */
            planRefusalReach = why.reach
            return "\(why)"
        }
    }

    private func readingResident<Value: AgentIntegrationSettledActReceipt &
        Codable & Equatable & Sendable>(
        _ result: AgentIntegrationProjectedResult<Value>) -> String? {
        switch result {
        case .completed(let receipt):
            planCorrelation = receipt.correlation
            planSettlement = receipt.settlement
            return nil
        case .refused(let failure):
            planCorrelation = failure.correlation
            planSettlement = failure.settlement ?? "unknown"
            planRefusalReach = failure.reach
            return "\(failure.code): \(failure.message)"
        case .unavailable(let unavailable):
            planRefusalReach = unavailable.reach
            return unavailable.message
        }
    }

    private func apply(_ settlements: [ActSettlement]?) {
        render(settlementTracker.apply(settlements))
    }

    private func track(_ correlation: String, label: String) {
        render(settlementTracker.track(correlation, label: label))
    }

    private func render(_ notices: [MirrorSettlementNotice]) {
        for notice in notices {
            ActLog.note(action: notice.label, outcome: notice.outcome, ms: 0)
            report(notice.confirmed
                   ? notice.label + " ✓"
                   : "\(notice.label) — \(notice.outcome)")
        }
    }

    private func sentence(for verdict: ActionAvailability) -> String {
        switch verdict {
        case .available:
            return "available"
        case .inputDeviceUnavailable(let reason), .unsupported(let reason):
            return reason
        }
    }

    /// One race-safe resident drag lane shared by Finder items and scroll
    /// thumbs. Motion and release can arrive while `dragpress` is still on the
    /// wire; retaining the latest point and release request prevents a quick
    /// drag from becoming "no drag is being held" followed by a stuck button.
    fileprivate func residentDragPress(window: String, at point: MirrorKit.Point,
                                        answer: @escaping (ItemDragAnswer) -> Void) {
        guard dragSession == nil, !dragPressInFlight else {
            answer(.refused("another drag is already being held"))
            return
        }
        dragPressInFlight = true
        pendingDragPoint = point
        pendingDragRelease = nil
        Task { @MainActor in
            switch await act.dragPress(window: window, h: point.x, v: point.y) {
            case .done(let minted):
                guard let minted else {
                    self.dragPressInFlight = false
                    answer(.refused("the Macintosh did not identify the drag"))
                    self.pendingDragRelease?(.refused(
                        "the Macintosh did not identify the drag"))
                    self.pendingDragRelease = nil
                    return
                }
                self.dragPressInFlight = false
                self.dragSession = minted
                answer(.confirmed)
                if let latest = self.pendingDragPoint,
                   latest != point {
                    _ = await self.act.dragMove(session: minted,
                                                h: latest.x, v: latest.y)
                }
                if let release = self.pendingDragRelease {
                    self.pendingDragRelease = nil
                    self.dragSession = nil
                    self.pendingDragPoint = nil
                    switch await self.act.dragRelease(session: minted) {
                    case .done: release(.confirmed)
                    case .refused(let why): release(.refused(why))
                    }
                }
            case .refused(let why):
                self.dragPressInFlight = false
                self.dragSession = nil
                self.pendingDragPoint = nil
                answer(.refused(why))
                self.pendingDragRelease?(.refused(why))
                self.pendingDragRelease = nil
            }
        }
    }

    fileprivate func residentDragMove(to point: MirrorKit.Point) {
        pendingDragPoint = point
        guard let session = dragSession else { return }
        Task { @MainActor in
            _ = await act.dragMove(session: session, h: point.x, v: point.y)
        }
    }

    fileprivate func residentDragRelease(
        answer: @escaping (ItemDragAnswer) -> Void
    ) {
        if dragPressInFlight {
            pendingDragRelease = answer
            return
        }
        guard let session = dragSession else {
            answer(.refused("no drag is being held"))
            return
        }
        dragSession = nil
        pendingDragPoint = nil
        Task { @MainActor in
            switch await act.dragRelease(session: session) {
            case .done: answer(.confirmed)
            case .refused(let why): answer(.refused(why))
            }
        }
    }
}

// MARK: - Host-owned Finder interior mutations

extension NOWMirrorSource: FinderInteractionDriver {
    var finderInteractionDriver: FinderInteractionDriver? { self }

    func setFinderSelection(
        _ names: [String], in container: InteractionPlan.FinderContainer,
        at point: MirrorKit.Point?
    ) {
        performFinderPlan(.finderSetSelection(items: names,
                                              container: container),
                          label: names.isEmpty ? "deselect Finder items"
                              : "select \(names.count) Finder item(s)",
                          cursor: point)
    }

    func openFinderItems(
        _ names: [String], in container: InteractionPlan.FinderContainer,
        at point: MirrorKit.Point?
    ) {
        guard !names.isEmpty else { return }
        performFinderPlan(.finderOpenItems(items: names, container: container),
                          label: "open \(names.count) Finder item(s)",
                          cursor: point)
    }

    func renameFinderItem(
        _ name: String, to newName: String,
        in container: InteractionPlan.FinderContainer,
        at point: MirrorKit.Point?
    ) {
        performFinderPlan(.finderRename(item: name, to: newName,
                                        container: container),
                          label: "rename \(name) to \(newName)", cursor: point)
    }
}

extension NOWMirrorSource: ScrollbarDragDriver {
    var scrollbarDragDriver: ScrollbarDragDriver? { self }

    func thumbPress(windowID: String, at point: MirrorKit.Point,
                    answer: @escaping (ItemDragAnswer) -> Void) {
        guard let ref = scene?.windows.first(where: { $0.id == windowID })?.ref,
              !ref.isEmpty else {
            answer(.refused("the scrollbar's Finder window has no live "
                            + "guest reference"))
            return
        }
        residentDragPress(window: ref, at: point, answer: answer)
    }

    func thumbMove(to point: MirrorKit.Point) {
        residentDragMove(to: point)
    }

    func thumbRelease(answer: @escaping (ItemDragAnswer) -> Void) {
        residentDragRelease(answer: answer)
    }
}

// MARK: - Holding the mouse button down

/// **The span between a gesture a person makes and a Macintosh that can
/// hold the mouse button down.**
///
/// Written 2026-08-07 after Michelle said "drag isnt working on my build".
/// It was not, it never had, and *nothing was red*: `MirrorSceneSource`
/// declares `itemDragDriver` with a protocol default of `nil`, this type
/// never overrode it, and a protocol default that returns nil is a legal
/// conformance. So the app compiled, conformed, passed every gate, and
/// answered every item drag with "this mirror cannot hold the mouse button
/// down" — a well-written refusal on a status line that scrolls, which is
/// how a deliberate refusal reads to a person as a dead feature.
/// `ItemDragSeamTests` now checks this conformer and the `dragpress` verb
/// as a pair, so half a bridge fails in either direction.
///
/// ## Why it names a WINDOW
///
/// `dragpress` takes an observation-minted reference, and a Finder icon has
/// none: it is not a Control Manager object, the element walk cannot see
/// it, and no observation ever minted one. What the guest CAN name is the
/// container — a folder window, or the Finder's own full-screen `Desktop`
/// window, both of which the walk has been reporting all along — so that is
/// what crosses, with the point checked against the window's rectangle on
/// the guest side. The reasoning, and the three designs rejected on the way
/// to it, are in docs/open-issues.md.
///
/// ## What it does NOT do
///
/// It never synthesises an answer. `.confirmed` is the only door to a
/// promoted drag in `ItemDragSession`, and a driver that manufactured one
/// would turn "we do not know yet" into a plausible wrong claim about a
/// file — the failure this whole arc exists to remove. Every case below is
/// either the guest's own word or a refusal in the guest's own sentence.
extension NOWMirrorSource: ItemDragDriver {

    var itemDragDriver: ItemDragDriver? { self }

    func dragPress(_ subject: DragTargeting.Subject, at point: MirrorKit.Point,
                   answer: @escaping (ItemDragAnswer) -> Void) {
        guard let window = containerReference(for: subject) else {
            answer(.refused(
                "the Macintosh has not named the "
                    + (subject.container == .desktop ? "desktop"
                                                     : "window")
                    + " \(subject.name) is in, so there is nothing to hold "
                    + "it by yet — try again once the mirror has observed "
                    + "it"))
            return
        }
        residentDragPress(window: window, at: point, answer: answer)
    }

    func dragMove(to point: MirrorKit.Point) {
        residentDragMove(to: point)
    }

    func dragRelease(_ plan: DragTargeting.Plan?,
                     answer: @escaping (ItemDragAnswer) -> Void) {
        residentDragRelease { [weak self] result in
            if case .confirmed = result, let plan {
                self?.applyConfirmedDrag(plan)
            }
            answer(result)
        }
    }

    private func applyConfirmedDrag(_ plan: DragTargeting.Plan) {
        guard let scene else { return }
        switch plan.subject.container {
        case .desktop:
            if plan.intent == .rearrange,
               var items = icons[Self.desktopKey],
               let index = items.firstIndex(where: {
                   $0.name == plan.subject.name
               }) {
                items[index].x = plan.dropFrame.l
                items[index].y = plan.dropFrame.t
                icons[Self.desktopKey] = items
            }
            desktopIconLayout = "<none>"
        case .window(let id):
            if let window = scene.windows.first(where: { $0.id == id }),
               let key = Self.finderWindowKey(window) {
                if plan.intent == .rearrange,
                   var items = icons[key],
                   let index = items.firstIndex(where: {
                       $0.name == plan.subject.name
                   }) {
                    let origin = FinderItems.contentOrigin(window)
                    items[index].x = plan.dropFrame.l - origin.x
                    items[index].y = plan.dropFrame.t - origin.y
                    icons[key] = items
                }
                finderLayouts[key] = nil
            }
        }
        if case .finderWindow(let id, _, _, _) = plan.destination,
           let window = scene.windows.first(where: { $0.id == id }),
           let key = Self.finderWindowKey(window) {
            finderLayouts[key] = nil
        }
        publishFinderComplements(for: Self.iconLayoutKey(scene))
        poll()
    }

    /// The observation-minted reference for the container an item lives in.
    ///
    /// The desktop is found with `HitTester.isDesktopBackdrop`, the predicate
    /// this side already uses to decide what a click on bare desktop means
    /// — one place deciding what the desktop window is, rather than a
    /// second spelling of the same title match.
    private func containerReference(
        for subject: DragTargeting.Subject) -> String? {
        guard let scene else { return nil }
        switch subject.container {
        case .desktop:
            return scene.windows.last(where: HitTester.isDesktopBackdrop)?.ref
        case .window(let id):
            return scene.windows.first(where: { $0.id == id })?.ref
        }
    }
}
