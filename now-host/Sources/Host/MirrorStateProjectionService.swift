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

        guard let key = currentGuest(),
              let engine = engines.existing(for: key),
              let current = engine.snapshot else {
            return unavailable(
                "now-mirror-snapshot-unavailable",
                "The selected guest has no published Mirror snapshot")
        }

        switch request.intention {
        case .metrics, .lifecycle:
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
        let menus = (projection.scene.menubar?.menus ?? []).map { menu in
            AgentIntegrationMirrorMenu(
                id: menu.id, title: menu.title, apple: menu.apple,
                left: menu.left,
                items: menu.items.map {
                    AgentIntegrationMirrorMenuItem(
                        title: $0.title, index: $0.index,
                        separator: $0.separator, enabled: $0.enabled,
                        marked: $0.mark, command: $0.cmd)
                })
        }
        return .init(
            metadata: metadata(projection), coverage: coverage,
            entities: (applications + windows).sorted { $0.id < $1.id },
            menus: menus,
            screen: .init(w: projection.scene.screen.w,
                          h: projection.scene.screen.h),
            surfaces: surfaces(projection.scene))
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
    private func surfaces(_ scene: MirrorKit.Scene)
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
        var itemBytes = Self.itemBudgetBytes
        var contentBytes = Self.contentBudgetBytes
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
            let desktopIcons = HitTester.isDesktopBackdrop(window)
                ? (scene.desktopItems ?? []) : []
            let finderItems = ((window.items ?? []) + desktopIcons).map { item in
                AgentIntegrationMirrorSurfaceItem(
                    source: "finderItem",
                    /* Addressed BY NAME, which is how the Finder itself
                       addresses them and why `finderOpen` takes a name
                       rather than a reference. */
                    ref: nil, role: item.kind, title: item.name,
                    rect: .init(l: item.x, t: item.y,
                                r: item.x, b: item.y),
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
                })
        }
    }

    /* **One ceiling, and every family gets a STATED share of it.**

       The protocol caps a message at 64 KB, and past that the writer
       throws and the connection closes with NO reply — so `snapshot`
       stops answering while `status` still does, which reads as a broken
       host rather than an oversized payload (open-issues, 2026-08-05).

       These are byte budgets rather than counts because an element's size
       is not something this side controls: a `text` draw op carries an
       arbitrary DrawString, a TE body has no promised length, and a
       control's semantic value is whatever the panel put there. A count
       that comfortably fits three hundred short ops overflows the same
       ceiling on three hundred long strings.

       They are also SEPARATE budgets rather than one shared pool, because
       a shared pool would let the first family served starve the rest —
       and the measured worst case says that is not hypothetical: the item
       projection alone encoded 54.6 KB of the 64 KB ceiling before any of
       this was added, so an independently-bounded addition of any size
       overflowed it. Both numbers are pinned by
       `testAWholeSceneOfItemsAndDrawOpsStillFitsOneMessage`, which
       measures rather than reasons; the rest of the ceiling is the
       snapshot's metadata, entities and menus. */
    private static let itemBudgetBytes = 40 * 1024
    private static let contentBudgetBytes = 12 * 1024

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
              postcondition: String(describing: operation.postcondition),
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
              contentGeneration: projection.contentGeneration)
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
