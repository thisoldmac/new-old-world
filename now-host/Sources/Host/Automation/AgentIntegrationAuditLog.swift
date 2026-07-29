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

    static func record(_ event: HostProjectionAuditEvent,
                       drivenGuest: String?,
                       log: HostLog = .shared) {
        log.write(level(event), area,
                  event.logMessage(drivenGuest: drivenGuest))
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
