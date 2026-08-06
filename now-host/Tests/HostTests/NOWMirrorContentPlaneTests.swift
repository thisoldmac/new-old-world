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
           "a5":"0x00999999","psn":"0.11111111","displayEpoch":3,"generation":7,
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

        let replacementPage = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":3,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":4,"generation":7,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":5,"fullLen":5,"trunc":false,"text":"Fresh"}],
         "nextCursor":65600,"records":1,"more":true}
        """), to: try scene())
        XCTAssertEqual(replacementPage.scene.windows[0].display?.count, 1,
                       "a partial replacement keeps the settled display")

        let replacement = model.apply(try drain("""
        {"cmd":"drain","ops":[],"nextCursor":65600,"records":0,
         "more":false}
        """), to: try scene())
        XCTAssertEqual(replacement.scene.windows[0].display?.map(\.text),
                       ["Fresh"])
    }

    func testFrontlessObservationRetainsInactiveWindowDisplay() throws {
        let model = plane()
        _ = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":7,"fullLen":7,"trunc":false,"text":"Retained"}],
         "nextCursor":64,"records":1}
        """), to: try scene())

        var frontless = try scene()
        for index in frontless.windows.indices {
            frontless.windows[index].front = false
        }
        let finished = expectation(description: "frontless join")
        model.join(into: frontless) { update in
            XCTAssertEqual(update.scene.windows[0].display?.map(\.text),
                           ["Retained"])
            XCTAssertTrue(update.sentence.contains("expected-stale"))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
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

    func testBitmapOnlyGenerationPublishesOnlyItsOwnSettledOps() throws {
        let model = plane()
        let first = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"state","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "kind":"origin","origin":[0,0]},
          {"op":"text","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "pen":[30,30],"font":3,"size":9,"face":0,
           "len":4,"fullLen":4,"trunc":false,"text":"City"}],
         "nextCursor":96,"records":2}
        """), to: try scene())
        XCTAssertEqual(first.scene.windows[0].display?.map(\.op),
                       ["state", "text"])

        let bitmap = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"bits","port":"0x1eba6800","ticks":3,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":4,"generation":8,
           "src":[0,0,100,100],"dst":[0,0,100,100]}],
         "nextCursor":160,"records":1}
        """), to: try scene())

        XCTAssertEqual(bitmap.scene.windows[0].display?.map(\.op), ["bits"],
                       "cross-generation retention belongs to the state engine")
        XCTAssertFalse(bitmap.sentence.contains("expected-stale"))
    }

    // MARK: - The blit-source join (plan 013, slice C)

    /// The whole slice in one drain: ops arrive under an offscreen port's
    /// key, a blitsrc record names that port, and the bits record that
    /// follows is REPLACED by the held ops re-homed into the window —
    /// shifted by the blit's translation and clipped to its destination.
    func testBlitSourceJoinRehomesOffscreenOpsIntoTheWindow() throws {
        let model = plane()
        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1f472e60","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "pen":[10,50],"font":3,"size":9,"face":0,
           "len":13,"fullLen":13,"trunc":false,"text":"offscreen row"},
          {"op":"blitsrc","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "srcPort":"0x1f472e60","srcPixmap":"0x00445566"},
          {"op":"bits","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "src":[0,0,404,203],"dst":[4,24,408,227],"mode":0,
           "srcRowBytes":1632}],
         "nextCursor":128,"records":3}
        """), to: try scene())

        let display = try XCTUnwrap(update.scene.windows[0].display)
        XCTAssertFalse(display.map(\.op).contains("bits"),
                       "a joined blit is content, never a hatch")
        XCTAssertEqual(display.map(\.op),
                       ["state", "state", "text", "state", "state"])
        XCTAssertEqual(display[0].kind, "origin")
        XCTAssertEqual(display[0].origin, [-4, -24],
                       "the prologue origin shifts held ops by dst - src")
        XCTAssertEqual(display[1].kind, "clip")
        XCTAssertEqual(display[1].rect, [0, 0, 404, 203],
                       "clipping to src maps to exactly dst under that origin")
        XCTAssertEqual(display[2].text, "offscreen row")
        XCTAssertEqual(display[2].pen, [10, 50],
                       "the held op itself is untouched; the origin moves it")
        XCTAssertEqual(display[3].kind, "origin")
        XCTAssertEqual(display[3].origin, [0, 0])
        XCTAssertEqual(display[4].kind, "clip")
        XCTAssertTrue(update.sentence.contains("joined 1 composite"))
        XCTAssertTrue(update.sentence.contains("holding 1 offscreen op"))
    }

    /// A blitsrc claim binds only the record immediately after it. An
    /// intervening op voids it: letting the claim drift onto a later blit
    /// is how one window's content ends up inside another.
    func testBlitSourceClaimVoidedByAnInterveningOp() throws {
        let model = plane()
        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1f472e60","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "verb":1,"rect":[0,0,50,50],"ext":[0,0]},
          {"op":"blitsrc","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "srcPort":"0x1f472e60","srcPixmap":"0x00445566"},
          {"op":"text","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "pen":[2,3],"font":3,"size":9,"face":0,
           "len":7,"fullLen":7,"trunc":false,"text":"Between"},
          {"op":"bits","port":"0x1eba6800","ticks":3,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "src":[0,0,50,50],"dst":[4,24,54,74],"mode":0,"srcRowBytes":100}],
         "nextCursor":160,"records":4}
        """), to: try scene())

        XCTAssertEqual(update.scene.windows[0].display?.map(\.op),
                       ["text", "bits"],
                       "a voided claim leaves the bits op to hatch honestly")
        XCTAssertFalse(update.sentence.contains("joined"))
    }

    /// A blitsrc naming a source this host never held degrades to the
    /// existing behaviour: the bits op lands and hatches.
    func testBlitSourceForAnUnheldSourceKeepsTheBitsOp() throws {
        let model = plane()
        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"blitsrc","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "srcPort":"0x1f472e60","srcPixmap":"0x00445566"},
          {"op":"bits","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "src":[0,0,50,50],"dst":[4,24,54,74],"mode":0,"srcRowBytes":100}],
         "nextCursor":96,"records":2}
        """), to: try scene())

        XCTAssertEqual(update.scene.windows[0].display?.map(\.op), ["bits"])
        XCTAssertFalse(update.sentence.contains("joined"))
    }

    /// A held source is keyed by port AND generation: the same address in
    /// a later arm generation is a DIFFERENT world (a disposed world's
    /// address is reused by the next NewGWorld of the same size).
    func testSourceAddressReuseAcrossGenerationsDoesNotJoin() throws {
        let model = plane()
        _ = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1f472e60","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "pen":[10,50],"font":3,"size":9,"face":0,
           "len":5,"fullLen":5,"trunc":false,"text":"Stale"}],
         "nextCursor":64,"records":1}
        """), to: try scene())

        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"blitsrc","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":4,"generation":8,
           "srcPort":"0x1f472e60","srcPixmap":"0x00445566"},
          {"op":"bits","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":4,"generation":8,
           "src":[0,0,50,50],"dst":[4,24,54,74],"mode":0,"srcRowBytes":100}],
         "nextCursor":160,"records":2}
        """), to: try scene())

        XCTAssertEqual(update.scene.windows[0].display?.map(\.op), ["bits"],
                       "generation 7's ops must not join a generation 8 blit")
    }

    /// The re-home transform composes in-stream origin changes with the
    /// blit's translation, and restores only the state the held run
    /// actually touched.
    func testRehomeTranslatesInStreamOriginsAndRestoresTouchedState() throws {
        var origin = DisplayOp(op: "state", ticks: 1)
        origin.kind = "origin"
        origin.origin = [100, 200]
        var fg = DisplayOp(op: "state", ticks: 1)
        fg.kind = "fg"
        fg.rgb = [65_535, 0, 0]
        var text = DisplayOp(op: "text", ticks: 1)
        text.text = "x"
        text.pen = [110, 210]
        var bits = DisplayOp(op: "bits", ticks: 2)
        bits.src = [0, 0, 50, 50]
        bits.dst = [10, 20, 60, 70]

        var window = NOWMirrorContentPlane.PortState()
        window.fg = [0, 0, 65_535]
        let out = try XCTUnwrap(NOWMirrorContentPlane.rehome(
            [origin, fg, text], bits: bits, restoring: window))

        XCTAssertEqual(out[2].origin, [90, 180],
                       "an in-stream origin composes with the translation")
        XCTAssertEqual(out.last?.kind, "fg")
        XCTAssertEqual(out.last?.rgb, [0, 0, 65_535],
                       "a touched colour restores to the window's own")
        XCTAssertFalse(out.contains { $0.kind == "bg" },
                       "an untouched colour is not restored")
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
