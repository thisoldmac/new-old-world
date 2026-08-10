import Foundation
import MirrorKit
import NOWAgentIntegration

/// Read-only adapter over the native Mirror's one session engine. It starts no
/// guest request and owns no cache; MCP status/snapshot/find/wait are four
/// renderings of this service's immutable DTOs.
@MainActor
final class MirrorStateProjectionService {
    private let engines: MirrorStateEngineRegistry
    private let currentGuest: () -> GuestKey?
    /// Read as a closure rather than held, because the timelines belong to
    /// the live Mirror source and this service is a read-only adapter that
    /// must not become a second owner of anything.
    private let metrics: () -> AgentIntegrationMirrorMetrics?
    private let lifecycle: () -> AgentIntegrationMirrorLifecycle?

    init(engines: MirrorStateEngineRegistry,
         currentGuest: @escaping () -> GuestKey?,
         metrics: @escaping () -> AgentIntegrationMirrorMetrics? = { nil },
         lifecycle: @escaping () -> AgentIntegrationMirrorLifecycle?
            = { nil }) {
        self.engines = engines
        self.currentGuest = currentGuest
        self.metrics = metrics
        self.lifecycle = lifecycle
    }

    func read(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult {
        guard request.isWellFormed else {
            return unavailable("now-mirror-read-invalid",
                               "The Mirror read request is not well formed")
        }
        /* Metrics are answered before the snapshot guard on purpose. A run
           whose scene never arrived is exactly when an agent most needs to
           see the cycle clocks — a walk that is failing or timing out is
           itself the measurement, and refusing it for want of a snapshot
           would hide the slowest cases behind the same silence a person
           gets from a blank Mirror. */
        if request.intention == .metrics {
            guard let metrics = metrics() else {
                return unavailable(
                    "now-mirror-metrics-unavailable",
                    "The Mirror is not running, so it has measured nothing")
            }
            return .init(value: .init(
                intention: .metrics,
                current: currentGuest()
                    .flatMap { engines.existing(for: $0)?.snapshot }
                    .map(metadata),
                metrics: metrics))
        }

        /* Lifecycle answers before the snapshot guard for the same reason
           metrics does, and a sharper one: the state it reports is exactly
           what explains a Mirror with no snapshot. Refusing it until a
           scene arrives would withhold the answer precisely when the
           question is being asked. */
        if request.intention == .lifecycle {
            guard let facts = lifecycle() else {
                return unavailable(
                    "now-mirror-lifecycle-unavailable",
                    "No Mac is connected, so no resident has answered")
            }
            return .init(value: .init(
                intention: .lifecycle,
                current: currentGuest()
                    .flatMap { engines.existing(for: $0)?.snapshot }
                    .map(metadata),
                lifecycle: facts))
        }

        if request.intention == .settlement {
            guard let key = currentGuest(),
                  let engine = engines.existing(for: key) else {
                return unavailable(
                    "now-mirror-operation-session-unavailable",
                    "The selected guest session has no semantic operation journal")
            }
            let operationID = request.operationID!
            guard engine.operations.operation(id: operationID) != nil else {
                return unavailable(
                    "now-mirror-operation-not-found",
                    "This guest session has no retained semantic operation with that ID")
            }
            let deadline = Date().addingTimeInterval(
                Double(request.timeoutMs ?? 5_000) / 1_000)
            while Date() < deadline {
                guard currentGuest() == key,
                      let live = engines.existing(for: key) else {
                    return unavailable(
                        "now-mirror-session-changed",
                        "The selected guest session changed while waiting for settlement")
                }
                if let operation = live.operations.operation(id: operationID),
                   operation.outcome.isTerminal {
                    return .init(value: .init(
                        intention: .settlement,
                        current: live.snapshot.map(metadata),
                        journal: [Self.record(operation)]))
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let live = engines.existing(for: key),
                  let operation = live.operations.operation(id: operationID)
            else {
                return unavailable(
                    "now-mirror-operation-abandoned",
                    "The semantic operation disappeared before it settled")
            }
            return .init(value: .init(
                intention: .settlement,
                current: live.snapshot.map(metadata),
                journal: [Self.record(operation)], timedOut: true))
        }

        guard let key = currentGuest(),
              let engine = engines.existing(for: key),
              let current = engine.snapshot else {
            return unavailable(
                "now-mirror-snapshot-unavailable",
                "The selected guest has no published Mirror snapshot")
        }

        switch request.intention {
        case .metrics, .lifecycle, .settlement:
            preconditionFailure("answered before this switch")
        case .journal:
            return .init(value: .init(
                intention: .journal, current: metadata(current),
                journal: engine.operations.records.map(Self.record)))
        case .status:
            return .init(value: .init(intention: .status,
                                      current: metadata(current)))
        case .snapshot:
            return .init(value: .init(intention: .snapshot,
                                      current: metadata(current),
                                      snapshot: snapshot(engine)))
        case .find:
            let needle = request.query!.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current)
            let matches = snapshot(engine).entities.filter { entity in
                [entity.id, entity.name, entity.title ?? ""].contains {
                    $0.folding(options: [.caseInsensitive,
                                         .diacriticInsensitive],
                               locale: .current).contains(needle)
                }
            }
            return .init(value: .init(intention: .find,
                                      current: metadata(current),
                                      matches: Array(matches.prefix(64))))
        case .wait:
            let deadline = Date().addingTimeInterval(
                Double(request.timeoutMs ?? 5_000) / 1_000)
            while Date() < deadline {
                guard currentGuest() == key,
                      let live = engines.existing(for: key) else {
                    return unavailable(
                        "now-mirror-session-changed",
                        "The selected guest session changed while waiting")
                }
                if let next = live.snapshot,
                   next.id > request.afterSnapshotID! {
                    return .init(value: .init(
                        intention: .wait, current: metadata(next),
                        snapshot: snapshot(live)))
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let latest = engines.existing(for: key)?.snapshot
            return .init(value: .init(
                intention: .wait,
                current: latest.map(metadata), timedOut: true))
        }
    }

    private func snapshot(_ engine: MirrorStateEngine)
        -> AgentIntegrationMirrorSnapshot {
        let projection = engine.snapshot!
        let applicationRecords: [MirrorApplicationRecord]
        let windowRecords: [MirrorWindowRecord]
        if let replica = engine.replica {
            applicationRecords = Array(replica.applications.values)
            windowRecords = Array(replica.windows.values)
        } else {
            applicationRecords = []
            windowRecords = []
        }
        // Window counts come from the SCENE's own attribution, which is
        // what the guest's walk produced — this side never counts windows
        // to decide whether a process has a face, only to split "has
        // windows" from "enumerated and has none".
        var windowsByPsn: [String: Int] = [:]
        for record in windowRecords {
            windowsByPsn[record.window.psn, default: 0] += 1
        }
        // The producer's own answer to "did you establish what each
        // process is", read from the projected scene rather than assumed:
        // without it an absent `backgroundOnly` is ambiguous, and the
        // conservative reading is `unknown`.
        let kindsEstablished = ProcessPresence.kindsEstablished(
            projection.scene)
        let applications = applicationRecords.map { record in
                let verdict = ProcessPresence.classify(
                    record.app,
                    windowCount: windowsByPsn[record.app.psn] ?? 0,
                    kindsEstablished: kindsEstablished)
                return AgentIntegrationMirrorEntity(
                    id: processID(record.identity), kind: .process,
                    ownerID: nil, name: record.app.name, title: nil,
                    front: record.app.front,
                    visible: engine.processVisibility(record.identity),
                    presence: verdict.presence.rawValue,
                    presenceReason: verdict.reason,
                    freshness: record.freshness.rawValue,
                    actionable: record.actionable)
            }
        let windows = windowRecords.map { record in
            AgentIntegrationMirrorEntity(
                id: windowID(record.identity), kind: .window,
                ownerID: processID(record.identity.process),
                name: record.window.app, title: record.window.title,
                front: record.window.front, visible: record.window.visible,
                freshness: record.freshness.rawValue,
                actionable: record.actionable)
        }
        let coverage = (projection.scene.meta.coverage ?? []).map {
            AgentIntegrationMirrorCoverage(
                scope: $0.scope, owner: $0.owner,
                status: $0.status.rawValue, reason: $0.reason)
        }.sorted {
            ($0.scope, $0.owner ?? "") < ($1.scope, $1.owner ?? "")
        }
        /* **EVERY family is bounded, and each states its own true count.**

           Two of the four used to be. `itemBudgetBytes` and
           `contentBudgetBytes` were constants — 40 KB and 12 KB — chosen
           against a stress fixture that has two entities, no menubar and
           no coverage rows. Entities and menus were therefore governed by
           nothing at all, and on a real OS 9 desktop they are not small: a
           menubar carries nine menus and the Apple menu alone can hold 96
           items. So the ceiling held in the test and broke on the machine,
           and the reply could not be sent — which is how sweep C met
           `snapshot` closing the connection, 3/3, on 2026-08-07.

           The order below is by how much a caller loses without it:
           entities are the ADDRESSING surface (an id that is not carried
           cannot be acted on at all), menus are the second act lane, and
           the window interiors come last because a caller that needs one
           window's interior can ask for that window. Whatever is left
           after the first two is split between items and content in the
           10:3 ratio their measured worst cases established — separate
           shares still, because one pool lets whichever family is served
           first starve the other.

           Every bound states the count it bounded: `entityTotal`,
           a menu's `itemTotal`, a surface's `itemTotal` and
           `displayTotal`. A truncated list that did not say so reads as a
           Mac with fewer things on it, which is worse than an empty one
           because it looks complete. */
        let allEntities = (applications + windows).sorted { $0.id < $1.id }
        let floor = AgentIntegrationMirrorSnapshot(
            metadata: metadata(projection), coverage: coverage,
            entities: [], menus: [],
            /* ABSENT rather than zero when the guest has not said. The
               field is optional precisely so a headless caller can tell
               "the screen is 0x0" — which is not a thing — from "nobody
               has measured it". Stated once here: `floor.screen` is what
               every later pass of the shedding loop carries, so the two
               cannot disagree. */
            screen: projection.scene.screen.known.map {
                .init(w: $0.w, h: $0.h)
            },
            surfaces: [])
        let fixed = (try? JSONEncoder().encode(floor).count) ?? 0

        /* **Measured, then measured again — because reasoning about it is
           what produced the hole.**

           Charging each family for its own contents leaves every CONTAINER
           uncharged: nine menu headers, and one wrapper per window carrying
           its id, title, rect, z and totals. Measured on the fixture below,
           48 window wrappers alone are 11.4 KB — a fifth of the ceiling
           that no budget had ever seen, which is precisely the shape of
           the omission this whole file keeps re-learning.

           So the assembled snapshot is ENCODED and checked, and if it is
           over, the shares are cut by the overshoot and it is built again.
           A loop that verifies cannot be wrong about an accounting it
           forgot; an arithmetic that reasons about wrapper sizes can be,
           and was. It converges in one or two passes and stops either way
           — and if it cannot fit at all, the transport's
           `response-too-large` refusal is the floor beneath it, which is
           an honest answer where the old silent close was not. */
        var reserve = 0        // what the containers cost, once measured
        var entityBytes = Self.entityBudgetBytes
        var menuBytes = Self.menuBudgetBytes
        var built = AgentIntegrationMirrorSnapshot(
            metadata: floor.metadata, coverage: coverage,
            entities: [], menus: [], screen: floor.screen)
        for pass in 0..<4 {
            var entityRoom = min(
                max(0, Self.snapshotCeilingBytes - fixed), entityBytes)
            let entities = Array(allEntities.prefix(
                Self.affording(allEntities, within: &entityRoom)))
            var menuRoom = menuBytes
            let menus = (projection.scene.menubar?.menus ?? []).map { menu in
                let items = menu.items.map {
                    AgentIntegrationMirrorMenuItem(
                        title: $0.title, index: $0.index,
                        separator: $0.separator, enabled: $0.enabled,
                        marked: $0.mark, command: $0.cmd)
                }
                let carried = Array(items.prefix(
                    Self.affording(items, within: &menuRoom)))
                return AgentIntegrationMirrorMenu(
                    id: menu.id, title: menu.title, apple: menu.apple,
                    left: menu.left, items: carried,
                    itemTotal: items.count)
            }
            let spent = fixed + (entityBytes - entityRoom)
                + (menuBytes - menuRoom) + reserve
            let room = max(0, Self.snapshotCeilingBytes - spent)
            var itemBytes = room * Self.itemShare
                / (Self.itemShare + Self.contentShare)
            var contentBytes = room - itemBytes
            built = .init(
                metadata: floor.metadata, coverage: coverage,
                entities: entities, menus: menus, screen: floor.screen,
                surfaces: surfaces(projection.scene,
                                   itemBytes: &itemBytes,
                                   contentBytes: &contentBytes),
                entityTotal: allEntities.count)
            let size = (try? JSONEncoder().encode(built).count) ?? 0
            guard size > Self.snapshotCeilingBytes, pass < 3 else { break }
            /* Shed from the two act lanes only after the interiors, which
               the loop has already emptied by the time the shares reach
               zero: an id that is not carried cannot be acted on at all,
               and a window's interior can be asked for one window at a
               time. */
            let over = size - Self.snapshotCeilingBytes
            if room > 0 {
                reserve += over            // the containers, now paid for
            } else {
                menuBytes = max(0, menuBytes - over)
            }
        }
        return built
    }

    /// **What the renderer draws, for the client that draws nothing.**
    ///
    /// Composed from the same `Scene` the renderer composes from, so the
    /// two cannot disagree about what the Mac is showing. Until this
    /// existed the projection carried window ENTITIES — id, title, front,
    /// freshness — and none of the state a person actually reads off a
    /// window: no rects, no controls, no field values, no dialog items. So
    /// the workflow this arc exists for, confirm the state is there and
    /// only then implement the drawing, could not be run for anything but
    /// windows and menus.
    private func surfaces(_ scene: MirrorKit.Scene,
                          itemBytes: inout Int,
                          contentBytes: inout Int)
        -> [AgentIntegrationMirrorSurface] {
        /* Bounded because the protocol caps one message at 64 KB and a
           Finder window can hold hundreds of rows. The cap is stated in
           `itemTotal` rather than applied silently: a truncated list that
           did not say so reads as a window with fewer controls than the
           Mac is drawing, which is the defect the Finder's own roster
           paging already had to learn. */
        let perWindow = 64
        let budget = 240
        var spent = 0
        return scene.windows.map { window in
            let controls = window.controls.map { control in
                AgentIntegrationMirrorSurfaceItem(
                    source: "control",
                    ref: control.ref.isEmpty ? nil : control.ref,
                    role: control.role, title: control.title,
                    rect: control.rect.map(Self.rect),
                    enabled: control.enabled, visible: control.visible,
                    value: control.value, checked: control.checked,
                    kind: control.semantic?.kind,
                    state: control.semantic?.state,
                    text: control.semantic?.value,
                    knowledge: control.semantic?.knowledge.rawValue,
                    definition: control.semantic?.definition,
                    number: nil)
            }
            let dialogItems = (window.dialogItems ?? []).map { item in
                AgentIntegrationMirrorSurfaceItem(
                    source: "dialogItem",
                    ref: item.ref, role: nil, title: item.title,
                    rect: Self.rect(item.rect),
                    enabled: item.enabled, visible: item.visible,
                    value: nil, checked: nil,
                    kind: item.semantic.kind, state: item.semantic.state,
                    text: item.semantic.value,
                    knowledge: item.semantic.knowledge.rawValue,
                    definition: item.semantic.definition,
                    number: item.number)
            }
            /* **The Finder's own items, and the omission that hid them.**
               Desktop icons and a folder window's file rows are neither
               controls nor dialog items — they are files the Finder draws,
               carried in `window.items`. Projecting only the first two
               reported the desktop as a window with zero elements while
               the machine was showing seventeen icons, which is exactly
               the "we cannot capture this class" wall this arc exists to
               remove. Found on 2026-08-05 by pairing a live snapshot
               against a screendump. */
            /* **AND THE DESKTOP'S OWN ICONS, which are not `items`.**
               The comment above says this omission "reported the desktop
               as a window with zero elements while the machine was
               showing seventeen icons" — and after that fix the desktop
               STILL reported zero, because the backdrop is the one Finder
               window whose icons never live in `window.items`. They are
               `scene.desktopItems`, read from the Finder by a different
               script and carried beside the windows rather than inside
               one. Measured 2026-08-06 on a live session: Macintosh HD 10
               rows, Control Panels 33, Desktop 0, with seven icons on the
               screen. Same shape, one field over, third time. */
            /* **ONE COORDINATE SPACE, and the desktop was the exception.**
               Sweep A, 2026-08-07: "Desktop items carry screen coordinates
               and zero size. Every one of the 19 is a point at a screen
               position, while every other surface's rects are
               content-local. Two conventions in one snapshot, and the
               degenerate one cannot be hit-tested."

               Both halves are fixed here, where they are created.

               SPACE. A window's own `items` are already content-local
               (FinderItems: the Finder's `position of` is window-content-
               local and scroll-compensated). `scene.desktopItems` are
               global screen positions, so they are made local to the
               window that carries them by subtracting that window's own
               origin. The backdrop's rect origin is used rather than
               `FinderItems.contentOrigin`, which adds a title bar the
               desktop backdrop does not have.

               SIZE. A Finder item's target is the 32x32 icon box plus the
               name under it - the box FinderItems measured by clicking and
               the box HitTester already compares against. A point is not a
               smaller version of that; it is a rect nothing can ever hit.

               An item the Finder did not place carries NO rect at all.
               That is the honest gap: `state: "unplaced"` says so, and a
               reader that needs geometry gets nothing rather than a
               position that was never true. */
            let backdrop = HitTester.isDesktopBackdrop(window)
            let desktopIcons = backdrop ? (scene.desktopItems ?? []) : []
            let finderItems = ((window.items ?? []) + desktopIcons).map { item in
                let x = backdrop ? item.x - window.rect.l : item.x
                let y = backdrop ? item.y - window.rect.t : item.y
                return AgentIntegrationMirrorSurfaceItem(
                    source: "finderItem",
                    /* Addressed BY NAME, which is how the Finder itself
                       addresses them and why `finderOpen` takes a name
                       rather than a reference. */
                    ref: nil, role: item.kind, title: item.name,
                    /* **The box the FINDER drew, not a 32x32 constant.** A
                       list view's rows are 16x16 at a 19-px pitch, so a
                       constant box overlapped the row below it and a click
                       computed from its centre selected the wrong file.
                       `HitTester.targetSize` is the one place that decides
                       it, and it still answers 32x44 for an item whose
                       producer never asked the Finder for a size. */
                    rect: item.placed
                        ? {
                            let box = HitTester.targetSize(item)
                            return .init(l: x, t: y,
                                         r: x + box.w, b: y + box.h)
                        }()
                        : nil,
                    enabled: true, visible: !item.invisible,
                    value: nil, checked: nil,
                    kind: item.alias ? "alias" : item.kind,
                    state: item.placed ? "placed" : "unplaced",
                    text: item.type, knowledge: nil, number: nil)
            }
            /* **The drawing itself, which only the Mirror window could
               see.** `Scene.Window.display` has carried the content
               plane's QuickDraw ops since slice 2 and this projection
               never read it, so the one face that draws nothing was also
               the one face that could not be told what was drawn. That
               makes slice 6's render rule — replay the ops rather than
               classify the control — available to a headless caller for
               the first time. Third instance of the same omission shape;
               `testEveryWindowFieldIsCarriedOrConsciouslyDeclined` is the
               guard that is meant to end it. */
            let display = window.display.map {
                Self.replayable($0, within: &contentBytes)
            }
            let all = controls + dialogItems + finderItems
            let room = max(0, min(perWindow, budget - spent))
            let candidates = Array(all.prefix(room))
            let items = Array(candidates.prefix(
                Self.affording(candidates, within: &itemBytes)))
            spent += items.count
            return .init(
                entityID: MirrorEntityID.window(window, in: scene)
                    ?? window.id,
                title: window.title,
                rect: Self.rect(window.rect), z: window.z,
                front: window.front, visible: window.visible,
                items: items, itemTotal: all.count,
                display: display,
                /* The TRUE count, always — `display.count` short of this
                   is a bounded tail and the caller can see exactly that. */
                displayTotal: window.display?.count,
                /* Found by the roster test rather than by a reader: the
                   same omission as `display`, one field over. `kind`
                   decides how the FRAME is drawn, `ref` says whether the
                   window can be addressed at all, and `text` is a dialog's
                   own content — none of which the entity list can hold. */
                kind: window.kind,
                ref: window.ref.flatMap { $0.isEmpty ? nil : $0 },
                text: window.text.map {
                    Self.windowText($0, within: &contentBytes)
                },
                /* **Whether an empty control list is an answer.** An agent
                   reading a window with no control items had no way to be
                   wrong before this: the guest emits `[]` for a panel
                   proven to have none and for one it never walked, and
                   since the shared control pool was measured filling, for
                   a panel skipped because earlier windows spent the slots.
                   Resolved here rather than passed on, because the
                   producer sends the word only where the array cannot
                   speak for itself and a caller must not have to know
                   that. */
                controlsState: window.controlsKnowledge.rawValue,
                /* **Which widgets the machine draws.** Passed through
                   unresolved, three-valued, because nothing on this side
                   can improve on it: `kind` is the substitute a caller
                   would otherwise reach for and it is provably wrong —
                   Extensions Manager and Memory are both `kind == 2` and
                   only one has a zoom box. Guessing here does not earn a
                   refusal; a click on a zoom box the machine never drew
                   lands in the racing stripes and DRAGS the window. */
                closeBox: window.closeBox, zoomBox: window.zoomBox)
        }
    }

    /* **One ceiling, shared out AFTER the part nobody can shrink.**

       The protocol caps a message at 64 KB. Past that the encode used to
       fail and the connection closed with NO reply — so `snapshot` stopped
       answering while `status` still did, which reads as a broken host
       rather than an oversized payload (open-issues, 2026-08-05; met again
       by sweep C on 2026-08-07). The transport no longer goes silent
       either way: `AgentIntegrationLocalCodec.encodeOrRefusal` substitutes
       a `response-too-large` refusal that names the size. **That is the
       floor, not the fix** — a refusal is honest, an answer is useful, and
       this is the half that keeps the answer.

       The shares are BYTE budgets rather than counts because an element's
       size is not something this side controls: a `text` draw op carries
       an arbitrary DrawString, a TE body has no promised length, and a
       control's semantic value is whatever the panel put there. A count
       that comfortably fits three hundred short ops overflows the same
       ceiling on three hundred long strings.

       They are SEPARATE shares rather than one pool, because a pool lets
       the first family served starve the rest — the item projection alone
       once encoded 54.6 KB of the ceiling.

       And they are DERIVED per scene rather than fixed, which is the
       2026-08-07 change. Two constants summing to 52 KB left 12 KB for
       everything they do not govern: metadata, coverage, every process and
       window entity, and a menubar that can carry 96 items. That is ample
       on the stress fixture, which has two entities and no menus, and not
       ample on a real OS 9 desktop — so the ceiling held in the test and
       broke on the machine. `snapshot(_:)` now encodes the ungoverned part
       first and shares out what is left, in the ratio the two measured
       worst cases established. */
    private static let itemShare = 10
    private static let contentShare = 3

    /* Ceilings rather than shares, because these two are usually small and
       taking a fixed proportion for them would starve the interiors on
       every ordinary scene to insure against an extreme one. Unspent bytes
       go back to the interiors. 12 KB of entities is roughly 90 windows
       and processes; 12 KB of menu items is several hundred commands. */
    private static let entityBudgetBytes = 12 * 1024
    private static let menuBudgetBytes = 12 * 1024

    /* The reserve is for what wraps the snapshot on the way out — the
       response envelope, the read value's `intention`, and its `current`
       metadata, which is the snapshot's metadata a second time. Measured
       generously: an under-reserve here is paid for by the exact failure
       this file is fixing. */
    private static let snapshotCeilingBytes =
        AgentIntegrationLocalProtocol.maximumMessageBytes - 4096

    /// The window's drawing, bounded — **newest last, oldest dropped
    /// first.**
    ///
    /// That is the producer's own rule when its 600-op accumulator
    /// overflows, and it is the one that survives a replay: later ops
    /// paint over earlier, so a tail still reaches the state the window is
    /// in, where a head stops partway through a redraw that has since been
    /// painted over.
    private static func replayable(_ ops: [MirrorKit.DisplayOp],
                                   within budget: inout Int)
        -> [AgentIntegrationMirrorDisplayOp] {
        let newestFirst = ops.reversed().map(displayOp)
        let fits = affording(newestFirst, within: &budget)
        return Array(newestFirst.prefix(fits).reversed())
    }

    /// How many of `values`, in the order given, the remaining budget can
    /// afford — measured by encoding them, because the failure this
    /// prevents is counted in real bytes and an estimate that is wrong in
    /// the cheap direction is what a 64 KB ceiling punishes.
    private static func affording<T: Encodable>(_ values: [T],
                                                within budget: inout Int)
        -> Int {
        let encoder = JSONEncoder()
        var fits = 0
        for value in values {
            // +1 for the array separator this element brings with it.
            let size = ((try? encoder.encode(value).count) ?? 0) + 1
            guard size <= budget else { break }
            budget -= size
            fits += 1
        }
        return fits
    }

    /// A TE body, bounded, with its true length beside it.
    private static func windowText(_ text: MirrorKit.Scene.TextContent,
                                   within budget: inout Int)
        -> AgentIntegrationMirrorWindowText {
        /* 64 bytes covers the wrapper keys, and the /4 is the worst case
           for a multi-byte character — pessimistic only once the budget is
           nearly gone, which is exactly when pessimism is the safe error. */
        let room = max(0, min(2048, (budget - 64) / 4))
        let projected = AgentIntegrationMirrorWindowText(
            content: String(text.content.prefix(room)),
            active: text.active, contentTotal: text.content.count)
        let size = ((try? JSONEncoder().encode(projected).count) ?? 0) + 1
        budget = max(0, budget - size)
        return projected
    }

    private static func displayOp(_ op: MirrorKit.DisplayOp)
        -> AgentIntegrationMirrorDisplayOp {
        .init(op: op.op, ticks: op.ticks, text: op.text, pen: op.pen,
              font: op.font, size: op.size, face: op.face, verb: op.verb,
              rect: op.rect, ext: op.ext, from: op.from, to: op.to,
              kind: op.kind, origin: op.origin, rgb: op.rgb, src: op.src,
              dst: op.dst)
    }

    /// The journal's own record, rendered. `target` and `postcondition`
    /// are described rather than structured: they are for a person reading
    /// what was asked, and a caller that needs to act uses the entity ids
    /// the snapshot publishes.
    private static func record(_ operation: MirrorOperation)
        -> AgentIntegrationMirrorOperationRecord {
        .init(id: operation.id,
              source: operation.source.rawValue,
              outcome: operation.outcome.rawValue,
              reason: operation.reason,
              target: String(describing: operation.target),
              postcondition: operation.postcondition.map(String.init(describing:))
                  ?? "none",
              displayedSnapshotID: operation.displayedSnapshotID,
              settledSequence: operation.settledSequence)
    }

    private static func rect(_ rect: MirrorKit.Rect)
        -> AgentIntegrationMirrorRect {
        .init(l: rect.l, t: rect.t, r: rect.r, b: rect.b)
    }

    private func metadata(_ projection: MirrorProjection)
        -> AgentIntegrationMirrorSnapshotMetadata {
        .init(guest: projection.session.guest,
              session: projection.session.incarnation,
              snapshotID: projection.id, sequence: projection.sequence,
              digest: projection.digest,
              baseComplete: projection.baseComplete,
              sceneGeneration: projection.sceneGeneration,
              contentGeneration: projection.contentGeneration,
              generations: .init(
                structure: projection.generations.structure,
                semantics: projection.generations.semantics,
                finder: projection.generations.finder,
                visibility: projection.generations.visibility,
                content: projection.generations.content),
              publicationReason: projection.publicationReason.rawValue)
    }

    private func processID(_ identity: MirrorProcessIdentity) -> String {
        MirrorEntityID.process(identity.incarnation)
    }

    private func windowID(_ identity: MirrorWindowIdentity) -> String {
        MirrorEntityID.window(
            processIncarnation: identity.process.incarnation,
            windowIncarnation: identity.incarnation)
    }

    private func unavailable(_ code: String, _ message: String)
        -> AgentIntegrationMirrorReadResult {
        .init(unavailable: .init(code: code, message: message))
    }
}
