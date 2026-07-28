import Foundation
import XCTest
@testable import Host

/// Every capability a guest has must be reachable from BOTH of its faces:
/// the console a human types into at the machine, and the wire the host
/// drives it over. This reads the guests' own source and fails when one
/// face gains a verb the other did not.
///
/// It exists because that drift happened and was invisible. `process.list`
/// shipped on NOW-68K's wire on 2026-07-25 and its console could not list
/// processes at all — nothing failed, no test noticed, and the gap
/// surfaced only because someone asked out loud what the console could do.
/// The console is where a person standing at a PowerBook debugs a machine
/// whose display is the only thing they have; the wire is where everything
/// automated happens. A capability on one face is half a feature.
///
/// The check is deliberately textual, like GuestWireConformanceTests: it
/// reads the same dispatch lines a human reads. A parser that understood C
/// properly would be a second compiler with its own bugs; this one fails
/// loudly and is fixed by looking.
final class CommandParityTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path),
                   encoding: .utf8)
    }

    /// Every `strcmp(name, "verb")` in a file — how both guests dispatch.
    private func dispatched(in text: String) -> Set<String> {
        var found: Set<String> = []
        let pattern = #"strcmp\(name,\s*"([a-z_.]+)"\)"#
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0,
                                                     length: ns.length)) {
            found.insert(ns.substring(with: m.range(at: 1)))
        }
        return found
    }

    /// Verbs that live on one face for a stated reason. An entry here is a
    /// DECISION with a justification, not a to-do — anything not listed is
    /// a failure, and adding a line here should feel like a small act of
    /// documentation.
    private static let consoleOnly: [String: String] = [
        "help": "prints the console's own verbs; meaningless over a wire",
        "clear": "clears this window's pane; acts on nothing else",
        "?": "an alias for help",
        // The PowerPC guest's file verbs act through the file.* message
        // families rather than x-commands, so the host reaches the same
        // capability by a different route and needs no console verb.
        "put": "file.* family from the host side, not an x-command",
        "mv": "file.* family from the host side, not an x-command",
        "trash": "file.* family from the host side, not an x-command",
        "untrash": "file.* family from the host side, not an x-command",
        "mkdir": "file.* family from the host side, not an x-command",
        // NOW-68K's own console face on the file.* family. The host does
        // not reach it as a command — it pushes a file and reads the
        // file.progress / file.done it gets back — so this is a
        // renderer for a capability the wire already has, not a verb the
        // wire is missing.
        "xfer": "renders the file.* family's state; the host reads it "
              + "from file.progress and file.done instead",
    ]

    private static let wireOnly: [String: String] = [
        "putstat": """
            a diagnostic the host reads to size a transfer before sending; \
            there is nothing for a person at the guest to do with it. \
            Recorded as a deliberate asymmetry on 2026-07-25 rather than \
            fixed — if it ever grows a human-facing use, it needs a \
            console verb.
            """,
    ]

    /// The PowerPC guest: `commands.c` answers the wire, `console_model.c`
    /// answers the Console page. Two lists, so two chances to drift.
    func testThePowerPCGuestsTwoFacesAgree() throws {
        let wire = dispatched(in: try source("now-guest-ppc/src/commands/commands.c"))
        let console = dispatched(in: try source("now-guest-ppc/src/console/console_model.c"))

        let missingFromConsole = wire.subtracting(console)
            .subtracting(Self.wireOnly.keys)
        XCTAssertTrue(missingFromConsole.isEmpty, """
            the PowerPC guest answers \(missingFromConsole.sorted()) over \
            the wire but not in its own console. A person at the machine \
            cannot reach what the host can. Add it to console_model.c, or \
            name it in wireOnly with the reason it does not belong there.
            """)

        let missingFromWire = console.subtracting(wire)
            .subtracting(Self.consoleOnly.keys)
        XCTAssertTrue(missingFromWire.isEmpty, """
            the PowerPC guest's console answers \(missingFromWire.sorted()) \
            but the wire does not. Add it to commands.c and the contract's \
            x-commands, or name it in consoleOnly with its reason.
            """)
    }

    /// NOW-68K: `commands68.c` is the command table both faces share, and
    /// `conwin.c` adds the console-local verbs plus any capability that is
    /// a message family rather than a command.
    func testTheSixtyEightKGuestsTwoFacesAgree() throws {
        let consoleText = try source("now-guest-68k/src/commands/n68_exec.c")

        // The console does not re-dispatch launch/quit; it hands the name
        // to the SAME table the wire uses. That delegation is the whole
        // anti-drift property, and it is stronger than any list this test
        // could compare: a verb added to commands68.c reaches the console
        // the moment it exists, with nobody having to remember.
        XCTAssertTrue(consoleText.contains("now68k_commands_run"), """
            n68_exec.c no longer delegates to now68k_commands_run, so the \
            console and the wire now have separate command paths that can \
            disagree. That is the defect class this project has paid the \
            most for — see two-halves-never-met-in-a-test.
            """)

        // `help` is dispatched on BOTH faces on purpose, and it is the
        // one case where that is right: the wire answers a row per
        // command as JSON, the console prints text and adds its own
        // console-local verbs, and no single result struct holds both
        // shapes. What makes it safe is that both render the SAME list.
        XCTAssertTrue(consoleText.contains("now68k_commands_docs"), """
            n68_exec.c prints a help list it wrote itself instead of \
            rendering commands68.h's published table. A hand-written list \
            agrees with the wire's until someone adds a command, and then \
            the machine has two different answers to "what can you do" — \
            which is the whole reason that table is published.
            """)

        // `ps` is the second and, so far, last case of the same shape: a
        // row per PROCESS, which an N68CmdResult cannot hold either. Both
        // faces render proc_list_rows() — the wire as the contract's
        // [name, detail] pairs, the console as text for a 58-column pane
        // — so the walk they describe is one walk. Adding a third name
        // here should be argued for; the reason is always "one result
        // struct cannot hold this reply", never "it was easier".
        //
        // Any OTHER verb on both faces is two implementations of one verb.
        let table = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))
        // vprobe is the THIRD row-array command, and each exemption has to
        // buy its place with the thing that makes it safe. help renders the
        // published doc table; ps renders proc_list_rows(); vprobe BORROWS
        // the single measurement table rather than measuring again — which
        // matters more here than for the other two, because a second run
        // would cost ~12s AND could not agree with the first, the screen
        // having moved in between.
        XCTAssertTrue(consoleText.contains("now68k_commands_vprobe"), """
            n68_exec.c runs its own vprobe instead of borrowing the table \
            commands68.c filled. Two measurements of a changing screen \
            cannot agree, so the console and the wire would report \
            different numbers for the same machine and both would be \
            defensible — the worst kind of disagreement to debug.
            """)

        let duplicated = table.intersection(dispatched(in: consoleText))
            .subtracting(["help", "ps", "vprobe"])
        XCTAssertTrue(duplicated.isEmpty, """
            n68_exec.c dispatches \(duplicated.sorted()) itself while \
            commands68.c also does. Two implementations of one verb is how \
            the console and the wire start telling a person different \
            things about the same machine.
            """)
    }

    /// The direction the first version of this file did not check, and the
    /// one that broke: a verb NOW-68K's own console answers must also be a
    /// verb its wire answers. The host console is a **dumb shell** — it
    /// relays the line a person types and keeps no command list — so a
    /// capability the guest offers only at its own keyboard is a
    /// capability the host cannot reach at all.
    ///
    /// That is not hypothetical. `ps` lived in conwin.c alone; a person at
    /// the PowerBook could list processes, and the same guest answered
    /// `unknown-command` to `ps` from the host's console, while serving
    /// `process.list` on that same wire the whole time (2026-07-25). The
    /// message family made the capability LOOK present on both faces —
    /// and a message family is not something anyone can type.
    func testEveryVerbTheSixtyEightKConsoleAnswersIsAlsoOnItsWire() throws {
        let console = dispatched(in: try source("now-guest-68k/src/commands/n68_exec.c"))
        let wire = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))

        let missingFromWire = console.subtracting(wire)
            .subtracting(Self.consoleOnly.keys)
        XCTAssertTrue(missingFromWire.isEmpty, """
            NOW-68K's console answers \(missingFromWire.sorted()) but its \
            wire does not, so the host console — which sends whatever is \
            typed and knows no command list — gets unknown-command for a \
            verb the machine plainly has. Add it to commands68.c and the \
            contract's x-commands, or name it in consoleOnly with the \
            reason it cannot cross a wire.
            """)
    }

    /// The capability that is not a command. `process.list` is its own
    /// message family, so the parity rule cannot be checked by comparing
    /// command tables — and that is exactly how it shipped wire-only.
    func testTheSixtyEightKConsoleCanListProcesses() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")

        guard wire.contains("\"process.list\"") else {
            return   // if the guest ever stops serving it, this is moot
        }
        XCTAssertTrue(console.contains("\"ps\""), """
            NOW-68K serves process.list on the wire, so the host can ask \
            what is running — but its console cannot. That is the exact \
            gap this file was written for: a message family is a \
            capability too, and comparing command tables alone would never \
            have caught it.
            """)
        XCTAssertTrue(console.contains("proc_list_rows"), """
            the console lists processes without using proc_list_rows(), so \
            there are now two process walks that can disagree. One \
            implementation, two renderers — see docs/command-parity.md.
            """)
    }

    /// The second capability that is not a command. Receiving a pushed
    /// file is the `file.*` message family, so — exactly like
    /// `process.list` above — no command table compares the two faces,
    /// and a wire-only implementation would look complete from every
    /// angle except a person standing at the machine.
    func testTheSixtyEightKConsoleCanSeeAnIncomingFile() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")

        guard wire.contains("\"file.offer\"") else {
            return   // if the guest ever stops receiving files, this is moot
        }
        XCTAssertTrue(console.contains("\"xfer\""), """
            NOW-68K accepts a file.offer over the wire, so the host can \
            push a file to it — but its console cannot say whether one is \
            arriving, how far it has got, or where it will land. A \
            transfer in flight shows no window and a finished one lands \
            somewhere the app never mentioned, so this is the whole of \
            what a person at the machine can know about it.
            """)
        XCTAssertTrue(console.contains("now68k_wire_put_status"), """
            n68_exec.c reports on transfers without reading \
            now68k_wire_put_status(), so the console and the wire now \
            keep separate counts of the same transfer. One \
            implementation, two renderers — see docs/command-parity.md.
            """)
    }

    /// The third capability that is not a command — and the one where
    /// the lesson was applied before it cost anything. SENDING a file is
    /// the `file.*` family read from the other end, so again no command
    /// table compares the two faces on its own.
    ///
    /// Two things are asserted, and they are different. The first is
    /// that a person at the machine can SEE an outgoing transfer, which
    /// is `xfer`'s job in both directions. The second is that `put` is
    /// in commands68.c rather than only in conwin.c, so the host console
    /// — a dumb shell with no knowledge of message families — can type
    /// it. `ps` satisfied the first and failed the second for a day.
    func testTheSixtyEightKConsoleCanSeeAnOutgoingFile() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")
        // dispatched(), not contains("\"put\"") — the doc table names
        // every verb too, so a substring check passes on a guest that
        // merely ADVERTISES the command and answers unknown-command to
        // it. Caught by mutation: renaming the dispatch arm left the
        // first version of this test green.
        let table = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))

        guard wire.contains("now68k_wire_send_file") else {
            return   // if the guest ever stops sending files, this is moot
        }
        XCTAssertTrue(console.contains("now68k_wire_send_status"), """
            NOW-68K can send a file, but its console cannot say whether \
            one is going out or what became of the last one. A person who \
            types `put` and then has no way to ask what happened is in \
            exactly the position `xfer` was written to fix, facing the \
            other way.
            """)
        XCTAssertTrue(table.contains("put"), """
            `put` is not in commands68.c's table, so the host console \
            gets unknown-command for it while a person at the PowerBook \
            can send files happily. That is the `ps` failure exactly: the \
            host console sends the line a person types and knows no \
            message families, so a capability reachable only from the \
            guest's own keyboard is one the host cannot reach at all.
            """)
    }

    /// The fourth capability that is not a command: BROWSING. `file.list`
    /// is a message family, so — like `process.list` and the two transfer
    /// directions above — no command table compares the two faces on its
    /// own, and a wire-only implementation would look complete from every
    /// angle except a person standing at the machine.
    ///
    /// Three things are asserted and they are different. That `ls` is in
    /// commands68.c, so the host console — a dumb shell with no knowledge
    /// of message families — can type it. That the console does NOT also
    /// dispatch it, because the whole point of the rows result type is
    /// that conwin.c reaches this verb by delegating. And that both faces
    /// read one enumeration.
    func testTheSixtyEightKConsoleCanListFiles() throws {
        let wire = try source("now-guest-68k/src/core/wire68.c")
        let console = try source("now-guest-68k/src/commands/n68_exec.c")
        let table = dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))

        guard wire.contains("\"file.list\"") else {
            return   // if the guest ever stops serving it, this is moot
        }
        XCTAssertTrue(table.contains("ls"), """
            NOW-68K serves file.list on the wire, so the host can see \
            what is on the machine — but `ls` is not in commands68.c's \
            table, so the host console gets unknown-command for it. That \
            is the `ps` failure exactly: a capability that is a family on \
            the wire is not something anyone can type.
            """)
        XCTAssertTrue(console.contains("now68k_commands_run_rows"), """
            conwin.c does not reach the table-shaped commands, so `ls` is \
            a verb the host can type and a person at the PowerBook cannot \
            — the same gap as `ps`, facing the other way.
            """)
        XCTAssertFalse(dispatched(in: console).contains("ls"), """
            n68_exec.c dispatches `ls` itself. It must not: \
            docs/command-parity.md's ruling on the third row-array command \
            was that a fourth should be a result type that holds rows, not \
            another exemption — and a strcmp here is exactly the fourth \
            arm that ruling forbids.
            """)
        XCTAssertTrue(
            try source("now-guest-68k/src/commands/commands68.c")
                .contains("n68_fileenum_page"), """
            `ls` lists files without going through n68_fileenum_page(), so \
            there are now two catalog walks that can disagree. One \
            implementation, two renderers — see docs/command-parity.md.
            """)
        XCTAssertTrue(wire.contains("n68_fileenum_page"), """
            the wire serves file.list from something other than \
            n68_fileenum_page(), which is the same drift from the other \
            side.
            """)
    }

    /// Both guests must only claim verbs the contract declares. The
    /// contract's registry is the source of truth; a guest inventing one
    /// is how a host learns to ask for something no schema describes.
    func testNeitherGuestInventsCommandsTheContractDoesNotDeclare() throws {
        let contract = try source("contract/asyncapi.yaml")
        let declared: Set<String> = {
            guard let start = contract.range(of: "\n  x-commands:") else {
                return []
            }
            let tail = contract[start.upperBound...]
            var names: Set<String> = []
            for line in tail.split(separator: "\n") {
                if !line.hasPrefix("  ") && !line.isEmpty { break }
                let t = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("    "), t.hasSuffix(":"),
                      !t.hasPrefix("x-") else { continue }
                let name = String(t.dropLast())
                if name.allSatisfy({ $0.isLowercase || $0 == "-" }) {
                    names.insert(name)
                }
            }
            return names
        }()
        XCTAssertFalse(declared.isEmpty, "could not read x-commands")

        for (file, verbs) in [
            ("now-guest-ppc/src/commands/commands.c",
             dispatched(in: try source("now-guest-ppc/src/commands/commands.c"))),
            ("now-guest-68k/src/commands/commands68.c",
             dispatched(in: try source("now-guest-68k/src/commands/commands68.c"))),
        ] {
            let undeclared = verbs.subtracting(declared)
                .subtracting(Self.consoleOnly.keys)
            XCTAssertTrue(undeclared.isEmpty, """
                \(file) answers \(undeclared.sorted()) on the wire, which \
                the contract's x-commands does not declare. The contract \
                changes FIRST — a verb the host cannot find in the schema \
                is a verb it can only learn about by accident.
                """)
        }
    }
}
