import Foundation
import XCTest
@testable import NOWAgentIntegration

/// The test `docs/contract-coverage.md` says it wishes it had, pointed at
/// the other half of the question.
///
/// `contract-coverage.md` derives what each GUEST serves and admits in its
/// own last section that nothing enforces it. `docs/mcp-coverage.md`
/// derives what any HOST FACE can ask for, and this is the enforcement:
/// the registry, the contract and both guests' dispatch are read here, and
/// the document must account for every difference between them.
///
/// The property under test is not "the tables are correct today". It is
/// that a capability cannot be added, or a gap closed, without the document
/// saying so — and that a gap cannot be labelled a decision without a
/// citation. A gap with a reason and a gap by accident are different facts;
/// collapsing them is how the accidental ones survive, so the disposition
/// column is checked as data rather than read as prose.
///
/// Nothing here constructs what it then parses. The host side is the live
/// registry, the contract side is the contract file, the guest side is the
/// guests' own dispatch, and the document is a fourth artifact compared
/// against all three.
final class MCPCoverageTests: XCTestCase {

    // MARK: - The document's own vocabulary

    /// Dispositions the document may use. Closed on purpose: a fourth word
    /// would be a fourth meaning nobody agreed to, and "sort of decided" is
    /// exactly the state this column exists to make impossible.
    private static let dispositions: Set<String> = [
        "deliberate", "planned", "unnoticed",
    ]

    private static let coverageDoc = "docs/mcp-coverage.md"

    /// The heading above the per-projection table.
    ///
    /// Named here once, and deliberately count-free. It used to read "What
    /// the thirteen reach", so landing a capability renamed a published
    /// heading and this string with it — the papercut every projection in
    /// the wide phase would have paid again.
    private static let projectionSection = "## What the projections reach"

    // MARK: - Host side: the registry, in process

    /// Capability name → what it requires and what it exposes, read from the
    /// live registry rather than from a parsed copy of it.
    ///
    /// Both arrays are carried because they answer different questions and
    /// this file needs each for a different check. `requires` decides
    /// availability against a partial guest; `exposes` decides coverage. Using
    /// the first as the second is the blind spot this test used to have.
    private func registryRows()
        -> [(name: String, requires: [String], exposes: [String])] {
        HostProjectionRegistry.hostFaces.projections.map {
            ($0.capability.rawValue, $0.requires, $0.exposes)
        }
    }

    // MARK: - Tests

    /// Every registered projection has a row, and every row is a registered
    /// projection — with the requirements the code actually declares.
    ///
    /// This is the assertion that fails when a capability lands
    /// undocumented, which is the drift the document was written for.
    func testTheProjectionTableMatchesTheRegistry() throws {
        let rows = try table(under: Self.projectionSection)
        var documented: [String: (requires: [String], exposes: [String])] = [:]
        for row in rows {
            let name = try backticked(row[0], row: row)
            XCTAssertNil(
                documented[name],
                "\(Self.coverageDoc) lists \(name) twice.")
            documented[name] = (codeTokens(row[1]), codeTokens(row[2]))
        }

        let registry = registryRows()
        let registered = Set(registry.map(\.name))
        let inDoc = Set(documented.keys)

        for missing in registered.subtracting(inDoc).sorted() {
            XCTFail(
                "The registry serves \"\(missing)\" and "
                    + "\(Self.coverageDoc) does not list it. A capability "
                    + "an agent can call and the coverage document has "
                    + "never heard of is the drift this document exists to "
                    + "make visible — add a row under "
                    + "\"\(Self.projectionSection)\".")
        }
        for extra in inDoc.subtracting(registered).sorted() {
            XCTFail(
                "\(Self.coverageDoc) lists \"\(extra)\" as a projected "
                    + "capability and no row in HostProjectionCatalog "
                    + "claims it. The document is describing a tool that "
                    + "does not exist.")
        }

        for row in registry {
            guard let stated = documented[row.name] else { continue }
            XCTAssertEqual(
                Set(stated.requires), Set(row.requires),
                "\(Self.coverageDoc) states \(row.name) requires "
                    + "\(stated.requires.sorted()); the code declares "
                    + "\(row.requires.sorted()). Requirements decide "
                    + "availability against a partial guest, so a wrong "
                    + "row here reads as a tool that works where it does "
                    + "not.")
            XCTAssertEqual(
                Set(stated.exposes), Set(row.exposes),
                "\(Self.coverageDoc) states \(row.name) exposes "
                    + "\(stated.exposes.sorted()); the code declares "
                    + "\(row.exposes.sorted()). Exposure decides what the "
                    + "gap table says is covered, so a wrong row here is a "
                    + "capability reading as askable when nothing returns "
                    + "its answer.")
        }
    }

