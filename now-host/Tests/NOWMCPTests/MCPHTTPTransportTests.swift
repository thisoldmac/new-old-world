import XCTest
@testable import Host
@testable import NOWAgentIntegration

final class MCPHTTPTransportTests: XCTestCase {
    private static let token = String(repeating: "t", count: 32)
    private static let port: UInt16 = 5254

    func testNOWOwnsTransportDefaultsAndPersistsEachControl() throws {
        let name = "mcp-transport-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MCPTransportPreferences(defaults: defaults)

        XCTAssertFalse(preferences.stdioStartsAutomatically)
        XCTAssertNil(defaults.object(
            forKey: MCPTransportPreferences.Keys.stdioEnabled),
            "reading the clean-install default must not manufacture a preference")
        XCTAssertFalse(preferences.httpStartsAutomatically)
        XCTAssertEqual(preferences.httpPort, 5254)
        XCTAssertEqual(preferences.httpAuthMode, .bearer)
        preferences.stdioStartsAutomatically = true
        preferences.httpStartsAutomatically = true
        preferences.httpPort = 6254
        preferences.httpAuthMode = .oauth

        let restored = MCPTransportPreferences(defaults: defaults)
        XCTAssertTrue(restored.stdioStartsAutomatically,
                      "an explicit pre-upgrade opt-in must survive")
        XCTAssertTrue(restored.httpStartsAutomatically)
        XCTAssertEqual(restored.httpPort, 6254)
        XCTAssertEqual(restored.httpAuthMode, .oauth)

        restored.stdioStartsAutomatically = false
        XCTAssertFalse(MCPTransportPreferences(defaults: defaults)
            .stdioStartsAutomatically,
            "an explicit opt-out must survive")

        /* A value written by a build this one has never heard of falls back
           to bearer, the mode every install had before modes existed. */
        defaults.set("quantum", forKey: MCPTransportPreferences.Keys.httpAuthMode)
        XCTAssertEqual(MCPTransportPreferences(defaults: defaults)
            .httpAuthMode, .bearer)
    }

    @MainActor
    func testEditableSettingsPersistWithoutConflatingTransportState() throws {
        let name = "mcp-settings-model-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MCPTransportSettingsModel(defaults: defaults)

        settings.stdioStartsAutomatically = false
        settings.httpStartsAutomatically = true
        settings.httpPort = 6354
        settings.httpPort = 0

        let restored = MCPTransportPreferences(defaults: defaults)
        XCTAssertFalse(restored.stdioStartsAutomatically)
        XCTAssertTrue(restored.httpStartsAutomatically)
        XCTAssertEqual(restored.httpPort, 6354)
        XCTAssertEqual(settings.httpPort, 6354)
    }

