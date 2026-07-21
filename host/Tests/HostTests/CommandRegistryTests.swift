import Foundation
import XCTest
@testable import Host

/// The command set lives in three hand-maintained places: the contract
/// declares it, the guest answers it, and this side offers it. Nothing
/// made them agree.
///
/// Adding `tail` proved the gap: it was written into the guest's table
/// and nowhere else, so the machine answered a command the contract did
/// not declare and this console would not offer. Undeclared and
/// unreachable is the quietest kind of broken — the feature exists, and
/// no path to it does.
///
/// Like the wire fixtures, this reads the other halves rather than
/// trusting a copy of them.
final class CommandRegistryTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Names under `x-commands:` in the contract — the declared spine.
    private func declared() throws -> Set<String> {
        let text = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "contract/asyncapi.yaml"), encoding: .utf8)
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
        let text = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "guest/src/commands.c"), encoding: .utf8)
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

    func testTheThreeHalvesAgreeOnTheCommandSet() throws {
        let declared = try declared()
        let answered = try answered()
        let offered = Set(ConsoleModel.commands)

        XCTAssertEqual(declared, answered, """
            The contract and the guest disagree. Declared but unanswered \
            means the console offers a command that fails; answered but \
            undeclared means a working command nobody can reach.
            """)
        XCTAssertEqual(offered, declared, """
            This console and the contract disagree. Every declared command \
            should be offered, and offering an undeclared one sends \
            something the other Mac will answer "unknown-command".
            """)
    }

    /// Every offered command needs its help, or `help` lies by omission.
    func testEveryOfferedCommandIsDocumented() {
        for name in ConsoleModel.commands {
            XCTAssertNotNil(ConsoleModel.catalog[name],
                            "\(name) is offered with no help text")
        }
    }
}
