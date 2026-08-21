import XCTest
@testable import Host
@testable import NOWAgentIntegration

private actor BlockingAPIRecordSink: NOWAPIDurableRecordSink {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func persistAPIRecord(event: HostProjectionAuditEvent,
                          agent: MCPAgentIdentity,
                          drivenGuest: String?) async {
        started = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func hasStarted() -> Bool { started }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompletionProbe {
    private var completed = false
    func finish() { completed = true }
    func value() -> Bool { completed }
}

private actor CapturingAPIRecordSink: NOWAPIDurableRecordSink {
    private var events: [HostProjectionAuditEvent] = []

    func persistAPIRecord(event: HostProjectionAuditEvent,
                          agent: MCPAgentIdentity,
                          drivenGuest: String?) async {
        events.append(event)
    }

    func recorded() -> [HostProjectionAuditEvent] { events }
}

/// The identity seam: who-called travels BESIDE the audit event, from each
/// transport to the records store, without the event's own shape changing.
final class MCPRecordsSeamTests: XCTestCase {
    /// The HTTP service's server factory hands back an identity box; the
    /// server fills the client half at initialize and the service adds the
    /// session id it minted.
    func testHTTPInitializeFillsTheIdentityBox() async throws {
        let identity = NOWMCPClientIdentity()
        let lifecycle = MCPInitializationSpy()
        let service = MCPHTTPService(
            configuration: .init(port: 5254,
                                 authMode: .unauthenticated,
                                 bearerToken: nil),
            serverFactory: {
                (NOWMCPServer(client: SocketAgentIntegrationClient(),
                              audit: LocalMCPAuditSink(),
                              identity: identity, lifecycle: lifecycle),
                 identity)
            })
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "Claude Code", "version": "2.1"],
            ],
        ])
        let reply = await service.respond(to: .init(
            method: "POST", target: "/mcp",
            headers: [
                "host": "127.0.0.1:5254",
                "content-type": "application/json",
                "accept": "application/json, text/event-stream",
            ], body: body))

        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(identity.clientName, "Claude Code")
        XCTAssertEqual(identity.clientVersion, "2.1")
        XCTAssertEqual(identity.sessionKey,
                       reply.headers["Mcp-Session-Id"])
        let recorded = lifecycle.last
        XCTAssertEqual(recorded?.clientName, "Claude Code")
        XCTAssertEqual(recorded?.clientVersion, "2.1")
        XCTAssertEqual(recorded?.sessionKey,
                       reply.headers["Mcp-Session-Id"])
    }

    /// The local-protocol audit request carries the identity fields only
    /// when the reporter has them, and bounds what a claim may say.
    func testLocalAuditRequestRoundTripsIdentityAndKeepsOldShape() throws {
        let event = HostProjectionAuditEvent(
            capability: HostCapabilityID("now_list_machines"), face: .mcp,
            guest: nil, outcome: .answered, reason: nil)

        let bare = try AgentIntegrationLocalCodec.encode(
            .audit(event))
        let decodedBare = try AgentIntegrationLocalCodec.decodeRequest(bare)
        XCTAssertNil(decodedBare.auditClientName)

        let full = try AgentIntegrationLocalCodec.encode(
            .audit(event, clientName: "Claude Code", clientVersion: "2.1",
                   sessionKey: "pid:42"))
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(full)
        XCTAssertEqual(decoded.auditClientName, "Claude Code")
        XCTAssertEqual(decoded.auditClientVersion, "2.1")
        XCTAssertEqual(decoded.auditSessionKey, "pid:42")

        let oversized = try AgentIntegrationLocalCodec.encode(
            .audit(event,
                   clientName: String(repeating: "n", count: 201)))
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(oversized))
    }

    func testLocalInitializationRequestHasItsOwnBoundedShape() throws {
        let request = try AgentIntegrationLocalCodec.encode(
            .mcpInitialize(clientName: "Claude Code", clientVersion: "2.1",
                           sessionKey: "pid:42"))
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(request)
        XCTAssertEqual(decoded.operation, .mcpInitialize)
        XCTAssertEqual(decoded.mcpClientName, "Claude Code")
        XCTAssertEqual(decoded.mcpClientVersion, "2.1")
        XCTAssertEqual(decoded.mcpSessionKey, "pid:42")
        XCTAssertNil(decoded.auditEvent,
                     "lifecycle evidence is not an invented action")

        let oversized = try AgentIntegrationLocalCodec.encode(
            .mcpInitialize(clientName: String(repeating: "n", count: 201),
                           clientVersion: nil, sessionKey: "pid:42"))
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(oversized))
    }

    /// The fan-out's third arm: a recorded event lands in the store, with
    /// the face naming an honest kind when nobody stated an identity.
    @MainActor
    func testAuditFanOutReachesTheRecordsStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-mcp-seam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MCPRecordsDatabase(root: root)
        let recorder = MCPRecordsRecorder(database: database)
        let event = HostProjectionAuditEvent(
            capability: HostCapabilityID("now_list_machines"), face: .chat,
            guest: "pb1400c", outcome: .answered, reason: nil)

        AgentIntegrationAuditLog.record(event, drivenGuest: nil,
                                        records: recorder)
        var iterator = recorder.inserted.makeAsyncIterator()
        let row = await iterator.next()
        XCTAssertEqual(row?.agentName, "Chat")
        XCTAssertEqual(row?.targetMachine, "pb1400c")
    }

    /// API records reuse the bounded store without acquiring an arguments or
    /// payload field: the bridge can carry only operation, target, and result.
    @MainActor
    func testAPIAuditReachesBoundedRecordsAsAnApplicationClient() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-api-seam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MCPRecordsDatabase(root: root)
        let recorder = MCPRecordsRecorder(database: database)
        var iterator = recorder.inserted.makeAsyncIterator()

        await HostNOWAPIAuditSink(records: recorder).record(.init(
            requestID: UUID(), operationID: "connections.disconnect",
            target: "pb1400c-session", disposition: .completed))

        let persisted = try await database.actions(
            matching: MCPActionQuery(limit: 1))
        XCTAssertEqual(persisted.count, 1,
                       "awaiting the API audit sink must include persistence")
        let row = await iterator.next()
        XCTAssertEqual(row?.agentName, "NOW API client")
        XCTAssertEqual(row?.targetMachine, "pb1400c-session")
        XCTAssertEqual(row?.action.face, .api)
        XCTAssertEqual(row?.action.capability, "connections.disconnect")
    }

    func testAPIAuditDoesNotReturnBeforeDurablePersistenceSettles() async throws {
        let records = BlockingAPIRecordSink()
        let completion = CompletionProbe()
        let task = Task {
            await HostNOWAPIAuditSink(records: records).record(.init(
                requestID: UUID(), operationID: "connections.disconnect",
                target: "pb1400c-session", disposition: .completed))
            await completion.finish()
        }
        while !(await records.hasStarted()) {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(10))
        let completedEarly = await completion.value()
        XCTAssertFalse(completedEarly)

        await records.release()
        await task.value
        let completedAfterRelease = await completion.value()
        XCTAssertTrue(completedAfterRelease)
    }

    func testAPIAuditPreservesAnsweredRefusedDeniedAndFailedOutcomes() async {
        let records = CapturingAPIRecordSink()
        let sink = HostNOWAPIAuditSink(records: records)
        for disposition in [
            NOWAPIAuditEvent.Disposition.completed, .refused, .denied, .failed,
        ] {
            await sink.record(.init(
                requestID: UUID(), operationID: "processes.quit",
                target: "pb1400c", disposition: disposition))
        }

        let events = await records.recorded()
        XCTAssertEqual(events.map(\.outcome), [
            .answered, .refused, .denied, .failed,
        ])
        XCTAssertEqual(events.map(\.reason), [nil, "refused", "denied", "failed"])
    }
}

private final class MCPInitializationSpy: MCPClientLifecycleSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recorded: MCPClientInitialization?

    var last: MCPClientInitialization? {
        lock.withLock { recorded }
    }

    func recordInitialization(_ initialization: MCPClientInitialization) {
        lock.withLock { recorded = initialization }
    }
}
