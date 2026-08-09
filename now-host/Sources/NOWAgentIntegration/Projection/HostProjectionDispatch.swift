import Foundation

/// The one way a face invokes a capability.
///
/// It exists for one reason: **a capability invoked by a non-user face emits
/// an audit event**, and that has to be mechanical rather than a habit. The
/// registry gave every face one lookup instead of a twelve-case switch, so
/// there is exactly one place an invocation happens — this one — and the
/// event is emitted there rather than in each row. A row cannot forget what
/// it never writes, and the next capability's author gets the behaviour by
/// adding a row.
///
/// A face constructs one of these with its own identity and its own sink.
/// The sink is not optional and has no default: a face that cannot say where
/// its audit events go cannot be built, which is a stronger guarantee than
/// any test, because it is checked by the compiler.
///
/// `HostProjectionAuditGateTests` holds the other half — nothing outside
/// this file may call a projection's `invoke` — because a face that reached
/// past this seam would be exactly the opaque control plane rule 3 refuses.
public struct HostProjectionDispatch {
    public let face: HostInvokingFace
    private let registry: HostProjectionRegistry
    private let audit: any HostProjectionAuditSink

    public init(face: HostInvokingFace,
                registry: HostProjectionRegistry = .hostFaces,
                audit: any HostProjectionAuditSink) {
        self.face = face
        self.registry = registry
        self.audit = audit
    }

    /// Invoke one capability by name, or nil if no row claims that name.
    ///
    /// Nil emits nothing, and that is deliberate: an unknown name is not an
    /// invocation of anything, there is no capability to name in a line, and
    /// the face already answers its caller "unknown tool". What a *known*
    /// capability comes to is always recorded, refusals included.
    ///
    /// The event is emitted once, after the outcome is known, rather than as
    /// a begun/ended pair. Two lines would double the local round-trips the
    /// MCP face spends per call, and the families underneath already log
    /// their own begin lines under `sw`, `proc` and `files`. The known cost:
    /// a call that is still waiting on a 32-second launch has not been
    /// logged yet, and one that takes the process down is never logged.
    public func invoke(
        _ name: String,
        arguments: HostProjectionArguments,
        guest selector: String?,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome? {
        guard let projection = registry.projection(named: name) else {
            return nil
        }
        let outcome: HostProjectionOutcome
        if let denial = await consentDenial(invoking: projection,
                                            through: client) {
            outcome = .deniedByConsent(denial)
        } else if let refusal = arguments.refusalForUnknownMembers(
            tool: projection.capability,
            accepting: projection.acceptedArguments) {
            outcome = .invalidArguments(refusal)
        } else {
            outcome = await projection.invoke(arguments, through: client)
        }
        await audit.record(.init(
            capability: projection.capability,
            face: face,
            guest: selector,
            outcome: outcome))
        return outcome
    }

    /* Why the key check is HERE and not in each row, and why it is second.

       Here, for the reason the audit event is here: two places to refuse is
       one place to forget, and a row added next year gets the strictness by
       existing rather than by remembering. Every row still validates its own
       VALUES — this gate knows the key namespace and nothing about what a
       key means.

       Second, after consent, because a machine whose owner said no has not
       been asked anything, and telling that caller their spelling was wrong
       would answer a question nobody got to ask. The cost is one local round
       trip spent before a malformed call is refused, over a Unix socket on
       this Mac and nothing on the guest wire. */

    /// **The machine's own ceiling, checked on the line that records the
    /// attempt.**
    ///
    /// It lives here and nowhere else for the reason the audit event does:
    /// two places to refuse is one place to forget, and the thing that writes
    /// down what happened is the thing that decides whether it may. One check
    /// covers every registered row, including the next one, without a per-row
    /// opt-in that a new capability's author has to remember.
    ///
    /// The answer comes from the session health of the machine THIS CALL is
    /// addressed to — the client the face hands in has already been addressed
    /// with the selector — so a host driving several Macs applies each one's
    /// own answer rather than the driven machine's to all of them. The cost is
    /// one extra local round trip per invocation, over a Unix socket on this
    /// Mac, and nothing on the guest wire.
    ///
    /// Returns nil when the call may proceed. Three of those are worth
    /// stating:
    ///
    /// - **The machine said nothing → fail OPEN.** A guest older than the
    ///   field looks exactly like an installer that omitted the feature, and
    ///   every 1400c in the field today is the former. This is a RECORDED
    ///   DECISION, not a property of the design — plan 006 makes it and the
    ///   contract's schema states it — and the moment the installer ships,
    ///   silence stops being the common case and this is the line that flips.
    ///   Nothing else in this file has to change when it does.
    /// - **No host and no guest → not a consent question.** An unreachable
    ///   host has no machine to have answered, and the projection's own
    ///   `unavailable` is the honest answer to give. Denying here would tell
    ///   a caller their machine refused when nothing was ever asked of it.
    /// - **Health that carries no guest → the same.** Nothing is connected;
    ///   there is nobody to consent.
    private func consentDenial(
        invoking projection: any HostProjection.Type,
        through client: AgentIntegrationClient
    ) async -> HostProjectionConsentDenial? {
        if case .hostProjects = projection.authorityDomain {
            return nil
        }
        guard case .available(let health) = await client.sessionHealth(),
              let guest = health.guest,
              let answer = guest.agentAccess else {
            return nil
        }
        let required = HostCapabilityTierDerivation.requiredTier(of: projection)
        guard !HostConsentCeiling.ceiling(for: answer).permits(required) else {
            return nil
        }
        let ground: HostProjectionConsentDenial.Ground
        switch answer {
        case .disabled: ground = .machineDeclines
        case .unrecognized: ground = .unrecognizedTier
        case .readOnly, .fullAccess: ground = .aboveGrantedTier
        }
        return .init(ground: ground,
                     capability: projection.capability,
                     requiredTier: required,
                     machineAnswer: answer.wire)
    }
}
