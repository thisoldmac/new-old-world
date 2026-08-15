import XCTest
@testable import Host
import NOWAgentIntegration

/// **`now_host_log_tail` — this side's log, and the things that are its
/// own.**
///
/// Nothing here builds a fixture that restates `HostLog`. Every read is of
/// the real ring, written through the real `HostLog.write` the rest of the
/// app calls, so a test that constructed the line it then parsed would be
/// testing one half twice. Each test writes under an area tag of its own, so
/// the shared singleton's other traffic cannot make a green or a red.
///
/// Four claims are load-bearing and fail separately:
///
/// 1. **It serves the RING, not the file.** The disk switch is off for these
///    tests and the lines still arrive. That is the whole reason the row
///    exists: the defect that motivated it was diagnosable only because
///    somebody's switch happened to be on.
/// 2. **The bounds are the ring's, stated once.** The row's maximum IS
///    `HostLog.ringCapacity`, read from the one constant both sides share.
/// 3. **A cut answer says so.** `shown` carries the guest row's wording, and
///    what is cut is the OLDEST end.
/// 4. **No guest has standing over it.** A machine that declined agent access
///    does not deny a read of this Mac's own log.
@MainActor
final class AgentIntegrationHostLogTailTests: XCTestCase {
    private let policy = AgentIntegrationHostLogPolicy.self

    override func setUp() async throws {
        try await super.setUp()
        /* The switch OFF for every test in this file, deliberately: this row
           must answer out of the ring, and a suite that ran with disk
           logging on could not tell the two apart. */
        HostLog.shared.setPersistsToDisk(false)
    }

    /// An area tag unique to one test, within the six characters the log's
    /// own tag field holds.
    private func tag(_ seed: String) -> String {
        String("t\(abs(seed.hashValue) % 99999)".prefix(6))
    }

    // MARK: - It reads what HostLog wrote