    /// A projection cannot expose a capability it does not require.
    ///
    /// The subset rule is what keeps `exposes` an honest narrowing of
    /// `requires` rather than a second, freely-written list. A row that claims
    /// to expose something it never asks the guest for is either mislabelled
    /// or answering from host state — and the second is the stop condition the
    /// whole seam exists to make visible.
    func testExposedCapabilitiesAreAlwaysRequiredOnes() {
        for row in registryRows() {
            let extra = Set(row.exposes).subtracting(row.requires)
            XCTAssertTrue(
                extra.isEmpty,
                "\(row.name) exposes "
                    + "\(extra.sorted().joined(separator: ", "))"
                    + " and does not require it. A projection cannot hand a "
                    + "caller the answer to a capability it never had "
                    + "grounds to ask the guest for; either add the "
                    + "requirement, or the row is answering from host state "
                    + "and that is a redesign.")
        }
    }

    /// Every requirement resolves to something the contract declares,
    /// directly or through the document's own alias table.
    ///
    /// An unresolvable requirement fails NOWHERE at run time: the ledger
    /// falls through to the command table, misses, and reports the tool
    /// permanently unavailable against every guest.
    func testEveryRequirementResolvesToTheContract() throws {
        let contract = try Contract(text: read("contract/asyncapi.yaml"))
        let aliases = try aliasTable()
        let declared = contract.messageNames.union(contract.verbs)

        for (alias, origin) in aliases {
            XCTAssertFalse(
                declared.contains(alias),
                "\(Self.coverageDoc) aliases \"\(alias)\", which the "
                    + "contract already declares. An alias for a real name "
                    + "hides a mismatch instead of showing one.")
            XCTAssertTrue(
                declared.contains(origin),
                "\(Self.coverageDoc) aliases \"\(alias)\" to "
                    + "\"\(origin)\", which the contract does not declare.")
        }

        for row in registryRows() {
            for requirement in row.requires {
                XCTAssertTrue(
                    declared.contains(requirement)
                        || aliases[requirement] != nil,
                    "\(row.name) requires \"\(requirement)\", which is "
                        + "neither a contract message name nor a contract "
                        + "command nor aliased in \(Self.coverageDoc). "
                        + "Nothing rejects an unknown requirement at run "
                        + "time: it reads as a missing command, so the "
                        + "tool is switched off against every guest.")
            }
        }
    }

    /// The gap table is exactly the host-askable capability no projection
    /// **exposes** — no row missing, and no row for a gap that is not one.
    ///
    /// Coverage is derived from `exposes`, not `requires`, and the difference
    /// is the point. Required-internally is not askable-by-a-caller:
    /// `now_launch_software` requires `software.list`, sweeps the catalog to
    /// match one name, and returns no listing at all — so under `requires` the
    /// software listing read as covered while an agent could not ask what was
    /// installed. It was a real gap wearing a tick, and the document said so
    /// about itself because it could not fix it from where it sat.
    func testTheGapTableIsExactlyWhatNoProjectionReaches() throws {
        let contract = try Contract(text: read("contract/asyncapi.yaml"))
        let aliases = try aliasTable()
        let covered = Set(
            registryRows().flatMap(\.exposes).map { aliases[$0] ?? $0 })

        var universe = contract.hostInitiated.union(contract.verbs)
        for row in try table(
            under: "### Asks the operations section does not mark") {
            let name = try backticked(row[0], row: row)
            XCTAssertTrue(
                contract.guestInitiated.contains(name),
                "\(Self.coverageDoc) adds \"\(name)\" by hand as an ask "
                    + "the operations section does not mark, but no `send` "
                    + "operation carries it. That table is for symmetric "
                    + "families only; it must not become a place to add an "
                    + "ordinary host ask by typing it.")
            universe.insert(name)
        }
        // A subsystem row stays one row until it is reached at all. The
        // moment a projection EXPOSES the census, whoever landed it owes
        // a row per probe — contract-coverage.md's rule, applied as a
        // condition rather than a judgement. Exposure is the right trigger:
        // a projection that merely consumed a census answer internally would
        // not let a caller ask probe by probe, so it would owe nothing.
        if covered.contains("census.request") {
            universe.formUnion(contract.probes)
        }

        let expected = universe.subtracting(covered)
        let rows = try table(under: "## Every gap, with its disposition")
        var stated: Set<String> = []
        for row in rows {
            let name = try backticked(row[0], row: row)
            XCTAssertTrue(
                stated.insert(name).inserted,
                "\(Self.coverageDoc) declares \"\(name)\" twice.")
        }

        for missing in expected.subtracting(stated).sorted() {
            XCTFail(
                "\"\(missing)\" is host-askable guest capability that no "
                    + "projection EXPOSES — some projection may well "
                    + "require it, which is not the same thing — and "
                    + "\(Self.coverageDoc) does not declare it. An "
                    + "undeclared gap is the accidental "
                    + "kind by definition — give it a row with a "
                    + "disposition, even if that disposition is "
                    + "\"unnoticed\".")
        }
        for phantom in stated.subtracting(expected).sorted() {
            let reason = covered.contains(phantom)
                ? "a projection already EXPOSES it, so it is not a gap — "
                    + "note that requiring it would not be enough, because "
                    + "a capability consumed internally is still unaskable"
                : "the contract declares no such host-askable capability"
            XCTFail(
                "\(Self.coverageDoc) declares a gap for \"\(phantom)\" "
                    + "and \(reason). A gap table that lists things that "
                    + "are not gaps cannot be trusted about the things "
                    + "that are.")
        }
    }

