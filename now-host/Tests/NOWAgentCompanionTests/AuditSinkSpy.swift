import Foundation
import NOWAgentIntegration

/// What the MCP face reported, in order.
///
/// An actor rather than a var: the face records from whatever task served
/// the call, and a test that read a plain array across that boundary would
/// be checking the audit gate with a data race.
actor AuditSinkSpy: HostProjectionAuditSink {
    private(set) var events: [HostProjectionAuditEvent] = []

    func record(_ event: HostProjectionAuditEvent) async {
        events.append(event)
    }

    func recorded() async -> [HostProjectionAuditEvent] { events }
}
