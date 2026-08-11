import Foundation
import MirrorKit

/// Bounded, per-session operation truth. This is not a UI notification list:
/// records remain available after the transient status clears, and unresolved
/// work is never evicted to make a new action look simpler than it is.
@MainActor
final class MirrorOperationJournal: ObservableObject {
    static let capacity = 128

    @Published private(set) var records: [MirrorOperation] = []

    @discardableResult
    func append(_ operation: MirrorOperation) -> Bool {
        if records.count >= Self.capacity {
            guard let terminal = records.firstIndex(where: {
                $0.outcome.isTerminal
            }) else { return false }
            records.remove(at: terminal)
        }
        records.append(operation)
        return true
    }

    func replace(_ operation: MirrorOperation) {
        guard let index = records.firstIndex(where: {
            $0.id == operation.id && $0.session == operation.session
        }) else { return }
        records[index] = operation
    }

    func operation(id: String) -> MirrorOperation? {
        records.first { $0.id == id }
    }
}
