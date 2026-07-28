import Foundation
import XCTest
@testable import Host

/// The command set lives in three hand-maintained places: the contract
/// declares it, the guest's dispatch answers it, and the guest's doc table
/// describes it. Nothing makes them agree.
///
/// Adding `tail` proved the gap: it was written into the guest's table and
/// nowhere else, so the machine answered a command the contract did not
/// declare and this console would not offer. Undeclared and unreachable is
/// the quietest kind of broken — the feature exists, and no path to it does.
///
/// The third leg used to be a command list on THIS side. It is gone: there
/// are two guests now with different tables, so the host console is a dumb
/// shell that learns the set at runtime by asking `help` (see ConsoleModel).
/// Its place is taken by the guest's own doc table — the thing `help`
/// answers from — and by the check below that this side has not quietly
/// grown a command list again.
///
/// Like the wire fixtures, this reads the other halves rather than trusting
/// a copy of them.
final class CommandRegistryTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path),
                   encoding: .utf8)
    }

    /// Names under `x-commands:` in the contract — the declared spine.
    private func declared() throws -> Set<String> {
        let text = try read("contract/asyncapi.yaml")
        guard let start = text.range(of: "\n  x-commands:\n") else {
            XCTFail("no x-commands registry in the contract")
            return []
        }
        var names: Set<String> = []
        for line in text[start.upperBound...].components(separatedBy: "\n") {
            // A sibling section at two spaces ends the registry.
            if line.hasPrefix("  ") && !line.hasPrefix("   "),
               line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                break
            }
            // Command names sit at exactly four spaces.
            guard line.hasPrefix("    "), !line.hasPrefix("     ") else {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(":"), !trimmed.contains(" ") else {
                continue
            }
            names.insert(String(trimmed.dropLast()))
        }
        XCTAssertFalse(names.isEmpty, "could not read the registry")
        return names
    }

    /// Names the guest's dispatch actually answers.
    private func answered() throws -> Set<String> {
        let text = try read("guest/src/commands.c")
        guard let body = text.range(of: "void now_command_run(") else {
            XCTFail("no dispatch in commands.c")
            return []
        }
        var names: Set<String> = []
        let pattern = #"strcmp\(name, "([a-z]+)"\) == 0"#
        let regex = try NSRegularExpression(pattern: pattern)
        let tail = String(text[body.lowerBound...])
        for match in regex.matches(in: tail,
                                   range: NSRange(tail.startIndex..., in: tail)) {
            if let r = Range(match.range(at: 1), in: tail) {
                names.insert(String(tail[r]))
            }
        }
        XCTAssertFalse(names.isEmpty, "could not read the guest's dispatch")
        return names
    }

    /// Names the guest's doc table marks as served over the wire — the rows
    /// `help` answers with, and therefore the only discovery surface there
    /// is now that this side keeps no list.
    private func documented() throws -> Set<String> {
        let text = try read("guest/src/cmd_help.c")
        guard let table = text.range(of: "const NowCommandDoc kNowCommandDocs[]")
        else {
            XCTFail("no doc table in cmd_help.c")
            return []
        }
        var names: Set<String> = []
        // { "quit", 1, "…"  — the 1 is the wire flag; a 0 is console-local.
        let pattern = #"\{\s*"([a-z]+)",\s*1,"#
        let regex = try NSRegularExpression(pattern: pattern)
        let tail = String(text[table.lowerBound...])
        for match in regex.matches(in: tail,
                                   range: NSRange(tail.startIndex..., in: tail)) {
            if let r = Range(match.range(at: 1), in: tail) {
                names.insert(String(tail[r]))
            }
        }
        XCTAssertFalse(names.isEmpty, "could not read the doc table")
        return names
    }

    /// Commands the registry declares that the POWERPC guest deliberately
    /// does not answer, with the reason — the same shape
    /// CommandParityTests uses, and for the same reason: an exemption
    /// that is a decision belongs in data with its justification, not in
    /// a subtraction someone finds later and cannot explain.
    ///
    /// This map exists because the registry stopped being one guest's
    /// command set. It was written when the PowerPC guest was the only
    /// one with commands at all; NOW-68K has always answered a strict
    /// SUBSET (launch, quit, help, ps, vprobe), which this test never had
    /// to notice. `put` is the first entry going the other way — a
    /// command one guest answers and the other deliberately does not.
    private static let notOnThePowerPCGuest: [String: String] = [
        "put": """
            NOW-68K answers `put` on its wire; the PowerPC guest answers \
            it only at its own console. That is deliberate on both sides. \
            A host driving the PowerPC guest reaches the same capability \
            through file.list and file.get, so it needs no verb — while \
            NOW-68K is the machine whose display fails, whose keyboard is \
            sometimes the only face there is, and whose host console is a \
            dumb shell that knows no message families. See \
            docs/command-parity.md.
            """,
        "cancel": """
            The same split as `put`, one step further along the same \
            transfer. Both guests honour file.cancel on the wire, so the \
            CAPABILITY is symmetric; what differs is whether it needs to \
            be typeable. A host driving the PowerPC guest cancels from \
            the Files UI, and a person at that guest cancels from its \
            own Workshop — neither needs a verb. NOW-68K has no Files \
            page and no cancel affordance anywhere, so on that machine \
            the verb IS the face, and it is the face that matters most: \
            the lane is one transfer wide across both directions, so \
            someone whose host has stopped answering mid-transfer has a \
            machine that will not transfer anything again until they can \
            say stop.
            """,
    ]

    func testTheThreeHalvesAgreeOnTheCommandSet() throws {
        let declared = try declared()
            .subtracting(Self.notOnThePowerPCGuest.keys)
        let answered = try answered()
        let documented = try documented()

        XCTAssertEqual(declared, answered, """
            The contract and the guest disagree. Declared but unanswered \
            means a command that fails when asked for; answered but \
            undeclared means a working command nobody can reach. A \
            command only NOW-68K serves belongs in \
            notOnThePowerPCGuest with its reason.
            """)
        XCTAssertEqual(documented, declared, """
            The guest's doc table and the contract disagree. Since the host \
            console keeps no command list, `help` IS discovery — a command \
            missing from cmd_help.c works and cannot be found, and one \
            listed there but not declared is offered and then refused.
            """)
    }

    /// Verbs NOW-68K's dispatch answers — `now68k_commands_run` and the
    /// row-array cases in `now68k_commands_dispatch`, which is the union a
    /// person can actually type at either of its faces.
    private func answered68K() throws -> Set<String> {
        let text = try read("guest68k/src/commands68.c")
        var names: Set<String> = []
        let regex = try NSRegularExpression(
            pattern: #"strcmp\(name, "([a-z]+)"\) == 0"#)
        for match in regex.matches(
            in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(match.range(at: 1), in: text) {
                names.insert(String(text[r]))
            }
        }
        XCTAssertFalse(names.isEmpty, "could not read NOW-68K's dispatch")
        return names
    }

    /// Its doc table — `k_docs` in the same file, which BOTH of its faces
    /// render: the wire's `help` builds JSON rows from it and `conwin.c`
    /// prints it.
    private func documented68K() throws -> Set<String> {
        let text = try read("guest68k/src/commands68.c")
        guard let table = text.range(of: "static const N68CommandDoc k_docs[]")
        else {
            XCTFail("no doc table in commands68.c")
            return []
        }
        var names: Set<String> = []
        let regex = try NSRegularExpression(pattern: #"\{\s*"([a-z]+)",\s*""#)
        let tail = String(text[table.lowerBound...])
        for match in regex.matches(
            in: tail, range: NSRange(tail.startIndex..., in: tail)) {
            if let r = Range(match.range(at: 1), in: tail) {
                names.insert(String(tail[r]))
            }
        }
        XCTAssertFalse(names.isEmpty, "could not read NOW-68K's doc table")
        return names
    }

    /// The same three-halves check, for the other guest.
    ///
    /// It did not exist until `front` was added, and its absence was
    /// provable: deleting `front`'s row from `k_docs` while leaving the
    /// dispatch case in place kept every test in this suite green. That is
    /// a working command nobody can discover — `help` IS discovery here,
    /// on both faces, and it is the only thing the host console's Tab
    /// completion has to go on. The PowerPC half of this has been checked
    /// since `tail` proved the same point from the other direction.
    ///
    /// NOW-68K serves a strict SUBSET of the registry, so the contract
    /// check is containment rather than equality — the reverse would fail
    /// on every verb the PowerPC guest has and this one does not.
    func testTheSixtyEightKGuestsThreeHalvesAgree() throws {
        let answered = try answered68K()
        let documented = try documented68K()
        let declared = try declared()

        XCTAssertEqual(answered, documented, """
            NOW-68K's dispatch and its doc table disagree. Answered but \
            undocumented is a command that works and cannot be found — \
            `help` is the only discovery surface on either of this \
            guest's faces, and the host console's Tab completion reads \
            nothing else. Documented but unanswered is a command that is \
            offered and then refused.
            """)
        XCTAssertTrue(documented.isSubset(of: declared), """
            NOW-68K documents \
            \(documented.subtracting(declared).sorted().joined(separator: ", ")) \
            which the contract's x-commands does not declare. A guest \
            inventing a verb is a verb the host can only learn about by \
            accident — the contract changes first (AGENTS.md).
            """)
    }

    /// The dumb-shell invariant, and the thing most likely to be undone by
    /// someone adding a convenience: this side must not name a command the
    /// guest serves. It knew fifteen of them, which was wrong for the Carbon
    /// guest the moment NOW-68K appeared with three.
    ///
    /// `help` is the exception and is spelled out: the host sends it for
    /// completion and for the menu item, which is how discovery happens at
    /// all. Naming it is not knowing the command SET.
    func testTheHostConsoleNamesNoGuestCommand() throws {
        let source = try read("host/Sources/Host/ConsoleModel.swift")
        let guestOnly = try declared().subtracting(["help"])

        for name in guestOnly.sorted() {
            XCTAssertFalse(source.contains("\"\(name)\""), """
                ConsoleModel.swift mentions the guest command "\(name)" as a \
                string literal. The host console is a dumb shell: it relays \
                the line and renders the reply, and there are two guests \
                with different command tables, so a list or a special case \
                here is wrong for at least one of them.
                """)
        }
    }

    /// The other half of the same invariant: what IS host-local stays small
    /// and stays behind the "/" prefix, so a verb added to either guest can
    /// never be shadowed by something on this side.
    func testHostLocalVerbsAreFewAndPrefixed() throws {
        XCTAssertEqual(ConsoleModel.localPrefix, "/")
        XCTAssertEqual(Set(ConsoleModel.LocalVerb.allCases.map(\.rawValue)),
                       ["clear", "save", "help", "swpage", "cancel"], """
            The host-local verb set changed. It stays small and explicit: a \
            verb belongs here only if no guest could serve it as a command — \
            three act on this console, swpage drives the software.list \
            family, which the host implements itself, and cancel acts on a \
            request THIS side made and holds the id for, which a guest has \
            no word for ("the thing you asked me a moment ago" names \
            nothing on the far machine). Anything a guest could answer \
            belongs on the guest, where the two tables differ.
            """)
        for verb in ConsoleModel.LocalVerb.allCases {
            XCTAssertFalse(verb.summary.isEmpty,
                           "/\(verb.rawValue) has no summary, so /help omits it")
        }
    }

    /// Every command's console grammar is stated in the contract, where both
    /// halves read it — because the sender is now forbidden from knowing it,
    /// and prose is all that is left to keep the two implementations honest.
    func testCommandsWithArgumentsDeclareTheirLineGrammar() throws {
        let text = try read("contract/asyncapi.yaml")
        for name in ["ls", "tail", "census", "sw", "launch", "quit",
                     "reveal", "vers", "screenshot", "gestalt", "help"] {
            guard let start = text.range(of: "\n    \(name):\n") else {
                XCTFail("\(name) is not in the contract's registry")
                continue
            }
            let rest = text[start.upperBound...]
            // The next sibling entry: exactly four spaces then a name. A
            // deeper line (six spaces) is still inside this command.
            let end = rest.range(of: "\n    [a-z]",
                                 options: .regularExpression)?.lowerBound
                ?? rest.endIndex
            XCTAssertTrue(rest[..<end].contains("x-line:"), """
                \(name) takes arguments a human can type, but the contract \
                does not say what its console line means. The host cannot \
                say — it does not parse it — so this file is the only place \
                the two implementations can be compared.
                """)
        }
    }
}
