import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// Exact semantic parity through both NOW-owned transports.
///
/// The total recipe gate below calls every advertised tool through each
/// transport. This companion gate compares the replies themselves for the
/// deterministic protocol-owned surface and one host-unavailable tool call,
/// so sharing `NOWMCPServer` is an implementation fact rather than the only
/// evidence offered for parity.
final class MCPTransportParityTests: XCTestCase {
    func testHTTPAndStdioHaveExactSurfaceAndResultParity() throws {
        let executable = try Self.hostExecutable()
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = "/tmp"
        environment["NOW_AGENT_SOCKET_SUFFIX"] = Self.freshSocketSuffix()
        let stdio = try MCPClient(executable: executable,
                                  environment: environment)
        let http = try MCPHTTPClient(environment: environment)
        defer {
            stdio.shutDown()
            http.shutDown()
        }

        try assertEqual(try stdio.handshake(), try http.handshake(),
                        operation: "initialize")

        let calls: [(String, [String: Any]?)] = [
            ("ping", nil),
            ("resources/list", [:]),
            ("resources/read", [
                "uri": NOWMCPServer.firstContactResourceURI,
            ]),
            ("prompts/list", [:]),
            ("prompts/get", [
                "name": NOWMCPServer.firstContactPromptName,
            ]),
            /* This one object contains the full tool catalog: names,
               descriptions, input schemas, required fields, and all enum
               values. Exact equality means no transport-specific catalog
               renderer can quietly drift. */
            ("tools/list", [:]),
            /* A real tool result through projection dispatch. With the
               deliberately unbound endpoint it is deterministic and proves
               the MCP result envelope as well as protocol-owned replies. */
            ("tools/call", [
                "name": "now_list_machines", "arguments": [:],
            ]),
            ("unknown/method", [:]),
            ("tools/list", ["cursor": "not-a-cursor"]),
            ("resources/read", ["uri": "now://unknown"]),
            ("prompts/get", ["name": "unknown"]),
            ("tools/call", ["name": "now_not_a_tool", "arguments": [:]]),
        ]

        for (method, params) in calls {
            try assertEqual(
                try stdio.request(method, params: params),
                try http.request(method, params: params),
                operation: method)
        }
    }

    func testBothTransportsRequireInitializedNotificationBeforeCatalog()
        throws {
        let executable = try Self.hostExecutable()
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = "/tmp"
        environment["NOW_AGENT_SOCKET_SUFFIX"] = Self.freshSocketSuffix()
        let stdio = try MCPClient(executable: executable,
                                  environment: environment)
        let http = try MCPHTTPClient(environment: environment)
        defer {
            stdio.shutDown()
            http.shutDown()
        }

        let params: [String: Any] = [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "now-conformance", "version": "1"],
        ]
        try assertEqual(
            try stdio.request("initialize", params: params),
            try http.request("initialize", params: params),
            operation: "initialize before notification")
        try assertEqual(
            try stdio.request("tools/list", params: [:]),
            try http.request("tools/list", params: [:]),
            operation: "tools/list before initialized notification")

        stdio.notify("notifications/initialized")
        http.notify("notifications/initialized")
        let afterStdio = try stdio.request("tools/list", params: [:])
        let afterHTTP = try http.request("tools/list", params: [:])
        try assertEqual(afterStdio, afterHTTP,
                        operation: "tools/list after notification")
        XCTAssertNotNil(afterStdio["result"])
    }

    private func assertEqual(_ lhs: [String: Any], _ rhs: [String: Any],
                             operation: String) throws {
        XCTAssertEqual(lhs as NSDictionary, rhs as NSDictionary, operation)
    }

    private static func hostExecutable() throws -> URL {
        let candidate = Bundle(for: MCPTransportParityTests.self)
            .bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Host")
        guard FileManager.default.isExecutableFile(atPath: candidate.path)
        else {
            XCTFail("No New Old World Host executable at \(candidate.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return candidate
    }

    private static func freshSocketSuffix() -> String {
        "parity-" + UUID().uuidString.prefix(8).lowercased()
    }

}
