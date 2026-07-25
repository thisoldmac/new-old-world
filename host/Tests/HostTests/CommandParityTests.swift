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
        let wire = dispatched(in: try source("guest/src/commands.c"))
        let console = dispatched(in: try source("guest/src/console_model.c"))

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
        let consoleText = try source("guest68k/src/conwin.c")

        // The console does not re-dispatch launch/quit; it hands the name
        // to the SAME table the wire uses. That delegation is the whole
        // anti-drift property, and it is stronger than any list this test
        // could compare: a verb added to commands68.c reaches the console
        // the moment it exists, with nobody having to remember.
        XCTAssertTrue(consoleText.contains("now68k_commands_run"), """
            conwin.c no longer delegates to now68k_commands_run, so the \
            console and the wire now have separate command paths that can \
            disagree. That is the defect class this project has paid the \
            most for — see two-halves-never-met-in-a-test.
            """)

        // ...and it must not have grown its own copy of a table verb.
        let table = dispatched(in: try source("guest68k/src/commands68.c"))
        let duplicated = table.intersection(dispatched(in: consoleText))
        XCTAssertTrue(duplicated.isEmpty, """
            conwin.c dispatches \(duplicated.sorted()) itself while \
            commands68.c also does. Two implementations of one verb is how \
            the console and the wire start telling a person different \
            things about the same machine.
            """)
    }

    /// The capability that is not a command. `process.list` is its own
    /// message family, so the parity rule cannot be checked by comparing
    /// command tables — and that is exactly how it shipped wire-only.
    func testTheSixtyEightKConsoleCanListProcesses() throws {
        let wire = try source("guest68k/src/wire68.c")
        let console = try source("guest68k/src/conwin.c")

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
            ("guest/src/commands.c",
             dispatched(in: try source("guest/src/commands.c"))),
            ("guest68k/src/commands68.c",
             dispatched(in: try source("guest68k/src/commands68.c"))),
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
