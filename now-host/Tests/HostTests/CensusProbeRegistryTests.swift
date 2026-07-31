import Foundation
import XCTest
@testable import Host

/// The host's `CensusProbes.all` is a copy of two things it cannot import:
/// the contract's `x-census/x-probes` registry and the guest's `k_probes[]`
/// dispatch table. A copy drifts, and a probe the guest grows but the host
/// forgets is a card silently missing from the dossier - so this pins the
/// copy to both originals, the way GuestWireConformanceTests pins the guest's
/// frames to the contract.
final class CensusProbeRegistryTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // host
            .deletingLastPathComponent()   // repo
    }

    /// The keys under `x-census/x-probes` in the contract - the set of
    /// probes the wire acknowledges.
    private func contractProbeIDs() throws -> Set<String> {
        let url = Self.repoRoot.appendingPathComponent("contract/asyncapi.yaml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "x-probes:"
        }) else {
            XCTFail("no x-probes in the contract"); return []
        }
        // x-probes sits at 4 spaces; its keys at 6, their columns at 8. Read
        // the 6-space keys until the block dedents back to <= 4.
        var ids = Set<String>()
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent <= 4 { break }
            if indent == 6, let colon = line.firstIndex(of: ":") {
                ids.insert(String(line[line.index(line.startIndex, offsetBy: 6)..<colon]))
            }
        }
        return ids
    }

    /// The `k_probes[]` names in the guest, in their dispatch order - which
    /// is the rail's display order, which the host mirrors.
    private func guestProbeOrder() throws -> [String] {
        let text = try GateSource.guestC(
            "now-guest-ppc/src/census/census_probes.c")
        guard let braceRange = text.range(of: "k_probes[] = {") else {
            XCTFail("no k_probes table in census_probes.c"); return []
        }
        let tail = text[braceRange.upperBound...]
        guard let end = tail.range(of: "};") else {
            XCTFail("k_probes table not terminated"); return []
        }
        let body = tail[..<end.lowerBound]
        // Each entry: { "name", gather_name },
        var order: [String] = []
        var i = body.startIndex
        while let open = body[i...].firstIndex(of: "\"") {
            guard let close = body[body.index(after: open)...].firstIndex(of: "\"")
            else { break }
            order.append(String(body[body.index(after: open)..<close]))
            i = body.index(after: close)
        }
        return order
    }

    func testHostProbeSetMatchesTheContract() throws {
        let host = Set(CensusProbes.all.map(\.id))
        let contract = try contractProbeIDs()
        XCTAssertEqual(host, contract,
            "host probe set drifted from the contract's x-probes; "
            + "missing here: \(contract.subtracting(host)); "
            + "extra here: \(host.subtracting(contract))")
    }

    func testHostProbeOrderMatchesTheGuestRail() throws {
        let host = CensusProbes.all.map(\.id)
        let guest = try guestProbeOrder()
        XCTAssertEqual(host, guest,
            "host probe order drifted from the guest's k_probes rail order")
    }

    /// The `k_probes68[]` names in NOW-68K, read the same way.
    private func guest68KProbeOrder() throws -> [String] {
        let text = try GateSource.guestC(
            "now-guest-68k/src/census/census68.c")
        guard let braceRange = text.range(of: "k_probes68[] = {") else {
            XCTFail("no k_probes68 table in census68.c"); return []
        }
        let tail = text[braceRange.upperBound...]
        guard let end = tail.range(of: "};") else {
            XCTFail("k_probes68 table not terminated"); return []
        }
        var order: [String] = []
        var i = tail[..<end.lowerBound].startIndex
        let body = tail[..<end.lowerBound]
        while let open = body[i...].firstIndex(of: "\"") {
            guard let close = body[body.index(after: open)...].firstIndex(of: "\"")
            else { break }
            order.append(String(body[body.index(after: open)..<close]))
            i = body.index(after: close)
        }
        return order
    }

    /// NOW-68K must not invent a probe, and must not miss one.
    ///
    /// Inventing is the obvious half: a name outside `x-census` is a probe
    /// a host can only learn about by accident, the census twin of
    /// `testNeitherGuestInventsCommandsTheContractDoesNotDeclare`.
    ///
    /// MISSING is the half worth the test. A declared probe absent from
    /// this table falls through to "unknown probe", which tells a caller
    /// the REGISTRY does not have it — a different and false statement
    /// from "this machine does not". NOW-68K answers all fourteen for
    /// exactly that reason, several with outcome `absent` (no PCI, no PC
    /// Card, no ATA bus on a 68030 PowerBook) and two with `refused` and a
    /// note. Those two words are not interchangeable, and this test is
    /// what keeps a future edit from closing the gap by deleting a row.
    func testTheSixtyEightKProbeSetIsExactlyTheContractRegistry() throws {
        let guest = try guest68KProbeOrder()
        let contract = try contractProbeIDs()
        XCTAssertEqual(Set(guest), contract, """
            NOW-68K's k_probes68 drifted from the contract's x-census: \
            missing there: \(contract.subtracting(Set(guest)).sorted()); \
            extra there: \(Set(guest).subtracting(contract).sorted()). A \
            declared probe this guest does not list answers "unknown \
            probe", which says the registry lacks it rather than that the \
            machine does.
            """)
    }

    /// Both guests present the same probes in the same order, so a host
    /// drawing a PowerBook 1400c and a PowerBook 180c draws one rail
    /// rather than two that happen to overlap.
    func testBothGuestsOrderTheirProbesTheSameWay() throws {
        XCTAssertEqual(try guest68KProbeOrder(), try guestProbeOrder(),
                       "the two guests' probe rails are in different orders")
    }

    /// Every row in both tables gathers the probe it is NAMED after.
    ///
    /// Found by mutation on 2026-07-31, and it is the hole every check above
    /// shares: they read the quoted names and never the function beside
    /// them. Swap two gathers —
    ///
    ///     { "pci",       gather_scsi },
    ///     { "scsi",      gather_pci },
    ///
    /// — and both guests compile, the native suite passes, and all four
    /// checks above agree the rails match the contract, while every machine
    /// reports its SCSI bus under PCI and its PCI bus under SCSI. Nothing
    /// downstream can catch it either: a dossier of plausible values in the
    /// wrong cards is exactly as well-formed as the right answer.
    ///
    /// (The simpler mutation — pointing one row at another's gather and
    /// leaving the displaced one unused — is caught, but by the compiler's
    /// `-Werror=unused-function`, not by anything here. A swap keeps both
    /// used and walks straight through.)
    ///
    /// This is a naming convention, not a proof: it cannot tell whether
    /// `gather_pci` reads PCI. What it does is make a mismatched pair
    /// impossible to write silently, which is what happened above.
    func testEveryProbeRowGathersTheProbeItNames() throws {
        for (file, table) in [
            ("now-guest-ppc/src/census/census_probes.c", "k_probes[] = {"),
            ("now-guest-68k/src/census/census68.c", "k_probes68[] = {"),
        ] {
            let text = try GateSource.guestC(file)
            guard let open = text.range(of: table),
                  let end = text.range(of: "};", range: open.upperBound
                                        ..< text.endIndex) else {
                XCTFail("no \(table) table in \(file)")
                continue
            }
            let body = String(text[open.upperBound..<end.lowerBound])
            let re = try NSRegularExpression(
                pattern: #"\{\s*"([a-z0-9]+)"\s*,\s*([A-Za-z0-9_]+)\s*\}"#)
            let ns = body as NSString
            let rows = re.matches(
                in: body, range: NSRange(location: 0, length: ns.length))
            XCTAssertFalse(
                rows.isEmpty,
                "\(file)'s \(table) no longer reads as "
                    + "`{ \"name\", gather_name }` rows, so this check and "
                    + "the three above it are reading nothing.")
            for row in rows {
                let name = ns.substring(with: row.range(at: 1))
                let gather = ns.substring(with: row.range(at: 2))
                XCTAssertEqual(
                    gather, "gather_\(name)", """
                    \(file): the probe named "\(name)" is gathered by \
                    \(gather). Every other check on this table reads the \
                    NAME and never the function beside it, so a mismatched \
                    pair reports one card's hardware under another's — \
                    well-formed, plausible, and wrong. If the pairing is \
                    deliberate, the row needs a different name.
                    """)
            }
        }
    }

    func testEveryProbeHasThreeColumnTitles() {
        for probe in CensusProbes.all {
            XCTAssertEqual(probe.columns.count, 3,
                "\(probe.id): a census row is [name, raw, meaning] - three "
                + "column titles, leading label plus Raw and Meaning")
        }
    }
}
