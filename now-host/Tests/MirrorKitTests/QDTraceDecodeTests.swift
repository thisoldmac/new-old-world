import XCTest
@testable import MirrorKit

/// **The decoder against the guest's own printf templates.**
///
/// Every JSON literal below is transcribed BY HAND from
/// `now-guest-ppc/src/content/qdtrace_json.c` — from the `snprintf` format
/// strings in `drain_sink()` and `now_qdtrace_drain_json()`, filled with
/// values chosen here. That is the point of the suite: the expectation comes
/// from a different artifact than the thing under test, so a decoder that
/// invents a key name cannot also invent the fixture that proves it right.
/// Where a literal is quoted, the file and the format it came from is named
/// beside it.
///
/// **Nothing here has run on a Macintosh, and neither has the emitter these
/// literals imitate.** `qdtrace.h` says so in its own header: upstream shipped
/// a count-only M0 and the record path has executed nowhere. So this suite
/// proves the two vocabularies agree *as written*; it proves nothing about
/// what a real ring contains. When a drain is finally watched on a machine,
/// the first thing to check is whether these literals were right.
final class QDTraceDecodeTests: XCTestCase {

    // MARK: - the templates, transcribed

    /// `drain_sink()` head, `qdtrace_json.c:271`:
    ///   `"%s{\"op\":\"%s\",\"port\":\"0x%08lx\",\"ticks\":%lu"`
    private func head(_ op: String, _ port: String, _ ticks: Int) -> String {
        "{\"op\":\"\(op)\",\"port\":\"\(port)\",\"ticks\":\(ticks)"
    }

    /// `now_qdtrace_drain_json()` tail, `qdtrace_json.c:457`.
    private func envelope(ops: [String], cursor: Int = 0, nextCursor: Int = 0,
                          writeCursor: Int = 0, pending: Int = 0,
                          records: Int? = nil, wraps: Int = 0,
                          more: Bool = false, resync: Bool = false,
                          torn: Bool = false, busy: Bool = false,
                          lostBytes: Int = 0, dropped: Int = 0) -> String {
        let n = records ?? ops.count
        return "{\"type\":\"command.result\",\"id\":7,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"drain\",\"ops\":["
            + ops.joined(separator: ",")
            + "],\"cursor\":\(cursor),\"nextCursor\":\(nextCursor),"
            + "\"writeCursor\":\(writeCursor),\"pending\":\(pending),"
            + "\"records\":\(n),\"wraps\":\(wraps),"
            + "\"more\":\(more),\"resync\":\(resync),\"torn\":\(torn),"
            + "\"busy\":\(busy),\"lostBytes\":\(lostBytes),"
            + "\"dropped\":\(dropped)}}}"
    }

    /// Pull `output.qdtrace` out of a whole `command.result`, the way a host
    /// reading a real reply must.
    private func qdtrace(_ json: String) throws -> [String: Any] {
        let any = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let root = try XCTUnwrap(any as? [String: Any])
        let output = try XCTUnwrap(root["output"] as? [String: Any])
        return try XCTUnwrap(output["qdtrace"] as? [String: Any])
    }

    private func drain(_ json: String) throws -> QDTraceDecode.Drain {
        try XCTUnwrap(QDTraceDecode.drain(try qdtrace(json)))
    }

    // MARK: - one op of every family

