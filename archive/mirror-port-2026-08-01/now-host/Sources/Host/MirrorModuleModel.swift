import Combine
import Foundation
import MirrorKit
import MirrorKitUI
import NOWAgentIntegration

/// The act pump, asked to start when a session begins and stopped when it
/// ends. **Not a new wire verb.** NOW's contract carries no pump command
/// today — this is the seam whoever builds one this wave wires an
/// implementation into (`MirrorModuleModel.init(pump:)`), the same shape as
/// `listener` and `driver`: a session without one simply has nothing to ask,
/// and Start proceeds without asking anything. A stub here would be a guess
/// at a wire message nobody has agreed to yet.
protocol MirrorPumpControl: Sendable {
    func start() async -> MirrorPumpOutcome
    func stop()
}

/// What asking the pump to start came to. Two refusal shapes, because
/// "this guest cannot do this at all" and "it can and said no this time"
/// are different facts and the config-area's refusal line should be able to
/// tell them apart the way every other refusal on this page does.
enum MirrorPumpOutcome: Equatable, Sendable {
    case started
    case unsupported(String)
    case refused(String)
}

/// Where a streaming session is, in one closed set a page can draw honestly
/// rather than assemble from booleans. `notStarted` and `stopped` read the
/// same to a person (nothing is happening) but are worth keeping apart for a
/// test: the first has never run, the second ran and was told to stop.
enum MirrorSessionState: Equatable {
    case notStarted
    case starting
    case streaming
    case stopped
    /// The guest left while a session was running. Distinct from `stopped`:
    /// nobody asked for this, and Start offered again is an attempt to
    /// resume, not a fresh session.
    case guestGone
}

/// The front window's joined content, carried forward past the fetch that
/// would otherwise wipe it.
///
/// **Why this exists at all.** `MirrorSceneAdapter` decodes every window's
/// `display` as `nil` — NOW's scene document carries no display plane, only
/// `MirrorContentJoin` attaches one, after the scene lands (see both files'
/// headers). A page that replaced `scene` wholesale on every fetch, the way
/// `show(document:)` always has, would show a window's content for exactly
/// one fetch and then show it wiped — not because anything stopped drawing,
/// but because the NEXT scene is a fresh decode with nothing joined yet.
///
/// **Ported from Mirror's `IslandStore` keying rule, unchanged.** `psn/title`
/// rather than `Scene.Window.id` (which folds in z-order, `"<psn>/<title>#z"`,
/// and turns over on every raise — `MirrorContentJoin`'s own header notes the
/// same field) and rather than window INDEX, which is the same z-order
/// problem the maintainer named directly. Two windows sharing one `psn/title`
/// (two `Untitled` documents in one app) are disambiguated by top-left
/// corner, stable across a raise the same way `IslandStore`'s is.
///
/// **Eviction is the hold-on-blur policy, not a second one.** A window still
/// present in the scene keeps its content however long it has been since it
/// was front — that is what "held" means. Only a window ABSENT from the
/// scene for `grace` fetches running loses its content, so a long session's
/// map stays bounded rather than growing one entry per window ever seen.
struct MirrorContentHold {
    private(set) var display: [String: [DisplayOp]] = [:]
    private var seenAt: [String: Int] = [:]

    /// Ported from `IslandStore.keys(for:)` — see this type's header for why
    /// psn/title and not `id` or index.
    static func keys(for windows: [MirrorKit.Scene.Window]) -> [String] {
        var occurrences: [String: Int] = [:]
        for win in windows {
            occurrences["\(win.psn)/\(win.title)", default: 0] += 1
        }
        return windows.map { win in
            let base = "\(win.psn)/\(win.title)"
            guard occurrences[base, default: 0] > 1 else { return base }
            return "\(base)@\(win.rect.l),\(win.rect.t)"
        }
    }

    /// Carry held content onto a freshly decoded scene, for every window
    /// whose own `display` is nil — which, from this adapter, is every
    /// window every time. Touches every window present so the eviction
    /// clock knows they are still here, then evicts anything absent for
    /// `grace` fetches running.
    mutating func apply(to scene: inout MirrorKit.Scene, at fetch: Int,
                        grace: Int) {
        let keys = Self.keys(for: scene.windows)
        for i in scene.windows.indices where scene.windows[i].display == nil {
            scene.windows[i].display = display[keys[i]]
        }
        let living = Set(keys)
        for key in keys { seenAt[key] = fetch }
        for (key, last) in seenAt where !living.contains(key) {
            guard fetch - last >= grace else { continue }
            seenAt[key] = nil
            display[key] = nil
        }
    }

    /// Remember what a join attached, so the NEXT fetch — which decodes a
    /// scene with this window's `display` back at `nil` — has something to
    /// carry forward.
    mutating func record(_ scene: MirrorKit.Scene) {
        let keys = Self.keys(for: scene.windows)
        for (i, window) in scene.windows.enumerated() {
            guard let ops = window.display else { continue }
            display[keys[i]] = ops
        }
    }
}

/// The Mirror page: what is on the other Mac's screen, drawn from the scene
/// the guest describes rather than from its pixels.
///
/// ## What it renders from, and who asks
///
/// **Two sources, one door.** `show(document:irVersion:provenance:)` takes
/// bytes and an envelope version, and both sources go through it: a person
/// opening a recorded document (`Provenance.fixture`), and a scene fetched off
/// the wire (`Provenance.guest`). The pane always says which one it is
/// drawing, because a replayed Finder window that reads as *this Mac, now* is
/// the worst thing this page could do.
///
/// **A scene arrives because something changed, or because a person asked.**
/// `fetchScene()`'s callers are `startSession()` — the page's Start Mirror
/// button, which asks once on the press rather than leaving the first picture
/// to the loop's own timing — and the watch loop below. There is no longer a
/// bare Fetch button beside them; `SceneProjection`'s `.appUI` row names Start
/// Mirror for that reason.
///
/// **RESTORED 2026-08-01, and it is a retraction.** This header used to argue
/// that a fetch happens on a button press *and on nothing else* — no timer —
/// because a scene is a transfer on the one bulk lane and "a poll would take
/// that lane at intervals nobody chose". The argument was tidy and it was
/// wrong about the product: a mirror that only ever shows the moment somebody
/// last pressed a button is a screenshot viewer. Upstream shipped a 0.5 s poll
/// and had already measured what this header was guessing about — fetch-on-
/// change ran at **one fetch per four polls**, 4.5 s against a 3.8 s baseline.
/// A theory that loses to a number is not a design decision.
///
/// What survives from that argument is the *cost* half, and it is what shapes
/// the loop:
///
/// 1. **The Mac moves one thing at a time.** A scene transfer takes the bulk
///    lane. So the loop does not transfer on every tick: it asks a **control**
///    question first (`axsnap` — the contract's own "the one call on this
///    surface that is safe to poll"), which takes no bulk lane at all, and
///    only spends a transfer when the answer differs from the last one, or
///    when the scene on screen is older than the ceiling.
/// 2. **A walk is real work on the machine being walked.** Same answer: the
///    walk runs when the cheap question says something moved, not on a
///    metronome.
/// 3. **A person can stop it.** It is their Mac and their lane. Live is the
///    default because a mirror that is not live is not a mirror, and `pause()`
///    is one press away and visible on the page.
///
/// **What the probe can and cannot see, stated rather than implied.**
/// `axsnap` reports the front process and whether it has windows and menus at
/// all. It therefore catches an application switch, a launch, a quit, the
/// first window of a program appearing — and it does **not** catch a window
/// moving inside one application. That is why the ceiling exists: an
/// unseen change costs bounded staleness, never permanent staleness. A probe
/// that pretended to be complete would be worse than no probe.
///
/// A scene on screen is still a moment in the past — the page dates it and
/// says so.
///
/// ## The resting states are the hard part
///
/// A mirror with nothing to mirror is the normal case on a desk where the
/// extension is not installed, and the failure to design against is a page
/// that reads as **broken** when it is merely **idle** — the most-cited defect
/// in this repo (`docs/metal-and-ux-review.md` §1: *"0 companions, 0 calls,
/// last seen never is the visual shape of a thing that failed to load"*).
///
/// Every state below therefore says three things: what is true, why that is
/// ordinary, and what would change it. None of them is drawn as a fault
/// except the one that IS a fault — a document that would not decode — and
/// `MirrorPaneState.isFault` is the switch the pane reads, asserted in tests
/// so a later state cannot quietly join the wrong side.
@MainActor
final class MirrorModuleModel: ObservableObject, GuestScopedModel {

    /// What this host knows about the NOW Extension on the connected Mac.
    ///
    /// `unasked` is a first-class value, not a stand-in for `absent`, and it
    /// **survives the arrival of a caller**. It used to mean "nothing on this
    /// side can ask"; it now means "nobody has asked yet", which is still the
    /// honest answer on every fresh connection precisely because asking is a
    /// person's decision here. Rendering it as "absent" would be this page
    /// inventing a fact about someone's Mac — no less so now that the fact is
    /// obtainable.
    enum ExtensionEvidence: Equatable, Sendable {
        case unasked
        case absent
        case present
    }

    /// Whether the extension's scene plane is armed. Same rule: `unasked`
    /// means nobody looked. A plane is dormant until the application arms it
    /// (`docs/resident-components.md`), so "present but unarmed" is the
    /// expected state of a freshly booted Mac and not a fault.
    enum PlaneEvidence: Equatable, Sendable {
        case unasked
        case unarmed
        case armed
    }

    /// Where the scene on screen came from. Carried beside the scene, never
    /// inferred from it: the document itself cannot say whether it was read
    /// off a wire a moment ago or off a disk from last month.
    enum Provenance: Equatable, Sendable {
        /// A recorded document replayed from a file on this Mac.
        case fixture(name: String)
        /// A scene this guest sent, in answer to a fetch.
        case guest(name: String)

        var isLive: Bool {
            if case .guest = self { return true }
            return false
        }
    }

    /// Where the last ask got to. Three values, because "nobody asked",
    /// "asking" and "asked and told no" are three different things to say and
    /// a boolean would collapse two of them.
    ///
    /// `refused` holds the reason whatever produced it — the guest declining,
    /// this side declining because the lane is busy, silence, a short
    /// transfer. The prose is already written for a person by whoever refused;
    /// this does not rewrite it.
    enum Fetch: Equatable, Sendable {
        case idle
        case looking
        case refused(String)
    }

    @Published var connection: GuestConnectionState = .disconnected {
        didSet { updateWatch() }
    }
    @Published private(set) var fetch: Fetch = .idle

    /// The wire. Optional so a test or a preview gets a model that can render
    /// every state without a socket — and so that a model without one simply
    /// cannot fetch, rather than fetching into a stub that always fails.
    private let listener: GuestListener?

    /// The act lane, for a gesture on the drawing. Optional for the same
    /// reason the listener is: a model without one refuses a click with a
    /// sentence rather than dispatching into a stub.
    private let driver: MirrorActionDriver?

