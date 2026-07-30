import XCTest
@testable import Host

/// The Diagnostics page driven over the real wire: a scripted `FakeGuest`
/// answers `help` and the three verbs, and these check the one thing this
/// page exists to get right — **what a person is shown for a diagnostic
/// their machine does not serve.**
///
/// The three verbs are not served by the same guests, so at any moment one or
/// two cards are unanswerable. The failure modes worth gating are showing a
/// control that would do nothing, and making "this guest does not have that
/// verb" look like a machine in trouble.
@MainActor
final class DiagnosticsModuleModelTests: XCTestCase {
    private var listener: GuestListener!
    private var model: DiagnosticsModel!

    override func setUp() async throws {
        listener = GuestListener(identity: .init(version: "t", name: "Host"),
                                 timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        model = DiagnosticsModel(listener: listener)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        model = nil
    }

    // MARK: harness

    /// Connects a guest whose `help` answers `commands`, and whose diagnostic
    /// verbs answer from `replies`. A verb absent from `replies` is answered
    /// the way a guest without it answers: `unknown-command`.
    private func connectGuest(
        commands: [String]?,
        replies: [String: CommandResult] = [:]
    ) async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1",
            name: "PB 180c", os: "7.1", chunk: 8192)))
        try await waitUntil("host hello") { !guest.received.isEmpty }
        try await waitUntil("host connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message else { return }
            if request.name == "help" {
                guard let commands else { return }
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: true,
                    output: ["help": commands.map { [$0, "a verb"] }],
                    error: nil)))
                return
            }
            if let reply = replies[request.name] {
                try? guest.send(.commandResult(.init(
                    id: request.id, ok: reply.ok, output: reply.output,
                    error: reply.error)))
                return
            }
            try? guest.send(.commandResult(.init(
                id: request.id, ok: false, output: nil,
                error: .init(code: "unknown-command",
                             message: "\(request.name): no such command"))))
        }
        model.connection = .connected(named: "PB 180c")
        return guest
    }

    private func serving(_ id: String) -> DiagnosticServing? {
        model.state(id: id)?.serving
    }

    // MARK: - Availability comes off the machine's own help

    /// **The card for a verb this Mac does not have says so, and the page
    /// never asked the machine.**
    ///
    /// The 68K guest's table: `vprobe` and `shotdiag` yes, `putstat` no. The
    /// answer comes from the same `help` the console's completions and the
    /// agent surface's capability ledger read — not from a guest name, and
    /// not from spending a full-screen read to find out.
    func testTheCommandTableDecidesWhichCardsCanBeRun() async throws {
        let guest = try await connectGuest(
            commands: ["help", "ps", "ls", "vprobe", "shotdiag"])
        defer { guest.connection.cancel() }

        try await waitUntil("help answered") {
            self.serving("vprobe") != .unknown
        }
        XCTAssertEqual(serving("vprobe"), .served)
        XCTAssertEqual(serving("shotdiag"), .served)
        XCTAssertEqual(serving("putstat"), .notServed,
                       "The verb is absent from this machine's table, which "
                           + "is the answer — the Carbon guest serves it.")
    }

    /// A card the machine cannot answer offers nothing to press, and pressing
    /// it anyway does not reach the wire.
    ///
    /// The view shows no button in that state; this is the model half of the
    /// same promise, so a future view that put one back cannot quietly send a
    /// command the machine will refuse.
    func testRunningAnUnservedDiagnosticNeverReachesTheMachine()
        async throws {
        let asked = Counter()
        let guest = try await connectGuest(
            commands: ["help", "ps", "vprobe"])
        defer { guest.connection.cancel() }
        try await waitUntil("help answered") {
            self.serving("putstat") == .notServed
        }
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "putstat" else { return }
            asked.value += 1
        }

        model.run(.putstat)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(asked.value, 0)
        XCTAssertFalse(
            model.state(id: "putstat")?.isRunning ?? true,
            "A card that cannot be run must not be left spinning.")
    }

    /// **A machine that never lists its commands leaves the cards `unknown`,
    /// and a run is still offered.**
    ///
    /// Unproven is not "no" — the same three-state distinction the capability
    /// ledger draws. Declining to ask because `help` went unanswered would
    /// take a working diagnostic away on the strength of a different verb's
    /// silence.
    func testAMachineThatNeverListsItsCommandsLeavesTheCardsUnknown()
        async throws {
        let guest = try await connectGuest(
            commands: nil,
            replies: ["vprobe": .init(
                id: 0, ok: true,
                output: ["vprobe": [["Screen", "640x480, 8-bit"]]],
                error: nil)])
        defer { guest.connection.cancel() }

        XCTAssertEqual(serving("vprobe"), .unknown)
        model.run(.vprobe)
        try await waitUntil("vprobe answered") {
            !(self.model.state(id: "vprobe")?.rows.isEmpty ?? true)
        }
        XCTAssertEqual(serving("vprobe"), .served,
                       "Answering the verb settles it, which is the machine "
                           + "establishing its own availability.")
    }

    // MARK: - Not here, versus not working

    /// A refusal that means "no such command" marks the card unserved and
    /// leaves **no error text**: nothing is wrong with the machine.
    func testAnUnknownCommandRefusalIsRecordedAsAbsenceNotAsAnError()
        async throws {
        let guest = try await connectGuest(commands: nil)
        defer { guest.connection.cancel() }

        model.run(.shotdiag)
        try await waitUntil("shotdiag refused") {
            self.serving("shotdiag") == .notServed
        }
        XCTAssertNil(model.state(id: "shotdiag")?.refusal,
                     "\"This Mac does not have the verb\" is not an error "
                         + "message, and showing one would read as a broken "
                         + "machine.")
    }

    /// Any other refusal keeps the card served and shows the guest's own
    /// sentence — a busy probe or a disk that said no is a real failure, and
    /// it is the machine's account of it that is displayed.
    func testARealRefusalKeepsTheCardServedAndShowsTheGuestsSentence()
        async throws {
        let guest = try await connectGuest(
            commands: ["help", "vprobe"],
            replies: ["vprobe": .init(
                id: 0, ok: false, output: nil,
                error: .init(
                    code: "vprobe-busy",
                    message: "vprobe is already measuring this screen"))])
        defer { guest.connection.cancel() }

        model.run(.vprobe)
        try await waitUntil("vprobe refused") {
            self.model.state(id: "vprobe")?.refusal != nil
        }
        XCTAssertEqual(serving("vprobe"), .served,
                       "A busy probe is a served one.")
        XCTAssertEqual(model.state(id: "vprobe")?.refusal,
                       "vprobe is already measuring this screen",
                       "The guest's sentence, not a rewording of it.")
    }

    // MARK: - Rendering

    /// The rows reach the page in the guest's order and wording.
    func testTheGuestsRowsReachThePageUneditedAndInOrder() async throws {
        let rows = [["Base", "0x00FA8000"],
                    ["Stripped", "0x00FA8000"],
                    ["Addressing", "24-bit"],
                    ["Verdict", "base is right; fault is downstream"]]
        let guest = try await connectGuest(
            commands: ["help", "shotdiag"],
            replies: ["shotdiag": .init(
                id: 0, ok: true, output: ["shotdiag": rows], error: nil)])
        defer { guest.connection.cancel() }

        model.run(.shotdiag)
        try await waitUntil("shotdiag answered") {
            !(self.model.state(id: "shotdiag")?.rows.isEmpty ?? true)
        }

        let rendered = model.state(id: "shotdiag")?.rows ?? []
        XCTAssertEqual(rendered.map(\.label), rows.map { $0[0] })
        XCTAssertEqual(rendered.map(\.value), rows.map { $0[1] })
    }

    /// **The `vprobe` card carries its caveat as a property of the card, not
    /// of a result.**
    ///
    /// A `vprobe` on the PowerBook 1400c reported `CopyBits failed` and that
    /// failure does not reproduce through the capture path. The sentence has
    /// to be on screen before the number is, or it is a footnote nobody read
    /// in time — so it lives on the diagnostic's description and is asserted
    /// without any run at all.
    func testTheFramebufferCardWarnsAgainstReadingItAsACaptureFailure()
        throws {
        let vprobe = try XCTUnwrap(
            GuestDiagnostics.all.first { $0.verb == "vprobe" })
        let caveat = try XCTUnwrap(
            vprobe.caveat,
            "The one diagnostic whose result has already been misread owes "
                + "a sentence saying what it is not about.")
        XCTAssertTrue(caveat.contains("capture"))
        XCTAssertTrue(caveat.contains("different paths"))
        for other in GuestDiagnostics.all where other.verb != "vprobe" {
            XCTAssertNil(other.caveat,
                         "A caveat on every card is a caveat nobody reads; "
                             + "\(other.verb) has no such misreading.")
        }
    }

    private final class Counter {
        var value = 0
    }
}
