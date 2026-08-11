import Foundation

/// #2 — the hardware census, projected from `census.request` /
/// `census.report`.
///
/// The paged family and not the `census` console verb, for the same reason
/// `ListProcessesProjection` projects `process.list` rather than `ps`: the
/// verb is the flat single-page read a person types, the family is the one
/// that paginates and carries a per-probe OUTCOME. Losing the outcome would
/// be the one thing `x-census` is most emphatic about — "we did not look"
/// and "it is not there" are never conflated.

/// The report's outcome vocabulary, closed, from `x-census.x-outcomes`.
///
/// It is projected verbatim rather than reduced to a boolean: `absent` is a
/// FINDING about the machine (no expansion slots), `refused` is the
/// responder declining to look, and a host that folded either into "no
/// data" would be inventing an answer.
public enum AgentIntegrationCensusOutcome:
    String, Codable, Equatable, Sendable, CaseIterable {
    case present
    case absent
    case partial
    case refused
    case failed
    case notAttempted = "not-attempted"
}

/// One page of one probe.
public struct AgentIntegrationCensusPage: Codable, Equatable, Sendable {
    public let probe: String
    public let outcome: AgentIntegrationCensusOutcome
    /// The probe's column headings, which vary by probe — `[Fact, Raw,
    /// Meaning]` for `overview`, `[Volume, Raw, Meaning]` for `volumes`.
    /// Carried because the rows are positional triples and a renderer
    /// cannot name their columns otherwise.
    public let columns: [String]
    /// `[name, raw, meaning]` triples. The raw value always survives
    /// beside the decoded meaning — a value the guest could not decode
    /// keeps its raw form and says so, rather than being dropped.
    public let rows: [[String]]
    public let hasMore: Bool
    public let nextCursor: Int?
    /// Rows the probe will yield in total, when the guest knows.
    public let total: Int?
    /// One sentence: why partial, why refused, what `absent` means on this
    /// machine.
    public let note: String?
    public let observedAt: Date

    public init(probe: String,
                outcome: AgentIntegrationCensusOutcome,
                columns: [String],
                rows: [[String]],
                hasMore: Bool,
                nextCursor: Int?,
                total: Int? = nil,
                note: String? = nil,
                observedAt: Date) {
        self.probe = probe
        self.outcome = outcome
        self.columns = columns
        self.rows = rows
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.total = total
        self.note = note
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationCensusResult =
    AgentIntegrationProjectedResult<AgentIntegrationCensusPage>

public enum AgentIntegrationCensusPolicy {
    /// What a probe name runs when the caller does not choose: the
    /// registry's synthesis probe, and the same default the `census` verb
    /// applies to an empty line.
    public static let defaultProbe = "overview"

    /// The probe registry is CLOSED but it is the GUEST's, not ours: an
    /// unknown name is answered `refused` with a note, never a protocol
    /// error, and that is what keeps the registry additive across
    /// versions. So this side bounds the name and does not enumerate it —
    /// a host holding a stale copy of the list would refuse a probe a
    /// newer guest serves.
    public static func isValidProbe(_ value: String) -> Bool {
        AgentIntegrationProjectionPolicy.isBoundedSelector(value)
    }
}
