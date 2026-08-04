import Foundation

struct MirrorSettlementNotice: Equatable {
    let label: String
    let outcome: String
    let confirmed: Bool
}

/// Bounded correlation state kept independently of the scene model.
///
/// The guest owns the settlement verdict; this store only joins that verdict
/// to the label of the interaction that created it. Its order is insertion
/// order, because lexicographic correlation order says nothing about age.
struct MirrorSettlementTracker {
    static let capacity = 16

    private var pending: [String: String] = [:]
    private var order: [String] = []
    private var reportedTimeouts: Set<String> = []

    var pendingCount: Int { pending.count }

    mutating func track(_ correlation: String, label: String)
        -> [MirrorSettlementNotice] {
        if pending[correlation] != nil {
            pending[correlation] = label
            return []
        }
        var notices: [MirrorSettlementNotice] = []
        if pending.count >= Self.capacity, let oldest = order.first,
           let evictedLabel = remove(oldest) {
            notices.append(.init(
                label: evictedLabel,
                outcome: "unknown (host settlement tracking evicted)",
                confirmed: false))
        }
        pending[correlation] = label
        order.append(correlation)
        return notices
    }

    mutating func apply(_ settlements: [ActSettlement]?)
        -> [MirrorSettlementNotice] {
        guard let settlements else { return [] } // old guest: no verdict
        let present = Set(settlements.map(Self.key))
        var notices: [MirrorSettlementNotice] = []
        for settlement in settlements {
            let correlation = Self.key(settlement)
            guard let label = pending[correlation] else { continue }
            switch settlement.status {
            case "confirmed":
                _ = remove(correlation)
                notices.append(.init(
                    label: label,
                    outcome: settlement.timedOutTicks == 0
                        ? "confirmed" : "confirmed after timing out",
                    confirmed: true))
            case "refused", "session-changed":
                _ = remove(correlation)
                notices.append(.init(label: label,
                                     outcome: settlement.status,
                                     confirmed: false))
            case "timed-out":
                if reportedTimeouts.insert(correlation).inserted {
                    notices.append(.init(label: label,
                                         outcome: "timed-out",
                                         confirmed: false))
                }
            default:
                break
            }
        }
        /* A full guest ring proves an absent tracked correlation fell off
           its bounded history. A shorter list proves no such thing. */
        if settlements.count == Self.capacity {
            for correlation in order where !present.contains(correlation) {
                if let label = remove(correlation) {
                    notices.append(.init(
                        label: label,
                        outcome: "unknown (guest settlement evicted)",
                        confirmed: false))
                }
            }
        }
        return notices
    }

    private static func key(_ settlement: ActSettlement) -> String {
        String(format: "%08X-%08X", settlement.correlationHi,
               settlement.correlationLo)
    }

    @discardableResult
    private mutating func remove(_ correlation: String) -> String? {
        reportedTimeouts.remove(correlation)
        order.removeAll { $0 == correlation }
        return pending.removeValue(forKey: correlation)
    }
}
