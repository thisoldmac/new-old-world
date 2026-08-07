import Foundation
import MirrorKit
import XCTest

/// The gate on `docs/known-wrong.md` — the register of things this product
/// knowingly ships that disagree with the machine.
///
/// That file is hand-maintained, and this repository has paid three times
/// in one day for hand-maintained enumerations that rotted at a merge
/// (AGENTS.md > "Enumerated lists rot at merges, and only a gate catches
/// it"). Two failure modes matter and they are different:
///
/// 1. **A row loses its argument.** A deviation with no stated reason is
///    indistinguishable from an oversight, which is the exact confusion
///    the file exists to end. So every row's six fields are checked as
///    DATA rather than read as prose, and the disposition words are a
///    closed vocabulary — "sort of decided" is the state this column is
///    here to make impossible.
/// 2. **A row outlives its own defect.** Somebody fixes the grow box and
///    the register goes on claiming it is broken, which is worse than no
///    register: a reader trusts it and stops looking. Two rows make a
///    claim that is checkable from here, and those two are checked
///    against the live code. **When a lane closes one, this test fails
///    and names the row to delete.** That is the intended failure, and
///    the message says so — it worked twice on 2026-08-07, when
///    `claude/019-kw01-kw06` closed the grow box and the `ctlact` false
///    negative and this file failed naming both.
///
///    **Deleting a row renumbers the ones below it**, because contiguity
///    is gated. So these test names carry a POSITION, not a permanent
///    name, and closing another row will move them again. The register
///    says the same thing to its readers.
///
/// What this canNOT check, said out loud because a gate that looks wider
/// than it is repeats the mistake it exists to catch: nothing here reads
/// the guest's pixels, the resident, the 68K tree or the emulator. Rows
/// KW-02 through KW-05 and KW-07 through KW-12 are prose, and
/// their measurements can rot with nobody noticing. The file says so too.
final class KnownWrongRegisterTests: XCTestCase {

    private static let registerDoc = "docs/known-wrong.md"

    /// The fields every row carries. Ordered, because a row that lists
    /// them in a different order is a row somebody wrote from memory.
    private static let requiredFields = [
        "What disagrees", "Measured", "Why it is left",
        "What would close it", "Owner", "Status",
    ]

    /// Closed on purpose. A third word would be a third meaning nobody
    /// agreed to.
    private static let statuses: Set<String> = ["decided", "undecided"]

    // MARK: - The document's shape

    func testEveryRowCarriesAllSixFields() throws {
        for row in try rows() {
            for field in Self.requiredFields where row.fields[field] == nil {
                XCTFail(
                    "\(Self.registerDoc): \(row.id) has no \"\(field)\" "
                        + "field. A row missing one is not a decision "
                        + "anyone can argue with — which is the only thing "
                        + "this file is for. The six are: "
                        + Self.requiredFields.joined(separator: ", ") + ".")
            }
        }
    }

    func testRowIdsAreUniqueAndContiguous(  ) throws {
        let ids = try rows().map(\.id)
        XCTAssertFalse(ids.isEmpty,
                       "\(Self.registerDoc) has no KW- rows at all.")
        let expected = (1...ids.count).map { String(format: "KW-%02d", $0) }
        XCTAssertEqual(
            ids, expected,
            "\(Self.registerDoc): row ids must be KW-01 upward with no "
                + "gaps and no repeats. A gap reads as a row somebody "
                + "deleted without closing, and a repeat means two rows "
                + "answer to one citation.")
    }

    func testStatusIsOneOfTheTwoWords() throws {
        for row in try rows() {
            let status = row.word("Status")
            XCTAssertTrue(
                Self.statuses.contains(status),
                "\(Self.registerDoc): \(row.id) has Status "
                    + "\"\(status)\". Allowed: "
                    + Self.statuses.sorted().joined(separator: ", ") + ".")
        }
    }

    /// An `undecided` row is one nobody has argued for, so it cannot name
    /// somebody who did. Only this direction is checked: a `decided` row
    /// may honestly be `unassigned` — a deviation the project as a whole
    /// stands behind with no single author is still a decision (KW-10,
    /// KW-11). The failure this catches is the other way round: a row
    /// quietly acquiring an owner while still claiming nobody chose it,
    /// which takes it off the list of things to close without closing it.
    func testAnUndecidedRowNamesNobodyWhoDecidedIt() throws {
        for row in try rows() where row.word("Status") == "undecided" {
            let owner = row.word("Owner")
            XCTAssertEqual(
                owner, "unassigned",
                "\(Self.registerDoc): \(row.id) is undecided with Owner "
                    + "\(owner). If somebody took it, say `decided`; if "
                    + "nobody did, say `unassigned`. The pair is what "
                    + "separates a decision from an oversight.")
        }
    }

    /// Owners are `Michelle`, a lane branch, or `unassigned`. A free-text
    /// owner is how a row ends up belonging to nobody in particular.
    func testOwnerIsMichelleALaneOrUnassigned() throws {
        for row in try rows() {
            let owner = row.word("Owner")
            let ok = owner == "Michelle" || owner == "unassigned"
                || owner.hasPrefix("claude/") || owner.hasPrefix("codex/")
                || owner.hasPrefix("thread/") || owner.hasPrefix("fork/")
            XCTAssertTrue(
                ok,
                "\(Self.registerDoc): \(row.id) has Owner \"\(owner)\". "
                    + "It must be Michelle, a lane branch in one of the "
                    + "namespaces this repo uses, or unassigned.")
        }
    }

