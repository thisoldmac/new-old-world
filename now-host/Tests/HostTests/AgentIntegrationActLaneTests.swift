import XCTest
@testable import Host
import NOWAgentIntegration

/// **The act lane's own coverage** — what it takes for a click on a rendered
/// scene to reach a Macintosh, and the three things this lane is allowed to
/// claim when it gets there.
///
/// Every assertion here is about what the HOST did with what a fake guest
/// answered. Nothing constructs the reply it then reads, and nothing asserts
/// against a machine: the guest half is served and metal-proven elsewhere,
/// and a host test that asserted about a PowerBook would be asserting about
/// a fixture.
///
/// The four properties, in the order they matter:
///
/// 1. **`dispatched` comes off the machine or the call is refused.** A guest
///    that answers `ok` with no `Dispatch` row has said something this
///    surface has no vocabulary for. The receipt is not filled in from the
///    request — that is the one failure the whole projection seam exists to
///    make visible, and it is the mutation this file is built to catch.
/// 2. **An act does not take the transfer lane.** A scene, a capture and a
///    stream all hold one; an act must reach the wire while one is held, or
///    a click in a live mirror would be refused by the stream that is
///    drawing it.
/// 3. **Identity is the guard.** No spelling of "the frontmost" survives
///    the codec, and a reference that is not one is refused rather than
///    resolved.
/// 4. **A refusal is the guest's own sentence.** `act-not-taken` and
///    `act-timeout` are the machine's words, and reading them to invent a
///    typed code would be this side deciding what happened where it cannot
///    see.
@MainActor
final class AgentIntegrationActLaneTests: XCTestCase {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let session = "5b6d9a44-0000-4000-8000-000000000001"
    private static let window =
        "now-window-11111111-2222-4333-8444-555555555555"
    private static let element =
        "now-element-11111111-2222-4333-8444-555555555555"

    private func adapter(
        _ listener: GuestListener,
        audit: @escaping (HostLog.LogLevel, String) -> Void = { _, _ in },
        timeout: TimeInterval = 5
    ) -> AgentIntegrationActControl {
        AgentIntegrationActControl(
            listener: listener,
            currentSessionID: { UUID(uuidString: Self.session) },
            commandTimeout: timeout,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            audit: audit)
    }

    /// Answers one act verb the way the PowerPC guest answers it, recording
    /// the arguments it was handed. `reply` nil means the guest never
    /// answers, which is the case the timeout exists for.
    private func installResponder(
        on guest: FakeGuest,
        verb: String,
        seen: Box<[String: String]?> = Box(nil),
        count: Box<Int> = Box(0),
        reply: ((Int) -> CommandResult)?
    ) {
        guest.onMessage = { message in
            switch message {
            case .commandRequest(let request) where request.name == verb:
                count.value += 1
                seen.value = request.args
                guard let reply else { return }
                try? guest.send(.commandResult(reply(request.id)))
            default:
                break
            }
        }
    }

    /// The rows a real `winact` answers with, as `act_cmds.c` writes them.
    private static func winactRows(id: Int) -> CommandResult {
        .init(id: id, ok: true, output: ["winact": [
            ["Window", window],
            ["Action", "move"],
            ["Dispatch", "dispatched"],
            ["Mechanism",
             "the window manager, in the application's own context"],
            ["Re-read", "40, 60 to 440, 360"],
        ]], error: nil)
    }

    // MARK: - 1. Dispatched comes off the machine

    /// A completed window act carries the machine's dispatch and the target
    /// this call named, and **nothing that would read as "it worked"**.
    ///
    /// The last assertion is the load-bearing one and mirrors the reveal
    /// lane's: an edit that appended a rectangle, a `performed`, or a
    /// `moved` to this receipt fails here. Where the window ended up is a
    /// question for an observation; the guest's own `Re-read` row is real
    /// evidence and is deliberately NOT merged into this claim.
    func testACompletedWindowActClaimsOnlyThatTheEventWasDispatched()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        installResponder(on: guest, verb: "winact", seen: seen) {
            Self.winactRows(id: $0)
        }

        let result = await adapter(listener).windowAct(.init(
            window: Self.window, action: .move, left: 40, top: 60))

        guard case .completed(let receipt) = result else {
            return XCTFail("an answered act is a completed act: \(result)")
        }
        XCTAssertEqual(seen.value?["window"], Self.window)
        XCTAssertEqual(seen.value?["action"], "move")
        XCTAssertEqual(seen.value?["left"], "40")
        XCTAssertEqual(seen.value?["top"], "60")
        XCTAssertNil(seen.value?["width"],
                     "a move carries no extent, and the host must not "
                         + "invent one to fill the argument out")
        XCTAssertEqual(receipt.window, Self.window)
        XCTAssertEqual(receipt.action, .move)
        XCTAssertEqual(receipt.dispatch, .dispatched)

