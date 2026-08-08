import Foundation
import MirrorKit

/// One session-pinned state owner. It is intentionally shadow-only here: the
/// legacy projection remains visible until direct preflight parity is proven.
@MainActor
final class MirrorStateEngine: ObservableObject {
    private struct SemanticContribution: Equatable {
        var controls: [String: Scene.Semantics] = [:]
        var dialogItems: [String: Scene.Semantics] = [:]
    }

    private struct ContentContribution: Equatable {
        var rect: Rect
        var display: [DisplayOp]?
    }

    let guestKey: GuestKey
    let session: MirrorGuestSession
    let store: MirrorSnapshotStore
    let diagnostics: MirrorEngineDiagnostics
    let operations: MirrorOperationJournal

    @Published private(set) var snapshot: MirrorProjection?
    @Published private(set) var lastRejection: MirrorObservationRejection?
    @Published private(set) var enabledPlanes = Set(MirrorPlaneID.allCases)
    private(set) var replica: MirrorReplica?
    private var semantics: [MirrorWindowIdentity: SemanticContribution] = [:]
    private var content: [MirrorWindowIdentity: ContentContribution] = [:]
    /// Machine-wide process visibility is observed independently from the
    /// structural walk. Keep the last values even while their coverage is
    /// stale so projection can be continuous without letting stale state
    /// settle a mutation.
    private var visibility: [MirrorProcessIdentity: Bool] = [:]
    private var visibilityCoverage: Scene.CoverageClaim?

    /// **What the Finder roster has and has not covered.**
    ///
    /// The icon roster used to be waited for inside the scene cycle, so a
    /// frame either had it or the frame had not been published; there was
    /// nothing to say. Since plan 014 §3 the cycle publishes first and the
    /// roster folds in when it arrives, and the interval between the two
    /// is a real state a person and an agent can both act wrongly on —
    /// windows drawn with no icons in them look like empty folders.
    ///
    /// Absence stays absence in the SCENE (a container never read carries
    /// no `items` key rather than an empty one), and this is the sentence
    /// that goes with it: typed status and a reason, in the vocabulary
    /// `process-visibility` already uses, so one rule reads both.
    private var finderItemsCoverage: Scene.CoverageClaim?
    private var publicationID = 0
    private var digestScene: Scene?
    private var digestPlanes: Set<MirrorPlaneID> = []
    private var digestValue = ""

    init(guestKey: GuestKey, store: MirrorSnapshotStore? = nil,
         diagnostics: MirrorEngineDiagnostics? = nil) {
        self.guestKey = guestKey
        session = .init(
            guest: guestKey.machine.slug,
            incarnation: guestKey.session.uuidString.lowercased())
        self.store = store ?? MirrorSnapshotStore()
        self.diagnostics = diagnostics ?? MirrorEngineDiagnostics()
        operations = MirrorOperationJournal()
    }

    @discardableResult
    func accept(_ scene: Scene, receivedAt: Date = Date())
        -> MirrorReductionResult {
        let result = MirrorReplicaReducer.reduce(
            .init(session: session, scene: scene, receivedAt: receivedAt),
            previous: replica)
        switch result {
        case .accepted(let next):
            replica = next
            let identities = windowIdentities(in: scene)
            _ = retainSemantics(from: scene, identities: identities, in: next)
            _ = retainContent(from: scene, identities: identities, in: next)
            pruneContributions(to: next)
            if !visibility.isEmpty {
                visibilityCoverage = .init(
                    scope: "process-visibility", status: .stale,
                    reason: "retained until visibility is observed for sequence "
                        + "\(next.lastSequence)")
            }
            lastRejection = nil
            publish(from: next.snapshot, at: receivedAt)
        case .rejected(let rejection):
            lastRejection = rejection
        }
        return result
    }

    func compareVisible(_ legacy: Scene, at date: Date = Date()) {
        guard let snapshot else { return }
        diagnostics.compare(legacy: legacy, engine: snapshot, at: date)
    }

    /// Reduces asynchronous content/Finder results into the already accepted
    /// structural sequence. Returns true only when a new immutable projection
    /// was actually published.
    @discardableResult
    func enrichContent(_ scene: Scene, receivedAt: Date = Date()) -> Bool {
        enrich(scene, plane: .content, receivedAt: receivedAt)
    }

    func enrichSemantics(_ scene: Scene, receivedAt: Date = Date()) -> Bool {
        enrich(scene, plane: .semantics, receivedAt: receivedAt)
    }

