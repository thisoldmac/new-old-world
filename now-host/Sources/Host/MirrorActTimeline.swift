import Foundation
import MirrorKit

/// Where an act's clocks go: the log, and the Mirror's own queue display.
///
/// Both audiences matter and they want different things. `acts.log` is
/// read minutes or days later, when a screenshot has turned out to be
/// ambiguous and the question is which of four clocks was the slow one.
/// The display is read while a person is still holding the mouse, when
/// the question is only "did that go, and is anything in front of it".
///
/// The measurement is deliberately passive. It records what the broker
/// already does rather than adding a timing path of its own, because the
/// instrument is the first suspect and one that changed the FIFO's
/// behaviour to observe it would be measuring itself.
@MainActor
final class MirrorActTimeline: ObservableObject {
    /// Enough to cover a sweep's worth of gestures without becoming a
    /// second, unbounded journal. The durable record is the log file.
    static let capacity = 32

    @Published private(set) var records: [MirrorActClocks] = []

    /// Acts queued or in flight right now, as the broker sees it. The
    /// number a person needs before they can read a slow gesture: at 0
    /// the classic Mac is slow, above 0 they are waiting on us.
    @Published var depth: Int = 0

    private let log: (MirrorActClocks) -> Void

    init(log: @escaping (MirrorActClocks) -> Void = MirrorActTimeline.write) {
        self.log = log
    }

    func record(_ clocks: MirrorActClocks) {
        records.append(clocks)
        if records.count > Self.capacity { records.removeFirst() }
        log(clocks)
    }

    /// The most recent measurement for one act, whatever kind it was.
    func latest(operationID: String) -> MirrorActClocks? {
        records.last { $0.operationID == operationID }
    }

    /// Both lines, together: the narrative for a person scrolling the log
    /// during a drive, and the `NOWBASE` line for whoever is building a
    /// table out of the run afterwards. Writing only one of them has been
    /// tried in both directions and each time the other audience lost.
    static func write(_ clocks: MirrorActClocks) {
        ActLog.note(action: "clocks \(clocks.label)\n    \(clocks.baselineLine)",
                    outcome: clocks.narrative,
                    ms: Int((clocks.total * 1000).rounded()))
    }
}
