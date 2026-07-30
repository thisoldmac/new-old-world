import Foundation
import NOWAgentIntegration

/// Drives one page of one census probe for an agent face.
///
/// It is thin by construction: the census needs no composition at all, so
/// this layer addresses, bounds, forwards and renders, and decides nothing
/// about the machine (rule 2, docs/agent-integration.md). The one thing it
/// adds that the wire does not carry is the probe's COLUMN HEADINGS, which
/// are a contract constant rather than a fact about the Mac — see
/// `columns(for:)`.
///
/// **The distinction it exists to protect** is between the call's outcome and
/// the probe's. `AgentIntegrationProjectedResult` says whether a Macintosh
/// answered; the report inside a completed call says what that Macintosh
/// found. A probe that answers `refused` or `absent` is a **completed call**
/// carrying a finding, and the only things that leave the completed arm here
/// are calls that produced no census report at all. `HardwareCensusProjection`
/// carries the argument in full.
@MainActor
final class AgentIntegrationCensus {
    private enum PageOutcome {
        case report(CensusReport)
        case timedOut
    }

    /// The bound on one page, and it is this side's only one — `census
    /// .request` has no guest-side watchdog, so an unanswered probe would
    /// otherwise leave the caller waiting on a Macintosh forever.
    ///
    /// **Unmeasured, and declared so.** Not one census probe has run against
    /// a Macintosh (`docs/contract-coverage.md`, "tested only — the pure
    /// half"), so this is the same order as the measurements that exist
    /// beside it: `catsearch` is ~20 s per catalog pass on a real disk and
    /// `software.list`'s sweep ~4 s. It is chosen shorter than the local
    /// surface's own window for this operation so that a slow probe answers
    /// the caller a bounded refusal rather than a transport error, which
    /// would teach it nothing.
    static let pageTimeout: TimeInterval = 30

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let pageTimeout: TimeInterval
    private let clock: @MainActor () -> Date

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         pageTimeout: TimeInterval = AgentIntegrationCensus.pageTimeout,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.pageTimeout = pageTimeout
        self.clock = clock
    }

    func page(probe: String, cursor: Int?) async
        -> AgentIntegrationCensusResult {
        guard AgentIntegrationCensusPolicy.isValidProbe(probe) else {
            /* The projection refuses this before a request is composed and
               the local codec refuses it again on arrival; this is the third
               reading, for a caller that reached the adapter directly. The
               NAME is bounded here and never checked against a list — the
               registry is the guest's, and a host holding a stale copy would
               refuse a probe a newer guest serves. */
            let cap = AgentIntegrationProjectionPolicy
                .maximumSelectorScalars
            return refused(
                "now-census-probe-invalid",
                "A census probe is a name of 1 to \(cap) characters")
        }
        if let cursor, cursor < 0 {
            return refused(
                "now-census-cursor-invalid",
                "A census cursor is 0 or more; 0 starts the probe over")
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }

        let outcome = await run(probe: probe, cursor: cursor)
        guard currentSessionID() == sessionID else {
            /* Unavailable rather than refused: the machine that was asked is
               no longer the machine on the other end, so nothing here can say
               what it found. */
            return .unavailable(.init(
                code: "now-census-outcome-unknown",
                message: "The paired guest changed while the census page was "
                    + "in progress"))
        }
        switch outcome {
        case .timedOut:
            return refused(
                "now-census-outcome-unknown",
                "The paired guest did not answer the census page in time")
        case .report(let report):
            return render(report, asked: probe)
        }
    }

    // MARK: - The wire

    private func run(probe: String, cursor: Int?) async -> PageOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            listener.requestCensus(probe: probe, cursor: cursor) {
                guard !settled else { return }
                settled = true
                timeoutTask?.cancel()
                continuation.resume(returning: .report($0))
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(pageTimeout * 1_000_000_000))
                guard !Task.isCancelled, !settled else { return }
                settled = true
                continuation.resume(returning: .timedOut)
            }
        }
    }

    // MARK: - Rendering

    /// One `census.report` as a projected page.
    ///
    /// Everything it can refuse, it refuses rather than repairing — a census
    /// whose page this side had to patch up is a census nobody can quote.
    private func render(_ report: CensusReport, asked probe: String)
        -> AgentIntegrationCensusResult {
        /* An empty `probe` cannot come off the wire: the contract requires
           the field on every census.report. It is what `GuestListener`
           synthesizes when the request never became a report at all — a
           `refuse`/`error` frame routed by id, or the connection going. So
           this is the guest declining the FAMILY (or nothing answering),
           which is a refusal of the call and not a probe outcome. The guest's
           own sentence rides in the note and is forwarded rather than
           replaced, the way `reveal` forwards its one refusal code's words. */
        guard !report.probe.isEmpty else {
            return refused(
                "now-census-refused",
                report.note ?? "The paired guest refused the census request")
        }
        guard let outcome =
            AgentIntegrationCensusOutcome(rawValue: report.outcome) else {
            /* A vocabulary this side does not have. Refused rather than
               mapped onto `failed`: every value in that enum is a claim about
               what the machine did, and picking one to stand in for a word
               nobody here understands would be this side deciding. */
            return refused(
                "now-census-outcome-unknown",
                "The paired guest answered probe "
                    + bounded(report.probe, scalars: 64)
                    + " with an outcome this host does not know")
        }
        guard report.rows.count
            <= AgentIntegrationCensusBounds.maximumRowsPerPage else {
            /* Refused, not trimmed. Trimming would hand a caller a short page
               under a `hasMore` that says it is whole, which is the one
               failure a paginated answer must not be able to have. */
            return refused(
                "now-census-page-invalid",
                "The paired guest sent more than "
                    + "\(AgentIntegrationCensusBounds.maximumRowsPerPage) "
                    + "rows in one census page")
        }
        guard report.rows.allSatisfy({
            $0.count == AgentIntegrationCensusBounds.cellsPerRow
        }) else {
            /* The triple is the contract's, and the third cell is the DECODED
               meaning beside the raw one. A row this side padded would put an
               empty meaning next to a raw value, which reads as "the guest
               could not decode it" — a claim the guest never made. */
            return refused(
                "now-census-page-invalid",
                "A census row is a [name, raw, meaning] triple")
        }
        return .completed(.init(
            probe: bounded(report.probe,
                           scalars: AgentIntegrationProjectionPolicy
                               .maximumSelectorScalars),
            outcome: outcome,
            columns: Self.columns(for: report.probe),
            rows: report.rows.map { row in
                row.map {
                    bounded($0,
                            scalars: AgentIntegrationCensusBounds
                                .maximumCellScalars)
                }
            },
            hasMore: report.more,
            /* Carried as the guest sent it, including the case where `more`
               is true and there is no cursor to continue with. Inventing one
               would send the caller back to a page number the guest never
               offered. */
            nextCursor: report.cursor,
            total: report.total,
            note: report.note.map {
                bounded($0,
                        scalars: AgentIntegrationCensusBounds
                            .maximumNoteScalars)
            },
            observedAt: clock()))
    }

    /// The probe's column headings.
    ///
    /// They are not on the wire — `census.report` carries rows and no header
    /// — so they come from this host's copy of the closed registry
    /// (`CensusProbes`, pinned to the contract and to the guest's own order by
    /// `CensusProbeRegistryTests`). That is a contract constant being
    /// rendered, not a fact about the machine being answered here: the
    /// headings are the same on every Mac.
    ///
    /// **Empty for a probe this host's copy does not carry**, which is a
    /// newer guest's probe. Empty rather than a guess: two of the three
    /// headings are always `Raw` and `Meaning`, and emitting those beside an
    /// invented first one would put a label on somebody's data that nothing
    /// declared.
    private static func columns(for probe: String) -> [String] {
        CensusProbes.probe(id: probe)?.columns ?? []
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationCensusResult {
        .refused(.init(
            code: code,
            message: bounded(
                message,
                scalars: AgentIntegrationCensusBounds
                    .maximumRefusalScalars)))
    }

    private func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }

    private static func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }
}