        let text = String(
            decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for claimed in ["performed", "succeeded", "applied", "moved",
                        "changed", "40, 60 to 440, 360"] {
            XCTAssertFalse(
                text.contains(claimed),
                "The receipt claims \"\(claimed)\". The event was handed to "
                    + "the application and nothing on this side saw what it "
                    + "did with it; dispatched is the only honest word, and "
                    + "the guest's re-read is a SEPARATE claim.")
        }
    }

    /// **The mutation gate.** A guest that answers `ok` and no `Dispatch`
    /// row must not produce a receipt.
    ///
    /// This is the test that fails when somebody makes the lane construct
    /// `.dispatched` from the request instead of reading it off the reply —
    /// which is the cheapest possible way to make an act "succeed" without
    /// anything having happened on a Macintosh. It is written against the
    /// row's absence rather than its value because a one-case enum has no
    /// wrong value to send.
    func testAnOkWithNoDispatchRowIsRefusedRatherThanCompleted()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        installResponder(on: guest, verb: "winact") { id in
            .init(id: id, ok: true, output: ["winact": [
                ["Window", Self.window],
                ["Action", "close"],
                /* Everything a real reply carries EXCEPT the one row that
                   is a claim about the event. */
                ["Mechanism", "the application's own FindWindow"],
                ["Re-read", "the window is gone"],
            ]], error: nil)
        }

        let result = await adapter(listener).windowAct(.init(
            window: Self.window, action: .close))

