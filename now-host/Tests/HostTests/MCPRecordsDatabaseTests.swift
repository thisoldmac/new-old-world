import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// The persistent MCP record: schema migration, identity dedup, queries,
/// and retention — all against a temporary root, the way `ChatStoreTests`
/// keeps the real Application Support out of a test run.
final class MCPRecordsDatabaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-mcp-records-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMigrationIsIdempotentAcrossReopen() async throws {
        _ = try MCPRecordsDatabase(root: root)
        let reopened = try MCPRecordsDatabase(root: root)
        let none = try await reopened.actions(matching: MCPActionQuery())
        XCTAssertTrue(none.isEmpty)
    }

    func testAgentsDedupAcrossSessionsAndUnknownsShareOneRow() async throws {
        let database = try MCPRecordsDatabase(root: root)
        let start = Date(timeIntervalSince1970: 1_000)

        for (index, session) in ["s-one", "s-two"].enumerated() {
            try await database.record(
                event: Self.event(outcome: .answered),
                agent: MCPAgentIdentity(kind: .mcpHTTP,
                                        clientName: "Claude Code",
                                        clientVersion: "2.1",
                                        sessionKey: session),
                drivenGuest: "pb1400c",
                at: start.addingTimeInterval(Double(index)))
        }
        for index in 0..<2 {
            try await database.record(
                event: Self.event(outcome: .answered),
                agent: MCPAgentIdentity(kind: .mcpStdio,
                                        sessionKey: "pid:\(index)"),
                drivenGuest: nil,
                at: start.addingTimeInterval(10 + Double(index)))
        }

        let agents = try await database.agents()
        XCTAssertEqual(agents.count, 2)
        let named = try XCTUnwrap(agents.first {
            $0.clientName == "Claude Code"
        })
        XCTAssertEqual(named.displayName, "Claude Code 2.1")
        let namedSessions = try await database.sessions(ofAgent: named.id)
        XCTAssertEqual(namedSessions.count, 2)
        let unknown = try XCTUnwrap(agents.first {
            $0.clientName.isEmpty
        })
        XCTAssertEqual(unknown.displayName, "Unknown stdio client")
        let unknownSessions = try await database.sessions(
            ofAgent: unknown.id)
        XCTAssertEqual(unknownSessions.count, 2)
    }

    func testActionsJoinFilterAndPage() async throws {
        let database = try MCPRecordsDatabase(root: root)
        let start = Date(timeIntervalSince1970: 1_000)
        let claude = MCPAgentIdentity(kind: .mcpHTTP,
                                      clientName: "Claude Code",
                                      clientVersion: "2.1",
                                      sessionKey: "s-1")

        try await database.record(
            event: Self.event(capability: "now_list_machines",
                              outcome: .answered),
            agent: claude, drivenGuest: "pb1400c", at: start)
        try await database.record(
            event: Self.event(capability: "now_menu_act",
                              outcome: .refused,
                              reason: "no such menu"),
            agent: claude, drivenGuest: "pb1400c",
            at: start.addingTimeInterval(1))
        try await database.record(
            event: Self.event(capability: "now_capture_screen",
                              outcome: .answered),
            agent: MCPAgentIdentity(kind: .chat),
            drivenGuest: nil, at: start.addingTimeInterval(2))

        let all = try await database.actions(matching: MCPActionQuery())
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first?.action.capability, "now_capture_screen")
        XCTAssertNil(all.first?.targetMachine)
        XCTAssertEqual(all.last?.agentName, "Claude Code 2.1")
        XCTAssertEqual(all.last?.targetMachine, "pb1400c")

        let refusals = try await database.actions(
            matching: MCPActionQuery(outcome: .refused))
        XCTAssertEqual(refusals.map(\.action.capability), ["now_menu_act"])
        XCTAssertEqual(refusals.first?.action.reason, "no such menu")

        let paged = try await database.actions(
            matching: MCPActionQuery(limit: 1,
                                     beforeActionID: all.first?.id))
        XCTAssertEqual(paged.map(\.action.capability), ["now_menu_act"])

        let counts = try await database.counts()
        XCTAssertEqual(counts.answered, 2)
        XCTAssertEqual(counts.refused, 1)
        XCTAssertEqual(counts.denied, 0)
    }

    func testPruneAgesOutActionsAndOrphanedQuietSessions() async throws {
        let database = try MCPRecordsDatabase(root: root)
        let ancient = Date(timeIntervalSince1970: 1_000)
        let identity = MCPAgentIdentity(kind: .mcpHTTP,
                                        clientName: "old client",
                                        sessionKey: "s-old")
        try await database.record(event: Self.event(outcome: .answered),
                                  agent: identity,
                                  drivenGuest: "pb1400c", at: ancient)

        let later = ancient.addingTimeInterval(
            MCPRecordsDatabase.actionAgeLimit + 60)
        try await database.prune(now: later)

        let actions = try await database.actions(
            matching: MCPActionQuery())
        XCTAssertTrue(actions.isEmpty)
        let agents = try await database.agents()
        XCTAssertEqual(agents.count, 1, "agents are never auto-pruned")
        let leftoverSessions = try await database.sessions(
            ofAgent: agents[0].id)
        XCTAssertTrue(leftoverSessions.isEmpty,
            "a session with no actions left and no recent life goes too")
    }

    func testRecorderNeverThrowsAndStreamsInsertedRows() async throws {
        let database = try MCPRecordsDatabase(root: root)
        let recorder = MCPRecordsRecorder(database: database)

        recorder.record(event: Self.event(outcome: .answered),
                        agent: MCPAgentIdentity(kind: .chat),
                        drivenGuest: nil)
        var iterator = recorder.inserted.makeAsyncIterator()
        let row = await iterator.next()
        XCTAssertEqual(row?.action.capability, "now_list_machines")
        XCTAssertEqual(row?.agentName, "Chat")
    }

    private static func event(
        capability: String = "now_list_machines",
        outcome: HostProjectionAuditEvent.Outcome,
        reason: String? = nil) -> HostProjectionAuditEvent {
        HostProjectionAuditEvent(
            capability: HostCapabilityID(capability), face: .mcp,
            guest: nil, outcome: outcome, reason: reason)
    }
}
