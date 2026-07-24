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
        client: AgentIntegrationClient
    ) async throws -> NOWMCPServer {
        let server = NOWMCPServer(client: client)
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

    func testListsOnlyApprovedReadOnlyObservationTools() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

        let response = try Self.object(await server.handle(
            try Self.request(id: 2, method: "tools/list", params: [:])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, [
            "now_session_health",
            "now_list_processes",
        ])
        let processTool = try XCTUnwrap(tools.last)
        let output = try XCTUnwrap(
            processTool["outputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(
            output["properties"] as? [String: Any])
        let snapshot = try XCTUnwrap(
            properties["snapshot"] as? [String: Any])
        let snapshotProperties = try XCTUnwrap(
            snapshot["properties"] as? [String: Any])
        let processes = try XCTUnwrap(
            snapshotProperties["processes"] as? [String: Any])

        XCTAssertEqual(processes["maxItems"] as? Int, 48)
        XCTAssertNotNil(snapshotProperties["freshness"])
        XCTAssertNotNil(snapshotProperties["referenceAuthority"])
    }

    func testHostAbsentReturnsTypedUnavailableWithoutLaunchingIt()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

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

    func testProcessListReturnsTypedHostUnavailableWithoutLaunchingIt()
        async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_list_processes", "arguments": [:]])))
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
            client: StubAgentIntegrationClient())

        let response = try Self.object(
            await server.handle(Data("{nope".utf8)))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue(response["id"] is NSNull)
    }

    func testFractionalRequestIDReturnsInvalidRequest() async throws {
        let server = NOWMCPServer(
            client: StubAgentIntegrationClient())
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
            client: StubAgentIntegrationClient())

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
            handler: { operation in
                switch operation {
                case .sessionHealth:
                    return .sessionHealth(.available(health))
                case .listProcesses:
                    return .processList(.guestUnavailable)
                }
            })
        try localServer.start()
        defer { localServer.stop() }
        let server = try await initializedServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint))

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
            client: StubAgentIntegrationClient())

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

    func testProcessListReturnsBoundedObservationOnlySnapshot()
        async throws {
        let process = AgentIntegrationObservedProcess(
            reference: "now-process-opaque",
            name: "Finder",
            kind: .finder,
            code: "FNDR",
            creator: "MACS",
            sizeKB: 4096,
            front: true)
        let snapshot = AgentIntegrationProcessSnapshot(
            sessionID: UUID(),
            observedAt: Date(timeIntervalSince1970: 1_000),
            freshness: .pointInTime,
            referenceAuthority: .observationOnly,
            processes: [process])
        let server = try await initializedServer(
            client: StubAgentIntegrationClient(
                processResult: .available(snapshot)))

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "now_list_processes", "arguments": [:]])))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let returned = try XCTUnwrap(
            structured["snapshot"] as? [String: Any])
        let processes = try XCTUnwrap(
            returned["processes"] as? [[String: Any]])
        let first = try XCTUnwrap(processes.first)

        XCTAssertEqual(structured["available"] as? Bool, true)
        XCTAssertEqual(returned["freshness"] as? String, "pointInTime")
        XCTAssertEqual(returned["referenceAuthority"] as? String,
                       "observationOnly")
        XCTAssertEqual(first["reference"] as? String,
                       "now-process-opaque")
        XCTAssertNil(first["psnHigh"])
        XCTAssertNil(first["psnLow"])
        XCTAssertNil(first["path"])
    }

    func testProcessListRejectsArguments() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

        let response = try Self.object(await server.handle(try Self.request(
            id: 2,
            method: "tools/call",
            params: [
                "name": "now_list_processes",
                "arguments": ["includePaths": true],
            ])))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testConcurrentProcessListCallsAllReturn() async throws {
        let server = try await initializedServer(
            client: StubAgentIntegrationClient())

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
                                "name": "now_list_processes",
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

private struct StubAgentIntegrationClient: AgentIntegrationClient {
    var healthResult: AgentIntegrationSessionHealthResult = .hostUnavailable
    var processResult: AgentIntegrationProcessListResult = .guestUnavailable

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        healthResult
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        processResult
    }
}
