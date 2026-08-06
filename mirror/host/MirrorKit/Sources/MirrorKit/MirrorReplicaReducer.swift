import Foundation

/// Pure, deletion-safe reconciliation. It has no clock, transport, UI, or
/// QEMU dependency; identical prior state plus observation yields identical
/// semantic state.
public enum MirrorReplicaReducer {
    public static func reduce(_ observation: GuestSceneObservation,
                              previous: MirrorReplica?)
        -> MirrorReductionResult {
        if let previous {
            guard previous.session == observation.session else {
                return .rejected(.sessionMismatch)
            }
            guard observation.scene.seq > previous.lastSequence else {
                return .rejected(.outOfOrder(last: previous.lastSequence,
                                             received: observation.scene.seq))
            }
        }

        let scene = observation.scene
        let session = observation.session
        var applications = previous?.applications ?? [:]
        var windows = previous?.windows ?? [:]
        var tombstones = previous?.tombstones ?? []
        let processCoverage = observation.coverage(scope: "processes")
        let processComplete = processCoverage?.status == .complete
        let processesByPSN = Dictionary(
            uniqueKeysWithValues: (scene.processes ?? []).compactMap { process
                -> (String, Scene.ProcessRef)? in
                guard process.incarnation != nil else { return nil }
                return (process.psn, process)
            })
        var observedProcesses = Set<MirrorProcessIdentity>()

        for (ordinal, app) in scene.apps.enumerated() {
            guard let incarnation = app.incarnation else { continue }
            let identity = MirrorProcessIdentity(session: session,
                                                 incarnation: incarnation)
            observedProcesses.insert(identity)
            let process = processesByPSN[app.psn]
            applications[identity] = .init(
                identity: identity, app: app, process: process,
                freshness: .fresh,
                actionable: processComplete && app.error == nil,
                lastAuthoritativeSequence: scene.seq, ordinal: ordinal)
        }

        for identity in Array(applications.keys)
        where !observedProcesses.contains(identity) {
            if processComplete {
                applications.removeValue(forKey: identity)
                tombstones.append(.init(identity: .process(identity),
                                        sequence: scene.seq))
                for windowIdentity in Array(windows.keys)
                where windowIdentity.process == identity {
                    windows.removeValue(forKey: windowIdentity)
                    tombstones.append(.init(identity: .window(windowIdentity),
                                            sequence: scene.seq))
                }
            } else if var retained = applications[identity] {
                retained.freshness = .expectedStale
                retained.actionable = false
                retained.app.front = false
                if retained.process != nil { retained.process!.front = false }
                applications[identity] = retained
            }
        }

        var observedWindows: [MirrorProcessIdentity: Set<MirrorWindowIdentity>]
            = [:]
        for (ordinal, window) in scene.windows.enumerated() {
            guard let process = processesByPSN[window.psn],
                  let processIncarnation = process.incarnation,
                  let windowIncarnation = window.incarnation else { continue }
            let processIdentity = MirrorProcessIdentity(
                session: session, incarnation: processIncarnation)
            let identity = MirrorWindowIdentity(
                process: processIdentity, incarnation: windowIncarnation)
            observedWindows[processIdentity, default: []].insert(identity)
            let complete = observation.coverage(
                scope: "windows", owner: processIncarnation)?.status == .complete
            var reconciledWindow = window
            if let retained = windows[identity]?.window,
               retained.rect == window.rect {
                /* Optional enrichment arrives independently from structural
                   scenes. Preserve only compatible same-incarnation content;
                   a geometry change invalidates coordinate-bearing data. */
                if reconciledWindow.display == nil {
                    reconciledWindow.display = retained.display
                }
                if reconciledWindow.items == nil {
                    reconciledWindow.items = retained.items
                }
                if reconciledWindow.text == nil {
                    reconciledWindow.text = retained.text
                }
                if reconciledWindow.dialogItems == nil {
                    reconciledWindow.dialogItems = retained.dialogItems
                }
            }
            windows[identity] = .init(
                identity: identity, window: reconciledWindow,
                freshness: .fresh,
                actionable: complete && window.ref != nil,
                lastAuthoritativeSequence: scene.seq, ordinal: ordinal)
        }

        for identity in Array(windows.keys) {
            let owner = identity.process
            let observed = observedWindows[owner, default: []].contains(identity)
            guard !observed else { continue }
            let complete = observation.coverage(
                scope: "windows", owner: owner.incarnation)?.status == .complete
            if complete && observedProcesses.contains(owner) {
                windows.removeValue(forKey: identity)
                tombstones.append(.init(identity: .window(identity),
                                        sequence: scene.seq))
            } else if var retained = windows[identity] {
                retained.freshness = .expectedStale
                retained.actionable = false
                retained.window.front = false
                windows[identity] = retained
            }
        }

        let menubar = reduceMenubar(observation,
                                    previous: previous?.menubar)
        let allProcessesIdentified = scene.apps.allSatisfy {
            $0.incarnation != nil
        } && (scene.processes ?? []).allSatisfy { $0.incarnation != nil }
        let baseComplete = processComplete && allProcessesIdentified
            && observedProcesses.allSatisfy {
                observation.coverage(scope: "windows", owner: $0.incarnation)?
                    .status == .complete
            }
        /* The desktop plane obeys the same rule as a window's `items`: an
           ABSENT key is "this producer does not report it", so the retained
           roster stands; a PRESENT one — including an empty array — is an
           answer, and it wins. No guest reports this plane at all, so
           without the retention the projection lost it on every poll. */
        let desktopItems = scene.desktopItems ?? previous?.desktopItems
        let projectionScene = project(scene, applications: applications,
                                      windows: windows, menubar: menubar,
                                      desktopItems: desktopItems)
        let digest = semanticDigest(applications: applications,
                                    windows: windows, menubar: menubar,
                                    coverage: scene.meta.coverage ?? [],
                                    unprovenApps: scene.apps.filter {
                                        $0.incarnation == nil
                                    },
                                    unprovenWindows: scene.windows.filter {
                                        $0.incarnation == nil
                                    })
        let projection = MirrorProjection(
            id: (previous?.snapshot.id ?? 0) + 1, session: session,
            sequence: scene.seq, digest: digest, baseComplete: baseComplete,
            sceneGeneration: previous.map {
                $0.snapshot.sceneGeneration
                    + ($0.snapshot.digest == digest ? 0 : 1)
            } ?? 1,
            contentGeneration: previous?.snapshot.contentGeneration ?? 0,
            scene: projectionScene)
        return .accepted(.init(
            session: session, lastSequence: scene.seq,
            applications: applications, windows: windows, menubar: menubar,
            desktopItems: desktopItems,
            tombstones: tombstones, snapshot: projection))
    }

