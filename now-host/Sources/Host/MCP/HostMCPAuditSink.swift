import Foundation
import NOWAgentIntegration

/// The in-process MCP audit seam.
///
/// HTTP already lives in the app that owns the person's log, so routing its
/// audit back through the local automation socket would manufacture a second process
/// boundary. Both transports still arrive at the same typed composition and
/// visible activity stream; only the route to that owner differs.
struct HostMCPAuditSink: HostProjectionAuditSink {
    let adapter: AgentIntegrationHostAdapter
    let activity: AgentActivityModel
    /// Per-session: the server fills name/version at initialize, the HTTP
    /// service adds the session id it minted. Nil on assemblies that never
    /// learned who called.
    var identity: NOWMCPClientIdentity? = nil
    var records: MCPRecordsRecorder? = nil

    func record(_ event: HostProjectionAuditEvent) async {
        let agent = identity.map {
            MCPAgentIdentity(
                kind: .mcpHTTP,
                clientName: MCPAgentIdentity.bounded($0.clientName),
                clientVersion: MCPAgentIdentity.bounded($0.clientVersion),
                sessionKey: $0.sessionKey)
        }
        await MainActor.run {
            AgentIntegrationAuditLog.record(
                event,
                drivenGuest: adapter.activeReference()?.id,
                transport: .http,
                agent: agent,
                records: records)
        }
    }
}