    /// `,"pen":[%d,%d],"font":%u,"size":%u,"face":%u,"len":%u,`
    /// `"fullLen":%u,"trunc":%s,"text":"%s"}` — `qdtrace_json.c:295`.
    func testTextRecord() throws {
        let json = envelope(ops: [
            head("text", "0x0032f4a0", 91234)
                + ",\"pen\":[12,40],\"font\":3,\"size\":9,\"face\":0,"
                + "\"len\":5,\"fullLen\":5,\"trunc\":false,\"text\":\"Hello\"}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.records.count, 1)
        let record = try XCTUnwrap(d.records.first)
        XCTAssertEqual(record.port, "0x0032f4a0")
        XCTAssertEqual(record.op.op, "text")
        XCTAssertEqual(record.op.ticks, 91234)
        XCTAssertEqual(record.op.text, "Hello")
        // For TEXT the guest's `pen` is the pen LOCATION, and it survives.
        XCTAssertEqual(record.op.pen, [12, 40])
        XCTAssertNil(record.penSize)
        XCTAssertEqual(record.op.font, 3)
        XCTAssertEqual(record.op.size, 9)
        XCTAssertEqual(record.op.face, 0)
        XCTAssertFalse(record.detailless)
        XCTAssertEqual(d.truncatedText, 0)
        XCTAssertTrue(d.undrawn.isEmpty)
        XCTAssertTrue(d.recordCountAgrees)
    }

    /// The truncation flag is counted, not discarded — a short label on
    /// screen is attributable rather than mysterious.
    func testTruncatedTextIsCounted() throws {
        let json = envelope(ops: [
            head("text", "0x0032f4a0", 91240)
                + ",\"pen\":[12,52],\"font\":3,\"size\":9,\"face\":0,"
                + "\"len\":64,\"fullLen\":300,\"trunc\":true,\"text\":\"aaa\"}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.truncatedText, 1)
        XCTAssertEqual(d.records.first?.op.text, "aaa")
    }

    /// `,"from":[%d,%d],"to":[%d,%d],"pen":[%d,%d]}` — `qdtrace_json.c:309`.
    ///
    /// **The collision this decoder exists to keep straight.** That third
    /// pair is `NowContentLinePayload.pn_h/pn_v` — a pen SIZE
    /// (`contract/content_table.h:251`) — and `DisplayOp.pen` is documented
    /// and used as a position. It must not land there.
    func testLinePenIsASizeAndNotAPosition() throws {
        let json = envelope(ops: [
            head("line", "0x0032f4a0", 91250)
                + ",\"from\":[0,0],\"to\":[100,0],\"pen\":[1,1]}"
        ])
        let d = try drain(json)
        let record = try XCTUnwrap(d.records.first)
        XCTAssertEqual(record.op.from, [0, 0])
        XCTAssertEqual(record.op.to, [100, 0])
        XCTAssertNil(record.op.pen, "a line's pen is a size; it must not sit "
                     + "in the field DisplayReplay reads as a text baseline")
        XCTAssertEqual(record.penSize, [1, 1])
    }

    /// `,"verb":%u,"rect":[%d,%d,%d,%d],"ext":[%d,%d]}` —
    /// `qdtrace_json.c:323`, shared by rect/rrect/oval/arc/poly/rgn.
    func testShapeRecords() throws {
        let json = envelope(ops: [
            head("rect", "0x0032f4a0", 91260)
                + ",\"verb\":0,\"rect\":[4,4,200,120],\"ext\":[0,0]}",
            head("rrect", "0x0032f4a0", 91261)
                + ",\"verb\":1,\"rect\":[8,8,60,30],\"ext\":[16,16]}",
            head("oval", "0x0032f4a0", 91262)
                + ",\"verb\":4,\"rect\":[10,10,40,40],\"ext\":[0,0]}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.records.map(\.op.op), ["rect", "rrect", "oval"])
        XCTAssertEqual(d.records.map { $0.op.verb }, [0, 1, 4])
        XCTAssertEqual(d.records[0].op.rect, [4, 4, 200, 120])
        XCTAssertEqual(d.records[1].op.ext, [16, 16])
        // frame / paint / fill — all three are drawn, so none are counted.
        XCTAssertTrue(d.undrawn.isEmpty)
    }

    /// The families the replay carries but does not draw, named with counts
    /// rather than vanishing. `poly` and `rgn` reuse the rect payload with
    /// the bounding box in `rect` (`content_table.h:254`).
    func testUndrawnFamiliesAreNamed() throws {
        let json = envelope(ops: [
            head("arc", "0x0032f4a0", 1)
                + ",\"verb\":0,\"rect\":[0,0,10,10],\"ext\":[0,90]}",
            head("poly", "0x0032f4a0", 2)
                + ",\"verb\":1,\"rect\":[0,0,10,10],\"ext\":[0,0]}",
            head("rgn", "0x0032f4a0", 3)
                + ",\"verb\":1,\"rect\":[0,0,10,10],\"ext\":[0,0]}",
            // erase and invert reach the renderer and are skipped there.
            head("rect", "0x0032f4a0", 4)
                + ",\"verb\":2,\"rect\":[0,0,10,10],\"ext\":[0,0]}",
            head("rect", "0x0032f4a0", 5)
                + ",\"verb\":3,\"rect\":[0,0,10,10],\"ext\":[0,0]}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.records.count, 5, "an undrawn op is still carried")
        XCTAssertEqual(d.undrawn["arc"], 1)
        XCTAssertEqual(d.undrawn["poly"], 1)
        XCTAssertEqual(d.undrawn["rgn"], 1)
        XCTAssertEqual(d.undrawn["rect (erase)"], 1)
        XCTAssertEqual(d.undrawn["rect (invert)"], 1)
    }

    /// `,"src":[…],"dst":[…],"mode":%u,"srcRowBytes":%u}` —
    /// `qdtrace_json.c:335`. Geometry only, never pixels: the absence of any
    /// byte field is the contract's rule made visible.
    func testBitsRecordCarriesGeometryOnly() throws {
        let json = envelope(ops: [
            head("bits", "0x0032f4a0", 91270)
                + ",\"src\":[0,0,32,32],\"dst\":[16,16,48,48],"
                + "\"mode\":0,\"srcRowBytes\":4}"
        ])
        let d = try drain(json)
        let record = try XCTUnwrap(d.records.first)
        XCTAssertEqual(record.op.src, [0, 0, 32, 32])
        XCTAssertEqual(record.op.dst, [16, 16, 48, 48])
        // `bits` is decoded and carried; the replay does not draw it yet.
        XCTAssertEqual(d.undrawn["bits"], 1)
    }

    /// The three state shapes, which are three different emit calls in the
    /// guest — `qdtrace_json.c:349` (clip), `:356` (origin), `:365` (rgb).
    func testStateRecords() throws {
        let json = envelope(ops: [
            head("state", "0x0032f4a0", 10)
                + ",\"kind\":\"clip\",\"rect\":[0,0,300,200]}",
            head("state", "0x0032f4a0", 11)
                + ",\"kind\":\"origin\",\"origin\":[0,64]}",
            head("state", "0x0032f4a0", 12)
                + ",\"kind\":\"fg\",\"rgb\":[0,0,0]}",
            head("state", "0x0032f4a0", 13)
                + ",\"kind\":\"bg\",\"rgb\":[65535,65535,65535]}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.records.map { $0.op.kind },
                       ["clip", "origin", "fg", "bg"])
        XCTAssertEqual(d.records[0].op.rect, [0, 0, 300, 200])
        XCTAssertEqual(d.records[1].op.origin, [0, 64])
        // RGBColor components are unsigned 16-bit; the guest prints them
        // unsigned for exactly this reason and 65535 must survive.
        XCTAssertEqual(d.records[3].op.rgb, [65535, 65535, 65535])
        // The replay applies origin and fg; clip and bg it does not.
        XCTAssertEqual(d.undrawn["state/clip"], 1)
        XCTAssertEqual(d.undrawn["state/bg"], 1)
        XCTAssertNil(d.undrawn["state/origin"])
        XCTAssertNil(d.undrawn["state/fg"])
    }

    /// `,"detail":false}` — `qdtrace_json.c:283` and `:376`. The record is
    /// kept and counted: a record silently reduced to a header is a drawing
    /// operation the host will think it saw in full.
    func testDetaillessRecordIsKeptAndCounted() throws {
        let json = envelope(ops: [
            head("comment", "0x0032f4a0", 91280) + ",\"detail\":false}",
            head("text", "0x0032f4a0", 91281) + ",\"detail\":false}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.records.count, 2)
        XCTAssertTrue(d.records.allSatisfy(\.detailless))
        XCTAssertEqual(d.detailless, 2)
        XCTAssertNil(d.records[1].op.pen, "no detail means no geometry")
        XCTAssertEqual(d.undrawn["text (no detail)"], 1)
        XCTAssertEqual(d.undrawn["comment (no detail)"], 1)
    }

    /// `op_name()`'s `default:` arm — a family a newer writer emits. It
    /// crosses as itself rather than being dropped.
    func testUnknownOpCrossesNamed() throws {
        let json = envelope(ops: [
            head("unknown", "0x0032f4a0", 5) + ",\"detail\":false}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.records.first?.op.op, "unknown")
        XCTAssertEqual(d.undrawn["unknown (no detail)"], 1)
    }

    // MARK: - the tail, and the four ways a drain ends short

    func testCursorAccountingCrosses() throws {
        let json = envelope(ops: [], cursor: 4096, nextCursor: 8192,
                            writeCursor: 65536, pending: 57344, records: 0,
                            wraps: 2, dropped: 11)
        let d = try drain(json)
        XCTAssertEqual(d.cursor, 4096)
        XCTAssertEqual(d.nextCursor, 8192)
        XCTAssertEqual(d.writeCursor, 65536)
        XCTAssertEqual(d.pending, 57344)
        XCTAssertEqual(d.wraps, 2)
        XCTAssertEqual(d.dropped, 11)
        XCTAssertTrue(d.records.isEmpty)
    }

    /// The four are four, and none of them stands in for another. This is
    /// the property the guest emitter's header argues for at length and it
    /// would be undone here by one `||`.
    func testTheFourShortnessesStayApart() throws {
        let more = try drain(envelope(ops: [], more: true))
        XCTAssertTrue(more.more)
        XCTAssertFalse(more.resync || more.torn || more.busy)

        let resync = try drain(envelope(ops: [], resync: true,
                                        lostBytes: 12288))
        XCTAssertTrue(resync.resync)
        XCTAssertEqual(resync.lostBytes, 12288)
        XCTAssertFalse(resync.more || resync.torn || resync.busy)

        let torn = try drain(envelope(ops: [], records: 3, torn: true))
        XCTAssertTrue(torn.torn)
        XCTAssertTrue(torn.records.isEmpty,
                      "a torn drain delivers nothing; the guest retracts it")

        let busy = try drain(envelope(ops: [], records: 0, busy: true))
        XCTAssertTrue(busy.busy)
    }

    /// `lostBytes` and `dropped` are two different losses with two different
    /// causes, and the guest's header says they are never summed. Nor here.
    func testLostBytesAndDroppedAreNotMerged() throws {
        let d = try drain(envelope(ops: [], resync: true, lostBytes: 4096,
                                   dropped: 9))
        XCTAssertEqual(d.lostBytes, 4096)
        XCTAssertEqual(d.dropped, 9)
    }

    /// A `records` count this side cannot match is a defect in the decoder,
    /// not a report about the Mac, and it must be visible as one.
    func testRecordCountDisagreementIsVisible() throws {
        let honest = try drain(envelope(ops: [
            head("rect", "0x1", 1) + ",\"verb\":0,\"rect\":[0,0,1,1],"
                + "\"ext\":[0,0]}"
        ]))
        XCTAssertTrue(honest.recordCountAgrees)

        let mismatch = try drain(envelope(ops: [
            head("rect", "0x1", 1) + ",\"verb\":0,\"rect\":[0,0,1,1],"
                + "\"ext\":[0,0]}"
        ], records: 4))
        XCTAssertFalse(mismatch.recordCountAgrees)
    }

    // MARK: - the join key

    /// `port` is the record header's `CGrafPtr` and the only thing in the
    /// stream that says whose ops these are. It is kept as the guest's own
    /// string — an opaque identity, compared and never arithmetic'd.
    func testPortsAreDistinctInFirstSeenOrder() throws {
        let json = envelope(ops: [
            head("rect", "0x0032f4a0", 1) + ",\"verb\":0,"
                + "\"rect\":[0,0,10,10],\"ext\":[0,0]}",
            head("rect", "0x00330b18", 2) + ",\"verb\":0,"
                + "\"rect\":[0,0,20,20],\"ext\":[0,0]}",
            head("rect", "0x0032f4a0", 3) + ",\"verb\":1,"
                + "\"rect\":[0,0,30,30],\"ext\":[0,0]}"
        ])
        let d = try drain(json)
        XCTAssertEqual(d.ports, ["0x0032f4a0", "0x00330b18"])
        XCTAssertEqual(d.ops(port: "0x0032f4a0").count, 2)
        XCTAssertEqual(d.ops(port: "0x00330b18").count, 1)
        XCTAssertEqual(d.ops(port: "0x0032f4a0").map(\.ticks), [1, 3],
                       "wire order within a port is the paint order")
    }

    // MARK: - what is not a drain

    /// `status` answers under the same `output.qdtrace` key and is not a
    /// drain. Nil rather than an empty drain: "the guest answered a
    /// different question" and "the guest drained nothing" are different
    /// answers and only the second is a fact about the screen.
    func testStatusReplyIsNotADrain() throws {
        // `now_qdtrace_status_json()`, `qdtrace_json.c:190` — the head of it.
        let json = "{\"type\":\"command.result\",\"id\":3,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"status\","
            + "\"plane\":{\"format\":1,\"length\":65676,\"ringCap\":65536}}}}"
        XCTAssertNil(QDTraceDecode.drain(try qdtrace(json)))
    }

    func testObjectWithoutCmdIsNotADrain() {
        XCTAssertNil(QDTraceDecode.drain(["ops": []]))
    }

    /// A record with no `port` cannot be joined to anything and a record
    /// with no `op` did not say what happened. Neither is counted — counting
    /// them would be counting this decoder's own confusion.
    func testRecordsWithoutOpOrPortAreNotCounted() throws {
        let json = envelope(ops: [
            "{\"port\":\"0x1\",\"ticks\":1}",
            "{\"op\":\"rect\",\"ticks\":2}",
            head("rect", "0x1", 3) + ",\"verb\":0,\"rect\":[0,0,1,1],"
                + "\"ext\":[0,0]}"
        ], records: 1)
        let d = try drain(json)
        XCTAssertEqual(d.records.count, 1)
        XCTAssertEqual(d.records.first?.port, "0x1")
    }
}