    func enrichFinder(_ scene: Scene, receivedAt: Date = Date()) -> Bool {
        enrich(scene, plane: nil, receivedAt: receivedAt)
    }

    /// Records whether the roster now folded in was read for the layout
    /// that is on screen. See `finderItemsCoverage`.
    ///
    /// Republishes when the claim CHANGES, and only then: the roster is
    /// re-asserted on every cycle that redraws from retained icons, and a
    /// publish per cycle for an unchanged sentence would be the same
    /// spending this plan is removing, one layer over.
    func noteFinderItems(complete: Bool, reason: String? = nil,
                         receivedAt: Date = Date()) {
        let claim = Scene.CoverageClaim(
            scope: "finder-items",
            status: complete ? .complete : .partial,
            reason: complete ? nil
                : (reason ?? "the Finder roster for this layout has not "
                   + "arrived; folder windows may be drawn without items"))
        guard claim != finderItemsCoverage else { return }
        finderItemsCoverage = claim
        guard let replica else { return }
        publish(from: replica.snapshot, at: receivedAt)
    }

    /// Join a complete guest-side Finder visibility census to the exact
    /// structural generation it describes. Names are used only as a join
    /// key; duplicate or missing names keep coverage partial and therefore
    /// non-settling.
    @discardableResult
    func enrichVisibility(_ byName: [String: Bool], complete: Bool,
                          sequence: Int, receivedAt: Date = Date()) -> Bool {
        guard let replica, sequence == replica.lastSequence else {
            return false
        }
        var next = visibility
        var matched = Set<MirrorProcessIdentity>()
        var ambiguous = false
        for (name, value) in byName {
            let candidates = replica.applications.values.filter {
                $0.app.name == name
            }
            guard candidates.count == 1, let record = candidates.first else {
                ambiguous = true
                continue
            }
            next[record.identity] = value
            matched.insert(record.identity)
        }
        // A DENOMINATOR THAT CANNOT BE FILLED PINS A HEALTH SIGNAL AT
        // `partial` FOREVER, and a signal that can never read green says
        // nothing at all.
        //
        // The census is the Finder's `every application process`, and a
        // faceless background application is not one — the Process Manager
        // omits a `modeOnlyBackground` process from the Application menu
        // and the Finder's roster alike. Six were running on a good boot
        // (Control Strip Extension, DVD AutoLauncher, FBC Indexing
        // Scheduler, Folder Actions, tbt-appe, tbt-worker), so requiring a
        // visibility row for every application in the replica required six
        // rows that could not exist. The claim then said the census "did
        // not uniquely cover every application" on a machine where it had
        // covered everything there was to cover.
        //
        // Excluded by the process's OWN declaration, never because we
        // failed to see a row for it: a name the census skipped for any
        // other reason still keeps this partial, which is the whole point.
        // An application with a face and nothing open right now is NOT
        // excluded — it has a visibility answer and the census returns it.
        let required = Set(replica.applications.filter {
            $0.value.app.backgroundOnly != true
        }.keys)
        let uncovered = required.subtracting(matched)
        let authoritative = complete && !ambiguous && uncovered.isEmpty
        let coverage = Scene.CoverageClaim(
            scope: "process-visibility",
            status: authoritative ? .complete : .partial,
            reason: authoritative ? nil
                : "visibility census did not uniquely cover every application")
        guard next != visibility || coverage != visibilityCoverage else {
            return false
        }
        visibility = next
        visibilityCoverage = coverage
        publish(from: replica.snapshot, at: receivedAt)
        return true
    }

    func processVisibility(_ identity: MirrorProcessIdentity) -> Bool? {
        visibility[identity]
    }

    private func enrich(_ scene: Scene, plane: MirrorPlaneID?,
                        receivedAt: Date) -> Bool {
        guard let prior = replica, scene.seq == prior.lastSequence else {
            return false
        }
        let reduced = MirrorReplicaReducer.enrich(scene, previous: prior)
        let next = reduced ?? prior
        var changed = reduced != nil
        let identities = windowIdentities(in: scene)
        if plane == .content {
            changed = retainContent(from: scene, identities: identities,
                                    in: next) || changed
        } else if plane == .semantics {
            changed = retainSemantics(from: scene, identities: identities,
                                      in: next) || changed
        }
        guard changed else { return false }
        replica = next
        pruneContributions(to: next)
        publish(from: next.snapshot, at: receivedAt)
        return true
    }

