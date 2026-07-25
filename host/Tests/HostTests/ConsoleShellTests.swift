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
    private final class Requests {
        var all: [CommandRequest] = []
        var last: CommandRequest? { all.last }
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
            guard case .commandRequest(let request) = message else { return }
            requests.all.append(request)
            if let output = serves[request.name] {
                try? guest.send(.commandResult(CommandResult(
                    id: request.id, ok: true, output: output, error: nil)))
            } else {
                try? guest.send(.commandResult(CommandResult(
                    id: request.id, ok: false, output: nil,
                    error: .init(
                        code: "unknown-command",
                        message: "\(request.name) is not a command this Mac "
                            + "knows"))))
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

    /// The line is relayed as typed: the command name, and everything after
    /// it as one unparsed string. The host used to turn "census pci" into
    /// {"probe": "pci"} — a mapping it could only know by knowing census.
    func testTheTypedLineIsRelayedUnparsed() async throws {
        let pair = try await connect(serves: ["census": ["census": []]])
        defer { pair.listener.stop() }

        pair.console.input = "census pci"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.name, "census")
        XCTAssertEqual(pair.requests.last?.line, "pci",
                       "the console must send the line, not a parsed argument")
        XCTAssertNil(pair.requests.last?.args,
                     "args is the typed caller's field; a console has nothing "
                     + "to put in it")
    }

    /// A name with spaces is one argument, and the host does not know that —
    /// so it must not split. "quit Adobe Photoshop 5.0" is the case that
    /// forced the rule.
    func testAWholeLineWithSpacesSurvivesIntact() async throws {
        let pair = try await connect(serves: ["quit": ["quit": []]])
        defer { pair.listener.stop() }

        pair.console.input = "quit --wait 12 Adobe Photoshop 5.0"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.line,
                       "--wait 12 Adobe Photoshop 5.0")
    }

    /// A bare command still carries a line, empty. Presence is the signal:
    /// the guest answers a human's bare `gestalt` with the snapshot and a
    /// module's argument-less call with every group, and it can only tell
    /// them apart by this field being there.
    func testABareCommandSendsAnEmptyLineNotNoLine() async throws {
        let pair = try await connect(serves: ["gestalt": ["snapshot": []]])
        defer { pair.listener.stop() }

        pair.console.input = "gestalt"
        pair.console.submit()
        try await settle { pair.requests.last != nil }

        XCTAssertEqual(pair.requests.last?.line, "",
                       "a bare console command sends \"\", never nil")
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

        XCTAssertEqual(pair.requests.last?.name, "teleport",
                       "an unknown command must still reach the guest — only "
                       + "it knows what it serves")
        XCTAssertTrue(pair.console.lines.contains {
            $0.text.contains("teleport")
                && $0.text.contains("not a command this Mac knows")
        }, "the guest's own words, rendered")
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
        try await settle { pair.requests.last?.name == "ls" }

        XCTAssertEqual(pair.requests.last?.name, "ls")
        XCTAssertEqual(pair.requests.last?.line, "Lab:Code")
    }

    // MARK: - Rendering

    func testGuestOutputRendersAsAlignedRows() async throws {
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
            $0.text.contains("System") && $0.text.contains("Mac OS 9.1") })
    }

    /// Several groups are labelled and aligned per group. gestalt --full is
    /// the only reply shaped this way, and the host renders it without being
    /// told which command it came from.
    func testSeveralGroupsAreLabelled() async throws {
        let pair = try await connect(serves: [
            "gestalt": ["cpu": [["Processor", "PowerPC 603e"]],
                        "memory": [["Physical", "40 MB"]]]])
        defer { pair.listener.stop() }

        pair.console.input = "gestalt --full"
        pair.console.submit()
        try await settle {
            pair.console.lines.contains { $0.text.contains("603e") }
        }
        XCTAssertTrue(pair.console.lines.contains { $0.text == "[cpu]" })
        XCTAssertTrue(pair.console.lines.contains { $0.text == "[memory]" })
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
        let sent = pair.requests.all.count

        pair.console.input = "/clear"
        pair.console.submit()
        XCTAssertTrue(pair.console.lines.isEmpty, "/clear clears")

        pair.console.input = "/help"
        pair.console.submit()
        XCTAssertTrue(pair.console.lines.contains {
            $0.text.contains("/save") })

        try await settle(until: { false }, seconds: 0.3)
        XCTAssertEqual(pair.requests.all.count, sent,
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
        XCTAssertTrue(pair.requests.all.isEmpty)
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
