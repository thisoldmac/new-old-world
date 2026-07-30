import Foundation

/// #5 — bring a running process to the front, projected from
/// `process.front`.
///
/// The smallest of the eleven: one message, one reference, no payload. It is
/// also the one the plan uses to prove what a projection row costs once its
/// verb exists (P1b), so this file stays deliberately thin.
///
/// The TARGET is a process reference, not a name. A PSN is meaningful only
/// while the process it names lives, so the host hands out the same opaque,
/// revalidated `now-process-…` reference `requestQuit` already uses and the
/// guest re-validates it against a live process before acting. A name is a
/// human's identifier — it is capped at 31 characters, is not unique, and
/// belongs on the guest's own console (`front`), which is where the contract
/// puts it.

/// What came of the ask, from the `front` verb's declared outcomes.
///
/// The switch is cooperative — the Process Manager makes it when the guest
/// next yields — so "asked" and "it is in front" are different facts and
/// this enum keeps them apart.
public enum AgentIntegrationFrontOutcome:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// Asked, and a re-check confirms it is frontmost.
    case fronted
    /// The Toolbox accepted it and it was not frontmost at the deadline.
    case unconfirmed
    /// Nothing of that reference was running to front. **Not a success.**
    /// `quit` treats not-running as done because the asked-for state
    /// already holds; here it cannot — a caller whose next step assumes a
    /// window is in front must not read "it is not there" as done.
    case notRunning = "not-running"
    /// The Toolbox would not bring it forward.
    case refused
}

public struct AgentIntegrationFrontReceipt:
    Codable, Equatable, Sendable {
    /// The reference the caller sent, echoed so a receipt read later says
    /// which process this was about.
    public let reference: String
    /// The process's name as the guest's own listing shows it, when the
    /// guest still had it to report.
    public let name: String?
    public let outcome: AgentIntegrationFrontOutcome
    public let revalidatedAt: Date
    public let observedAt: Date

    public init(reference: String,
                name: String?,
                outcome: AgentIntegrationFrontOutcome,
                revalidatedAt: Date,
                observedAt: Date) {
        self.reference = reference
        self.name = name
        self.outcome = outcome
        self.revalidatedAt = revalidatedAt
        self.observedAt = observedAt
    }
}

public typealias AgentIntegrationFrontResult =
    AgentIntegrationProjectedResult<AgentIntegrationFrontReceipt>