    func testItReturnsTheLinesHostLogActuallyWroteOldestLast() {
        let area = tag(#function)
        HostLog.shared.write(.info, area, "first")
        HostLog.shared.write(.warn, area, "second")
        HostLog.shared.write(.error, area, "third")

        let tail = HostLogTailReader.read(lines: 10, area: area)

        XCTAssertEqual(tail.lines.count, 3)
        XCTAssertTrue(tail.lines[0].hasSuffix("first"))
        XCTAssertTrue(
            tail.lines[1].hasSuffix("? second"),
            "The warn marker is the log's own and must cross untouched: "
                + "\(tail.lines[1])")
        XCTAssertTrue(
            tail.lines[2].hasSuffix("! third"),
            "Oldest first, so the LAST line is the most recent thing that "
                + "happened: \(tail.lines)")
        XCTAssertEqual(tail.shown, "3 of 3")
        XCTAssertEqual(tail.matching, 3)
    }

    /// The ring is served whether or not anything reaches the disk.
    ///
    /// This is the row's reason for existing, so it is asserted rather than
    /// assumed: with the switch off there is no file, `file` is null, and the
    /// lines are still there.
    /// The file is switched ON and then OFF inside the test, deliberately:
    /// the sharp case is not "there was never a file", it is "there WAS one
    /// and there is not now". `HostLog` used to keep `url` past the close, so
    /// this row would have reported a path beside `persistsToDisk: false` and
    /// left an agent to guess which of the two was true. (Found by this test
    /// on a full run, where another suite had opened a file first.)
    func testItServesTheRingWhileTheDiskSwitchIsOff() {
        let area = tag(#function)
        HostLog.shared.setPersistsToDisk(true)
        XCTAssertNotNil(HostLog.shared.url,
                        "The test needs a file to have existed, or it is not "
                            + "exercising the stale-path case at all.")
        HostLog.shared.setPersistsToDisk(false)

        HostLog.shared.write(.info, area, "evidence that survives the switch")
        let tail = HostLogTailReader.read(lines: 5, area: area)

        XCTAssertFalse(tail.persistsToDisk)
        XCTAssertNil(
            tail.file,
            "A path beside a false switch names a file nothing is writing.")
        XCTAssertEqual(tail.lines.count, 1,
                       "The ring answered with no file behind it.")
    }

    // MARK: - The area filter

    func testTheAreaFilterKeepsOneSubsystemAndCountsOnlyIt() {
        let mine = tag(#function)
        let other = tag(#function + "other")
        HostLog.shared.write(.info, other, "noise")
        HostLog.shared.write(.info, mine, "signal")
        HostLog.shared.write(.info, other, "more noise")

        let tail = HostLogTailReader.read(lines: 100, area: mine)

        XCTAssertEqual(tail.lines.count, 1)
        XCTAssertEqual(tail.matching, 1)
        XCTAssertEqual(tail.area, mine)
        XCTAssertTrue(tail.lines[0].contains(mine))
        XCTAssertFalse(tail.lines.contains { $0.contains("noise") })
    }

    /// Unfiltered is a different answer, and a bigger one — the guard against
    /// a filter that silently applies itself.
    func testNoFilterReturnsEveryArea() {
        let mine = tag(#function)
        HostLog.shared.write(.info, mine, "one")

        let filtered = HostLogTailReader.read(lines: 2000, area: mine)
        let everything = HostLogTailReader.read(lines: 2000, area: nil)

        XCTAssertNil(everything.area)
        XCTAssertGreaterThan(
            everything.matching, filtered.matching,
            "The suite has written under other areas; an unfiltered read "
                + "that matched only one is a filter applying itself.")
    }

    /// An area wider than the tag field is REFUSED, not answered empty.
    ///
    /// `HostLog.write` truncates a tag to six characters, so "continuity"
    /// could never match a line. An empty tail is indistinguishable from a
    /// quiet subsystem, which is precisely the wrong conclusion to hand
    /// somebody diagnosing one.
    func testAnAreaWiderThanTheTagIsRefusedRatherThanAnsweredEmpty() async {
        let outcome = await HostLogTailProjection.invoke(
            .init(raw: ["area": "continuity"]), through: NoHostStub())

        guard case .invalidArguments(let message) = outcome else {
            return XCTFail(
                "An unmatchable area was accepted: \(outcome). An empty tail "
                    + "reads as a silent subsystem.")
        }
        XCTAssertTrue(message.contains("\(policy.areaTagScalars)"),
                      "The refusal states the width: \(message)")
    }

    func testAnEmptyAreaIsRefused() async {
        guard case .invalidArguments = await HostLogTailProjection.invoke(
            .init(raw: ["area": ""]), through: NoHostStub()) else {
            return XCTFail("An empty area matched nothing and was accepted.")
        }
    }

    // MARK: - The count, and its bound

    /// The maximum is the ring's own capacity, read from one constant.
    ///
    /// Two numbers that agree today are two numbers; this asserts they are
    /// one — the standing rule that a limit is stated once where both sides
    /// read it.
    func testTheMaximumIsTheRingsOwnCapacityAndNotASecondNumber() {
        XCTAssertEqual(policy.maximumLineCount, HostLog.ringCapacity)
        XCTAssertEqual(HostLog.ringCapacity, policy.ringCapacity)

        let schema = HostLogTailProjection.mcpDescriptor["inputSchema"]
            as? [String: Any]
        let lines = (schema?["properties"] as? [String: Any])?["lines"]
            as? [String: Any]
        XCTAssertEqual(
            lines?["maximum"] as? Int, HostLog.ringCapacity,
            "The published maximum is the ring's, or a caller is told a "
                + "bound the row does not keep.")
    }

    func testOutOfRangeCountsAreRefusedRatherThanClamped() async {
        for bad in [0, -1, policy.maximumLineCount + 1] {
            guard case .invalidArguments = await HostLogTailProjection.invoke(
                .init(raw: ["lines": bad]), through: NoHostStub()) else {
                return XCTFail(
                    "\(bad) lines was accepted; a silently smaller answer to "
                        + "a bigger question is how a reader concludes the "
                        + "machine went quiet.")
            }
        }
    }

    /// `true` bridges to an NSNumber that casts to 1, so a flag would be
    /// answered with one line of log. It is refused before the integer is
    /// read.
    ///
    /// **Through JSONSerialization, deliberately.** A Swift `Bool` in an
    /// `[String: Any]` does not cast to `Int` at all, so a test that wrote
    /// one would pass with the guard deleted — it would be asserting Swift's
    /// bridging rules rather than this row's. What the MCP face actually
    /// hands a projection is a parsed JSON graph, whose `true` is an
    /// NSNumber, and that IS `as? Int`. (Watched: with the guard removed and
    /// a literal `true`, this test passed.)
    func testABooleanCountIsRefusedBeforeItBecomesOne() async throws {
        let raw = try JSONSerialization.jsonObject(
            with: Data(#"{"lines": true}"#.utf8))
        XCTAssertNotNil(
            (raw as? [String: Any])?["lines"] as? Int,
            "If a JSON true stops casting to Int, this test no longer "
                + "exercises the guard it names.")

        guard case .invalidArguments = await HostLogTailProjection.invoke(
            .init(raw: raw), through: NoHostStub()) else {
            return XCTFail("A boolean count was read as one line.")
        }
    }

    func testTheWholeRingIsAValidRequest() async {
        let outcome = await HostLogTailProjection.invoke(
            .init(raw: ["lines": policy.maximumLineCount]),
            through: RecordingStub())
        guard case .value = outcome else {
            return XCTFail("The ring's own size was refused: \(outcome)")
        }
    }

    func testABareCallIsCompleteAndAskingWithNothingUsesTheDefault() async {
        let stub = RecordingStub()
        guard case .value = await HostLogTailProjection.invoke(
            .init(raw: nil), through: stub) else {
            return XCTFail("A bare call was refused; every member is optional.")
        }
        let asked = await stub.asked
        XCTAssertEqual(asked.count, 1)
        XCTAssertNil(
            asked[0].lines,
            "Absent must cross as absent: substituting the number here would "
                + "put the default in two places.")

        /* And the reader is where absent becomes the default. */
        XCTAssertEqual(
            HostLogTailReader.read(lines: nil, area: nil).requested,
            policy.defaultLineCount)
    }

    func testAnUnknownArgumentIsRefusedNamingBothHalves() async {
        guard case .invalidArguments(let message) =
                await HostLogTailProjection.invoke(
                    .init(raw: ["count": 10]), through: NoHostStub()) else {
            return XCTFail("An unknown key was ignored rather than refused.")
        }
        XCTAssertTrue(message.contains("count"), message)
        XCTAssertTrue(message.contains("lines"), message)
    }

    // MARK: - A cut answer says so

    /// The budget drops the OLDEST lines and reports it, the way the guest
    /// row's `shown` does.
    func testATruncatedAnswerSaysSoAndKeepsTheNewestLines() {
        let area = tag(#function)
        let filler = String(repeating: "x", count: 480)
        let count = 40
        for index in 0..<count {
            HostLog.shared.write(.info, area, "\(index) \(filler)")
        }

        let tail = HostLogTailReader.read(lines: count, area: area)

        XCTAssertLessThan(
            tail.lines.count, count,
            "40 lines of ~500 scalars exceed the budget of "
                + "\(policy.maximumTotalScalars); if this stops being true "
                + "the test is no longer exercising truncation.")
        XCTAssertEqual(tail.shown,
                       "\(tail.lines.count) of \(count) (older ones did not fit)")
        XCTAssertTrue(
            tail.lines.last?.contains("\(count - 1) ") == true,
            "The newest line survives — a diagnosis reads backwards from "
                + "what just happened.")
        XCTAssertEqual(
            tail.matching, count,
            "matching reports what the ring holds, so a caller can tell a "
                + "short log from a cut answer.")
    }

    func testAnUncutAnswerDoesNotClaimToBeCut() {
        let area = tag(#function)
        HostLog.shared.write(.info, area, "one")
        HostLog.shared.write(.info, area, "two")

        let tail = HostLogTailReader.read(lines: 40, area: area)
        XCTAssertEqual(tail.shown, "2 of 2")
        XCTAssertFalse(tail.shown.contains("did not fit"))
    }

    /// A control character is written as `\xNN` rather than dropped or passed
    /// through: passed through it corrupts the row it travels in, and dropped
    /// it loses evidence in the one place somebody is looking for it.
    func testAControlCharacterIsEscapedRatherThanDroppedOrPassedThrough() {
        let area = tag(#function)
        HostLog.shared.write(.info, area, "before\u{07}after")

        let line = HostLogTailReader.read(lines: 1, area: area).lines[0]
        XCTAssertTrue(line.contains("\\x07"), line)
        XCTAssertFalse(line.unicodeScalars.contains { $0.value == 7 })
        XCTAssertTrue(line.contains("beforeafter") == false && line.contains("before"),
                      "The surrounding text survives the escape: \(line)")
    }

    func testALineIsBoundedSoOneCannotEatTheWholeBudget() {
        let area = tag(#function)
        HostLog.shared.write(.info, area,
                             String(repeating: "y", count: 5_000))

        let line = HostLogTailReader.read(lines: 1, area: area).lines[0]
        XCTAssertEqual(line.unicodeScalars.count, policy.maximumLineScalars)
        XCTAssertTrue(line.hasSuffix("…"), "A cut line shows it was cut.")
    }

    // MARK: - Whose authority it spends

    /// A machine that declined agent access does not deny a read of THIS
    /// Mac's log. The dispatch is the gate, so it is asked rather than the
    /// row.
    func testAGuestThatDeclinedDoesNotDenyThisMacsOwnLog() async {
        let dispatch = HostProjectionDispatch(
            face: .mcp, audit: SilentAudit())

        let outcome = await dispatch.invoke(
            HostLogTailProjection.capability.rawValue,
            arguments: .init(raw: [:]), guest: nil,
            through: DecliningGuestStub())

        guard case .value = outcome else {
            return XCTFail(
                "A guest's refusal denied a read of this Mac's own log: "
                    + "\(String(describing: outcome)). Consent is about the "
                    + "machine that gave it.")
        }
    }

    func testItTakesNoGuestSelectorAndAsksNoGuestAnything() {
        XCTAssertFalse(HostLogTailProjection.acceptsGuestAddressing)
        XCTAssertEqual(HostLogTailProjection.authorityDomain,
                       .hostApplication)
        XCTAssertFalse(
            HostProjectionAuthorityDomain.hostApplication
                .isGuestConsentRelevant)
        XCTAssertTrue(HostLogTailProjection.requires.isEmpty)
        XCTAssertTrue(HostLogTailProjection.exposes.isEmpty)
    }

    /// The refusal a caller reads when they name a guest describes THIS row,
    /// not the projects storage the exemption used to be spelled for.
    func testTheAddressingRefusalDoesNotSendTheCallerToProjects() {
        let subject = HostLogTailProjection.authorityDomain
            .addressingRefusalSubject
        XCTAssertFalse(
            subject.contains("project"),
            "A host-log refusal that says \"project storage\" sends somebody "
                + "to the wrong half of the product: \(subject)")
        XCTAssertEqual(
            HostProjectionAuthorityDomain.hostProjects
                .addressingRefusalSubject,
            "operates on host-owned project storage",
            "And the projects wording is unchanged by that split.")
    }

    // MARK: - The areas the description offers

    /// **Every area the tool description names is one this host writes.**
    ///
    /// The description is built from `areaExamples`, so there is one list
    /// rather than a sentence and a set; this is what keeps that list honest.
    /// An agent that filters on a tag nothing produces gets an empty tail and
    /// reads it as a silent subsystem — the same failure the over-wide area
    /// refusal exists to prevent, arriving by the other route.
    ///
    /// It reads the app's own source for the evidence, the way
    /// `HostFaceParityTests` does, rather than keeping a second list here.
    func testEveryAreaTheDescriptionOffersIsOneTheHostWrites() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // now-host
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("now-host/Sources/Host")

        /* Any first argument that is not itself a string, then the area:
           the level is sometimes a literal `.warn`, sometimes a forwarded
           `$0` (the continuity controller's audit closure is the latter, and
           a narrower pattern missed all four of its files — which this test
           caught on its first run). */
        let pattern = try NSRegularExpression(
            pattern: #"\.write\(\s*(?:[^,()"]{0,40},\s*)?"([A-Za-z]+)""#)
        var written = Set<String>()
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("Could not read \(root.path)")
        }
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let whole = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: whole) {
                guard let range = Range(match.range(at: 1), in: text) else {
                    continue
                }
                written.insert(String(
                    String(text[range]).prefix(
                        AgentIntegrationHostLogPolicy.areaTagScalars)))
            }
        }

        XCTAssertTrue(
            written.contains("contin"),
            "The scan found no continuity lines, so it is not reading the "
                + "app's log calls and this gate proves nothing. Found: "
                + "\(written.sorted().joined(separator: ", "))")

        for area in HostLogTailProjection.areaExamples {
            XCTAssertTrue(
                written.contains(area),
                "The description offers \"\(area)\" as an area and no "
                    + "HostLog.write under now-host/Sources/Host produces it. "
                    + "An agent that filters on it gets an empty tail and "
                    + "reads it as a silent subsystem. This host writes: "
                    + "\(written.sorted().joined(separator: ", "))")
        }

        let description = HostLogTailProjection
            .mcpDescriptor["description"] as? String ?? ""
        for area in HostLogTailProjection.areaExamples {
            XCTAssertTrue(
                description.contains("\"\(area)\""),
                "The description is supposed to be built from the list; "
                    + "\(area) is in the list and not in the sentence.")
        }
    }

    // MARK: - The local codec

    func testTheLocalCodecCarriesBothFieldsAndRefusesEitherOutOfRange()
        throws {
        let request = AgentIntegrationLocalRequest.hostLogTail(
            lines: 40, area: "contin")
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(request))
        XCTAssertEqual(decoded.operation, .hostLogTail)
        XCTAssertEqual(decoded.hostLogLineCount, 40)
        XCTAssertEqual(decoded.hostLogArea, "contin")

        for bad in [AgentIntegrationLocalRequest.hostLogTail(
                        lines: policy.maximumLineCount + 1),
                    .hostLogTail(area: "continuity")] {
            let data = try AgentIntegrationLocalCodec.encode(bad)
            XCTAssertThrowsError(
                try AgentIntegrationLocalCodec.decodeRequest(data),
                "The socket is reachable by anything that speaks it, so the "
                    + "bound is kept here too.")
        }
    }

    func testABareHostLogRequestIsAComplete() throws {
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(.hostLogTail()))
        XCTAssertEqual(decoded.operation, .hostLogTail)
        XCTAssertNil(decoded.hostLogLineCount)
        XCTAssertNil(decoded.hostLogArea)
    }

    func testTheResponseCarriesTheTailAsItsOneResult() throws {
        let area = tag(#function)
        HostLog.shared.write(.info, area, "one line, over the socket")
        /* A whole second, because the wire's dates are ISO-8601 and a
           sub-second fraction does not survive the round trip. That is the
           codec's shape rather than this row's, and pinning it here keeps
           the assertion about the payload. */
        let tail = HostLogTailReader.read(
            lines: 1, area: area,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        let response = AgentIntegrationLocalResponse(
            requestID: UUID(), hostLogTailResult: .completed(tail))
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(
            AgentIntegrationLocalCodec.encode(response))
        guard case .completed(let round) = decoded.hostLogTailResult else {
            return XCTFail("The host log result did not survive the codec.")
        }
        XCTAssertEqual(round, tail)
    }
}

// MARK: - Stubs

/// The nine oldest protocol requirements have no defaults — history, not the
/// pattern — so they are answered once here rather than three times below.
/// "No host" throughout: none of these lanes is what this file is about.
private protocol HostLogStub: AgentIntegrationClient {}

extension HostLogStub {
    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult { .unavailable(.host) }
    func listProcesses() async
        -> AgentIntegrationProcessListResult { .unavailable(.host) }
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult { .unavailable(.host) }
    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult { .unavailable(.host) }
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult { .unavailable(.host) }
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult { .hostUnavailable(.host) }
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult { .hostUnavailable(.host) }
}

/// No host at all: everything falls to the protocol's own defaults.
private struct NoHostStub: HostLogStub {
    func addressing(_ selector: String?) -> AgentIntegrationClient { self }
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }
}

/// Records what the row asked for, and answers a tail read off the real ring
/// — so even the stub does not invent a log.
private actor RecordingStub: HostLogStub {
    private(set) var asked: [(lines: Int?, area: String?)] = []

    nonisolated func addressing(_ selector: String?)
        -> AgentIntegrationClient { self }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func hostLogTail(lines: Int?, area: String?) async
        -> AgentIntegrationHostLogTailResult {
        asked.append((lines, area))
        return .completed(await MainActor.run {
            HostLogTailReader.read(lines: lines, area: area)
        })
    }
}

/// A reachable host with one machine connected that answered `hello.agent`
/// with `disabled` — the machine refuses to be read at all.
private struct DecliningGuestStub: HostLogStub {
    func addressing(_ selector: String?) -> AgentIntegrationClient { self }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .available(.init(
            state: .connected,
            observedAt: Date(timeIntervalSince1970: 0),
            listeningPort: 1400,
            sessionID: nil,
            guest: .init(name: "pb1400c", version: "0.1.0",
                         agentAccess: .disabled,
                         operatingSystem: "Mac OS 9.1",
                         connectedAt: nil, lastTraffic: nil, quietFor: nil,
                         pingsAnswered: nil, framesReceived: nil),
            failure: nil))
    }

    func hostLogTail(lines: Int?, area: String?) async
        -> AgentIntegrationHostLogTailResult {
        .completed(await MainActor.run {
            HostLogTailReader.read(lines: lines, area: area)
        })
    }
}

private actor SilentAudit: HostProjectionAuditSink {
    func record(_ event: HostProjectionAuditEvent) async {}
}