    /// Kind and Served are derived facts, so the document may not disagree
    /// with the derivation. `Served` is what makes this a JOIN rather than
    /// a host-side list: a gap in capability a guest already serves is the
    /// expensive kind.
    func testEveryGapRowStatesTheDerivedKindAndServingGuests() throws {
        let contract = try Contract(text: read("contract/asyncapi.yaml"))
        let guests = try GuestDispatch(
            ppcMessages: read("now-guest-ppc/src/core/wire.c"),
            k68Messages: read("now-guest-68k/src/core/wire68.c"),
            ppcCommands: read("now-guest-ppc/src/commands/commands.c"),
            k68Commands: read("now-guest-68k/src/commands/commands68.c"))

        for row in try table(under: "## Every gap, with its disposition") {
            let name = try backticked(row[0], row: row)
            let kind = row[1].trimmingCharacters(in: .whitespaces)
            let served = row[2].trimmingCharacters(in: .whitespaces)

            let derivedKind: String
            if contract.verbs.contains(name) {
                derivedKind = "command"
            } else if contract.probes.contains(name),
                !contract.messageNames.contains(name) {
                derivedKind = "probe"
            } else {
                derivedKind = "message"
            }
            XCTAssertEqual(
                kind, derivedKind,
                "\(Self.coverageDoc) calls \"\(name)\" a \(kind); the "
                    + "contract makes it a \(derivedKind).")

            let derivedServed = guests.served(name)
            XCTAssertEqual(
                served, derivedServed,
                "\(Self.coverageDoc) says \"\(name)\" is served by "
                    + "\(served); the guests' own dispatch says "
                    + "\(derivedServed). The Served column is the whole "
                    + "reason this is a join and not a host-side list — a "
                    + "gap in capability a guest already serves costs more "
                    + "than one in capability nobody has.")
        }
    }

