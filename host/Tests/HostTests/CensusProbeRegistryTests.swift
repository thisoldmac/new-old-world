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
        let url = Self.repoRoot
            .appendingPathComponent("guest/src/census_probes.c")
        let text = try String(contentsOf: url, encoding: .utf8)
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

    func testEveryProbeHasThreeColumnTitles() {
        for probe in CensusProbes.all {
            XCTAssertEqual(probe.columns.count, 3,
                "\(probe.id): a census row is [name, raw, meaning] - three "
                + "column titles, leading label plus Raw and Meaning")
        }
    }
}
