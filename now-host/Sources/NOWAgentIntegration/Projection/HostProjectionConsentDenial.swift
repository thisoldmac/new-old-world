import Foundation

/// **The machine can, and declines.**
///
/// This is a different fact from every "this guest cannot do that" the
/// surface already says, and it gets its own type because the surface is
/// already fluent in the other one: `unavailable`, `unproven`, the family
/// ledger and `not-implemented` all mean a capability is MISSING. Routed
/// through any of them, a refusal by consent would reach an agent as *"this
/// machine cannot take screenshots"* when the truth is *"this machine's owner
/// said no"* — and the person who then goes looking for a broken capability
/// is debugging a machine that is working correctly.
///
/// So a caller must be able to tell the two apart **without reading the
/// prose**, and on the MCP face it can:
///
/// - **incapacity** arrives as a tool RESULT — `isError: false`, an
///   `unavailable` (or `refused`) arm inside the row's own output schema.
///   The call happened and the answer is about the machine.
/// - **a consent denial** arrives as a JSON-RPC ERROR with this type's
///   `jsonRPCCode`, and `error.data.reason` is one of three enumerated
///   grounds. Nothing was asked of the machine at all.
///
/// The wording follows the same split, so a person reading a log line or an
/// agent quoting a message never has to guess which kind of no it was.
public struct HostProjectionConsentDenial: Equatable, Sendable {
    /// Why consent was not there. Enumerated rather than described so a
    /// caller can branch, and so the three cases stay countable when a third
    /// tier arrives.
    public enum Ground: String, Equatable, Sendable {
        /// The machine answered `disabled`: it refuses agent control
        /// outright. One state for both the installer's omission and the
        /// switch being flipped — plan 006 wants one refusal path, not two.
        case machineDeclines = "machine-declines"
        /// The machine consented, to less than this capability needs.
        case aboveGrantedTier = "above-granted-tier"
        /// The machine named a ceiling this build cannot evaluate, so this
        /// build cannot claim to be under it.
        case unrecognizedTier = "unrecognized-tier"
    }

    /// The JSON-RPC error code a consent denial is reported under.
    ///
    /// In the implementation-defined range (-32000…-32099) and deliberately
    /// NOT -32602: an invalid-params error says the caller asked wrongly, and
    /// this caller asked correctly. Retrying with different arguments is the
    /// obvious response to the first and useless against the second.
    public static let jsonRPCCode = -32010

    public let ground: Ground
    /// Which capability was refused, by the one spelling the registry keys
    /// on.
    public let capability: String
    /// The tier the row needs, derived from what it publishes.
    public let requiredTier: HostCapabilityTier
    /// What the machine actually said, verbatim — including a token this
    /// build does not recognise, which is precisely the case where the raw
    /// string is the only useful thing anybody has.
    public let machineAnswer: String

    public init(ground: Ground,
                capability: HostCapabilityID,
                requiredTier: HostCapabilityTier,
                machineAnswer: String) {
        self.ground = ground
        self.capability = capability.rawValue
        self.requiredTier = requiredTier
        self.machineAnswer = machineAnswer
    }

    /// The short form, for the audit line a person reads at the machine.
    ///
    /// Bounded by habit rather than by luck: the audit event truncates a
    /// reason at 120 scalars, and these three sentences are written to fit
    /// so a log line is never cut mid-word.
    public var reason: String {
        switch ground {
        case .machineDeclines:
            return "this machine declines agent control (said \"disabled\")"
        case .aboveGrantedTier:
            return "this machine granted \(machineAnswer), and this needs "
                + requiredTier.displayName
        case .unrecognizedTier:
            return "this machine named a tier this build does not know "
                + "(\"\(machineAnswer)\")"
        }
    }

    /// The long form, written for the agent that called.
    ///
    /// Every one of them says the same two things, because they are the two
    /// a caller gets wrong: the machine is CAPABLE of this, and no host-side
    /// setting is the way through.
    public var message: String {
        switch ground {
        case .machineDeclines:
            return "\(capability) was not attempted: the Macintosh answered "
                + "\"disabled\" when it connected, so it accepts nothing "
                + "from an agent. This is consent, not capability — the "
                + "machine can do this and its owner has said no. It is "
                + "changed at that machine, and nothing on this host "
                + "overrides it."
        case .aboveGrantedTier:
            return "\(capability) was not attempted: it needs "
                + "\(requiredTier.displayName) and the Macintosh granted "
                + "\(machineAnswer). This is consent, not capability — the "
                + "machine can do this and its owner has granted less. "
                + "Read-only capabilities still work; this one is changed "
                + "at that machine."
        case .unrecognizedTier:
            return "\(capability) was not attempted: the Macintosh answered "
                + "\"\(machineAnswer)\", a consent tier this host does not "
                + "recognise, so this host has no reading of what it was "
                + "granted. This is consent, not capability. It reads as a NEWER "
                + "Macintosh than this host — update the host rather than "
                + "the machine."
        }
    }

    /// What travels in a JSON-RPC error's `data`, so a caller branches on
    /// fields rather than on the sentence.
    public var errorData: [String: Any] {
        [
            "kind": "consent",
            "reason": ground.rawValue,
            "capability": capability,
            "requiredTier": requiredTier.rawValue,
            "machineAnswer": machineAnswer,
        ]
    }
}