    /// A gap is a decision only when the decision is cited.
    ///
    /// This is the assertion the document is really for. "Deliberate" with
    /// nothing behind it is how an accident gets retired quietly, so the
    /// word costs a reference; "planned" costs a plan item number.
    func testADeliberateGapCitesItsArgumentAndAPlannedGapItsPlanItem()
        throws {
        let planItem = try NSRegularExpression(pattern: #"\bW\d"#)
        for row in try table(under: "## Every gap, with its disposition") {
            let name = try backticked(row[0], row: row)
            let disposition = row[3].trimmingCharacters(in: .whitespaces)
            let why = row[4].trimmingCharacters(in: .whitespaces)

            XCTAssertTrue(
                Self.dispositions.contains(disposition),
                "\"\(name)\" has disposition \"\(disposition)\", which is "
                    + "not one of "
                    + "\(Self.dispositions.sorted().joined(separator: ", "))"
                    + ". The vocabulary is closed so that a gap is either "
                    + "argued, scheduled, or admitted to be neither.")
            XCTAssertFalse(
                why.isEmpty,
                "\"\(name)\" declares a disposition and no reason.")

            switch disposition {
            case "deliberate":
                XCTAssertTrue(
                    why.contains(".md"),
                    "\"\(name)\" is called a deliberate gap and cites "
                        + "nothing. A deliberate gap is one somebody "
                        + "argued for; the citation is what stops an "
                        + "accident being retired by typing the word. "
                        + "Cite the file that carries the argument, or "
                        + "mark it unnoticed.")
            case "planned":
                let range = NSRange(why.startIndex..., in: why)
                XCTAssertNotNil(
                    planItem.firstMatch(in: why, range: range),
                    "\"\(name)\" is called planned and names no plan item "
                        + "(expected something like \"W1 #4\"). Planned "
                        + "without a number is a wish.")
            default:
                break
            }
        }
    }

    /// The document's own headline claim, checked rather than typed: most
    /// of what an agent cannot ask for is capability a guest already has.
    /// If that ever stops being true, the document's opening paragraph is
    /// wrong and should be rewritten rather than left to read as current.
    func testMostUnreachedCapabilityIsAlreadyServedBySomeGuest() throws {
        let rows = try table(under: "## Every gap, with its disposition")
        let unserved = rows.filter {
            $0[2].trimmingCharacters(in: .whitespaces) == "none"
        }
        XCTAssertLessThan(
            unserved.count, rows.count / 2,
            "More than half the declared gaps are capability no guest "
                + "serves, so \(Self.coverageDoc)'s opening claim — that "
                + "the gap is mostly capability the guest already has — no "
                + "longer holds. Rewrite it rather than leaving it to read "
                + "as current.")
    }

    // MARK: - The contract, read rather than remembered

    private struct Contract {
        /// Wire `type` of every message the contract declares.
        let messageNames: Set<String>
        /// Messages carried by an operation whose action is `receive`: the
        /// guest receives them, so they are what a host can ask for.
        let hostInitiated: Set<String>
        /// The `send` half, needed only to check the document's hand-added
        /// symmetric rows are genuinely not derivable.
        let guestInitiated: Set<String>
        let verbs: Set<String>
        let probes: Set<String>

        init(text: String) throws {
            // components/messages: `key:` then `name: <wire type>`.
            guard let componentsAt = text.range(of: "\ncomponents:") else {
                throw Failure("no components section in the contract")
            }
            var byKey: [String: String] = [:]
            let components = String(text[componentsAt.lowerBound...])
            let message = try NSRegularExpression(
                pattern: #"^    ([A-Za-z]+):\n      name: ([a-z.]+)$"#,
                options: [.anchorsMatchLines])
            for match in message.matches(
                in: components,
                range: NSRange(components.startIndex..., in: components)) {
                guard let key = Range(match.range(at: 1), in: components),
                    let name = Range(match.range(at: 2), in: components)
                else { continue }
                byKey[String(components[key])] = String(components[name])
            }
            guard !byKey.isEmpty else {
                throw Failure("could not read the contract's messages")
            }
            messageNames = Set(byKey.values)

            guard let operationsAt = text.range(of: "\noperations:") else {
                throw Failure("no operations section in the contract")
            }
            var receive: Set<String> = []
            var send: Set<String> = []
            var action: String?
            let operations = text[
                operationsAt.upperBound..<componentsAt.lowerBound]
            for line in operations.components(separatedBy: "\n") {
                if line.hasPrefix("  "), !line.hasPrefix("   "),
                    line.hasSuffix(":") {
                    action = nil
                } else if line.hasPrefix("    action: ") {
                    action = String(line.dropFirst("    action: ".count))
                } else if let ref = line.range(of: "messages/"),
                    line.hasSuffix("\"") {
                    let key = String(line[ref.upperBound...].dropLast())
                    guard let name = byKey[key] else { continue }
                    if action == "receive" {
                        receive.insert(name)
                    } else if action == "send" {
                        send.insert(name)
                    }
                }
            }
            guard !receive.isEmpty, !send.isEmpty else {
                throw Failure("could not read the contract's operations")
            }
            hostInitiated = receive
            guestInitiated = send

            verbs = try Self.keys(
                in: text, under: "\n  x-commands:\n", atIndent: 4)
            probes = try Self.keys(
                in: text, under: "\n    x-probes:\n", atIndent: 6)
        }

        /// The keys of one closed registry. A sibling section at the
        /// parent's indent ends it, exactly as CommandRegistryTests reads
        /// `x-commands`.
        private static func keys(
            in text: String, under anchor: String, atIndent indent: Int
        ) throws -> Set<String> {
            guard let start = text.range(of: anchor) else {
                throw Failure("no \(anchor.trimmingCharacters(in: .whitespacesAndNewlines)) in the contract")
            }
            let pad = String(repeating: " ", count: indent)
            let parent = String(repeating: " ", count: indent - 2)
            var names: Set<String> = []
            for line in text[start.upperBound...]
                .components(separatedBy: "\n") {
                if line.hasPrefix(parent), !line.hasPrefix(parent + " "),
                    line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                    break
                }
                guard line.hasPrefix(pad), !line.hasPrefix(pad + " ") else {
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasSuffix(":"), !trimmed.contains(" ") else {
                    continue
                }
                names.insert(String(trimmed.dropLast()))
            }
            guard !names.isEmpty else {
                throw Failure("read no names under \(anchor)")
            }
            return names
        }
    }

    // MARK: - The guests, read the way contract-coverage.md publishes

    private struct GuestDispatch {
        let ppc: Set<String>
        let k68: Set<String>

        init(
            ppcMessages: String, k68Messages: String,
            ppcCommands: String, k68Commands: String
        ) throws {
            // The four greps docs/contract-coverage.md publishes, as
            // regexes. Reusing its method rather than inventing a second
            // one is deliberate: two derivations of one fact drift.
            let ppcTypes = try Self.captures(
                #"json_type_is\([a-z_]+, *"([a-z.]+)"\)"#, in: ppcMessages)
            let k68Types = try Self.captures(
                #"strcmp\(type, "([a-z.]+)"\)"#, in: k68Messages)
            let ppcVerbs = try Self.captures(
                #"strcmp\(name, "([a-z]+)"\) == 0"#, in: ppcCommands)
            let k68Verbs = try Self.captures(
                #"\{ *"([a-z]+)""#, in: k68Commands)
            for (label, set) in [
                ("wire.c", ppcTypes), ("wire68.c", k68Types),
                ("commands.c", ppcVerbs), ("commands68.c", k68Verbs),
            ] where set.isEmpty {
                throw Failure("read no dispatch from \(label)")
            }
            ppc = ppcTypes.union(ppcVerbs)
            k68 = k68Types.union(k68Verbs)
        }

        /// Commands and message types share one namespace here because
        /// they do not collide: the contract's verbs have no dots and its
        /// message names all do.
        func served(_ name: String) -> String {
            switch (ppc.contains(name), k68.contains(name)) {
            case (true, true): return "both"
            case (true, false): return "ppc"
            case (false, true): return "68k"
            case (false, false): return "none"
            }
        }

        private static func captures(
            _ pattern: String, in text: String
        ) throws -> Set<String> {
            let regex = try NSRegularExpression(pattern: pattern)
            var found: Set<String> = []
            for match in regex.matches(
                in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) {
                    found.insert(String(text[range]))
                }
            }
            return found
        }
    }

    // MARK: - Reading the document

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(path),
            encoding: .utf8)
    }

    /// The first markdown table after a heading, as cells. The heading is
    /// named in the failure so a renamed section is a one-line fix rather
    /// than a hunt.
    private func table(under heading: String) throws -> [[String]] {
        let document = try read(Self.coverageDoc)
        guard let start = document.range(of: "\n" + heading + "\n") else {
            throw Failure(
                "\(Self.coverageDoc) has no \"\(heading)\" section. The "
                    + "test reads its tables by heading; rename one and "
                    + "this is where it says so.")
        }
        var rows: [[String]] = []
        var seenHeader = false
        for line in document[start.upperBound...]
            .components(separatedBy: "\n") {
            guard line.hasPrefix("|") else {
                if rows.isEmpty && !seenHeader { continue }
                break
            }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if !seenHeader {
                seenHeader = true
                continue
            }
            if cells.allSatisfy({
                $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty
            }) {
                continue
            }
            rows.append(cells)
        }
        guard !rows.isEmpty else {
            throw Failure("read no table rows under \"\(heading)\"")
        }
        return rows
    }

    /// The document's alias table: a host-side requirement name and the
    /// contract name it stands for.
    private func aliasTable() throws -> [String: String] {
        var aliases: [String: String] = [:]
        for row in try table(
            under: "### One requirement is not a contract name") {
            let alias = try backticked(row[0], row: row)
            guard let origin = codeTokens(row[1]).first else {
                throw Failure(
                    "the alias row for \"\(alias)\" names no contract "
                        + "origin")
            }
            aliases[alias] = origin
        }
        return aliases
    }

    /// The single backticked identifier a first cell must be.
    private func backticked(_ cell: String, row: [String]) throws -> String {
        guard let name = codeTokens(cell).first, codeTokens(cell).count == 1
        else {
            throw Failure(
                "expected one backticked name in the first cell of "
                    + "\(row); got \"\(cell)\"")
        }
        return name
    }

    /// Every `backticked` token in a cell, in order.
    private func codeTokens(_ cell: String) -> [String] {
        cell.components(separatedBy: "`").enumerated()
            .filter { $0.offset % 2 == 1 }
            .map(\.element)
            .filter { !$0.isEmpty }
    }
}
