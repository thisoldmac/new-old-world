import XCTest

@testable import Host
@testable import NOWAgentIntegration

/* The loop against a scripted provider and a stub machine: tool calls
   flow through the dispatch (visible to the audit spy as the chat
   face), results feed back as turns, refusals continue the chat, and
   the ceiling, busy rule and cancellation all bite. */

private final class ScriptedChatProvider: ChatProvider, @unchecked Sendable {
    let id = "fake"
    let label = "Fake"
    /// Overridable: the harness asks the provider what it can reach, so
    /// a reach is a thing this double must be able to lie about.
    var toolReach = ChatToolReach.harness
    private let lock = NSLock()
    private var script: [[ChatStreamEvent]]
    private(set) var requests: [ChatCompletionRequest] = []
    /// When the script runs dry, either finish politely or hang until
    /// cancelled — the second is how the busy/cancel tests hold a turn
    /// open.
    var hangsWhenDry = false

    init(_ script: [[ChatStreamEvent]]) {
        self.script = script
    }

    func entry() async -> ChatProviderEntry {
        ChatProviderEntry(id: id, label: label, state: "serving", detail: "")
    }

    func listModels() async throws -> [ChatModel] {
        [ChatModel(providerID: id, modelID: "m", displayName: "m")]
    }

    func stream(_ request: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = script.isEmpty ? nil : script.removeFirst()
        let hang = hangsWhenDry
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if let events {
                for event in events { continuation.yield(event) }
                continuation.finish()
                return
            }
            if hang {
                let task = Task {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            } else {
                continuation.yield(.finished(.endTurn))
                continuation.finish()
            }
        }
    }
}

private actor AuditSpy: HostProjectionAuditSink {
    private(set) var events: [HostProjectionAuditEvent] = []
    func record(_ event: HostProjectionAuditEvent) async {
        events.append(event)
    }
    func all() -> [HostProjectionAuditEvent] { events }
}

/// A connected stub machine with a configurable consent answer. Only
/// the lanes these tests drive answer anything real.
private struct StubMachineClient: AgentIntegrationClient {
    var access: AgentIntegrationGuestAccess?
    /// False means nothing has dialled in — the state a pane opens in,
    /// and the one the system prompt has to stop describing the moment
    /// a machine arrives.
    var isConnected = true

    func addressing(_ selector: String?) -> AgentIntegrationClient { self }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        guard isConnected else { return .unavailable(.guest) }
        return .available(.init(
            state: .connected,
            observedAt: Date(timeIntervalSince1970: 0),
            listeningPort: 1400,
            sessionID: nil,
            guest: .init(
                name: "pb1400c", version: "0.1.0", agentAccess: access,
                operatingSystem: "Mac OS 9.1", connectedAt: nil,
                lastTraffic: nil, quietFor: nil, pingsAnswered: nil,
                framesReceived: nil),
            failure: nil))
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.guest)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.guest)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.guest)
    }

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        .unavailable(.guest)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.guest)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.guest)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.guest)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.guest)
    }
}

/// A connection that arrives mid-session, shared with the harness's
/// client factory so the SECOND turn builds its client from the new
/// state rather than a captured one.
private final class Connected: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ChatHarnessEvent] = []
    private let done = XCTestExpectation(description: "finished")

    func sink(_ event: ChatHarnessEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
        if case .finished = event { done.fulfill() }
    }

    func wait(_ test: XCTestCase, seconds: TimeInterval = 5)
        -> [ChatHarnessEvent] {
        _ = XCTWaiter.wait(for: [done], timeout: seconds)
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func outcome() -> ChatChatOutcome? {
        lock.lock()
        defer { lock.unlock() }
        for case .finished(let outcome) in events { return outcome }
        return nil
    }
}

private func toolCallEvents(_ name: String, arguments: String = "{}")
    -> [ChatStreamEvent] {
    [
        .textDelta("Checking. "),
        .finished(.toolUse([ChatToolCall(
            id: "c1", name: name, argumentsJSON: arguments)])),
    ]
}

