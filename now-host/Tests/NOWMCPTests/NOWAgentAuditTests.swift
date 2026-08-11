import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// The MCP face's own coverage of rule 3: a tool call made over this
/// surface reaches the person's log, by the same private socket every other
/// call uses.
///
/// `HostProjectionAuditTests` proves the dispatch emits; this proves the
/// emission actually crosses NOW's stdio bridge process, which is the half a spy
/// in the same process cannot see. It is deliberately driven through
/// `handle` — the real MCP entry point — rather than through the dispatch,
/// because "the face is wired up" is the claim under test.
final class NOWAgentAuditTests: XCTestCase {

    private func temporaryEndpoint() -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    /// Everything the fake host was told, in order.
    private actor Reported {
        private var events: [HostProjectionAuditEvent] = []
        func add(_ event: HostProjectionAuditEvent) { events.append(event) }
        func all() -> [HostProjectionAuditEvent] { events }
    }

    func testAToolCallReportsItselfToTheHost() async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let reported = Reported()
        let localServer = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                switch request.operation {
                case .audit:
                    if let event = request.auditEvent {
                        await reported.add(event)
                    }
                    return .recorded
                default:
                    return .processList(.guestUnavailable)
                }
            })
        try localServer.start()
        defer { localServer.stop() }

        let server = NOWMCPServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint),
            audit: LocalMCPAuditSink(endpoint: endpoint))
        _ = await server.handle(try request(id: 1, method: "initialize",
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

        _ = await server.handle(try request(
            id: 2, method: "tools/call",
            params: ["name": "now_list_processes", "arguments": [:]]))
        /* And one the projection refuses, which the host would otherwise
           never hear about: an argument refusal is decided in this process
           and sends no request of its own. */
        _ = await server.handle(try request(
            id: 3, method: "tools/call",
            params: [
                "name": "now_list_processes",
                "arguments": ["unexpected": 1],
            ]))

        let events = await reported.all()
        XCTAssertEqual(events.count, 2, "Reported: \(events)")
        XCTAssertEqual(events.first?.capability, "now_list_processes")
        XCTAssertEqual(events.first?.face, .mcp)
        XCTAssertEqual(events.first?.outcome, .answered)
        XCTAssertEqual(events.last?.outcome, .refused)
        XCTAssertEqual(events.last?.reason,
                       "now_list_processes accepts no arguments")
    }

    /// The selector a caller passed is the machine the line names. It is
    /// lifted off the arguments before the projection runs, so this is also
    /// the only place it could be lost.
    func testTheReportedEventNamesTheAddressedMachine() async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let reported = Reported()
        let localServer = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                switch request.operation {
                case .audit:
                    if let event = request.auditEvent {
                        await reported.add(event)
                    }
                    return .recorded
                default:
                    return .processList(.guestUnavailable)
                }
            })
        try localServer.start()
        defer { localServer.stop() }

        let server = NOWMCPServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint),
            audit: LocalMCPAuditSink(endpoint: endpoint))
        _ = await server.handle(try request(id: 1, method: "initialize",
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
        _ = await server.handle(try request(
            id: 2, method: "tools/call",
            params: [
                "name": "now_list_processes",
                "arguments": ["guest": "pb1400c"],
            ]))

        let events = await reported.all()
        XCTAssertEqual(events.count, 1, "Reported: \(events)")
        XCTAssertEqual(events.first?.guest, "pb1400c")
    }

    /// A host that is gone cannot be told, and the tool call still works.
    /// The alternative — failing a call this face has already served, or
    /// telling an agent about the person's logging — is worse than a missing
    /// line for a machine that has no log open.
    func testAnAbsentHostDoesNotFailTheCall() async throws {
        let (endpoint, root) = temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = NOWMCPServer(
            client: SocketAgentIntegrationClient(endpoint: endpoint),
            audit: LocalMCPAuditSink(endpoint: endpoint))
        _ = await server.handle(try request(id: 1, method: "initialize",
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

        let answered = await server.handle(try request(
            id: 2, method: "tools/call",
            params: ["name": "now_list_machines", "arguments": [:]]))
        let data = try XCTUnwrap(answered)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["available"] as? Bool, false)
    }

    private func request(id: Int, method: String,
                         params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        object["params"] = params
        return try JSONSerialization.data(withJSONObject: object)
    }
}
