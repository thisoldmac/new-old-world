import Foundation
import MirrorKit

/// Bounded immutable publication history for one guest session. Waiters and
/// MCP projection arrive later; this owns the retention rule they will share.
@MainActor
final class MirrorSnapshotStore {
    struct Entry: Equatable {
        var snapshot: MirrorProjection
        var publishedAt: Date
    }

    private(set) var entries: [Entry] = []
    let limit: Int
    let maxAge: TimeInterval

    init(limit: Int = 32, maxAge: TimeInterval = 15 * 60) {
        self.limit = max(1, limit)
        self.maxAge = max(0, maxAge)
    }

    var current: MirrorProjection? { entries.last?.snapshot }

    func publish(_ snapshot: MirrorProjection, at date: Date) {
        entries.append(.init(snapshot: snapshot, publishedAt: date))
        let cutoff = date.addingTimeInterval(-maxAge)
        entries.removeAll { $0.publishedAt < cutoff }
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }
}
