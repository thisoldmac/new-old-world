import XCTest
@testable import Host

final class OnboardingPreferencesTests: XCTestCase {
    func testMinimalPreferencesMatchTheGuestV1RecordAndMacBinaryContract()
        throws {
        let data = try XCTUnwrap(OnboardingPreferences.macBinary(
            host: "192.168.1.44", port: 5_250))
        let bytes = [UInt8](data)

        XCTAssertEqual(bytes.count, 256,
                       "72 data bytes are padded to a MacBinary block")
        XCTAssertEqual(bytes[1], 19)
        XCTAssertEqual(String(bytes: bytes[2..<21], encoding: .macOSRoman),
                       "New Old World Prefs")
        XCTAssertEqual(String(bytes: bytes[65..<69], encoding: .ascii),
                       "pref")
        XCTAssertEqual(String(bytes: bytes[69..<73], encoding: .ascii),
                       "NOWo")
        XCTAssertEqual(uint32(bytes, at: 83), 72)
        XCTAssertEqual(bytes[122], 129)
        XCTAssertEqual(bytes[123], 129)
        XCTAssertEqual(uint16(bytes, at: 124), crc16(bytes[0..<124]))

        XCTAssertEqual(String(bytes: bytes[128..<132], encoding: .ascii),
                       "NOWp")
        XCTAssertEqual(uint16(bytes, at: 132), 1)
        XCTAssertEqual(uint16(bytes, at: 134), 5_250)
        XCTAssertEqual(String(
            bytes: bytes[136..<200].prefix(while: { $0 != 0 }),
            encoding: .ascii), "192.168.1.44")
    }

    func testPreferencesRefuseAHostThatCannotFitTheGuestRecord() {
        XCTAssertNil(OnboardingPreferences.macBinary(
            host: String(repeating: "1", count: 64), port: 5_250))
        XCTAssertNil(OnboardingPreferences.macBinary(
            host: "classic-mac.local", port: 5_250),
            "the guest's v1 contract is a dotted-quad ASCII field")
    }

    private func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0
                    ? (crc << 1) ^ 0x1021
                    : crc << 1
            }
        }
        return crc
    }
}
