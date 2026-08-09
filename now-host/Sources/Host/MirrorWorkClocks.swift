import Foundation

/// The host-observable brackets for one request-shaped trip to a guest.
///
/// Host and classic-Mac clocks are not synchronized, so the guest contributes
/// durations rather than wall-clock instants. Every host instant below uses
/// the same clock and can therefore be subtracted without inventing precision.
struct MirrorWorkClocks: Equatable, Sendable {
    let traceID: String
    let sessionID: String
    let purpose: GuestWorkPurpose
    let enqueuedAt: Date
    var admittedAt: Date?
    var replyAt: Date?
    var settledAt: Date?
    var publishedAt: Date?
    var guestHandlerMs: Int?
    var outcome: String?

    var admissionWait: TimeInterval? {
        admittedAt.map { $0.timeIntervalSince(enqueuedAt) }
    }

    var guestRoundTrip: TimeInterval? {
        guard let admittedAt, let replyAt else { return nil }
        return replyAt.timeIntervalSince(admittedAt)
    }

    var settlementWait: TimeInterval? {
        guard let replyAt, let settledAt else { return nil }
        return settledAt.timeIntervalSince(replyAt)
    }

    var publicationWait: TimeInterval? {
        guard let settledAt, let publishedAt else { return nil }
        return publishedAt.timeIntervalSince(settledAt)
    }

    var total: TimeInterval? {
        (publishedAt ?? settledAt ?? replyAt).map {
            $0.timeIntervalSince(enqueuedAt)
        }
    }
}

/// A bounded, per-session trace ledger. It is deliberately independent from
/// the operation journal: direct gestures and ambient reads have no operation
/// record, but their queue time still has to be attributable.
@MainActor
final class MirrorWorkTimeline {
    private(set) var entries: [MirrorWorkClocks] = []
    let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func append(_ clocks: MirrorWorkClocks) {
        entries.append(clocks)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func replace(_ clocks: MirrorWorkClocks) {
        guard let index = entries.lastIndex(where: {
            $0.traceID == clocks.traceID && $0.sessionID == clocks.sessionID
        }) else {
            append(clocks)
            return
        }
        entries[index] = clocks
    }

    func reset() {
        entries.removeAll(keepingCapacity: true)
    }
}