    /// Adds independently arriving render-bearing fields to the exact
    /// structural observation they were derived from. It never changes
    /// membership, geometry, coverage, actionability, or sequence, and a
    /// stale/mismatched contribution is therefore a no-op rather than a
    /// second authority.
    public static func enrich(_ enriched: Scene, previous: MirrorReplica)
        -> MirrorReplica? {
        guard enriched.seq == previous.lastSequence else { return nil }
        let processesByPSN = Dictionary(
            uniqueKeysWithValues: (enriched.processes ?? []).compactMap {
                process -> (String, String)? in
                guard let incarnation = process.incarnation else { return nil }
                return (process.psn, incarnation)
            })
        var windows = previous.windows
        var changed = false

        for contribution in enriched.windows {
            guard let processIncarnation = processesByPSN[contribution.psn],
                  let windowIncarnation = contribution.incarnation else {
                continue
            }
            let process = MirrorProcessIdentity(
                session: previous.session, incarnation: processIncarnation)
            let identity = MirrorWindowIdentity(
                process: process, incarnation: windowIncarnation)
            guard var record = windows[identity],
                  record.window.rect == contribution.rect else { continue }
            var window = record.window
            if let display = contribution.display,
               display != window.display {
                window.display = display
            }
            if let items = contribution.items, items != window.items {
                window.items = items
            }
            if let text = contribution.text, text != window.text {
                window.text = text
            }
            if let dialogItems = contribution.dialogItems,
               dialogItems != window.dialogItems {
                window.dialogItems = dialogItems
            }
            guard window != record.window else { continue }
            record.window = window
            windows[identity] = record
            changed = true
        }

        /* Recorded on the REPLICA, not only on the projection it produces.
           Writing it to the snapshot alone is what made this plane last
           exactly one poll: the next structural scene rebuilt the
           projection and had nowhere to read the roster back from. */
        var desktopItems = previous.desktopItems
        if let contributed = enriched.desktopItems,
           contributed != desktopItems {
            desktopItems = contributed
            changed = true
        }
        let projectionScene = project(
            previous.snapshot.scene,
            applications: previous.applications,
            windows: windows, menubar: previous.menubar,
            desktopItems: desktopItems)
        guard changed else { return nil }
        let digest = semanticDigest(
            applications: previous.applications, windows: windows,
            menubar: previous.menubar,
            coverage: projectionScene.meta.coverage ?? [],
            unprovenApps: projectionScene.apps.filter {
                $0.incarnation == nil
            },
            unprovenWindows: projectionScene.windows.filter {
                $0.incarnation == nil
            })
        let projection = MirrorProjection(
            id: previous.snapshot.id + 1, session: previous.session,
            sequence: previous.lastSequence, digest: digest,
            baseComplete: previous.snapshot.baseComplete,
            sceneGeneration: previous.snapshot.sceneGeneration,
            contentGeneration: previous.snapshot.contentGeneration + 1,
            scene: projectionScene)
        return .init(
            session: previous.session, lastSequence: previous.lastSequence,
            applications: previous.applications, windows: windows,
            menubar: previous.menubar, desktopItems: desktopItems,
            tombstones: previous.tombstones,
            snapshot: projection)
    }