    /// Plane policy changes presentation, never ownership. Every contribution
    /// remains in its session/window shelf so a diagnostic switch can hide or
    /// reveal it immediately without another guest walk or draw drain.
    @discardableResult
    func setEnabledPlanes(_ planes: Set<MirrorPlaneID>,
                          at date: Date = Date()) -> Bool {
        let normalized = planes.union([.structure])
        guard normalized != enabledPlanes else { return false }
        enabledPlanes = normalized
        if let replica { publish(from: replica.snapshot, at: date) }
        return true
    }

    func isPlaneEnabled(_ plane: MirrorPlaneID) -> Bool {
        enabledPlanes.contains(plane)
    }

    /// One typed settlement view per coverage claim. Retained stale entities
    /// remain in the replica, but only a claim whose own scope is complete can
    /// satisfy the pure reducer's postcondition.
    func settlementEvidence(receivedAt: Date = Date())
        -> [MirrorSettlementEvidence] {
        guard let replica, let claims = snapshot?.scene.meta.coverage else {
            return []
        }
        let processes = Set(replica.applications.keys)
        let windows = Set(replica.windows.keys)
        let frontProcess = replica.applications.values.first {
            $0.app.front
        }?.identity
        let frontWindow = replica.windows.values.first {
            $0.window.front
        }?.identity
        let titles = Dictionary(uniqueKeysWithValues: replica.windows.map {
            ($0.key, $0.value.window.title)
        })
        let processNames = Dictionary(uniqueKeysWithValues:
            replica.applications.map { ($0.key, $0.value.app.name) })
        return claims.map {
            .init(session: session, sequence: replica.lastSequence,
                  coverage: $0, receivedAt: receivedAt,
                  presentProcesses: processes, presentWindows: windows,
                  frontProcess: frontProcess, frontWindow: frontWindow,
                  windowTitles: titles, processVisibility: visibility,
                  processNames: processNames)
        }
    }

    private func publish(from base: MirrorProjection, at date: Date) {
        let scene = compose(base.scene)
        publicationID += 1
        let projection = MirrorProjection(
            id: publicationID, session: base.session,
            sequence: base.sequence,
            digest: digest(scene, planes: enabledPlanes),
            baseComplete: base.baseComplete,
            sceneGeneration: base.sceneGeneration,
            contentGeneration: base.contentGeneration,
            scene: scene)
        snapshot = projection
        store.publish(projection, at: date)
    }

    private func compose(_ base: Scene) -> Scene {
        var scene = base
        for claim in [visibilityCoverage, finderItemsCoverage].compactMap({
            $0
        }) {
            var coverage = scene.meta.coverage ?? []
            coverage.removeAll { $0.scope == claim.scope }
            coverage.append(claim)
            scene.meta.coverage = coverage
        }
        let identities = windowIdentities(in: scene)
        for index in scene.windows.indices {
            if enabledPlanes.contains(.semantics),
               let identity = identities[index],
               let contribution = semantics[identity] {
                for controlIndex in scene.windows[index].controls.indices {
                    let ref = scene.windows[index].controls[controlIndex].ref
                    if let semantic = contribution.controls[ref] {
                        scene.windows[index].controls[controlIndex].semantic = semantic
                    }
                }
                if scene.windows[index].dialogItems != nil {
                    for itemIndex in scene.windows[index].dialogItems!.indices {
                        let item = scene.windows[index].dialogItems![itemIndex]
                        if let semantic = contribution.dialogItems[
                            Self.dialogKey(item)] {
                            scene.windows[index].dialogItems![itemIndex]
                                .semantic = semantic
                        }
                    }
                }
            } else if !enabledPlanes.contains(.semantics) {
                for controlIndex in scene.windows[index].controls.indices {
                    scene.windows[index].controls[controlIndex].semantic = nil
                }
                if scene.windows[index].dialogItems != nil {
                    for itemIndex in scene.windows[index].dialogItems!.indices {
                        scene.windows[index].dialogItems![itemIndex].semantic =
                            .init(knowledge: .unknown)
                    }
                }
            }

            if enabledPlanes.contains(.content),
               let identity = identities[index],
               let contribution = content[identity],
               contribution.rect == scene.windows[index].rect {
                scene.windows[index].display = contribution.display
            } else if !enabledPlanes.contains(.content) {
                scene.windows[index].display = nil
            }
        }
        return scene
    }

