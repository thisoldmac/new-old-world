import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// Rule 3 of the parity slice, made mechanical: **a capability invoked by a
/// non-user face emits an audit event.** MCP is an optional feature of NOW,
/// and optional does not mean kneecapped — but a suite of agentic controls
/// opaque to the person at the machine is not what NOW is.
///
/// Two halves, and the second is the gate:
///
/// 1. Every registry row, invoked through the dispatch, emits exactly one
///    event naming itself — including when it refuses.
/// 2. **Nothing outside the dispatch may invoke a projection.** That is what
///    fails when a capability becomes reachable without leaving a trace, and
///    it is the half that cannot be satisfied by remembering to do the right
///    thing in each new face.
final class HostProjectionAuditTests: XCTestCase {

    // MARK: - Every capability, every outcome

    /// One event per invocation, naming the capability and the face, for all
    /// twelve rows — asked of the registry rather than a list here, so a
    /// thirteenth row is covered the moment it is added.
    func testEveryCapabilityEmitsOneEventNamingItself() async {
        for projection in HostProjectionRegistry.hostFaces.projections {
            let spy = AuditSpy()
            let dispatch = HostProjectionDispatch(face: .mcp, audit: spy)
            let outcome = await dispatch.invoke(
                projection.capability.rawValue,
                arguments: .init(raw: nil),
                guest: "pb1400c",
                through: SilentAuditClient())
            XCTAssertNotNil(
                outcome,
                "\(projection.capability) is registered but the dispatch "
                    + "could not find it.")
            let events = await spy.recorded()
            XCTAssertEqual(
                events.count, 1,
                "\(projection.capability) produced \(events.count) audit "
                    + "events for one invocation.")
            XCTAssertEqual(
                events.first?.capability,
                projection.capability.rawValue)
            XCTAssertEqual(events.first?.face, .mcp)
            XCTAssertEqual(events.first?.guest, "pb1400c")
        }
    }

    /// A REFUSED invocation emits, and says so.
    ///
    /// This is the decision worth stating: an attempt that was denied is the
    /// more interesting event, not the less. A person reading the log wants
    /// to see that something asked this machine to quit a process and was
    /// turned away; an audit trail that recorded only what succeeded would
    /// describe a machine nobody had ever tried to drive. It also covers the
    /// one class of outcome the host never sees — an argument refusal is
    /// decided in the companion and no local request is ever sent — so if it
    /// were not emitted here it would be recorded nowhere at all.
    func testARefusedInvocationEmitsWithItsReason() async {
        let spy = AuditSpy()
        let dispatch = HostProjectionDispatch(face: .mcp, audit: spy)
        let outcome = await dispatch.invoke(
            "now_session_health",
            arguments: .init(raw: ["unexpected": 1]),
            guest: nil,
            through: SilentAuditClient())

        guard case .invalidArguments = outcome else {
            return XCTFail("The projection did not refuse the argument.")
        }
        let event = await spy.recorded().first
        XCTAssertEqual(event?.outcome, .refused)
        XCTAssertEqual(event?.reason,
                       "now_session_health accepts no arguments")
        XCTAssertEqual(event?.level, .warn)
    }

    /// An unknown name emits nothing: nothing was invoked, and there is no
    /// capability for a line to be about. The face answers "unknown tool".
    func testAnUnknownCapabilityEmitsNothing() async {
        let spy = AuditSpy()
        let dispatch = HostProjectionDispatch(face: .mcp, audit: spy)
        let outcome = await dispatch.invoke(
            "now_not_a_capability",
            arguments: .init(raw: nil),
            guest: nil,
            through: SilentAuditClient())
        XCTAssertNil(outcome)
        let events = await spy.recorded()
        XCTAssertTrue(events.isEmpty,
                      "An unknown tool name produced \(events).")
    }

    // MARK: - What a person reads

    /// The line says which face, which capability, which machine and what
    /// came of it — and nothing about the arguments. A path, a receipt or a
    /// process reference would put user content and one-use credentials in a
    /// file to answer a question nobody asked of this line.
    func testTheLineNamesFaceCapabilityGuestAndOutcome() {
        let answered = HostProjectionAuditEvent(
            capability: LaunchSoftwareProjection.capability,
            face: .mcp, guest: "pb1400c", outcome: .answered)
        XCTAssertEqual(
            answered.logMessage(),
            "mcp now_launch_software guest=pb1400c answered")

        /* An omitted selector meant "the machine this host is driving", and
           only the host knows which that was. */
        let driven = HostProjectionAuditEvent(
            capability: ListProcessesProjection.capability,
            face: .mcp, guest: nil, outcome: .answered)
        XCTAssertEqual(
            driven.logMessage(drivenGuest: "q950"),
            "mcp now_list_processes guest=q950 answered")
        XCTAssertEqual(
            driven.logMessage(),
            "mcp now_list_processes guest=? answered")
    }