final class ChatHarnessTests: XCTestCase {
    private func makeHarness(
        provider: ScriptedChatProvider,
        access: AgentIntegrationGuestAccess? = .fullAccess,
        audit: AuditSpy = AuditSpy(),
        maxToolTurns: Int = 4
    ) -> ChatHarness {
        let registry = ChatProviderRegistry()
        registry.register(provider)
        return ChatHarness(
            registry: registry,
            makeClient: { _ in StubMachineClient(access: access) },
            audit: audit,
            maxToolTurns: maxToolTurns)
    }

    func testTextToolTextRoundTrip() async {
        let provider = ScriptedChatProvider([
            toolCallEvents("now_list_processes"),
            [.textDelta("Nothing running."), .finished(.endTurn)],
        ])
        let audit = AuditSpy()
        let harness = makeHarness(provider: provider, audit: audit)
        let log = EventLog()
        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("what runs?")],
            addressing: nil, origin: .hostPane, events: log.sink)
        _ = log.wait(self)

        let outcome = log.outcome()
        XCTAssertEqual(outcome?.ok, true)
        // Assistant tool-call turn, tool-result turn, final assistant.
        XCTAssertEqual(outcome?.appended.count, 3)
        XCTAssertEqual(outcome?.appended[0].role, .assistant)
        XCTAssertEqual(outcome?.appended[1].role, .tool)
        XCTAssertEqual(outcome?.appended[2].role, .assistant)
        // The second provider request saw the whole exchange.
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[1].turns.count, 3)
        // The system prompt names the machine and its situation.
        XCTAssertTrue(provider.requests[0].system.contains("pb1400c"))
        XCTAssertTrue(
            provider.requests[0].system.contains("classic machine"))
        // And the dispatch recorded the call under the chat face.
        let recorded = await audit.all()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].face, .chat)
        XCTAssertEqual(recorded[0].capability, "now_list_processes")
        XCTAssertEqual(recorded[0].outcome, .answered)
    }

    func testConsentDenialBecomesAToolErrorAndTheChatContinues() async {
        let provider = ScriptedChatProvider([
            toolCallEvents("now_list_processes"),
            [.textDelta("The machine declined."), .finished(.endTurn)],
        ])
        let audit = AuditSpy()
        let harness = makeHarness(
            provider: provider, access: .disabled, audit: audit)
        let log = EventLog()
        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("ps")],
            addressing: nil, origin: .hostPane, events: log.sink)
        let events = log.wait(self)

        XCTAssertEqual(log.outcome()?.ok, true, "a denial must not end the chat")
        let toolFinishes = events.compactMap {
            if case .toolFinished(_, let ok) = $0 { return ok }
            return nil
        }
        XCTAssertEqual(toolFinishes, [false])
        let recorded = await audit.all()
        XCTAssertEqual(recorded.first?.outcome, .denied)
        // The denial's own sentence went back to the model as a result.
        guard case .toolResult(_, let text, _, let isError)?
            = log.outcome()?.appended[1].content.first else {
            return XCTFail("no tool result turn")
        }
        XCTAssertTrue(isError)
        XCTAssertFalse(text.isEmpty)
    }

    func testUnknownToolAndBadJSONAreErrorsNotCrashes() async {
        let provider = ScriptedChatProvider([
            toolCallEvents("now_totally_made_up"),
            toolCallEvents("now_list_processes", arguments: "{nope"),
            [.finished(.endTurn)],
        ])
        let audit = AuditSpy()
        let harness = makeHarness(provider: provider, audit: audit)
        let log = EventLog()
        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("x")],
            addressing: nil, origin: .hostPane, events: log.sink)
        _ = log.wait(self)

        XCTAssertEqual(log.outcome()?.ok, true)
        // Unknown tool: dispatch answered nil, nothing audited. Bad
        // JSON: never dispatched, nothing audited either.
        let recorded = await audit.all()
        XCTAssertTrue(recorded.isEmpty)
        guard case .toolResult(_, let unknownText, _, true)?
            = log.outcome()?.appended[1].content.first else {
            return XCTFail("no unknown-tool result")
        }
        XCTAssertTrue(unknownText.contains("Unknown tool"))
        guard case .toolResult(_, let jsonText, _, true)?
            = log.outcome()?.appended[3].content.first else {
            return XCTFail("no bad-json result")
        }
        XCTAssertTrue(jsonText.contains("JSON"))
    }

    func testTurnCeilingStopsARunawayToolLoop() async {
        let provider = ScriptedChatProvider([
            toolCallEvents("now_list_processes"),
            toolCallEvents("now_list_processes"),
            toolCallEvents("now_list_processes"),
        ])
        let harness = makeHarness(provider: provider, maxToolTurns: 2)
        let log = EventLog()
        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("x")],
            addressing: nil, origin: .hostPane, events: log.sink)
        _ = log.wait(self)
        XCTAssertEqual(log.outcome()?.ok, false)
        XCTAssertEqual(log.outcome()?.code, "turn-limit")
    }

    func testUnknownModelRefusesBeforeAnyProviderCall() async {
        let provider = ScriptedChatProvider([])
        let harness = makeHarness(provider: provider)
        let log = EventLog()
        await harness.run(
            conversation: "t", wireModelID: "elsewhere/m",
            transcript: [.user("x")],
            addressing: nil, origin: .hostPane, events: log.sink)
        _ = log.wait(self)
        XCTAssertEqual(log.outcome()?.code, "unknown-model")
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testSecondSendIsBusyAndCancelEndsTheFirst() async {
        let provider = ScriptedChatProvider([])
        provider.hangsWhenDry = true
        let harness = makeHarness(provider: provider)
        let log = EventLog()
        let started = await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("x")],
            addressing: nil, origin: .hostPane, events: log.sink)
        XCTAssertTrue(started)
        let second = await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("y")],
            addressing: nil, origin: .hostPane, events: { _ in })
        XCTAssertFalse(second, "one transcript, one turn at a time")
        let stillRunning = await harness.isRunning(conversation: "t")
        XCTAssertTrue(stillRunning)

        let cancelled = await harness.cancel(conversation: "t")
        XCTAssertTrue(cancelled)
        _ = log.wait(self)
        XCTAssertEqual(log.outcome()?.code, "cancelled")
        let again = await harness.cancel(conversation: "t")
        XCTAssertFalse(again, "a second cancel is not-running")
    }

    func testGuestWireOriginAddsTheClassicScreenRules() async {
        let provider = ScriptedChatProvider([[.finished(.endTurn)]])
        let harness = makeHarness(provider: provider)
        let log = EventLog()
        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("hi")],
            addressing: "pb1400c", origin: .guestWire, events: log.sink)
        _ = log.wait(self)
        XCTAssertTrue(provider.requests[0].system.contains("Plain text only"))
        XCTAssertTrue(
            provider.requests[0].system.contains("sitting AT the classic"))
    }

    /* The declaration is the whole point of the reach work, so it is
       asserted rather than assumed: a provider that says it has no
       hands must be SENT none and TOLD so. Without this, the harness
       can go back to rendering the registry for a runtime spawned with
       `--tools ""` and every test still passes — which is how the
       original defect read as working code. */
    func testAToollessProviderIsSentNoToolsAndToldWhy() async {
        let provider = ScriptedChatProvider([[.finished(.endTurn)]])
        provider.toolReach = .none(reason: "Codex answers from knowledge")
        let harness = makeHarness(provider: provider)
        let log = EventLog()

        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("what is in the process table?")],
            addressing: nil, origin: .hostPane, events: log.sink)
        _ = log.wait(self)

        XCTAssertTrue(provider.requests[0].tools.isEmpty,
                      "a provider that cannot use tools was sent some")
        XCTAssertTrue(
            provider.requests[0].system.contains("YOU HAVE NO TOOLS"),
            provider.requests[0].system)
        XCTAssertTrue(
            provider.requests[0].system.contains(
                "Codex answers from knowledge"),
            provider.requests[0].system)
    }

    /// A workspace provider reaches the same capabilities by another
    /// road (MCP), so a second copy in the request would be two names
    /// for one act — and the turn must still be told where it is.
    func testAWorkspaceProviderIsSentNoDescriptorsButKeepsItsFrame() async {
        let provider = ScriptedChatProvider([[.finished(.endTurn)]])
        provider.toolReach = .workspace(summary: "Full access to now")
        let harness = makeHarness(provider: provider)
        let log = EventLog()

        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("build the guest")],
            addressing: nil, origin: .hostPane, events: log.sink)
        _ = log.wait(self)

        XCTAssertTrue(provider.requests[0].tools.isEmpty)
        XCTAssertTrue(
            provider.requests[0].system.contains("Full access to now"),
            provider.requests[0].system)
    }

    /// The harness's own loop is unchanged for the four providers that
    /// use it — and it is sent the WHOLE registry, project rows and all.
    func testAHarnessProviderIsSentEveryRegistryRow() async {
        let provider = ScriptedChatProvider([[.finished(.endTurn)]])
        let harness = makeHarness(provider: provider)
        let log = EventLog()

        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("hello")],
            addressing: nil, origin: .hostPane, events: log.sink)
        _ = log.wait(self)

        let names = Set(provider.requests[0].tools.map(\.name))
        XCTAssertEqual(names.count,
                       HostProjectionRegistry.hostFaces.projections.count)
        XCTAssertTrue(names.contains("now_development"))
    }

    func testToolSchemasCarryNoTopLevelCombinators() throws {
        // The Anthropic API rejects a top-level oneOf/anyOf/allOf/not
        // in input_schema (metal, 2026-08-02: now_launch_software
        // 400ed every turn). Asked of the real registry so row
        // twenty-seven is covered the day it lands.
        for descriptor in ChatToolRendering.descriptors() {
            let schema = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: descriptor.inputSchemaJSON) as? [String: Any])
            for combinator in ["oneOf", "anyOf", "allOf", "not"] {
                XCTAssertNil(
                    schema[combinator],
                    "\(descriptor.name) exposes a top-level \(combinator)")
            }
            XCTAssertNotNil(schema["type"])
        }
    }

    func testToolDescriptorsCarryNoGuestParameter() throws {
        let descriptors = ChatToolRendering.descriptors()
        XCTAssertFalse(descriptors.isEmpty)
        for descriptor in descriptors {
            let schema = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: descriptor.inputSchemaJSON) as? [String: Any])
            let properties = schema["properties"] as? [String: Any] ?? [:]
            XCTAssertNil(
                properties["guest"],
                "\(descriptor.name) exposes guest addressing to the model; "
                    + "the chat face pins it per conversation")
        }
    }

    /// **The prompt is rebuilt per turn, not captured when the pane
    /// opened.** A pane is routinely open before anything dials in, and a
    /// prompt composed once would go on telling the model there is no
    /// machine for the rest of the session — worse than saying nothing,
    /// because the model then refuses tools that would now work.
    func testAMachineThatConnectsAfterTheFirstTurnReachesTheNextPrompt()
        async {
        let provider = ScriptedChatProvider([
            [.textDelta("Nothing to look at."), .finished(.endTurn)],
            [.textDelta("Looking."), .finished(.endTurn)],
        ])
        let registry = ChatProviderRegistry()
        registry.register(provider)
        let connected = Connected()
        let harness = ChatHarness(
            registry: registry,
            makeClient: { _ in
                StubMachineClient(access: .fullAccess,
                                  isConnected: connected.value)
            },
            audit: AuditSpy())

        let first = EventLog()
        await harness.run(
            conversation: "t", wireModelID: "fake/m",
            transcript: [.user("what is connected?")],
            addressing: nil, origin: .hostPane, events: first.sink)
        _ = first.wait(self)

        connected.value = true

        let second = EventLog()
        await harness.run(
            conversation: "t2", wireModelID: "fake/m",
            transcript: [.user("what is connected now?")],
            addressing: nil, origin: .hostPane, events: second.sink)
        _ = second.wait(self)

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(
            provider.requests[0].system.contains(
                "no \(MachineNaming.commonNoun) is connected"),
            provider.requests[0].system)
        XCTAssertTrue(provider.requests[1].system.contains("pb1400c"),
                      provider.requests[1].system)
        XCTAssertFalse(
            provider.requests[1].system.contains(
                "no \(MachineNaming.commonNoun) is connected"),
            provider.requests[1].system)
    }
}
