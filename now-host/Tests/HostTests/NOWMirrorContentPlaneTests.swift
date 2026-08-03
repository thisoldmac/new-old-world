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
           "pen":[20,30],"font":3,"size":9,"face":0,
           "len":8,"fullLen":8,"trunc":false,"text":"Workshop"},
          {"op":"text","port":"0x22222222","ticks":2,
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

    func testResyncRetractsContentThatMayHaveBeenOverwritten() throws {
        let model = plane()
        _ = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1eba6800","ticks":1,
           "verb":0,"rect":[0,0,20,20],"ext":[0,0]}],
         "nextCursor":32,"records":1}
        """), to: try scene())

        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[],"nextCursor":65536,"records":0,
         "resync":true,"lostBytes":4096}
        """), to: try scene())
        XCTAssertNil(update.scene.windows[0].display)
        XCTAssertTrue(update.sentence.contains("4096 earlier bytes"))
    }

    func testProcessSerialParsesOnlyTheTwoPartWireShape() {
        XCTAssertEqual(NOWMirrorContentPlane.serial("0.29360131")?.hi, 0)
        XCTAssertEqual(NOWMirrorContentPlane.serial("0.29360131")?.lo,
                       29_360_131)
        XCTAssertNil(NOWMirrorContentPlane.serial("front"))
        XCTAssertNil(NOWMirrorContentPlane.serial("1.2.3"))
    }
}
