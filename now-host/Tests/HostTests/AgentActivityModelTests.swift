import XCTest
import NOWAgentIntegration
@testable import Host

/// The Agent page's words and its stream, tested where they are decided —
/// in the model — so the sentences a person reads are a fact rather than a
/// screenshot somebody took once.
@MainActor
final class AgentActivityModelTests: XCTestCase {

    // MARK: - The resting state

    /// **The state the page spends most of its life in, on most Macs.**
    ///
    /// A struct of zeroes rendered into the same table as an idle companion
    /// reads as a feature that failed to load, which is why the presence
    /// type keeps `neverAttached` as its own case. The reading has to spend
    /// that: its own sentences, and NO counters.
    func testNothingHasEverAttachedIsNotDrawnAsZeroes() {
        let reading = AgentPresenceReading(.none, asOf: Date())
        XCTAssertFalse(reading.showsCounters,
                       "Zero counters read as broken; this state has words.")
        XCTAssertEqual(reading.tone, .resting)
        XCTAssertFalse(reading.detail.contains("0"),
                       "No count belongs in the never-attached sentence.")
        // It says what is true and what would appear, rather than nothing.
        XCTAssertTrue(reading.detail.contains("Nothing is driving this Mac"),
                      reading.detail)
        XCTAssertTrue(reading.detail.contains("this page is where its work "
                                              + "appears"),
                      reading.detail)
    }

    /// Nothing has ever attached and nothing is attached now are different
    /// sentences. If they ever render the same, the pane reads as broken on
    /// the Mac where the first one is permanently true.
    func testNeverAttachedAndIdleAreDifferentSentences() {
        let now = Date()
        let idle = AgentPresenceReading(
            .init(totalRequests: 3,
                  lastSeen: now.addingTimeInterval(-3600)),
            asOf: now)
        let never = AgentPresenceReading(.none, asOf: now)
        XCTAssertNotEqual(never.headline, idle.headline)
        XCTAssertNotEqual(never.detail, idle.detail)
        XCTAssertTrue(idle.showsCounters,
                      "A companion that HAS attached has counts to show.")
        XCTAssertTrue(idle.detail.contains("1 hour ago"), idle.detail)
    }

    /// An endpoint that never opened reports the same `.neverAttached` — it
    /// is the honest reading, nothing reached it — so the page has to carry
    /// the reason separately or it prints a socket path to a file that does
    /// not exist.
    func testAFailedEndpointIsItsOwnStateRatherThanAnEmptyPage() {
        let model = AgentActivityModel()
        XCTAssertEqual(model.stdio, .unopened)
        model.stdioUnavailable("Refusing to replace an unsafe endpoint")
        XCTAssertEqual(
            model.stdio,
            .unavailable("Refusing to replace an unsafe endpoint"))
        model.stdioOpened(at: "/tmp/x/host.sock")
        XCTAssertEqual(model.stdio, .open(endpoint: "/tmp/x/host.sock"))
    }

    // MARK: - The server's lifecycle, which the MCP pane owns

    /// **Stopped is not "never started", and neither is "did not start".**
    ///
    /// The MCP pane draws one line off this state and offers one button, so
    /// three different reasons the socket is absent have to stay three
    /// states: a person whose client cannot connect is told whether they
    /// switched it off, whether it failed, or whether it has yet to run.
    func testAServerStoppedByHandIsItsOwnStateAndNotAFailure() {
        let model = AgentActivityModel()
        model.stdioOpened(at: "/tmp/x/host.sock")
        XCTAssertTrue(model.stdio.isRunning)

        model.stdioStopped()

        XCTAssertEqual(model.stdio, .stopped)
        XCTAssertFalse(model.stdio.isRunning,
                       "A stopped server offers Start, never Stop.")
        XCTAssertNotEqual(model.stdio, .unopened)
        for state in [MCPTransportState.unopened, .stopped,
                      .unavailable("no")] {
            XCTAssertFalse(state.isRunning,
                           "\(state) is not a server anyone can reach.")
        }
    }

    /// **Closing the door does not erase what came through it.** History
    /// lives in the records store now; transport lifecycle is state on this
    /// model and never touches the record.
    func testStoppingTheServerKeepsWhatAnAgentAlreadyDid() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MCPRecordsDatabase(root: root)
        try await database.record(
            event: HostProjectionAuditEvent(
                capability: ListProcessesProjection.capability, face: .mcp,
                guest: "PB 180c", outcome: .answered, reason: nil),
            agent: MCPAgentIdentity(kind: .mcpStdio),
            drivenGuest: nil, at: Date())
        let model = AgentActivityModel()
        model.stdioOpened(at: "/tmp/x/host.sock")

        model.stdioStopped()

