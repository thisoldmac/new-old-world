import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

final class HTTPTransportLivenessTests: XCTestCase {
    func testNOWOwnedListenerAnswersIncrementalHTTPClient() async throws {
        let port = try Self.unusedPort()
        let token = String(repeating: "l", count: 32)
        let listener = try MCPHTTPListener(
            configuration: .init(port: port, bearerToken: token),
            serverFactory: {
                (NOWMCPServer(client: SocketAgentIntegrationClient(),
                              audit: LocalMCPAuditSink()),
                 NOWMCPClientIdentity())
            })
        try await listener.start()
        defer { listener.stop() }

        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/mcp"))
        let initialize = try Self.body(id: 1, method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": ["name": "now-owned-http-test", "version": "1"],
        ])
        let initialized = try await Self.post(
            initialize, to: endpoint, token: token)
        XCTAssertEqual(initialized.response.statusCode, 200)
        let session = try XCTUnwrap(
            initialized.response.value(forHTTPHeaderField: "Mcp-Session-Id"))

        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])
        let notified = try await Self.post(
            notification, to: endpoint, token: token, session: session,
            protocolVersion: "2025-11-25")
        XCTAssertEqual(notified.response.statusCode, 202)

        let listed = try await Self.post(
            try Self.body(id: 2, method: "tools/list", params: [:]),
            to: endpoint, token: token, session: session,
            protocolVersion: "2025-11-25")
        XCTAssertEqual(listed.response.statusCode, 200)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: listed.data)
                as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(tools.count, 42)
    }

    func testListenerStopsRestartsAndRefusesASecondOwnerOfThePort()
        async throws {
        let port = try Self.unusedPort()
        let token = String(repeating: "r", count: 32)
        let first = try Self.listener(port: port, token: token)
        try await first.start()

        let collision = try Self.listener(port: port, token: token)
        do {
            try await collision.start()
            collision.stop()
            return XCTFail("a second listener unexpectedly owned the port")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Address")
                || String(describing: error).contains("48"), "\(error)")
        }

        first.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        let restarted = try Self.listener(port: port, token: token)
        try await restarted.start()
        restarted.stop()
    }

    private static func listener(port: UInt16, token: String) throws
        -> MCPHTTPListener {
        try MCPHTTPListener(
            configuration: .init(port: port, bearerToken: token),
            serverFactory: {
                (NOWMCPServer(client: HTTPConformanceNoHostClient(),
                              audit: LocalMCPAuditSink()),
                 NOWMCPClientIdentity())
            })
    }

    private static func post(
        _ body: Data, to endpoint: URL, token: String,
        session: String? = nil, protocolVersion: String? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 0.5
        request.httpBody = body
        request.setValue("Bearer \(token)",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream",
                         forHTTPHeaderField: "Accept")
        if let session {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let protocolVersion {
            request.setValue(protocolVersion,
                             forHTTPHeaderField: "Mcp-Protocol-Version")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private static func body(id: Int, method: String,
                             params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method,
        ]
        object["params"] = params
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func unusedPort() throws -> UInt16 {
        /* The NOW-owned listener is the owner that proves the bind. Using a
           second NWListener as a preflight is not useful: it creates a race
           by releasing the port before the product starts, and current
           Network.framework rejects `.any` as a required local endpoint.
           A high random port makes collisions vanishingly unlikely; a real
           collision is still a loud product-start failure, never a skip. */
        UInt16.random(in: 40_000...60_000)
    }

}
