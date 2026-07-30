import XCTest
@testable import Host
import NOWAgentIntegration

/// The diagnostics capability's own coverage, aimed at the two things that
/// are genuinely its own: **that the three rows can differ in availability**,
/// and **that "this Mac does not serve it" is an answer rather than a
/// failure**.
///
/// The rest — rows crossing back unedited, a bound on the wait, a busy guard —
/// is the shape `catsearch` established, and it is checked here against these
/// verbs rather than assumed to have carried over.
@MainActor
final class AgentIntegrationDiagnosticsTests: XCTestCase {

    /// An abbreviated `vprobe`, in the guest's own shape and order
    /// (`now-guest-ppc/src/census/vprobe.c`, `n68_vprobe.h`).
    private static let vprobeRows: [[String]] = [
        ["Screen", "640x480, 8-bit"],
        ["CopyBits", "best 118.4 ms"],
        ["Raw 32-bit", "1st 132.9 / best 121.7 ms"],
        ["Reread", "no cache (within 2%)"],
        ["Partial 480 rows", "linear"],
        ["Fidelity", "480/480 rows match"],
        ["Addressing", "24-bit, 32-bit for reads"],
    ]

    /// `putstat` on a machine that has received nothing this launch. Its own
    /// zeroes, which are a real answer and not an absence.
    private static let idlePutstatRows: [[String]] = [
        ["Bytes", "0"],
        ["Chunks", "0"],
        ["Writes", "0"],
        ["In FSWrite", "0 ms"],
        ["In receive", "0 ms"],
        ["Resumed from", "0"],
    ]

    private final class Counter {
        var value = 0
    }

