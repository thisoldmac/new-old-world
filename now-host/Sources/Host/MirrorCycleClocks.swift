import Foundation
import NOWAgentIntegration

/// The clocks of one scene cycle — the other half of "it felt slow".
///
/// `MirrorActClocks` measures a MUTATION: a person clicked and waited.
/// This measures the OBSERVATION the Mirror is built out of, and the two
/// are charged to different repairs. An act's settle time is mostly this
/// cycle's period, because an act confirms from a later scene: making the
/// walk cheaper shortens every act on the machine without touching the
/// act path at all.
///
/// The split matters most for the case the user named — forcing a full
/// rewalk. Structure alone and structure-plus-semantics-plus-interaction
/// are very different amounts of guest work, and a baseline that averaged
/// them would describe a machine that does not exist.
///
/// - `request` — asking until the delivery arrived. Guest walk plus wire.
/// - `decode` — delivery arrived until the Mirror published it. Ours.
/// - `idle` — the previous cycle publishing until this one asked. The
///   poll cadence, and pure added latency: no work happens in it.
struct MirrorCycleClocks: Equatable {
    var requestedAt: Date
    var deliveredAt: Date?
    var publishedAt: Date
    /// The gap since the last cycle published, when there was one. First
    /// cycle of a run has no predecessor and reports `-` rather than 0.
    var idleBefore: TimeInterval?
    /// Which planes were asked for. A structure-only cycle and a full
    /// walk are not comparable numbers and must not share a row.
    var semantics: Bool
    var interaction: Bool
    /// `ok`, or the reason it produced no scene. A failed cycle still
    /// spent the guest's time and still belongs in the record.
    var outcome: String
    /// What arrived, when it arrived: enough to see a rewalk's size
    /// rather than only its duration.
    var windows: Int?
    var elements: Int?
    /// **Where the guest spent the `request` half of this cycle**, from
    /// the scene's own `meta.phases`. The clocks above can only say the
    /// guest took a second; this says which second. Nil for a producer
    /// that does not report phases — never zeroes, which would be a
    /// measurement.
    var phases: NOWSceneDocument.Phases?

    var request: TimeInterval? {
        deliveredAt.map { $0.timeIntervalSince(requestedAt) }
    }

    var decode: TimeInterval? {
        deliveredAt.map { publishedAt.timeIntervalSince($0) }
    }

    var total: TimeInterval { publishedAt.timeIntervalSince(requestedAt) }

    /// The planes as one greppable token, because a baseline table is
    /// grouped by this before anything else in it means anything.
    var walk: String {
        switch (semantics, interaction) {
        case (false, false): return "structure"
        case (true, false): return "structure+semantics"
        case (false, true): return "structure+interaction"
        case (true, true): return "full"
        }
    }

    var baselineLine: String {
        BaselineLine.line("cycle", [
            ("walk", walk),
            ("outcome", outcome),
            ("idle_ms", Self.ms(idleBefore)),
            ("request_ms", Self.ms(request)),
            ("decode_ms", Self.ms(decode)),
            ("total_ms", Self.ms(total)),
            ("windows", windows.map(String.init) ?? "-"),
            ("elements", elements.map(String.init) ?? "-"),
        ] + Self.phaseFields(phases))
    }

    /// **The phases go HERE and not on the ambient status line.**
    ///
    /// The line under the mirror is one line a person reads at a glance
    /// while watching a machine work, and eight microsecond counts would
    /// destroy exactly the thing it is good at. This record is the other
    /// audience: `NOWBASE cycle` is already the project's grammar for a
    /// measurement that gets copied out of a log into a commit message
    /// (docs/68k-metal-baseline.md), it is already written once per
    /// cycle, and a greppable `ph_controls=` is what turns "why was that
    /// scene slow" into one command.
    ///
    /// KEYS ARE SORTED rather than left in dictionary order: a
    /// measurement grammar whose field order changes between runs cannot
    /// be diffed, and diffing two runs is the whole point.
    /// `phcost_us` rides beside them because a breakdown that will not
    /// state its own weight is asking to be trusted rather than read.
    private static func phaseFields(_ phases: NOWSceneDocument.Phases?)
            -> [(String, String)] {
        guard let phases else { return [] }
        var fields = (phases.us ?? [:]).sorted { $0.key < $1.key }
            .map { ("ph_\($0.key)_us", String($0.value)) }
        if let cost = phases.clockUs {
            fields.append(("phcost_us", String(cost)))
        }
        if let reads = phases.clockReads {
            fields.append(("phreads", String(reads)))
        }
        if let faults = phases.faults, faults != 0 {
            /* Only when non-zero, and then loudly: a fault means one of
               the numbers above is wrong, and a field that is always
               `0` teaches a reader to stop seeing it. */
            fields.append(("phfaults", String(faults)))
        }
        return fields
    }

    private static func ms(_ interval: TimeInterval?) -> String {
        guard let interval else { return "-" }
        return String(Int((interval * 1000).rounded()))
    }

    private static func msValue(_ interval: TimeInterval?) -> Int? {
        interval.map { Int(($0 * 1000).rounded()) }
    }

    /// One conversion for both faces — see `MirrorActClocks.projected`.
    var projected: AgentIntegrationMirrorCycleMetric {
        .init(walk: walk, outcome: outcome,
              idleMs: Self.msValue(idleBefore),
              requestMs: Self.msValue(request),
              decodeMs: Self.msValue(decode),
              totalMs: Self.msValue(total) ?? 0,
              windows: windows, elements: elements)
    }
}

/// A rolling view of the scene cadence, for the Mirror page and for the
/// log.
///
/// Deliberately keeps the LAST of each walk kind rather than a running
/// average. Rule 2 of `docs/mirror-measurement-method.md`: trials that
/// are not independent measure drift, and these are not independent —
/// a full walk right after another is reading a warm guest. The spread
/// is the interesting part, so the records stay separate and a person
/// reads them.
@MainActor
final class MirrorCycleTimeline: ObservableObject {
    static let capacity = 24

    @Published private(set) var records: [MirrorCycleClocks] = []

    private let log: (MirrorCycleClocks) -> Void

    init(log: @escaping (MirrorCycleClocks) -> Void
            = MirrorCycleTimeline.write) {
        self.log = log
    }

    func record(_ clocks: MirrorCycleClocks) {
        records.append(clocks)
        if records.count > Self.capacity { records.removeFirst() }
        log(clocks)
    }

    /// The most recent cycle of one walk kind, which is the only
    /// like-for-like comparison this data supports.
    func latest(walk: String) -> MirrorCycleClocks? {
        records.last { $0.walk == walk }
    }

    static func write(_ clocks: MirrorCycleClocks) {
        ActLog.note(action: "cycle\n    " + clocks.baselineLine,
                    outcome: clocks.outcome,
                    ms: Int((clocks.total * 1000).rounded()))
    }
}
