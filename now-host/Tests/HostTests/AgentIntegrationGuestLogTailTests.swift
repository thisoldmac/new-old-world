import XCTest
@testable import Host
import NOWAgentIntegration

/// The two groups a real `tail` answers, in the guest's own shapes.
private func tailOutput(
    lines: [(String, String)] = [
        ("21:04:11", "wire   connected to 10.0.1.7"),
        ("21:04:19", "get    Notes.txt, 4096 bytes"),
    ],
    shown: String = "2 of 2"
) -> [String: [[String]]] {
    [
        "tail": lines.map { [$0.0, $0.1] },
        "log": [
            ["file", "Macintosh HD:Lab:now-logs:2026-07-30 210411.log"],
            ["shown", shown],
        ],
    ]
}

/// The session the fake pairing reports, spelled once outside the class so
/// a default argument can reach it.
private let logTailSession = "5b6d9a44-0000-4000-8000-000000000000"

/// The log-tail capability's own coverage, aimed at the four things that are
/// genuinely its own.
///
/// **It names no file, and cannot be made to.** This is the first row that
/// returns text the machine wrote, so the tests that matter most are the ones
/// that fail if a path argument ever appears.
///
/// **The count reaches the guest by the one route that works.** A typed
/// argument is a quoted string on this wire and the guest reads this one with
/// `strtol`, so `"40"` is 0 and clamps to a single line — an answer that is
/// wrong and silent. The test below asserts the line form, and it fails if
/// somebody "tidies" the count back into `args`.
///
/// **The bound is the guest's own and stays visible.** The `log` group's
/// `shown` row crosses untouched, and `note` stays empty because the type
/// reserves it for a guest sentence rather than a host one.
///
/// **A control character is escaped, not dropped and not passed through.**
///
/// Nothing here constructs the message it then parses: a fake guest answers
/// the `tail` command the way a real one does (the shapes are lifted from
/// `now-guest-ppc/src/commands/commands.c :: run_tail`), and every assertion
/// is about what the host did with it.
@MainActor
final class AgentIntegrationGuestLogTailTests: XCTestCase {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Answers the `tail` command, recording the request it was asked with.
    /// `reply` nil means the guest never answers, which is the case the
    /// timeout exists for.
    private func installResponder(
        on guest: FakeGuest,
        seen: Box<CommandRequest?> = Box(nil),
        count: Box<Int> = Box(0),
        reply: ((Int) -> CommandResult)? = { id in
            .init(id: id, ok: true, output: tailOutput(), error: nil)
        }
    ) {
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "tail":
                count.value += 1
                seen.value = request
                guard let reply else { return }
                try? guest.send(.commandResult(reply(request.id)))
            default:
                break
            }
        }
    }

    private func adapter(
        _ listener: GuestListener,
        audit: @escaping (HostLog.LogLevel, String) -> Void = { _, _ in },
        timeout: TimeInterval = 5,
        session: @escaping () -> UUID? = { UUID(uuidString: logTailSession) }
    ) -> AgentIntegrationGuestLogTail {
        AgentIntegrationGuestLogTail(
            listener: listener,
            currentSessionID: session,
            commandTimeout: timeout,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            audit: audit)
    }

    // MARK: - The count, and the route it has to take

    /// **The one that catches the silent shortfall.** The caller's count goes
    /// on the LINE and not into `args`.
    ///
    /// `CommandRequest.args` is `[String: String]`, so a typed `lines` reaches
    /// the guest as `"40"`; it reads the value with `now_json_find_int`, which
    /// is `strtol` on the byte after the colon, and `strtol("\"40\"")` is 0 —
    /// which `run_tail` clamps to 1. A caller asking for forty lines would get
    /// one, with `ok:true` and nothing anywhere saying so. The line form is
    /// what the contract declares for this verb (`x-line`).
    func testTheCountTravelsOnTheLineBecauseATypedArgWouldReadAsZero()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let seen = Box<CommandRequest?>(nil)
        installResponder(on: guest, seen: seen)

        _ = await adapter(listener).tail(lines: 40)

        XCTAssertEqual(
            seen.value?.line, "40",
            "The count must reach the guest on the line. As a typed arg it "
                + "arrives quoted, parses as 0 and clamps to ONE line — a "
                + "wrong answer with no error anywhere.")
        XCTAssertNil(
            seen.value?.args?["lines"],
            "A quoted \"lines\" is worse than no lines at all: the guest "
                + "finds the key, parses 0, and never reaches its own "
                + "default of 20.")
    }

    /// No count means no field, so the default of 20 stays the guest's
    /// number. A copy of it on this side is the limit-in-three-places defect
    /// the project preamble names.
    func testNoCountSendsNoFieldSoTheDefaultStaysTheGuests() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let seen = Box<CommandRequest?>(nil)
        installResponder(on: guest, seen: seen)

        _ = await adapter(listener).tail(lines: nil)

        XCTAssertNotNil(seen.value, "the verb should still be asked")
        XCTAssertNil(seen.value?.line)
        XCTAssertNil(seen.value?.args)
        let request = try XCTUnwrap(seen.value)
        let json = String(
            decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(
            json.contains("20"),
            "20 is the GUEST's default. This side sending it would be the "
                + "same limit written in two places, which is how they "
                + "drift apart.")
    }

    /// A count the verb cannot serve is refused here, and **nothing reaches
    /// the machine** — the third reading of a bound the projection and the
    /// local codec have already applied.
    func testAnOutOfRangeCountIsRefusedWithoutAskingTheMachine()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let asks = Box(0)
        installResponder(on: guest, count: asks)

        let result = await adapter(listener).tail(
            lines: AgentIntegrationGuestLogPolicy.maximumLineCount + 1)

        guard case .refused(let failure) = result else {
            return XCTFail("41 lines is not something the verb can serve: "
                               + "\(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-lines-invalid")
        XCTAssertEqual(
            asks.value, 0,
            "A request that could only be refused must not cost a round "
                + "trip to a 68030.")
    }

    // MARK: - The answer

    /// The guest's lines cross as the guest wrote them, oldest first, with
    /// its own account of the answer's edges beside them and no host claim
    /// added.
    func testACompletedTailCarriesTheGuestsLinesAndItsOwnBound()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: { id in
            .init(id: id, ok: true,
                  output: tailOutput(
                      shown: "12 of 20 (older ones did not fit)"),
                  error: nil)
        })

        let result = await adapter(listener).tail(lines: 20)

        guard case .completed(let report) = result else {
            return XCTFail("an answered tail is a completed tail: \(result)")
        }
        XCTAssertEqual(report.verb, "tail")
        /* Sorted for determinism, since `output` is a dictionary and the
           wire's group order is already gone. */
        XCTAssertEqual(report.groups.map(\.name), ["log", "tail"])
        let lines = try XCTUnwrap(report.groups.last)
        XCTAssertEqual(lines.rows.map(\.label), ["21:04:11", "21:04:19"])
        XCTAssertEqual(lines.rows.last?.value, "get    Notes.txt, 4096 bytes")
        let meta = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(
            meta.rows.first { $0.label == "shown" }?.value,
            "12 of 20 (older ones did not fit)",
            "The guest's own statement of its bound IS how the bound stays "
                + "visible. Dropping this row would make a truncated answer "
                + "indistinguishable from a quiet machine.")
        XCTAssertNil(
            report.note,
            "The note is the GUEST's sentence about its own answer. `tail` "
                + "states its bound as the shown row instead, and a host "
                + "lifting one row into that field would be deciding which "
                + "of the guest's rows mattered.")
    }

    /// Row order inside the `tail` group is chronological and is preserved.
    /// It is the one transformation that would change what the answer says.
    func testTheLinesAreNotReorderedByTheHost() {
        let stamps = (0..<12).map {
            (String(format: "21:%02d:00", $0), "app    line \($0)")
        }
        let report = AgentIntegrationGuestLogTail.report(
            from: .init(id: 1, ok: true,
                        output: tailOutput(lines: stamps),
                        error: nil),
            observedAt: Date(timeIntervalSince1970: 0))

        let group = report.groups.first { $0.name == "tail" }
        XCTAssertEqual(group?.rows.map(\.label), stamps.map(\.0))
    }

    /// A control character inside a line is written `\xNN`: still there,
    /// still readable, and unable to corrupt whatever renders the row.
    func testAControlCharacterInALineIsEscapedRatherThanDroppedOrRaw() {
        let report = AgentIntegrationGuestLogTail.report(
            from: .init(
                id: 1, ok: true,
                output: ["tail": [["21:04:11", "files  a\u{0D}b\u{07}"]]],
                error: nil),
            observedAt: Date(timeIntervalSince1970: 0))

        let value = report.groups.first?.rows.first?.value
        XCTAssertEqual(value, "files  a\\x0Db\\x07")
        XCTAssertFalse(
            value?.unicodeScalars.contains { $0.value < 0x20 } ?? true,
            "A raw control byte corrupts the row it lands in.")
        XCTAssertTrue(
            value?.contains("a") == true && value?.contains("b") == true,
            "Nothing around the escape may be lost — silently mangling "
                + "bytes is the failure this escape exists to avoid.")
    }

    /// A guest refusal stays a refusal and its own sentence crosses.
    func testAGuestRefusalKeepsItsOwnWords() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: { id in
            .init(id: id, ok: false, output: nil,
                  error: .init(code: "tail-refused",
                               message: "this Mac keeps no log this launch"))
        })

        let result = await adapter(listener).tail(lines: nil)

        guard case .refused(let failure) = result else {
            return XCTFail("a refusal is not a completed tail: \(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-refused")
        XCTAssertEqual(failure.message, "this Mac keeps no log this launch")
    }

    /// A guest that never answers is not an empty log.
    func testASilentGuestIsAnUnknownOutcomeAndNotAQuietLog() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: nil)

        let result = await adapter(listener, timeout: 0.2).tail(lines: nil)

        guard case .refused(let failure) = result else {
            return XCTFail("silence is not an answer: \(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-outcome-unknown")
    }

    /// The machine that was asked is no longer on the other end, so what came
    /// back is a different Mac's log or nothing — unavailable, not refused.
    func testAGuestThatChangedMidReadIsUnavailableRatherThanRefused()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest)
        let sessions = [UUID(uuidString: logTailSession), UUID()]
        let nth = Box(0)

        let result = await adapter(listener, session: {
            defer { nth.value += 1 }
            return sessions[min(nth.value, sessions.count - 1)]
        }).tail(lines: nil)

        guard case .unavailable(let failure) = result else {
            return XCTFail("a changed pairing cannot be reported as an "
                               + "answer: \(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-outcome-unknown")
    }

    // MARK: - The line the person at the machine reads

    /// The audit line says a log was read and **how much**, never what it
    /// said. A log that quoted the log would double every line on the next
    /// read, and docs/logging.md keeps content out of the caller's trace.
    func testTheAuditLineCountsTheLinesAndNeverQuotesThem() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest)
        let written = Box<[String]>([])

        _ = await adapter(listener, audit: { _, message in
            written.value.append(message)
        }).tail(lines: nil)

        let line = try XCTUnwrap(written.value.first)
        XCTAssertTrue(line.contains("2 log lines"), line)
        for quoted in ["Notes.txt", "10.0.1.7", "now-logs"] {
            XCTAssertFalse(
                line.contains(quoted),
                "The audit line quotes \"\(quoted)\" out of the log it just "
                    + "read. The trace says who asked, not what the machine "
                    + "said.")
        }
    }

    // MARK: - The projection: what a caller may send

    /// **The scope test.** The input schema offers a count and nothing that
    /// could name a file, and this row must never grow one: it returns bytes,
    /// which is the property `file.list` and `reveal` do not have, and the
    /// guest verb has no target to point at.
    func testTheInputSchemaOffersACountAndNothingThatNamesAFile() throws {
        let descriptor = GuestLogTailProjection.mcpDescriptor
        let input = try XCTUnwrap(
            descriptor["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(
            input["properties"] as? [String: Any])

        XCTAssertEqual(Set(properties.keys), ["lines"])
        XCTAssertEqual(input["additionalProperties"] as? Bool, false)
        XCTAssertNil(
            input["required"],
            "Every member is optional: a bare call is a complete request.")
        for named in ["path", "target", "file", "name"] {
            XCTAssertNil(
                properties[named],
                "\"\(named)\" would make this an arbitrary-file read. The "
                    + "verb takes a count; a named bounded read is "
                    + "now_guest_files_download, under guestRoot.")
        }
        let lines = try XCTUnwrap(properties["lines"] as? [String: Any])
        XCTAssertEqual(lines["type"] as? String, "integer")
        XCTAssertEqual(lines["minimum"] as? Int, 1)
        XCTAssertEqual(
            lines["maximum"] as? Int,
            AgentIntegrationGuestLogPolicy.maximumLineCount)
    }

    /// The three outcomes a caller has to be able to tell apart, including
    /// the unavailable arm every row shares.
    func testTheOutputSchemaDeclaresTheUnavailableArm() throws {
        let output = try XCTUnwrap(
            GuestLogTailProjection.mcpDescriptor["outputSchema"]
                as? [String: Any])
        let variants = try XCTUnwrap(output["oneOf"] as? [[String: Any]])
        let outcomes = variants.compactMap {
            (($0["properties"] as? [String: Any])?["outcome"]
                as? [String: Any])?["const"] as? String
        }
        XCTAssertEqual(outcomes, ["completed", "refused", "unavailable"])
    }

    /// Every argument shape a caller can get wrong, refused with something
    /// that says what would have been accepted.
    func testTheArgumentBoundsRefuseWhatTheVerbCannotServe() async {
        let host = LogTailStubHost()
        let refusals: [(String, Any?)] = [
            ("over the maximum",
             ["lines": AgentIntegrationGuestLogPolicy.maximumLineCount + 1]),
            ("zero", ["lines": 0]),
            ("negative", ["lines": -5]),
            /* `true` bridges to an NSNumber that casts to 1, so a caller who
               sent a flag would otherwise get one line of log. */
            ("a boolean", ["lines": true]),
            ("a quoted number", ["lines": "40"]),
            ("a fraction", ["lines": 2.5]),
            ("an unknown key", ["lines": 20, "path": "Macintosh HD:"]),
            ("not an object at all", 40),
        ]
        for (what, arguments) in refusals {
            let outcome = await GuestLogTailProjection.invoke(
                .init(raw: arguments), through: host)
            guard case .invalidArguments = outcome else {
                return XCTFail("\(what) should be refused: \(outcome)")
            }
        }
        let asked = await host.asked
        XCTAssertTrue(
            asked.isEmpty,
            "Nothing refused here may reach a machine.")
    }

    /// A bare call and a bounded count both reach the host, and the answer
    /// survives rendering — the projection renders and does not re-decide.
    func testAValidCountReachesTheHostAndAnAbsentOneIsComplete()
        async throws {
        let host = LogTailStubHost()

        for (label, arguments) in [("absent", nil as Any?),
                                   ("empty", [:] as Any?),
                                   ("bounded", ["lines": 40] as Any?)] {
            let outcome = await GuestLogTailProjection.invoke(
                .init(raw: arguments), through: host)
            guard case .value(let value) = outcome else {
                return XCTFail("\(label) arguments are a complete request: "
                                   + "\(outcome)")
            }
            let json = String(
                decoding: try value.encoded(using: JSONEncoder()),
                as: UTF8.self)
            XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
            XCTAssertTrue(json.contains("wire   connected"))
            XCTAssertNil(
                value.attachment,
                "This row answers in JSON; only capture attaches anything.")
        }
        let asked = await host.asked
        XCTAssertEqual(asked, [nil, nil, 40])
    }

    /// The row requires the command and nothing else — in particular not
    /// `file.list`, which would tie a log read to the Files family's
    /// authority and imply a path this verb does not have.
    func testTheRowRequiresTheCommandAndNothingFromTheFilesFamily() {
        XCTAssertEqual(
            GuestLogTailProjection.requires,
            [AgentIntegrationCapabilityNames.tailCommand])
        XCTAssertEqual(
            GuestLogTailProjection.exposes,
            [AgentIntegrationCapabilityNames.tailCommand])
        XCTAssertFalse(
            GuestLogTailProjection.requires.contains(
                AgentIntegrationCapabilityNames.fileList),
            "This row reads no directory and names no path; requiring the "
                + "file family would make it unavailable against a guest "
                + "that serves tail.")
        XCTAssertTrue(
            AgentIntegrationCapabilityNames.all.contains(
                AgentIntegrationCapabilityNames.tailCommand),
            "A requirement missing from the declared set is a name only a "
                + "test knows.")
    }

    // MARK: - PowerPC only, in typed form and by derivation

    /// **The whole of "PPC only".** A guest whose command table names `tail`
    /// can be asked; one whose table does not reports the row `unavailable`
    /// — a complete typed answer with a reason, never a weaker version of
    /// the tool — and nothing in the row or the ledger asks which guest is on
    /// the wire to get there. The 68K guest's table has no `tail`, so that is
    /// the mechanism the fork rides on.
    func testTheRowIsAvailableExactlyWhenTheGuestsHelpNamesTail()
        async throws {
        for (commands, expected) in [
            (["help", "tail"], AgentIntegrationCapabilityState.available),
            (["help", "ls", "ps"], .unavailable),
        ] {
            let (listener, guest) = try await connectedListener()
            defer {
                guest.connection.cancel()
                listener.stop()
            }
            guest.onMessage = { message in
                switch message {
                case .commandRequest(let request)
                    where request.name == "help":
                    try? guest.send(.commandResult(.init(
                        id: request.id, ok: true,
                        output: ["help": commands.map { [$0, "a verb"] }],
                        error: nil)))
                /* The report probes these two families. Answered — with the
                   refusal a guest that lacks them really sends — because a
                   silent fake makes each probe wait out its full watchdog,
                   and a minute of test time is paid for nothing this test is
                   about. */
                case .processList(let request):
                    try? guest.send(.error(.init(
                        id: request.id, code: "not-implemented",
                        message: "unsupported message type")))
                case .fileList(let request):
                    try? guest.send(.error(.init(
                        id: request.id, code: "not-implemented",
                        message: "unsupported message type")))
                default:
                    break
                }
            }
            let adapter = AgentIntegrationHostAdapter(listener: listener)

            let report = await adapter.sessionCapabilities()
            guard case .available(let capabilities) = report else {
                return XCTFail("expected a capability report: \(report)")
            }
            let row = capabilities.tools.first {
                $0.tool == "now_guest_log_tail"
            }
            XCTAssertEqual(
                row?.state, expected,
                "A command requirement is resolved against the guest's own "
                    + "help table; \(commands) should read \(expected).")
            if expected == .unavailable {
                XCTAssertEqual(row?.missing, ["tail"])
            }
        }
    }

    /// The rendering is bounded, and a guest answering something larger or
    /// stranger than the contract's two groups is carried rather than
    /// trusted.
    func testTheRenderingIsBoundedAndDoesNotInvent() throws {
        let bounds = AgentIntegrationGuestLogTailBounds.self
        let many = (0..<(bounds.maximumRowsPerGroup + 6)).map {
            ["21:00:00", "app    line \($0)"]
        }
        let report = AgentIntegrationGuestLogTail.report(
            from: .init(id: 1, ok: true,
                        output: ["tail": many, "log": [["only-one-cell"]]],
                        error: nil),
            observedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(report.groups.map(\.name), ["log", "tail"])
        XCTAssertEqual(report.groups.last?.rows.count,
                       bounds.maximumRowsPerGroup)
        let lone = try XCTUnwrap(report.groups.first?.rows.first)
        XCTAssertEqual(lone.label, "only-one-cell")
        XCTAssertEqual(
            lone.value, "",
            "A one-cell row has no value, and repeating the label as one "
                + "would be this side inventing an answer.")
    }

    /// The host's own bounds are sized from the guest's buffers, so they are
    /// a backstop and cannot trim a legitimate answer before the guest's own
    /// frame budget does.
    func testTheHostBoundsCannotBiteBeforeTheGuestsDo() {
        let bounds = AgentIntegrationGuestLogTailBounds.self
        XCTAssertGreaterThanOrEqual(
            bounds.maximumRowsPerGroup,
            AgentIntegrationGuestLogPolicy.maximumLineCount,
            "A row bound below the verb's own maximum would drop lines the "
                + "guest said it was sending, and the shown row would then "
                + "disagree with the answer beside it.")
        XCTAssertGreaterThanOrEqual(
            bounds.maximumValueScalars, 255,
            "The log group's file row carries an HFS path.")
    }
}

/// Answers one tail and records the counts it was asked for. Everything else
/// answers "no host", which is what the protocol's defaults are for.
private actor LogTailStubHost: AgentIntegrationClient {
    private(set) var asked: [Int?] = []

    func tailGuestLog(lines: Int?) async
        -> AgentIntegrationGuestRowReportResult {
        asked.append(lines)
        return .completed(.init(
            verb: "tail",
            groups: [
                .init(name: "log",
                      rows: [.init(label: "shown", value: "2 of 2")]),
                .init(name: "tail",
                      rows: [.init(label: "21:04:11",
                                   value: "wire   connected to 10.0.1.7")]),
            ],
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

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