        guard case .refused(let failure) = result else {
            return XCTFail(
                "A guest that never said the event was dispatched has not "
                    + "told this host that anything happened, and a receipt "
                    + "built from the request would be the host answering "
                    + "for the machine: \(result)")
        }
        XCTAssertEqual(failure.code, "now-window-act-outcome-unknown")
    }

    /// The same gate on the other three dispatching acts, so a fix applied
    /// to one of them cannot leave the others reporting from their own
    /// arguments.
    func testEveryDispatchingActNeedsTheMachinesDispatchRow() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let control = adapter(listener)

        installResponder(on: guest, verb: "ctlact") { id in
            .init(id: id, ok: true,
                  output: ["ctlact": [["Element", Self.element],
                                      ["Part", "10"]]], error: nil)
        }
        guard case .refused = await control.controlAct(
            .init(element: Self.element, part: 10)) else {
            return XCTFail("ctlact completed with no dispatch row")
        }

        installResponder(on: guest, verb: "menuact") { id in
            .init(id: id, ok: true,
                  output: ["menuact": [["Menu", "129"], ["Item", "3"]]],
                  error: nil)
        }
        guard case .refused = await control.menuAct(
            .init(menu: 129, item: 3, titleLeft: 44)) else {
            return XCTFail("menuact completed with no dispatch row")
        }

        installResponder(on: guest, verb: "textset") { id in
            .init(id: id, ok: true,
                  output: ["textset": [["Element", Self.element],
                                       ["Text", "hello"],
                                       ["Length", "5"],
                                       ["Returned", "5"],
                                       ["Truncated", "no"]]], error: nil)
        }
        guard case .refused = await control.setElementText(
            element: Self.element, text: "hello") else {
            return XCTFail("textset completed with no dispatch row")
        }
    }

    /// A reply carrying ANOTHER verb's group is not this call's answer.
    ///
    /// The lane reads the rows out of the group named for the verb it sent.
    /// A reader that took "whichever single group came back" would let one
    /// act's receipt be composed out of a different question's answer, which
    /// is the same class of mistake as trusting a stale reference.
    func testRowsUnderAnotherVerbsNameAreNotThisActsAnswer() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        installResponder(on: guest, verb: "menuact") { id in
            .init(id: id, ok: true,
                  output: ["ctlact": [["Dispatch", "dispatched"]]],
                  error: nil)
        }

        let result = await adapter(listener).menuAct(
            .init(menu: 129, item: 1, titleLeft: 44))

        guard case .refused = result else {
            return XCTFail("a ctlact group is not a menuact's answer: "
                               + "\(result)")
        }
    }

    // MARK: - 2. An act is not on the transfer lane

    /// **An act reaches the wire while the transfer lane is held.**
    ///
    /// The concrete failure this guards: a person watching a live mirror
    /// clicks a button in it. The stream holds the transfer lane for its
    /// whole life, so an act that consulted `transferLaneHolder` would be
    /// refused for exactly as long as the scene it is acting on is being
    /// drawn — the two would deadlock by design.
    ///
    /// A scene request is used to hold the lane because it is the cheapest
    /// holder to arrange, and `requestScene` refusing while it is held is
    /// what proves the lane is genuinely occupied.
    func testAnActIsNotRefusedByTheTransferLane() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        installResponder(on: guest, verb: "winact", seen: seen) {
            Self.winactRows(id: $0)
        }

        /* Hold the lane: a scene request the fake guest never answers. */
        listener.requestScene { _ in }
        XCTAssertTrue(listener.isScenePending)
        let blocked = Box<Bool>(false)
        listener.requestScene { result in
            if case .failure = result { blocked.value = true }
        }
        XCTAssertTrue(
            blocked.value,
            "the precondition of this test is that the transfer lane IS "
                + "held; if a second scene is not refused, the test below "
                + "proves nothing")

        let result = await adapter(listener).windowAct(.init(
            window: Self.window, action: .move, left: 40, top: 60))

        guard case .completed = result else {
            return XCTFail(
                "An act must reach the wire while a bulk transfer holds the "
                    + "lane. A click in a rendered scene that waited for the "
                    + "stream drawing that scene would never run: \(result)")
        }
        XCTAssertNotNil(seen.value, "the act never reached the guest")
    }

    // MARK: - 3. Identity is the guard

    /// No spelling of a target-free act survives the local codec, and
    /// neither does a reference that is merely a string.
    ///
    /// The list is deliberately long. Upstream measured the alternative at
    /// 18/20 hijacked, so what is being asserted is not "the parser is
    /// strict" but "there is no way to say it at all" — and the way that
    /// property breaks is somebody adding one convenient spelling.
    func testNoSpellingOfAFrontmostTargetReachesTheWire() throws {
        for spelling in ["frontmost", "front", "active", "current", "top",
                         "topmost", "focused", "foreground", "*", "",
                         "any", "0", "now-window-frontmost"] {
            XCTAssertThrowsError(
                try encodeThenDecode(.windowAct(.init(
                    window: spelling, action: .zoom))),
                "\"\(spelling)\" reached the wire as a window target. An "
                    + "act that cannot name what it acts on rides whatever "
                    + "the person at the machine does next.")
            XCTAssertThrowsError(
                try encodeThenDecode(.textGet(element: spelling)),
                "\"\(spelling)\" reached the wire as an element target.")
        }
    }

    /// The per-action geometry rule survives the socket. A `Codable` decode
    /// is happy to produce a close carrying a width; the codec is not, and
    /// the socket is the trust boundary — any process of this uid can write
    /// it without going near a projection row.
    func testTheCodecRefusesGeometryTheActionDoesNotTake() throws {
        XCTAssertThrowsError(try encodeThenDecode(.windowAct(.init(
            window: Self.window, action: .close, width: 400))))
        XCTAssertThrowsError(try encodeThenDecode(.windowAct(.init(
            window: Self.window, action: .zoom, left: 10, top: 10))))
        XCTAssertThrowsError(try encodeThenDecode(.windowAct(.init(
            window: Self.window, action: .move, left: 10))),
            "half a move names half a destination")
        XCTAssertThrowsError(try encodeThenDecode(.windowAct(.init(
            window: Self.window, action: .resize, width: 0, height: 10))),
            "a zero edge is not a window any machine could draw")
        XCTAssertThrowsError(try encodeThenDecode(.controlAct(
            .init(element: Self.element, part: 0))),
            "0 is not a ControlPartCode")
        XCTAssertThrowsError(try encodeThenDecode(.menuAct(
            .init(menu: 129, item: 0, titleLeft: 44))),
            "menu items are counted from 1, so 0 names nothing")
        XCTAssertThrowsError(try encodeThenDecode(.textSet(
            element: Self.element,
            text: String(repeating: "x",
                         count: AgentIntegrationActPolicy
                             .maximumTextScalars + 1))),
            "a text over the cap is refused, never truncated into a silent "
                + "half-write")
    }

    /// The five legal shapes cross the socket unchanged — including an
    /// EMPTY replacement, which is a real act: emptying a field is
    /// something a person does, and an absent text is not the same request.
    func testTheFiveLegalShapesSurviveTheSocket() throws {
        let window = try encodeThenDecode(.windowAct(.init(
            window: Self.window, action: .resize, width: 400, height: 300)))
        XCTAssertEqual(window.operation, .windowAct)
        XCTAssertEqual(window.windowActRequest?.width, 400)

        let control = try encodeThenDecode(.controlAct(
            .init(element: Self.element, part: 129)))
        XCTAssertEqual(control.controlActRequest?.part, 129)

        let menu = try encodeThenDecode(.menuAct(
            .init(menu: 129, item: 4, titleLeft: 44,
                  process: .init(high: 0, low: 8_421_376))))
        XCTAssertEqual(menu.menuActRequest?.titleLeft, 44)
        XCTAssertEqual(menu.menuActRequest?.process?.low, 8_421_376)

        XCTAssertEqual(
            try encodeThenDecode(.textGet(element: Self.element))
                .actElement, Self.element)
        XCTAssertEqual(
            try encodeThenDecode(.textSet(element: Self.element, text: ""))
                .actText, "",
            "an empty replacement is a legal act — emptying a field is "
                + "something a person does — and must not be read as an "
                + "absent one")
    }

    // MARK: - 4. A refusal is the guest's own sentence

    /// `act-not-taken` is what a guest says when it armed and the
    /// application never called the trap it was waiting on. The words cross;
    /// nothing here reads them to invent a typed code, because this side
    /// cannot see what happened.
    func testAGuestRefusalCrossesInTheGuestsOwnWords() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        installResponder(on: guest, verb: "ctlact") { id in
            .init(id: id, ok: false, output: nil,
                  error: .init(
                    code: "act-not-taken",
                    message: "armed, and the application never called "
                        + "TrackControl"))
        }

        let result = await adapter(listener).controlAct(
            .init(element: Self.element, part: 10))

        guard case .refused(let failure) = result else {
            return XCTFail("a guest that said no is a refusal: \(result)")
        }
        XCTAssertEqual(failure.code, "now-control-act-refused")
        XCTAssertTrue(failure.message.contains("never called TrackControl"),
                      "the guest's own sentence is the distinction; a host "
                          + "that replaced it would delete the answer")
    }

    /// Silence is bounded, and the bound is this side's. The guest's own act
    /// deadline is ~5 s and a submit can spend it twice, so a machine that
    /// is working normally can be quiet for ten seconds — and one that has
    /// gone must not hold a caller forever.
    func testSilenceBecomesABoundedRefusalRatherThanAHang() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        installResponder(on: guest, verb: "textget", reply: nil)

        let result = await adapter(listener, timeout: 0.2)
            .getElementText(element: Self.element)

        guard case .refused(let failure) = result else {
            return XCTFail("silence is a bounded refusal: \(result)")
        }
        XCTAssertEqual(failure.code, "now-text-get-outcome-unknown")
    }

    // MARK: - The reading

    /// `textget` is the one act that changes nothing, so it has no
    /// `Dispatch` row to find and must not be made to want one. What it
    /// carries is a READING, and `truncated` is a fact about that reading.
    func testATextReadingCarriesTheGuestsTruncationFlag() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        installResponder(on: guest, verb: "textget") { id in
            .init(id: id, ok: true, output: ["textget": [
                ["Element", Self.element],
                ["Text", "Untitled"],
                ["Length", "4096"],
                ["Returned", "8"],
                ["Truncated", "yes"],
            ]], error: nil)
        }

        let result = await adapter(listener)
            .getElementText(element: Self.element)

        guard case .completed(let reading) = result else {
            return XCTFail("an answered read is a completed read: \(result)")
        }
        XCTAssertEqual(reading.text, "Untitled")
        XCTAssertTrue(
            reading.truncated,
            "a caller that cannot tell a short field from a clipped one has "
                + "been told nothing useful")
    }

    /// An act that reached a machine leaves a line the person at that
    /// machine can read, and the line says DISPATCHED rather than done.
    func testADispatchedActIsAudited() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        installResponder(on: guest, verb: "winact") { Self.winactRows(id: $0) }
        let lines = Box<[String]>([])

        _ = await adapter(listener, audit: { _, line in
            lines.value.append(line)
        }).windowAct(.init(window: Self.window, action: .move,
                           left: 40, top: 60))

        let line = try XCTUnwrap(lines.value.first)
        XCTAssertTrue(line.contains("winact move"))
        XCTAssertTrue(line.contains("dispatched"))
        for claimed in ["moved", "succeeded", "done"] {
            XCTAssertFalse(line.contains(claimed),
                           "the log line claims \"\(claimed)\"")
        }
    }

    // MARK: -

    private func encodeThenDecode(_ request: AgentIntegrationLocalRequest)
        throws -> AgentIntegrationLocalRequest {
        try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(request))
    }
}
