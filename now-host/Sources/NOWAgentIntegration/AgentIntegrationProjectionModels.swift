import Foundation

public protocol AgentIntegrationSettledActReceipt {
    var correlation: String? { get }
    var settlement: String { get }
}

/// The shared shapes the eleven projected capabilities answer in.
///
/// They live in one file because they are one decision, not eleven: the
/// local surface had grown a bespoke result envelope per capability, and
/// eleven more of those would have been eleven more `Codable`
/// implementations saying the same three things. A capability whose answer
/// genuinely does not fit here keeps its own type (the guest-files family
/// and capture both do); a capability that only needs "it worked, here is
/// the value" / "the machine said no" / "nobody could ask" uses this.

/// Why a capability did not answer, said by whichever side said no.
///
/// Distinct from `AgentIntegrationLocalError`, which is this socket's own
/// protocol failure: a guest refusing a path is not a malformed message,
/// and collapsing the two would let a caller read a real answer as a bug.
public struct AgentIntegrationProjectionFailure:
    Codable, Equatable, Sendable {
    /// **Did the refused call reach the machine's act plane?**
    ///
    /// A refusal answers two different questions at once, and only one of
    /// them was ever readable here: *why* it was refused, and *whether
    /// anything might have happened anyway*. The second decides whether a
    /// caller may stop waiting, so it is a value rather than a sentence to
    /// be pattern-matched — reading "was not sent" out of prose is how the
    /// Mirror's FIFO came to hold itself open for fifteen seconds after a
    /// refusal that had demonstrably done nothing.
    ///
    /// `notSent` is a claim about the machine and is only made where this
    /// side can prove it: the request never left (a local refusal), or the
    /// guest refused it before its act plane registered a correlation.
    /// Everything else is `unknown`, which is the safe direction — a
    /// caller that waits needlessly loses time, a caller that stops waiting
    /// wrongly loses the effect.
    public enum Reach: String, Codable, Equatable, Sendable {
        case notSent
        case unknown
    }

    public let code: String
    public let message: String
    public let correlation: String?
    public let settlement: String?
    public let reach: Reach

    public init(code: String, message: String,
                correlation: String? = nil, settlement: String? = nil,
                reach: Reach = .unknown) {
        self.code = code
        self.message = message
        self.correlation = correlation
        self.settlement = settlement
        self.reach = reach
    }

    /* Decoded tolerantly, because `reach` is newer than the callers that
       read this shape: a refusal written before the field existed says
       nothing about whether it reached the machine, and "nothing" is
       exactly `unknown`. */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        correlation = try container.decodeIfPresent(String.self,
                                                    forKey: .correlation)
        settlement = try container.decodeIfPresent(String.self,
                                                   forKey: .settlement)
        reach = try container.decodeIfPresent(Reach.self, forKey: .reach)
            ?? .unknown
    }
}

/// One projected answer: the value, a refusal, or nobody to ask.
///
/// Three cases and not two, because "the machine said no" and "there was
/// no machine" are different facts and only one of them is fixed by
/// plugging something in — the same distinction `x-census` draws between
/// `refused` and `absent`, kept at this layer too.
public enum AgentIntegrationProjectedResult<
    Value: Codable & Equatable & Sendable
>: Equatable, Sendable {
    case completed(Value)
    case refused(AgentIntegrationProjectionFailure)
    case unavailable(AgentIntegrationUnavailable)

    public static var hostUnavailable: Self { .unavailable(.host) }
    public static var guestUnavailable: Self { .unavailable(.guest) }
}

extension AgentIntegrationProjectedResult: Codable {
    private enum Outcome: String, Codable {
        case completed
        case refused
        case unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case completed
        case refused
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .completed:
            self = .completed(
                try container.decode(Value.self, forKey: .completed))
        case .refused:
            self = .refused(try container.decode(
                AgentIntegrationProjectionFailure.self, forKey: .refused))
        case .unavailable:
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed(let value):
            try container.encode(Outcome.completed, forKey: .outcome)
            try container.encode(value, forKey: .completed)
        case .refused(let failure):
            try container.encode(Outcome.refused, forKey: .outcome)
            try container.encode(failure, forKey: .refused)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

extension AgentIntegrationUnavailable {
    /// The operation exists on the wire and NOTHING SERVES IT YET.
    ///
    /// A verb landed ahead of the adapter that will answer it, deliberately
    /// (`docs/plans/2026-07-30-005`, P1a): the serialization for eleven
    /// capabilities went in as one commit so eleven agents would not each
    /// edit the same three list tails. Until a capability's own row lands,
    /// its handler answers THIS — because the alternative, an empty
    /// success, is a trap for whoever inherits it. An empty listing reads
    /// as "the machine has no software installed"; this reads as what is
    /// true.
    ///
    /// It is reachable only by a caller that composes the request itself:
    /// no projection row claims these operations, so no face can send one.
    public static func notWired(_ operation: String)
        -> AgentIntegrationUnavailable {
        AgentIntegrationUnavailable(
            code: "now-capability-not-wired",
            message: "\(operation) is carried by this host's local "
                + "protocol and no capability serves it yet")
    }
}

/// Bounds the projected operations share.
///
/// Stated once because the alternative is what the control-frame cap did:
/// the same limit in the sender, in the receiver's buffer, and in prose,
/// as three different numbers.
public enum AgentIntegrationProjectionPolicy {
    /// A probe, domain or verb-target name. Generous for an HFS path
    /// (`reveal` and `launch` share their target grammar, and a full path
    /// is a legal one) and far short of the 16 KiB frame.
    public static let maximumSelectorScalars = 255

    /// The two paginated projections do NOT share a cursor floor, and the
    /// difference is the contract's, not ours: `software.list` is 1-based
    /// over a cached inventory (1 rebuilds the cache), while
    /// `census.request` treats 0 and absent alike as "start the probe
    /// over". Each decode branch states its own floor rather than one
    /// helper flattening them into a number that is wrong for one side.
    public static func isBoundedSelector(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.count <= maximumSelectorScalars
    }
}
