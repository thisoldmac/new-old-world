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

    /// One record with the given op fields, wrapped in the v2 identity
    /// every record must carry.
    private func single(_ fields: String) throws -> QDTraceDecode.Drain {
        try XCTUnwrap(QDTraceDecode.drain(try object("""
        {"cmd":"drain","ops":[
          {"port":"0x1eba6800","ticks":1,"a5":"0x00100000","psn":"0.42",
           "displayEpoch":3,"generation":7,\(fields)}],
         "records":1,"nextCursor":64}
        """)))
    }

    /// Invert stopped being deferred when the replay gained a canvas of
    /// its own to invert against. It is the verb classic Mac OS draws
    /// selection, carets and pressed states with, so leaving it in the
    /// inventory was the mirror's standing claim that it shows every
    /// window unselected.
    func testInvertIsNoLongerDeferred() throws {
        for shape in ["rect", "rrect", "oval"] {
            let drain = try single(
                "\"op\":\"\(shape)\",\"verb\":3,\"rect\":[33,116,34,132]")
            XCTAssertTrue(drain.undrawn.isEmpty,
                          "\(shape) invert is drawn, not deferred")
        }
    }

    /// A verb outside the GrafVerb range is still nobody's drawing.
    func testUnknownVerbStaysDeferred() throws {
        let drain = try single(
            "\"op\":\"rect\",\"verb\":9,\"rect\":[0,0,4,4]")
        XCTAssertEqual(drain.undrawn, ["rect (verb 9)": 1])
    }

    // MARK: - The region shape discriminator

    /// `rgnSize == 10` is QuickDraw's rectangular Region, so the box the
    /// contract sends IS the shape and the renderer's rectangle is exact.
    func testRectangularRegionIsNotDeferredAtAll() throws {
        let drain = try single(
            "\"op\":\"rgn\",\"verb\":2,\"rect\":[0,21,389,203],\"ext\":[10,0]")
        XCTAssertTrue(drain.undrawn.isEmpty)
    }

    /// A larger record means real shape the box is hiding, and the
    /// rectangle is honestly reported as an approximation.
    func testIrregularRegionIsReportedAsBoundsOnly() throws {
        let drain = try single(
            "\"op\":\"rgn\",\"verb\":2,\"rect\":[0,0,40,40],\"ext\":[42,0]")
        XCTAssertEqual(drain.undrawn, ["rgn (bounds only)": 1])
    }

    /// THE THIRD STATE, and the reason the field is worth having: a
    /// resident older than the discriminator sends ext = 0, and that
    /// must never be read as "rectangular". Every one of the 39 region
    /// ops in the committed capture corpus is in exactly this state.
    func testRegionFromAResidentWithoutTheDiscriminatorSaysSo() throws {
        let drain = try single(
            "\"op\":\"rgn\",\"verb\":2,\"rect\":[0,0,40,40],\"ext\":[0,0]")
        XCTAssertEqual(drain.undrawn, ["rgn (shape unreported)": 1])
        let absent = try single(
            "\"op\":\"rgn\",\"verb\":2,\"rect\":[0,0,40,40]")
        XCTAssertEqual(absent.undrawn, ["rgn (shape unreported)": 1],
                       "a missing ext is the same claim as a zero one")
    }

    /// Region shape and region verb are separate questions: an
    /// unreadable verb is named as one even when the shape is known.
    func testRegionVerbOutranksItsShape() throws {
        let drain = try single(
            "\"op\":\"rgn\",\"verb\":7,\"rect\":[0,0,4,4],\"ext\":[10,0]")
        XCTAssertEqual(drain.undrawn, ["rgn (verb 7)": 1])
    }

    /// arc and poly have no renderer case at all, and the inventory
    /// must keep saying so — zero of them appear in today's corpus, and
    /// a counter that fell silent would read as coverage.
    func testArcAndPolyRemainDeferredWhole() throws {
        XCTAssertEqual(try single(
            "\"op\":\"arc\",\"verb\":1,\"rect\":[0,0,8,8],\"ext\":[0,90]")
            .undrawn, ["arc": 1])
        XCTAssertEqual(try single(
            "\"op\":\"poly\",\"verb\":1,\"rect\":[0,0,8,8],\"ext\":[24,0]")
            .undrawn, ["poly": 1])
    }

    func testRegionShapeReadsTheContractsThreeStates() {
        XCTAssertEqual(RegionShape(rgnSize: 10), .rectangular)
        XCTAssertEqual(RegionShape(rgnSize: 0), .unreported)
        XCTAssertEqual(RegionShape(rgnSize: 42), .irregular(bytes: 42))
        XCTAssertTrue(RegionShape(rgnSize: 10).boundsAreExact)
        XCTAssertFalse(RegionShape(rgnSize: 0).boundsAreExact)
        /* Below the minimum is a malformed region, never a rectangle. */
        XCTAssertEqual(RegionShape(rgnSize: 8), .unreported)
    }
}
