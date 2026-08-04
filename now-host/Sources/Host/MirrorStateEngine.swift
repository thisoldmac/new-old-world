import Foundation
import MirrorKit

/// One session-pinned state owner. It is intentionally shadow-only here: the
/// legacy projection remains visible until direct preflight parity is proven.
@MainActor
final class MirrorStateEngine: ObservableObject {
    let guestKey: GuestKey
    let session: MirrorGuestSession
    let store: MirrorSnapshotStore
    let diagnostics: MirrorEngineDiagnostics

    @Published private(set) var snapshot: MirrorProjection?
    @Published private(set) var lastRejection: MirrorObservationRejection?
    private(set) var replica: MirrorReplica?

    init(guestKey: GuestKey, store: MirrorSnapshotStore? = nil,
         diagnostics: MirrorEngineDiagnostics? = nil) {
        self.guestKey = guestKey
        session = .init(
            guest: guestKey.machine.slug,
            incarnation: guestKey.session.uuidString.lowercased())
        self.store = store ?? MirrorSnapshotStore()
        self.diagnostics = diagnostics ?? MirrorEngineDiagnostics()
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
            snapshot = next.snapshot
            lastRejection = nil
            store.publish(next.snapshot, at: receivedAt)
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
    func enrich(_ scene: Scene, receivedAt: Date = Date()) -> Bool {
        guard let replica,
              let next = MirrorReplicaReducer.enrich(scene,
                                                      previous: replica) else {
            return false
        }
        self.replica = next
        snapshot = next.snapshot
        store.publish(next.snapshot, at: receivedAt)
        return true
    }
}
