import Foundation
import MirrorKit
import NOWAgentIntegration

/// The clocks of one Mirror act, kept apart on purpose.
///
/// ---- Why one duration is not enough ----------------------------------
///
/// `ActLog` already times an act, and its single number is the interval
/// around `serve(plan)` — the request leaving and the guest answering it.
/// That is one of at least four things a person means by "it was slow",
/// and on the 2026-08-04 PowerBook 1400c drive it was the wrong one.
/// The mutation FIFO serialises dispatch against settlement, so an act
/// that will refuse still holds the lane for its full timeout, and every
/// gesture behind it waits. Those gestures look slow and are not: they
/// were queued behind a corpse. Nothing in the log said so, which is why
/// that drive could not tell working from stuck.
///
/// So the record separates:
///
/// - `waited` — enqueue to leaving the FIFO. Head-of-line blocking, and
///   nothing to do with the classic Mac at all.
/// - `dispatch` — leaving the FIFO to the guest answering the request.
///   Wire plus whatever the guest had to do to serve it.
/// - `settle` — the guest answering to a later observation confirming the
///   effect. This is where the poll cadence lands, and it is charged to
///   an act that may have finished long before.
/// - `total` — what the person actually waited, which is the sum and the
///   only one of the four they experience.
///
/// Attribution is the whole point: three of these have different repairs
/// and optimising the wrong one is the failure this exists to prevent.
///
/// ---- Honesty ----------------------------------------------------------
///
/// A record is emitted when the FIFO lane is RELEASED, whatever the
/// outcome, and a second one if a late observation settles an act that
/// had already timed out. The first is not retracted. A timeout that
/// blocked the lane for fifteen seconds did block it for fifteen seconds,
/// and a later confirmation does not give that time back.
struct MirrorActClocks: Equatable {

    /// Which record this is. A single act can produce two.
    enum Kind: String {
        /// The FIFO lane was released — settled, refused, or timed out.
        case released
        /// A later observation confirmed an act that had already timed
        /// out and freed the lane. Its `settle` is measured from the same
        /// dispatch, so it is legitimately larger than the timeout.
        case late
    }

    var kind: Kind
    var operationID: String
    var label: String
    var outcome: MirrorOperationOutcome
    /// How many acts were already queued or in flight when this one
    /// arrived. `0` means it went straight to the guest; anything else
    /// means `waited` is somebody else's fault, and says whose scale.
    var queueDepthAtEntry: Int
    var enqueuedAt: Date
    var dispatchStartedAt: Date?
    var dispatchReturnedAt: Date?
    var settledAt: Date?
    var releasedAt: Date

    /// Enqueue until the FIFO let it go.
    var waited: TimeInterval? {
        dispatchStartedAt.map { $0.timeIntervalSince(enqueuedAt) }
    }

    /// The guest's share: request out, answer back.
    var dispatch: TimeInterval? {
        guard let started = dispatchStartedAt,
              let returned = dispatchReturnedAt else { return nil }
        return returned.timeIntervalSince(started)
    }

    /// Answer back until an observation confirmed the effect. Absent when
    /// nothing ever confirmed it, which is a different statement from
    /// zero and must not be rendered as one.
    var settle: TimeInterval? {
        guard let returned = dispatchReturnedAt,
              let settled = settledAt else { return nil }
        return max(0, settled.timeIntervalSince(returned))
    }

    /// What the person waited: enqueue to the last thing that happened.
    var total: TimeInterval {
        max(settledAt ?? releasedAt, releasedAt).timeIntervalSince(enqueuedAt)
    }

    /// `NOWBASE act …`, one line, greppable beside the metal transfer
    /// rungs it shares a grammar with.
    ///
    /// An absent clock prints `-` rather than `0`: a settle that never
    /// happened and a settle that took no time are opposite results, and
    /// a table that renders both as zero is how an unconfirmed act gets
    /// averaged into a healthy one.
    var baselineLine: String {
        BaselineLine.line("act", [
            ("kind", kind.rawValue),
            ("op", operationID),
            ("label", label),
            ("outcome", outcome.rawValue),
            ("depth", String(queueDepthAtEntry)),
            ("waited_ms", Self.ms(waited)),
            ("dispatch_ms", Self.ms(dispatch)),
            ("settle_ms", Self.ms(settle)),
            ("total_ms", Self.ms(total)),
        ])
    }

    /// The same facts for a person reading `acts.log` mid-drive, where
    /// the question is always "is this one stuck, or behind something
    /// that is".
    var narrative: String {
        var parts = ["queued behind \(queueDepthAtEntry)"]
        if let waited { parts.append("waited \(Self.ms(waited))ms") }
        if let dispatch { parts.append("guest \(Self.ms(dispatch))ms") }
        parts.append(settle.map { "settled \(Self.ms($0))ms" }
            ?? "never settled")
        return parts.joined(separator: ", ")
            + ", total \(Self.ms(total))ms"
    }

    private static func ms(_ interval: TimeInterval?) -> String {
        guard let interval else { return "-" }
        return String(Int((interval * 1000).rounded()))
    }

    private static func msValue(_ interval: TimeInterval?) -> Int? {
        interval.map { Int(($0 * 1000).rounded()) }
    }

    /// The same measurement an agent reads over MCP. One conversion, here,
    /// so the headless client and the Mirror page cannot come to disagree
    /// about what a clock means.
    var projected: AgentIntegrationMirrorActMetric {
        .init(kind: kind.rawValue, operationID: operationID, label: label,
              outcome: outcome.rawValue,
              queueDepthAtEntry: queueDepthAtEntry,
              waitedMs: Self.msValue(waited),
              dispatchMs: Self.msValue(dispatch),
              settleMs: Self.msValue(settle),
              totalMs: Self.msValue(total) ?? 0)
    }
}
