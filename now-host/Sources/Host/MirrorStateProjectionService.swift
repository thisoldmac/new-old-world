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

    init(engines: MirrorStateEngineRegistry,
         currentGuest: @escaping () -> GuestKey?) {
        self.engines = engines
        self.currentGuest = currentGuest
    }

    func read(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult {
        guard request.isWellFormed else {
            return unavailable("now-mirror-read-invalid",
                               "The Mirror read request is not well formed")
        }
        guard let key = currentGuest(),
              let engine = engines.existing(for: key),
              let current = engine.snapshot else {
            return unavailable(
                "now-mirror-snapshot-unavailable",
                "The selected guest has no published Mirror snapshot")
        }

        switch request.intention {
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
        let applications = applicationRecords.map { record in
                AgentIntegrationMirrorEntity(
                    id: processID(record.identity), kind: .process,
                    ownerID: nil, name: record.app.name, title: nil,
                    front: record.app.front, visible: true,
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
        return .init(
            metadata: metadata(projection), coverage: coverage,
            entities: (applications + windows).sorted { $0.id < $1.id })
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
        "process:" + identity.incarnation
    }

    private func windowID(_ identity: MirrorWindowIdentity) -> String {
        "window:" + identity.process.incarnation + ":" + identity.incarnation
    }

    private func unavailable(_ code: String, _ message: String)
        -> AgentIntegrationMirrorReadResult {
        .init(unavailable: .init(code: code, message: message))
    }
}
