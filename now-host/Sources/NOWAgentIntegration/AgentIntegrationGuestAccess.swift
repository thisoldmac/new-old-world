import Foundation

/// What the machine being driven answered, when asked whether a companion
/// agent may drive it and how far — `hello.agent` in
/// `contract/asyncapi.yaml`.
///
/// This is a CARRIER. Nothing here decides anything: enforcement lives in
/// one place on the host side and is not this type's business. What this
/// type owes its callers is that the three answers, the silence, and a tier
/// it has never heard of stay five distinguishable things — because the
/// defect this whole field exists to prevent is silence being read as a
/// yes.
///
/// Absence is `nil` and is NOT a case here, deliberately: an optional that
/// a caller must unwrap is harder to mistake for an answer than a
/// `.notStated` case sitting in a switch beside the real ones.
public enum AgentIntegrationGuestAccess: Sendable, Equatable, Hashable {
    /// The machine refuses. Either the installer omitted the agent
    /// features or somebody flipped the switch — one state on purpose, so
    /// there is one refusal path and one sentence for the caller.
    case disabled
    /// Consent, bounded to operations that change nothing on the machine.
    case readOnly
    /// Consent, unbounded within what the product can do at all.
    case fullAccess
    /// A tier this build has never heard of, kept verbatim.
    ///
    /// It means a NEWER sender, not a broken one, so it must not fail the
    /// hello decode — and it must not read as consent either: a receiver
    /// that cannot name the ceiling cannot claim to be under it. Kept as
    /// the raw token so a log line can say what was actually said.
    case unrecognized(String)

    /// Decodes the wire token. `nil` in, `nil` out — absence is preserved
    /// as absence rather than defaulted to anything.
    public init?(wire: String?) {
        guard let wire, !wire.isEmpty else { return nil }
        switch wire {
        case "disabled": self = .disabled
        case "read-only": self = .readOnly
        case "full": self = .fullAccess
        default: self = .unrecognized(wire)
        }
    }

    /// The token as the contract spells it. Round-trips `unrecognized`, so
    /// re-encoding a hello from a newer sender does not quietly drop what
    /// it said.
    public var wire: String {
        switch self {
        case .disabled: return "disabled"
        case .readOnly: return "read-only"
        case .fullAccess: return "full"
        case .unrecognized(let raw): return raw
        }
    }

    /// How this reads where a person sees it.
    public var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        case .readOnly: return "Read Only"
        case .fullAccess: return "Full Access"
        case .unrecognized(let raw): return "Unrecognised (\(raw))"
        }
    }
}

extension AgentIntegrationGuestAccess: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        /* The failable init only returns nil for absent/empty, and neither
           reaches here: an absent field decodes as a nil OPTIONAL of this
           type without ever calling in. */
        self = AgentIntegrationGuestAccess(wire: raw) ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }
}