    func testNOWCreatesOnePrivatePersistentHTTPToken() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-mcp-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("token")
        let store = try MCPHTTPTokenStore(url: url)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.utf8.count, 64)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,
                       0o600)
    }

    func testParserAcceptsIncrementalBodyAndRejectsAmbiguousFraming() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let head = Data(("POST /mcp HTTP/1.1\r\n"
            + "Host: 127.0.0.1:5254\r\n"
            + "Content-Length: \(body.count)\r\n\r\n").utf8)
        var parser = BoundedMCPHTTPRequestParser()
        XCTAssertNil(try parser.append(head + body.prefix(5)))
        let request = try XCTUnwrap(parser.append(body.dropFirst(5)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/mcp")
        XCTAssertEqual(request.headers["host"], "127.0.0.1:5254")
        XCTAssertEqual(request.body, body)

        var duplicate = BoundedMCPHTTPRequestParser()
        XCTAssertThrowsError(try duplicate.append(Data((
            "GET /mcp HTTP/1.1\r\nHost: localhost:5254\r\n"
                + "Host: 127.0.0.1:5254\r\n\r\n").utf8))) {
            XCTAssertEqual($0 as? MCPHTTPRequestParseError, .malformed)
        }

        var chunked = BoundedMCPHTTPRequestParser()
        XCTAssertThrowsError(try chunked.append(Data((
            "POST /mcp HTTP/1.1\r\nHost: localhost:5254\r\n"
                + "Transfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n")
            .utf8))) {
            XCTAssertEqual($0 as? MCPHTTPRequestParseError,
                           .unsupportedTransferEncoding)
        }
    }

    func testParserEnforcesHeaderAndProtocolBodyBounds() throws {
        var header = BoundedMCPHTTPRequestParser(maximumHeaderBytes: 32)
        XCTAssertThrowsError(try header.append(
            Data(String(repeating: "H", count: 33).utf8))) {
            XCTAssertEqual($0 as? MCPHTTPRequestParseError,
                           .headersTooLarge)
        }

        var body = BoundedMCPHTTPRequestParser()
        let head = "POST /mcp HTTP/1.1\r\nHost: localhost:\(Self.port)\r\n"
            + "Content-Length: \(NOWMCPServer.maximumMessageBytes + 1)\r\n\r\n"
        XCTAssertThrowsError(try body.append(Data(head.utf8))) {
            XCTAssertEqual($0 as? MCPHTTPRequestParseError, .bodyTooLarge)
        }
    }

    func testHTTPRejectsWrongPathVerbContentAndAcceptHeaders() async throws {
        let service = service()
        let initialize = try Self.initializeBody(id: 1)
        let base = Self.post(initialize)

        let wrongPath = await service.respond(to: .init(
            method: "POST", target: "/not-mcp", headers: base.headers,
            body: initialize))
        XCTAssertEqual(wrongPath.status, 404)
        let get = await service.respond(to: .init(
            method: "GET", target: "/mcp", headers: base.headers,
            body: Data()))
        XCTAssertEqual(get.status, 405)
        var wrongContent = base.headers
        wrongContent["content-type"] = "text/plain"
        let unsupported = await service.respond(to: .init(
            method: "POST", target: "/mcp", headers: wrongContent,
            body: initialize))
        XCTAssertEqual(unsupported.status, 415)
        var wrongAccept = base.headers
        wrongAccept["accept"] = "application/json"
        let unacceptable = await service.respond(to: .init(
            method: "POST", target: "/mcp", headers: wrongAccept,
            body: initialize))
        XCTAssertEqual(unacceptable.status, 406)
    }

    func testHTTPRequiresLoopbackHostBearerAndSafeOrigin() async throws {
        let service = service()
        let initialize = try Self.initializeBody(id: 1)

        var request = Self.post(initialize)
        request = .init(method: request.method, target: request.target,
                        headers: request.headers.filter { $0.key != "authorization" },
                        body: request.body)
        let unauthorized = await service.respond(to: request)
        XCTAssertEqual(unauthorized.status, 401)

        let badHost = await service.respond(to: Self.post(
            initialize, headers: ["host": "example.test:5254"]))
        XCTAssertEqual(badHost.status, 400)
        let badOrigin = await service.respond(to: Self.post(
            initialize,
            headers: ["origin": "https://attacker.example"]))
        XCTAssertEqual(badOrigin.status, 403)
        let safeOrigin = await service.respond(to: Self.post(
            initialize,
            headers: ["origin": "http://localhost:5254"]))
        XCTAssertEqual(safeOrigin.status, 200)
    }

    func testHTTPSessionHandshakeListAndDelete() async throws {
        let service = service()
        let initialized = await service.respond(
            to: Self.post(try Self.initializeBody(id: 1)))
        XCTAssertEqual(initialized.status, 200)
        let session = try XCTUnwrap(initialized.headers["Mcp-Session-Id"])
        let version = "2025-11-25"

        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])
        let notified = await service.respond(to: Self.post(
            notification, session: session, protocolVersion: version))
        XCTAssertEqual(notified.status, 202)

        let listed = await service.respond(to: Self.post(
            try Self.request(id: 2, method: "tools/list", params: [:]),
            session: session, protocolVersion: version))
        XCTAssertEqual(listed.status, 200)
        let object = try Self.object(listed.body)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertFalse(try XCTUnwrap(result["tools"] as? [[String: Any]]).isEmpty)

        let unknownSession = await service.respond(to: Self.post(
            try Self.request(id: 3, method: "ping"),
            session: "not-a-session", protocolVersion: version))
        XCTAssertEqual(unknownSession.status, 404)
        let missingVersion = await service.respond(to: Self.post(
            try Self.request(id: 4, method: "ping"),
            session: session, protocolVersion: nil))
        XCTAssertEqual(missingVersion.status, 400)

        let deleted = await service.respond(to: .init(
            method: "DELETE", target: "/mcp",
            headers: Self.baseHeaders.merging([
                "mcp-session-id": session,
                "mcp-protocol-version": version,
            ], uniquingKeysWith: { _, new in new }), body: Data()))
        XCTAssertEqual(deleted.status, 200)
        let afterDelete = await service.respond(to: Self.post(
            try Self.request(id: 5, method: "ping"),
            session: session, protocolVersion: version))
        XCTAssertEqual(afterDelete.status, 404)
    }

    func testHTTPAndStdioUseTheSameMCPDispatcher() async throws {
        let direct = NOWMCPServer(client: SocketAgentIntegrationClient(),
                                  audit: LocalMCPAuditSink())
        let service = service()
        let initialize = try Self.initializeBody(id: 1)

        let directInitializeData = await direct.handle(initialize)
        let directInitialize = try XCTUnwrap(directInitializeData)
        let httpInitialize = await service.respond(to: Self.post(initialize))
        XCTAssertEqual(try Self.object(directInitialize),
                       try Self.object(httpInitialize.body) as NSDictionary)
        let session = try XCTUnwrap(httpInitialize.headers["Mcp-Session-Id"])

        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])
        _ = await direct.handle(notification)
        _ = await service.respond(to: Self.post(
            notification, session: session,
            protocolVersion: "2025-11-25"))

        let list = try Self.request(id: 2, method: "tools/list", params: [:])
        let directListData = await direct.handle(list)
        let directList = try XCTUnwrap(directListData)
        let httpList = await service.respond(to: Self.post(
            list, session: session, protocolVersion: "2025-11-25"))
        XCTAssertEqual(try Self.object(directList),
                       try Self.object(httpList.body) as NSDictionary)
    }

    func testSessionLimitExpiresRatherThanGrowingWithoutBound() async throws {
        let configuration = MCPHTTPConfiguration(
            port: Self.port, bearerToken: Self.token,
            maximumSessions: 1, sessionLifetime: 10)
        let service = MCPHTTPService(
            configuration: configuration,
            serverFactory: Self.serverFactory)
        let start = Date(timeIntervalSince1970: 1_000)
        let first = await service.respond(
            to: Self.post(try Self.initializeBody(id: 1)), now: start)
        XCTAssertEqual(first.status, 200)
        let full = await service.respond(
            to: Self.post(try Self.initializeBody(id: 2)), now: start)
        XCTAssertEqual(full.status, 429)
        let expired = await service.respond(
            to: Self.post(try Self.initializeBody(id: 3)),
            now: start.addingTimeInterval(11))
        XCTAssertEqual(expired.status, 200)
    }

    func testOnlySuccessfulAuthenticatedInitializeReportsDiagnosticState()
        async throws {
        let probe = HTTPInitializationProbe()
        let service = MCPHTTPService(
            configuration: .init(port: Self.port, bearerToken: Self.token),
            serverFactory: Self.serverFactory,
            initializationObserver: { probe.record($0) })
        let moment = Date(timeIntervalSince1970: 42)
        let body = try Self.initializeBody(id: 1)

        var unauthorizedHeaders = Self.post(body).headers
        unauthorizedHeaders["authorization"] = nil
        let unauthorized = await service.respond(to: .init(
            method: "POST", target: "/mcp", headers: unauthorizedHeaders,
            body: body), now: moment)
        XCTAssertEqual(unauthorized.status, 401)
        XCTAssertTrue(probe.moments.isEmpty)

        let initialized = await service.respond(
            to: Self.post(body), now: moment)
        XCTAssertEqual(initialized.status, 200)
        XCTAssertEqual(probe.moments, [moment])
    }

    private func service() -> MCPHTTPService {
        MCPHTTPService(
            configuration: .init(
                port: Self.port, bearerToken: Self.token),
            serverFactory: Self.serverFactory)
    }

    private static let serverFactory: MCPHTTPService.ServerFactory = {
        (NOWMCPServer(client: SocketAgentIntegrationClient(),
                      audit: LocalMCPAuditSink()),
         NOWMCPClientIdentity())
    }

    private static var baseHeaders: [String: String] {[
        "host": "127.0.0.1:\(port)",
        "authorization": "Bearer \(token)",
    ]}

    private static func post(_ body: Data, session: String? = nil,
                             protocolVersion: String? = nil,
                             headers: [String: String] = [:])
        -> MCPHTTPRequest {
        var all = baseHeaders.merging([
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        ], uniquingKeysWith: { _, new in new })
        for (key, value) in headers { all[key] = value }
        all["mcp-session-id"] = session
        all["mcp-protocol-version"] = protocolVersion
        return .init(method: "POST", target: "/mcp", headers: all, body: body)
    }

    private static func initializeBody(id: Int) throws -> Data {
        try request(id: id, method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": ["name": "http-tests", "version": "1"],
        ])
    }

    private static func request(id: Int, method: String,
                                params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method,
        ]
        object["params"] = params
        return try JSONSerialization.data(withJSONObject: object,
                                           options: [.sortedKeys])
    }

    private static func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}

private final class HTTPInitializationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Date] = []

    var moments: [Date] { lock.withLock { stored } }
    func record(_ moment: Date) { lock.withLock { stored.append(moment) } }
}