    // MARK: - The rows whose claim is checkable from here
    //
    // Each of these FAILS WHEN THE DEFECT IS FIXED. That is the point.

    /// KW-01 — no zoom box is drawn on any window, because IR v1 cannot
    /// say which windows have one. Deliberate, and it costs five of nine
    /// corpus windows a widget the machine draws.
    func testKW01NoWindowShapeIsGivenAZoomBox() throws {
        try requireRow("KW-01")
        for (kind, title) in [(2 as Int?, "Extensions Manager"),
                              (8, "SimpleText"),
                              (20, "Macintosh HD"),
                              (2000, "Appearance"),
                              (nil, "unreported kind")] {
            let win = try window(kind: kind, title: title)
            XCTAssertNil(
                WindowChrome.widgetBox(win, .zoom),
                "KW-01 in \(Self.registerDoc) says nothing draws a zoom "
                    + "box, on any window, until the WindowRecord's "
                    + "spareFlag crosses the contract. \"\(title)\" now "
                    + "gets one — if the flag landed, close the row; if "
                    + "it did not, the fabricated affordance is back and "
                    + "a zoom act clicks into the racing stripes.")
        }
    }

    /// KW-06 — menu item geometry assumes uniform 16-pixel rows, ~30 px
    /// out by the bottom of a menu with separators. The row's stated
    /// reason ("nothing consumes item rects") has expired, so the
    /// consumer is checked too: if `menuItemPoint` loses its last caller
    /// the row is a dead constant, not a live wrong answer.
    func testKW06MenuGeometryStillAssumesUniformRowsAndStillHasACaller()
        throws
    {
        try requireRow("KW-06")
        XCTAssertEqual(
            ActionModel.menuRowHeight, 16,
            "KW-06 in \(Self.registerDoc) says menu item points are "
                + "computed from a uniform 16 px row. The constant "
                + "moved — if real row heights now reach the host, close "
                + "the row.")
        // Two items three apart must be exactly three rows apart. If they
        // are not, geometry stopped being uniform and the row is wrong.
        let first = ActionModel.menuItemPoint(menuLeft: 100, itemIndex: 1)
        let fourth = ActionModel.menuItemPoint(menuLeft: 100, itemIndex: 4)
        XCTAssertEqual(
            fourth.1 - first.1, 3 * ActionModel.menuRowHeight,
            "KW-06 says the spacing is uniform. It is not any more, which "
                + "means somebody taught this real geometry. Close the row.")
    }

    // MARK: - Reading the document

    private struct Row {
        let id: String
        var fields: [String: String]

        /// A single-word field, with the markdown code ticks the document
        /// writes it in taken off. `Owner` and `Status` are vocabulary,
        /// not prose, and comparing them with the backticks attached is
        /// how a check passes vacuously against a set it never matches.
        func word(_ name: String) -> String {
            (fields[name] ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "` ."))
        }
    }

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

    /// Every `## KW-nn — …` section and its `- **Field:** value` bullets.
    ///
    /// A field's value runs to the next bullet, so a wrapped paragraph is
    /// one value; the parser keeps the whole thing rather than the first
    /// line, because a row's argument is usually longer than a line and
    /// truncating it here would make the shape check pass on half a
    /// sentence.
    private func rows() throws -> [Row] {
        let document = try read(Self.registerDoc)
        var rows: [Row] = []
        var field: String?
        for line in document.components(separatedBy: "\n") {
            if line.hasPrefix("## KW-") {
                let id = String(line.dropFirst(3).prefix(5))
                rows.append(Row(id: id, fields: [:]))
                field = nil
                continue
            }
            guard !rows.isEmpty else { continue }
            if line.hasPrefix("- **"), let close = line.range(of: ":**") {
                let name = String(
                    line[line.index(line.startIndex, offsetBy: 4)
                        ..< close.lowerBound])
                let value = String(line[close.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                rows[rows.count - 1].fields[name] = value
                field = name
            } else if let f = field, line.hasPrefix("  ") {
                rows[rows.count - 1].fields[f]? +=
                    " " + line.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") || line.hasPrefix("---") {
                field = nil
            }
        }
        return rows
    }

    /// Fails naming the row if the register no longer carries it. A code
    /// check whose row was deleted is a check with nothing to say, and it
    /// should be deleted with the row rather than left passing silently.
    private func requireRow(_ id: String) throws {
        guard try rows().contains(where: { $0.id == id }) else {
            XCTFail(
                "\(Self.registerDoc) no longer has \(id), and this test "
                    + "exists to keep that row honest. Delete the test "
                    + "with the row.")
            return
        }
    }

    /// A window built through the public decoder rather than a memberwise
    /// initialiser, so the fixture is the shape a real scene produces.
    private func window(kind: Int?, title: String) throws -> Scene.Window {
        let kindJSON = kind.map(String.init) ?? "null"
        let json = """
            {"id":"1.0/\(title)#0","app":"\(title)","psn":"1.0",
             "title":"\(title)","kind":\(kindJSON),
             "rect":{"l":100,"t":80,"r":500,"b":400},
             "front":true,"z":0,"visible":true,"controls":[]}
            """
        return try JSONDecoder().decode(
            Scene.Window.self, from: Data(json.utf8))
    }
}
