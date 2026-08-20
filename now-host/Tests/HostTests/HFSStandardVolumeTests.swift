import Foundation
import XCTest
@testable import Host

/// The oracle is hfsutils - an independent HFS Standard implementation -
/// so this codec never grades its own homework. Without NOW_HFSUTILS the
/// suite skips visibly, the same rule as the Retro68 gates: a desk
/// without the tool is not failing a check it cannot run.
final class HFSStandardVolumeTests: XCTestCase {
    func testOracleReadsBackNamesForksAndFinderInfo() throws {
        let tools = try HFSOracle.tools()
        let dataFork = Data((0..<21_000).map { UInt8($0 % 251) })
        let resourceFork = Data((0..<250_000).map { UInt8($0 % 253) })
        let readMe = Data("Type the host into Host.\r".utf8)
        let files = [
            HFSStandardVolume.File(
                name: "NOW-68K", type: "APPL", creator: "NOWo",
                finderFlags: 0, dataFork: dataFork,
                resourceFork: resourceFork),
            HFSStandardVolume.File(
                name: "Read Me First", type: "TEXT", creator: "ttxt",
                finderFlags: 0, dataFork: readMe, resourceFork: Data()),
        ]
        let capacity = try XCTUnwrap(
            HFSStandardVolume.fittingCapacity(for: files))
        let disk = try XCTUnwrap(HFSStandardVolume.build(
            volumeName: "NOW Setup", files: files, capacity: capacity))
        XCTAssertEqual(disk.count, 800 * 1_024,
                       "this payload fits the 800K size")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let image = temporary.appendingPathComponent("volume.hfs")
        try disk.write(to: image)

        // The oracle mounts it...
        try HFSOracle.run(tools + "/hmount", [image.path], home: temporary)
        defer { _ = try? HFSOracle.run(tools + "/humount", [], home: temporary) }
        let listing = try HFSOracle.run(tools + "/hls", ["-la", ":"], home: temporary)
        let text = try XCTUnwrap(String(data: listing, encoding: .utf8))
        XCTAssertTrue(text.contains("NOW-68K"), text)
        XCTAssertTrue(text.contains("Read Me First"), text)
        XCTAssertTrue(text.contains("APPL"), text)
        XCTAssertTrue(text.contains("NOWo"), text)

        // ...and hands back byte-identical forks through MacBinary.
        let extracted = temporary.appendingPathComponent("out.bin")
        try HFSOracle.run(tools + "/hcopy", ["-m", ":NOW-68K", extracted.path],
                home: temporary)
        let roundTrip = try MacBinaryFile.decode(
            Data(contentsOf: extracted))
        XCTAssertEqual(roundTrip.name, "NOW-68K")
        XCTAssertEqual(roundTrip.type, "APPL")
        XCTAssertEqual(roundTrip.creator, "NOWo")
        XCTAssertEqual(roundTrip.dataFork, dataFork)
        XCTAssertEqual(roundTrip.resourceFork, resourceFork)
    }

    func testDiskCopy42WrapsTheVolumeWithItsChecksum() throws {
        let files = [HFSStandardVolume.File(
            name: "NOW-68K", type: "APPL", creator: "NOWo",
            finderFlags: 0, dataFork: Data([1, 2, 3]),
            resourceFork: Data(repeating: 9, count: 4_000))]
        let disk = try XCTUnwrap(HFSStandardVolume.build(
            volumeName: "NOW Setup", files: files, capacity: .floppy800K))
        let image = try XCTUnwrap(DiskCopy42Image.data(
            name: "NOW-68K Setup.img", disk: disk))
        XCTAssertEqual(image.count, 84 + disk.count)
        XCTAssertEqual(Int(image[0]), "NOW-68K Setup.img".count)
        // data size field
        let size = image[64..<68].reduce(0) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(size, UInt32(disk.count))
        // magic
        XCTAssertEqual(image[82], 0x01)
        XCTAssertEqual(image[83], 0x00)
        // the checksum in the header matches an independent recompute
        let stored = image[72..<76].reduce(0) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(stored, DiskCopy42Image.checksum(disk))
    }

    func testTooLargePayloadIsRefusedNotTruncated() {
        let files = [HFSStandardVolume.File(
            name: "big", type: "APPL", creator: "NOWo",
            finderFlags: 0,
            dataFork: Data(count: 2 * 1_024 * 1_024),
            resourceFork: Data())]
        XCTAssertNil(HFSStandardVolume.fittingCapacity(for: files))
        XCTAssertNil(HFSStandardVolume.build(
            volumeName: "NOW Setup", files: files, capacity: .floppy1440K))
    }

    /// The oracle above is order-blind - hfsutils tolerates an unsorted
    /// leaf, the real File Manager does not - so the catalog's record
    /// order is asserted structurally, against an order computed by a
    /// SECOND independent implementation (machfs 1.3's catalog sort,
    /// evaluated offline for these names; space sorts before hyphen in
    /// Apple's table, which ASCII would get wrong).
    func testCatalogLeafKeepsAppleSortOrder() throws {
        let names = ["NOW-68K", "NOW Extension", "Read Me First",
                     "New Old World Prefs"]
        let files = names.map {
            HFSStandardVolume.File(
                name: $0, type: "TEXT", creator: "ttxt", finderFlags: 0,
                dataFork: Data([1]), resourceFork: Data())
        }
        let disk = try XCTUnwrap(HFSStandardVolume.build(
            volumeName: "NOW Setup", files: files, capacity: .floppy800K))

        // Walk the leaf chain the way a reader does: catalog node n is
        // sector 5+n (alloc blocks start at sector 4, catalog at block 1);
        // the header record names the first and last leaf, ndFLink links
        // them. Records are key(1+keyLen, even-padded)+data; the first two
        // on the chain are the root and its thread.
        func node(_ number: Int) -> Data {
            disk.subdata(in: (5 + number) * 512..<((6 + number) * 512))
        }
        let header = node(0)
        let firstLeaf = Int(header[14 + 10]) << 24
            | Int(header[14 + 11]) << 16
            | Int(header[14 + 12]) << 8 | Int(header[14 + 13])
        var found: [String] = []
        var current = firstLeaf
        while current != 0 {
            let leaf = node(current)
            let recordCount = Int(leaf[10]) << 8 | Int(leaf[11])
            for index in 0..<recordCount {
                let position = leaf.count - 2 * (index + 1)
                let offset = Int(leaf[position]) << 8
                    | Int(leaf[position + 1])
                let nameLength = Int(leaf[offset + 6])
                guard nameLength > 0 else { continue }  // the thread key
                let nameBytes = leaf.subdata(
                    in: (offset + 7)..<(offset + 7 + nameLength))
                found.append(String(data: nameBytes,
                                    encoding: .macOSRoman) ?? "?")
            }
            current = Int(leaf[0]) << 24 | Int(leaf[1]) << 16
                | Int(leaf[2]) << 8 | Int(leaf[3])
        }
        // The root record's key carries the volume name; drop it.
        XCTAssertEqual(found, ["NOW Setup", "New Old World Prefs",
                               "NOW Extension", "NOW-68K",
                               "Read Me First"])
    }

}