    /// The pace of the watch loop: `automatic`, `maxBackoff` and
    /// `settleAfterAct` come from here and are not configurable this wave.
    /// `probeInterval` and `refreshCeiling` seed the persisted, configurable
    /// properties below and are otherwise unused after `init` — read
    /// `self.probeInterval`/`self.refreshCeiling`, never `watch.…`, anywhere
    /// past this point.
    let watch: WatchPolicy

    /// The act pump, when a lane has built one. See `MirrorPumpControl`.
    private let pump: MirrorPumpControl?

    private let defaults: UserDefaults

    private enum Keys {
        static let probeInterval = "mirror.probeInterval"
        static let refreshCeiling = "mirror.refreshCeiling"
        static let contentGraceFetches = "mirror.contentGraceFetches"
        static let pixelDrawEnabled = "mirror.pixelDrawEnabled"
    }

    /// A window absent from the scene this many fetches running loses its
    /// held content. A guess, in the same spirit as `settleAfterAct` — no
    /// measurement backs this number, only the requirement that the map not
    /// grow forever. Configurable and persisted.
    static let defaultContentGraceFetches = 20

    init(listener: GuestListener? = nil,
         actions: MirrorActionDriver? = nil,
         watch: WatchPolicy = .live,
         pump: MirrorPumpControl? = nil,
         islandCapture: IslandCapture? = nil,
         defaults: UserDefaults = .standard) {
        self.listener = listener
        self.driver = actions
        self.watch = watch
        self.pump = pump
        self.injectedIslandCapture = islandCapture
        self.defaults = defaults
        self.probeInterval = defaults.object(forKey: Keys.probeInterval)
            as? TimeInterval ?? watch.probeInterval
        self.refreshCeiling = defaults.object(forKey: Keys.refreshCeiling)
            as? TimeInterval ?? watch.refreshCeiling
        self.contentGraceFetches =
            defaults.object(forKey: Keys.contentGraceFetches) as? Int
            ?? Self.defaultContentGraceFetches
        self.pixelDrawEnabled =
            defaults.object(forKey: Keys.pixelDrawEnabled) as? Bool ?? true
    }

    deinit {
        ticker?.invalidate()
    }

    /// Whether the button is offered at all. A page with no wire, or no Mac,
    /// has nothing to ask.
    var canFetch: Bool { listener != nil && isConnected }

