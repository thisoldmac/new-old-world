import XCTest
@testable import Host
import NOWAgentIntegration

/// The catalog-search capability's own coverage, aimed at the three things
/// that are genuinely its own: **the cost, the bound, and the difference
/// between an answer that is narrower and one that is shorter.**
///
/// `catsearch` is a measurement, not a query — it takes no arguments and
/// returns no listing — so most of what could go wrong here is the host
/// mis-stating what a sweep found. The fake guest below is therefore free to
/// answer the shapes a real one does: a complete sweep, a volume with no
/// CatSearch at all (three rows and no sweep), a sweep that gave up, a
/// refusal, and silence.
@MainActor
final class AgentIntegrationCatalogSearchTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    /// The rows a healthy PowerBook answers, abbreviated but in the guest's
    /// own shape and order (`now-guest-ppc/src/files/catsearch.c`).
    private static let completeSweep: [[String]] = [
        ["Volume", "Macintosh HD (vRefNum -1)"],
        ["On disk", "21874 files, 1902 folders"],
        ["CatSearch", "supported (vMAttrib)"],
        ["Cold sweep", "228 ticks = 3.8 s, 16 slices"],
        ["Longest slice", "15 ticks (budget 15)"],
        ["APPL hits", "412"],
        ["First hits", "SimpleText, Finder, ResEdit"],
        ["Warm sweep", "61 ticks = 1.0 s, 5 slices"],
    ]

    /// What a volume without CatSearch answers: three rows, and no sweep ran
    /// at all. Narrower than a complete answer, not a shortened one.
    private static let noCatSearch: [[String]] = [
        ["Volume", "Server Share (vRefNum -3)"],
        ["On disk", "0 files, 0 folders"],
        ["CatSearch", "NOT supported (vMAttrib)"],
    ]

    /// Answers `catsearch` from a closure, and records how many times it was
    /// asked. Everything else is ignored, the way an unknown command is.
    private func installResponder(
        on guest: FakeGuest,
        asked: Counter = Counter(),
        answer: @escaping (Int) -> CommandResult?
    ) {
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "catsearch" else { return }
            asked.value += 1
            guard let reply = answer(asked.value) else { return }
            try? guest.send(.commandResult(.init(
                id: request.id, ok: reply.ok, output: reply.output,
                error: reply.error)))
        }
    }

    private func ok(_ rows: [[String]]) -> CommandResult {
        .init(id: 0, ok: true, output: ["catsearch": rows], error: nil)
    }

    private func rows(
        _ result: AgentIntegrationGuestRowReportResult
    ) throws -> [AgentIntegrationGuestRow] {
        guard case .completed(let report) = result else {
            throw UnexpectedTestResult(
                description: "expected a completed measurement: \(result)")
        }
        XCTAssertEqual(report.verb, "catsearch")
        XCTAssertEqual(report.groups.count, 1,
                       "catsearch answers one named group, not several.")
        XCTAssertEqual(report.groups.first?.name, "catsearch")
        return report.groups.first?.rows ?? []
    }

    // MARK: - Rendering, and not interpreting

    /// The guest's rows cross back verbatim and in order.
    ///
    /// The assertion that matters is the ORDER and the WORDING: a host that
    /// sorted these, or turned "supported (vMAttrib)" into a boolean, would
    /// be answering a question about the machine out of its own state and
    /// would go stale the first time the guest reworded a row.
    func testTheGuestsRowsCrossBackVerbatimAndInOrder() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] _ in ok(Self.completeSweep) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.measureCatalogSearch()

        let rendered = try rows(result)
        XCTAssertEqual(rendered.map(\.label),
                       Self.completeSweep.map { $0[0] })
        XCTAssertEqual(rendered.map(\.value),
                       Self.completeSweep.map { $0[1] })
        guard case .completed(let report) = result else { return }
        XCTAssertNil(report.note,
                     "Nothing was bounded, so nothing claims to have been.")
    }

    /// **A volume with no CatSearch answers three rows, and that is a
    /// COMPLETE answer to a narrower question.**
    ///
    /// The guest's documented fallback: `GetVolParms` without
    /// `bHasCatSearch` returns before any sweep runs. The host must not
    /// report it as a failure, must not pad it out to look like a sweep, and
    /// must not add a field of its own saying which path ran — the guest's own
    /// `CatSearch` row says so, which is what a caller reads.
    func testAVolumeWithoutCatSearchIsANarrowerAnswerNotAFailure()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] _ in ok(Self.noCatSearch) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let rendered = try rows(await adapter.measureCatalogSearch())

        XCTAssertEqual(rendered.count, 3)
        XCTAssertEqual(rendered.last?.label, "CatSearch")
        XCTAssertEqual(rendered.last?.value, "NOT supported (vMAttrib)",
                       "The row that says which path produced this answer "
                           + "is the guest's own, and it must survive "
                           + "unedited — it is the only thing telling a "
                           + "caller no sweep ran.")
    }

    /// A sweep that gave up says so in its own rows, and the hit count says
    /// it is incomplete. Same rule: the host carries it, does not restate it.
    func testAnIncompleteSweepKeepsTheGuestsOwnAccountOfWhyItStopped()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let gaveUp: [[String]] = [
            ["Volume", "Macintosh HD (vRefNum -1)"],
            ["On disk", "98211 files, 7440 folders"],
            ["CatSearch", "supported (vMAttrib)"],
            ["Cold sweep", "1204 ticks = 20.1 s, 74 slices"],
            ["Longest slice", "38 ticks (budget 15)"],
            ["APPL hits", "1180 (incomplete)"],
            ["Outcome", "gave up after 20 s"],
        ]
        installResponder(on: guest) { [self] _ in ok(gaveUp) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let rendered = try rows(await adapter.measureCatalogSearch())

        XCTAssertEqual(rendered.map(\.label).last, "Outcome")
        XCTAssertEqual(rendered.first { $0.label == "APPL hits" }?.value,
                       "1180 (incomplete)")
    }

    // MARK: - The bound, made visible

    /// **A bound that bites says so.** The ceiling is the guest's own row
    /// buffer, so it cannot bite today — which is exactly why the note is
    /// tested against a guest that answers past it rather than assumed.
    func testAnAnswerPastTheBoundIsShortenedAndTheReportSaysSo()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let overlong = (1...20).map { ["Row \($0)", "value \($0)"] }
        installResponder(on: guest) { [self] _ in ok(overlong) }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.measureCatalogSearch()

        let rendered = try rows(result)
        XCTAssertEqual(
            rendered.count,
            AgentIntegrationCatalogSearchPolicy.maximumRows,
            "The bound is the guest's own buffer size; 20 rows is more "
                + "than a catsearch can produce and must still not be "
                + "silently truncated.")
        guard case .completed(let report) = result else { return }
        XCTAssertEqual(report.note,
                       AgentIntegrationCatalogSearchPolicy
                           .truncationNote(answered: 20))
        XCTAssertEqual(rendered.first?.label, "Row 1",
                       "The bound drops the TAIL. The rows that say which "
                           + "path produced the answer are the first three, "
                           + "so they can never be the ones lost.")
    }

    /// Label and value are bounded to what the machine's own row struct can
    /// hold, so a guest sending more cannot widen this side's answer.
    func testLabelAndValueAreBoundedToTheGuestsOwnRowSize() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let policy = AgentIntegrationCatalogSearchPolicy.self
        installResponder(on: guest) { [self] _ in
            ok([[String(repeating: "L", count: 200),
                 String(repeating: "V", count: 500)]])
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let rendered = try rows(await adapter.measureCatalogSearch())

        XCTAssertEqual(rendered.first?.label.count,
                       policy.maximumLabelScalars)
        XCTAssertEqual(rendered.first?.value.count,
                       policy.maximumValueScalars)
    }

    // MARK: - Refusals, and the cost the machine already spent

    /// A guest refusal stays a refusal and keeps the guest's own code.
    func testAGuestRefusalKeepsItsOwnCodeAndClaimsNoMeasurement()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { _ in
            .init(id: 0, ok: false, output: nil,
                  error: .init(code: "catsearch-failed",
                               message: "no boot volume (err -35)"))
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .refused(let failure) =
            await adapter.measureCatalogSearch() else {
            return XCTFail("a guest refusal must remain a refusal")
        }
        XCTAssertEqual(failure.code, "catsearch-failed")
        XCTAssertEqual(failure.message, "no boot volume (err -35)")
    }

    /// `ok` with nothing under the verb's key is refused, not reported as a
    /// sweep that found nothing. "The disk has no applications" and "the
    /// answer did not arrive in the declared shape" are different facts and
    /// only the first is about the machine.
    func testAnOkAnswerWithNoRowsIsRefusedRatherThanReportedAsEmpty()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { _ in
            .init(id: 0, ok: true, output: ["something": [["a", "b"]]],
                  error: nil)
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .refused(let failure) =
            await adapter.measureCatalogSearch() else {
            return XCTFail("an unshaped answer is not a measurement")
        }
        XCTAssertEqual(failure.code, "now-catsearch-invalid")
    }

    /// **A second sweep while one is running is refused, and the machine is
    /// asked exactly once.** The guest is cooperatively scheduled: two sweeps
    /// would not run concurrently, they would make the first one's timings
    /// meaningless.
    func testASecondMeasurementIsRefusedWhileOneIsStillRunning()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let asked = Counter()
        // Never answers, so the first measurement is still in flight.
        installResponder(on: guest, asked: asked) { _ in nil }
        let adapter = AgentIntegrationHostAdapter(
            listener: listener, catalogSearchTimeout: 30)
        let first = Task { await adapter.measureCatalogSearch() }
        try await waitUntil("the guest to be asked") { asked.value == 1 }

        guard case .refused(let failure) =
            await adapter.measureCatalogSearch() else {
            first.cancel()
            return XCTFail("a second sweep must be refused, not queued")
        }
        XCTAssertEqual(failure.code, "now-catsearch-busy")
        XCTAssertEqual(asked.value, 1,
                       "The refusal must happen on this side; the machine "
                           + "is already busy with the first sweep.")
        first.cancel()
    }

    /// A guest that never answers inside the bound is refused with an
    /// outcome nobody knows — not reported as a measurement of nothing.
    func testAGuestThatNeverAnswersIsRefusedWithAnUnknownOutcome()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { _ in nil }
        let adapter = AgentIntegrationHostAdapter(
            listener: listener, catalogSearchTimeout: 0.2)

        guard case .refused(let failure) =
            await adapter.measureCatalogSearch() else {
            return XCTFail("silence is not a measurement")
        }
        XCTAssertEqual(failure.code, "now-catsearch-outcome-unknown")
    }

    /// No guest, no answer about a guest — `unavailable`, not a refusal.
    func testADisconnectedGuestIsUnavailableRatherThanRefused() async {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let result = await AgentIntegrationHostAdapter(
            listener: disconnected).measureCatalogSearch()

        guard case .unavailable(let missing) = result else {
            return XCTFail("a disconnected guest cannot refuse anything")
        }
        XCTAssertEqual(missing.code, "now-guest-unavailable")
    }

    // MARK: - PowerPC only, and typed

    /// **Unavailability is derived from the guest's own command table.**
    ///
    /// The 68K guest has no `catsearch`, and this is how the surface says so:
    /// the same code, two guests, opposite answers, with nothing reading a
    /// hello name. There is deliberately no reduced form of the tool for the
    /// guest that lacks the verb.
    func testTheToolIsUnavailableAgainstAGuestWhoseTableLacksTheVerb()
        async throws {
        for (commands, expected) in [
            (["help", "ps", "ls"], AgentIntegrationCapabilityState
                .unavailable),
            (["help", "ps", "catsearch"], .available),
        ] as [([String], AgentIntegrationCapabilityState)] {
            let (listener, guest) = try await connectedListener()
            guest.onMessage = { message in
                switch message {
                case .commandRequest(let request)
                    where request.name == "help":
                    try? guest.send(.commandResult(.init(
                        id: request.id, ok: true,
                        output: ["help": commands.map { [$0, "a verb"] }],
                        error: nil)))
                /* The report probes two read-only FAMILIES on its way to the
                   answer, and a guest that never answers them costs this
                   test their two 30 s watchdogs to prove nothing about a
                   command table. Answering them empty settles the probes at
                   once and leaves the assertion on its own subject. */
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
                return XCTFail("expected a capability report")
            }
            let tool = value.tools.first {
                $0.tool == "now_catalog_search"
            }
            XCTAssertEqual(tool?.state, expected,
                           "commands \(commands) should make the tool "
                               + "\(expected)")
            if expected == .unavailable {
                XCTAssertEqual(tool?.missing, ["catsearch"])
            }
            guest.connection.cancel()
            listener.stop()
        }
    }

    /// The cost decision, pinned where it can be argued with.
    ///
    /// `catsearch` is a COMMAND, so its availability comes off `help` and no
    /// report can spend the machine's forty seconds incidentally — which is
    /// what `software.list`'s `probeCostly` flag exists to prevent for a
    /// message FAMILY. A row here would mean this requirement had been
    /// mistaken for a family, and the gate that catches the opposite mistake
    /// cannot catch this one.
    func testTheCostlyCommandOwesNoFamilyPolicyRow() {
        XCTAssertEqual(
            CatalogSearchProjection.requires,
            [AgentIntegrationCapabilityNames.catsearchCommand])
        XCTAssertEqual(
            CatalogSearchProjection.exposes,
            [AgentIntegrationCapabilityNames.catsearchCommand],
            "The measurement IS the answer; nothing about catsearch is "
                + "consumed internally.")
        XCTAssertFalse(
            AgentIntegrationCapabilityLedger.familyPolicy.contains {
                $0.family
                    == AgentIntegrationCapabilityNames.catsearchCommand
            },
            "A command with a familyPolicy row would be accounted for "
                + "twice and would suggest the ledger could probe it, "
                + "which is the one thing this capability's cost argument "
                + "rests on being impossible.")
    }

    // MARK: - The projection's own bound

    /// It takes nothing, and a caller sending anything is told so before a
    /// Macintosh spends a second on it.
    func testTheProjectionAcceptsNoArguments() async {
        let refused: [Any?] = [
            ["path": "Macintosh HD:"],
            ["volume": "Macintosh HD:"],
            ["probeCostly": true],
            "catsearch",
            [1, 2, 3],
        ]
        for raw in refused {
            let outcome = await CatalogSearchProjection.invoke(
                .init(raw: raw), through: CatalogSearchStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "accepted \(String(describing: raw)) as arguments")
            }
            XCTAssertEqual(message, "now_catalog_search accepts no arguments")
        }
    }

    /// Absent and empty both pass, the host is asked once, and the rows it
    /// answered are the rows the caller reads.
    func testAnEmptyCallReachesTheHostAndTheRowsSurvive() async throws {
        for raw in [nil, [String: Any]()] as [Any?] {
            let host = CatalogSearchStubHost()
            let outcome = await CatalogSearchProjection.invoke(
                .init(raw: raw), through: host)

            guard case .value(let value) = outcome else {
                return XCTFail("an argument-free call should reach the host")
            }
            let calls = await host.calls
            XCTAssertEqual(calls, 1)
            let json = String(
                decoding: try value.encoded(using: JSONEncoder()),
                as: UTF8.self)
            XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
            XCTAssertTrue(json.contains("NOT supported (vMAttrib)"),
                          "The guest's own words reach the caller unedited.")
            XCTAssertNil(
                value.attachment,
                "This row answers in JSON; only capture attaches anything.")
        }
    }

    /// The description prices the call before a caller makes it, and the
    /// annotations do not promise a free retry. Both are the whole of what
    /// this row does about its cost, so both are gated.
    func testTheDescriptorPricesTheCallAndDoesNotClaimIdempotence() throws {
        let descriptor = CatalogSearchProjection.operationDescriptor.mcpToolDescriptor
        let description = try XCTUnwrap(
            descriptor["description"] as? String)
        XCTAssertTrue(description.contains("EXPENSIVE"))
        XCTAssertTrue(description.contains("20 s per pass"),
                      "A caller must be able to price the call from the "
                          + "description alone.")
        let annotations = try XCTUnwrap(
            descriptor["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(
            annotations["idempotentHint"] as? Bool, false,
            "A second call is a second forty seconds and answers different "
                + "numbers, because the warm pass rides the cold pass's "
                + "cache. Claiming idempotence invites a free retry.")
        XCTAssertNil(
            (descriptor["inputSchema"] as? [String: Any])?["required"],
            "Nothing is required because nothing is accepted.")
    }
}

/// Answers one measurement and counts the calls. Everything else says "no
/// host", which is what the client protocol's defaults are for.
private actor CatalogSearchStubHost: AgentIntegrationClient {
    private(set) var calls = 0

    func catalogSearch() async -> AgentIntegrationGuestRowReportResult {
        calls += 1
        return .completed(.init(
            verb: "catsearch",
            groups: [.init(name: "catsearch", rows: [
                .init(label: "Volume", value: "Server Share (vRefNum -3)"),
                .init(label: "CatSearch",
                      value: "NOT supported (vMAttrib)"),
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
