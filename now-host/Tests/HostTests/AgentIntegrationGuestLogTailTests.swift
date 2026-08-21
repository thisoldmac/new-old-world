import XCTest
@testable import Host
import NOWAgentIntegration

/// A scripted guest ring for the paging tests: `count` lines, oldest first,
/// each tagged with an area, answered the way `run_tail` answers — pages of
/// at most 40, newest-first walk, a `log` group with matching/held/next.
/// The shapes are lifted from `now-guest-ppc/src/commands/commands.c`; the
/// guest's REAL emission is proved against the real decoder by the
/// conformance fixture and the emulator run, not here — this fake exists so
/// the HOST's walk can be watched against a ring with known contents.
@MainActor
private final class FakeRing {
    struct Line {
        let seq: UInt32
        let area: String
        let text: String
    }

    let lines: [Line]
    let ringCapacity = 2000
    var pageLimit = 40

    init(count: Int, area: (Int) -> String = { _ in "wire" }) {
        lines = (1...count).map {
            Line(seq: UInt32($0), area: area($0), text: "line \($0)")
        }
    }

    /// One page, as the guest would answer it.
    func reply(to request: CommandRequest) -> CommandResult {
        var want = 20
        if case .number(let n)? = request.args?["lines"] { want = n }
        want = max(1, min(want, pageLimit))
        var before: UInt32?
        if case .number(let b)? = request.args?["before"] { before = UInt32(b) }
        var area: String?
        if case .text(let a)? = request.args?["area"] { area = a }

        let matching = lines.filter { area == nil || $0.area == area }
        let eligible = matching.filter {
            before == nil || $0.seq < before!
        }
        let page = Array(eligible.suffix(want))
        let older = eligible.count - page.count
        var log: [[String]] = [
            ["file", "Macintosh HD:Lab:now-logs:2026-08-15 010203.log"],
            ["shown", "\(page.count) of \(matching.count)"],
            ["matching", "\(matching.count)"],
            ["held", "\(lines.count) of \(ringCapacity)"],
        ]
        if let area { log.append(["area", area]) }
        if older > 0, let oldest = page.first {
            log.append(["next", "\(oldest.seq)"])
        }
        return .init(
            id: request.id, ok: true,
            output: [
                "tail": page.map { ["01:02:\(String(format: "%02d", $0.seq % 60))",
                                    "\($0.area.padding(toLength: 6, withPad: " ", startingAt: 0)) \($0.text)"] },
                "log": log,
            ],
            error: nil)
    }
}

/// The session the fake pairing reports, spelled once outside the class so
/// a default argument can reach it.
private let logTailSession = "5b6d9a44-0000-4000-8000-000000000000"

