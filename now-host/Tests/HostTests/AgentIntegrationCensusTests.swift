import XCTest
@testable import Host
import NOWAgentIntegration

/// The hardware census capability's own coverage, aimed at the one thing that
/// is genuinely its own: **a probe's outcome is not the call's outcome.**
///
/// `AgentIntegrationProjectedResult` says whether a Macintosh answered.
/// `census.report`'s `outcome` says what that Macintosh found. The census
/// exists to distinguish "the machine said no" from "we did not look" and both
/// from an answer, and the way to lose all three is to flatten the second level
/// into the first — so most of what follows is a fake guest answering with each
/// word in that vocabulary and this side being held to reporting it as a
/// COMPLETED call.
///
/// The wire is real: the reports below cross a socket through the codec and the
/// listener, so nothing here is a model parsing what it just built.
@MainActor
final class AgentIntegrationCensusTests: XCTestCase {
    // MARK: - Harness

    /// Answers each `census.request` with one scripted report, echoing the
    /// request's id, and records the cursors the host sent.
    @MainActor
    private final class Script {
        var pages: [CensusReport] = []
        private(set) var cursors: [Int?] = []
        private(set) var probes: [String] = []
        private var served = 0
        /// When set, the guest answers with an `error` carrying the request's
        /// id instead of a report — how a guest says it does not implement
        /// the family at all.
        var refuseFamily: (code: String, message: String)?

        func install(on guest: FakeGuest) {
            guest.onMessage = { [weak self, weak guest] message in
                guard let self, let guest,
                      case .censusRequest(let request) = message else {
                    return
                }
                probes.append(request.probe)
                cursors.append(request.cursor)
                if let refusal = refuseFamily {
                    try? guest.send(.error(ErrorMessage(
                        id: request.id, code: refusal.code,
                        message: refusal.message)))
                    return
                }
                let index = served
                served += 1
                guard index < pages.count else { return }
                var report = pages[index]
                report.id = request.id
                try? guest.send(.censusReport(report))
            }
        }
    }

    private func report(
        probe: String = "identity",
        outcome: String = "present",
        rows: [[String]] = [["Model", "$0224", "PowerBook 1400c"]],
        more: Bool = false,
        cursor: Int? = nil,
        total: Int? = nil,
        note: String? = nil
    ) -> CensusReport {
        CensusReport(id: 0, probe: probe, outcome: outcome, rows: rows,
                     more: more, cursor: cursor, total: total, note: note)
    }

    /// Drives one page against a scripted guest and hands back both halves.
    private func page(
        probe: String = "identity",
        cursor: Int? = nil,
        script: Script,
        pageTimeout: TimeInterval = 5
    ) async throws -> AgentIntegrationCensusResult {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        script.install(on: guest)
        /* One stable id for the whole call: the adapter only compares the
           session before and after the wire, so what matters is that it does
           not change under it — the changed-guest arm has its own reasoning
           and is not what these tests are about. */
        let session = UUID()
        let census = AgentIntegrationCensus(
            listener: listener,
            currentSessionID: { session },
            pageTimeout: pageTimeout,
            clock: { Self.moment })
        return await census.page(probe: probe, cursor: cursor)
    }

    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The probe's outcome versus the call's

    /// **The distinction this capability exists for.** NOW-68K answers
    /// `selectors` with `refused` — 32 KB of selector names does not fit a
    /// 384 KB partition — and that is a machine ANSWERING, so the call
    /// completed. Reporting it as a refused call would tell a caller nothing
    /// reached the Macintosh, which is false and unfixable by retrying.
    func testAProbeThatRefusesIsACompletedCallCarryingThatRefusal()
        async throws {
        let script = Script()
        script.pages = [report(
            probe: "selectors", outcome: "refused", rows: [],
            note: "the documented selector table does not fit this partition")]

        let result = try await page(probe: "selectors", script: script)

        guard case .completed(let page) = result else {
            return XCTFail(
                "a guest that answered has completed the call: \(result)")
        }
        XCTAssertEqual(page.outcome, .refused)
        XCTAssertEqual(page.rows.count, 0)
        XCTAssertEqual(
            page.note,
            "the documented selector table does not fit this partition",
            "the machine's own reason, forwarded rather than replaced")
    }

    /// `absent` is a FINDING about the hardware — `pci` on a pre-PCI Mac —
    /// rendered as content. Zero rows is the complete answer, and the caller
    /// reads `outcome` rather than the row count.
    func testAnAbsentProbeIsAFindingRatherThanAnEmptyAnswer() async throws {
        let script = Script()
        script.pages = [report(
            probe: "pci", outcome: "absent", rows: [],
            note: "no Name Registry on this Mac")]

        let result = try await page(probe: "pci", script: script)

        guard case .completed(let page) = result else {
            return XCTFail("absence is an answer: \(result)")
        }
        XCTAssertEqual(page.outcome, .absent)
        XCTAssertEqual(page.rows.count, 0)
        XCTAssertNotEqual(
            page.outcome, .refused,
            "\"the machine said no\" is never \"we did not look\"")
    }