    /// Control bytes are legal in an HFS name and reach this side inside
    /// paths and machine ids. One in a log line corrupts the row the Logs
    /// page draws, so the line escapes them — the same choice the
    /// guest-Files audit text already makes.
    func testControlBytesAreEscapedRatherThanWritten() {
        let event = HostProjectionAuditEvent(
            capability: SessionHealthProjection.capability,
            face: .mcp,
            guest: "pb\u{01}1400c",
            outcome: .refused,
            reason: "refused\u{0A}the argument")
        let line = event.logMessage()
        XCTAssertTrue(line.contains("guest=pb\\x011400c"), line)
        XCTAssertTrue(line.contains("refused\\x0Athe argument"), line)
        XCTAssertFalse(line.contains("\n"), "The line is one row.")
    }

    /// A refusal sentence is bounded at construction, because it travels
    /// inside a 16 KiB local request beside everything else.
    func testAReasonIsBoundedAtConstruction() {
        let event = HostProjectionAuditEvent(
            capability: SessionHealthProjection.capability,
            face: .mcp, guest: nil, outcome: .refused,
            reason: String(repeating: "x", count: 4096))
        XCTAssertEqual(
            event.reason?.unicodeScalars.count,
            HostProjectionAuditEvent.maximumReasonScalars)
    }