/// The log-retrieval capability's own coverage.
///
/// **It names no file, and cannot be made to.** This row returns text the
/// machine wrote, so the tests that matter most are the ones that fail if a
/// path argument ever appears.
///
/// **The walk is the host's job and every bound reports itself.** Pages
/// follow the guest's own `next` cursor; a cursor that fails to descend
/// stops the walk; the byte budget trims OLDEST lines and says so in
/// `shown`.
///
/// **The two sides state their limits once each and a test holds them
/// equal**: `testTheGuestHeadersAndTheHostPolicyStateTheSameLimits` reads
/// the guest's own headers, which is this project's adaptation of "state a
/// limit once" to a limit two toolchains must both compile.
@MainActor
final class AgentIntegrationGuestLogTailTests: XCTestCase {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Answers the `tail` command from a scripted ring, recording every
    /// request. `reply` nil means the guest never answers, which is the
    /// case the timeout exists for.
    private func installResponder(
        on guest: FakeGuest,
        requests: Box<[CommandRequest]> = Box([]),
        reply: ((CommandRequest) -> CommandResult)?
    ) {
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "tail":
                requests.value.append(request)
                guard let reply else { return }
                try? guest.send(.commandResult(reply(request)))
            default:
                break
            }
        }
    }

    private func adapter(
        _ listener: GuestListener,
        audit: @escaping (HostLog.LogLevel, String) -> Void = { _, _ in },
        timeout: TimeInterval = 5,
        session: @escaping @MainActor () -> UUID? = {
            UUID(uuidString: logTailSession)
        }
    ) -> AgentIntegrationGuestLogTail {
        AgentIntegrationGuestLogTail(
            listener: listener,
            currentSessionID: session,
            commandTimeout: timeout,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            audit: audit)
    }

    // MARK: - What crosses the wire, and in what form

    /// **The one that catches the silent shortfall, inverted since v13.**
    /// The count crosses as a typed NUMBER — `CommandArg.number` encodes a
    /// bare JSON integer, which the guest's `now_json_find_int` reads
    /// exactly. What must never come back is the QUOTED form: a `"40"` is
    /// 0 to the guest's strtol and clamps to one line, ok:true, nothing
    /// anywhere saying so.
    func testTheCountCrossesAsABareNumberNeverAQuotedString() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let ring = FakeRing(count: 10)
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) { ring.reply(to: $0) }

        _ = await adapter(listener).tail(lines: 10, area: nil)

        let request = try XCTUnwrap(requests.value.first)
        XCTAssertEqual(request.args?["lines"], .number(10))
        XCTAssertNil(request.line, "The line form is for humans.")
        let json = String(
            decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(
            json.contains("\"lines\":10"),
            "A quoted \"lines\" is worse than no lines at all: the guest "
                + "finds the key, parses 0, clamps to ONE line and answers "
                + "ok — the silent shortfall this test pins. Got: \(json)")
    }

    /// No count means no field, so the default of 20 stays the guest's
    /// number. A copy of it on this side is the limit-in-three-places
    /// defect the project preamble names.
    func testNoCountSendsNoFieldSoTheDefaultStaysTheGuests() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let ring = FakeRing(count: 5)
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) { ring.reply(to: $0) }

        let result = await adapter(listener).tail(lines: nil, area: nil)

        let request = try XCTUnwrap(requests.value.first)
        XCTAssertNil(request.args?["lines"])
        XCTAssertNil(request.line)
        guard case .completed(let retrieval) = result else {
            return XCTFail("an answered tail completes: \(result)")
        }
        XCTAssertEqual(retrieval.requested, 20,
                       "The DEFAULT is applied to the report, not sent.")
        XCTAssertEqual(retrieval.lines.count, 5)
    }

    /// The area rides beside the count and reaches the guest, where the
    /// filtering happens — before the wire, which is the whole point of
    /// having it.
    func testTheAreaFilterReachesTheGuestAndOnlyMatchingLinesReturn()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let ring = FakeRing(count: 30) { $0 % 3 == 0 ? "files" : "wire" }
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) { ring.reply(to: $0) }

        let result = await adapter(listener).tail(lines: 10, area: "files")

        XCTAssertEqual(requests.value.first?.args?["area"], .text("files"))
        guard case .completed(let retrieval) = result else {
            return XCTFail("an answered tail completes: \(result)")
        }
        XCTAssertEqual(retrieval.area, "files")
        XCTAssertEqual(retrieval.matching, 10)
        XCTAssertTrue(retrieval.lines.allSatisfy { $0.contains("files") })
    }

    // MARK: - The walk

    /// **The retrieval this arc exists for.** 200 lines off a 300-line
    /// ring: five pages of 40, each older than the last, reassembled
    /// OLDEST-first with no line served twice and none skipped — the
    /// once-and-only-once property the guest's native test proves for one
    /// page, held across the whole walk.
    func testHundredsOfLinesArePagedAndReassembledInOrder() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let ring = FakeRing(count: 300)
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) { ring.reply(to: $0) }

        let result = await adapter(listener).tail(lines: 200, area: nil)

        guard case .completed(let retrieval) = result else {
            return XCTFail("an answered walk completes: \(result)")
        }
        XCTAssertEqual(retrieval.lines.count, 200)
        XCTAssertEqual(retrieval.pages, 5)
        XCTAssertEqual(requests.value.count, 5)
        /* Oldest-first across page boundaries: lines 101...300. */
        XCTAssertTrue(retrieval.lines.first?.hasSuffix("line 101") == true,
                      "\(retrieval.lines.first ?? "nil")")
        XCTAssertTrue(retrieval.lines.last?.hasSuffix("line 300") == true)
        XCTAssertEqual(retrieval.matching, 300)
        XCTAssertEqual(retrieval.shown, "200 of 300",
                       "Serving everything asked for earns no suffix; "
                           + "matching says how much more exists.")
        XCTAssertEqual(retrieval.ringCapacity, 2000)
        /* The cursors the walk sent must strictly descend, first absent. */
        let befores = requests.value.map { request -> Int? in
            if case .number(let b)? = request.args?["before"] { return b }
            return nil
        }
        XCTAssertNil(befores.first ?? nil)
        let sent = befores.compactMap { $0 }
        XCTAssertEqual(sent, [261, 221, 181, 141])
    }

    /// A ring smaller than the ask ends the walk at the guest's own "no
    /// next row", and the answer says what there was — no suffix, because
    /// nothing that exists was withheld.
    func testAShortLogEndsTheWalkAndReportsItself() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let ring = FakeRing(count: 12)
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) { ring.reply(to: $0) }

        let result = await adapter(listener).tail(lines: 200, area: nil)

        guard case .completed(let retrieval) = result else {
            return XCTFail("a short log is still an answer: \(result)")
        }
        XCTAssertEqual(retrieval.lines.count, 12)
        XCTAssertEqual(retrieval.shown, "12 of 12")
        XCTAssertEqual(retrieval.pages, 1)
        XCTAssertEqual(
            retrieval.guestFile,
            "Macintosh HD:Lab:now-logs:2026-08-15 010203.log")
    }

    /// A guest whose cursor does not descend is walking this side in a
    /// circle; the walk stops and reports what it has rather than looping.
    func testACursorThatFailsToDescendStopsTheWalk() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) { request in
            .init(id: request.id, ok: true,
                  output: [
                      "tail": [["01:02:03", "wire   the same page"]],
                      "log": [["matching", "500"], ["next", "400"]],
                  ],
                  error: nil)
        }

        let result = await adapter(listener).tail(lines: 200, area: nil)

        guard case .completed(let retrieval) = result else {
            return XCTFail("a stopped walk still answers: \(result)")
        }
        XCTAssertEqual(
            requests.value.count, 2,
            "The second page repeated the cursor; a third ask would be "
                + "the start of the loop this guard exists to end.")
        XCTAssertEqual(retrieval.lines.count, 2)
        XCTAssertTrue(retrieval.shown.contains("(older ones did not fit)"))
    }

    /// A guest from before v13 answers one page with no matching/next rows.
    /// That is a complete single-page answer, not an error: matching falls
    /// back to what arrived.
    func testAPreV13GuestAnswersOnePageCompletely() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: { request in
            .init(id: request.id, ok: true,
                  output: [
                      "tail": [["21:04:11", "wire   connected"],
                               ["21:04:19", "get    Notes.txt"]],
                      "log": [["file", "now-logs:x.log"],
                              ["shown", "2 of 2"]],
                  ],
                  error: nil)
        })

        let result = await adapter(listener).tail(lines: 200, area: nil)

        guard case .completed(let retrieval) = result else {
            return XCTFail("an old guest's page is an answer: \(result)")
        }
        XCTAssertEqual(retrieval.lines,
                       ["21:04:11 wire   connected",
                        "21:04:19 get    Notes.txt"])
        XCTAssertEqual(retrieval.matching, 2)
        XCTAssertEqual(retrieval.pages, 1)
        XCTAssertEqual(
            retrieval.ringCapacity,
            AgentIntegrationGuestLogPolicy.ringCapacity,
            "No held row means the policy's constant, which the guest-header "
                + "test keeps honest.")
    }

    /// The byte budget binds before the count on a log of long lines; the
    /// OLDEST go, and shown says so.
    func testTheByteBudgetTrimsOldestAndSaysSo() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let wide = String(repeating: "x", count: 400)
        installResponder(on: guest, reply: { request in
            var before = UInt32.max
            if case .number(let b)? = request.args?["before"] {
                before = UInt32(b)
            }
            let newest = min(before - 1, 1000)
            let seqs = (max(1, newest - 39)...newest)
            return .init(
                id: request.id, ok: true,
                output: [
                    "tail": seqs.map { ["01:02:03", "wire   \($0) \(wide)"] },
                    "log": [["matching", "1000"],
                            ["held", "1000 of 2000"],
                            ["next", "\(seqs.lowerBound)"]],
                ],
                error: nil)
        })

        let result = await adapter(listener).tail(lines: 500, area: nil)

        guard case .completed(let retrieval) = result else {
            return XCTFail("a budgeted answer still completes: \(result)")
        }
        XCTAssertLessThan(retrieval.lines.count, 500)
        XCTAssertTrue(retrieval.shown.hasSuffix("(older ones did not fit)"),
                      retrieval.shown)
        let bytes = retrieval.lines.reduce(0) {
            $0 + $1.utf8.count
                + AgentIntegrationGuestLogPolicy.perLineEnvelopeBytes
        }
        XCTAssertLessThanOrEqual(
            bytes, AgentIntegrationGuestLogPolicy.maximumTotalBytes)
        /* Newest survive: the last line is sequence 1000. */
        XCTAssertTrue(retrieval.lines.last?.contains("1000") == true)
    }

    // MARK: - Refusals, silence, and a changed machine

    /// A count the ring cannot hold is refused here, and **nothing reaches
    /// the machine** — the third reading of a bound the projection and the
    /// local codec have already applied.
    func testAnOutOfRangeCountIsRefusedWithoutAskingTheMachine()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) {
            FakeRing(count: 1).reply(to: $0)
        }

        let result = await adapter(listener).tail(
            lines: AgentIntegrationGuestLogPolicy.maximumLineCount + 1,
            area: nil)

        guard case .refused(let failure) = result else {
            return XCTFail("2001 lines is not something the ring holds: "
                               + "\(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-lines-invalid")
        XCTAssertTrue(requests.value.isEmpty,
                      "A request that could only be refused must not cost "
                          + "a round trip to a 68030.")
    }

    /// An area wider than the guest's tag field could never match a line;
    /// refusing it beats answering with an empty tail that reads as a
    /// silent subsystem.
    func testAnOverwideAreaIsRefusedWithoutAskingTheMachine() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let requests = Box<[CommandRequest]>([])
        installResponder(on: guest, requests: requests) {
            FakeRing(count: 1).reply(to: $0)
        }

        let result = await adapter(listener).tail(
            lines: nil, area: "continuity")

        guard case .refused(let failure) = result else {
            return XCTFail("a 10-character tag can never match a 6-wide "
                               + "field: \(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-area-invalid")
        XCTAssertTrue(requests.value.isEmpty)
    }

    /// A guest refusal stays a refusal and its own sentence crosses.
    func testAGuestRefusalKeepsItsOwnWords() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: { request in
            .init(id: request.id, ok: false, output: nil,
                  error: .init(code: "tail-refused",
                               message: "this Mac keeps no log this launch"))
        })

        let result = await adapter(listener).tail(lines: nil, area: nil)

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

        let result = await adapter(listener, timeout: 0.2)
            .tail(lines: nil, area: nil)

        guard case .refused(let failure) = result else {
            return XCTFail("silence is not an answer: \(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-outcome-unknown")
    }

    /// The machine that was asked is no longer on the other end, so what
    /// came back is a different Mac's log or nothing — unavailable, not
    /// refused.
    func testAGuestThatChangedMidReadIsUnavailableRatherThanRefused()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: {
            FakeRing(count: 3).reply(to: $0)
        })
        let sessions = [UUID(uuidString: logTailSession), UUID()]
        let nth = Box(0)

        let result = await adapter(listener, session: {
            defer { nth.value += 1 }
            return sessions[min(nth.value, sessions.count - 1)]
        }).tail(lines: nil, area: nil)

        guard case .unavailable(let failure) = result else {
            return XCTFail("a changed pairing cannot be reported as an "
                               + "answer: \(result)")
        }
        XCTAssertEqual(failure.code, "now-log-tail-outcome-unknown")
    }

    // MARK: - What a line may carry

    /// A control character inside a line is written `\xNN`: still there,
    /// still readable, and unable to corrupt whatever renders the answer.
    func testAControlCharacterInALineIsEscapedRatherThanDroppedOrRaw() {
        let page = AgentIntegrationGuestLogTail.Page(
            from: .init(
                id: 1, ok: true,
                output: ["tail": [["21:04:11", "files  a\u{0D}b\u{07}"]]],
                error: nil))

        XCTAssertEqual(page.lines, ["21:04:11 files  a\\x0Db\\x07"])
        XCTAssertFalse(
            page.lines.first?.unicodeScalars
                .contains { $0.value < 0x20 } ?? true,
            "A raw control byte corrupts whatever renders the answer.")
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
        let ring = FakeRing(count: 60)
        installResponder(on: guest, reply: { ring.reply(to: $0) })
        let written = Box<[String]>([])

        _ = await adapter(listener, audit: { _, message in
            written.value.append(message)
        }).tail(lines: 60, area: nil)

        let line = try XCTUnwrap(written.value.first)
        XCTAssertTrue(line.contains("60 log lines"), line)
        XCTAssertTrue(line.contains("2 pages"), line)
        for quoted in ["line 1", "now-logs"] {
            XCTAssertFalse(
                line.contains(quoted),
                "The audit line quotes \"\(quoted)\" out of the log it just "
                    + "read. The trace says who asked, not what the machine "
                    + "said.")
        }
    }

    // MARK: - The projection: what a caller may send

    /// **The scope test.** The input schema offers a count and an area and
    /// nothing that could name a file, and this row must never grow one: it
    /// returns bytes, which is the property `file.list` and `reveal` do not
    /// have, and the guest verb has no target to point at. The `before`
    /// cursor is deliberately absent too — paging is the host's job, and a
    /// cursor a caller could pass is a page they could skip.
    func testTheInputSchemaOffersCountAndAreaAndNothingThatNamesAFile()
        throws {
        let descriptor = GuestLogTailProjection.operationDescriptor.mcpToolDescriptor
        let input = try XCTUnwrap(
            descriptor["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(
            input["properties"] as? [String: Any])

        XCTAssertEqual(Set(properties.keys), ["lines", "area"])
        XCTAssertEqual(input["additionalProperties"] as? Bool, false)
        XCTAssertNil(
            input["required"],
            "Every member is optional: a bare call is a complete request.")
        for named in ["path", "target", "file", "name", "before"] {
            XCTAssertNil(
                properties[named],
                "\"\(named)\" does not belong on this row's input.")
        }
        let lines = try XCTUnwrap(properties["lines"] as? [String: Any])
        XCTAssertEqual(lines["type"] as? String, "integer")
        XCTAssertEqual(lines["minimum"] as? Int, 1)
        XCTAssertEqual(
            lines["maximum"] as? Int,
            AgentIntegrationGuestLogPolicy.maximumLineCount)
        let area = try XCTUnwrap(properties["area"] as? [String: Any])
        XCTAssertEqual(
            area["maxLength"] as? Int,
            AgentIntegrationGuestLogPolicy.areaTagScalars)
    }

    /// The three outcomes a caller has to be able to tell apart, including
    /// the unavailable arm every row shares.
    func testTheOutputSchemaDeclaresTheUnavailableArm() throws {
        let output = try XCTUnwrap(
            GuestLogTailProjection.operationDescriptor.mcpToolDescriptor["outputSchema"]
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
            ("an overwide area", ["area": "continuity"]),
            ("an empty area", ["area": ""]),
            ("a numeric area", ["area": 6]),
            ("an unknown key", ["lines": 20, "path": "Macintosh HD:"]),
            ("a cursor, which is the host's job", ["before": 100]),
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

    /// A bare call and a bounded ask both reach the host, and the answer
    /// survives rendering — the projection renders and does not re-decide.
    func testAValidAskReachesTheHostAndAnAbsentOneIsComplete()
        async throws {
        let host = LogTailStubHost()

        for (label, arguments) in [
            ("absent", nil as Any?),
            ("empty", [:] as Any?),
            ("bounded", ["lines": 200, "area": "wire"] as Any?),
        ] {
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
        XCTAssertEqual(asked.map(\.lines), [nil, nil, 200])
        XCTAssertEqual(asked.map(\.area), [nil, nil, "wire"])
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

    // MARK: - The limits, stated once per side and held equal

    /// **"State a limit once" across two toolchains.** The guest states its
    /// ring, page and tag-field sizes in its own headers; this side restates
    /// them in `AgentIntegrationGuestLogPolicy` so a bad ask is refused
    /// before it costs a round trip. Two statements, one test holding them
    /// equal — the same pattern as the control-frame cap, adapted to a limit
    /// a Swift module cannot #include.
    func testTheGuestHeadersAndTheHostPolicyStateTheSameLimits() throws {
        let root = URL(fileURLWithPath: #filePath) // …/Tests/HostTests/x
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nowlog = try String(
            contentsOf: root.appendingPathComponent(
                "now-guest-ppc/src/core/nowlog.h"),
            encoding: .utf8)
        let logquery = try String(
            contentsOf: root.appendingPathComponent(
                "now-guest-ppc/src/core/logquery.h"),
            encoding: .utf8)

        XCTAssertTrue(
            nowlog.contains(
                "kLogKept = \(AgentIntegrationGuestLogPolicy.ringCapacity)"),
            "The guest's ring (nowlog.h kLogKept) and this side's "
                + "ringCapacity have drifted apart.")
        XCTAssertTrue(
            logquery.contains(
                "kLogQueryPageMax = "
                    + "\(AgentIntegrationGuestLogPolicy.pageLineCount)"),
            "The guest's page (logquery.h kLogQueryPageMax) and this side's "
                + "pageLineCount have drifted apart.")
        XCTAssertTrue(
            logquery.contains(
                "kLogQueryAreaMax = "
                    + "\(AgentIntegrationGuestLogPolicy.areaTagScalars)"),
            "The guest's tag field (logquery.h kLogQueryAreaMax) and this "
                + "side's areaTagScalars have drifted apart.")
    }

    // MARK: - PowerPC only, in typed form and by derivation

    /// **The whole of "PPC only".** A guest whose command table names `tail`
    /// can be asked; one whose table does not reports the row `unavailable`
    /// — a complete typed answer with a reason, never a weaker version of
    /// the tool — and nothing in the row or the ledger asks which guest is
    /// on the wire to get there. The 68K guest's table has no `tail`, so
    /// that is the mechanism the fork rides on.
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
}

/// Answers one retrieval and records the asks. Everything else answers "no
/// host", which is what the protocol's defaults are for.
private actor LogTailStubHost: AgentIntegrationClient {
    struct Ask: Equatable {
        let lines: Int?
        let area: String?
    }

    private(set) var asked: [Ask] = []

    func tailGuestLog(lines: Int?, area: String?) async
        -> AgentIntegrationGuestLogRetrievalResult {
        asked.append(.init(lines: lines, area: area))
        return .completed(.init(
            lines: ["21:04:11 wire   connected to 10.0.1.7"],
            requested: lines ?? AgentIntegrationGuestLogPolicy
                .defaultLineCount,
            matching: 1,
            shown: "1 of 1",
            area: area,
            ringCapacity: AgentIntegrationGuestLogPolicy.ringCapacity,
            guestFile: nil,
            pages: 1,
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