    private static func reduceMenubar(
        _ observation: GuestSceneObservation,
        previous: MirrorMenubarRecord?) -> MirrorMenubarRecord? {
        let claim = observation.scene.meta.coverage?.first {
            $0.scope == "menubar"
        }
        let complete = claim?.status == .complete
        let owner = claim?.owner.map {
            MirrorProcessIdentity(session: observation.session,
                                  incarnation: $0)
        }
        if let menubar = observation.scene.menubar {
            return .init(menubar: menubar, owner: owner, freshness: .fresh,
                         actionable: complete,
                         lastAuthoritativeSequence: observation.scene.seq)
        }
        if complete { return nil }
        guard var retained = previous else { return nil }
        retained.freshness = .expectedStale
        retained.actionable = false
        return retained
    }

    private static func project(
        _ latest: Scene,
        applications: [MirrorProcessIdentity: MirrorApplicationRecord],
        windows: [MirrorWindowIdentity: MirrorWindowRecord],
        menubar: MirrorMenubarRecord?,
        desktopItems: [Scene.DesktopItem]?) -> Scene {
        var projected = latest
        projected.desktopItems = desktopItems
        let unprovenApps = latest.apps.filter { $0.incarnation == nil }
        let unprovenProcesses = (latest.processes ?? []).filter {
            $0.incarnation == nil
        }
        let unprovenWindows = latest.windows.filter { $0.incarnation == nil }
        let appRows = applications.values.sorted {
            if $0.freshness != $1.freshness { return $0.freshness == .fresh }
            return $0.ordinal < $1.ordinal
        }
        projected.apps = appRows.map(\.app) + unprovenApps
        projected.processes = appRows.compactMap(\.process) + unprovenProcesses
        projected.windows = windows.values.sorted {
            if $0.freshness != $1.freshness { return $0.freshness == .fresh }
            return $0.ordinal < $1.ordinal
        }.map(\.window) + unprovenWindows
        projected.menubar = menubar?.menubar
        return projected
    }

    private static func semanticDigest(
        applications: [MirrorProcessIdentity: MirrorApplicationRecord],
        windows: [MirrorWindowIdentity: MirrorWindowRecord],
        menubar: MirrorMenubarRecord?, coverage: [Scene.CoverageClaim],
        unprovenApps: [Scene.AppRef], unprovenWindows: [Scene.Window])
        -> String {
        var bytes: [UInt8] = []
        func append(_ text: String) {
            bytes.append(contentsOf: text.utf8)
            bytes.append(0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for record in applications.values.sorted(by: {
            $0.identity.incarnation < $1.identity.incarnation
        }) {
            append(record.identity.incarnation)
            if let data = try? encoder.encode(record.app) {
                append(data.base64EncodedString())
            }
            if let process = record.process,
               let data = try? encoder.encode(process) {
                append(data.base64EncodedString())
            }
            append(record.freshness.rawValue)
            append(record.actionable ? "1" : "0")
        }
        for record in windows.values.sorted(by: {
            ($0.identity.process.incarnation, $0.identity.incarnation)
                < ($1.identity.process.incarnation, $1.identity.incarnation)
        }) {
            append(record.identity.process.incarnation)
            append(record.identity.incarnation)
            if let data = try? encoder.encode(record.window) {
                append(data.base64EncodedString())
            }
            append(record.freshness.rawValue)
            append(record.actionable ? "1" : "0")
        }
        if let menubar, let data = try? encoder.encode(menubar.menubar) {
            append(menubar.owner?.incarnation ?? "")
            append(data.base64EncodedString())
            append(menubar.freshness.rawValue)
            append(menubar.actionable ? "1" : "0")
        }
        for claim in coverage.sorted(by: {
            [$0.scope, $0.owner ?? "", $0.status.rawValue, $0.reason ?? ""]
                .joined(separator: "\u{0}")
                < [$1.scope, $1.owner ?? "", $1.status.rawValue,
                   $1.reason ?? ""].joined(separator: "\u{0}")
        }) {
            append(claim.scope); append(claim.owner ?? "")
            append(claim.status.rawValue); append(claim.reason ?? "")
        }
        for app in unprovenApps {
            if let data = try? encoder.encode(app) {
                append(data.base64EncodedString())
            }
            append("unproven")
        }
        for window in unprovenWindows {
            if let data = try? encoder.encode(window) {
                append(data.base64EncodedString())
            }
            append("unproven")
        }
        var hash: UInt64 = 1469598103934665603
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}
