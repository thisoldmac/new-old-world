import XCTest
@testable import Host

final class ContinuityDatagramTests: XCTestCase {
    func testStateMatchesTheSharedBigEndianVector() throws {
        let packet = ContinuityStateDatagram(
            nonceHi: 0x0123_4567, nonceLo: 0x89AB_CDEF,
            epoch: 0x1020_3040, positionSequence: 7,
            h: -2, v: 342, buttonGeneration: 3,
            flags: [.inside, .primaryDown], requestedHz: 30,
            hostStamp: 0x5566_7788,
            previousButtonGeneration: 2, previousButtonDown: false)
        let data = ContinuityDatagramCodec.encode(packet)

        XCTAssertEqual(data.count, 48)
        XCTAssertEqual(Array(data.prefix(8)),
                       [0x4E, 0x57, 0x43, 0x31, 0, 4, 0, 3])
        XCTAssertEqual(Array(data[24..<28]), [0xFF, 0xFE, 0x01, 0x56])
        XCTAssertEqual(Array(data[40..<48]), [0, 0, 0, 2, 0, 0, 0, 0])
        XCTAssertEqual(try ContinuityDatagramCodec.decodeState(data), packet)
    }

    func testWithKeepaliveFlagAddsOnlyThatBitAndIsIdempotent() throws {
        let packet = ContinuityStateDatagram(
            nonceHi: 0x0123_4567, nonceLo: 0x89AB_CDEF,
            epoch: 0x1020_3040, positionSequence: 7,
            h: -2, v: 342, buttonGeneration: 3,
            flags: [.inside, .primaryDown, .carriedLevel], requestedHz: 30,
            hostStamp: 0x5566_7788,
            previousButtonGeneration: 2, previousButtonDown: true)
        let wire = ContinuityDatagramCodec.encode(packet)

        let flagged = ContinuityDatagramCodec.withKeepaliveFlag(wire)
        var expected = packet
        expected.flags.insert(.keepalive)
        XCTAssertEqual(try ContinuityDatagramCodec.decodeState(flagged),
                       expected)
        // Nothing but the flag word may move, and the source is untouched.
        XCTAssertEqual(wire, ContinuityDatagramCodec.encode(packet))
        XCTAssertEqual(ContinuityDatagramCodec.withKeepaliveFlag(flagged),
                       flagged)
        // A non-zero-based Data slice must flag the same byte.
        let shifted = (Data([0xAA, 0xBB]) + wire)[2...]
        XCTAssertEqual(ContinuityDatagramCodec.withKeepaliveFlag(shifted),
                       flagged)
    }

    func testStateRejectsUnknownBitsAndNonzeroReservedField() {
        var packet = [UInt8](ContinuityDatagramCodec.encode(
            ContinuityStateDatagram(
                nonceHi: 1, nonceLo: 2, epoch: 3, positionSequence: 4,
                h: 5, v: 6, buttonGeneration: 7, flags: .inside,
                requestedHz: 30, hostStamp: 8)))
        packet[7] = 0x80
        XCTAssertThrowsError(
            try ContinuityDatagramCodec.decodeState(Data(packet))) { error in
                XCTAssertEqual(error as? ContinuityDatagramError,
                               .reservedFlags(0x0080))
            }
        packet[7] = 1
        packet[35] = 1
        XCTAssertThrowsError(
            try ContinuityDatagramCodec.decodeState(Data(packet))) { error in
                XCTAssertEqual(error as? ContinuityDatagramError,
                               .reservedField(1))
            }
        packet[35] = 0
        packet[45] = 4
        XCTAssertThrowsError(
            try ContinuityDatagramCodec.decodeState(Data(packet))) { error in
                XCTAssertEqual(error as? ContinuityDatagramError,
                               .reservedFlags(4))
            }
    }

    func testAckRoundTripsAndCarriesAppliedGeneration() throws {
        let ack = ContinuityAckDatagram(
            nonceHi: 1, nonceLo: 2, epoch: 3, positionSequence: 4,
            buttonGeneration: 5, arrivalTicks: 100, applyTicks: 102,
            rejectedPackets: 9, state: .active, acceptedHz: 60,
            exitReason: .guestInput)
        let data = ContinuityDatagramCodec.encode(ack)
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(Array(data.prefix(4)), [0x4E, 0x57, 0x41, 0x31])
        XCTAssertEqual(try ContinuityDatagramCodec.decodeAck(data), ack)
    }

    func testDatagramsAreExactSize() {
        XCTAssertThrowsError(
            try ContinuityDatagramCodec.decodeState(Data(repeating: 0,
                                                          count: 47))) { error in
                XCTAssertEqual(error as? ContinuityDatagramError,
                               .wrongSize(expected: 48, actual: 47))
            }
    }
}
