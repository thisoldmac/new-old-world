import XCTest
@testable import Host
import NOWAgentIntegration

/// The reveal capability's own coverage, aimed at the two things that are
/// genuinely its own: **that a completed answer claims only that the machine
/// was asked**, and **that a call which changed somebody's screen left a line
/// naming what appeared on it**.
///
/// Both halves matter because this is the smallest capability in the set. The
/// guest sends its Finder one no-reply Apple Event and asks it forward; `ok`
/// therefore means "asked", and the cheap mistake is to let the word
/// "revealed" — which the guest itself uses — travel as a confirmation.
///
/// Nothing here constructs the message it then parses. A fake guest answers
/// the `reveal` command with what a real one answers, and every assertion is
/// about what the host did with it.
@MainActor
final class AgentIntegrationRevealTests: XCTestCase {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Answers the `reveal` command, recording the target it was asked
    /// about. `reply` nil means the guest never answers at all, which is the
    /// case the timeout exists for.
    private func installResponder(
        on guest: FakeGuest,
        target: Box<String?> = Box(nil),
        count: Box<Int> = Box(0),
        reply: ((Int) -> CommandResult)? = { id in
            .init(id: id, ok: true,
                  output: ["reveal": [["Reveal",
                                       "revealed SimpleText in the Finder"]]],
                  error: nil)
        }
    ) {
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == "reveal":
                count.value += 1
                target.value = request.args?["target"]
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
        timeout: TimeInterval = 5
    ) -> AgentIntegrationRevealItem {
        AgentIntegrationRevealItem(
            listener: listener,
            currentSessionID: { UUID(uuidString: Self.session) },
            commandTimeout: timeout,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            audit: audit)
    }

    private static let session = "5b6d9a44-0000-4000-8000-000000000000"

    // MARK: - Asked is not confirmed

    /// The guest's rows arrive as the guest wrote them, and the row is the
    /// whole of the answer — there is no confirmation field, because nothing
    /// on this wire could fill one honestly.
    ///
    /// The assertion that matters is the last one: the result carries the
    /// guest's sentence and **no** host-invented claim beside it. A future
    /// edit that appended "fronted" or "confirmed" to this answer without
    /// something new to confirm it fails here.
    func testACompletedRevealCarriesTheGuestsWordsAndNoHostClaim()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let asked = Box<String?>(nil)
        installResponder(on: guest, target: asked)

        let result = await adapter(listener).reveal(
            target: "Macintosh HD:Apps:SimpleText")

        guard case .completed(let report) = result else {
            return XCTFail("an answered reveal is a completed reveal: "
                               + "\(result)")
        }
        XCTAssertEqual(asked.value, "Macintosh HD:Apps:SimpleText")
        XCTAssertEqual(report.verb, "reveal")
        XCTAssertEqual(report.groups.map(\.name), ["reveal"])
        XCTAssertEqual(report.groups.first?.rows.first?.label, "Reveal")
        XCTAssertEqual(report.groups.first?.rows.first?.value,
                       "revealed SimpleText in the Finder")
        XCTAssertNil(
            report.note,
            "The note is the GUEST's sentence about the edges of its own "
                + "answer. A host filling it would be putting host words "
                + "where the type promises the machine's.")
        let text = String(
            decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for claimed in ["confirmed", "fronted", "selected"] {
            XCTAssertFalse(
                text.contains(claimed),
                "The answer claims \"\(claimed)\". The guest's Apple Event "
                    + "is sent kAENoReply and the front switch is "
                    + "cooperative, so nothing here can know any of that; "
                    + "asked is the only honest claim.")
        }
    }

