import Foundation
import NOWAgentIntegration

/// HTTP initializes in the records-owning host process, so lifecycle evidence
/// lands directly in the owning process.
struct HostMCPInitializationSink: MCPClientLifecycleSink {
    let records: MCPRecordsRecorder?

    func recordInitialization(_ initialization: MCPClientInitialization) {
        records?.recordInitialization(agent: MCPAgentIdentity(
            kind: .mcpHTTP,
            clientName: initialization.clientName,
            clientVersion: initialization.clientVersion,
            sessionKey: initialization.sessionKey))
    }
}
