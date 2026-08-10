import Foundation
import XCTest
@testable import Host

final class NDIFImageTests: XCTestCase {
    func testReadOnlyImageCarriesRawDiskAndBlockMapInBothForks() throws {
        let disk = Data((0..<1_024).map { UInt8($0 % 251) })
        let encoded = try XCTUnwrap(NDIFImage.macBinary(
            name: "NOW Setup.img", volumeName: "NOW Setup", disk: disk))
        let bytes = [UInt8](encoded)

        XCTAssertEqual(String(bytes: bytes[65..<69], encoding: .ascii),
                       "rohd")
        XCTAssertEqual(String(bytes: bytes[69..<73], encoding: .ascii),
                       "ddsk")
        XCTAssertEqual(bigEndianUInt32(bytes, at: 83), 1_024)
        let resourceLength = Int(bigEndianUInt32(bytes, at: 87))
        XCTAssertGreaterThan(resourceLength, 0)
        XCTAssertEqual(Data(bytes[128..<1_152]), disk)

        let resourceStart = 128 + padded(disk.count)
        let resourceFork = Data(bytes[resourceStart..<(resourceStart
            + resourceLength)])
        let blockMap = try XCTUnwrap(resource(named: "bcem",
                                              in: resourceFork))
        XCTAssertEqual(bigEndianUInt32([UInt8](blockMap), at: 68), 2)
        XCTAssertEqual(bigEndianUInt32([UInt8](blockMap), at: 124), 2)
        XCTAssertEqual(bigEndianUInt32([UInt8](blockMap), at: 128), 0x02)
        XCTAssertEqual(bigEndianUInt32([UInt8](blockMap), at: 132), 0)
        XCTAssertEqual(bigEndianUInt32([UInt8](blockMap), at: 136), 1_024)
        XCTAssertEqual(bigEndianUInt32([UInt8](blockMap), at: 140),
                       (2 << 8) | 0xff)
    }

    func testImageRejectsNonSectorSizedDisk() {
        XCTAssertNil(NDIFImage.macBinary(
            name: "NOW Setup.img", volumeName: "NOW Setup",
            disk: Data(repeating: 0, count: 513)))
    }

    private func resource(named type: String, in fork: Data) -> Data? {
        let bytes = [UInt8](fork)
        let dataOffset = Int(bigEndianUInt32(bytes, at: 0))
        let mapOffset = Int(bigEndianUInt32(bytes, at: 4))
        let typeList = mapOffset + Int(bigEndianUInt16(
            bytes, at: mapOffset + 24))
        let count = Int(bigEndianUInt16(bytes, at: typeList)) + 1
        for index in 0..<count {
            let entry = typeList + 2 + index * 8
            guard String(bytes: bytes[entry..<(entry + 4)],
                         encoding: .ascii) == type else { continue }
            let references = typeList
                + Int(bigEndianUInt16(bytes, at: entry + 6))
            let resourceOffset = Int(bytes[references + 5]) << 16
                | Int(bytes[references + 6]) << 8
                | Int(bytes[references + 7])
            let start = dataOffset + resourceOffset
            let length = Int(bigEndianUInt32(bytes, at: start))
            return Data(bytes[(start + 4)..<(start + 4 + length)])
        }
        return nil
    }

    private func padded(_ count: Int) -> Int {
        (count + 127) / 128 * 128
    }

    private func bigEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private func bigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
