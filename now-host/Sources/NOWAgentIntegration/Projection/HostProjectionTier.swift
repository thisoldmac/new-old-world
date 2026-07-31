import Foundation

/// **How far a consenting machine has to have consented for one capability
/// to run** — the ceiling half of `hello.agent`.
///
/// Two tiers, ordered rather than boolean, so a third can slot in above
/// without re-shaping the wire token or anything that compares two of these.
/// Read Only is the floor because it is the tier every consenting machine
/// grants; a machine that grants nothing says `disabled` instead, which is
/// not a tier and is deliberately not a case here.
public enum HostCapabilityTier: String, Sendable, CaseIterable, Comparable {
    /// Reachable by a machine that consented to being READ and not changed.
    case readOnly = "read-only"
    /// Reachable only by a machine that consented to being driven.
    case fullAccess = "full"

    /// Where a person sees it — the same two words `AgentIntegrationGuestAccess`
    /// uses, because they name one thing and a second spelling of one thing is
    /// what this arc keeps deleting.
    public var displayName: String {
        switch self {
        case .readOnly: return "Read Only"
        case .fullAccess: return "Full Access"
        }
    }

    private var ordinal: Int {
        switch self {
        case .readOnly: return 0
        case .fullAccess: return 1
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// The tier a row needs, **derived from what the row already publishes**.
///
/// There is no fourth per-row field and there must not be one. Every row
/// already declares MCP's `readOnlyHint` in its `mcpDescriptor` annotations,
/// because that is what an agent reads before calling it; a tier declared
/// separately would be a second statement of the same fact, free to disagree
/// with the first. This arc has collapsed four hand-maintained capability
/// lists already — one of them a tool partition that broke the moment
/// guest-files could mutate — and a fifth would be that mistake with a fresh
/// coat (plan 006, stop condition 1).
///
/// **The boundary is `readOnlyHint`, and `destructiveHint` is not a second
/// boundary.** With two tiers a destructive row and a merely-changing row are
/// on the same side of the only line there is, so promoting `destructiveHint`
/// to a tier signal would invent a distinction the tiers cannot express.
/// What it is used for instead is COHERENCE: a row claiming to be read-only
/// and destructive at once is a row whose annotations cannot both be true,
/// and `HostProjectionConsentTests` fails naming it. That keeps the second
/// hint load-bearing without letting it move anything.
///
/// **The derivation reads the rendered descriptor, not the source text.**
/// Seven rows state their annotations through a shared fragment
/// (`HostProjectionSchema.readOnlyAnnotations`, `GuestFilesSchema
/// .uploadAnnotations`) rather than as their own literal, and a text scan
/// would see nineteen declarations and five or seven silent rows depending on
/// how it counted. Rendered, all twenty-six answer. A row that shares a
/// fragment is not a row that failed to declare.
public enum HostCapabilityTierDerivation {
    /// The row's published MCP annotations, or nil if it publishes none.
    public static func annotations(
        of projection: any HostProjection.Type
    ) -> [String: Any]? {
        projection.mcpDescriptor["annotations"] as? [String: Any]
    }

    /// One declared hint as an honest three-state: true, false, or **not
    /// stated**. Nil is what the gate below fails on; it is never a default.
    public static func hint(
        _ name: String,
        of projection: any HostProjection.Type
    ) -> Bool? {
        annotations(of: projection)?[name] as? Bool
    }

    /// The tier one row requires.
    ///
    /// A row that declares no `readOnlyHint` lands in `fullAccess` — the
    /// restrictive reading, because the safe answer to "we do not know what
    /// this changes" is not "let it through". That branch is unreachable
    /// while `testEveryRowDeclaresBothHints` is green, and it is written this
    /// way so that the failure mode of the gate lapsing is a capability
    /// needing MORE consent than it should rather than less.
    public static func requiredTier(
        of projection: any HostProjection.Type
    ) -> HostCapabilityTier {
        hint("readOnlyHint", of: projection) == true ? .readOnly : .fullAccess
    }
}

/// **What one machine's `hello.agent` answer permits.**
///
/// This is where the answer becomes a decision. It is not on
/// `AgentIntegrationGuestAccess` on purpose: that type is a carrier and says
/// so in its own header, and a `permits(...)` method hanging off it would put
/// policy on the thing whose whole job is to keep five readings
/// distinguishable.
public enum HostConsentCeiling {
    /// The machine consented up to and including this tier.
    case upTo(HostCapabilityTier)
    /// Nothing is permitted. Not "no answer" — an answer that grants
    /// nothing.
    case nothing

    /// The ceiling for one answer, including the two readings that are not
    /// tiers.
    ///
    /// - `disabled` → nothing. The machine refuses.
    /// - `read-only` / `full` → that tier.
    /// - **an unrecognised token → nothing.** Our call, and the schema's
    ///   argument: a receiver that cannot name the ceiling cannot claim to be
    ///   under it. Unlike silence, the machine DID answer — it stated a limit
    ///   this build cannot evaluate, and the only two readings available are
    ///   "assume it means at least full" and "we do not know". Assuming the
    ///   first would make an older host the way to escape a newer machine's
    ///   narrower tier, which is the one direction a version skew must never
    ///   open. The token is kept verbatim so the refusal can quote it.
    public static func ceiling(
        for answer: AgentIntegrationGuestAccess
    ) -> HostConsentCeiling {
        switch answer {
        case .disabled: return .nothing
        case .readOnly: return .upTo(.readOnly)
        case .fullAccess: return .upTo(.fullAccess)
        case .unrecognized: return .nothing
        }
    }

    /// Whether one tier is within this ceiling.
    public func permits(_ tier: HostCapabilityTier) -> Bool {
        switch self {
        case .nothing: return false
        case .upTo(let granted): return tier <= granted
        }
    }
}
