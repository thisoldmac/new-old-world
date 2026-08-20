import Foundation
import XCTest
@testable import Host
import NOWAgentIntegration

final class MCPHTTPWorkspaceAuthorityTests: XCTestCase {
    private static let version = "2025-11-25"

    func testThreeConcurrentSessionsKeepTwoRootsIsolatedAndOneUngrant()
        async throws {
        let roots = try WorkspaceRoots()
        defer { roots.remove() }
        let grants = MCPHTTPWorkspaceGrantAuthority(
            maximumOutstanding: 4, lifetime: 30)
        let service = service(grants)

        let tokenA = try XCTUnwrap(grants.issue(workspaceRoot: roots.a))
        let sessionA = try await initialize(service, grant: tokenA)
        let tokenB = try XCTUnwrap(grants.issue(workspaceRoot: roots.b))
        let sessionB = try await initialize(service, grant: tokenB)
        let ungranted = try await initialize(service, grant: nil)

        try await assertAccepted(service, session: sessionA, path: "a.bin")
        try await assertRefused(
            service, session: sessionA,
            path: roots.b.appendingPathComponent("b.bin").path)
        try await assertAccepted(service, session: sessionB, path: "b.bin")
        try await assertRefused(
            service, session: sessionB,
            path: roots.a.appendingPathComponent("a.bin").path)
        try await assertUngrant(
            service, session: ungranted,
            path: roots.a.appendingPathComponent("a.bin").path)
    }

    func testIssuingALaterGrantCannotRetargetAnExistingSession() async throws {
        let roots = try WorkspaceRoots()
        defer { roots.remove() }
        let grants = MCPHTTPWorkspaceGrantAuthority(
            maximumOutstanding: 4, lifetime: 30)
        let service = service(grants)
        let token = try XCTUnwrap(grants.issue(workspaceRoot: roots.a))
        let session = try await initialize(service, grant: token)

        _ = try XCTUnwrap(grants.issue(workspaceRoot: roots.b))

        try await assertAccepted(service, session: session, path: "a.bin")
        try await assertRefused(
            service, session: session,
            path: roots.b.appendingPathComponent("b.bin").path)
    }

    func testUnknownExpiredAndReusedGrantsAreRefused() async throws {
        let roots = try WorkspaceRoots()
        defer { roots.remove() }
        let grants = MCPHTTPWorkspaceGrantAuthority(
            maximumOutstanding: 2, lifetime: 1)
        let service = service(grants)

        let unknown = await initializeResponse(
            service, grant: String(repeating: "f", count: 64))
        XCTAssertEqual(unknown.status, 403)

        let reusable = try XCTUnwrap(grants.issue(
            workspaceRoot: roots.a, now: Date(timeIntervalSince1970: 10)))
        let accepted = await initializeResponse(
            service, grant: reusable,
            now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(accepted.status, 200)
        let reused = await initializeResponse(
            service, grant: reusable,
            now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(reused.status, 403)

        let expired = try XCTUnwrap(grants.issue(
            workspaceRoot: roots.b, now: Date(timeIntervalSince1970: 20)))
        let refused = await initializeResponse(
            service, grant: expired,
            now: Date(timeIntervalSince1970: 22))
        XCTAssertEqual(refused.status, 403)
    }

    func testOutstandingGrantSetIsBounded() throws {
        let roots = try WorkspaceRoots()
        defer { roots.remove() }
        let grants = MCPHTTPWorkspaceGrantAuthority(
            maximumOutstanding: 1, lifetime: 30)
        let now = Date(timeIntervalSince1970: 100)

        let first = try XCTUnwrap(
            grants.issue(workspaceRoot: roots.a, now: now))
        XCTAssertNil(grants.issue(workspaceRoot: roots.b, now: now))
        XCTAssertNotNil(grants.redeem(first, now: now))
        XCTAssertNotNil(grants.issue(workspaceRoot: roots.b, now: now))
    }

    private func service(_ grants: MCPHTTPWorkspaceGrantAuthority)
        -> MCPHTTPService {
        MCPHTTPService(
            configuration: .init(port: 5254, authMode: .unauthenticated,
                                 bearerToken: nil),
            sessionServerFactory: { grant in
                (NOWMCPServer(
                    client: SocketAgentIntegrationClient(),
                    audit: LocalMCPAuditSink(), workspaceGrant: grant),
                 NOWMCPClientIdentity())
            },
            workspaceGrants: grants)
    }

    private func initialize(_ service: MCPHTTPService, grant: String?)
        async throws -> String {
        let response = await initializeResponse(service, grant: grant)
        XCTAssertEqual(response.status, 200)
        return try XCTUnwrap(response.headers["Mcp-Session-Id"])
    }

    private func initializeResponse(
        _ service: MCPHTTPService, grant: String?, now: Date = Date()
    ) async -> MCPHTTPResponse {
        await service.respond(to: request(
            Self.body(id: 1, method: "initialize", params: [
                "protocolVersion": Self.version,
                "capabilities": [:],
                "clientInfo": ["name": "workspace-test", "version": "1"],
            ]), grant: grant), now: now)
    }

    private func assertAccepted(_ service: MCPHTTPService, session: String,
                                path: String) async throws {
        let object = try await call(service, session: session, path: path)
        XCTAssertNotNil(object["result"], "expected an in-root call: \(object)")
    }

    private func assertRefused(_ service: MCPHTTPService, session: String,
                               path: String) async throws {
        let object = try await call(service, session: session, path: path)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertFalse((error["message"] as? String ?? "").contains(path))
    }

    private func assertUngrant(_ service: MCPHTTPService, session: String,
                               path: String) async throws {
        let object = try await call(service, session: session, path: path)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(
            result["structuredContent"] as? [String: Any])
        let unavailable = try XCTUnwrap(
            structured["unavailable"] as? [String: Any])
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-files-workspace-unavailable")
    }

    private func call(_ service: MCPHTTPService, session: String, path: String)
        async throws -> [String: Any] {
        _ = await service.respond(to: request(
            Self.notification("notifications/initialized"), session: session))
        let response = await service.respond(to: request(
            Self.body(id: 2, method: "tools/call", params: [
                "name": "now_guest_files_upload_file",
                "arguments": [
                    "localPath": path,
                    "destinationPath": "Lab:file.bin",
                    "container": "data",
                ],
            ]), session: session))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body)
                as? [String: Any])
    }

    private func request(_ body: Data, session: String? = nil,
                         grant: String? = nil) -> MCPHTTPRequest {
        var headers = [
            "host": "127.0.0.1:5254",
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        ]
        headers["mcp-session-id"] = session
        headers["mcp-protocol-version"] = session == nil ? nil : Self.version
        headers[MCPHTTPWorkspaceGrantAuthority.headerName] = grant
        return .init(method: "POST", target: "/mcp", headers: headers, body: body)
    }

    private static func body(id: Int, method: String,
                             params: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
    }

    private static func notification(_ method: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": method,
        ])
    }
}

private struct WorkspaceRoots {
    let parent: URL
    let a: URL
    let b: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "now-http-workspace-\(UUID().uuidString)", isDirectory: true)
        a = parent.appendingPathComponent("a", isDirectory: true)
        b = parent.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(
            at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: b, withIntermediateDirectories: true)
        try Data("root-a".utf8).write(to: a.appendingPathComponent("a.bin"))
        try Data("root-b".utf8).write(to: b.appendingPathComponent("b.bin"))
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
}
