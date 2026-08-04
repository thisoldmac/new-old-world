import XCTest
import MirrorKit
@testable import Host

@MainActor
final class NOWMirrorContentPlaneTests: XCTestCase {
    private func plane() -> NOWMirrorContentPlane {
        NOWMirrorContentPlane(listener: GuestListener(
            identity: .init(version: "test", name: "Test Host")))
    }

    private func scene(address: UInt32 = 0x1eba6800) throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "now-scene-ir-v1", withExtension: "json",
            subdirectory: "Fixtures"))
        var value = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: url))
        XCTAssertFalse(value.windows.isEmpty)
        for index in value.windows.indices { value.windows[index].front = false }
        value.windows[0].front = true
        value.windows[0].addr = address
        value.windows[0].display = nil
        return value
    }

    private func drain(_ json: String) throws -> QDTraceDecode.Drain {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(QDTraceDecode.drain(object))
    }

    func testDrawOpsJoinOnlyByExactGuestWindowAddress() throws {
        let model = plane()
        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "pen":[20,30],"font":3,"size":9,"face":0,
           "len":8,"fullLen":8,"trunc":false,"text":"Workshop"},
          {"op":"text","port":"0x22222222","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":5,"fullLen":5,"trunc":false,"text":"Wrong"}],
         "cursor":0,"nextCursor":128,"writeCursor":128,"pending":0,
         "records":2,"wraps":0,"more":false,"resync":false,
         "torn":false,"busy":false,"lostBytes":0,"dropped":0}
        """), to: try scene())

        XCTAssertEqual(update.scene.windows[0].display?.map(\.text),
                       ["Workshop"])
        XCTAssertTrue(update.sentence.contains("1 new draw op"))
        XCTAssertTrue(update.sentence.contains("no window in this scene"))
        XCTAssertEqual(model.cursor, 128)
    }

    func testEmptyDrainRetainsTheLastSettledDisplay() throws {
        let model = plane()
        let first = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "verb":0,"rect":[0,0,20,20],"ext":[0,0]}],
         "nextCursor":32,"records":1}
        """), to: try scene())
        XCTAssertEqual(first.scene.windows[0].display?.count, 1)

        let second = model.apply(try drain("""
        {"cmd":"drain","ops":[],"nextCursor":32,"records":0}
        """), to: try scene())
        XCTAssertEqual(second.scene.windows[0].display?.count, 1)
        XCTAssertTrue(second.sentence.contains("retained 1 draw ops"))
    }

    func testPartialDrainDoesNotPublishHalfADisplay() throws {
        let model = plane()
        let partial = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "pen":[20,30],"font":3,"size":9,"face":0,
           "len":4,"fullLen":4,"trunc":false,"text":"Half"}],
         "nextCursor":64,"writeCursor":128,"records":1,"more":true}
        """), to: try scene())

        XCTAssertNil(partial.scene.windows[0].display,
                     "a bounded ring page is not a coherent repaint")
        XCTAssertEqual(model.operations.values.first?.map(\.text), ["Half"])
        XCTAssertTrue(partial.sentence.contains("last settled display"))

        let complete = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "pen":[20,44],"font":3,"size":9,"face":0,
           "len":4,"fullLen":4,"trunc":false,"text":"Done"}],
         "nextCursor":128,"writeCursor":128,"records":1,"more":false}
        """), to: try scene())
        XCTAssertEqual(complete.scene.windows[0].display?.map(\.text),
                       ["Half", "Done"])
    }

    func testResyncRetainsSettledContentUntilANewerGuestDisplay() throws {
        let model = plane()
        _ = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "verb":0,"rect":[0,0,20,20],"ext":[0,0]}],
         "nextCursor":32,"records":1}
        """), to: try scene())

        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[],"nextCursor":65536,"records":0,
         "resync":true,"lostBytes":4096}
        """), to: try scene())
        XCTAssertEqual(update.scene.windows[0].display?.count, 1)
        XCTAssertTrue(update.sentence.contains("4096 earlier bytes"))

        let sameGeneration = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":7,"fullLen":7,"trunc":false,"text":"Too late"}],
         "nextCursor":65568,"records":1}
        """), to: try scene())
        XCTAssertEqual(sameGeneration.scene.windows[0].display?.count, 1)
        XCTAssertTrue(sameGeneration.sentence.contains(
            "overwritten display generation"))

        let replacement = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":3,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":4,"generation":7,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":5,"fullLen":5,"trunc":false,"text":"Fresh"}],
         "nextCursor":65600,"records":1}
        """), to: try scene())
        XCTAssertEqual(replacement.scene.windows[0].display?.map(\.text),
                       ["Fresh"])
    }

    func testStaleGenerationCannotOverlayNewerDisplay() throws {
        let model = plane()
        let newer = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":9,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":4,"generation":8,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":3,"fullLen":3,"trunc":false,"text":"New"}],
         "nextCursor":64,"records":1}
        """), to: try scene())
        XCTAssertEqual(newer.scene.windows[0].display?.map(\.text), ["New"])

        let stale = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1eba6800","ticks":10,
           "a5":"0x00999999","psn":"0.29949953",
           "displayEpoch":99,"generation":7,
           "verb":0,"rect":[0,0,20,20]}],
         "nextCursor":128,"records":1}
        """), to: try scene())
        XCTAssertEqual(stale.scene.windows[0].display?.map(\.text), ["New"])
        XCTAssertTrue(stale.sentence.contains("rejected 1 stale/superseded"))
    }

    func testBitmapPlaceholderDoesNotDiscardAdjacentStructuredOps() throws {
        let model = plane()
        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"bits","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "src":[0,0,20,20],"dst":[4,4,24,24],"mode":0,"srcRowBytes":20},
          {"op":"text","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "pen":[30,30],"font":3,"size":9,"face":0,
           "len":5,"fullLen":5,"trunc":false,"text":"After"}],
         "nextCursor":128,"records":2}
        """), to: try scene())
        XCTAssertEqual(update.scene.windows[0].display?.map(\.op),
                       ["bits", "text"])
        XCTAssertFalse(update.sentence.contains("renderer defers bits"))
    }

    func testProcessSerialParsesOnlyTheTwoPartWireShape() {
        XCTAssertEqual(NOWMirrorContentPlane.serial("0.29360131")?.hi, 0)
        XCTAssertEqual(NOWMirrorContentPlane.serial("0.29360131")?.lo,
                       29_360_131)
        XCTAssertNil(NOWMirrorContentPlane.serial("front"))
        XCTAssertNil(NOWMirrorContentPlane.serial("1.2.3"))
    }

    func testSameProcessDifferentFrontWindowRequiresRetarget() throws {
        let first = try scene(address: 0x1000)
        let front = try XCTUnwrap(first.windows.first(where: \.front))
        XCTAssertFalse(NOWMirrorContentPlane.needsTarget(
            currentPSN: front.psn, currentWindow: 0x1000, front: front))

        var changed = front
        changed.addr = 0x2000
        XCTAssertTrue(NOWMirrorContentPlane.needsTarget(
            currentPSN: front.psn, currentWindow: 0x1000, front: changed))
    }

    func testOldVisibleWindowOfSameProcessCannotJoinAfterRetarget() throws {
        let model = plane()
        var value = try scene(address: 0x2000)
        XCTAssertGreaterThan(value.windows.count, 1)
        value.windows[1].psn = value.windows[0].psn
        value.windows[1].addr = 0x1000
        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x00001000","ticks":1,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":2,"generation":6,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":3,"fullLen":3,"trunc":false,"text":"Old"}],
         "nextCursor":64,"records":1}
        """), to: value)
        XCTAssertNil(update.scene.windows[0].display)
        XCTAssertNil(update.scene.windows[1].display)
        XCTAssertTrue(update.sentence.contains("named no window"))
    }
}
