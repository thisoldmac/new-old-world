import XCTest
@testable import Host

final class TransferIdentityTests: XCTestCase {
    /// The published check value for CRC-32/ISO-HDLC. If this drifts, the
    /// guest and the host are computing different functions and every
    /// resumed transfer fails its checksum for no visible reason.
    func testMatchesTheStandardCheckValue() {
        XCTAssertEqual(TransferIdentity.crc32(Data("123456789".utf8)),
                       0xCBF4_3926)
    }

    func testEmptyInputIsZero() {
        XCTAssertEqual(TransferIdentity.crc32(Data()), 0)
    }

    /// Streaming must equal one-shot, since the guest necessarily
    /// computes it in arrival-sized pieces and the host in one go.
    func testRunningCRCMatchesOneShotAcrossArbitrarySplits() {
        let bytes = Data((0..<5000).map { UInt8(($0 &* 31 &+ 7) & 0xFF) })
        let want = TransferIdentity.crc32(bytes)
        for split in [1, 2, 7, 1448, 4096, 4999] {
            var running = TransferIdentity.CRC32()
            var i = 0
            while i < bytes.count {
                let end = min(i + split, bytes.count)
                running.update(bytes[i..<end])
                i = end
            }
            XCTAssertEqual(running.checksum, want,
                           "split of \(split) disagrees with one-shot")
        }
    }

    /// A resumed transfer that lands the tail of one file onto the head
    /// of another is worse than starting over, so the token has to move
    /// when the content does.
    func testTokenChangesWhenAnyByteChanges() {
        var a = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let first = TransferIdentity.resumeToken(for: a)
        a[500] ^= 0x01
        XCTAssertNotEqual(TransferIdentity.resumeToken(for: a), first)
    }

    func testTokenChangesWhenLengthChanges() {
        let a = Data(repeating: 0, count: 1000)
        let b = Data(repeating: 0, count: 1001)
        XCTAssertNotEqual(TransferIdentity.resumeToken(for: a),
                          TransferIdentity.resumeToken(for: b))
    }

    /// Same bytes must give the same token in a later session, or resume
    /// never engages at all — the failure would be silent and look like
    /// "resume just doesn't work".
    func testTokenIsStableForIdenticalContent() {
        let a = Data((0..<4096).map { UInt8(($0 &* 17) & 0xFF) })
        let b = Data((0..<4096).map { UInt8(($0 &* 17) & 0xFF) })
        XCTAssertEqual(TransferIdentity.resumeToken(for: a),
                       TransferIdentity.resumeToken(for: b))
    }

    /// It carries the length, so a receiver can reject an offset past the
    /// end without having read a byte.
    func testTokenCarriesTheLength() {
        let token = TransferIdentity.resumeToken(for: Data(count: 1234))
        XCTAssertTrue(token.hasPrefix("1234-"), token)
    }
}
