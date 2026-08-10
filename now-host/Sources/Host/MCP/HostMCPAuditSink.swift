import Foundation
import NOWAgentIntegration

/// The in-process MCP audit seam.
///
/// HTTP already lives in the app that owns the person's log, so routing its
/// audit back through the stdio socket would manufacture a second process
/// boundary. Both transports still arrive at the same typed composition and
/// visible activity stream; only the route to that owner differs.
struct HostMCPAuditSink: HostProjectionAuditSink {
    let adapter: AgentIntegrationHostAdapter
    let activity: AgentActivityModel

    func record(_ event: HostProjectionAuditEvent) async {
        await MainActor.run {
            AgentIntegrationAuditLog.record(
                event,
                drivenGuest: adapter.activeReference()?.id,
                stream: activity)
        }
    }
}