    /// Asks the connected Mac for one scene. **The only producer of a live
    /// scene on this page**, called by the person's button and by the watch
    /// loop.
    ///
    /// A second press while one is in flight is ignored rather than queued:
    /// the listener would refuse it against its own lane guard anyway, and
    /// turning an impatient click into a visible refusal would teach a person
    /// that the page is broken when it is merely working. The watch loop
    /// relies on the same guard — it never queues either.
    /// `withContent` asks for the QuickDraw content plane too, once this
    /// scene has landed. Not a blind default: the loop's CEILING fetch never
    /// passes it (`MirrorContentJoin` is fetch-on-ask by design, and joining
    /// content on a timer would be a second thing polling somebody else's
    /// Mac for a plane that only changes when they draw) — but a session
    /// arms it once at `startSession` and re-arms it on the loop's OWN
    /// change signal (`probeForChange`), which is evidence of a new front
    /// window rather than a blind poll. A window this fetch does not join
    /// keeps whatever it last held (`MirrorContentHold`, in `show`).
    func fetchScene(withContent: Bool = false) {
        guard let listener, isConnected else { return }
        guard fetch != .looking else {
            /* A second ask cannot start a new fetch — the listener would
               refuse it against its own lane guard anyway. But dropping it
               SILENTLY, the way this used to, could lose the one thing that
               makes it different from the fetch already in flight: a want
               for content. Upgrading the in-flight ask keeps that want
               alive for when it lands, rather than requiring whoever asked
               to ask again into the same race. */
            if withContent { contentAsked = true }
            return
        }
        contentAsked = withContent
        fetch = .looking
        listener.requestScene { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let delivery):
                self.fetch = .idle
                /* A scene arrived, so the lane was free and the guest
                   answered: whatever the loop had backed off from is over.
                   `lastSceneAt` is the ceiling's clock and is stamped from
                   ARRIVAL rather than from `capturedAt` — the guest's clock
                   is its own and this side's ceiling is about how stale the
                   PAGE is. */
                self.backoff = 0
                self.holdUntil = nil
                self.lastSceneAt = Date()
                self.lastSeq = delivery.seq
                /* A scene that arrived is proof of both rungs of the ladder
                   at once: only the extension can walk other programs'
                   windows, and only an armed plane runs the walk. Recorded
                   through the same seams a probe would use, so there is one
                   path to these facts and not two. */
                self.record(extensionEvidence: .present)
                self.record(planeEvidence: .armed)
                self.show(document: delivery.document,
                          /* The ENVELOPE's major, not the body's. The gate
                             inside `show` runs on this number before the body
                             is parsed; reading it off the document instead
                             would be a parse before the gate. */
                          irVersion: delivery.irVersion,
                          provenance: .guest(name: delivery.guestName))
                /* AFTER the scene is on screen, not instead of it. The join
                   is a separate control round trip and may refuse; a window
                   with chrome and no interior is strictly better than no
                   window while the drain is in flight. */
                if self.contentAsked { self.joinContent() }
                self.contentAsked = false
                /* Unlike content, this is NOT fetch-on-ask: a folder window
                   with no items in it reads as an empty folder, which is
                   the wrong lie for a page whose whole claim is what the
                   Finder is showing. See `MirrorFolderItemsJoin`. */
                self.joinFolderItems()
            case .failure(let failure):
                self.contentAsked = false
                /* Deliberately does NOT touch the evidence ladder. A guest
                   that refuses has answered — but what it answered is "not
                   now", which is not a fact about whether the extension is
                   installed, and a local refusal ("the lane is busy") is not
                   a fact about the other Mac at all. Demoting the ladder on
                   a refusal would let a busy moment be recorded as a missing
                   extension. */
                self.fetch = .refused(failure.message)
                self.watchNoted(failure)
            }
        }
    }

    // MARK: - The watch loop

    /// How often the cheap question is asked, how stale the drawing may get,
    /// and how far a collision backs off.
    ///
    /// `automatic` is what a test turns off. It does not change a single
    /// decision — `watchTick()` is the same function either way — it only
    /// decides whether a `Timer` calls it or the test does.
    struct WatchPolicy: Equatable, Sendable {
        var probeInterval: TimeInterval
        /// The oldest the drawing may be before a scene is fetched whether
        /// or not the probe saw anything. This is what bounds the staleness
        /// of a change the probe cannot see — a window moved inside one
        /// application — and it is why the probe is allowed to be a partial
        /// signal instead of having to be a complete one.
        var refreshCeiling: TimeInterval
        var maxBackoff: TimeInterval
        var automatic: Bool
        /// How long a dispatched act is given to become visible before the
        /// page asks for one scene.
        ///
        /// **A guess, and marked as one.** Nothing measures how long a
        /// classic application takes to reach its event loop and redraw after
        /// an event is handed to it — it depends on the application, on what
        /// else is running, and on the machine. 0.6 s is chosen to be longer
        /// than a redraw and shorter than a person's patience, and the loop's
        /// refresh ceiling is what makes an under-guess merely slow rather
        /// than wrong: a page that looked too early looks again within
        /// `refreshCeiling`.
        var settleAfterAct: TimeInterval = 0.6

        static let live = WatchPolicy(probeInterval: 0.5, refreshCeiling: 5,
                                      maxBackoff: 8, automatic: true)
        /// For a test: the same decisions, driven by hand, and no wall clock
        /// in the act path either.
        static let manual = WatchPolicy(probeInterval: 0.5, refreshCeiling: 5,
                                        maxBackoff: 8, automatic: false,
                                        settleAfterAct: 0)
    }

    /// The probe's pace and the ceiling's reach, configurable and persisted
    /// (`Keys.probeInterval`/`Keys.refreshCeiling`) — set through
    /// `setProbeInterval`/`setRefreshCeiling`, never assigned directly, so
    /// changing either while the loop is live can restart the ticker at the
    /// new pace without a separate call the config area might forget to
    /// make.
    @Published private(set) var probeInterval: TimeInterval
    @Published private(set) var refreshCeiling: TimeInterval
    /// See `MirrorContentHold`'s header.
    @Published private(set) var contentGraceFetches: Int
    /// **The hard guarantee.** Objects-first is already policy — a window
    /// with a semantic source never gets photographed — so a normal app
    /// already sends zero pixels; this is the switch for the FALLBACK plane
    /// underneath that policy, for the window with no semantic source at
    /// all. Off means no capture request for any window leaves this host,
    /// for anyone, ever — checked in `scheduleIslandPass`/`onePass`
    /// themselves rather than by handing the pass a closure that always
    /// refuses, because a refused capture still costs a round trip and this
    /// guarantee is that none is spent. DEFAULT ON: the fallback exists
    /// because it is the ordinary case for a program this host has no
    /// semantics for, and no session should silently lose it.
    @Published private(set) var pixelDrawEnabled: Bool

    /// How often the cheap question is asked. Restarts a running ticker at
    /// the new pace immediately, rather than waiting for it to next fire at
    /// the old one.
    func setProbeInterval(_ value: TimeInterval) {
        guard value > 0, value != probeInterval else { return }
        probeInterval = value
        defaults.set(value, forKey: Keys.probeInterval)
        guard ticker != nil else { return }
        ticker?.invalidate()
        ticker = nil
        updateWatch()
    }

    /// The oldest the drawing may be before the ceiling fetches regardless
    /// of what the probe said. Takes effect on the next tick — nothing needs
    /// restarting, since `watchTick` reads it fresh every time.
    func setRefreshCeiling(_ value: TimeInterval) {
        guard value > 0 else { return }
        refreshCeiling = value
        defaults.set(value, forKey: Keys.refreshCeiling)
    }

    /// How many fetches a window may be absent for before its held content
    /// is dropped. See `MirrorContentHold`.
    func setContentGraceFetches(_ value: Int) {
        guard value > 0 else { return }
        contentGraceFetches = value
        defaults.set(value, forKey: Keys.contentGraceFetches)
    }

    /// The hard guarantee's own switch.
    ///
    /// **Off drops what is already held, immediately.** A held photograph
    /// is still pixels on screen — turning this off must mean none are,
    /// not merely that no new ones are taken — and `islandNote` names the
    /// toggle so a window that goes back to empty chrome reads as a policy
    /// a person set rather than a fault. `onePass` discards the answer of
    /// any capture that was already outstanding when this flips, so a
    /// round trip that lands a moment later cannot undo the drop.
    ///
    /// **On resumes without a restart.** `scheduleIslandPass` runs the same
    /// gate a redraw or a join completing already does, so a session that
    /// is running picks the fallback plane back up on its own rather than
    /// needing Stop/Start.
    func setPixelDrawEnabled(_ value: Bool) {
        guard value != pixelDrawEnabled else { return }
        pixelDrawEnabled = value
        defaults.set(value, forKey: Keys.pixelDrawEnabled)
        guard value else {
            /* The STORE (what a later pass would reattach) and the SCENE
               ALREADY ON SCREEN (what is drawn right now) are two separate
               facts, and dropping only the first would leave last pass's
               photograph sitting in the drawing until the next fetch
               happened to overwrite it — a held photograph is still pixels
               on screen the whole time nobody asked to keep it there. */
            sceneIslands = SceneIslands()
            if var current = scene {
                for i in current.windows.indices
                    where current.windows[i].items == nil {
                    current.windows[i].island = nil
                }
                scene = current
            }
            islandNote = "Draw Window Pixels is off, so held window "
                + "interiors were dropped. Windows with no semantic source "
                + "draw as empty chrome until it is switched back on."
            return
        }
        islandNote = nil
        scheduleIslandPass()
    }

    // MARK: - The session

    /// Where a streaming session is. See `MirrorSessionState`.
    @Published private(set) var sessionState: MirrorSessionState = .notStarted
    /// What asking the act pump to start came to, when there was a pump to
    /// ask. Nil when there is nothing to say — no pump, or it started
    /// cleanly.
    @Published private(set) var pumpNote: String?

    /// Whether the session wants the front window's content plane kept
    /// current: armed once when `startSession` begins, and re-armed on
    /// every probe-detected front-process change (`probeForChange`) so
    /// content follows the front window without a second timer polling for
    /// it. Not persisted — it describes what a RUNNING session is doing,
    /// not a preference.
    private var contentArmed = false

    /// Whether Start is offered at all. Same gate the retired manual button
    /// used: no wire, no Mac, nothing to start.
    var canStartSession: Bool { canFetch }

    /// Begins a streaming session: arms the content plane, asks the pump to
    /// start (best-effort — see `MirrorPumpControl`), fetches one scene WITH
    /// content rather than waiting for the loop's own first tick to decide
    /// whether to, and starts the loop. Idempotent: pressing Start on an
    /// already-starting or already-streaming session does nothing.
    func startSession() {
        guard canStartSession, sessionState != .starting,
              sessionState != .streaming else { return }
        sessionState = .starting
        contentArmed = true
        pumpNote = nil
        if let pump {
            Task { @MainActor [weak self] in
                switch await pump.start() {
                case .started:
                    self?.pumpNote = nil
                case .unsupported(let reason), .refused(let reason):
                    self?.pumpNote = reason
                }
            }
        }
        fetchScene(withContent: true)
        setLive(true)
    }

    /// Tears the session down: stops the loop and, when a pump was asked to
    /// start, asks it to stop. The last scene stays on screen — Stop means
    /// "not updating any more", not "forget what was shown".
    func stopSession() {
        guard sessionState == .starting || sessionState == .streaming
            || sessionState == .guestGone else { return }
        sessionState = .stopped
        contentArmed = false
        pumpNote = nil
        /* Stop tears the pixel plane down. The scene on screen keeps the
           islands already drawn into it — Stop means "not updating any
           more", not "forget what was shown" — but nothing further is
           photographed, and the megabytes of held interiors are released
           rather than kept warm for a session nobody asked to resume. A
           Start after this re-photographs, which is also the honest thing:
           held pixels from before a stop describe a Mac that has had a
           while to change. */
        sceneIslands = SceneIslands()
        islandNote = nil
        pump?.stop()
        setLive(false)
    }

    // MARK: - Breaking away into its own window

    /// Whether this pane is showing inside its own standalone window
    /// rather than embedded in the module list.
    ///
    /// **Model state, not view state.** The embedded pane and the
    /// standalone window are two SEPARATE SwiftUI hierarchies over the SAME
    /// model — neither can read the other's local `@State` — so the one
    /// fact both need to agree on (is the embedded page showing the pane or
    /// a "bring it back" placeholder?) has to live here. It carries nothing
    /// about a session: detaching moves which window draws this model, not
    /// whether it is running.
    @Published private(set) var isDetached = false

    /// Break the pane out. Idempotent: a second call while already detached
    /// does nothing, rather than the window controller trying to work out
    /// what "detach an already-detached pane" would even mean.
    func detach() {
        guard !isDetached else { return }
        isDetached = true
    }

    /// Bring the pane back — from the module page's own "Bring Back"
    /// button, or from the standalone window closing. Neither the session
    /// nor the scene is touched: this is only a fact about which window
    /// draws the pane.
    func reattach() {
        guard isDetached else { return }
        isDetached = false
    }

    /// Whether the page is keeping itself up to date. Live by default,
    /// because a mirror that only updates when pressed is a screenshot
    /// viewer — and stoppable, because it is somebody else's Mac and one
    /// transfer lane.
    @Published private(set) var isLive = true
    /// Why the loop is in the state it is in, when that is worth a sentence:
    /// backed off, stopped because the guest said no, running without a
    /// probe. Nil when there is nothing to say.
    @Published private(set) var liveNote: String?
    /// When the drawing on screen arrived. The ceiling's clock, and the
    /// "updated N ago" the header shows.
    @Published private(set) var lastSceneAt: Date?
    /// The producer's counter for the scene on screen, kept because it is
    /// the guest's own answer to "is this the same scene, newer moment" and
    /// a later change signal will want it. Never used to decide anything
    /// today — a value this side does not act on is recorded, not invented.
    private(set) var lastSeq: Int?

    private var ticker: Timer?
    private var lastProbe: String?
    private var probing = false
    /// False once the guest has told us it does not serve the probe. Then
    /// the ceiling is the whole loop, which is honest and slower rather
    /// than a poll dressed up as change detection.
    private(set) var probeUsable = true
    private var backoff: TimeInterval = 0
    private var holdUntil: Date?

    /// The person's switch.
    func setLive(_ on: Bool) {
        guard on != isLive else { return }
        isLive = on
        if on {
            /* Resuming forgives whatever stopped it. The reason it stopped
               was true when it was written and is not a fact about the Mac
               now — leaving it on screen beside a running loop would be the
               page contradicting itself. */
            liveNote = nil
            backoff = 0
            holdUntil = nil
            probeUsable = true
            lastProbe = nil
        }
        updateWatch()
        if on { watchTick() }
    }

    /// One turn of the loop: the cheap question, and a transfer only when
    /// something says to spend one.
    ///
    /// Order matters and is the whole design. The ceiling is checked BEFORE
    /// the probe, so a page that has gone stale refreshes even on a guest
    /// whose probe answers "nothing moved" — the probe cannot see a window
    /// drag, and a loop that trusted it completely would sit on a wrong
    /// picture forever while reporting itself live.
    func watchTick(now: Date = Date()) {
        guard isLive, canFetch, fetch != .looking, !probing else { return }
        if let holdUntil, now < holdUntil { return }
        let age = lastSceneAt.map { now.timeIntervalSince($0) }
        if scene == nil || age == nil || age! >= refreshCeiling {
            fetchScene()
            return
        }
        guard probeUsable else { return }
        probeForChange()
    }

    /// The cheap question. A **control** message, not a transfer: it does not
    /// take the bulk lane, which is what makes asking it ten times per scene
    /// cheaper than fetching a scene once.
    private func probeForChange() {
        guard let listener else { return }
        probing = true
        listener.runCommand(MirrorSceneProbe.command) { [weak self] result in
            guard let self else { return }
            self.probing = false
            switch MirrorSceneProbe.read(result) {
            case .token(let token):
                defer { self.lastProbe = token }
                /* The first answer establishes the baseline; it is not a
                   change. Fetching on it would put a transfer on the wire
                   for the fact that we had never asked before, which the
                   ceiling has already covered. */
                guard let last = self.lastProbe else { return }
                if token != last {
                    /* This IS the front-window-change signal a streaming
                       session re-arms content on — the loop's own evidence
                       that something moved, not a blind timer. See
                       `contentArmed`'s header. */
                    self.fetchScene(withContent: self.contentArmed)
                }
            case .unsupported(let reason):
                self.probeUsable = false
                self.liveNote =
                    "This Mac does not answer the cheap \"what is in front\" "
                    + "question (\(reason)), so live updating asks for a "
                    + "whole scene every "
                    + "\(Int(self.refreshCeiling.rounded())) seconds "
                    + "instead of only when something moves."
            case .unanswered:
                /* Silence or a dropped connection. Says nothing about
                   whether the guest serves the probe, so nothing is
                   recorded and the next tick asks again. */
                break
            }
        }
    }

    /// What a refused fetch does to the loop.
    ///
    /// Two refusals, two answers, and collapsing them is how a page ends up
    /// hammering a Mac that already said no:
    ///
    /// - **This side refused** ("the Mac can move one thing at a time and a
    ///   file is coming from the Mac"): a collision with somebody else's
    ///   transfer. Back off — doubling, capped — and let the page say so.
    ///   Nothing is queued; the tick after the hold asks again.
    /// - **The guest refused**: it was asked, it answered, and the answer was
    ///   no. Repeating that every ceiling is not persistence, it is a loop
    ///   asking a machine the same question until somebody notices. Live
    ///   updating STOPS, with the reason, and Look Now still asks by hand.
    private func watchNoted(_ failure: GuestListener.SceneFailure) {
        guard isLive else { return }
        if failure.refusedByGuest {
            isLive = false
            updateWatch()
            liveNote = "Live updating stopped: this Mac answered the last "
                + "ask with a refusal rather than a scene. Look Now asks "
                + "again, and Live starts the loop back up."
            return
        }
        backoff = backoff == 0
            ? probeInterval * 2
            : min(backoff * 2, watch.maxBackoff)
        holdUntil = Date().addingTimeInterval(backoff)
        liveNote = "The last ask collided with something else on the Mac's "
            + "one transfer lane. Live updating waits "
            + String(format: "%.1f", backoff)
            + "s and asks again — nothing is queued."
    }

    /// Starts and stops the timer. The loop exists only while there is a
    /// machine to ask and a person who wants it asking.
    private func updateWatch() {
        let wanted = isLive && canFetch && watch.automatic
        guard wanted != (ticker != nil) else { return }
        if wanted {
            ticker = Timer.scheduledTimer(
                withTimeInterval: probeInterval, repeats: true) { _ in
                Task { @MainActor [weak self] in self?.watchTick() }
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: - Clicking the drawing

    /// What became of one gesture, in the page's words.
    ///
    /// Five outcomes and not three, because the two extra ones are the two a
    /// person is most likely to produce by accident and the two silence would
    /// hurt most: a press in the letterbox, and a press on something the
    /// scene draws but cannot address.
    struct ActionReport: Equatable {
        enum Outcome: Equatable {
            /// The act reached the machine and it answered. **The only claim
            /// this page makes about a click**, and it is the driver's word
            /// read off the guest's reply — never synthesised here, and never
            /// upgraded to "it worked".
            case dispatched
            /// The machine was asked and said no.
            case refused
            /// Nothing was asked, and this says which half is missing.
            case unavailable
            /// The gesture meant nothing to send.
            case inert
            /// On its way. Not an outcome — the absence of one yet, kept
            /// distinct so an ask in flight is never read as an act that
            /// meant nothing.
            case asking
            /// The press was not on the guest's screen at all.
            case offScreen

            var isDispatched: Bool { self == .dispatched }
        }

        var outcome: Outcome
        /// What was pressed, named the way the scene names it.
        var target: String
        var sentence: String
    }

    /// The last gesture's outcome, for the pane to show. **A click that
    /// cannot be dispatched says so**; silence is the failure mode this
    /// product keeps paying for.
    @Published private(set) var lastAction: ActionReport?

    func clearLastAction() { lastAction = nil }

    /// A press in the letterbox. Reported rather than swallowed: the black
    /// margin looks like part of the picture, and a person pressing it twice
    /// with nothing happening has been told nothing.
    func clickedOffScreen() {
        lastAction = ActionReport(
            outcome: .offScreen, target: "the border",
            sentence: "That point is outside the Mac's screen — the drawing "
                + "keeps the guest's own proportions, so the pane's margins "
                + "are not part of it.")
    }

    /// One keystroke, typed while the drawing has keyboard focus.
    ///
    /// **Not gated on a hit test — a keystroke has no point.** It is gated
    /// on `scene` the same way `click` is: nothing is sent to a Mac this
    /// page is not currently showing. `ActionModel.paneKeystroke` has
    /// already decided whether this press is even expressible (nil for one
    /// it cannot name); a nil here is silently nothing, the same way a
    /// disabled control's empty action list is — there was nothing to send,
    /// which is not a defect this page can report a target for.
    func key(virtualKeyCode: Int, characters: String?,
            command: Bool, option: Bool, control: Bool) {
        guard scene != nil else { return }
        guard let action = ActionModel.paneKeystroke(
            virtualKeyCode: virtualKeyCode, characters: characters,
            command: command, option: option, control: control) else {
            return
        }
        let named = characters.map { "key \($0)" } ?? "key \(virtualKeyCode)"
        if case .unavailable(let reason) = ActionModel.availability(action) {
            lastAction = ActionReport(outcome: .unavailable, target: named,
                                      sentence: reason)
            return
        }
        guard let driver else {
            lastAction = ActionReport(
                outcome: .unavailable, target: named,
                sentence: "This window has no act lane — it is showing a "
                    + "scene without a machine behind it.")
            return
        }
        lastAction = ActionReport(
            outcome: .asking, target: named, sentence: "Asking the Mac…")
        Task { @MainActor in
            let outcomes = await driver.drive([action])
            self.lastAction = Self.report(outcomes, on: named)
            if self.lastAction?.outcome.isDispatched == true {
                self.lastProbe = nil
                self.holdUntil = nil
            }
        }
    }

    /// A primary press at a point on the guest's screen.
    ///
    /// **Identity addressing only.** Every target here is resolved from the
    /// scene by the hit tester, and what goes on the wire is what the act
    /// names — a menu and item, a control reference. Nothing on this path
    /// falls back to a coordinate or to "whatever is in front", and the
    /// acts that could only be carried that way report themselves
    /// unavailable rather than being approximated.
    func click(x: Int, y: Int, count: Int = 1, mods: Int = 0) {
        guard let scene else { return }

        /* A dropdown open takes every press before the ordinary hit test
           does: `HitTester` has no idea the mirror is drawing a menu over
           whatever is underneath it (menu-open is UI state this page owns,
           not a fact the scene carries), so a point inside it would
           otherwise resolve to the window or desktop behind it. */
        if let openMenu, let menus = scene.menubar?.menus,
           menus.indices.contains(openMenu) {
            handleDropdownPress(x: x, y: y, trackingIndex: openMenu,
                                menus: menus, in: scene)
            return
        }

        let target = HitTester.hitTest(scene, x: x, y: y)
        note(selection: target)
        if case .menuTitle(let index) = target, let menus = scene.menubar?.menus,
           menus.indices.contains(index) {
            openDropdown(at: index, menu: menus[index])
            return
        }
        /* A double-click on a folder window's OWN item takes the aim path
           BEFORE the generic vocabulary sees it: `ActionModel.click` would
           turn this into `.finderOpen`, which `MirrorActionDriver` refuses
           outright — this host has no `script` lane, and open does not need
           one (see `MirrorFolderItemsAim`'s header). Every other target
           still goes through the ordinary route below, unchanged. */
        if count >= 2, case .windowItem(let windowID, let name,
                                        let windowTitle, _, _) = target,
           let window = scene.windows.first(where: { $0.id == windowID }) {
            openFolderItem(name: name, windowTitle: windowTitle,
                          window: window)
            return
        }
        /* The scene-aware overload, because three of the hit tester's targets
           name a window by an id and a window act is addressed by the
           window's IDENTITY. See `ActionModel.click(on:in:count:mods:)`. */
        let actions = ActionModel.click(on: target, in: scene,
                                        count: count, mods: mods)
        perform(actions, on: target)
    }

    // MARK: - The pane's own dropdown (menu-open UI state)

    /// **This page's own menu-bar tracking state: which menu (if any) is
    /// pulled down.** UI-local by the vocabulary's own ruling — opening a
    /// menu is this page's drawing, not a guest action
    /// (`ActionModel.click(on:...)`'s comment on `.menuTitle`) — so nothing
    /// downstream of the scene carries it; this page owns it the same way
    /// it owns `selectedItem`.
    @Published private(set) var openMenu: Int?

    /// The open menu's REAL per-item geometry (`menugeom`), once the paired
    /// guest has answered for it. `nil` covers every honest reason there is
    /// nothing here: nobody has asked yet, the ask is in flight, the guest
    /// refused (no NOW Extension, one that predates the act plane, or one
    /// that is dark), or the menu changed while the ask was in flight.
    /// `SceneRenderer` falls back to its own uniform 16px assumption in
    /// every one of those cases — never a guess dressed as a reading.
    @Published private(set) var openMenuGeometry: MirrorKit.MenuGeometry?

    /// Open the mirror's own dropdown for one menu-bar title, and ask the
    /// paired guest for its real geometry.
    ///
    /// The dropdown draws (with the fallback constant) the instant this is
    /// called — it does not wait on the ask below, the same way a real
    /// Menu Manager draws a menu before it knows exactly how a custom MDEF
    /// will lay out every row. `menugeom`'s answer, if one comes, upgrades
    /// the SAME drawing to real rects; it never blocks it.
    private func openDropdown(at index: Int, menu: MirrorKit.Scene.Menu) {
        openMenu = index
        openMenuGeometry = nil
        guard let driver else { return }
        Task { @MainActor in
            let result = await driver.adapter.menuGeom(.init(menu: menu.id))
            /* The menu that was open when this ask was MADE, not whatever
               is open when it ANSWERS — a person can close a menu, or open
               a different one, well inside 15s of network round trip, and
               that later state must not be overwritten by a stale answer
               to a question nobody is asking any more. */
            guard self.openMenu == index else { return }
            switch result {
            case .completed(let receipt):
                self.openMenuGeometry = .init(
                    menu: receipt.menu, width: receipt.width,
                    height: receipt.height,
                    orderedItems: receipt.items.map {
                        .init(top: $0.top, left: $0.left,
                             bottom: $0.bottom, right: $0.right)
                    })
            case .refused, .unavailable:
                /* Honest fallback, not a fault: the extension is absent,
                   stale, dark, or this process has not pumped since the
                   plane armed. The dropdown is already drawn and stays
                   drawn — `SceneRenderer`'s own uniform assumption — this
                   page simply has nothing real to upgrade it with. */
                self.openMenuGeometry = nil
            }
        }
    }

    /// Dismiss the pane's own dropdown, with no act sent — closing a menu
    /// by clicking away, or after selecting from it, is not itself
    /// something a Macintosh does; it is this page putting its drawing
    /// back the way it was.
    private func closeMenu() {
        openMenu = nil
        openMenuGeometry = nil
    }

    /// One press while the mirror's own dropdown is showing.
    ///
    /// Three outcomes, in the order a person at a real menu bar would
    /// expect: a press on one of ITS OWN items selects that item; a press
    /// on ANOTHER menu's title slides the tracking to that menu instead of
    /// requiring a second click (the classic Mac's own dragged-open
    /// behaviour); anything else — the window underneath, the desktop, the
    /// letterbox — dismisses the menu without acting on whatever is under
    /// it, because a click meant to close a menu is not also a click on
    /// the window it happened to land on.
    private func handleDropdownPress(x: Int, y: Int, trackingIndex: Int,
                                     menus: [MirrorKit.Scene.Menu],
                                     in scene: MirrorKit.Scene) {
        let menu = menus[trackingIndex]
        if let item = SceneRenderer.dropdownItem(
            menu, x: x, y: y, geometry: openMenuGeometry) {
            selectMenuItem(item, in: menu)
            return
        }
        if y >= 0, y < HitTester.menubarHeight,
           case .menuTitle(let index) = HitTester.hitTest(scene, x: x, y: y),
           index != trackingIndex, menus.indices.contains(index) {
            openDropdown(at: index, menu: menus[index])
            return
        }
        closeMenu()
    }

    /// A press on one item of the mirror's own open dropdown. Closes the
    /// menu first — selecting an item ends the tracking whether or not the
    /// act it produces is sendable, the same way a real menu closes on
    /// release regardless of what the application does with the command.
    ///
    /// `ActionModel.menuSelect` already refuses a separator (`[]`);
    /// `SceneRenderer.dropdownItem` should never hand one back in the first
    /// place (a separator's own rect, real or the uniform assumption, is
    /// not a selectable row), but the guard is repeated here rather than
    /// trusted across the seam, the same discipline `ActionModel.click`
    /// re-checks a control's `ref` for.
    private func selectMenuItem(_ item: MirrorKit.Scene.MenuItem,
                                in menu: MirrorKit.Scene.Menu) {
        closeMenu()
        let actions = ActionModel.menuSelect(menu: menu, item: item)
        guard !actions.isEmpty else { return }
        performNamed(actions, named: "\"\(item.title)\"")
    }

    /// **The aim path for one folder-window item.** Distinct from
    /// `perform(_:on:)` because this act's target is not the vocabulary's
    /// opaque reference — it is a NAME, and `MirrorFolderItemsAim` refuses to
    /// resolve it against anything but a position it fetches itself, fresh,
    /// at the moment of the open. See that type's header for why.
    private func openFolderItem(name: String, windowTitle: String,
                                window: MirrorKit.Scene.Window) {
        let named = "\"\(name)\""
        guard let scene else { return }
        guard let finderPSN = scene.processes?.first(where: {
            $0.name == "Finder"
        })?.psn else {
            lastAction = ActionReport(
                outcome: .unavailable, target: named,
                sentence: "This scene has not reported a Finder process, so "
                    + "there is no address to open \(named) at.")
            return
        }
        guard let folderItemsAim else {
            lastAction = ActionReport(
                outcome: .unavailable, target: named,
                sentence: "This window has no act lane — it is showing a "
                    + "scene without a machine behind it.")
            return
        }
        lastAction = ActionReport(outcome: .asking, target: named,
                                  sentence: "Asking the Mac…")
        Task { @MainActor in
            let outcome = await folderItemsAim.open(
                item: name, windowTitle: windowTitle, finderPSN: finderPSN,
                chrome: window)
            self.lastAction = Self.report(folderItem: outcome, on: named)
            if self.lastAction?.outcome.isDispatched == true {
                self.lastProbe = nil
                self.holdUntil = nil
                await self.lookAgainAfterActing()
            }
        }
    }

    /// Built once per listener, the same way `contentJoin` and
    /// `folderItemsJoin` are: a model without one refuses an open with a
    /// sentence rather than reaching for a stub.
    private lazy var folderItemsAim: MirrorFolderItemsAim? =
        listener.map(MirrorFolderItemsAim.init(listener:))

    /// `MirrorFolderItemsAim.Outcome` in the page's own words — the same
    /// three-way shape `report(_:on:)` reads off the ordinary act driver,
    /// kept separate because this outcome type carries no `.inert`: an open
    /// that reached this function always asked something.
    private static func report(folderItem outcome: MirrorFolderItemsAim.Outcome,
                               on named: String) -> ActionReport {
        switch outcome {
        case .dispatched(let sentence):
            return ActionReport(outcome: .dispatched, target: named,
                                sentence: sentence)
        case .refused(let sentence):
            return ActionReport(outcome: .refused, target: named,
                                sentence: sentence)
        case .unavailable(let sentence):
            return ActionReport(outcome: .unavailable, target: named,
                                sentence: sentence)
        }
    }

    /// **The mirror's own selection, because the guest's is unreadable.**
    ///
    /// A Finder shows selection by inverting the icon and reports it nowhere
    /// — it lives only in those pixels, and this page draws from what the Mac
    /// SAYS rather than from what it draws. So the pane presents selection
    /// the way the Finder would, from its own record of what was clicked.
    ///
    /// Two honest consequences, and neither is papered over: this is not
    /// evidence the guest selected anything (the act's own outcome is), and a
    /// selection made by the person sitting at the Macintosh does not appear
    /// here. It is feedback for the gesture, not a reading of the machine.
    @Published private(set) var selectedItem: String?

    private func note(selection target: HitTester.Target) {
        switch target {
        case .desktopItem(let name, _, _), .windowItem(_, let name, _, _, _):
            selectedItem = name
        case .desktop:
            /* Clicking the bare desktop deselects, as it does on the Mac.
               Only the desktop: a click on a window or a menu leaves the
               Finder's selection alone, so leaving ours alone is the
               faithful thing. */
            selectedItem = nil
        default:
            break
        }
    }

    /// **A drag on the drawing: a window moved or resized.**
    ///
    /// The gesture is the person's; what crosses is geometry. A title-bar
    /// drag becomes `winact move` with the window's new content origin and a
    /// grow-box drag becomes `winact resize` with its new content size — the
    /// answer the application's own `FindWindow`/`GrowWindow` would have
    /// produced, with no pixel path and no injected mouse in between (which
    /// is what a NOW connection cannot have: there is no emulator on the
    /// other end by assumption).
    ///
    /// The starting point decides what the drag IS, which is why it is hit
    /// tested rather than the end point: a drag that ends over another window
    /// is still a drag of the one it started on.
    func drag(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) {
        guard let scene else { return }
        let target = HitTester.hitTest(scene, x: start.x, y: start.y)
        let delta = (dx: end.x - start.x, dy: end.y - start.y)
        let window: MirrorKit.Scene.Window?
        let actions: [MirrorAction]
        switch target {
        case .titlebar(let id, _, _, _):
            window = scene.windows.first { $0.id == id }
            actions = window.map { ActionModel.windowMove($0, in: scene,
                                                          by: delta) } ?? []
        case .growBox(let id, _, _):
            window = scene.windows.first { $0.id == id }
            actions = window.map { ActionModel.windowResize($0, in: scene,
                                                            by: delta) } ?? []
        default:
            window = nil
            actions = []
        }
        guard !actions.isEmpty else {
            /* A drag that began anywhere else. Reported rather than
               swallowed: a person who dragged an icon expecting it to move
               has been told nothing by silence, and moving an icon is not a
               window act — the Finder owns that geometry and NOW's contract
               has no verb for it. */
            lastAction = ActionReport(
                outcome: .inert, target: Self.describe(target),
                sentence: "A drag moves or resizes a WINDOW here, by its "
                    + "title bar or its grow box. Nothing else on this "
                    + "drawing has a drag NOW's contract can carry.")
            return
        }
        perform(actions, on: target)
    }

    /// One gesture's actions, driven and reported. Shared by the press and
    /// the drag so the two cannot grow different ideas of what a refusal
    /// looks like.
    private func perform(_ actions: [MirrorAction],
                         on target: HitTester.Target) {
        guard !actions.isEmpty else {
            lastAction = Self.nothingToSend(target, named: Self.describe(target))
            return
        }
        performNamed(actions, named: Self.describe(target))
    }

    /// The same drive-and-report body `perform(_:on:)` runs, for a gesture
    /// with no `HitTester.Target` to derive a name from — a menu item lives
    /// inside the mirror's OWN open dropdown, at a point the scene's
    /// ordinary hit test was never asked about and has no case for. Callers
    /// must have already confirmed `actions` is non-empty: there is no
    /// `HitTester.Target` here for `nothingToSend` to read if it were not.
    private func performNamed(_ actions: [MirrorAction], named: String) {
        /* The vocabulary is asked before the lane is, and in that order for a
           reason: whether an act can be carried at all is a fact about NOW's
           contract, not about whether this window happens to have a wire
           behind it. A page with no lane that reported "no lane" for a
           positional click would name the wrong missing half — the click
           names nothing, and would be refused with a lane. */
        if case .unavailable(let reason) =
            ActionModel.availability(actions[0]) {
            lastAction = ActionReport(outcome: .unavailable, target: named,
                                      sentence: reason)
            return
        }
        guard let driver else {
            lastAction = ActionReport(
                outcome: .unavailable, target: named,
                sentence: "This window has no act lane — it is showing a "
                    + "scene without a machine behind it.")
            return
        }
        lastAction = ActionReport(
            outcome: .asking, target: named,
            sentence: "Asking the Mac…")
        Task { @MainActor in
            let outcomes = await driver.drive(actions)
            self.lastAction = Self.report(outcomes, on: named)
            /* A dispatched act is a reason to look again, and the driver's
               own sentence says why: whether the application acted on it is
               a question for the NEXT scene. Forgetting the probe's baseline
               is what makes the next tick fetch one. */
            if self.lastAction?.outcome.isDispatched == true {
                self.lastProbe = nil
                self.holdUntil = nil
                await self.lookAgainAfterActing()
            }
        }
    }

    /// **Act, settle, look once.**
    ///
    /// Forgetting the probe's baseline is enough for a page whose loop is
    /// running, and is nothing at all for a page that is paused — which is a
    /// person watching their click do nothing visible, on a product whose
    /// whole claim is that it shows you the other Mac. So a dispatched act
    /// asks for one scene on its own.
    ///
    /// **The settle is not politeness.** The act's own receipt says the event
    /// was handed to the application and nothing more; the application then
    /// has to reach its event loop and redraw. A scene fetched in the same
    /// breath would be a picture of the machine BEFORE it acted, arriving
    /// after the act — which reads as "the click did nothing" more
    /// convincingly than silence does. `settleAfterAct` is the wait, it is a
    /// GUESS at the redraw and marked as one (`WatchPolicy`), and the fetch
    /// after it is one ask and not a loop.
    private func lookAgainAfterActing() async {
        guard canFetch else { return }
        if watch.settleAfterAct > 0 {
            try? await Task.sleep(nanoseconds:
                UInt64(watch.settleAfterAct * 1_000_000_000))
        }
        /* `fetchScene` already declines while one is in flight, so an act
           during a fetch costs nothing and queues nothing — and the ceiling
           will bring the next one along anyway. */
        fetchScene()
    }

    /// The report for a gesture that produced no act. The distinction that
    /// matters — and the one the brief for this page is built on — is
    /// between *there was nothing to send* and *this thing cannot be
    /// addressed*. A control the scene drew but carries no reference for is
    /// the second, and it gets the vocabulary's own sentence rather than a
    /// new one written here.
    private static func nothingToSend(_ target: HitTester.Target,
                                      named: String) -> ActionReport {
        switch target {
        case .control(_, let control) where control.enabled:
            /* `ActionModel.click` answered [] for an enabled control, which
               leaves exactly one reason: no reference. Asked of the
               vocabulary rather than asserted here, so the two cannot drift
               into disagreeing about the same control. */
            if case .needsObservation(let command, let reason) =
                ActionModel.availability(
                    .axdo(ref: control.ref, count: 1, mods: 0, text: nil)) {
                return ActionReport(
                    outcome: .unavailable, target: named,
                    sentence: "\(reason) The host lane for \(command) is "
                        + "built; what is missing is a reference on the "
                        + "rendered control.")
            }
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "Nothing was sent for this press.")
        case .control:
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "This control reads as disabled in the scene the "
                    + "Mac sent. A classic application often disables its "
                    + "controls at rest, so this is not proof it would "
                    + "refuse — but nothing was sent.")
        case .growBox:
            /* Not "a drag cannot be carried" any more — it can, as
               `winact resize`, which is geometry rather than mouse motion.
               What is true is narrower: a grow box does nothing on a PRESS,
               here or on a Macintosh. */
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "The grow box resizes on a drag rather than a "
                    + "press. Drag it and the Mac is asked for the new size.")
        case .widget(_, let kind, _, _):
            /* Reached only for the windowshade: close and zoom both produce
               an act. `winact` has four actions and collapse is not one, so
               naming `zoom` for it would be this side deciding two different
               behaviours are alike. */
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "NOW's window verb moves, resizes, zooms and "
                    + "closes a window. Rolling one up is a fifth thing it "
                    + "does not carry, and zoom is not a near-enough "
                    + "substitute to send in its place.")
        case .scrollbar:
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "A scroll bar's thumb moves on a drag, not a "
                    + "press.")
        case .appMenu:
            /* Unlike `.menuTitle` below, this is still true: the switcher
               (the Application menu at the right of the bar) has no
               open/track state on this page yet — only the ordinary
               menu-bar dropdown does, since 2026-08-01 (`openDropdown`,
               `click(x:y:count:mods:)`). */
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "Opening a menu is this page's own drawing, and "
                    + "this page does not draw the Application menu's "
                    + "switcher yet. Nothing was sent to the Mac.")
        case .menuTitle:
            /* Unreachable from `click(x:y:count:mods:)`: a `.menuTitle` hit
               is intercepted there and opens the dropdown before
               `ActionModel.click` or `perform` ever sees it. Kept as an
               explicit case (rather than folding into `default`) so a
               future caller of `perform` directly gets an accurate
               sentence instead of the generic one below. */
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "Opening a menu is this page's own drawing, "
                    + "handled before a press reaches this function — "
                    + "reaching this case at all is a bug in the caller.")
        default:
            return ActionReport(
                outcome: .inert, target: named,
                sentence: "Nothing was sent for this press.")
        }
    }

    /// One report from a sequence's outcomes. The sequence stops at the
    /// first act that did not dispatch, so the LAST outcome is the one that
    /// decided how it ended.
    private static func report(_ outcomes: [MirrorActionDriver.Outcome],
                               on named: String) -> ActionReport {
        guard let last = outcomes.last else {
            return ActionReport(outcome: .inert, target: named,
                                sentence: "Nothing was sent for this press.")
        }
        switch last {
        case .dispatched(let sentence):
            return ActionReport(outcome: .dispatched, target: named,
                                sentence: sentence)
        case .refused(let sentence):
            return ActionReport(outcome: .refused, target: named,
                                sentence: sentence)
        case .unavailable(let sentence):
            return ActionReport(outcome: .unavailable, target: named,
                                sentence: sentence)
        case .inert:
            return ActionReport(outcome: .inert, target: named,
                                sentence: "Nothing was sent for this press.")
        }
    }

    /// What was pressed, in a phrase a person can check against what they
    /// pressed. Names come off the scene — never invented, never a
    /// coordinate dressed up as an identity.
    private static func describe(_ target: HitTester.Target) -> String {
        switch target {
        case .menuTitle(let index): return "menu title \(index + 1)"
        case .appMenu: return "the Application menu"
        case .appMenuItem(_, let name): return name
        case .widget(_, let kind, _, _): return "the \(kind) box"
        case .growBox: return "the grow box"
        case .control(_, let control):
            return control.title.isEmpty ? "a control" : "\"\(control.title)\""
        case .scrollbar: return "a scroll bar"
        case .titlebar: return "the title bar"
        case .content: return "the window"
        case .desktop: return "the desktop"
        case .windowItem(_, let name, _, _, _): return "\"\(name)\""
        case .desktopItem(let name, _, _): return "\"\(name)\""
        }
    }

    @Published private(set) var extensionEvidence: ExtensionEvidence = .unasked
    @Published private(set) var planeEvidence: PlaneEvidence = .unasked
    @Published private(set) var scene: MirrorKit.Scene?
    @Published private(set) var provenance: Provenance?
    /// The last document that would not decode, kept as prose. Distinct from
    /// having no scene: one is silence, the other is something that went
    /// wrong, and only the second is drawn as a fault.
    @Published private(set) var failure: String?

    /// What the last content join came to, as a sentence for the page.
    ///
    /// Nil until somebody asks for content. It is kept separate from
    /// `failure` on purpose: a scene that arrived and a content plane that
    /// could not be joined are two different states, and folding the second
    /// into the first would draw a working mirror as a fault.
    @Published private(set) var contentNote: String?

    /// Set for exactly one fetch, by whoever asked for content. Cleared on
    /// the way out either way — a flag left standing would make the next
    /// fetch, including one the LOOP made, join content it never asked for.
    private var contentAsked = false

    /// Built once per listener and kept, because it holds the ring cursor
    /// between joins. A new one each time would re-read the ring from zero.
    private lazy var contentJoin: MirrorContentJoin? =
        listener.map(MirrorContentJoin.init(listener:))

    /// One content join against the scene on screen. Called only from
    /// `fetchScene(withContent: true)`'s success path — never from the loop.
    private func joinContent() {
        guard let contentJoin, let scene else { return }
        joinsInFlight += 1
        contentJoin.join(into: scene) { [weak self] joined, outcome in
            guard let self else { return }
            self.joinsInFlight -= 1
            /* On EVERY exit, including the stale one below: the pass is
               owed to whichever join finishes last, and a join dropped for
               staleness is still a join that finished. */
            defer { self.scheduleIslandPass() }
            /* A join answers about the scene it was HANDED. If a newer scene
               landed while the drain was in flight, these ops describe a
               moment that is no longer on screen, and attaching them would
               put old drawing inside a new window. */
            guard self.scene?.seq == scene.seq,
                  self.scene?.capturedAt == scene.capturedAt else {
                self.contentNote =
                    "A newer scene arrived while the drawing was on its way, "
                    + "so it was dropped rather than drawn into a window it "
                    + "does not describe."
                return
            }
            if case .attached = outcome {
                self.scene = joined
                /* Remembered so the NEXT scene fetch — which decodes this
                   window's `display` back to nil, see `MirrorSceneAdapter`
                   — has something to carry forward. */
                self.contentHold.record(joined)
            }
            self.contentNote = outcome.sentence
        }
    }

    /// What the last folder-items join came to, as a sentence for the page.
    /// Nil while there is nothing worth saying — a scene with no Finder
    /// folder window open joins nothing, and silence is the honest report
    /// for that, not an empty note.
    @Published private(set) var folderItemsNote: String?

    /// Stateless — no ring cursor to carry — but built once per listener the
    /// same way `contentJoin` is, so a model without one simply cannot join.
    private lazy var folderItemsJoin: MirrorFolderItemsJoin? =
        listener.map(MirrorFolderItemsJoin.init(listener:))

    /// One folder-items join against the scene on screen. Called from
    /// `fetchScene`'s success path automatically — see the call site for why
    /// this one is not fetch-on-ask the way `joinContent` is.
    private func joinFolderItems() {
        guard let folderItemsJoin, let scene else { return }
        joinsInFlight += 1
        folderItemsJoin.join(into: scene) { [weak self] joined, outcome in
            guard let self else { return }
            self.joinsInFlight -= 1
            /* See `joinContent` — the last join to finish schedules the
               island pass, and this one is the LAST word on which windows
               have a semantic source at all. A guest that refuses the walk
               still has windows that need pixels, so every branch counts. */
            defer { self.scheduleIslandPass() }
            /* Same staleness guard `joinContent` uses: a walk answers about
               the scene it was HANDED, and a newer scene may have landed
               while it was in flight. */
            guard self.scene?.seq == scene.seq,
                  self.scene?.capturedAt == scene.capturedAt else {
                self.folderItemsNote =
                    "A newer scene arrived while the window walk was on its "
                    + "way, so it was dropped rather than drawn into "
                    + "windows it does not describe."
                return
            }
            switch outcome {
            case .joined(let windows, let items):
                if windows > 0 { self.scene = joined }
                self.folderItemsNote = Self.folderItemsSentence(
                    windows: windows, items: items,
                    ambiguous: folderItemsJoin.lastAmbiguous)
            case .refused(let reason), .unavailable(let reason):
                self.folderItemsNote = reason
            }
        }
    }

    /// The folder-items note's words, split out so the wording is testable
    /// without a join or a socket.
    static func folderItemsSentence(windows: Int, items: Int,
                                    ambiguous: Set<String>) -> String? {
        var parts: [String] = []
        if windows > 0 {
            parts.append("\(items) item\(items == 1 ? "" : "s") across "
                + "\(windows) folder window\(windows == 1 ? "" : "s").")
        }
        if !ambiguous.isEmpty {
            let names = ambiguous.sorted().map { "\"\($0)\"" }
                .joined(separator: ", ")
            parts.append(
                "\(names) has more than one open window sharing that "
                    + "title, and the Finder's own scripting terminology "
                    + "cannot tell them apart either — neither drew items.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Held content past the fetch that would otherwise wipe it. See
    /// `MirrorContentHold`'s header.
    private var contentHold = MirrorContentHold()
    /// This session's fetch counter — the eviction clock `MirrorContentHold`
    /// runs on. Advances once per `show(document:)`, live or replayed alike;
    /// a replayed fixture's windows key against a different psn/title and
    /// simply never match anything held, so running the same clock over
    /// both costs nothing and keeps there being only one.
    private var fetchIndex = 0

    // MARK: - The pixel-island fallback

    /// One window's interior, photographed. **The last plane, not the first**
    /// — see `islandPass()` for the hierarchy and `SceneIslands` for the
    /// lifecycle it feeds.
    ///
    /// `@MainActor` because the only real implementation drives the listener,
    /// which is; a test's fake is trivially satisfied by the same annotation.
    /// It SUSPENDS rather than blocking, and that is the whole design
    /// decision this seam exists to state — `SceneIslands.Capture`'s header
    /// carries the argument (the reply and its watchdog both arrive on the
    /// main queue, so waiting on the main queue can only deadlock).
    typealias IslandCapture = @MainActor (MirrorKit.Rect) async throws
        -> PixelIsland

    /// Supplied by a test. Nil in the app, where the listener builds one.
    private let injectedIslandCapture: IslandCapture?

    /// What a refused capture was refused for, and what the page may say
    /// about it. Nil while there is nothing to say — which is the ordinary
    /// case: a pass that captured nothing because every window already had
    /// its pixels is the system working.
    @Published private(set) var islandNote: String?

    /// The island policy's state — held pixels, their content signatures,
    /// the eviction clock. Lives here rather than in the policy's callers so
    /// there is one store per page, not one per pass.
    private var sceneIslands = SceneIslands()

    /// One pass at a time, and one more if a trigger arrived while a pass was
    /// running. A second concurrent pass would put a second capture on a wire
    /// that serves one transfer at a time, and dropping the trigger outright
    /// would lose the redraw signal that caused it.
    private var islandPassInFlight = false
    private var islandPassWanted = false

    /// How many plane joins are outstanding for the scene on screen.
    ///
    /// **The island pass waits for zero.** Both planes above this one answer
    /// asynchronously and in whichever order the guest replies, and a pass
    /// that ran between them photographs a window that is about to be told
    /// what it contains — measured, not theorised: the first version of this
    /// wiring scheduled off `joinFolderItems`'s completion alone and spent a
    /// capture on a Finder window every time the item walk happened to answer
    /// before the content drain did.
    private var joinsInFlight = 0

    /// Built once and kept, the way `contentJoin` is. Nil when nothing can
    /// capture — no injected fake and no listener — so a model without a wire
    /// simply never photographs anything rather than photographing into a
    /// stub that always fails.
    private lazy var islandCapture: IslandCapture? = {
        if let injectedIslandCapture { return injectedIslandCapture }
        guard let listener else { return nil }
        return { rect in
            /* `requestCapture*` REPLACES the listener's single pending
               completion (`GuestListener.isCapturePending`'s own header says
               so), so starting one here while a person's Screenshots capture
               is in flight would leave THEIR completion never called. The
               island plane is the lowest-priority reason to take that lane;
               it yields, and the next pass asks again. */
            guard !listener.isCapturePending else {
                throw IslandCaptureRefusal(
                    message: "A capture was already on its way, so this "
                        + "window's interior was not asked for. The pixels "
                        + "already held stay on screen.")
            }
            let delivery = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<GuestListener
                    .CaptureDelivery, Error>) in
                listener.requestCaptureRegion(
                    left: rect.l, top: rect.t, right: rect.r, bottom: rect.b
                ) { result in
                    switch result {
                    case .success(let delivery):
                        continuation.resume(returning: delivery)
                    case .failure(let failure):
                        continuation.resume(
                            throwing: IslandCaptureRefusal(
                                message: failure.message))
                    }
                }
            }
            return try delivery.makePixelIsland()
        }
    }()

    /// A capture that did not happen, in the words of whoever refused it.
    /// Distinct from the adapter's own errors so a reader can tell "the Mac
    /// said no" from "the bytes would not rasterise".
    struct IslandCaptureRefusal: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Whether this page may photograph a window at all right now.
    ///
    /// **Inside a started session, and nowhere else.** A capture is the most
    /// expensive thing this page can ask for (~1 s of the one bulk lane, per
    /// window), and a session is exactly the statement that a person asked
    /// for a live view and is watching it. A replayed fixture can never reach
    /// here — it does not make a session streaming (`Provenance.isLive`) —
    /// and `stopSession` tears the held pixels down.
    private var islandsRunning: Bool {
        sessionState == .starting || sessionState == .streaming
    }

    /// Ask for a pass, coalesced. Called from the join completions rather
    /// than from the fetch's success path, because both of the joins ABOVE
    /// this plane decide whether a window needs it at all, and a pass that
    /// ran before they landed would photograph a Finder window ~1 s before
    /// learning it had items — a second of somebody's Mac spent on pixels
    /// the renderer would then refuse to draw.
    private func scheduleIslandPass() {
        guard pixelDrawEnabled, islandsRunning, islandCapture != nil,
              scene != nil else { return }
        /* Whoever finishes last schedules; the earlier ones do nothing. */
        guard joinsInFlight == 0 else { return }
        guard !islandPassInFlight else {
            islandPassWanted = true
            return
        }
        Task { @MainActor [weak self] in await self?.islandPass() }
    }

    /// Photograph the windows that have no semantic source, hold the rest.
    ///
    /// **The plane hierarchy, and why this is last.** A Finder window with
    /// joined `items` is a MODEL and the renderer draws it in preference to
    /// any island it holds (`SceneRenderer`'s content branch tests
    /// `win.items == nil` first) — so capturing one costs a second of the
    /// other Mac to produce pixels that can never be shown. `SceneIslands`
    /// skips those windows; this is the reason it does.
    ///
    /// **What makes a window re-photograph.** Not a timer: the blit ticks the
    /// content join already drained. `SceneIslands` signs each held island
    /// with its content rect plus the newest large `bits` op over it, so a
    /// window is re-read when the guest actually redrew it and reuses its
    /// pixels when it did not.
    ///
    /// `internal` rather than private so a test can drive one pass and await
    /// it — the same reason `watchTick` is.
    func islandPass() async {
        guard !islandPassInFlight else {
            islandPassWanted = true
            return
        }
        islandPassInFlight = true
        defer { islandPassInFlight = false }
        repeat {
            islandPassWanted = false
            await onePass()
        } while islandPassWanted
    }

    private func onePass() async {
        guard pixelDrawEnabled, islandsRunning, let capture = islandCapture,
              var working = scene else { return }
        /* A pass answers about the scene it STARTED on, the same staleness
           rule both joins live by — and here it matters most, because a
           capture is the longest thing this page waits for. */
        let seq = working.seq, capturedAt = working.capturedAt

        var policy = sceneIslands
        /* The redraw signal. Ops reach a window only through
           `MirrorContentJoin`, which attaches to the FRONT window alone under
           its single-port rule, so this concatenation is that window's ops
           today — and stays correct if a later join attributes more, since
           the policy matches each op against the window's own content rect
           before believing it. */
        policy.displayOps = working.windows.compactMap(\.display).flatMap { $0 }
        /* One number, not two: a held island and held content are the same
           promise about the same window, so they expire on the same clock.
           See `MirrorContentHold`. */
        policy.gracePolls = contentGraceFetches
        let spentBefore = policy.bytesFetched
        await policy.attach(&working, poll: fetchIndex, capture: capture)
        let captured = policy.bytesFetched - spentBefore

        /* The toggle may have gone off WHILE this capture was outstanding —
           a round trip already spent cannot be un-spent, but writing its
           answer back now would undo the very drop `setPixelDrawEnabled`
           just did. Discarding here, after the await rather than before it,
           is what makes the drop the last word regardless of how the two
           race. */
        guard pixelDrawEnabled else { return }

        /* The PIXELS are kept whichever way the staleness check goes: they
           cost a second of somebody's Mac and they describe a window, not a
           scene. Only the scene they were about may be stale.

           Writing the policy back can lose at most one fetch's worth of
           "these windows were present" — a `show` that landed mid-pass
           touched the store this copy predates. That cannot evict a living
           window: the next `show` or pass touches it again, well inside a
           grace measured in tens of fetches. */
        sceneIslands = policy
        guard var current = scene, current.seq == seq,
              current.capturedAt == capturedAt else {
            islandNote = "A newer scene arrived while a window's interior "
                + "was being photographed, so it was not drawn into windows "
                + "it does not describe. The pixels were kept."
            return
        }

        /* **Write back the ONE field this plane owns, not the whole scene.**
           `seq`/`capturedAt` catch a newer SCENE; they cannot catch another
           PLANE landing on the same one, and the joins do exactly that — a
           capture takes ~1 s, which is ample time for a folder walk to
           answer. Assigning the copy wholesale therefore reverted the items
           that had just been joined onto it (found by test, not by
           reasoning: `testAWindowWithFolderItemsIsNeverPhotographed` waited
           five seconds for items that had arrived and been overwritten).

           Matched by `MirrorContentHold`'s keying rather than by index,
           which is z-order and turns over on a raise — and re-checked
           against `items` here, at the last possible moment, so a window
           that acquired a semantic source mid-capture is drawn from it. */
        /* `uniquingKeysWith`, not `uniqueKeysWithValues`, which TRAPS on a
           collision. The keying rule disambiguates same-titled windows by
           corner, so a collision needs two windows of one app sharing a
           title AND a top-left — rare, and a page that mirrors somebody's
           Mac does not get to crash on a coincidence. First wins: scene
           order is front-first. */
        let capturedIslands = Dictionary(
            zip(MirrorContentHold.keys(for: working.windows),
                working.windows.map(\.island)),
            uniquingKeysWith: { first, _ in first })
        let keys = MirrorContentHold.keys(for: current.windows)
        for i in current.windows.indices where current.windows[i].items == nil {
            guard let island = capturedIslands[keys[i]] ?? nil else { continue }
            current.windows[i].island = island
        }
        scene = current
        islandNote = captured > 0
            ? "\(captured) bytes of window interior were read from this Mac."
            : nil
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    private var guestName: String {
        if case .connected(let name, _) = connection { return name }
        return ""
    }

    /// The one door in. `irVersion` is the envelope's number — the gate runs
    /// on it before the body is parsed, which is `NOWSceneCodec`'s contract
    /// and the reason this does not decode first and check after.
    func show(document: Data, irVersion: Int = 1, provenance: Provenance) {
        /* Whatever the last ask ended in, this is a newer answer than that
           refusal. Left standing, a refusal from a minute ago would sit over
           a scene that plainly arrived. */
        fetch = .idle
        do {
            let doc = try NOWSceneCodec.decode(irVersion: irVersion,
                                               document: document)
            var decoded = MirrorSceneAdapter.scene(from: doc)
            /* Every window's `display` decodes to nil here — the adapter's
               own header says so. `apply` fills each nil back in from what a
               PRIOR fetch joined, so a background window's interior survives
               this fetch instead of reading as wiped. */
            fetchIndex += 1
            contentHold.apply(to: &decoded, at: fetchIndex,
                              grace: contentGraceFetches)
            /* The pixel plane's half of the same rule, and it must happen
               HERE rather than in the capture pass: that pass suspends for
               as long as a round trip takes, and a window whose pixels are
               already in hand must not read as blank for that second. No
               wire is touched — `reattachHeld` cannot fetch. */
            sceneIslands.reattachHeld(&decoded, poll: fetchIndex)
            scene = decoded
            self.provenance = provenance
            failure = nil
            /* The first scene under a starting session is what makes it a
               STREAMING one — not the press that began it, which only says
               a person asked. A replayed fixture is never live, so it can
               never make this transition; see `Provenance.isLive`. */
            if provenance.isLive, sessionState == .starting {
                sessionState = .streaming
            }
        } catch let error as NOWSceneDecodeError {
            fail(Self.describe(error), provenance: provenance)
        } catch {
            fail("\(error)", provenance: provenance)
        }
    }

    /// Puts the page back to its resting state without touching what this
    /// host believes about the machine.
    func clearScene() {
        scene = nil
        provenance = nil
        failure = nil
        fetch = .idle
        /* The note describes a scene that is no longer here. */
        contentNote = nil
        folderItemsNote = nil
    }

    /// Seams for the probe that does not exist yet. They are `internal` and
    /// called from tests only; when something learns these facts for real it
    /// calls them instead of growing a second path.
    func record(extensionEvidence: ExtensionEvidence) {
        self.extensionEvidence = extensionEvidence
    }

    func record(planeEvidence: PlaneEvidence) {
        self.planeEvidence = planeEvidence
    }

    /// A machine leaving takes its scene with it — but only a LIVE one. A
    /// replayed fixture is this Mac's document and has nothing to do with
    /// who is on the wire, so it stays on screen.
    func guestLeft(_ key: GuestKey) {
        /* A running session lost the machine it was streaming from — that
           is `guestGone`, not `stopped`: nobody asked for this, and Start
           offered again is an attempt to RESUME, not a fresh session. A
           session that had already been stopped, or never started, has
           nothing to lose here. */
        if sessionState == .starting || sessionState == .streaming {
            sessionState = .guestGone
        }
        contentArmed = false
        pumpNote = nil
        /* Held content is keyed by psn/title on ONE machine's windows; kept
           across, it would answer the next Mac's windows by coincidence of
           name rather than by anything real. */
        contentHold = MirrorContentHold()
        /* Same argument, and stronger: an island is a PHOTOGRAPH of one
           machine's screen. Keyed by psn/title, it would answer the next
           Mac's window of the same name with the last one's pixels — the
           mislabelling the occlusion rule exists to prevent, one machine
           further out. */
        sceneIslands = SceneIslands()
        islandNote = nil
        fetchIndex = 0
        extensionEvidence = .unasked
        planeEvidence = .unasked
        /* A ring cursor is a byte count into ONE machine's ring. Carried
           across, it reads against the next Mac's ring as either a colossal
           overrun or bytes that were never written. */
        contentJoin?.guestChanged()
        contentAsked = false
        contentNote = nil
        /* A refusal is a thing ONE Mac said. It does not travel to the next
           machine on the wire, and it must not outlive the one that said it:
           the listener settles an in-flight scene with a disconnect reason,
           and that answer describes a connection that no longer exists. */
        fetch = .idle
        /* The loop's whole memory is about the machine that left: what was
           in front of it, when its last scene landed, what it collided
           with. None of that describes the next Mac on the wire, and a
           stale probe token carried across would make the first tick of the
           next connection report a change that is really a change of
           MACHINE. `isLive` is deliberately NOT reset — it is the person's
           setting, not the guest's. */
        lastProbe = nil
        lastSceneAt = nil
        lastSeq = nil
        probeUsable = true
        backoff = 0
        holdUntil = nil
        liveNote = nil
        /* A gesture's outcome is a claim about a machine's answer. The
           machine is gone; the claim goes with it. */
        lastAction = nil
        if provenance?.isLive == true { clearScene() }
        updateWatch()
    }

    private func fail(_ reason: String, provenance: Provenance) {
        scene = nil
        self.provenance = provenance
        failure = reason
    }

    private static func describe(_ error: NOWSceneDecodeError) -> String {
        switch error {
        case .unsupportedMajor(let major):
            return "This scene announces IR major \(major), which this "
                + "version of New Old World does not read. It was refused "
                + "before it was parsed."
        case .versionDisagreement(let envelope, let body):
            return "The scene's envelope says IR \(envelope) and its body "
                + "says \(body). A document that cannot agree with itself "
                + "about what it is does not get read."
        case .malformed(let detail):
            return "The scene could not be read: \(detail)"
        }
    }

    /// What the pane draws. Derived, never stored — one place decides, and a
    /// test can ask it without a view.
    var state: MirrorPaneState {
        if let failure, let provenance {
            return .unreadable(reason: failure, provenance: provenance)
        }
        if let scene, let provenance {
            return MirrorSceneAdapter.hasScreen(scene)
                ? .showing(scene: scene, provenance: provenance)
                : .sceneWithoutScreen(provenance: provenance)
        }
        guard isConnected else { return .noGuest }
        /* The ask outranks the ladder, and in this order. A fetch in flight
           is the most recent true thing about this page; a refusal is the
           most recent ANSWER, and both are more useful than repeating what
           the page believed before anyone asked.

           Both sit BELOW the scene checks above, on purpose: a refused
           refresh must not blank a scene that arrived perfectly a minute
           ago. `fetchNote` is how that refusal is still said out loud while
           the drawing stays. */
        switch fetch {
        case .looking:
            return .looking(guest: guestName)
        case .refused(let reason):
            return .refused(guest: guestName, reason: reason)
        case .idle:
            break
        }
        switch extensionEvidence {
        case .unasked:
            return .notLookedYet(guest: guestName)
        case .absent:
            return .extensionAbsent(guest: guestName)
        case .present:
            switch planeEvidence {
            case .unasked:
                return .notLookedYet(guest: guestName)
            case .unarmed:
                return .planeUnarmed(guest: guestName)
            case .armed:
                return .armedNoSceneYet(guest: guestName)
            }
        }
    }

    /// The last refusal, for the case `state` cannot carry it: a scene is on
    /// screen and a refresh was declined.
    ///
    /// Not a second source of truth — it is the same stored `fetch`, answering
    /// a different question. `state` answers "what does this page DRAW";
    /// this answers "what did the last ask COME TO". While there is nothing
    /// drawn the two agree, because `state` reports the refusal itself.
    var fetchNote: String? {
        guard case .refused(let reason) = fetch else { return nil }
        return reason
    }
}

/// The page's states, as one closed set.
///
/// An enum rather than a handful of booleans in the view, because "what does
/// this page show when there is nothing to show" is a decision with a right
/// answer per case, and a view assembling it from flags gets combinations
/// nobody designed — a spinner over an error, a hint about arming a plane on
/// a Mac that is not connected.
enum MirrorPaneState: Equatable {
    /// Nothing is on the wire.
    case noGuest
    /// A Mac is connected and nobody has asked it what it has.
    case notLookedYet(guest: String)
    /// A scene has been asked for and has not come back yet.
    case looking(guest: String)
    /// The ask was answered no, and this is what was said. **Not a fault**:
    /// the commonest reason is that the Mac is doing one of the other things
    /// its single transfer lane carries, which is the system working.
    case refused(guest: String, reason: String)
    /// Asked: this Mac has no NOW Extension.
    case extensionAbsent(guest: String)
    /// The extension is there and its scene plane is dormant.
    case planeUnarmed(guest: String)
    /// Armed, and no scene has arrived yet.
    case armedNoSceneYet(guest: String)
    /// A scene, and where it came from.
    case showing(scene: MirrorKit.Scene, provenance: MirrorModuleModel.Provenance)
    /// A scene that reported no screen size. Not a fault and not a blank
    /// canvas: the producer did not say how big the screen is, so there is
    /// nothing to fit the drawing into.
    case sceneWithoutScreen(provenance: MirrorModuleModel.Provenance)
    /// A document that would not decode. The only fault in the set.
    case unreadable(reason: String, provenance: MirrorModuleModel.Provenance)

    /// The one state drawn as something wrong. Everything else is idle, and
    /// idle is drawn as idle.
    var isFault: Bool {
        if case .unreadable = self { return true }
        return false
    }

    /// True when the page has something to draw rather than something to say.
    var hasScene: Bool {
        if case .showing = self { return true }
        return false
    }

    /// The resting copy: a glyph, a headline, what is true, and what would
    /// change it. Data rather than view code so the words are testable and
    /// so no state can reach the screen without having been written.
    var resting: MirrorRestingCopy? {
        switch self {
        case .showing:
            return nil
        case .noGuest:
            return MirrorRestingCopy(
                symbol: "desktopcomputer",
                title: "No Mac Connected",
                message: "The other Mac dials this one. When it connects, "
                    + "this page can show what is on its screen — drawn "
                    + "from what the Mac says is there, not from its pixels.",
                next: "A recorded scene can be opened here at any time, "
                    + "with or without a Mac on the wire.")
        case .notLookedYet(let guest):
            return MirrorRestingCopy(
                symbol: "questionmark.circle",
                title: "Not Looked Yet",
                message: "\(guest) is connected. Whether it has the NOW "
                    + "Extension — the resident piece that can see other "
                    + "programs' windows — has not been asked.",
                /* This line used to say nothing on this side asks. Something
                   does now, and it is the person reading this: asking makes
                   the Mac walk every window it has, so it happens when they
                   say so and not because they opened a page. */
                next: "Look Now asks \(guest) to walk its screen and send "
                    + "back what it finds. A recorded scene can be opened "
                    + "here instead, at any time.")
        case .looking(let guest):
            return MirrorRestingCopy(
                symbol: "hourglass",
                title: "Looking",
                message: "\(guest) was asked to walk its screen. It visits "
                    + "every program and every window to answer, which takes "
                    + "a moment on a Macintosh of this vintage.",
                next: "The scene appears here when it arrives.")
        case .refused(let guest, let reason):
            return MirrorRestingCopy(
                /* A speech bubble, not a warning triangle. \(guest) answered
                   the question — the answer was no. */
                symbol: "bubble.left",
                title: "Not This Time",
                message: "\(guest) was asked for a scene and did not send "
                    + "one. \(reason)",
                next: "Look Now asks again. Nothing about \(guest) was "
                    + "changed by the refusal, and nothing was drawn from it.")
        case .extensionAbsent(let guest):
            return MirrorRestingCopy(
                symbol: "puzzlepiece.extension",
                title: "No NOW Extension",
                message: "\(guest) is connected and running NOW, and that is "
                    + "enough for every other page. Only this one needs the "
                    + "NOW Extension: a program can read its own windows, "
                    + "and reading another program's needs code resident "
                    + "inside it.",
                next: "Install the NOW Extension on \(guest) and restart it.")
        case .planeUnarmed(let guest):
            return MirrorRestingCopy(
                symbol: "moon.zzz",
                title: "Scene Plane Dormant",
                message: "\(guest) has the NOW Extension and its scene plane "
                    + "is asleep. That is how it ships: a plane runs no code "
                    + "at all until something asks for it, so a Mac that "
                    + "never opens this page never runs a window walk.",
                /* Was: "what this page will do when it can ask for a
                   scene". It can ask now. */
                next: "Look Now asks for a scene, which is what arms it.")
        case .armedNoSceneYet(let guest):
            return MirrorRestingCopy(
                symbol: "clock",
                title: "Nothing on Screen",
                /* Rewritten. This used to be the first-second-or-two state of
                   a page that was waiting for a scene to arrive by itself.
                   Scenes do not arrive by themselves — they are fetched — so
                   the only way here now is having HAD one: a scene answered,
                   and then was closed. Saying "waiting" would describe a page
                   that is not waiting for anything. */
                message: "\(guest) has answered this page before, so its NOW "
                    + "Extension is there and its scene plane is armed. "
                    + "Nothing is being shown right now.",
                next: "Look Now asks \(guest) for a fresh scene.")
        case .sceneWithoutScreen(let provenance):
            return MirrorRestingCopy(
                symbol: "rectangle.dashed",
                title: "No Screen Size Reported",
                message: "This scene from \(provenance.label) describes "
                    + "windows but never says how big the screen is, so "
                    + "there is nothing to fit them into. The scene is not "
                    + "damaged — the producer did not report that plane.",
                next: "A scene from a newer guest build will carry it.")
        case .unreadable(let reason, let provenance):
            return MirrorRestingCopy(
                symbol: "exclamationmark.triangle",
                title: "Scene Could Not Be Read",
                message: "\(provenance.label): \(reason)",
                next: "Nothing was drawn from it. A scene is refused whole "
                    + "rather than shown in part.")
        }
    }
}

/// A resting state's words. Four fields, and the fourth is the point: a page
/// that says what is true without saying what would change it is a page that
/// reads as broken.
struct MirrorRestingCopy: Equatable {
    let symbol: String
    let title: String
    let message: String
    /// What a person can do, or what will happen next. Never empty.
    let next: String
}

extension MirrorModuleModel.Provenance {
    /// How the page names this scene's origin, in one phrase it can drop into
    /// a sentence.
    var label: String {
        switch self {
        case .fixture(let name): return "Recorded scene \(name)"
        case .guest(let name): return "\(name)"
        }
    }

    /// The banner over the drawing. A replay must never read as this Mac,
    /// now — that is the whole reason provenance is carried at all.
    var banner: String {
        switch self {
        case .fixture(let name):
            return "Replayed from \(name) — a recording, not this Mac now"
        case .guest(let name):
            /* Not "live". A scene is FETCHED, one ask at a time, and by
               the time it is drawn it is a description of a moment that has
               passed. Calling it live would make the page's own words the
               thing that misleads — the same failure the replay banner
               beside it exists to prevent. */
            return "From \(name) — the moment it was asked, not a live view"
        }
    }
}
