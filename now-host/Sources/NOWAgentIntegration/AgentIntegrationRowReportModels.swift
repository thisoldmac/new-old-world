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

/// #9, the guest's log for this launch — the `tail` verb, PAGED.
///
/// Every number here restates a bound the guest owns, so a request that
/// could only be refused is refused HERE, before it costs a round trip to a
/// 68030 — and `AgentIntegrationGuestLogTailTests` reads the guest's own
/// headers to hold the two sides equal, which is the "state a limit once"
/// rule adapted to a limit that two toolchains must both compile.
public enum AgentIntegrationGuestLogPolicy {
    /// The verb's default, which is the guest's own. `x-commands` declares
    /// "Default 20".
    public static let defaultLineCount = 20

    /// One ANSWER's bound — a page. `x-commands` declares "most 40 per
    /// answer" because a page must fit a 4 KB control frame; the guest's
    /// copy is `kLogQueryPageMax` (logquery.h).
    public static let pageLineCount = 40

    /// The guest ring's size — `kLogKept` in nowlog.h. Asking for more
    /// than the ring holds is asking for lines that do not exist, so this
    /// is the retrieval bound, reached by paging `before` cursors.
    public static let ringCapacity = 2000
    public static var maximumLineCount: Int { ringCapacity }

    /// The area tag field's width — nowlog.c writes "%-6.6s", the same
    /// truncation the host's own log applies, so "contin" and never
    /// "continuity". A longer filter could never match and is refused
    /// rather than answered with an empty tail.
    public static let areaTagScalars = 6

    /// One rendered line's cap. A stored guest line is at most 119 bytes
    /// (`kLogLineMax`), but control bytes cross escaped as \xNN, so the
    /// bound leaves room for a line of them rather than trimming one.
    public static let maximumLineScalars = 480

    /// The whole answer's budget in BYTES, the same derivation as the host
    /// log's: half the local frame cap for the lines, the envelope and the
    /// declared fields the other half. The retrieval stops PAGING when the
    /// budget is reached and says so in `shown` — older lines are dropped
    /// first, never silently.
    public static var maximumTotalBytes: Int {
        AgentIntegrationLocalProtocol.maximumMessageBytes / 2
    }
    public static let perLineEnvelopeBytes = 4

    /// The most `tail` round trips one retrieval may cost. A page that
    /// byte-budgets down to ~25 short lines reaches the whole ring in ~80;
    /// past this something is wrong with the cursor, and a loop that
    /// trusts a guest's cursor unboundedly is a loop a defective guest
    /// drives forever.
    public static let maximumPageRequests = 120

    /// The guest composes a command refusal into a 240-byte buffer; this
    /// is that with room for what it may quote back.
    public static let maximumRefusalScalars = 320

    public static func isValidLineCount(_ value: Int) -> Bool {
        value >= 1 && value <= maximumLineCount
    }

    /// An area filter is a non-empty tag no wider than the tag field.
    public static func isValidArea(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= areaTagScalars
    }
}

/// One retrieval of the guest's log — pages of the `tail` verb, reassembled.
///
/// Deliberately the same reading experience as
/// `AgentIntegrationHostLogTail`: whole formatted lines, oldest first, with
/// the answer's own edges declared beside them. The two logs are the two
/// halves of one wire, and an agent diagnosing it reads them side by side.
public struct AgentIntegrationGuestLogRetrieval: Codable, Equatable,
    Sendable {
    /// Whole lines, "HH:MM:SS area [!?] message", OLDEST first — the
    /// guest's clock, which is not this machine's and is not comparable to
    /// it.
    public let lines: [String]
    /// What the caller asked for, after the default was applied.
    public let requested: Int
    /// How many held lines match the filter, as the guest last reported it.
    /// The ring is live, so this can move between pages; the freshest
    /// answer wins.
    public let matching: Int
    /// "N of M", plus "(older ones did not fit)" when the byte budget or
    /// the page bound stopped the retrieval before the count did.
    public let shown: String
    /// The filter that was applied, echoed; nil when every area.
    public let area: String?
    /// The guest ring's size, so `matching == ringCapacity` reads as "the
    /// beginning of this launch has already rolled off".
    public let ringCapacity: Int
    /// Where the guest is writing this launch's file on ITS disk, as the
    /// guest names it; nil when the guest did not say.
    public let guestFile: String?
    /// How many wire round trips served this answer. Observability, and
    /// the honest cost of asking a 68030-class link for hundreds of lines.
    public let pages: Int
    public let observedAt: Date

    public init(lines: [String], requested: Int, matching: Int,
                shown: String, area: String?, ringCapacity: Int,
                guestFile: String?, pages: Int, observedAt: Date) {
        self.lines = lines
        self.requested = requested
        self.matching = matching
        self.shown = shown
        self.area = area
        self.ringCapacity = ringCapacity
        self.guestFile = guestFile
        self.pages = pages
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationGuestLogRetrievalResult =
    AgentIntegrationProjectedResult<AgentIntegrationGuestLogRetrieval>

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
