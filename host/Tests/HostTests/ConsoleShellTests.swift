import Foundation
import Network
import XCTest
@testable import Host

/// The host console as a dumb shell.
///
/// What is being protected here is an absence: this side must not know what
/// commands the other machine has. The old console knew fifteen, which was
/// wrong for the Carbon guest the moment NOW-68K arrived serving three — and
/// wrong in the quietest way, because a command the guest had and the console
/// did not was reported as "not a declared command" without ever reaching the
/// wire. So these tests watch what goes ONTO the wire and what comes back,
/// not what the model believes.
///
/// The guest here answers `unknown-command` for anything it does not have,
/// exactly as the contract requires and as NOW-68K really does.
@MainActor
final class ConsoleShellTests: XCTestCase {

    /// A connected pair, plus the requests the guest saw.
    private struct Pair {
        let listener: GuestListener
        let guest: FakeGuest
        let console: ConsoleModel
        let requests: Requests
    }

    /// A box, because the guest's callback runs after the pair is built.
    ///
    /// `execs` is what the console actually sends now. `commands` is kept
    /// because ONE thing still uses the typed plane on purpose — Tab
    /// completion, which needs `help`'s first column and not its prose. That
    /// split is the design, so both are recorded and both are asserted.
    private final class Requests {
        var execs: [ExecRequest] = []
        var commands: [CommandRequest] = []
        var last: ExecRequest? { execs.last }
    }