    /// The line reaches this side's log in the format docs/logging.md
    /// defines, under the `agent` area.
    @MainActor
    func testTheEventReachesTheHostLogInTheSpecFormat() throws {
        let log = HostLog.shared
        log.setPersistsToDisk(true)
        let url = try XCTUnwrap(log.url)
        AgentIntegrationAuditLog.record(
            HostProjectionAuditEvent(
                capability: RequestQuitProjection.capability,
                face: .mcp, guest: nil, outcome: .refused,
                reason: "now_request_quit accepts one process reference"),
            drivenGuest: "pb1400c")

        let line = try XCTUnwrap(
            String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").last.map(String.init))
        let pattern = #"^\d{2}:\d{2}:\d{2} agent  \? mcp now_request_quit "#
            + #"guest=pb1400c refused: "#
        XCTAssertNotNil(
            line.range(of: pattern, options: .regularExpression),
            "line did not match the spec's format: \(line)")
    }

    // MARK: - The host does not take dictation

    /// The host writes this line into the person's log, so it accepts facts
    /// and not text: a capability no row claims cannot reach the file, which
    /// bounds a same-uid process to inventing events about capabilities that
    /// actually exist — something it could cause for real by calling them.
    func testAnEventNamingNoCapabilityIsRefusedByTheCodec() throws {
        let good = AgentIntegrationLocalRequest.audit(.init(
            capability: SessionHealthProjection.capability,
            face: .mcp, guest: nil, outcome: .answered))
        XCTAssertNoThrow(try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(good)))

        let forged = try forgedAuditRequest(capability: "now_rm_rf")
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(forged)) { error in
            guard case AgentIntegrationLocalTransportError
                .invalidMessage(let message) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("Audit event"), message)
        }
    }

    /// An audit report is not a request about a guest, so it carries no
    /// selection of any kind. The codec refuses one that smuggles a path in
    /// beside the event.
    func testAnAuditReportCarryingASelectionIsRefused() throws {
        var object = try auditObject(capability: "now_session_health")
        object["guestFilePath"] = "Lab:secret"
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(
                try JSONSerialization.data(withJSONObject: object)))
    }

    private func auditObject(capability: String) throws -> [String: Any] {
        [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "audit",
            "auditEvent": [
                "capability": capability,
                "face": "mcp",
                "outcome": "answered",
            ],
        ]
    }

    private func forgedAuditRequest(capability: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: try auditObject(capability: capability))
    }

    // MARK: - The gate

    /// **A face may not reach past the dispatch.**
    ///
    /// One central hook cannot be forgotten by the next capability's author;
    /// a face that called `invoke` on a projection itself would be a
    /// capability reachable with no line in anyone's log, and nothing else
    /// in this tree would notice. So the rule is checked against the source,
    /// the way `LoggingSpecTests` checks the per-chunk rule and
    /// `AgentIntegrationCapabilityTests` checks that nothing branches on
    /// guest identity.
    ///
    /// Verified by mutation: restoring `projection.invoke(...)` in
    /// `NOWMCPServer.callTool` fails this test by file and line.
    ///
    /// **Its limit is the exclusion, and the exclusion is a NAME.** A line
    /// is forgiven when it contains `dispatch.invoke(`, because that is how
    /// every legitimate face spells the call — so a local variable named
    /// `dispatch` holding a projection walks straight through:
    ///
    ///     if let dispatch = registry.projection(named: name) {
    ///         _ = await dispatch.invoke(arguments, through: client)
    ///     }
    ///
    /// That compiles, invokes a capability, emits nothing, and passes
    /// (audited 2026-07-31). It is not the spelling anyone reaches for
    /// first, and it is one shadowed binding away from being it.
    ///
    /// Not fixed here, because no text check can tell what a name is bound
    /// to and a cleverer regex would only move the spelling. The real fix
    /// is a production one and belongs on its own change: `invoke` is
    /// `public` on `HostProjection`, which is what lets a different module
    /// call it at all. Narrow that to the module the dispatch lives in and
    /// the compiler enforces what this test can only ask for.
    func testNothingButTheDispatchInvokesAProjection() throws {
        let dispatch = "HostProjectionDispatch.swift"
        var offenders: [String] = []
        for file in try Self.swiftFiles(
            under: ["now-host/Sources"],
            excluding: [dispatch]) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(
                separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                /* The declaration in the protocol and the rows' own
                   definitions are `func invoke`; only a CALL is the
                   offence. */
                guard line.contains(".invoke("),
                      !line.contains("dispatch.invoke("),
                      !line.contains("func invoke") else { continue }
                offenders.append(
                    "\(file.lastPathComponent):\(number + 1): "
                        + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            A host face invokes a projection directly, so that capability \
            can be driven without emitting an audit event — rule 3 of the \
            parity slice, docs/agent-integration.md. Route it through \
            HostProjectionDispatch.invoke, which emits for every outcome.
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The other half of the same rule: the sink is a required argument, so
    /// a face cannot be assembled without one. This asserts the entry point
    /// actually passes the sink that reaches the person's log rather than
    /// something that drops events — the compiler enforces that one exists,
    /// not that it goes anywhere.
    ///
    /// **Comments stripped**, and this one had the quiet direction. Mutation
    /// on 2026-07-31: pass a sink whose `record` does nothing, and leave
    /// `audit: LocalAuditSink()` in the comment above it. It builds, all 916
    /// tests pass, and every agent-driven action on the machine reaches no
    /// log a person reads — which is the entire property this test names.
    ///
    /// Its sibling above, `testNothingButTheDispatchInvokesAProjection`,
    /// deliberately keeps reading RAW text: it asserts that no line calls
    /// `.invoke(`, so a comment can only ADD an offender — a loud false
    /// failure, never a silent pass — and its failure message reports line
    /// NUMBERS, which stripping would shift off the real source.
    func testTheCompanionEntryPointPassesTheLocalSink() throws {
        let text = try GateSource.hostSwift(
            "now-host/Sources/NOWAgentCompanion/StdioMCP.swift")
        XCTAssertTrue(
            text.contains("audit: LocalAuditSink()"), """
            The companion's entry point does not hand the MCP face the sink \
            that reports to the running host, so its invocations would \
            reach no log a person reads.
            """)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftFiles(under roots: [String],
                                   excluding names: [String]) throws
        -> [URL] {
        var files: [URL] = []
        for root in roots {
            let directory = repoRoot.appendingPathComponent(root)
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      !names.contains(url.lastPathComponent) else { continue }
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty, "Found no source to read.")
        return files
    }
}

/// What a face reported, in order.
private actor AuditSpy: HostProjectionAuditSink {
    private var events: [HostProjectionAuditEvent] = []

    func record(_ event: HostProjectionAuditEvent) async {
        events.append(event)
    }

    func recorded() -> [HostProjectionAuditEvent] { events }
}

/// Answers "no host" to everything, so a projection under test reaches its
/// own bound and its own result without a host or a guest.
private struct SilentAuditClient: AgentIntegrationClient {
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.host)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.host)
    }

    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.host)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.host)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.host)
    }
}
