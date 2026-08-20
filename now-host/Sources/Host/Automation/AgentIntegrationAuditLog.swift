import Foundation
import NOWAgentIntegration

/// Where a reported agent invocation lands: one line in this side's log,
/// under the `agent` area, at the level the outcome earns.
///
/// It is a type rather than two lines inside the local server's handler so
/// that the format has a test. The line is composed here from typed fields
/// the codec has already validated — a reporting process supplies facts, not
/// text, because the log belongs to the person at the machine.
@MainActor
enum AgentIntegrationAuditLog {
    static let area = "agent"

    /// One reported invocation, written to both places a person can read
    /// it: the log, which is the record, and the Agent page, which is the
    /// glance. **One call and one composition**, rather than the reporting
    /// site remembering to do both — the visible half of rule 3 was missing
    /// for twelve capabilities precisely because it was a second thing to
    /// remember, and a fan-out that lives at the call site is that same
    /// mistake with fewer callers.
    ///
    /// `stream` is optional because the log is not: a build with no window
    /// open, and every test that only cares about the line, still writes it.
    /// `transport` is the route the report travelled, known only at the two
    /// recording seams (the socket bridge is stdio; `HostMCPAuditSink` is
    /// HTTP). It tags the log line so a transport card can tail its own
    /// session; the composed text is unchanged.
    /// `records` is the third fan-out — the durable store — and `agent` is
    /// who did it, carried beside the event because the event itself stays
    /// identity-free. With a recorder and no stated identity, the face
    /// still names an honest kind.
    static func record(_ event: HostProjectionAuditEvent,
                       drivenGuest: String?,
                       log: HostLog = .shared,
                       stream: AgentActivityModel? = nil,
                       transport: MCPTransportKind? = nil,
                       agent: MCPAgentIdentity? = nil,
                       records: MCPRecordsRecorder? = nil) {
        log.write(level(event), area,
                  event.logMessage(drivenGuest: drivenGuest),
                  transport: transport)
        stream?.record(event, drivenGuest: drivenGuest)
        records?.record(event: event,
                        agent: agent ?? fallbackIdentity(event, transport),
                        drivenGuest: drivenGuest)
    }

    private static func fallbackIdentity(
        _ event: HostProjectionAuditEvent,
        _ transport: MCPTransportKind?) -> MCPAgentIdentity {
        switch event.face {
        case .chat: return MCPAgentIdentity(kind: .chat)
        case .appIntent: return MCPAgentIdentity(kind: .appIntent)
        case .mcp:
            return MCPAgentIdentity(
                kind: transport == .http ? .mcpHTTP : .mcpStdio)
        }
    }

    /// A refusal is `warn`: it went wrong and continued, which is
    /// docs/logging.md's own definition. An answered call is `info` — it
    /// happened. Neither is `error`, because only `error` pays to flush and
    /// an agent call is not the last thing before a crash.
    private static func level(_ event: HostProjectionAuditEvent)
        -> HostLog.LogLevel {
        switch event.level {
        case .warn: return .warn
        case .info: return .info
        }
    }
}