        let rows = try await database.actions(matching: MCPActionQuery())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.action.capability,
                       ListProcessesProjection.capability.rawValue)
    }

    /// The two transports are independently operable. Stopping the
    /// client-launched stdio bridge must not take down NOW's HTTP listener.
    func testTransportLifecycleStatesAreIndependent() {
        let model = AgentActivityModel()
        model.stdioOpened(at: "/tmp/new-old-world.sock")
        model.httpOpened(at: "http://127.0.0.1:5254/mcp",
                         bearerToken: "secret")

        model.stdioStopped()

        XCTAssertEqual(model.stdio, .stopped)
        XCTAssertEqual(model.http,
                       .open(endpoint: "http://127.0.0.1:5254/mcp"))
        XCTAssertEqual(model.httpBearerToken, "secret")

        model.httpStopped()
        XCTAssertEqual(model.http, .stopped)
        XCTAssertNil(model.httpBearerToken)
    }

    func testPresenceCombinesStdioAndHTTPWithoutDoubleCountingEither() {
        let model = AgentActivityModel()
        let stdioFirst = Date(timeIntervalSince1970: 100)
        let httpFirst = Date(timeIntervalSince1970: 200)
        let httpLast = Date(timeIntervalSince1970: 300)
        model.httpRequestBegan(at: httpFirst)
        model.httpRequestEnded(at: httpLast)
        let companion = AgentCompanionActivity.Companion(
            processID: 42, firstSeen: stdioFirst,
            lastSeen: Date(timeIntervalSince1970: 250), requests: 3)

        let combined = model.combinedActivity(
            .init(companions: [companion], totalRequests: 3, inFlight: 1,
                  firstSeen: stdioFirst,
                  lastSeen: Date(timeIntervalSince1970: 250)))

        XCTAssertEqual(combined.companions.count, 1)
        XCTAssertEqual(combined.totalRequests, 4)
        XCTAssertEqual(combined.inFlight, 1)
        XCTAssertEqual(combined.firstSeen, stdioFirst)
        XCTAssertEqual(combined.lastSeen, httpLast)
    }

    // MARK: - Presence that changes with nothing happening

    /// The ledger publishes on every change, which covers every transition
    /// that HAPPENS. This one does not happen: the same activity, unread and
    /// untouched, crosses from attached to not-attached on the clock alone.
    /// It is why the reading takes a clock and why the pane re-derives on a
    /// schedule rather than on the publisher.
    func testAttachedDecaysToIdleWithNothingHappening() {
        let spoke = Date()
        let activity = AgentCompanionActivity(totalRequests: 1,
                                              firstSeen: spoke,
                                              lastSeen: spoke)
        let inside = AgentPresenceReading(
            activity,
            asOf: spoke.addingTimeInterval(
                AgentCompanionActivity.activeWindow - 1))
        let outside = AgentPresenceReading(
            activity,
            asOf: spoke.addingTimeInterval(
                AgentCompanionActivity.activeWindow + 1))
        XCTAssertEqual(inside.tone, .attached)
        XCTAssertEqual(outside.tone, .resting)
        XCTAssertNotEqual(inside.headline, outside.headline)
    }

    /// A request in flight beats the clock: a companion whose last COMPLETED
    /// call was an hour ago but which is being served right now is working,
    /// not idle.
    func testAnInFlightCallReadsAsWorkingWhateverTheClockSays() {
        let reading = AgentPresenceReading(
            .init(totalRequests: 9, inFlight: 1,
                  lastSeen: Date().addingTimeInterval(-3600)),
            asOf: Date())
        XCTAssertEqual(reading.tone, .working)
        XCTAssertEqual(reading.headline, "An agent is working now")
    }

    func testElapsedIsWrittenOutRatherThanFormatted() {
        let now = Date()
        func text(_ ago: TimeInterval) -> String {
            AgentPresenceReading.elapsed(now.addingTimeInterval(-ago),
                                         to: now)
        }
        XCTAssertEqual(text(2), "just now")
        XCTAssertEqual(text(30), "30 seconds ago")
        XCTAssertEqual(text(60), "1 minute ago")
        XCTAssertEqual(text(600), "10 minutes ago")
        XCTAssertEqual(text(7200), "2 hours ago")
        XCTAssertEqual(text(86400 * 3), "3 days ago")
    }

    // MARK: - The stream

    /// The record answers "what did it do", which the presence ledger
    /// deliberately refuses to record. It stores exactly the audit event's
    /// fields; the row's own words come from the registry at draw time.
    func testARecordedActionCarriesTheRowsOwnWordsAndItsHint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MCPRecordsDatabase(root: root)
        let start = Date(timeIntervalSince1970: 1_000)
        try await database.record(
            event: HostProjectionAuditEvent(
                capability: GuestFilesMutateProjection.capability,
                face: .mcp, guest: nil, outcome: .answered),
            agent: MCPAgentIdentity(kind: .mcpStdio),
            drivenGuest: "pb1400c", at: start)
        try await database.record(
            event: HostProjectionAuditEvent(
                capability: ListProcessesProjection.capability,
                face: .mcp, guest: "q950", outcome: .refused,
                reason: "now_list_processes accepts no arguments"),
            agent: MCPAgentIdentity(kind: .mcpStdio),
            drivenGuest: "pb1400c", at: start.addingTimeInterval(1))

        // Newest first: the question is asked in that order.
        let rows = try await database.actions(matching: MCPActionQuery())
        XCTAssertEqual(rows.first?.action.capability, "now_list_processes")
        XCTAssertEqual(rows.first?.targetMachine, "q950",
                       "A named machine is the caller's, not the driven one.")
        XCTAssertEqual(rows.first?.action.reason,
                       "now_list_processes accepts no arguments")
        XCTAssertEqual(rows.last?.targetMachine, "pb1400c",
                       "An omitted selector resolves to the driven machine.")
        let capability = try XCTUnwrap(rows.last?.action.capability)
        XCTAssertTrue(AgentActivityEvent.isDestructive(capability),
                      "The row declares itself destructive; the page reads "
                      + "that rather than deciding it again.")
        // The row's MCP title, less the product name it repeats.
        XCTAssertEqual(AgentActivityEvent.title(for: capability),
                       "Change the Guest's Files")
    }

    /// Every registered capability has words, because the title comes from
    /// the row. A hand-kept list is the failure this derivation avoids: it
    /// would go stale one row at a time and nothing would fail.
    func testEveryRegisteredCapabilityHasWordsOfItsOwn() {
        for capability in HostProjectionRegistry.hostFaces.capabilities {
            let title = AgentActivityEvent.title(for: capability.rawValue)
            XCTAssertFalse(title.isEmpty, capability.rawValue)
            XCTAssertNotEqual(
                title, capability.rawValue,
                "\(capability.rawValue) fell back to its tool name, so its "
                + "row states no title for the MCP face.")
            XCTAssertFalse(title.contains("New Old World"), title)
        }
    }

    /// One call, both readers. The log line and the durable record come
    /// from the same typed event at the same seam, so a reporting site
    /// cannot write one and forget the other — which is exactly how the
    /// visible half of rule 3 went missing for twelve capabilities.
    func testOneAuditCallReachesBothTheLogAndTheRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = MCPRecordsRecorder(
            database: try MCPRecordsDatabase(root: root))
        let log = HostLog.shared
        let before = log.lines.count
        AgentIntegrationAuditLog.record(
            HostProjectionAuditEvent(
                capability: RevealItemProjection.capability,
                face: .mcp, guest: nil, outcome: .answered),
            drivenGuest: "pb1400c",
            records: recorder)

        XCTAssertEqual(log.lines.count, before + 1)
        let line = try XCTUnwrap(log.lines.last?.text)
        XCTAssertTrue(line.contains("mcp now_reveal_item guest=pb1400c "
                                    + "answered"), line)
        var iterator = recorder.inserted.makeAsyncIterator()
        let row = await iterator.next()
        XCTAssertEqual(row?.action.capability, "now_reveal_item")
        XCTAssertEqual(row?.targetMachine, "pb1400c")
    }

    // MARK: - The machine's own answer

    /// **Silence is not consent.** A guest that predates the field says
    /// nothing, and a build that omitted the agent features says `disabled`
    /// out loud — the whole reason the field is three-state. The page must
    /// never render the first as a yes.
    func testSilenceReadsAsAnAbsentAnswerRatherThanAYes() {
        let silent = AgentConsentReading(machine: "q950", access: nil)
        XCTAssertFalse(silent.isConsent)
        XCTAssertTrue(silent.detail.contains("Silence is not consent"),
                      silent.detail)
        // And it says who is proceeding anyway, rather than implying the
        // machine agreed to it.
        XCTAssertTrue(silent.detail.contains(
            "decision made on \(MachineNaming.thisMac)"), silent.detail)
        // And it names the machine that stayed silent rather than calling
        // it "this Mac" — the phrase the window around this row already
        // spends on the reader's own machine.
        XCTAssertTrue(silent.detail.lowercased().contains("q950"),
                      silent.detail)
        XCTAssertFalse(silent.detail.contains("This Mac"), silent.detail)
    }

    func testTheFourAnswersReadAsFourDifferentThings() {
        let readings = [
            AgentConsentReading(machine: "m", access: nil),
            AgentConsentReading(machine: "m", access: .disabled),
            AgentConsentReading(machine: "m", access: .readOnly),
            AgentConsentReading(machine: "m", access: .fullAccess),
            AgentConsentReading(machine: "m", access: .unrecognized("god")),
        ]
        XCTAssertEqual(Set(readings.map(\.title)).count, readings.count,
                       "Five states, five readings.")
        XCTAssertEqual(readings.map(\.isConsent),
                       [false, false, true, true, false],
                       "Only a tier this build can NAME is consent.")
        XCTAssertTrue(readings[1].detail.contains("says no"),
                      readings[1].detail)
        // A refusing machine is changed at the machine. There is no control
        // on this page, and the sentence says where one is.
        XCTAssertTrue(readings[1].detail.contains("not here"),
                      readings[1].detail)
        XCTAssertTrue(readings[4].title.contains("god"), readings[4].title)
    }
}
