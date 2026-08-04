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
    var status: String { lastAct.isEmpty ? ambient : lastAct }

    /// NOW addresses elements by reference and has no positional click
    /// verb — `contract/asyncapi.yaml` states that omission deliberately.
    /// Both halves matter: the first is what makes this mirror drivable on
    /// metal, the second is what makes a click on bare desktop a named
    /// refusal instead of a silence.
    nonisolated var planes: ActionPlanes { .residentActPlane }

    private let listener: GuestListener
    private let engineRegistry: MirrorStateEngineRegistry?
    private let act: AgentIntegrationActControl
    private let cycleIO: NOWMirrorCycleIO
    private let interval: TimeInterval
    private let planePolicy: @MainActor (GuestKey) -> Set<MirrorPlaneID>
    private let finderRefreshOverride: (@MainActor (
        MirrorKit.Scene, Int, @escaping () -> Void
    ) -> Void)?
    private let visibilityRefreshOverride: (@MainActor (
        MirrorKit.Scene, Int, @escaping () -> Void
    ) -> Void)?
    private let lifecycleDidChange: @MainActor () -> Void
    private var running = false
    private var runGeneration = 0
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
    /// Cached against `FinderItems.layoutKey`, which changes when a
    /// window moves, resizes or SCROLLS - three Apple events per
    /// container is cheap (0.3s for 33 items, measured) but not cheap
    /// enough to spend on every frame of a mirror.
    private var icons: [String: [MirrorKit.Scene.DesktopItem]] = [:]
    private var iconLayout: String = "<none>"
    private var fetchingIcons = false
    private var iconTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var actGeneration = 0
    private var settlementTracker = MirrorSettlementTracker()
    private var planCorrelation: String?
    private var planSettlement = "unknown"
    private var mutationBroker: MirrorMutationBroker?
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
         finderRefreshOverride: (@MainActor (
             MirrorKit.Scene, Int, @escaping () -> Void
         ) -> Void)? = nil,
         visibilityRefreshOverride: (@MainActor (
             MirrorKit.Scene, Int, @escaping () -> Void
         ) -> Void)? = nil,
         cycleIO: NOWMirrorCycleIO? = nil,
         lifecycleDidChange: @escaping @MainActor () -> Void = {}) {
        self.listener = listener
        self.engineRegistry = engineRegistry
        self.act = act
        let content = NOWMirrorContentPlane(listener: listener)
        self.cycleIO = cycleIO ?? .live(listener: listener, content: content)
        self.interval = interval
        self.planePolicy = planePolicy
        self.finderRefreshOverride = finderRefreshOverride
        self.visibilityRefreshOverride = visibilityRefreshOverride
        self.lifecycleDidChange = lifecycleDidChange
    }

    // MARK: - The poll

    func start() {
        guard !running else { return }
        runGeneration &+= 1
        iconTask?.cancel()
        iconTask = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        fetchingIcons = false
        guard let key = cycleIO.activeKey() else {
            ambient = "no Mac is connected"
            return
        }
        pinnedGuestKey = key
        shadowEngine = engineRegistry?.engine(for: key)
        _ = shadowEngine?.setEnabledPlanes(planePolicy(key))
        scene = shadowEngine?.snapshot?.scene ?? scene
        mutationBroker = shadowEngine.map {
            MirrorMutationBroker(journal: $0.operations)
        }
        running = true
        cycleGeneration = nil
        pollRequestedAfterCycle = false
        cycleIO.guestChanged()
        ambient = "asking for a scene…"
        lifecycleDidChange()
        poll()
    }

    func stop() {
        runGeneration &+= 1
        let stoppingGeneration = runGeneration
        running = false
        cycleGeneration = nil
        pollRequestedAfterCycle = false
        rearmTask?.cancel()
        rearmTask = nil
        iconTask?.cancel()
        iconTask = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        fetchingIcons = false
        guard let stoppingKey = pinnedGuestKey,
              stoppingKey == cycleIO.activeKey() else {
            ambient = "stopped; pinned Mac was not active"
            pinnedGuestKey = nil
            shadowEngine = nil
            mutationBroker?.sessionChanged()
            mutationBroker = nil
            lifecycleDidChange()
            return
        }
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
                  self.runGeneration == stoppingGeneration,
                  self.pinnedGuestKey == stoppingKey else {
                return
            }
            self.ambient = failure.map {
                "stopped; Content claim release refused: \($0)"
            } ?? "stopped"
            self.pinnedGuestKey = nil
            self.shadowEngine = nil
            self.mutationBroker?.sessionChanged()
            self.mutationBroker = nil
            self.lifecycleDidChange()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 11_000_000_000)
                self?.lifecycleDidChange()
            }
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
        cycleIO.requestScene(
            pinnedGuestKey, planes.contains(.semantics),
            planes.contains(.interaction)) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentCycle(generation) else { return }
            switch result {
            case .success(let delivery):
                guard delivery.guestKey == self.pinnedGuestKey else {
                    self.ambient = "ignored a scene from a different Mac"
                    self.finishCycle(generation)
                    return
                }
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
                self.ambient = failure.refusedByGuest
                    ? "the Mac declined: \(failure.message)"
                    : failure.message
            }
            self.finishCycle(generation)
        }
    }

    private func accept(_ delivery: GuestListener.SceneDelivery,
                        generation: Int) {
        guard isCurrentCycle(generation) else { return }
        do {
            var decoded = try NOWMirrorSceneDecoder.decode(
                irVersion: delivery.irVersion, document: delivery.document)
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
            let menuStatus = continuity.retainedAppleItems
                ? " · Apple menu expected-stale" : ""
            guard pinnedGuestKey == cycleIO.activeKey() else {
                shadowEngine?.compareVisible(decoded)
                scene = projectedScene(fallback: decoded)
                ambient = "(decoded.windows.count) windows · pinned Mac "
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
                    self.refreshComplements(decoded,
                                            generation: generation) {
                        guard self.isCurrentCycle(generation) else { return }
                        self.ambient = "\(decoded.windows.count) windows · "
                            + (failure.map {
                                "content release refused: \($0)"
                            } ?? "content off") + menuStatus
                        self.finishCycle(generation)
                        self.lifecycleDidChange()
                    }
                }
                return
            }
            cycleIO.joinContent(decoded) { [weak self] update in
                guard let self else { return }
                guard self.isCurrentCycle(generation) else { return }
                _ = self.shadowEngine?.enrichContent(update.scene)
                self.observeOperations()
                self.shadowEngine?.compareVisible(update.scene)
                self.scene = self.projectedScene(fallback: update.scene)
                /* The Finder roster is part of this structural cycle. The
                   old code launched it after P3 and immediately rearmed the
                   next poll, so a later scene could win while the older
                   roster was still in flight. Keep the cycle open until the
                   exact layout's bounded pages have settled. */
                self.refreshComplements(update.scene,
                                        generation: generation) {
                    guard self.isCurrentCycle(generation) else { return }
                    self.ambient = "\(update.scene.windows.count) windows · walk "
                        + "\(delivery.walkMs.map { "\($0)ms" } ?? "?") · transfer "
                        + "\(delivery.transferMs)ms · \(update.sentence)"
                        + menuStatus
                    self.finishCycle(generation)
                    self.lifecycleDidChange()
                }
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

    private func isCurrentCycle(_ generation: Int) -> Bool {
        running && runGeneration == generation
            && cycleGeneration == generation
    }

    /// Drain one cycle exactly once. A policy toggle made while scene or
    /// content was in flight earns one immediate follow-up; the ordinary
    /// interval owns every other continuation.
    private func finishCycle(_ generation: Int) {
        guard isCurrentCycle(generation) else { return }
        cycleGeneration = nil
        if pollRequestedAfterCycle {
            pollRequestedAfterCycle = false
            poll()
        } else {
            rearm()
        }
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
        var out = scene
        if let desktop = icons[Self.desktopKey] { out.desktopItems = desktop }
        out.windows = out.windows.map { win in
            guard FinderItems.isFolderWindow(win),
                  let items = icons[win.title] else { return win }
            var w = win
            w.items = items
            return w
        }
        return out
    }

    private static let desktopKey = "\u{0}desktop"

    private static func iconLayoutKey(_ scene: MirrorKit.Scene) -> String {
        let folders = scene.windows.filter(FinderItems.isFolderWindow)
        return (["desktop"] + folders.map(FinderItems.layoutKey))
            .joined(separator: "|")
    }

    /// Asynchronous planes settle one structural generation before the next
    /// starts. Each contribution remains independently retained by the state
    /// engine; this ordering only prevents two guest commands from racing on
    /// the cooperative wire lane.
    private func refreshComplements(_ scene: MirrorKit.Scene,
                                    generation: Int,
                                    completion: @escaping () -> Void) {
        refreshIconsIfStale(scene, generation: generation) { [weak self] in
            guard let self else { return }
            self.refreshVisibility(scene, generation: generation,
                                   completion: completion)
        }
    }

    private func refreshIconsIfStale(_ scene: MirrorKit.Scene,
                                     generation: Int,
                                     completion: @escaping () -> Void) {
        if let finderRefreshOverride {
            finderRefreshOverride(scene, generation, completion)
            return
        }
        let folders = scene.windows.filter(FinderItems.isFolderWindow)
        /* The leading "desktop" is not decoration. The key used to be just
           the folder windows joined, so a machine with NO Finder window
           open produced "" - which equals the initial value of iconLayout,
           so the guard never fired and the DESKTOP's own icons were never
           fetched at all. Watched: a mirror with a bare desktop drew no
           icons, ever, while every folder window drew its own. */
        let key = Self.iconLayoutKey(scene)
        guard key != iconLayout else { return completion() }
        guard !fetchingIcons else {
            note("Finder roster read was already in flight; retained the "
                 + "last complete roster")
            return completion()
        }
        fetchingIcons = true
        iconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var fresh: [String: [MirrorKit.Scene.DesktopItem]] = [:]
            var complete = true
            if let d = await self.readIcons(container: "desktop") {
                fresh[Self.desktopKey] = d
            } else {
                complete = false
            }
            for win in folders {
                let quoted = win.title.replacingOccurrences(of: "\"",
                                                            with: "\\\"")
                if let items = await self.readIcons(
                    container: "window \"\(quoted)\"") {
                    fresh[win.title] = items
                } else {
                    complete = false
                }
            }
            guard !Task.isCancelled,
                  self.isCurrentCycle(generation) else { return }
            for (container, items) in fresh {
                self.icons[container] = items
            }
            if complete { self.iconLayout = key }
            self.fetchingIcons = false
            if let current = self.scene {
                let enriched = self.withIcons(current)
                _ = self.shadowEngine?.enrichFinder(enriched)
                self.observeOperations()
                self.shadowEngine?.compareVisible(enriched)
                self.scene = self.projectedScene(fallback: enriched)
            }
            self.iconTask = nil
            completion()
        }
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
    /// Eight HFS names plus positions/kinds remain comfortably below that
    /// bound; every page carries the same total so a partial read is refused.
    nonisolated private static let iconPageSize = 8

    static func iconItemsScript(container: String, offset: Int,
                                limit: Int = iconPageSize) -> String {
        """
        tell application "Finder"
        set ns to name of every item of \(container)
        set ps to position of every item of \(container)
        set ks to kind of every item of \(container)
        end tell
        set totalCount to count ns
        set out to "N" & tab & totalCount & return
        set firstIndex to \(offset + 1)
        set lastIndex to \(offset + limit)
        if lastIndex > totalCount then set lastIndex to totalCount
        if firstIndex <= lastIndex then
        repeat with i from firstIndex to lastIndex
        set p to item i of ps
        set out to out & "I" & tab & (item i of ns) & tab & (item 1 of p) & \
        tab & (item 2 of p) & tab & (item i of ks) & return
        end repeat
        end if
        return out
        """
    }

    private func readIcons(container: String)
        async -> [MirrorKit.Scene.DesktopItem]? {
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
        var offset = 0
        while expectedTotal == nil || offset < expectedTotal! {
            let source = Self.iconItemsScript(container: container,
                                              offset: offset)
            let read = await readingOutput("script", ["source": .text(source)])
            guard let text = read.value, !read.truncated,
                  let total = Self.iconPageTotal(text),
                  expectedTotal == nil || expectedTotal == total,
                  total <= FinderItems.maxItemsPerWindow else {
                let reason = read.truncated
                    ? "guest result truncated"
                    : (read.error ?? "incomplete or changing item roster")
                note("could not read the items of \(container) - \(reason)")
                return nil
            }
            expectedTotal = total
            let page = Self.parseIcons(text)
            let expectedCount = min(Self.iconPageSize, total - offset)
            guard page.count == expectedCount else {
                note("could not read the items of \(container) - page "
                     + "\(offset / Self.iconPageSize + 1) was incomplete")
                return nil
            }
            roster.append(contentsOf: page)
            offset += page.count
            if total == 0 { break }
        }

        let types = """
        tell application "Finder"
        set fn to name of every file of \(container)
        set ft to file type of every file of \(container)
        set fc to creator type of every file of \(container)
        end tell
        set out to ""
        repeat with i from 1 to (count fn)
        set out to out & "F" & tab & (item i of fn) & tab & (item i of ft) & \
        tab & (item i of fc) & tab & "" & return
        end repeat
        return out
        """
        let art = await readingOutput("script", ["source": .text(types)])
        if art.value == nil || art.truncated {
            note("\(container): items read, but not their icon art"
                 + " - \(art.truncated ? "guest result truncated" : "\(art.error ?? "no reason given")")")
        }
        /* Unquote BEFORE joining. Each script answers in SOURCE form, so
           each blob carries its own surrounding quotes; concatenating
           them raw would leave a `""` inside one line and eat the row on
           either side of it. */
        let typesByName = Dictionary(uniqueKeysWithValues:
            Self.parseIconTypes(art.truncated ? "" : (art.value ?? "")))
        return roster.map { item in
            guard let pair = typesByName[item.name] else { return item }
            var out = item
            out.type = pair.0.isEmpty ? nil : String(pair.0.prefix(4))
            out.creator = pair.1.isEmpty ? nil : String(pair.1.prefix(4))
            return out
        }
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
        set out to out & "V" & tab & (name of candidate) & tab & \
        (visible of candidate) & return
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

    private func refreshVisibility(_ scene: MirrorKit.Scene,
                                   generation: Int,
                                   completion: @escaping () -> Void) {
        if let visibilityRefreshOverride {
            visibilityRefreshOverride(scene, generation, completion)
            return
        }
        visibilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var observed: [String: Bool] = [:]
            var expectedTotal: Int?
            var offset = 0
            var complete = true
            while expectedTotal == nil || offset < expectedTotal! {
                let read = await self.readingOutput(
                    "script", ["source": .text(Self.visibilityScript(
                        offset: offset))])
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
            guard !Task.isCancelled,
                  self.isCurrentCycle(generation) else { return }
            _ = self.shadowEngine?.enrichVisibility(
                observed, complete: complete
                    && observed.count == expectedTotal,
                sequence: scene.seq)
            self.scene = self.projectedScene(fallback: scene)
            self.observeOperations()
            self.visibilityTask = nil
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
                guard let x = Int(f[2]), let y = Int(f[3]) else { continue }
                let kind = f[4].lowercased()
                items.append(.init(
                    name: f[1],
                    kind: kind.contains("folder") ? "folder"
                        : kind.contains("disk") ? "disk"
                        : kind.contains("application") ? "application" : "file",
                    type: nil, creator: nil,
                    x: x, y: y, placed: true,
                    alias: kind.contains("alias"), invisible: false))
            case "F":
                /* An OSType is four characters. The Finder answers with
                   the type as text, and a file whose type is unset comes
                   back empty rather than absent - which is a real
                   answer, and the atlas treats it as one. */
                types[f[1]] = (f[2], f[3])
            default:
                continue
            }
        }
        return items.map { item in
            guard let pair = types[item.name] else { return item }
            var out = item
            out.type = pair.0.isEmpty ? nil : String(pair.0.prefix(4))
            out.creator = pair.1.isEmpty ? nil : String(pair.1.prefix(4))
            return out
        }
    }

    private static func parseIconTypes(_ raw: String)
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
        if let refusal = pinnedActionRefusal() {
            let label = InteractionBridge.label(for: interaction)
            ActLog.note(action: label,
                        outcome: "NOT DISPATCHED: \(refusal)", ms: 0)
            report(refusal)
            return
        }
        guard currentPlanePolicy.contains(.interaction) else {
            let label = InteractionBridge.label(for: interaction)
            ActLog.note(action: label,
                        outcome: "NOT DISPATCHED: Interaction policy is off",
                        ms: 0)
            report("\(label): Interaction is off; the Mirror is read-only.")
            return
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
        case .unsupported(let why):
            ActLog.note(action: InteractionBridge.label(for: interaction),
                        outcome: "NOT DISPATCHED (unsupported): \(why)", ms: 0)
            report("\(InteractionBridge.label(for: interaction)): \(why)")
        default:
            let label = InteractionBridge.label(for: interaction)
            if let engine = shadowEngine,
               let operation = MirrorActionExecutor.operation(
                    for: interaction, plan: plan, engine: engine),
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
                        self.perform(interaction)
                    }
                    return
                }
                report(label + " — queued")
                let accepted = mutationBroker.enqueue(operation, execute: {
                    [weak self] in
                    guard let self else {
                        return .init(complaint: "the Mirror closed",
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
                        effectMayHaveLanded: complaint?.contains(
                            "was not sent") != true)
                }, report: { [weak self] operation, complaint in
                    self?.reportOperation(operation, label: label,
                                          complaint: complaint)
                })
                if !accepted {
                    report(label + " — not dispatched: operation journal full")
                }
                return
            }
            if shadowEngine != nil,
               MirrorActionExecutor.requiresTypedSettlement(
                    for: interaction, plan: plan) {
                let reason = "the displayed guest state has no stable identity "
                    + "for this operation; it was not sent"
                ActLog.note(action: "unresolved \(label)  plan=\(plan)",
                            outcome: "NOT DISPATCHED: \(reason)", ms: 0)
                report(label + " — " + reason)
                return
            }
            report(label + "…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let started = Date()
                let complaint = await self.serve(plan)
                if let correlation = self.planCorrelation {
                    self.track(correlation, label: label)
                }
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
        report(label + "…")
        Task { @MainActor [weak self] in
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
    }

    private var currentPlanePolicy: Set<MirrorPlaneID> {
        pinnedGuestKey.map(planePolicy) ?? [.structure]
    }

    // MARK: - Serving a plan

    /// Returns nil when it went, or a sentence for a person when it did
    /// not. Every branch answers one or the other; none stays quiet.
    private func serve(_ plan: InteractionPlan) async -> String? {
        planCorrelation = nil
        planSettlement = "unknown"
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
            return await finder(
                "select \(reference(item, in: container))")
        case .finderOpen(let item, let container):
            return await finder(
                "open \(reference(item, in: container))")
        case .finderDeselect:
            return await finder("select {}")

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

    static func finderScript(_ phrase: String) -> String {
        """
        tell application "Finder"
        \(phrase)
        activate
        end tell
        """
    }

    private func finder(_ phrase: String) async -> String? {
        let source = Self.finderScript(phrase)
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
    static let hideFrontApplicationScript = """
            tell application "Finder"
            set visible of first application process whose frontmost is true \
            to false
            end tell
            return "dispatched"
            """

    static func appleMenuItemScript(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Finder"
        open item "\(escaped)" of folder "Apple Menu Items" of system folder
        end tell
        return "dispatched"
        """
    }

    static let hideOtherApplicationsScript = """
            tell application "Finder"
            repeat with candidate in every application process
            if not (frontmost of candidate) then \
            set visible of candidate to false
            end repeat
            end tell
            return "dispatched"
            """

    static let showAllApplicationsScript = """
            tell application "Finder"
            set visible of every application process to true
            end tell
            return "dispatched"
            """

    private func applicationVisibility(
        _ action: InteractionPlan.ApplicationVisibility) async -> String? {
        switch action {
        case .hide(let psn, let incarnation, _, _, _, _),
             .hideOthers(let psn, let incarnation, _, _, _, _):
            guard let app = scene?.apps.first(where: { $0.psn == psn }),
                  app.front, app.incarnation == incarnation else {
                return "the Application-menu target changed before dispatch"
            }
            let source: String
            if case .hide = action {
                source = Self.hideFrontApplicationScript
            } else {
                source = Self.hideOtherApplicationsScript
            }
            let read = await readingOutput(
                "script", ["source": .text(source)])
            if let error = read.error { return error }
            return Self.visibilityDispatchOutcome(read.value)

        case .showAll:
            let read = await readingOutput(
                "script", ["source": .text(Self.showAllApplicationsScript)])
            if let error = read.error { return error }
            return Self.visibilityDispatchOutcome(read.value)
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
    private func readingOutput(_ verb: String,
                               _ args: [String: CommandArg],
                               row: String = "output")
        async -> (value: String?, error: String?, truncated: Bool) {
        await withCheckedContinuation { continuation in
            listener.runCommand(verb, typed: args) { result in
                guard result.ok else {
                    let e = result.error
                    return continuation.resume(returning: (
                        nil,
                        "\(e?.code ?? "error"): \(e?.message ?? "no reason")",
                        false))
                }
                var value: String?
                var truncated = false
                for cells in result.output?[verb] ?? [] where cells.first == row {
                    value = cells.count > 1 ? cells.last : ""
                }
                for cells in result.output?[verb] ?? []
                where cells.first == "truncated" {
                    truncated = cells.last?.lowercased() == "true"
                }
                continuation.resume(returning: (value, nil, truncated))
            }
        }
    }

    /// The verbs with no typed projection on this host yet. Reads the
    /// guest's own reply rather than assuming a send is a success.
    private func run(_ verb: String,
                     _ args: [String: CommandArg], act isAct: Bool = false)
        async -> String? {
        await withCheckedContinuation { continuation in
            listener.runCommand(verb, typed: args) { result in
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
            return "\(failure.code): \(failure.message)"
        case .unavailable(let why):
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
            return "\(failure.code): \(failure.message)"
        case .unavailable(let unavailable):
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
}
