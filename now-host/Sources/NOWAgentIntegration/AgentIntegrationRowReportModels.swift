import Foundation

/// The answer shape of the guest's `x-commands` verbs, projected.
///
/// Five of the eleven capabilities in P1 are served by a command verb whose
/// declared output is `x-rowArray` — ordered `[label, value]` pairs, in
/// named groups. `gestalt` returns six groups; `tail`, `catsearch`,
/// `reveal` and the diagnostics trio return one each. That is one shape,
/// so it is one type: the contract already made this decision and copying
/// it five times would only create five chances to copy it differently.
///
/// **The rows are the guest's own words.** `x-commands` says so in as many
/// letters — "rows for a human to read, not a machine to parse" — and rule
/// 2 of the parity slice says the host may render but not answer. So this
/// type carries them and does not interpret them: a host that parsed a
/// `gestalt` row into a typed CPU field would be answering a question about
/// the machine out of its own head the moment the guest's wording changed.

/// One named group of rows, order preserved.
///
/// An array of pairs and not a dictionary, because the guest's order is
/// part of the answer — `overview` uses empty-valued rows as section
/// captions, which a map would scatter.
public struct AgentIntegrationGuestRowGroup:
    Codable, Equatable, Sendable {
    /// The output key the guest answered under: `gestalt`'s `cpu`,
    /// `memory`, `os`…; or the verb's own name for a single-group answer.
    public let name: String
    public let rows: [AgentIntegrationGuestRow]

    public init(name: String, rows: [AgentIntegrationGuestRow]) {
        self.name = name
        self.rows = rows
    }
}

/// One row: a label and a value, as the guest wrote them.
public struct AgentIntegrationGuestRow: Codable, Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One verb's answer.
public struct AgentIntegrationGuestRowReport:
    Codable, Equatable, Sendable {
    /// The verb that produced it, as `help` names it. Present so a report
    /// read out of a log says which question it answered.
    public let verb: String
    public let groups: [AgentIntegrationGuestRowGroup]
    /// The guest's own sentence about the edges of the answer, when it
    /// offered one — truncation, a bound reached, a probe not served.
    public let note: String?
    public let observedAt: Date

    public init(verb: String,
                groups: [AgentIntegrationGuestRowGroup],
                note: String? = nil,
                observedAt: Date) {
        self.verb = verb
        self.groups = groups
        self.note = note
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationGuestRowReportResult =
    AgentIntegrationProjectedResult<AgentIntegrationGuestRowReport>

/// #9, the guest's log for this launch — the `tail` verb.
public enum AgentIntegrationGuestLogPolicy {
    /// The verb's own bound, restated on this side so a request that could
    /// only be refused is refused HERE, before it costs a round trip to a
    /// 68030. `x-commands` declares "Default 20, most 40".
    public static let defaultLineCount = 20
    public static let maximumLineCount = 40

    public static func isValidLineCount(_ value: Int) -> Bool {
        value >= 1 && value <= maximumLineCount
    }
}

/// #13, the diagnostics trio, as one closed choice.
///
/// One operation and not three: none of them takes an argument, all three
/// answer row arrays, and the plan gives them a single home (a Diagnostics
/// module). Three operations would have been three names for "run the
/// diagnostic I picked".
public enum AgentIntegrationDiagnosticProbe:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// VRAM read cost by access method. Both guests. ~3 s, wants a still
    /// screen.
    case vprobe
    /// Where a staged capture read from — the verb that found the 180c
    /// addressing defect. NOW-68K; costs what a capture costs.
    case shotdiag
    /// Where the last file the guest RECEIVED spent its time. PowerPC.
    case putstat
}
