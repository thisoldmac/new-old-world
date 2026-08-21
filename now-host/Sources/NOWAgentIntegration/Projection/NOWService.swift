import Foundation

/// Client-neutral invocation boundary shared by protocol adapters.
///
/// S1 deliberately preserves the proven projection dispatch underneath it.
/// Later slices bind public `operationID`s to typed requests here; MCP keeps
/// addressing its established capability names through the same consent,
/// bounds, handler, result, and audit path.
public struct NOWService: Sendable {
    private let dispatch: HostProjectionDispatch

    public init(
        face: HostInvokingFace,
        registry: HostProjectionRegistry = .hostFaces,
        audit: any HostProjectionAuditSink
    ) {
        dispatch = HostProjectionDispatch(
            face: face, registry: registry, audit: audit)
    }

    public func invokeProjection(
        named capability: String,
        arguments: HostProjectionArguments,
        guest selector: String?,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome? {
        await dispatch.invoke(
            capability, arguments: arguments, guest: selector,
            through: client)
    }
}
