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
    public let face: HostProjectionFace
    private let registry: HostProjectionRegistry
    private let audit: any HostProjectionAuditSink

    public init(face: HostProjectionFace,
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
        let outcome = await projection.invoke(arguments, through: client)
        await audit.record(.init(
            capability: projection.capability,
            face: face,
            guest: selector,
            outcome: outcome))
        return outcome
    }
}
