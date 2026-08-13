import XCTest
@testable import Host

final class ContinuityDatagramTests: XCTestCase {
    func testStateMatchesTheSharedBigEndianVector() throws {
        let packet = ContinuityStateDatagram(
            nonceHi: 0x0123_4567, nonceLo: 0x89AB_CDEF,
            epoch: 0x1020_3040, positionSequence: 7,
            h: -2, v: 342, buttonGeneration: 3,
            flags: [.inside, .primaryDown], requestedHz: 30,
            hostStamp: 0x5566_7788)
        let data = ContinuityDatagramCodec.encode(packet)

        XCTAssertEqual(data.count, 40)
        XCTAssertEqual(Array(data.prefix(8)),
                       [0x4E, 0x57, 0x43, 0x31, 0, 3, 0, 3])
        XCTAssertEqual(Array(data[24..<28]), [0xFF, 0xFE, 0x01, 0x56])
        XCTAssertEqual(try ContinuityDatagramCodec.decodeState(data), packet)
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
                                                          count: 39))) { error in
                XCTAssertEqual(error as? ContinuityDatagramError,
                               .wrongSize(expected: 40, actual: 39))
            }
    }
}
