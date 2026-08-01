import Foundation

/// **The shapes `now_wait_for` answers in**, and the clock it polls
/// against.
///
/// See `WaitForProjection`'s header for what this row does and does not
/// wait for; this file holds only its vocabulary.

/// What a caller may wait for. Three predicates over `process.list`'s own
/// rows — nothing this row cannot already read without a new guest message.
public enum AgentIntegrationWaitCondition: String, Codable, Sendable {
    /// A process named `name` appears in the listing, in any position.
    case running
    /// A process named `name` appears in the listing AND is marked front.
    case front
    /// NO process named `name` appears in the listing — the mirror of
    /// `running`, for waiting out a quit.
    case gone
}

/// What satisfied the wait.
public struct AgentIntegrationWaitReceipt: Codable, Equatable, Sendable {
    public let name: String
    public let until: AgentIntegrationWaitCondition
    /// How long the poll ran before the condition held, measured by this
    /// host's own clock — never the guest's, which states no notion of
    /// elapsed wall time across a poll.
    public let elapsedMs: Int
    /// When the LISTING that satisfied the condition was taken. The guest's
    /// own `observedAt`, copied through rather than recomputed — this row
    /// does not backdate a satisfaction to when the poll started.
    public let observedAt: Date

    public init(name: String, until: AgentIntegrationWaitCondition,
                elapsedMs: Int, observedAt: Date) {
        self.name = name
        self.until = until
        self.elapsedMs = elapsedMs
        self.observedAt = observedAt
    }
}

/// The condition never held inside the bound. Not a refusal: the poll ran
/// exactly as asked and the machine answered every time; the fact reported
/// is that the condition was false at every observation taken.
public struct AgentIntegrationWaitTimeoutReport:
    Codable, Equatable, Sendable {
    public let name: String
    public let until: AgentIntegrationWaitCondition
    public let elapsedMs: Int
    public let timeoutMs: Int
    /// The last listing's own timestamp, when at least one poll completed.
    /// Absent only if the bound was too short to complete even one —
    /// `AgentIntegrationWaitPolicy.minimumTimeoutMs` keeps that from being
    /// silent, but a caller reading this field gets the fact rather than an
    /// inference from the numbers beside it.
    public let lastObservedAt: Date?

    public init(name: String, until: AgentIntegrationWaitCondition,
                elapsedMs: Int, timeoutMs: Int, lastObservedAt: Date?) {
        self.name = name
        self.until = until
        self.elapsedMs = elapsedMs
        self.timeoutMs = timeoutMs
        self.lastObservedAt = lastObservedAt
    }
}

/// One wait's whole answer: it held, the bound ran out first, or nobody
/// could be asked at all.
///
/// Three cases and not `AgentIntegrationProjectedResult`'s two-plus-refused:
/// `process.list` itself has no `refused` outcome
/// (`AgentIntegrationProcessListResult` is `available` or `unavailable`
/// only), so a `refused` arm here would be a case this row could never
/// reach honestly. `timedOut` takes its place, and it is not a synonym for
/// failure — see `AgentIntegrationWaitTimeoutReport`.
public enum AgentIntegrationWaitResult: Equatable, Sendable {
    case satisfied(AgentIntegrationWaitReceipt)
    case timedOut(AgentIntegrationWaitTimeoutReport)
    case unavailable(AgentIntegrationUnavailable)

    public static var hostUnavailable: Self { .unavailable(.host) }
}

extension AgentIntegrationWaitResult: Codable {
    private enum Outcome: String, Codable {
        case satisfied
        case timedOut
        case unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case satisfied
        case timedOut
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .satisfied:
            self = .satisfied(try container.decode(
                AgentIntegrationWaitReceipt.self, forKey: .satisfied))
        case .timedOut:
            self = .timedOut(try container.decode(
                AgentIntegrationWaitTimeoutReport.self, forKey: .timedOut))
        case .unavailable:
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .satisfied(let receipt):
            try container.encode(Outcome.satisfied, forKey: .outcome)
            try container.encode(receipt, forKey: .satisfied)
        case .timedOut(let report):
            try container.encode(Outcome.timedOut, forKey: .outcome)
            try container.encode(report, forKey: .timedOut)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

/// The bound this row enforces, stated once so the schema, the decode and
/// the poll loop all read the same numbers.
///
/// **The hard cap is 10 seconds and this row does not take a larger one.**
/// An agent call that blocks the host's local socket for an unbounded time
/// is the failure this cap is shaped against — a caller that needs longer
/// polls again, honestly, rather than being handed a lane that can hang.
public enum AgentIntegrationWaitPolicy {
    public static let minimumTimeoutMs = 100
    public static let maximumTimeoutMs = 10_000
    public static let defaultTimeoutMs = 5_000
    /// How often the loop re-reads `process.list`. Not exposed to a caller —
    /// it is this row's own cost control, not a fact about the machine.
    public static let pollIntervalMs = 200

    public static func isValidTimeout(_ value: Int) -> Bool {
        value >= minimumTimeoutMs && value <= maximumTimeoutMs
    }
}

/// The clock a poll loop measures elapsed time against and waits on between
/// reads — injected so a test can run the loop's real logic (the
/// condition check, the timeout arithmetic, the multi-read sequencing)
/// without a test suite spending real wall-clock seconds asleep.
public protocol AgentIntegrationWaitClock: Sendable {
    func now() -> Date
    func sleep(milliseconds: Int) async
}

/// The real clock: wall time and a real, cancellable sleep. What
/// `WaitForProjection.invoke` uses outside a test.
public struct AgentIntegrationSystemWaitClock: AgentIntegrationWaitClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(milliseconds: Int) async {
        try? await Task.sleep(
            nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}
