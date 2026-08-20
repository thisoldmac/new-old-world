import Foundation
import NOWAgentIntegration

/// The client-launched stdio process reports only a successful handshake's
/// bounded identity to the running host. It is lifecycle evidence, not a
/// fabricated tool audit event.
struct LocalMCPInitializationSink: MCPClientLifecycleSink {
    private let client: AgentIntegrationLocalClient?

    init(endpoint: AgentIntegrationEndpoint? = nil) {
        client = try? AgentIntegrationLocalClient(endpoint: endpoint)
    }

    func recordInitialization(_ initialization: MCPClientInitialization)
        async {
        try? await client?.recordMCPInitialization(
            clientName: initialization.clientName,
            clientVersion: initialization.clientVersion,
            sessionKey: initialization.sessionKey)
    }
}
