import Foundation
import NOWAgentIntegration

protocol NOWAPIDurableRecordSink: Sendable {
    func persistAPIRecord(event: HostProjectionAuditEvent,
                          agent: MCPAgentIdentity,
                          drivenGuest: String?) async
}

extension MCPRecordsRecorder: NOWAPIDurableRecordSink {
    func persistAPIRecord(event: HostProjectionAuditEvent,
                          agent: MCPAgentIdentity,
                          drivenGuest: String?) async {
        await recordAndWait(event: event, agent: agent,
                            drivenGuest: drivenGuest)
    }
}

/// Bridges the API's content-free event into the host's existing visible and
/// durable audit fan-out. Request bodies and results are absent by type.
struct HostNOWAPIAuditSink: NOWAPIAuditSink {
    let records: (any NOWAPIDurableRecordSink)?

    func record(_ event: NOWAPIAuditEvent) async {
        let outcome: HostProjectionAuditEvent.Outcome
        let reason: String?
        switch event.disposition {
        case .completed:
            outcome = .answered
            reason = nil
        case .refused:
            outcome = .refused
            reason = "refused"
        case .denied:
            outcome = .denied
            reason = "denied"
        case .failed:
            outcome = .failed
            reason = "failed"
        }
        let projectionEvent = HostProjectionAuditEvent(
            capability: HostCapabilityID(event.operationID), face: .api,
            guest: event.target, outcome: outcome,
            reason: reason)
        await MainActor.run {
            AgentIntegrationAuditLog.record(
                projectionEvent, drivenGuest: nil, transport: .http,
                agent: MCPAgentIdentity(kind: .api))
        }
        await records?.persistAPIRecord(
            event: projectionEvent, agent: MCPAgentIdentity(kind: .api),
            drivenGuest: nil)
    }
}
