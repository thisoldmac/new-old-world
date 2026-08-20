import XCTest
import Darwin
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class NOWAPIHTTPTests: XCTestCase {
    private static let apiKey = String(repeating: "a", count: 64)

    func testAPIKeyAndMCPBearerCannotAuthorizeTheOtherRoute() async throws {
        let fixture = FixtureHost()
        let service = makeHTTPService(host: fixture)

        let missing = await service.respond(to: request("GET", "/api/v1"))
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(missing.headers["WWW-Authenticate"], "ApiKey")

        let bearerOnly = await service.respond(to: request(
            "GET", "/api/v1", headers: ["authorization": "Bearer mcp-token"]))
        XCTAssertEqual(bearerOnly.status, 401)

        let apiKeyOnMCP = await service.respond(to: request(
            "GET", "/mcp", headers: ["x-api-key": Self.apiKey]))
        XCTAssertEqual(apiKeyOnMCP.status, 401)

        let authorized = await service.respond(to: apiRequest("GET", "/api/v1"))
        XCTAssertEqual(authorized.status, 200)
    }

    func testDisconnectTargetsTheExactSessionNotTheStableGuestID() async throws {
        let fixture = FixtureHost()
        let service = makeHTTPService(host: fixture)

        let stableID = await service.respond(to: apiRequest(
            "DELETE", "/api/v1/connections/pb1400c"))
        XCTAssertEqual(stableID.status, 400)
        XCTAssertTrue(fixture.disconnected.isEmpty)

        let exact = await service.respond(to: apiRequest(
            "DELETE", "/api/v1/connections/pb1400c-11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(exact.status, 200)
        XCTAssertEqual(fixture.disconnected, [
            "pb1400c-11111111-1111-1111-1111-111111111111",
        ])
    }

    func testStoppingGuestListenerLeavesDeveloperAPIRoutable() async throws {
        let fixture = FixtureHost()
        let service = makeHTTPService(host: fixture)

        let stopped = await service.respond(to: apiRequest(
            "DELETE", "/api/v1/listener"))
        XCTAssertEqual(stopped.status, 200)
        XCTAssertEqual(fixture.stopCount, 1)

        let identity = await service.respond(to: apiRequest("GET", "/api/v1"))
        XCTAssertEqual(identity.status, 200)
        XCTAssertEqual(try object(identity.body)["apiMajor"] as? Int, 1)
    }

    func testGuestJSONHasOnlyPublicContractFields() async throws {
        let service = makeHTTPService(host: FixtureHost())
        let response = await service.respond(to: apiRequest(
            "GET", "/api/v1/guests"))
        XCTAssertEqual(response.status, 200)
        let guests = try XCTUnwrap(try object(response.body)["guests"]
            as? [[String: Any]])
        let guest = try XCTUnwrap(guests.first)
        XCTAssertEqual(Set(guest.keys), [
            "id", "sessionId", "displayName", "connected", "connectedAt",
        ])
        XCTAssertNil(guest["address"])
        XCTAssertNil(guest["fingerprint"])
        XCTAssertNil(guest["registryKey"])
    }

    func testOperationCatalogPublishesBoundAPIOperationsNotMCPTools() async throws {
        let service = makeHTTPService(host: FixtureHost())
        let response = await service.respond(to: apiRequest(
            "GET", "/api/v1/operations"))
        let rows = try XCTUnwrap(try object(response.body)["operations"]
            as? [[String: Any]])
        let identifiers = Set(rows.compactMap { $0["operationId"] as? String })
        XCTAssertTrue(identifiers.contains("connections.disconnect"))
        XCTAssertTrue(identifiers.contains("commands.execute"))
        XCTAssertFalse(identifiers.contains("now_list_machines"))
        XCTAssertFalse(identifiers.contains("files.put"),
                       "S4 operations are not runtime-bound in S2")
    }

    func testConsoleCommandRouteReturnsTheGuestResult() async throws {
        let fixture = FixtureHost()
        let service = makeHTTPService(host: fixture)
        let response = await service.respond(to: apiRequest(
            "POST", "/api/v1/guests/pb1400c/commands",
            body: Data(#"{"command":"help","argumentLine":""}"#.utf8)))

        XCTAssertEqual(response.status, 200)
        let body = try object(response.body)
        XCTAssertEqual(body["operationId"] as? String, "commands.execute")
        XCTAssertEqual(body["disposition"] as? String, "completed")
        XCTAssertEqual(fixture.commands.first?.guestID, "pb1400c")
        XCTAssertEqual(fixture.commands.first?.request.command, "help")
        XCTAssertEqual(fixture.commands.first?.request.argumentLine, "")
        XCTAssertNil(fixture.commands.first?.request.arguments)
    }

    func testConsoleCommandAcceptsTypedArgumentsWithoutCoercion() async throws {
        let fixture = FixtureHost()
        let service = makeHTTPService(host: fixture)
        let response = await service.respond(to: apiRequest(
            "POST", "/api/v1/guests/pb1400c/commands",
            body: Data(#"{"command":"winact","arguments":{"part":21,"wait":true,"title":"General"}}"#.utf8)))

        XCTAssertEqual(response.status, 200)
        let arguments = try XCTUnwrap(fixture.commands.first?.request.arguments)
        XCTAssertEqual(arguments["part"], .number(21))
        XCTAssertEqual(arguments["wait"], .flag(true))
        XCTAssertEqual(arguments["title"], .text("General"))
        XCTAssertNil(fixture.commands.first?.request.argumentLine)
    }

    func testConsoleCommandRejectsAmbiguousAndOversizedInputBeforeDispatch() async throws {
        let fixture = FixtureHost()
        let service = makeHTTPService(host: fixture)
        let ambiguous = await service.respond(to: apiRequest(
            "POST", "/api/v1/guests/pb1400c/commands",
            body: Data(#"{"command":"help","arguments":{},"argumentLine":""}"#.utf8)))
        XCTAssertEqual(ambiguous.status, 400)
        XCTAssertEqual(try errorCode(ambiguous), "ambiguous_command_arguments")
        XCTAssertEqual(try object(ambiguous.body)["disposition"] as? String,
                       "invalid")

        let longLine = String(repeating: "x", count:
            NOWAPIConsoleCommandService.maximumArgumentLineBytes + 1)
        let body = try JSONSerialization.data(withJSONObject: [
            "command": "help", "argumentLine": longLine,
        ])
        let oversized = await service.respond(to: apiRequest(
            "POST", "/api/v1/guests/pb1400c/commands", body: body))
        XCTAssertEqual(oversized.status, 400)
        XCTAssertEqual(try errorCode(oversized), "invalid_argument_line")
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testConsoleCommandAuditsOnlyOperationTargetAndDisposition() async throws {
        let audit = NOWAPIAuditSpy()
        let fixture = FixtureHost()
        let service = makeHTTPService(host: fixture, audit: audit)
        let secret = "payload-must-not-enter-audit"
        let response = await service.respond(to: apiRequest(
            "POST", "/api/v1/guests/pb1400c/commands",
            body: Data("{\"command\":\"help\",\"argumentLine\":\"\(secret)\"}".utf8)))

        XCTAssertEqual(response.status, 200)
        let events = await audit.recorded()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.operationID, "commands.execute")
        XCTAssertEqual(event.target, "pb1400c")
        XCTAssertEqual(event.disposition, .completed)
        XCTAssertFalse(String(describing: event).contains(secret))
    }

    func testMutationsAuditOperationAndTargetWithoutBody() async throws {
        let audit = NOWAPIAuditSpy()
        let service = makeHTTPService(host: FixtureHost(), audit: audit)
        let response = await service.respond(to: apiRequest(
            "DELETE", "/api/v1/connections/pb1400c-11111111-1111-1111-1111-111111111111",
            body: Data(#"{"private":"must-not-be-recorded"}"#.utf8)))
        XCTAssertEqual(response.status, 200)
        let recorded = await audit.recorded()
        let event = try XCTUnwrap(recorded.first)
        XCTAssertEqual(event.operationID, "connections.disconnect")
        XCTAssertEqual(event.target, "pb1400c-11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(event.disposition, .completed)
    }

    func testIndependentFixtureClientUsesNoMCPHandshakeOrToolNames() async throws {
        let port = try availablePort()
        let fixture = FixtureHost()
        let listener = try MCPHTTPListener(
            configuration: .init(port: port, authMode: .bearer,
                                 bearerToken: "mcp-token"),
            serverFactory: {
                (NOWMCPServer(client: SocketAgentIntegrationClient(),
                              audit: LocalMCPAuditSink()),
                 NOWMCPClientIdentity())
            },
            apiRouter: NOWAPIHTTPRouter(
                apiKey: Self.apiKey,
                contractDigest: String(repeating: "d", count: 64),
                host: fixture))
        try await listener.start()
        defer { listener.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "api-v1-client", withExtension: "py",
            subdirectory: "Fixtures"))
        process.arguments = [fixtureURL.path, String(port), Self.apiKey]
        let errors = Pipe()
        process.standardError = errors
        let finished = expectation(description: "Python API fixture finished")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        await fulfillment(of: [finished], timeout: 8)
        XCTAssertEqual(process.terminationStatus, 0,
                       String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? "")
    }

    private func makeHTTPService(
        host: FixtureHost,
        audit: any NOWAPIAuditSink = NOWAPINullAuditSink()
    ) -> MCPHTTPService {
        MCPHTTPService(
            configuration: .init(port: 5254, authMode: .bearer,
                                 bearerToken: "mcp-token"),
            serverFactory: {
                (NOWMCPServer(client: SocketAgentIntegrationClient(),
                              audit: LocalMCPAuditSink()),
                 NOWMCPClientIdentity())
            },
            apiRouter: NOWAPIHTTPRouter(
                apiKey: Self.apiKey,
                contractDigest: String(repeating: "d", count: 64),
                host: host,
                audit: audit))
    }

    private func apiRequest(_ method: String, _ target: String,
                            body: Data = Data()) -> MCPHTTPRequest {
        request(method, target, headers: ["x-api-key": Self.apiKey], body: body)
    }

    private func request(_ method: String, _ target: String,
                         headers: [String: String] = [:],
                         body: Data = Data()) -> MCPHTTPRequest {
        .init(method: method, target: target,
              headers: ["host": "127.0.0.1:5254"].merging(
                headers, uniquingKeysWith: { _, new in new }), body: body)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(_ response: MCPHTTPResponse) throws -> String? {
        let error = try XCTUnwrap(try object(response.body)["error"]
            as? [String: Any])
        return error["code"] as? String
    }

    private func availablePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socket, $0, &length)
            }
        }
        return UInt16(bigEndian: bound.sin_port)
    }
}

@MainActor
private final class FixtureHost: NOWAPIHostServing {
    var disconnected: [String] = []
    var stopCount = 0
    var commands: [(guestID: String, request: NOWAPIConsoleCommandRequest)] = []
    var commandOutcome: NOWAPIConsoleCommandOutcome?

    func apiGuests() -> [NOWAPIGuestSummary] {
        [.init(id: "pb1400c",
               sessionID: "pb1400c-11111111-1111-1111-1111-111111111111",
               displayName: "PowerBook 1400c", connected: true,
               connectedAt: Date(timeIntervalSince1970: 1_000))]
    }

    func apiGuest(id: String) -> NOWAPIGuestDetail? {
        guard id == "pb1400c" else { return nil }
        return .init(summary: apiGuests()[0], name: "PowerBook 1400c",
                     version: "1", build: "fixture", operatingSystem: "Mac OS 9.1",
                     agentAccess: "control", capabilities: ["files", "commands"])
    }

    func apiListener() -> NOWAPIListenerSummary {
        .init(state: stopCount == 0 ? "connected" : "idle",
              desiredPorts: [5250], boundPorts: stopCount == 0 ? [5250] : [])
    }

    func apiStartListener() -> NOWAPIListenerSummary { apiListener() }
    func apiStopListener() -> NOWAPIListenerSummary {
        stopCount += 1
        return apiListener()
    }
    func apiConnections() -> [NOWAPIConnectionSummary] {
        apiGuests().compactMap { guest in
            guard let sessionID = guest.sessionID,
                  let connectedAt = guest.connectedAt else { return nil }
            return .init(guestID: guest.id, sessionID: sessionID,
                         connectedAt: connectedAt)
        }
    }
    func apiDisconnect(sessionID: String) -> Bool {
        guard sessionID == apiGuests()[0].sessionID else { return false }
        disconnected.append(sessionID)
        return true
    }

    func apiExecuteCommand(
        guestID: String, request: NOWAPIConsoleCommandRequest,
        completion: @escaping (NOWAPIConsoleCommandOutcome) -> Void
    ) {
        commands.append((guestID, request))
        completion(commandOutcome ?? .init(
            guestID: guestID,
            sessionID: "pb1400c-11111111-1111-1111-1111-111111111111",
            disposition: .completed,
            output: ["help": [["help", "list commands"]]],
            outputObjects: nil, error: nil))
    }
}

private actor NOWAPIAuditSpy: NOWAPIAuditSink {
    private(set) var events: [NOWAPIAuditEvent] = []
    func record(_ event: NOWAPIAuditEvent) { events.append(event) }
    func recorded() -> [NOWAPIAuditEvent] { events }
}
