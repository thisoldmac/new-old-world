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
    /// **The sentence behind the word**, verbatim from
    /// `GuestListener.SceneFailure.message`.
    ///
    /// `outcome` has five words in it and one of them — `failed` — is a
    /// bucket: no Mac connected, a scene already in flight, a short
    /// transfer, a delta that would not rebuild, and the watchdog's
    /// silence all land in it. The host computes a typed, written reason
    /// for each of those and spends it on `ambient`, which only the
    /// window sees. An agent reading `mirror_read --intention metrics`
    /// got the bucket and nothing else: on 2026-08-07 a live drive
    /// returned 14 of 24 cycles reading `failed` with every clock at
    /// zero, and nothing in the reply could say which of five bugs that
    /// was.
    ///
    /// It is carried, never parsed. The vocabulary of `outcome` is
    /// unchanged — this is the reason travelling beside it, not a sixth
    /// word.
    ///
    /// **Deliberately absent from `baselineLine`.** `BaselineLine`
    /// values are space-free by construction and its own comment warns
    /// against inviting "somebody to put a message in one"; a sanitised
    /// prose sentence would be an unreadable field in a grammar built to
    /// be diffed.
    var reason: String?
    /// What arrived, when it arrived: enough to see a rewalk's size
    /// rather than only its duration.
    ///
    /// **Nil unless this cycle published a scene.** They used to be read
    /// off the last GOOD scene on every cycle, so a run of failures
    /// reported the window and element counts of whatever had last
    /// worked — numbers that describe a different cycle, in the row of
    /// the one that never asked. `-` says the cycle produced nothing to
    /// count, which is what happened.
    var windows: Int?
    var elements: Int?
    /// **Where the guest spent the `request` half of this cycle**, from
    /// the scene's own `meta.phases`. The clocks above can only say the
    /// guest took a second; this says which second. Nil for a producer
    /// that does not report phases — never zeroes, which would be a
    /// measurement.
    var phases: NOWSceneDocument.Phases?

    /// **Where OUR half of the cycle went**, the same way `phases` says
    /// where the guest's did.
    ///
    /// `decode_ms` is a bracket, not a decode: it runs from "the delivery
    /// arrived" to "the Mirror published it", and everything this side
    /// does in between is charged to it. On 2026-08-06 it read 12,457 ms
    /// and every reading of that number started by looking for a
    /// quadratic in the JSON — because the field's name is the only thing
    /// anyone had. The document decodes, reduces and projects in 4 ms
    /// (`MirrorDecodeCostTests`); the rest was guest round-trips inside
    /// the bracket. One extra field would have said so in a grep.
    ///
    /// - `own` — decode, reduce, project. This host's own CPU.
    /// - `content` — the P3 join: guest round-trips, ours to schedule but
    ///   not ours to speed up.
    var ownWork: TimeInterval?
    var contentJoin: TimeInterval?

    /// **How many guest commands this cycle GAVE UP on.**
    ///
    /// `command.request` gained a watchdog on 2026-08-06
    /// (`GuestListener.commandWatchdogSeconds`), and a bound that is not
    /// reported is a silent truncation: the cycle would publish a scene
    /// missing its content join and nothing anywhere would say the answer
    /// had been abandoned rather than arrived. So a cycle that expired a
    /// command says `timeouts=N` on its own line.
    ///
    /// Emitted only when non-zero, for the reason `phfaults` is: a field
    /// that reads `0` on every line of a log teaches a reader to stop
    /// seeing it, and this one has to be visible the one time it appears.
    var guestTimeouts: Int?

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
        ] + Self.bracketFields(own: ownWork, content: contentJoin) + [
            ("total_ms", Self.ms(total)),
            ("windows", windows.map(String.init) ?? "-"),
            ("elements", elements.map(String.init) ?? "-"),
        ] + Self.timeoutField(guestTimeouts) + Self.phaseFields(phases))
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
    /// Present only for a cycle that got far enough to have them, the way
    /// `phaseFields` is — a cycle that never decoded has no split, and a
    /// `-` there would invite someone to read absence as zero.
    private static func bracketFields(own: TimeInterval?,
                                      content: TimeInterval?)
            -> [(String, String)] {
        var fields: [(String, String)] = []
        if let own { fields.append(("dc_own_ms", ms(own))) }
        if let content { fields.append(("dc_content_ms", ms(content))) }
        return fields
    }

    /// See `guestTimeouts`. Zero is not written: it is the ordinary case,
    /// and a field present on every line stops being read by the time it
    /// matters.
    private static func timeoutField(_ count: Int?) -> [(String, String)] {
        guard let count, count > 0 else { return [] }
        return [("timeouts", String(count))]
    }

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
        .init(walk: walk, outcome: outcome, reason: reason,
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

    /// A timeline describes one Mirror session. Keeping its rows across a
    /// stop or reconnection makes the next run's measurements unattributed.
    func reset() {
        records.removeAll()
    }

    static func write(_ clocks: MirrorCycleClocks) {
        ActLog.note(action: "cycle\n    " + clocks.baselineLine,
                    outcome: clocks.outcome,
                    ms: Int((clocks.total * 1000).rounded()))
    }
}
