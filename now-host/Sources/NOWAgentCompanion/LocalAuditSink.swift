import Foundation
import NOWAgentIntegration

/// The MCP face's audit sink: one bounded local report per invocation, to
/// the running host, over the same per-uid private socket every other call
/// uses.
///
/// It goes to the host rather than to a file of its own because the log a
/// person reads is the host app's — its Logs page and its per-launch file in
/// `~/Library/Logs/now-logs`. A companion that wrote its own file would be a
/// second log nobody has open, which is the failure `docs/logging.md` was
/// written to stop: information that existed and had nowhere to live.
///
/// **A failure to report is silent, and that is the honest behaviour.** The
/// reasons it can fail are that the host is absent, is a version that does
/// not understand the operation, or has stopped answering — and in all three
/// there is no log to write the line into. Refusing the tool call instead
/// would mean an optional feature failing calls it had already served, and
/// reporting the failure to the MCP caller would tell an agent about the
/// person's logging rather than about their machine.
struct LocalAuditSink: HostProjectionAuditSink {
    private let client: AgentIntegrationLocalClient?

    /// Deliberately NOT the addressed client the projections use: an audit
    /// report asks nothing of any guest, so it carries no selector. The
    /// machine the invocation concerned travels inside the event.
    init(endpoint: AgentIntegrationEndpoint? = nil) {
        client = try? AgentIntegrationLocalClient(endpoint: endpoint)
    }

    func record(_ event: HostProjectionAuditEvent) async {
        try? await client?.recordAudit(event)
    }
}