    @discardableResult
    private func retainSemantics(from scene: Scene,
                                 identities: [MirrorWindowIdentity?],
                                 in replica: MirrorReplica) -> Bool {
        var changed = false
        for index in scene.windows.indices {
            guard let identity = identities[index],
                  replica.windows[identity] != nil else { continue }
            var next = semantics[identity] ?? SemanticContribution()
            for control in scene.windows[index].controls {
                guard let semantic = control.semantic else { continue }
                if next.controls[control.ref] != semantic {
                    next.controls[control.ref] = semantic
                    changed = true
                }
            }
            for item in scene.windows[index].dialogItems ?? [] {
                let key = Self.dialogKey(item)
                if next.dialogItems[key] != item.semantic {
                    next.dialogItems[key] = item.semantic
                    changed = true
                }
            }
            if !next.controls.isEmpty || !next.dialogItems.isEmpty {
                semantics[identity] = next
            }
        }
        return changed
    }

    @discardableResult
    private func retainContent(from scene: Scene,
                               identities: [MirrorWindowIdentity?],
                               in replica: MirrorReplica) -> Bool {
        var changed = false
        for index in scene.windows.indices {
            let window = scene.windows[index]
            guard let identity = identities[index],
                  replica.windows[identity]?.window.rect == window.rect,
                  window.display != nil else {
                continue
            }
            var display = window.display
            if let fresh = display,
               !Self.hasRenderableStructuredDrawing(fresh),
               let retained = content[identity],
               retained.rect == window.rect,
               let prior = retained.display,
               Self.hasRenderableStructuredDrawing(prior) {
                display!.append(contentsOf: prior.filter { $0.op != "bits" })
            }
            let next = ContentContribution(rect: window.rect, display: display)
            if content[identity] != next {
                content[identity] = next
                changed = true
            }
        }
        return changed
    }

    private func pruneContributions(to replica: MirrorReplica) {
        let identities = Set(replica.windows.keys)
        if semantics.keys.contains(where: { !identities.contains($0) }) {
            semantics = semantics.filter { identities.contains($0.key) }
        }
        if content.contains(where: {
            replica.windows[$0.key]?.window.rect != $0.value.rect
        }) {
            content = content.filter {
                replica.windows[$0.key]?.window.rect == $0.value.rect
            }
        }
        let processIdentities = Set(replica.applications.keys)
        if visibility.keys.contains(where: {
            !processIdentities.contains($0)
        }) {
            visibility = visibility.filter {
                processIdentities.contains($0.key)
            }
        }
    }

    private func windowIdentities(in scene: Scene)
        -> [MirrorWindowIdentity?] {
        let processes = Dictionary(uniqueKeysWithValues:
            (scene.processes ?? []).compactMap { process in
                process.incarnation.map { (process.psn, $0) }
            })
        return scene.windows.map { window in
            guard let process = processes[window.psn],
                  let incarnation = window.incarnation else { return nil }
            return MirrorWindowIdentity(
                process: .init(session: session, incarnation: process),
                incarnation: incarnation)
        }
    }

    private static func dialogKey(_ item: Scene.DialogItem) -> String {
        item.ref ?? "#\(item.number)"
    }

    /// Match the renderer's actual structured vocabulary. An operation family
    /// is not evidence that the host can draw this particular operation:
    /// invert rectangles need destination pixels, malformed text has no
    /// glyph position, and arc/poly are still unsupported. Treating any of
    /// those as a usable repaint let one later Sherlock invert erase the last
    /// complete text/control display from the retained P3 shelf.
    private static func hasRenderableStructuredDrawing(
        _ operations: [DisplayOp]
    )
        -> Bool {
        operations.contains { operation in
            switch operation.op {
            case "text":
                return !(operation.text?.isEmpty ?? true)
                    && operation.pen?.count == 2
            case "line":
                return operation.from?.count == 2
                    && operation.to?.count == 2
            case "rect", "rrect", "oval", "rgn":
                return operation.rect?.count == 4
                    && [0, 1, 2, 4].contains(operation.verb ?? 0)
            default:
                return false
            }
        }
    }

    private func digest(_ scene: Scene,
                        planes: Set<MirrorPlaneID>) -> String {
        var stable = scene
        stable.seq = 0
        stable.capturedAt = 0
        if stable == digestScene, planes == digestPlanes { return digestValue }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = (try? encoder.encode(stable)) ?? Data()
        bytes.append(contentsOf: planes.map(\.rawValue).sorted()
            .joined(separator: ",").utf8)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let value = String(format: "%016llx", hash)
        digestScene = stable
        digestPlanes = planes
        digestValue = value
        return value
    }
}
