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
        /* Its own capability record, never `.shared`. Two machines with the
           same NAME get the same synthetic key in tests, so one case's
           refusal would otherwise reach the next case's model and darken a
           verb nothing in that case ever refused — a leak that only shows up
           now that a run consults the gate rather than this page's own
           `serving`. */
        model = DiagnosticsModel(listener: listener,
                                 capabilities: GuestCapabilityRecord())
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
        replies: [String: CommandResult] = [:],
        named name: String = "PB 180c"
    ) async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1",
            name: name, os: "7.1", chunk: 8192)))
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
        model.connection = .connected(named: name)
        return guest
    }

    private func serving(_ id: String) -> DiagnosticServing? {
        model.state(id: id)?.serving
    }

    /// Whether the page would let a person press Run — the answer the row's
    /// dimming and the button's state both come from.
    private func runnable(_ id: String) -> Bool {
        guard let state = model.state(id: id) else { return false }
        return model.availability(for: state).isRunnable
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
        try await waitUntil("vprobe answered", timeout: 2.5) {
            !(self.model.state(id: "vprobe")?.rows.isEmpty ?? true)
        }
        XCTAssertEqual(serving("vprobe"), .served,
                       "Answering the verb settles it, which is the machine "
                           + "establishing its own availability.")
    }

    // MARK: - Three states, not two

    /// **Supported, unsupported, and not-yet-run are three different facts,
    /// and the page can name each of them.**
    ///
    /// The list shows every diagnostic whichever machine is on the wire, so
    /// each row has to carry which it is in. Collapsing any pair is a page
    /// telling a person their Mac cannot do something when the truth is that
    /// nobody has spent the measurement yet — or the reverse, which is worse:
    /// a Run button that will never work, offered as though it would.
    func testSupportedUnsupportedAndNotYetRunAreThreeSeparateAnswers()
        async throws {
        let guest = try await connectGuest(
            commands: ["help", "vprobe", "shotdiag"],
            replies: ["vprobe": .init(
                id: 0, ok: true,
                output: ["vprobe": [["Screen", "640x480, 8-bit"]]],
                error: nil)])
        defer { guest.connection.cancel() }
        try await waitUntil("help answered") {
            self.serving("putstat") == .notServed
        }

        // Served and never run: runnable, nothing to explain, no reading.
        let shotdiag = try XCTUnwrap(model.state(id: "shotdiag"))
        XCTAssertEqual(model.availability(for: shotdiag), .supported)
        XCTAssertFalse(shotdiag.hasRun,
                       "supported is not the same fact as run")

        // Served AND run: still supported — the axes do not interfere.
        model.run(.vprobe)
        try await waitUntil("vprobe answered") {
            self.model.state(id: "vprobe")?.hasRun ?? false
        }
        let vprobe = try XCTUnwrap(model.state(id: "vprobe"))
        XCTAssertEqual(model.availability(for: vprobe), .supported)
        XCTAssertTrue(vprobe.hasRun)

        // Absent from the table: not runnable, and it says why.
        let putstat = try XCTUnwrap(model.state(id: "putstat"))
        XCTAssertFalse(model.availability(for: putstat).isRunnable)
        XCTAssertFalse(putstat.hasRun,
                       "unsupported must not be dressed as a finished run")
    }

    /// **A machine that has not listed its commands is `unproven`, which is
    /// RUNNABLE** — and that is the third state, not a softer kind of no.
    func testAnUnaskedMachineLeavesEveryDiagnosticRunnable() async throws {
        let guest = try await connectGuest(commands: nil)
        defer { guest.connection.cancel() }

        for state in model.states {
            let availability = model.availability(for: state)
            XCTAssertTrue(availability.isRunnable,
                          "\(state.id) went dark on silence; unproven is not "
                              + "a no, and the run is what settles it")
            guard case .unproven = availability else {
                return XCTFail("\(state.id): expected unproven, got "
                                   + "\(availability)")
            }
            XCTAssertFalse(availability.deservesAVisibleReason,
                           "an enabled control does not get to nag")
        }
    }

    /// **A disabled diagnostic carries the sentence that says why**, naming
    /// this machine and the sibling guest that does answer the verb.
    ///
    /// A greyed control with no explanation is indistinguishable from a bug —
    /// the failure the whole gate exists to prevent — and "not available" on
    /// its own reads as damage rather than as a difference between two
    /// guests of different completeness.
    func testADisabledDiagnosticSaysWhichMachineCannotAndWhy() async throws {
        let guest = try await connectGuest(
            commands: ["help", "vprobe", "shotdiag"])
        defer { guest.connection.cancel() }
        try await waitUntil("help answered") {
            self.serving("putstat") == .notServed
        }

        let putstat = try XCTUnwrap(model.state(id: "putstat"))
        let availability = model.availability(for: putstat)
        XCTAssertTrue(availability.deservesAVisibleReason,
                      "a dark control must explain itself in place, not only "
                          + "on hover")
        let reason = try XCTUnwrap(availability.reason)
        XCTAssertTrue(reason.contains("PB 180c"),
                      "the sentence names the machine that cannot: \(reason)")
        XCTAssertTrue(reason.contains("putstat"))
        XCTAssertTrue(reason.contains("Carbon guest"),
                      "it names the sibling that answers the verb, which is "
                          + "what stops this reading as a fault: \(reason)")
        XCTAssertTrue(reason.contains("Not a fault"),
                      "absence must not read as damage: \(reason)")
    }

    /// **A 68K-shaped command table disables a different diagnostic from a
    /// PowerPC-shaped one.** Support is a fact about the machine on the wire,
    /// read from its own `help`, and never a static list on this side.
    ///
    /// Two machines in one test on purpose: the property is the DIFFERENCE.
    /// A page that hard-coded either subset would pass every single-guest
    /// check and still grey out the wrong row the moment the other Mac
    /// dialled in.
    func testTheDisabledSubsetFollowsTheMachineNotThisSide() async throws {
        let sixtyEight = try await connectGuest(
            commands: ["help", "vprobe", "shotdiag"], named: "PB 180c")
        try await waitUntil("68K help answered") {
            self.serving("putstat") == .notServed
        }
        XCTAssertTrue(runnable("vprobe"))
        XCTAssertTrue(runnable("shotdiag"))
        XCTAssertFalse(runnable("putstat"),
                       "the 68K guest does not serve putstat")
        sixtyEight.connection.cancel()
        // The second machine's `help` must not race the first one's socket
        // still being the listener's connection.
        try await waitUntil("first machine gone") {
            if case .connected = self.listener.state { return false }
            return true
        }
        model.connection = .disconnected

        let powerPC = try await connectGuest(
            commands: ["help", "vprobe", "putstat"], named: "PB 1400c")
        defer { powerPC.connection.cancel() }
        try await waitUntil("PPC help answered") {
            self.serving("shotdiag") == .notServed
        }
        XCTAssertTrue(runnable("vprobe"), "both guests serve vprobe")
        XCTAssertTrue(runnable("putstat"))
        XCTAssertFalse(runnable("shotdiag"),
                       "the Carbon guest does not serve shotdiag, and the "
                           + "previous machine's subset must not survive the "
                           + "switch")
    }

    // MARK: - Selection

    /// **Every diagnostic is selectable, including one the machine cannot
    /// run.** A row that refuses selection can never show the sentence
    /// explaining why it is grey — which leaves a page whose greyest row is
    /// also its least explained.
    func testAnUnsupportedDiagnosticIsStillSelectableAndExplainsItself()
        async throws {
        let guest = try await connectGuest(
            commands: ["help", "vprobe", "shotdiag"])
        defer { guest.connection.cancel() }
        try await waitUntil("help answered") {
            self.serving("putstat") == .notServed
        }

        XCTAssertEqual(model.selection, "vprobe",
                       "the page opens on a row rather than on an empty "
                           + "detail pane")
        model.selection = "putstat"
        let selected = try XCTUnwrap(model.selectedState)
        XCTAssertEqual(selected.id, "putstat")
        XCTAssertFalse(model.availability(for: selected).isRunnable)
        XCTAssertNotNil(model.availability(for: selected).reason,
                        "selecting the dark row is how a person finds out "
                            + "why it is dark")
    }

    /// A selection survives the machine going away — what is on screen is
    /// still what that Mac said, and moving the reader's place would be this
    /// side reacting to an event they did not cause.
    func testSelectionSurvivesTheWireDropping() async throws {
        let guest = try await connectGuest(commands: ["help", "vprobe"])
        defer { guest.connection.cancel() }
        model.selection = "shotdiag"
        model.connection = .disconnected
        XCTAssertEqual(model.selection, "shotdiag")
        XCTAssertEqual(model.selectedState?.id, "shotdiag")
    }

    // MARK: - Not here, versus not working

    /// A refusal that means "no such command" marks the card unserved and
    /// leaves **no error text**: nothing is wrong with the machine.
    func testAnUnknownCommandRefusalIsRecordedAsAbsenceNotAsAnError()
        async throws {
        let guest = try await connectGuest(commands: nil)
        defer { guest.connection.cancel() }

        model.run(.shotdiag)
        try await waitUntil("shotdiag refused", timeout: 2.5) {
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

    // MARK: - A working probe with nothing to report

    /// **A Mac that has received no file answers zeroes, and the page must
    /// not draw them as a table.**
    ///
    /// This is the exact shape the UX review names as the worst defect the
    /// product has: eleven `0` rows look like a feature that failed to load.
    /// The reading splits the response the way the guest actually composes
    /// it — eight counters about the last received file, three read from the
    /// live connection — so the page can say "nothing received yet" in words
    /// and still show the numbers that prove the probe answered.
    func testAMacThatHasReceivedNothingReadsAsNeverRunNotAsZeroes()
        async throws {
        let guest = try await connectGuest(
            commands: ["help", "putstat"],
            replies: ["putstat": .init(
                id: 0, ok: true,
                output: ["putstat": Self.idleRows], error: nil)])
        defer { guest.connection.cancel() }

        model.run(.putstat)
        try await waitUntil("putstat answered") {
            !(self.model.state(id: "putstat")?.rows.isEmpty ?? true)
        }

        let reading = try XCTUnwrap(
            model.state(id: "putstat")?.transferReading)
        XCTAssertTrue(reading.hasReceivedNothing)
        XCTAssertEqual(reading.transfer.count, 8)
        XCTAssertEqual(reading.live.map(\.label),
                       ["Rcv backlog", "Rcv peak", "Loop passes"])
        XCTAssertEqual(reading.live.map(\.value), ["58", "103", "11406"],
                       "The live counters are the evidence the probe "
                           + "answered, so they survive the never-run state.")
    }

    /// The same response with one real transfer in it is NOT the never-run
    /// state, and nothing is hidden: every row the guest sent is still drawn.
    func testAMacThatHasReceivedAFileKeepsAllElevenRows() async throws {
        var rows = Self.idleRows
        rows[0] = ["Bytes", "108544"]
        rows[1] = ["Chunks", "14"]
        let guest = try await connectGuest(
            commands: ["help", "putstat"],
            replies: ["putstat": .init(
                id: 0, ok: true, output: ["putstat": rows], error: nil)])
        defer { guest.connection.cancel() }

        model.run(.putstat)
        try await waitUntil("putstat answered") {
            !(self.model.state(id: "putstat")?.rows.isEmpty ?? true)
        }

        let reading = try XCTUnwrap(
            model.state(id: "putstat")?.transferReading)
        XCTAssertFalse(reading.hasReceivedNothing)
        XCTAssertEqual(reading.transfer.count + reading.live.count, 11)
    }

    /// **A zero is not a silence.** A machine that answered `ok` and sent no
    /// rows told us nothing, and that is a different fact from a machine
    /// reporting zeroes — the whole point of the never-run state is that the
    /// two must not look alike.
    func testAnEmptyAnswerIsNotTheSameFactAsAnAnswerOfZeroes() async throws {
        let guest = try await connectGuest(
            commands: ["help", "putstat"],
            replies: ["putstat": .init(
                id: 0, ok: true, output: ["putstat": []], error: nil)])
        defer { guest.connection.cancel() }

        model.run(.putstat)
        try await waitUntil("putstat answered") {
            self.model.state(id: "putstat")?.hasRun ?? false
        }

        let state = try XCTUnwrap(model.state(id: "putstat"))
        XCTAssertTrue(state.answeredWithNothing,
                      "No rows at all is the probe not answering, and the "
                          + "page says so rather than drawing nothing.")
        XCTAssertNil(state.transferReading,
                     "There is no transfer reading to compose from silence.")
    }

    /// The three cheap ways the split could be got wrong, held down: an
    /// unrecognised label counts as a transfer counter (so a non-zero one
    /// stops the page claiming nothing arrived), `0 ms` and the CRC's
    /// `00000000` read as zero, and a value with no digits never does.
    func testTheZeroTestReadsUnitsAndTheCRCButNeverGuesses() {
        XCTAssertTrue(TransferDiagnosticsReading.isZero("0"))
        XCTAssertTrue(TransferDiagnosticsReading.isZero("0 ms"))
        XCTAssertTrue(TransferDiagnosticsReading.isZero("00000000"))
        XCTAssertFalse(TransferDiagnosticsReading.isZero("1 ms"))
        XCTAssertFalse(TransferDiagnosticsReading.isZero("—"),
                       "A value this side did not expect is not a zero.")

        let unknown = TransferDiagnosticsReading(rows: [
            DiagnosticRow(index: 0, label: "Bytes", value: "0"),
            DiagnosticRow(index: 1, label: "Sectors Rewritten", value: "9"),
            DiagnosticRow(index: 2, label: "Loop passes", value: "12"),
        ])
        XCTAssertFalse(unknown.hasReceivedNothing,
                       "A newer guest's unrecognised non-zero counter must "
                           + "not be filed as live and read away.")
        XCTAssertEqual(unknown.live.map(\.label), ["Loop passes"])
    }

    /// `putstat`'s eleven rows exactly as the Carbon guest composes them
    /// (`now-guest-ppc/src/commands/commands.c :: run_putstat`), with the
    /// live counters taken from the real screenshot that prompted this work.
    private static let idleRows: [[String]] = [
        ["Bytes", "0"],
        ["Chunks", "0"],
        ["Writes", "0"],
        ["In FSWrite", "0 ms"],
        ["In receive", "0 ms"],
        ["Resumed from", "0"],
        ["CRC reseed", "0 ms"],
        ["CRC-32", "00000000"],
        ["Rcv backlog", "58"],
        ["Rcv peak", "103"],
        ["Loop passes", "11406"],
    ]

    // MARK: - wirestat, the fourth instrument

    /// **The rows split into the loop's facts and its two distributions**,
    /// and every expectation here comes from the guest's own emitter rather
    /// than from what this side's parser happens to do.
    ///
    /// The fixture is the shape `now-guest-ppc/src/commands/commands.c ::
    /// run_wirestat` composes: six `[label, value]` facts, then
    /// `wirestat_hist` twice — `<key> n|mean|min|max` followed by one row per
    /// non-empty bucket, labelled with the edges from
    /// `now-guest-ppc/src/core/loopstat.c :: k_edges` and marked `(median)`
    /// on the median bin.
    func testWirestatSplitsIntoTheLoopsFactsAndItsTwoDistributions() {
        let reading = WirestatReading(rows: Self.rows(Self.wirestatRows))

        XCTAssertEqual(reading.facts.map(\.label),
                       ["Sleep now", "Idle sleep", "Wake on data",
                        "Notifier", "Data notifications",
                        "WakeUpProcess calls"],
                       "The settings and the notifier counters are facts "
                           + "about the loop, not bins of a distribution.")
        XCTAssertEqual(reading.histograms.map(\.id), ["pass", "notice"],
                       "In the order the guest emits them: its own service "
                           + "interval first, then the notice delay.")

        let pass = try? XCTUnwrap(reading.histograms.first)
        XCTAssertEqual(pass?.samples, "1287")
        XCTAssertEqual(pass?.mean, "24000 us")
        XCTAssertEqual(pass?.minimum, "900 us")
        XCTAssertEqual(pass?.maximum, "216000 us")
        XCTAssertEqual(pass?.buckets.map(\.range),
                       ["500-1000 us", "1000-2000 us", "2000-4000 us",
                        "8000-16000 us", "66000-133000 us", "133000+ us"],
                       "The edges stay in the guest's words, the median "
                           + "marker stripped off the one that carries it.")
        XCTAssertEqual(pass?.buckets.filter(\.isMedian).map(\.range),
                       ["1000-2000 us"])
        XCTAssertEqual(pass?.peak, 840)

        let notice = reading.histograms.last
        XCTAssertEqual(notice?.samples, "413")
        XCTAssertEqual(notice?.buckets.map(\.count), [377, 24, 8, 4])
    }

    /// **A bucket is recognised by its grammar, never by a list of labels.**
    ///
    /// The contract says the rows a guest sends are its own diagnostic
    /// vocabulary and that a caller "must not require any particular label to
    /// exist" (`contract/asyncapi.yaml`, `x-commands.wirestat`). So a guest
    /// that grows a third distribution draws as one here with no host change,
    /// and a row this side cannot read stays visible as a fact rather than
    /// being swallowed.
    func testAThirdDistributionNeedsNoHostChangeAndOddRowsSurvive() {
        let reading = WirestatReading(rows: Self.rows([
            ["Sleep now", "2 tick(s)"],
            ["sync n", "12"],
            ["sync 0-500 us (median)", "9"],
            ["sync 133000+ us", "3"],
            ["pass 4000-8000 us", "not a number"],
            ["pass whatever", "7"],
        ]))

        XCTAssertEqual(reading.histograms.map(\.id), ["sync"],
                       "`pass` never proved itself a distribution here: no "
                           + "row of its own carried bucket edges.")
        XCTAssertEqual(reading.histograms.first?.buckets.map(\.count), [9, 3])
        XCTAssertEqual(reading.facts.map(\.label),
                       ["Sleep now", "pass 4000-8000 us", "pass whatever"],
                       "A row this side cannot read is shown as it arrived. "
                           + "An unread row on screen is a smaller failure "
                           + "than a measurement quietly dropped.")
    }

    /// The page runs the verb, reads it, and takes the link's own timing off
    /// `net` in the same gesture — the four rows that used to sit on
    /// Networking's first card (034, G-1).
    func testRunningWireTimingAlsoReadsTheLinksOwnTiming() async throws {
        let guest = try await connectGuest(
            commands: ["help", "wirestat", "net"],
            replies: [
                "wirestat": .init(id: 0, ok: true,
                                  output: ["wirestat": Self.wirestatRows],
                                  error: nil),
                "net": .init(id: 0, ok: true,
                             output: ["net": Self.netRows], error: nil),
            ])
        defer { guest.connection.cancel() }

        model.run(verb: "wirestat")
        try await waitUntil("wirestat answered") {
            !(self.model.state(id: "wirestat")?.rows.isEmpty ?? true)
        }
        try await waitUntil("link timing read") {
            !self.model.linkTiming.isEmpty
        }

        let reading = try XCTUnwrap(
            model.state(id: "wirestat")?.wirestatReading)
        XCTAssertEqual(reading.histograms.count, 2)
        XCTAssertEqual(model.linkTiming.map(\.label),
                       ["Round trip", "Receive window", "Window peak",
                        "Quiet for"],
                       "Exactly the rows `GuestLinkTiming` names, and the "
                           + "machine's facts — Peer, Port, Address — stay "
                           + "on Networking.")
        XCTAssertEqual(model.linkTiming.map(\.value),
                       ["31 ms", "8192 bytes", "16384 bytes", "4s"])
    }

    /// A machine without `wirestat` in its table says which guest has it,
    /// and the page does not offer a run that could only be refused.
    func testAMachineWithoutWireTimingSaysWhichGuestServesIt() async throws {
        let guest = try await connectGuest(commands: ["help", "vprobe"])
        defer { guest.connection.cancel() }

        try await waitUntil("help answered") {
            self.serving("wirestat") != .unknown
        }
        XCTAssertEqual(serving("wirestat"), .notServed)
        XCTAssertFalse(runnable("wirestat"))
        let state = try XCTUnwrap(model.state(id: "wirestat"))
        XCTAssertTrue(
            model.notServedSentence(state.diagnostic).contains("MacTCP"),
            "The 68K guest cannot measure an Open Transport wake at all; "
                + "that is a fact about the stack, not a fault.")
    }

    /// `wirestat`'s rows as the Carbon guest composes them
    /// (`commands.c :: run_wirestat` and `wirestat_hist`, bucket edges from
    /// `loopstat.c :: k_edges`). Empty bins are omitted by the emitter and
    /// the low edge carries forward, which is why the ranges below skip.
    private static let wirestatRows: [[String]] = [
        ["Sleep now", "2 tick(s)"],
        ["Idle sleep", "2 tick(s)"],
        ["Wake on data", "on"],
        ["Notifier", "installed"],
        ["Data notifications", "413"],
        ["WakeUpProcess calls", "390"],
        ["pass n", "1287"],
        ["pass mean", "24000 us"],
        ["pass min", "900 us"],
        ["pass max", "216000 us"],
        ["pass 500-1000 us", "12"],
        ["pass 1000-2000 us (median)", "840"],
        ["pass 2000-4000 us", "301"],
        ["pass 8000-16000 us", "94"],
        ["pass 66000-133000 us", "31"],
        ["pass 133000+ us", "9"],
        ["notice n", "413"],
        ["notice mean", "3000 us"],
        ["notice min", "100 us"],
        ["notice max", "86000 us"],
        ["notice 0-500 us (median)", "377"],
        ["notice 500-1000 us", "24"],
        ["notice 33000-66000 us", "8"],
        ["notice 133000+ us", "4"],
    ]

    /// `net` as the Carbon guest composes it (`commands.c :: run_net`): a
    /// section header is a label with an empty value, and every member row's
    /// label arrives indented by two spaces.
    private static let netRows: [[String]] = [
        ["This Connection", ""],
        ["  Peer", "10.0.2.2"],
        ["  Port", "5555"],
        ["  Up", "3m"],
        ["  Round trip", "31 ms"],
        ["  Receive window", "8192 bytes"],
        ["  Window peak", "16384 bytes"],
        ["  Quiet for", "4s"],
        ["TCP/IP", ""],
        ["  Address", "10.0.2.15"],
    ]

    private static func rows(_ pairs: [[String]]) -> [DiagnosticRow] {
        pairs.enumerated().map {
            DiagnosticRow(index: $0.offset, label: $0.element[0],
                          value: $0.element[1])
        }
    }

    private final class Counter {
        var value = 0
    }
}