    /// `serves` is the guest's whole command table. Everything else gets the
    /// contract's `unknown-command`.
    private func connect(serves: [String: [String: [[String]]]],
                         deadline: Date = Date().addingTimeInterval(8))
        async throws -> Pair {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        while Date() < deadline {
            if case .listening = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let guest = FakeGuest(port: listener.boundPort!)
        let requests = Requests()
        guest.onMessage = { message in
            switch message {
            case .execRequest(let request):
                requests.execs.append(request)
                /* THE GUEST SPLITS. That is not a convenience here, it is
                   the thing under test: the host sent one opaque string and
                   somebody has to find the verb in it, and the contract says
                   the somebody is whoever serves the verb. A fake guest that
                   received a pre-split name would be testing the wire the
                   host used to speak. */
                let verb = String(request.line.prefix { $0 != " " })
                if let output = serves[verb] {
                    var seq = 0
                    for (group, rows) in output.sorted(by: { $0.key < $1.key }) {
                        if output.count > 1 {
                            try? guest.send(.execOutput(ExecOutput(
                                id: request.id, seq: seq, text: "[\(group)]\r")))
                            seq += 1
                        }
                        for row in rows {
                            try? guest.send(.execOutput(ExecOutput(
                                id: request.id, seq: seq,
                                text: row.joined(separator: "  ") + "\r")))
                            seq += 1
                        }
                    }
                    try? guest.send(.execResult(ExecResult(
                        id: request.id, ok: true, code: nil, message: nil)))
                } else {
                    try? guest.send(.execOutput(ExecOutput(
                        id: request.id, seq: 0,
                        text: "! unknown-command: \(verb)\r")))
                    try? guest.send(.execResult(ExecResult(
                        id: request.id, ok: false, code: "unknown-command",
                        message: "\(verb) is not a command this Mac knows")))
                }
            case .commandRequest(let request):
                requests.commands.append(request)
                if let output = serves[request.name] {
                    try? guest.send(.commandResult(CommandResult(
                        id: request.id, ok: true, output: output, error: nil)))
                } else {
                    try? guest.send(.commandResult(CommandResult(
                        id: request.id, ok: false, output: nil,
                        error: .init(
                            code: "unknown-command",
                            message: "\(request.name) is not a command this "
                                + "Mac knows"))))
                }
            default:
                return
            }
        }
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
                                    version: "0.1.0", name: "PowerBook 180c",
                                    os: "7.1", chunk: nil)))
        while Date() < deadline {
            if case .connected = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return Pair(listener: listener, guest: guest,
                    console: ConsoleModel(listener: listener),
                    requests: requests)
    }

    private func settle(until condition: @escaping () -> Bool,
                        seconds: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - What goes onto the wire

    /// The line crosses whole. Not "the name, and the rest as a string" —
    /// ONE string, verb included, with no field for the host to have split
    /// it into.
    ///
    /// The host used to turn "census pci" into {"probe": "pci"}, a mapping it
    /// could only know by knowing census. Then it sent name="census",
    /// line="pci", which was better and still a rule about where verbs end.
    /// Now it sends "census pci" and has no rule at all.
    func testTheTypedLineIsRelayedUnparsed() async throws {
        let pair = try await connect(serves: ["census": ["census": []]])
        defer { pair.listener.stop() }

        pair.console.input = "census pci"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.line, "census pci",
                       "the whole line, verb and all")
        XCTAssertTrue(pair.requests.commands.isEmpty,
                      "a typed line must not touch the command plane; that "
                      + "plane is for callers that KNOW the command")
    }

    /// A name with spaces is one argument, and the host does not know that —
    /// so it must not split. "quit Adobe Photoshop 5.0" is the case that
    /// forced the rule, and the flags in front of it are the case that shows
    /// why splitting only the FIRST word was still not enough.
    func testAWholeLineWithSpacesSurvivesIntact() async throws {
        let pair = try await connect(serves: ["quit": ["quit": []]])
        defer { pair.listener.stop() }

        pair.console.input = "quit --wait 12 Adobe Photoshop 5.0"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.line,
                       "quit --wait 12 Adobe Photoshop 5.0")
    }

    /// A bare command is just itself. There is no empty-argument field to
    /// get right any more: the old plane needed `line: ""` to distinguish a
    /// human's bare `gestalt` from a module's argument-less call, and this
    /// plane needs nothing, because only a human is ever on it.
    func testABareCommandIsTheWholeLine() async throws {
        let pair = try await connect(serves: ["gestalt": ["snapshot": []]])
        defer { pair.listener.stop() }

        pair.console.input = "gestalt"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.line, "gestalt")
    }

    /// A line whose verb does not end at a space. Nothing serves this today
    /// and that is the point: it must still ARRIVE, because the host is not
    /// the thing that decides what a verb looks like. The old split would
    /// have sent name="cd" and quietly dropped the rest of the meaning.
    func testALineWithNoSpaceDelimitedVerbStillCrosses() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }

        pair.console.input = "cd Lab && ls"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.line, "cd Lab && ls",
                       "an interpreter this host has never heard of would "
                       + "receive exactly what was typed")
    }

    /// The whole point. A command this build has never heard of goes across
    /// and comes back refused BY THE GUEST — which is how a host that knows
    /// no command table can still be honest about one that does not exist.
    func testAnUnknownCommandIsRefusedByTheGuestNotHere() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }

        pair.console.input = "teleport"
        pair.console.submit()
        try await settle {
            pair.console.lines.contains { $0.text.contains("unknown-command") }
        }

        XCTAssertEqual(pair.requests.last?.line, "teleport",
                       "an unknown command must still reach the guest — only "
                       + "it knows what it serves")
        XCTAssertTrue(pair.console.lines.contains {
            $0.text.contains("! unknown-command: teleport")
        }, "the guest's own words, rendered — including its own marker")
    }

    /// A command the OTHER guest serves is not special-cased here either.
    /// NOW-68K has launch and quit and nothing else; the console must carry
    /// `ls` to it and let it say no.
    func testACommandOnlyTheOtherGuestServesStillCrossesTheWire()
        async throws {
        let pair = try await connect(serves: ["launch": ["launch": []]])
        defer { pair.listener.stop() }

        pair.console.input = "ls Lab:Code"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.line, "ls Lab:Code")
    }

    /// THE ACCEPTANCE TEST for this plane, stated as code.
    ///
    /// A verb no version of this host has ever heard of, that appears in no
    /// contract file and in no registry, is typed and answered. Nothing was
    /// rebuilt on this side and nothing was declared anywhere. If this test
    /// ever needs a host-side edit to keep passing, the plane has failed
    /// whatever else is green.
    func testAVerbThisHostHasNeverHeardOfIsTypeable() async throws {
        let pair = try await connect(serves: [
            "frobnicate": ["frobnicate": [["Widgets", "17 frobbed"]]]])
        defer { pair.listener.stop() }

        pair.console.input = "frobnicate --all"
        pair.console.submit()
        try await settle {
            pair.console.lines.contains { $0.text.contains("frobbed") }
        }
        XCTAssertEqual(pair.requests.last?.line, "frobnicate --all")
        XCTAssertTrue(pair.console.lines.contains {
            $0.text.contains("Widgets") && $0.text.contains("17 frobbed") })
    }

    // MARK: - Rendering

    /// Text arrives as the guest drew it, and is shown that way.
    ///
    /// This used to assert that the HOST aligned two columns. It no longer
    /// does any such thing, and that is the fix rather than a regression:
    /// the guest already decided its own layout for its own screen, and a
    /// host re-deciding it meant the same listing lined up one way on the
    /// PowerBook and another way here.
    func testGuestTextIsShownAsTheGuestWroteIt() async throws {
        let pair = try await connect(serves: [
            "gestalt": ["snapshot": [["System", "Mac OS 9.1"],
                                     ["CarbonLib", "1.6"]]]])
        defer { pair.listener.stop() }

        pair.console.input = "gestalt"
        pair.console.submit()
        try await settle {
            pair.console.lines.contains { $0.text.contains("1.6") }
        }
        XCTAssertTrue(pair.console.lines.contains {
            $0.text == "System  Mac OS 9.1" },
            "the guest's spacing, not a width this side computed")
    }

    /// Multi-line output is split on the guest's own CR and shown as lines,
    /// with nothing dropped. The old renderer skipped any row that was not
    /// exactly two columns — a MISSING line rather than an ugly one, which
    /// is the worst way for a console to be wrong.
    func testEveryLineSurvivesIncludingOnesThatAreNotTwoColumns()
        async throws {
        let pair = try await connect(serves: [
            "gestalt": ["cpu": [["Processor", "PowerPC 603e"],
                                ["a bare sentence with no column at all"]]]])
        defer { pair.listener.stop() }

        pair.console.input = "gestalt --full"
        pair.console.submit()
        try await settle {
            pair.console.lines.contains { $0.text.contains("603e") }
        }
        XCTAssertTrue(pair.console.lines.contains {
            $0.text == "a bare sentence with no column at all" },
            "a one-column line is shown, not silently dropped")
    }

    // MARK: - What stays host-side

    /// The local verbs are behind "/" so a guest command can never be
    /// shadowed by one — and so a human can see which side a line acts on.
    func testLocalVerbsNeverReachTheWire() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }

        pair.console.input = "gestalt"
        pair.console.submit()
        try await settle { pair.requests.last != nil }
        let sent = pair.requests.execs.count

        pair.console.input = "/clear"
        pair.console.submit()
        XCTAssertTrue(pair.console.lines.isEmpty, "/clear clears")

        pair.console.input = "/help"
        pair.console.submit()
        XCTAssertTrue(pair.console.lines.contains {
            $0.text.contains("/save") })

        try await settle(until: { false }, seconds: 0.3)
        XCTAssertEqual(pair.requests.execs.count, sent,
                       "no local verb may send anything")
    }

    /// An unknown LOCAL verb is refused locally and says why — the one place
    /// this side may answer for itself, because "/" claimed the namespace.
    func testAnUnknownLocalVerbIsRefusedHereWithTheReason() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }

        pair.console.input = "/teleport"
        pair.console.submit()
        XCTAssertTrue(pair.console.lines.contains {
            $0.text.contains("not a local verb")
                && $0.text.contains("other Mac")
        })
        XCTAssertTrue(pair.requests.execs.isEmpty)
    }

    /// `/save` replaces `gestalt --save`, which only worked because the host
    /// knew what gestalt returned. This one is command-agnostic: it writes
    /// what is on screen.
    func testSaveWritesTheScrollback() async throws {
        let pair = try await connect(serves: ["gestalt": ["snapshot":
            [["System", "Mac OS 9.1"]]]])
        defer { pair.listener.stop() }

        pair.console.input = "gestalt"
        pair.console.submit()
        try await settle {
            pair.console.lines.contains { $0.text.contains("Mac OS 9.1") }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-console-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        pair.console.input = "/save \(url.path)"
        pair.console.submit()

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("Mac OS 9.1"))
    }

    // MARK: - History

    func testHistoryWalksBackAndForward() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }

        for command in ["gestalt", "ps"] {
            pair.console.input = command
            pair.console.submit()
        }
        XCTAssertEqual(pair.console.recallHistory(-1), "ps")
        XCTAssertEqual(pair.console.recallHistory(-1), "gestalt")
        XCTAssertEqual(pair.console.recallHistory(-1), "gestalt",
                       "the oldest is the floor, not a wrap")
        XCTAssertEqual(pair.console.recallHistory(1), "ps")
        XCTAssertEqual(pair.console.recallHistory(1), "",
                       "past the newest is the empty line being edited")
    }

    func testHistoryIsEmptyBeforeAnythingIsTyped() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }
        XCTAssertNil(pair.console.recallHistory(-1))
    }

    /// A repeated line is not stored twice — recalling three `ps` in a row to
    /// get back to the interesting one is the thing shells learned not to do.
    func testARepeatedLineIsNotStoredTwice() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }

        for _ in 0..<3 {
            pair.console.input = "ps"
            pair.console.submit()
        }
        XCTAssertEqual(pair.console.history, ["ps"])
    }

    // MARK: - Completion comes from the guest

    /// Tab completes from what the GUEST said it serves. Nothing is cached
    /// in the binary, so a guest with three commands completes three.
    func testCompletionComesFromTheGuestsOwnHelp() async throws {
        let pair = try await connect(serves: [
            "help": ["help": [["launch", "open an application"],
                              ["quit", "ask one to quit"],
                              ["help", "list the commands this Mac serves"],
                              ["", "every other command answers "
                                 + "unknown-command"]]]])
        defer { pair.listener.stop() }

        // The first Tab has nothing yet and asks. Nothing is printed: nobody
        // typed it.
        XCTAssertNil(pair.console.complete("la"))
        try await settle { !pair.console.completions.isEmpty }

        XCTAssertEqual(pair.console.completions, ["help", "launch", "quit"],
                       "the prose row is not a command")
        XCTAssertEqual(pair.console.complete("la"), "launch")
        XCTAssertNil(pair.console.complete("z"), "no match completes to nothing")
    }

    /// Several matches complete to the shared prefix and list themselves,
    /// which is what a shell does.
    func testSeveralMatchesCompleteToTheirCommonPrefix() async throws {
        let pair = try await connect(serves: [
            "help": ["help": [["putstat", "timings"], ["put", "send"]]]])
        defer { pair.listener.stop() }

        XCTAssertNil(pair.console.complete("p"))
        try await settle { !pair.console.completions.isEmpty }

        XCTAssertEqual(pair.console.complete("p"), "put")
        XCTAssertTrue(pair.console.lines.contains {
            $0.text.contains("put") && $0.text.contains("putstat") })
    }

    /// A guest that does not serve `help` has no completion, and that is the
    /// honest outcome — NOW-68K's predecessor answers unknown-command here.
    /// It must not fall back to a list of its own.
    func testAGuestWithoutHelpSimplyHasNoCompletion() async throws {
        let pair = try await connect(serves: [:])
        defer { pair.listener.stop() }

        XCTAssertNil(pair.console.complete("la"))
        try await settle(until: { false }, seconds: 0.5)
        XCTAssertTrue(pair.console.completions.isEmpty)
        XCTAssertNil(pair.console.complete("la"))
    }

    /// Only the command name completes. An argument is the guest's grammar,
    /// and this side does not have it.
    func testArgumentsDoNotComplete() async throws {
        let pair = try await connect(serves: [
            "help": ["help": [["launch", "open an application"]]]])
        defer { pair.listener.stop() }

        XCTAssertNil(pair.console.complete("l"))
        try await settle { !pair.console.completions.isEmpty }
        XCTAssertNil(pair.console.complete("launch Sim"),
                     "the host cannot know what launch's argument may be")
        XCTAssertNil(pair.console.complete("/cl"),
                     "local verbs are few and typed in full")
    }

    /// The completions belong to the machine that gave them. A different
    /// guest serves a different set, so they go when the wire does.
    func testCompletionsAreForgottenWhenTheGuestGoes() async throws {
        let pair = try await connect(serves: [
            "help": ["help": [["launch", "open an application"]]]])

        XCTAssertNil(pair.console.complete("la"))
        try await settle { !pair.console.completions.isEmpty }
        XCTAssertFalse(pair.console.completions.isEmpty)

        pair.console.forgetGuest()
        XCTAssertTrue(pair.console.completions.isEmpty,
                      "a list from a machine that has gone is a wrong list")
        pair.listener.stop()
    }
}
