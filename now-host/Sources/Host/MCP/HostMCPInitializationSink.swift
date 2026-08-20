import Foundation
import NOWAgentIntegration

/// HTTP initializes in the records-owning host process, so lifecycle evidence
/// lands directly rather than crossing the stdio companion's local socket.
struct HostMCPInitializationSink: MCPClientLifecycleSink {
    let records: MCPRecordsRecorder?

    func recordInitialization(_ initialization: MCPClientInitialization)
        async {
        await records?.recordInitialization(agent: MCPAgentIdentity(
            kind: .mcpHTTP,
            clientName: MCPAgentIdentity.bounded(initialization.clientName),
            clientVersion: MCPAgentIdentity.bounded(
                initialization.clientVersion),
            sessionKey: initialization.sessionKey))
    }
}