    /// `partial` is the PowerPC `pram` answer — 20 of 256 bytes — and it
    /// arrives with rows AND the sentence saying what was out of reach.
    /// Neither half may be dropped: rows without the note read as complete.
    func testAPartialProbeKeepsItsRowsAndItsReason() async throws {
        let script = Script()
        script.pages = [report(
            probe: "pram", outcome: "partial",
            rows: [["0x00", "$A8", "valid"]],
            note: "20 of 256 bytes: the XPRAM trap is not declared here")]

        let result = try await page(probe: "pram", script: script)

        guard case .completed(let page) = result else {
            return XCTFail("a partial probe still answered: \(result)")
        }
        XCTAssertEqual(page.outcome, .partial)
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertNotNil(page.note)
    }

    /// The whole vocabulary survives the round trip, in both directions. A
    /// word this side quietly renamed would be a fact about a Macintosh
    /// changed in transit.
    func testEveryOutcomeWordSurvivesTheWireUnchanged() async throws {
        for outcome in AgentIntegrationCensusOutcome.allCases {
            let script = Script()
            script.pages = [report(outcome: outcome.rawValue, rows: [])]
            let result = try await page(script: script)
            guard case .completed(let page) = result else {
                return XCTFail("\(outcome.rawValue) is an answer: \(result)")
            }
            XCTAssertEqual(page.outcome, outcome)
        }
    }

    /// An outcome word this side has no vocabulary for is refused, not mapped.
    /// Choosing one of the six to stand in for a word nobody here understands
    /// would be the host deciding what a machine found.
    func testAnUnknownOutcomeWordIsRefusedRatherThanGuessedAt() async throws {
        let script = Script()
        script.pages = [report(outcome: "mostly", rows: [])]

        let result = try await page(script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("an unrenderable report is not an answer")
        }
        XCTAssertEqual(failure.code, "now-census-outcome-unknown")
    }

    // MARK: - Absence is absent

