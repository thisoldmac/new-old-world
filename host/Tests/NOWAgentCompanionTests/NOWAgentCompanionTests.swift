import XCTest
@testable import NOWAgentCompanion
@testable import NOWAgentIntegration

final class NOWAgentCompanionTests: XCTestCase {
    private func temporaryEndpoint() -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nct-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    private static func request(id: Int, method: String,
                                params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        object["params"] = params
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func object(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func initializedServer(
        client: AgentIntegrationHealthClient
    ) async throws -> NOWMCPServer {
        let server = NOWMCPServer(healthClient: client)
        _ = await server.handle(try Self.request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "tests", "version": "1"],
            ]))
        _ = await server.handle(try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            ]))
        return server
    }

    func testListsOnlySessionHealth() async throws {
        let server = try await initializedServer(
            client: StubHealthClient(result: .hostUnavailable))

        let response = try Self.object(await server.handle(
            try Self.request(id: 2, method: "tools/list", params: [:])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String,
                       "now_session_health")
    }

    func testHostAbsentReturnsTypedUnavailableWithoutLaunchingIt()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketHealthClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_session_health", "arguments": [:]])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])

        XCTAssertEqual(structured["available"] as? Bool, false)
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-host-unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMalformedJSONReturnsParseError() async throws {
        let server = NOWMCPServer(
            healthClient: StubHealthClient(result: .hostUnavailable))

        let response = try Self.object(
            await server.handle(Data("{nope".utf8)))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue(response["id"] is NSNull)
    }

    func testFractionalRequestIDReturnsInvalidRequest() async throws {
        let server = NOWMCPServer(
            healthClient: StubHealthClient(result: .hostUnavailable))
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1.5,
            "method": "ping",
        ])

        let response = try Self.object(await server.handle(data))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32600)
        XCTAssertTrue(response["id"] is NSNull)
    }

    func testSessionHealthRejectsArguments() async throws {
        let server = try await initializedServer(
            client: StubHealthClient(result: .hostUnavailable))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_session_health",
                "arguments": ["path": "/tmp"],
            ])))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    @MainActor
    func testToolCallTraversesThePrivateSocket() async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let health = AgentIntegrationSessionHealth(
            state: .notListening,
            observedAt: observedAt,
            listeningPort: nil,
            sessionID: nil,
            guest: nil,
            failure: nil)
        let localServer = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { .available(health) })
        try localServer.start()
        defer { localServer.stop() }
        let server = try await initializedServer(
            client: SocketHealthClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_session_health", "arguments": [:]])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let returned = try XCTUnwrap(
            structured["health"] as? [String: Any])

        XCTAssertEqual(structured["available"] as? Bool, true)
        XCTAssertEqual(returned["state"] as? String, "notListening")
    }

    func testConcurrentSessionHealthCallsAllReturn() async throws {
        let server = try await initializedServer(
            client: StubHealthClient(result: .hostUnavailable))

        let responses = try await withThrowingTaskGroup(
            of: [String: Any].self
        ) { group in
            for id in 2..<10 {
                group.addTask {
                    try Self.object(await server.handle(
                        try Self.request(
                            id: id,
                            method: "tools/call",
                            params: [
                                "name": "now_session_health",
                                "arguments": [:],
                            ])))
                }
            }
            var values: [[String: Any]] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(responses.count, 8)
        XCTAssertTrue(responses.allSatisfy { $0["result"] != nil })
    }

    func testStdioFramerBoundsAnOversizedRequest() {
        var framer = BoundedMCPLineFramer()
        let data = Data(repeating: 0x41,
                        count: NOWMCPServer.maximumMessageBytes + 1)
            + Data([0x0A])

        let events = framer.append(data)

        XCTAssertEqual(events.count, 1)
        guard case .oversized = events[0] else {
            return XCTFail("expected one bounded oversized event")
        }
    }
}

private struct StubHealthClient: AgentIntegrationHealthClient {
    let result: AgentIntegrationSessionHealthResult

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        result
    }
}
