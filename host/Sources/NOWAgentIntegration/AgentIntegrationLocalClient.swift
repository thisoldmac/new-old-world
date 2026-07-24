import Darwin
import Foundation

public struct AgentIntegrationLocalClient: Sendable {
    public let endpoint: AgentIntegrationEndpoint
    private let expectedUID: uid_t

    public init(endpoint: AgentIntegrationEndpoint? = nil,
                expectedUID: uid_t = geteuid()) throws {
        self.endpoint = try endpoint ?? .currentUser(uid: expectedUID)
        self.expectedUID = expectedUID
    }

    public func sessionHealth() async throws
        -> AgentIntegrationSessionHealthResult {
        let response = try await send(operation: .sessionHealth)
        guard let result = response.result else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no session-health result")
        }
        return result
    }

    public func listProcesses() async throws
        -> AgentIntegrationProcessListResult {
        let response = try await send(operation: .listProcesses)
        guard let result = response.processListResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no process-list result")
        }
        return result
    }

    func sendRaw(_ request: Data) async throws -> Data {
        try await Task.detached { try sendRaw(request) }.value
    }

    private func send(operation: AgentIntegrationLocalRequest.Operation)
        async throws -> AgentIntegrationLocalResponse {
        try await Task.detached {
            let request = AgentIntegrationLocalRequest(operation: operation)
            let response = try sendRaw(
                AgentIntegrationLocalCodec.encode(request))
            let decoded = try AgentIntegrationLocalCodec.decodeResponse(
                response)
            guard decoded.requestID == request.requestID else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Local response request ID did not match")
            }
            if let error = decoded.error {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "\(error.code): \(error.message)")
            }
            return decoded
        }.value
    }

    private func sendRaw(_ request: Data) throws -> Data {
        try AgentIntegrationUnixSocket.validateDirectory(
            endpoint.directoryURL, uid: expectedUID)
        try AgentIntegrationUnixSocket.validateSocket(
            endpoint.socketURL, uid: expectedUID)
        let descriptor = try AgentIntegrationUnixSocket.makeSocket()
        defer { close(descriptor) }
        AgentIntegrationUnixSocket.setTimeouts(descriptor)
        try AgentIntegrationUnixSocket.withAddress(
            path: endpoint.socketURL.path) { address, length in
            if connect(descriptor, address, length) != 0 {
                if errno == ENOENT || errno == ECONNREFUSED {
                    throw AgentIntegrationLocalTransportError
                        .hostUnavailable
                }
                throw AgentIntegrationUnixSocket.ioError("connect")
            }
        }
        try AgentIntegrationUnixSocket.writeLine(request, to: descriptor)
        _ = shutdown(descriptor, SHUT_WR)
        return try AgentIntegrationUnixSocket.readLine(from: descriptor)
    }
}
