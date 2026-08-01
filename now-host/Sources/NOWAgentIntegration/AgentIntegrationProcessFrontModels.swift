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

/// What came of the ask — **confirmed frontmost, or only accepted.**
///
/// The guest draws that distinction and the wire cannot carry it. The
/// `front` CONSOLE verb yields for `kProcFrontWaitSecs` and re-reads
/// `GetFrontProcess`, so it can answer `kProcFrontDone` versus
/// `kProcFrontUnconfirmed` (`now-guest-ppc/src/processes/proc_actions.h`).
/// The `process.front` MESSAGE both guests serve is thin over
/// `SetFrontProcess` and answers `process.result`, which has `ok` and a
/// reason and no field that could carry "and it landed" — the 68K guest's
/// `handle_process_drive` says so in as many words. **So `ok:true` off the
/// wire is `unconfirmed` and nothing more.**
///
/// `fronted` is therefore earned host-side, by the check the guest's own
/// comment recommends: re-list, and read the `front` flag on the target's
/// row. That is the sanctioned composition — every fact in it came from the
/// guest in the same breath, and the confirming answer comes from
/// `process.list`, a different subsystem from the one that was just asked.
///
/// Two cases and not four. Whether the machine REFUSED, and whether there
/// was anything there to front, are carried by the envelope
/// (`AgentIntegrationProjectedResult.refused`) rather than by a second
/// success-shaped outcome — a receipt is what a completed ask produced, and
/// `completed(outcome: refused)` would say both things about one call.
/// Not-running in particular is a refusal here where `quit` treats it as
/// done: quit's asked-for state already holds, and you cannot front what is
/// not there.
public enum AgentIntegrationFrontOutcome:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// Asked, and a fresh listing shows it frontmost.
    case fronted
    /// Asked and accepted, and NOT confirmed frontmost. Either the switch
    /// had not landed when the confirming listing was read — it happens
    /// when the guest next yields — or nothing could confirm it, because
    /// the listing did not come back or carried no `front` flag.
    case unconfirmed
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
    /// When the reference was matched against a fresh listing, immediately
    /// before the ask.
    public let revalidatedAt: Date
    /// When the CONFIRMING listing was read — the moment `outcome` is a
    /// fact about, and already in the past by the time a caller reads it.
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
