import Foundation
import XCTest
@testable import NOWAgentCompanion

final class HTTPTransportLivenessTests: XCTestCase {
    func testSpawnedCompanionAnswersIncrementalHTTPClient() async throws {
        let port = try Self.unusedPort()
        let token = String(repeating: "l", count: 32)
        let process = Process()
        process.executableURL = try Self.companionExecutable()
        process.arguments = ["--http", "--port", "\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment[CompanionInvocation.tokenEnvironmentKey] = token
        environment["NOW_AGENT_SOCKET_SUFFIX"] = "http-liveness"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/mcp"))
        let initialize = try Self.body(id: 1, method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": ["name": "spawned-http-test", "version": "1"],
        ])
        let initialized = try await Self.eventuallyPost(
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

    private static func eventuallyPost(
        _ body: Data, to endpoint: URL, token: String
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var last: Error?
        for _ in 0..<25 {
            do { return try await post(body, to: endpoint, token: token) }
            catch {
                last = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw last ?? URLError(.cannotConnectToHost)
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
        /* The spawned product is the owner that proves the bind. Using a
           second NWListener as a preflight is not useful: it creates a race
           by releasing the port before the product starts, and current
           Network.framework rejects `.any` as a required local endpoint.
           A high random port makes collisions vanishingly unlikely; a real
           collision is still a loud product-start failure, never a skip. */
        UInt16.random(in: 40_000...60_000)
    }

    private static func companionExecutable() throws -> URL {
        let candidate = Bundle(for: HTTPTransportLivenessTests.self)
            .bundleURL.deletingLastPathComponent()
            .appendingPathComponent("NOWAgentCompanion")
        guard FileManager.default.isExecutableFile(atPath: candidate.path)
        else {
            XCTFail("No NOWAgentCompanion executable at \(candidate.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return candidate
    }
}