    /// Answers one verb from a closure and counts the asks. Everything else
    /// is ignored, the way a guest ignores nothing — an unanswered command is
    /// how this suite tests the bound.
    private func installResponder(
        on guest: FakeGuest,
        verb: String,
        asked: Counter = Counter(),
        answer: @escaping (Int) -> CommandResult?
    ) {
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == verb else { return }
            asked.value += 1
            guard let reply = answer(asked.value) else { return }
            try? guest.send(.commandResult(.init(
                id: request.id, ok: reply.ok, output: reply.output,
                error: reply.error)))
        }
    }

    private func ok(_ verb: String, _ rows: [[String]]) -> CommandResult {
        .init(id: 0, ok: true, output: [verb: rows], error: nil)
    }

    private func rows(
        _ result: AgentIntegrationGuestRowReportResult, verb: String
    ) throws -> [AgentIntegrationGuestRow] {
        guard case .completed(let report) = result else {
            throw XCTSkip("expected a completed measurement: \(result)")
        }
        XCTAssertEqual(report.verb, verb)
        XCTAssertEqual(report.groups.count, 1,
                       "a diagnostic answers one named group, not several.")
        XCTAssertEqual(report.groups.first?.name, verb)
        return report.groups.first?.rows ?? []
    }

    // MARK: - Rendering, and not interpreting

    /// The guest's rows cross back verbatim and in order.
    ///
    /// The wording is the assertion. A host that turned `CopyBits best 118.4
    /// ms` into a number, or `Addressing 24-bit` into a flag, would be
    /// answering for the machine — and it is exactly the row a reader is most
    /// tempted to interpret, since a CopyBits failure here has already been
    /// misread as a capture defect.
    func testTheGuestsRowsCrossBackVerbatimAndInOrder() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, verb: "vprobe") { [self] _ in
            ok("vprobe", Self.vprobeRows)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.runDiagnostic(.vprobe)

        let rendered = try rows(result, verb: "vprobe")
        XCTAssertEqual(rendered.map(\.label), Self.vprobeRows.map { $0[0] })
        XCTAssertEqual(rendered.map(\.value), Self.vprobeRows.map { $0[1] })
        guard case .completed(let report) = result else { return }
        XCTAssertNil(report.note,
                     "Nothing was bounded, so nothing claims to have been.")
    }

    /// **`putstat`'s zeroes are a completed answer**, not an empty one.
    ///
    /// The one verb here whose honest answer looks like nothing happened. A
    /// host that read an all-zero counter set as "no measurement" would
    /// refuse a call the machine answered perfectly well.
    func testIdleTransferCountersAreACompletedAnswerNotAnAbsence()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, verb: "putstat") { [self] _ in
            ok("putstat", Self.idlePutstatRows)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let rendered = try rows(await adapter.runDiagnostic(.putstat),
                                verb: "putstat")

        XCTAssertEqual(rendered.count, Self.idlePutstatRows.count)
        XCTAssertEqual(rendered.first?.value, "0",
                       "The guest's zero is the guest's answer and reaches "
                           + "the caller as one.")
    }

    /// A guest answering past the bound says so in `note`, and no row the
    /// guest sent is silently dropped from what a caller can see it kept.
    func testAnAnswerPastTheBoundSaysSoRatherThanShrinkingQuietly()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let over = (1...24).map { ["Row \($0)", "value \($0)"] }
        installResponder(on: guest, verb: "vprobe") { [self] _ in
            ok("vprobe", over)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.runDiagnostic(.vprobe)

        let rendered = try rows(result, verb: "vprobe")
        XCTAssertEqual(rendered.count,
                       AgentIntegrationDiagnosticsPolicy.maximumRows)
        guard case .completed(let report) = result else { return }
        let note = try XCTUnwrap(report.note)
        XCTAssertTrue(note.contains("24"),
                      "The note says what the guest answered, so the "
                          + "shortfall is visible: \(note)")
        XCTAssertTrue(note.contains("host"),
                      "The bound is the HOST's and the sentence says so — "
                          + "this field is otherwise the guest's own words.")
    }

    /// A short `[label]` pair is rendered with an empty value rather than
    /// dropped: a row the guest sent and the host removed is the failure the
    /// bound's own note exists to avoid, one row down.
    func testAShortRowKeepsItsLabelRatherThanVanishing() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, verb: "shotdiag") { [self] _ in
            ok("shotdiag", [["Base"], ["Stripped", "0x00FA8000"]])
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let rendered = try rows(await adapter.runDiagnostic(.shotdiag),
                                verb: "shotdiag")

        XCTAssertEqual(rendered.map(\.label), ["Base", "Stripped"])
        XCTAssertEqual(rendered.first?.value, "")
    }

    // MARK: - "Not here" is an answer

    /// **A guest without the verb refuses it by name, and that refusal is the
    /// CALL's — with the guest's own code.**
    ///
    /// This is the route a caller learns availability by if it did not ask
    /// first, and it must not arrive as a completed measurement of nothing:
    /// the machine never ran a diagnostic, it declined to recognise a verb.
    func testAGuestWithoutTheVerbRefusesItInItsOwnWords() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, verb: "shotdiag") { _ in
            .init(id: 0, ok: false, output: nil,
                  error: .init(code: "unknown-command",
                               message: "shotdiag: no such command"))
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .refused(let failure) =
            await adapter.runDiagnostic(.shotdiag) else {
            return XCTFail("a guest that lacks the verb has refused, and "
                               + "that is not a completed measurement")
        }
        XCTAssertEqual(failure.code, "unknown-command",
                       "The guest's own code, not one invented here.")
        XCTAssertEqual(failure.message, "shotdiag: no such command")
    }

    /// `ok: true` with no rows under the verb's key is refused rather than
    /// reported as a measurement of nothing — which matters most for
    /// `putstat`, whose zeroes are a real answer and would be
    /// indistinguishable.
    func testAnAnswerInTheWrongShapeIsRefusedRatherThanReadAsEmpty()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, verb: "putstat") { _ in
            .init(id: 0, ok: true, output: ["stats": []], error: nil)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .refused(let failure) =
            await adapter.runDiagnostic(.putstat) else {
            return XCTFail("an answer in an undeclared shape is not a "
                               + "measurement")
        }
        XCTAssertEqual(failure.code, "now-diagnostic-invalid")
    }

    // MARK: - The bound, and the lane

    /// Silence inside the bound is refused with an outcome nobody knows.
    func testAGuestThatNeverAnswersIsRefusedWithAnUnknownOutcome()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, verb: "vprobe") { _ in nil }
        let adapter = AgentIntegrationHostAdapter(
            listener: listener, diagnosticsTimeout: 0.2)

        guard case .refused(let failure) =
            await adapter.runDiagnostic(.vprobe) else {
            return XCTFail("silence is not a measurement")
        }
        XCTAssertEqual(failure.code, "now-diagnostic-outcome-unknown")
    }

    /// **The busy guard is per LANE, not per verb.**
    ///
    /// A `vprobe` still running holds the machine's framebuffer, so a
    /// `shotdiag` asked for meanwhile is refused rather than queued: two
    /// full-screen reads at once on a cooperatively-scheduled Mac are the
    /// first one's numbers made meaningless. A per-verb guard would have let
    /// exactly that through.
    func testASecondDiagnosticIsRefusedWhileAnotherVerbIsStillRunning()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        // Nothing answers, so the first run is still in flight when the
        // second is asked; its own bound is short so the test does not wait.
        guest.onMessage = { _ in }
        let adapter = AgentIntegrationHostAdapter(
            listener: listener, diagnosticsTimeout: 1.5)

        async let first = adapter.runDiagnostic(.vprobe)
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = await adapter.runDiagnostic(.shotdiag)

        guard case .refused(let failure) = second else {
            return XCTFail("a second diagnostic mid-run is not a "
                               + "measurement")
        }
        XCTAssertEqual(failure.code, "now-diagnostic-busy")
        _ = await first
    }

    /// No guest, no answer about a guest — `unavailable`, not a refusal.
    func testADisconnectedGuestIsUnavailableRatherThanRefused() async {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let result = await AgentIntegrationHostAdapter(
            listener: disconnected).runDiagnostic(.putstat)

        guard case .unavailable(let missing) = result else {
            return XCTFail("a disconnected guest cannot refuse anything")
        }
        XCTAssertEqual(missing.code, "now-guest-unavailable")
    }

    // MARK: - The crux: three rows, and why not one

    /// **Each row requires exactly one command**, which is what lets the
    /// three differ in availability.
    ///
    /// The whole design decision, pinned where it can be argued with. A row
    /// requiring two of these verbs would be `unavailable` wherever either is
    /// missing, and no guest serves all three — so a single row requiring the
    /// trio would be permanently unavailable against every Macintosh that
    /// exists, in a sentence that reads as a fact about the machine. The next
    /// test proves that consequence against the ledger rather than asserting
    /// it here.
    func testEachRowRequiresAndExposesExactlyItsOwnCommand() {
        let names = AgentIntegrationCapabilityNames.self
        let rows: [(any HostProjection.Type, String)] = [
            (FramebufferProbeProjection.self, names.vprobeCommand),
            (CaptureDiagnosticsProjection.self, names.shotdiagCommand),
            (TransferDiagnosticsProjection.self, names.putstatCommand),
        ]
        for (row, verb) in rows {
            XCTAssertEqual(
                row.requires, [verb],
                "\(row.capability) must require its own verb and nothing "
                    + "else: requires is a conjunction, so a second entry "
                    + "would switch the row off wherever that verb is "
                    + "absent — and these three are never all present.")
            XCTAssertEqual(
                row.exposes, [verb],
                "The measurement IS the answer; nothing about these verbs "
                    + "is consumed internally.")
            XCTAssertTrue(
                AgentIntegrationCapabilityNames.all.contains(verb),
                "\(verb) must be declared in "
                    + "AgentIntegrationCapabilityNames, or an unknown "
                    + "requirement reads as a missing command and the row "
                    + "is off against every guest with nothing failing.")
            XCTAssertFalse(
                AgentIntegrationCapabilityLedger.familyPolicy.contains {
                    $0.family == verb
                },
                "\(verb) is a COMMAND. A familyPolicy row would account for "
                    + "it twice and suggest the ledger could probe it, when "
                    + "its availability comes off `help` for free.")
        }
        XCTAssertEqual(
            Set(rows.map { $0.0.capability.rawValue }).count, 3,
            "Three capabilities, three names.")
    }

    /// **Availability is derived per row from the guest's own command table,
    /// and the three answers differ on one machine.**
    ///
    /// The same code, two guests, opposite answers, with nothing reading a
    /// hello name — and this is the assertion that a one-row design could not
    /// have satisfied: on each table, one row is available and another is not.
    func testTheThreeRowsResolveDifferentlyAgainstOneCommandTable()
        async throws {
        let tables: [(String, [String], [String: AgentIntegrationCapabilityState])] = [
            ("the 68K guest's table",
             ["help", "ps", "ls", "vprobe", "shotdiag"],
             ["now_framebuffer_probe": .available,
              "now_capture_diagnostics": .available,
              "now_transfer_diagnostics": .unavailable]),
            ("the Carbon guest's table",
             ["help", "ps", "ls", "vprobe", "putstat", "catsearch"],
             ["now_framebuffer_probe": .available,
              "now_capture_diagnostics": .unavailable,
              "now_transfer_diagnostics": .available]),
            ("a build older than all three",
             ["help", "ps", "ls"],
             ["now_framebuffer_probe": .unavailable,
              "now_capture_diagnostics": .unavailable,
              "now_transfer_diagnostics": .unavailable]),
        ]
        for (label, commands, expected) in tables {
            let (listener, guest) = try await connectedListener()
            guest.onMessage = { message in
                switch message {
                case .commandRequest(let request)
                    where request.name == "help":
                    try? guest.send(.commandResult(.init(
                        id: request.id, ok: true,
                        output: ["help": commands.map { [$0, "a verb"] }],
                        error: nil)))
                /* The report probes two read-only FAMILIES on the way to its
                   answer; answering them empty settles the probes at once
                   and leaves the assertion on its own subject. */
                case .processList(let request):
                    try? guest.send(.processListing(.init(
                        id: request.id, processes: [], more: false,
                        cursor: nil)))
                case .fileList(let request):
                    try? guest.send(.fileListing(.init(
                        id: request.id, path: request.path, entries: [],
                        more: false, cursor: nil, root: nil)))
                default:
                    return
                }
            }
            let adapter = AgentIntegrationHostAdapter(listener: listener)

            let report = await adapter.sessionCapabilities()

            guard case .available(let value) = report else {
                guest.connection.cancel()
                listener.stop()
                return XCTFail("expected a capability report for \(label)")
            }
            for (tool, state) in expected {
                let row = value.tools.first { $0.tool == tool }
                XCTAssertEqual(row?.state, state,
                               "\(tool) against \(label)")
            }
            guest.connection.cancel()
            listener.stop()
        }
    }

    // MARK: - The projections' own bounds

    /// None of the three takes an argument, and a caller sending one is told
    /// so before a Macintosh spends a full-screen read on it.
    func testTheProjectionsAcceptNoArguments() async {
        let rows: [any HostProjection.Type] = [
            FramebufferProbeProjection.self,
            CaptureDiagnosticsProjection.self,
            TransferDiagnosticsProjection.self,
        ]
        let refused: [Any?] = [
            ["probe": "vprobe"],
            ["depth": 8],
            "vprobe",
            [1, 2, 3],
        ]
        for row in rows {
            for raw in refused {
                let outcome = await row.invoke(
                    .init(raw: raw), through: DiagnosticsStubHost())
                guard case .invalidArguments(let message) = outcome else {
                    return XCTFail("\(row.capability) accepted "
                                       + "\(String(describing: raw))")
                }
                XCTAssertEqual(
                    message, "\(row.capability.rawValue) accepts no arguments")
            }
        }
    }

    /// Absent and empty both pass, each row asks for **its own** probe, and
    /// the guest's words reach the caller.
    func testEachRowSendsItsOwnProbeAndTheRowsSurvive() async throws {
        let expected: [(any HostProjection.Type,
                        AgentIntegrationDiagnosticProbe)] = [
            (FramebufferProbeProjection.self, .vprobe),
            (CaptureDiagnosticsProjection.self, .shotdiag),
            (TransferDiagnosticsProjection.self, .putstat),
        ]
        for (row, probe) in expected {
            for raw in [nil, [String: Any]()] as [Any?] {
                let host = DiagnosticsStubHost()
                let outcome = await row.invoke(
                    .init(raw: raw), through: host)

                guard case .value(let value) = outcome else {
                    return XCTFail("an argument-free call should reach the "
                                       + "host")
                }
                let asked = await host.asked
                XCTAssertEqual(asked, [probe],
                               "\(row.capability) must ask for its own "
                                   + "diagnostic and no other.")
                let json = String(
                    decoding: try value.encoded(using: JSONEncoder()),
                    as: UTF8.self)
                XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
                XCTAssertTrue(json.contains(probe.rawValue))
                XCTAssertNil(
                    value.attachment,
                    "These rows answer in JSON; only capture attaches "
                        + "anything.")
            }
        }
    }

    /// The three descriptors each price the call, and none claims a free
    /// retry — they are measurements.
    func testEachDescriptorPricesItsCallAndClaimsNoIdempotence() throws {
        for row in [FramebufferProbeProjection.self as any HostProjection.Type,
                    CaptureDiagnosticsProjection.self,
                    TransferDiagnosticsProjection.self] {
            let descriptor = row.mcpDescriptor
            let annotations = try XCTUnwrap(
                descriptor["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true,
                           "\(row.capability) changes nothing on the "
                               + "machine.")
            XCTAssertEqual(
                annotations["idempotentHint"] as? Bool, false,
                "\(row.capability) is a measurement: a second call answers "
                    + "different numbers, and a caller told otherwise would "
                    + "be entitled to cache it.")
            XCTAssertNil(
                (descriptor["inputSchema"] as? [String: Any])?["required"],
                "Nothing is required because nothing is accepted.")
        }
    }

    /// **The vprobe/capture distinction is in the published description**,
    /// not only in a doc.
    ///
    /// A `vprobe` on the PowerBook 1400c reported `CopyBits failed` and that
    /// failure does not reproduce through `capture.request`. A caller reading
    /// this tool's answer must not conclude that capture is broken, and the
    /// only place that can reach them is the description they are handed.
    func testTheFramebufferProbeDescriptionRefusesToImplyCaptureIsBroken()
        throws {
        let description = try XCTUnwrap(
            FramebufferProbeProjection.mcpDescriptor["description"]
                as? String)
        XCTAssertTrue(description.contains("CopyBits"))
        XCTAssertTrue(description.contains("different paths"),
                      "The description must say the two paths differ: "
                          + "\(description)")
        let capture = try XCTUnwrap(
            CaptureDiagnosticsProjection.mcpDescriptor["description"]
                as? String)
        XCTAssertTrue(capture.contains("NOT a capture"),
                      "shotdiag stages a capture and produces no image; a "
                          + "caller wanting a picture must be sent "
                          + "elsewhere: \(capture)")
    }
}

/// Answers one measurement per probe and records which were asked for.
/// Everything else says "no host", which is what the client protocol's
/// defaults are for.
private actor DiagnosticsStubHost: AgentIntegrationClient {
    private(set) var asked: [AgentIntegrationDiagnosticProbe] = []

    func runDiagnostic(_ probe: AgentIntegrationDiagnosticProbe) async
        -> AgentIntegrationGuestRowReportResult {
        asked.append(probe)
        return .completed(.init(
            verb: probe.rawValue,
            groups: [.init(name: probe.rawValue, rows: [
                .init(label: "Screen", value: "640x480, 8-bit"),
            ])],
            observedAt: Self.moment))
    }

    /// Fixed so an encode round trip cannot drift on sub-second precision.
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Everything else answers "no host"

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
