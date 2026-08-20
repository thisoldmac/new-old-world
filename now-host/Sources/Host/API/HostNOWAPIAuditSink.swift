import Foundation
import NOWAgentIntegration

/// Bridges the API's content-free event into the host's existing visible and
/// durable audit fan-out. Request bodies and results are absent by type.
struct HostNOWAPIAuditSink: NOWAPIAuditSink {
    let records: MCPRecordsRecorder?

    func record(_ event: NOWAPIAuditEvent) async {
        let outcome: HostProjectionAuditEvent.Outcome =
            event.disposition == .completed ? .answered : .refused
        let projectionEvent = HostProjectionAuditEvent(
            capability: HostCapabilityID(event.operationID), face: .api,
            guest: event.target, outcome: outcome,
            reason: event.disposition == .completed ? nil : "refused")
        await MainActor.run {
            AgentIntegrationAuditLog.record(
                projectionEvent, drivenGuest: nil, transport: .http,
                agent: MCPAgentIdentity(kind: .api), records: records)
        }
    }
}