    /// Rule 4, at the field level: what the guest did not say is an ABSENT
    /// KEY. A `total` of 0 or a `note` of "" would be this side making a
    /// claim, so the encoded answer must carry neither.
    func testWhatTheGuestDidNotSayIsAbsentAndNotZero() async throws {
        let script = Script()
        script.pages = [report(total: nil, note: nil)]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a page")
        }
        XCTAssertNil(page.total)
        XCTAssertNil(page.note)
        XCTAssertNil(page.nextCursor)
        let json = String(
            decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains("\"total\""),
                       "an absent fact is an absent key: \(json)")
        XCTAssertFalse(json.contains("\"note\""),
                       "an absent fact is an absent key: \(json)")
    }

    /// A raw value the guest could not decode keeps its raw form beside a
    /// meaning that says so. Both cells cross unchanged — the third cell is
    /// the guest's reading, and this side has no business improving it.
    func testTheRawValueSurvivesBesideTheDecodedMeaning() async throws {
        let script = Script()
        script.pages = [report(
            probe: "selectors",
            rows: [["gestaltFoo", "$DEADBEEF", "unknown selector"]])]

        let result = try await page(probe: "selectors", script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a page")
        }
        XCTAssertEqual(page.rows.first,
                       ["gestaltFoo", "$DEADBEEF", "unknown selector"])
    }

    // MARK: - Paging, and its bound

    /// One call is one page, and the caller is handed what it needs to ask
    /// for the next one. The page boundary is the guest's pacing — `scsi`
    /// walks one target per page — so this side does not loop it away.
    func testOneCallIsOnePageAndTheCursorReachesTheCaller() async throws {
        let script = Script()
        script.pages = [report(probe: "scsi", rows: [["0", "$00", "disk"]],
                               more: true, cursor: 1, total: 7)]

        let result = try await page(probe: "scsi", script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a page")
        }
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, 1)
        XCTAssertEqual(page.total, 7)
        XCTAssertEqual(script.probes, ["scsi"],
                       "one call asked once; nothing looped to the end")
    }

    /// A cursor the caller passed reaches the guest verbatim, and an omitted
    /// one is omitted rather than sent as 0 — which the contract says are the
    /// same request, so inventing one would only make the wire less honest.
    func testTheCallersCursorReachesTheGuestAndAnAbsentOneStaysAbsent()
        async throws {
        let continued = Script()
        continued.pages = [report()]
        _ = try await page(cursor: 16, script: continued)
        XCTAssertEqual(continued.cursors, [16])

        let fresh = Script()
        fresh.pages = [report()]
        _ = try await page(script: fresh)
        XCTAssertEqual(fresh.cursors, [nil])
    }

    /// `more` with no cursor is carried as it arrived. Inventing a cursor
    /// would send the caller back to a page number the guest never offered.
    func testMoreWithoutACursorIsReportedRatherThanRepaired() async throws {
        let script = Script()
        script.pages = [report(more: true, cursor: nil)]

        let result = try await page(script: script)

        guard case .completed(let page) = result else {
            return XCTFail("expected a page")
        }
        XCTAssertTrue(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    /// **The bound is visible, not silent.** A page over the contract's 16
    /// rows is refused: trimming it would hand a caller a short page under a
    /// `hasMore` that says the page is whole, which is the one failure a
    /// paginated answer must not be able to have.
    func testAnOversizedPageIsRefusedRatherThanTrimmed() async throws {
        let script = Script()
        let rows = (0...AgentIntegrationCensusBounds.maximumRowsPerPage)
            .map { ["row \($0)", "$\($0)", "meaning"] }
        script.pages = [report(rows: rows)]

        let result = try await page(script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("a page this side cannot carry is not an answer")
        }
        XCTAssertEqual(failure.code, "now-census-page-invalid")
    }

    /// A row that is not a triple is refused rather than padded. A padded
    /// row would put an empty MEANING beside a raw value, which reads as
    /// "the guest could not decode it" — a claim the guest never made.
    func testARowThatIsNotATripleIsRefusedRatherThanPadded() async throws {
        let script = Script()
        script.pages = [report(rows: [["Model", "$0224"]])]

        let result = try await page(script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("a malformed row is not an answer")
        }
        XCTAssertEqual(failure.code, "now-census-page-invalid")
    }

    // MARK: - Nothing answered at all

    /// The guest does not implement the family: its `error` carries the
    /// request's id, the listener routes it, and the words are the guest's.
    /// A refused CALL, because no census report exists.
    func testAGuestThatDoesNotServeTheFamilyRefusesTheCall() async throws {
        let script = Script()
        script.refuseFamily = ("not-implemented",
                              "census.request is not implemented here")

        let result = try await page(script: script)

        guard case .refused(let failure) = result else {
            return XCTFail("a guest that answered nothing did not complete")
        }
        XCTAssertEqual(failure.code, "now-census-refused")
        XCTAssertTrue(
            failure.message.contains("not implemented"),
            "the guest's own sentence: \(failure.message)")
    }

    /// Silence is bounded, and it is a refusal of the call rather than a
    /// probe outcome — a `failed` page would say the machine tried.
    func testAnUnansweredPageIsBoundedAndClaimsNothingAboutTheMachine()
        async throws {
        let script = Script()
        script.pages = []

        let result = try await page(script: script, pageTimeout: 0.2)

        guard case .refused(let failure) = result else {
            return XCTFail("a page nobody answered is not a page")
        }
        XCTAssertEqual(failure.code, "now-census-outcome-unknown")
    }

    /// No guest, no answer about a guest. `unavailable` rather than refused:
    /// "the machine said no" and "there was no machine" are the two facts the
    /// shared envelope exists to keep apart.
    func testADisconnectedGuestIsUnavailableRatherThanRefused() async {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let result = await AgentIntegrationCensus(
            listener: disconnected,
            currentSessionID: { nil }
        ).page(probe: "identity", cursor: nil)

        guard case .unavailable(let missing) = result else {
            return XCTFail("a disconnected guest cannot refuse anything")
        }
        XCTAssertEqual(missing.code, "now-guest-unavailable")
    }

    // MARK: - Columns, which are not on the wire

    /// The headings come from this host's copy of the closed registry, which
    /// is a contract constant being rendered rather than a fact about the Mac
    /// being answered here — they are the same on every machine.
    func testColumnsComeFromTheRegistryAndAnUnknownProbeGetsNone()
        async throws {
        let known = Script()
        known.pages = [report(probe: "volumes")]
        guard case .completed(let volumes) =
            try await page(probe: "volumes", script: known) else {
            return XCTFail("expected a page")
        }
        XCTAssertEqual(volumes.columns, ["Volume", "Raw", "Meaning"])

        /* A probe a newer guest grew. Empty rather than a guess: two of the
           three headings are always Raw and Meaning, and inventing the first
           would label somebody's data with something nothing declared. */
        let newer = Script()
        newer.pages = [report(probe: "thunderbolt")]
        guard case .completed(let unknown) =
            try await page(probe: "thunderbolt", script: newer) else {
            return XCTFail("an unknown probe name is the guest's to refuse")
        }
        XCTAssertEqual(unknown.columns, [])
        XCTAssertEqual(unknown.probe, "thunderbolt")
    }

    // MARK: - The projection's own bound

    /// The probe is required and there is no all-probes form: fourteen calls
    /// summed by this host would be an answer it composed. The cursor is
    /// optional and bounded below.
    func testTheProjectionRequiresABoundedProbeAndAWholeCursor() async {
        let refused: [Any?] = [
            nil,
            [String: Any](),
            ["cursor": 0],
            ["probe": ""],
            ["probe": "identity", "extra": 1],
            ["probe": "identity", "cursor": -1],
            ["probe": "identity", "cursor": "16"],
            ["probe": "identity", "cursor": true],
            ["probe": String(repeating: "x", count: 256)],
        ]
        for raw in refused {
            let outcome = await HardwareCensusProjection.invoke(
                .init(raw: raw), through: CensusStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "accepted \(String(describing: raw)) as a census ask")
            }
            XCTAssertEqual(message, HardwareCensusProjection.argumentRefusal)
        }
    }

    /// The probe and the cursor reach the host verbatim, and the outcome the
    /// host answered is the outcome the caller reads — the projection renders
    /// it and does not re-decide it.
    func testTheAskReachesTheHostVerbatimAndTheOutcomeSurvives() async throws {
        let host = CensusStubHost()
        let outcome = await HardwareCensusProjection.invoke(
            .init(raw: ["probe": "scsi", "cursor": 3]), through: host)

        guard case .value(let value) = outcome else {
            return XCTFail("a bounded probe should reach the host")
        }
        let asked = await host.asked
        XCTAssertEqual(asked.map(\.probe), ["scsi"])
        XCTAssertEqual(asked.map(\.cursor), [3])
        let json = String(
            decoding: try value.encoded(using: JSONEncoder()), as: UTF8.self)
        XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
        XCTAssertTrue(json.contains("\"refused\""),
                      "the PROBE's refusal rides inside a completed call")
        XCTAssertNil(
            value.attachment,
            "This row answers in JSON; only capture attaches anything.")
    }

    /// An omitted cursor is omitted all the way down: absent and 0 are the
    /// same request by contract, so this side sends neither in place of the
    /// other.
    func testAnOmittedCursorReachesTheHostAsAbsent() async {
        let host = CensusStubHost()
        _ = await HardwareCensusProjection.invoke(
            .init(raw: ["probe": "overview"]), through: host)
        let asked = await host.asked
        XCTAssertEqual(asked.count, 1)
        XCTAssertNil(asked.first?.cursor)
    }

    // MARK: - What the row declares

    /// **The requirement is the FAMILY and never a probe name.** A probe is
    /// an argument, and the capability ledger can resolve neither a family
    /// nor a probe out of the guest's `help` table — so requiring "overview"
    /// would switch this tool off against every guest for the life of every
    /// connection, in a sentence that reads as a fact about the Macintosh.
    func testTheRowRequiresTheFamilyAndNotAProbe() {
        XCTAssertEqual(
            HardwareCensusProjection.requires,
            [AgentIntegrationCapabilityNames.censusRequest])
        XCTAssertEqual(
            HardwareCensusProjection.exposes,
            [AgentIntegrationCapabilityNames.censusRequest])
        for probe in CensusProbes.all {
            XCTAssertFalse(
                HardwareCensusProjection.requires.contains(probe.id),
                "\(probe.id) is an argument of this row, not a requirement "
                    + "of it")
        }
    }

    /// The ledger row the family owes. Without it `state(of:)` falls through
    /// to the command table, which cannot contain a message family, and the
    /// tool reports itself permanently unavailable against every guest.
    /// `MCPCoverageTests` gates this too; asserting it here is what makes the
    /// failure land beside the capability that needs it.
    func testTheFamilyHasALedgerRowWithAnHonestProbePolicy() {
        let row = AgentIntegrationCapabilityLedger.familyPolicy.first {
            $0.family == AgentIntegrationCapabilityNames.censusRequest
        }
        let policy = try? XCTUnwrap(row)
        XCTAssertEqual(
            policy?.unobserved, .notProbedCostly,
            "there is no cheap request in this family: the probe argument "
                + "is required and the registry's default is the synthesis "
                + "of every other probe")
        XCTAssertEqual(policy?.probedOnRequest, false)
    }
}

/// Answers one census page and records what it was asked. Everything else
/// says "no host", which is what the protocol's defaults are for.
private actor CensusStubHost: AgentIntegrationClient {
    private(set) var asked: [(probe: String, cursor: Int?)] = []

    func census(probe: String, cursor: Int?) async
        -> AgentIntegrationCensusResult {
        asked.append((probe: probe, cursor: cursor))
        return .completed(.init(
            probe: probe,
            /* The probe declined to look, inside a call that completed. The
               encode assertion above is what pins that those are two levels
               and not two spellings. */
            outcome: .refused,
            columns: ["Target", "Raw", "Meaning"],
            rows: [],
            hasMore: false,
            nextCursor: nil,
            note: "an INQUIRY scan is never unattended here",
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
