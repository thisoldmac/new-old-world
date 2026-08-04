import XCTest
@testable import MirrorKit

final class QDTraceDecodeTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
    }

    func testDrainKeepsExactPortAndDisplayOperation() throws {
        let value = try object("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":9,
           "a5":"0x00100000","psn":"0.42","displayEpoch":3,"generation":7,
           "pen":[14,22],"font":3,"size":9,"face":0,
           "len":8,"fullLen":8,"trunc":false,"text":"Workshop"}],
         "cursor":0,"nextCursor":64,"writeCursor":64,"pending":0,
         "records":1,"wraps":0,"more":false,"resync":false,
         "torn":false,"busy":false,"lostBytes":0,"dropped":0}
        """)

        let drain = try XCTUnwrap(QDTraceDecode.drain(value))
        XCTAssertTrue(drain.recordCountAgrees)
        XCTAssertEqual(drain.nextCursor, 64)
        XCTAssertEqual(drain.records.first?.port, "0x1eba6800")
        XCTAssertEqual(drain.records.first?.portAddress, 0x1eba6800)
        XCTAssertEqual(drain.records.first?.psn, "0.42")
        XCTAssertEqual(drain.records.first?.displayEpoch, 3)
        XCTAssertEqual(drain.records.first?.generation, 7)
        XCTAssertEqual(drain.records.first?.op.text, "Workshop")
        XCTAssertEqual(drain.records.first?.op.pen, [14, 22])
    }

    func testLinePenSizeCannotBecomeTextPenPosition() throws {
        let value = try object("""
        {"cmd":"drain","ops":[
          {"op":"line","port":"0x00001000","ticks":1,
           "a5":"0x00100000","psn":"0.42","displayEpoch":3,"generation":7,
           "from":[1,2],"to":[3,4],"pen":[2,2]}],
         "records":1,"nextCursor":32}
        """)
        let record = try XCTUnwrap(QDTraceDecode.drain(value)?.records.first)
        XCTAssertNil(record.op.pen)
        XCTAssertEqual(record.penSize, [2, 2])
    }

    func testTornDrainCannotClaimItsPartialRecordsAgree() throws {
        let value = try object("""
        {"cmd":"drain","ops":[],"records":4,"torn":true,
         "nextCursor":0}
        """)
        let drain = try XCTUnwrap(QDTraceDecode.drain(value))
        XCTAssertTrue(drain.recordCountAgrees,
                      "a torn reply deliberately retracts its partial rows")
        XCTAssertTrue(drain.records.isEmpty)
    }

    func testRecordWithoutFullV2IdentityIsRejected() throws {
        let value = try object("""
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1eba6800","ticks":1,
           "verb":0,"rect":[0,0,20,20]}],
         "records":1}
        """)
        let drain = try XCTUnwrap(QDTraceDecode.drain(value))
        XCTAssertTrue(drain.records.isEmpty)
        XCTAssertFalse(drain.recordCountAgrees)
    }

    func testStatusIsNotMisreadAsAnEmptyDrain() throws {
        XCTAssertNil(QDTraceDecode.drain(try object(
            "{\"cmd\":\"status\",\"active\":{\"mode\":\"off\"}}")))
    }

    func testImplementedBackgroundAndEraseAreNotReportedAsDeferred() throws {
        let value = try object("""
        {"cmd":"drain","ops":[
          {"op":"state","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.42","displayEpoch":3,
           "generation":7,"kind":"bg","rgb":[1,2,3]},
          {"op":"rect","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.42","displayEpoch":3,
           "generation":7,"verb":2,"rect":[0,0,20,20]}],
         "records":2,"nextCursor":64}
        """)
        let drain = try XCTUnwrap(QDTraceDecode.drain(value))
        XCTAssertTrue(drain.undrawn.isEmpty)
    }
}
