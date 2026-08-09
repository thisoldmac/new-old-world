import Foundation
import XCTest
@testable import Host

final class MacBinaryEncoderTests: XCTestCase {
    func testEnvelopePreservesFinderMetadataAndBothForks() throws {
        let dataFork = Data([0x44, 0x41, 0x54, 0x41, 0x21])
        let resourceFork = Data([0x52, 0x53, 0x52, 0x43])

        let encoded = try XCTUnwrap(MacBinaryEncoder.data(
            name: "Classic Package", type: "SIT5", creator: "SIT!",
            dataFork: dataFork, resourceFork: resourceFork))
        let bytes = [UInt8](encoded)

        XCTAssertEqual(bytes[1], 15)
        XCTAssertEqual(String(bytes: bytes[2..<17], encoding: .macOSRoman),
                       "Classic Package")
        XCTAssertEqual(String(bytes: bytes[65..<69], encoding: .ascii),
                       "SIT5")
        XCTAssertEqual(String(bytes: bytes[69..<73], encoding: .ascii),
                       "SIT!")
        XCTAssertEqual(bigEndianUInt32(bytes, at: 83), 5)
        XCTAssertEqual(bigEndianUInt32(bytes, at: 87), 4)
        XCTAssertEqual(Data(bytes[128..<133]), dataFork)
        XCTAssertEqual(Data(bytes[256..<260]), resourceFork)
        XCTAssertEqual(bytes.count, 384,
                       "each fork occupies its own 128-byte-padded region")
    }

    private func bigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