    /// A guest refusal stays a refusal, and its **own sentence** crosses —
    /// which is how "the Finder is not running" reaches a caller at all.
    ///
    /// `reveal` answers every refusal with one code, so the words are the
    /// only distinction there is; the host does not read them to invent a
    /// typed one. Forwarding is safe because those sentences quote the
    /// caller's own target and nothing else — which is exactly what the `#n`
    /// refusal below protects.
    func testTheGuestsOwnRefusalSentenceCrossesUnderOneCode() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: { id in
            .init(id: id, ok: false, output: nil,
                  error: .init(code: "reveal-refused",
                               message: "the Finder is not running"))
        })

        let result = await adapter(listener).reveal(target: "SimpleText")

        guard case .refused(let failure) = result else {
            return XCTFail("a guest refusal must remain a refusal")
        }
        XCTAssertEqual(failure.code, "now-reveal-refused")
        XCTAssertEqual(failure.message, "the Finder is not running")
    }

    /// A guest that never answers is a typed refusal naming the unknown,
    /// never a completed reveal. Something may still appear on the screen
    /// afterwards, and the answer must not pretend to know.
    func testAnUnansweredRevealIsRefusedWithTheOutcomeUnknown()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let count = Box(0)
        installResponder(on: guest, count: count, reply: nil)

        let result = await adapter(listener, timeout: 0.2).reveal(
            target: "SimpleText")

        guard case .refused(let failure) = result else {
            return XCTFail("silence is not a completed reveal")
        }
        XCTAssertEqual(failure.code, "now-reveal-outcome-unknown")
        XCTAssertEqual(count.value, 1)
    }

    /// No guest, no answer about a guest — `unavailable`, not a refusal, and
    /// nothing is sent.
    func testADisconnectedGuestIsUnavailableRatherThanRefused() async {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let control = AgentIntegrationRevealItem(
            listener: disconnected,
            currentSessionID: { nil })

        let result = await control.reveal(target: "SimpleText")

        guard case .unavailable(let missing) = result else {
            return XCTFail("a disconnected guest cannot refuse anything")
        }
        XCTAssertEqual(missing.code, "now-guest-unavailable")
    }

    // MARK: - Rule 3: the person whose screen changed

    /// **A reveal that reached the machine leaves a line naming the target.**
    ///
    /// This is the rule-3 half, and the reason it is not left to the audit
    /// event: that event deliberately carries no arguments, so it says a
    /// reveal happened and cannot say what appeared. For this capability the
    /// target IS the event — the same reason the guest-Files family logs its
    /// paths — and a person whose Finder just came forward needs the name to
    /// connect the two.
    func testAnAskedRevealLogsTheTargetAndSaysItIsOnlyAnAsk() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest)
        let lines = Box<[(HostLog.LogLevel, String)]>([])

        _ = await adapter(listener, audit: { lines.value.append(($0, $1)) })
            .reveal(target: "Macintosh HD:Apps:SimpleText")

        XCTAssertEqual(lines.value.count, 1)
        let line = try XCTUnwrap(lines.value.first)
        XCTAssertEqual(line.0, .info)
        XCTAssertTrue(
            line.1.contains("Macintosh HD:Apps:SimpleText"),
            "The line does not name what appeared: \(line.1)")
        XCTAssertTrue(
            line.1.contains("asked"),
            "The line reads as a confirmation rather than an ask: \(line.1)")
    }

    /// A refusal logs too, at warn, and a control byte in the target is
    /// escaped rather than written raw into the row the Logs page draws.
    /// Control bytes are legal in an HFS name and arrive from callers.
    func testARefusalLogsAtWarnWithControlBytesEscaped() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest, reply: { id in
            .init(id: id, ok: false, output: nil,
                  error: .init(code: "reveal-refused",
                               message: "nothing named that to reveal"))
        })
        let lines = Box<[(HostLog.LogLevel, String)]>([])

        _ = await adapter(listener, audit: { lines.value.append(($0, $1)) })
            .reveal(target: "Simple\u{07}Text")

        let line = try XCTUnwrap(lines.value.first)
        XCTAssertEqual(line.0, .warn)
        XCTAssertTrue(line.1.contains("\\x07"), line.1)
        XCTAssertFalse(line.1.contains("\u{07}"), "a raw control byte")
    }

    // MARK: - The projection's own bound

    /// The target is the only thing a caller may send, and `#n` is not one.
    ///
    /// The pick form indexes a match list the guest shares with **whoever
    /// searched last**, including the person at the machine's own console, so
    /// the same string names different items at different moments. That is
    /// the stale-positional-reference hazard the opaque-reference vocabulary
    /// exists to avoid, and refusing it is also what keeps the guest's
    /// forwarded refusal sentences free of items the caller never named.
    func testTheProjectionTakesOneBoundedTargetAndNeverAPick() async {
        let expected =
            "now_reveal_item requires one bounded target: a full HFS path "
                + "or an item name, never a #n pick"
        let refused: [Any?] = [
            nil,
            [String: Any](),
            ["path": "Macintosh HD:Apps:SimpleText"],
            ["target": ""],
            ["target": "#1"],
            ["target": String(repeating: "x", count: 256)],
            ["target": "SimpleText", "extra": 1],
        ]
        for raw in refused {
            let outcome = await RevealItemProjection.invoke(
                .init(raw: raw), through: RevealStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "accepted \(String(describing: raw)) as a target")
            }
            XCTAssertEqual(message, expected)
        }
    }

    /// The adapter refuses a pick too, so the bound is not the projection's
    /// alone. It matters because the local codec — landed for eleven verbs at
    /// once and not this row's to change — admits `#n` as a bounded selector:
    /// a caller composing its own local request must still not get one
    /// through.
    func testTheAdapterRefusesAPickEvenThoughTheCodecWouldCarryIt()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let count = Box(0)
        installResponder(on: guest, count: count)

        let result = await adapter(listener).reveal(target: "#2")

        guard case .refused(let failure) = result else {
            return XCTFail("a pick is not a target")
        }
        XCTAssertEqual(failure.code, "now-reveal-target-invalid")
        XCTAssertEqual(count.value, 0, "the machine was asked anyway")
    }

    /// A valid target reaches the host verbatim and the answer survives
    /// rendering — the projection renders and does not re-decide.
    func testAValidTargetIsPassedThroughAndTheAnswerSurvives() async throws {
        let host = RevealStubHost()
        let outcome = await RevealItemProjection.invoke(
            .init(raw: ["target": "Macintosh HD:Apps:SimpleText"]),
            through: host)

        guard case .value(let value) = outcome else {
            return XCTFail("a valid target should reach the host")
        }
        let asked = await host.asked
        XCTAssertEqual(asked, ["Macintosh HD:Apps:SimpleText"])
        let json = String(
            decoding: try value.encoded(using: JSONEncoder()), as: UTF8.self)
        XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
        XCTAssertTrue(json.contains("revealed SimpleText in the Finder"))
        XCTAssertNil(
            value.attachment,
            "This row answers in JSON; only capture attaches anything.")
    }

    /// The row exposes the command it lets a caller direct, and requires
    /// nothing else — in particular not the `process.list` that would let it
    /// pre-check for a Finder, which is the guest's call to make and not
    /// this side's from a listing taken a moment earlier.
    func testTheRowRequiresTheCommandAndNothingItWouldDecideWith() {
        XCTAssertEqual(
            RevealItemProjection.requires,
            [AgentIntegrationCapabilityNames.revealCommand])
        XCTAssertEqual(
            RevealItemProjection.exposes,
            [AgentIntegrationCapabilityNames.revealCommand])
        XCTAssertFalse(
            RevealItemProjection.requires.contains(
                AgentIntegrationCapabilityNames.processList),
            "Requiring the process listing would make this row unavailable "
                + "against a guest that serves reveal, to support a "
                + "precondition the guest checks better at the moment it "
                + "acts.")
    }

    /// The rendering is bounded, and a guest that answers something larger
    /// or stranger than the contract's one row is carried rather than
    /// trusted: extra groups and rows are cut at the declared bound, and a
    /// one-cell row does not become a row that says the same thing twice.
    func testTheRowReportRenderingIsBoundedAndDoesNotInvent() {
        let bounds = AgentIntegrationRevealItemBounds.self
        let many = (0..<(bounds.maximumRowsPerGroup + 4)).map {
            ["Label \($0)", "Value \($0)"]
        }
        let result = CommandResult(
            id: 1, ok: true,
            output: [
                "reveal": many,
                "extra": [["only-one-cell"]],
            ],
            error: nil)

        let report = AgentIntegrationRevealItem.report(
            from: result, observedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(report.verb, "reveal")
        XCTAssertEqual(report.groups.map(\.name), ["extra", "reveal"])
        XCTAssertEqual(report.groups.last?.rows.count,
                       bounds.maximumRowsPerGroup)
        let lone = try? XCTUnwrap(report.groups.first?.rows.first)
        XCTAssertEqual(lone?.label, "only-one-cell")
        XCTAssertEqual(
            lone?.value, "",
            "A one-cell row has no value, and repeating the label as one "
                + "would be this side inventing an answer.")
    }
}

/// Answers one reveal and records the targets it was asked about. Everything
/// else answers "no host", which is what the protocol's defaults are for.
private actor RevealStubHost: AgentIntegrationClient {
    private(set) var asked: [String] = []

    func revealItem(target: String) async
        -> AgentIntegrationGuestRowReportResult {
        asked.append(target)
        return .completed(.init(
            verb: "reveal",
            groups: [.init(name: "reveal",
                           rows: [.init(
                               label: "Reveal",
                               value: "revealed SimpleText in the Finder")])],
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
