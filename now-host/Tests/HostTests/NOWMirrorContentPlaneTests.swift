import XCTest
import MirrorKit
import MirrorKitUI
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

    /// **A world born away from the origin lands where it was born.**
    ///
    /// The Appearance panel composes each theme thumbnail into a GWorld
    /// made with the thumbnail's rect in WINDOW coordinates —
    /// `worldborn [36,57,213,182]` — so the world's own origin reads
    /// `[36,57]`, every op it draws is stated in that frame, and so is
    /// the `src` of the blit that reveals it. `dst - src` therefore
    /// already carries the whole translation.
    ///
    /// Before 2026-08-07 the join counted the origin a second time and
    /// dropped both thumbnails, opening white erase included, at the
    /// content's top-left corner — which is exactly where the panel's
    /// `Themes` and `Appearance` tabs are. The tabs rendered as bare end
    /// caps with nothing between them, and slice 16 ranked it first.
    ///
    /// Asserted as the effective window-local rectangle of the world's
    /// own opening erase, because that is the pixel claim: replay the
    /// published origin state the way `DisplayReplay` does and the erase
    /// must cover the thumbnail, not the tab strip.
    func testAWorldBornAwayFromTheOriginIsNotShiftedTwice() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "qdtrace-drain-sweep-appearance",
            withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let capture = try XCTUnwrap(QDTraceDecode.drain(object))
        var value = try scene(address: 0x1ea880b0)
        value.windows[0].psn = "0.35520514"
        value.windows[0].title = "Appearance"
        let ops = try XCTUnwrap(
            plane().apply(capture, to: value).scene.windows[0].display)

        var origin = [0, 0]
        var placed: [[Int]] = []
        for op in ops {
            if op.op == "state", op.kind == "origin",
               let o = op.origin, o.count == 2 { origin = o }
            guard op.op == "rect", op.verb == 2, let r = op.rect,
                  r.count == 4, r[2] - r[0] == 177, r[3] - r[1] == 125
            else { continue }
            placed.append([r[0] - origin[0], r[1] - origin[1],
                           r[2] - origin[0], r[3] - origin[1]])
        }

        XCTAssertFalse(placed.isEmpty,
                       "the thumbnail worlds' opening erases reach the window")
        for rect in placed {
            XCTAssertTrue(rect == [36, 57, 213, 182]
                          || rect == [232, 57, 409, 182],
                          "a thumbnail erase landed at \(rect); the two "
                          + "thumbnails are at [36,57] and [232,57] and "
                          + "[0,0] is the tab strip")
        }
    }

    /// The control run's own drain, captured live off a mac99 guest on
    /// 2026-08-06 (tools/gwprobe.py, label control-join-3): one rebuild
    /// burst of the loop applet's GWorld — six 'offscreen row' texts at
    /// pens the applet's source states outright — then the blitsrc+bits
    /// pair that reveals it. The join must place all six texts and leave
    /// no hatch. This is the two halves meeting on real bytes, not on a
    /// hand-typed fixture.
    func testControlCaptureJoinsSixOffscreenRowsIntoTheWindow() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "qdtrace-drain-blitsrc-control",
            withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let capture = try XCTUnwrap(QDTraceDecode.drain(object))
        XCTAssertTrue(capture.recordCountAgrees,
                      "the captured drain decodes whole")

        var value = try scene(address: 0x1e9431f0)
        value.windows[0].psn = "0.35782658"
        for index in value.windows.indices where index != 0 {
            value.windows[index].psn = "0.99999999"
        }
        let model = plane()
        let update = model.apply(capture, to: value)

        let display = try XCTUnwrap(update.scene.windows[0].display)
        XCTAssertEqual(display.filter { $0.op == "text" }.map(\.text),
                       Array(repeating: "offscreen row", count: 6))
        XCTAssertFalse(display.map(\.op).contains("bits"),
                       "the joined composite replaced the hatch")
        XCTAssertEqual(display.first { $0.op == "text" }?.pen, [14, 24],
                       "the first row lands at the applet's own pen")
        XCTAssertTrue(update.sentence.contains("joined 1 composite"))
    }

    /// THE PAYOFF (plan 013, slice D): a real Finder icon-view window's
    /// interior, composed host-side from a drain captured live off the
    /// CFM Finder on mac99/OS 9.1 (gwprobe finder-join-7, 2026-08-06) —
    /// ten real labels at their true pens, icon stamps as bits geometry,
    /// one blitsrc naming the hooked offscreen world, and not one pixel
    /// on the wire. The pens asserted below are the same values plan 013
    /// quotes from the original measurement, captured again a day later
    /// through the whole new pipeline.
    func testFinderCaptureComposesTheRealInteriorHostSide() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "qdtrace-drain-blitsrc-finder",
            withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let capture = try XCTUnwrap(QDTraceDecode.drain(object))
        XCTAssertTrue(capture.recordCountAgrees)

        var value = try scene(address: 0x00a01c40)
        value.windows[0].psn = "0.29949953"
        value.windows[0].title = "Macintosh HD"
        for index in value.windows.indices where index != 0 {
            value.windows[index].psn = "0.99999999"
        }
        let model = plane()
        let update = model.apply(capture, to: value)

        let display = try XCTUnwrap(update.scene.windows[0].display)
        let texts = display.filter { $0.op == "text" }
        XCTAssertEqual(texts.count, 10, "every label the Finder drew")
        func pen(_ label: String) -> [Int]? {
            texts.first { $0.text == label }?.pen
        }
        XCTAssertEqual(pen("10 items, 3.21 GB available"), [135, 14])
        XCTAssertEqual(pen("Documents"), [280, 67])
        XCTAssertEqual(pen("TimBotTu"), [282, 131])
        XCTAssertEqual(pen("TBT"), [40, 195])
        /* Icons arrive as bits geometry (deferred item 1: identity needs
           PlotIconSuite interception) — hatched rectangles at correct
           positions is the honest first result, not a shortfall. They
           are the re-homed source's own stamps, not the joined blit. */
        XCTAssertGreaterThan(
            display.filter { $0.op == "bits" }.count, 0,
            "icon stamps survive as placed geometry")
        XCTAssertTrue(update.sentence.contains("joined 1 composite"))

        /* Mirror's render-screenshot rule: the composed interior is
           agent-verifiable as an image of the RENDER — not the guest
           framebuffer, not the host screen. Opt-in so CI never writes
           outside its sandbox. */
        if let out = ProcessInfo.processInfo.environment["NOW_RENDER_OUT"] {
            let png = try RenderShot.png(scene: update.scene)
            try png.write(to: URL(fileURLWithPath: out))
        }
    }

    /// G1: a cycle chases the cursor while the guest says `more`,
    /// instead of leaving a busy ring to lap an awake reader. The
    /// listener here answers two pages and then stops, so the assertion
    /// is that BOTH were consumed inside one join.
    func testABusyRingIsDrainedAcrossPagesWithinOneCycle() throws {
        let model = plane()
        let first = try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":1,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "pen":[20,30],"font":3,"size":9,"face":0,
           "len":4,"fullLen":4,"trunc":false,"text":"Page"}],
         "nextCursor":64,"writeCursor":256,"records":1,"more":true}
        """)
        let second = try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x1eba6800","ticks":2,
           "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
           "pen":[20,44],"font":3,"size":9,"face":0,
           "len":3,"fullLen":3,"trunc":false,"text":"Two"}],
         "nextCursor":256,"writeCursor":256,"records":1,"more":false}
        """)
        _ = model.apply(first, to: try scene())
        let update = model.apply(second, to: try scene())
        XCTAssertEqual(update.scene.windows[0].display?.map(\.text),
                       ["Page", "Two"],
                       "both pages land in one settled display")
        XCTAssertEqual(model.cursor, 256, "the cursor caught the writer")
    }

    /* ── THE IDLE DECAY (2026-08-07) ────────────────────────────────────
       Michelle's Date & Time panel lost its group boxes, its date field
       and half of two labels while she was NOT touching it, minutes
       after opening it, and never recovered until she pushed the window
       back and brought it forward.

       `displayEpoch` advances once per ARM, not per repaint, so a panel
       with a ticking clock accumulates into ONE identity for as long as
       it stays front. The accumulator's cap was a raw FIFO: past 1200
       ops it dropped the OLDEST, which is the establishing repaint —
       the erase, the group boxes, the static labels — while keeping the
       clock ticks that pushed it over. The window did not get smaller;
       it got hollow, and the sentence said nothing at all.

       These two tests are the mechanism and its honest floor. */

    /// The establishing repaint must survive an application that keeps
    /// drawing small ops forever. Reintroduce the raw `removeFirst` trim
    /// and this fails naming the labels.
    func testAClockTickingPastTheCapDoesNotHollowOutTheWindow() throws {
        let model = plane()
        _ = model.apply(try drain(Self.establishingPass), to: try scene())

        // ~40 minutes of a one-second clock at four ops a tick: far past
        // the 1200-op cap, and not one of them redraws a label.
        for tick in 0..<600 {
            _ = model.apply(try drain(Self.clockTick(tick)), to: try scene())
        }

        let display = try XCTUnwrap(
            model.apply(try drain("""
            {"cmd":"drain","ops":[],"nextCursor":9999,"records":0}
            """), to: try scene()).scene.windows[0].display)
        let text = display.compactMap(\.text)
        XCTAssertTrue(text.contains("Current Date"),
                      "the establishing pass was evicted: \(text.prefix(8))")
        XCTAssertTrue(text.contains("Set Daylight-Saving Time Automatically"))
        XCTAssertTrue(text.contains("Server Options…"))
        XCTAssertLessThanOrEqual(
            model.operations.values.reduce(0) { $0 + $1.count },
            NOWMirrorContentPlane.operationCapPerWindow,
            "compaction must stay bounded, not merely stop trimming")
    }

    /// When there is no pass boundary to compact to, the ops really are
    /// dropped — and THAT must be said, not swallowed. The frame is
    /// marked stale so the renderer shows a gap rather than a confident
    /// subset.
    func testACapReachedWithNoPassBoundaryMarksTheFrameRatherThanLying()
        throws {
        let model = plane()
        // Regions carry no geometry on this wire, so neither the pass
        // rule nor the coverage rule can measure them: nothing here is
        // provably off the guest's screen, and the drop is forced.
        for tick in 0..<700 {
            _ = model.apply(try drain("""
            {"cmd":"drain","ops":[
              {"op":"rgn","port":"0x1eba6800","ticks":\(100 + tick),
               "a5":"0x00100000","psn":"0.29949953",
               "displayEpoch":3,"generation":7,"verb":1},
              {"op":"rgn","port":"0x1eba6800","ticks":\(100 + tick),
               "a5":"0x00100000","psn":"0.29949953",
               "displayEpoch":3,"generation":7,"verb":2}],
             "nextCursor":\(300 + tick * 32),"records":2,"more":false}
            """), to: try scene())
        }
        let update = model.apply(try drain("""
        {"cmd":"drain","ops":[],"nextCursor":9999,"records":0}
        """), to: try scene())
        XCTAssertTrue(
            update.sentence.contains("dropped"),
            "silent subtraction is the defect: \(update.sentence)")
        XCTAssertEqual(update.scene.windows[0].displayEpoch?.stale, true)
    }

    /// One full repaint pass of a Date & Time-shaped panel: a window-wide
    /// erase, the group boxes, the static labels, the date field.
    private static let establishingPass = """
    {"cmd":"drain","ops":[
      {"op":"rect","port":"0x1eba6800","ticks":1,
       "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
       "verb":2,"rect":[0,0,404,238],"ext":[0,0]},
      {"op":"rect","port":"0x1eba6800","ticks":1,
       "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
       "verb":0,"rect":[12,20,190,70],"ext":[0,0]},
      {"op":"text","port":"0x1eba6800","ticks":1,
       "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
       "pen":[20,18],"font":3,"size":9,"face":0,
       "len":12,"fullLen":12,"trunc":false,"text":"Current Date"},
      {"op":"text","port":"0x1eba6800","ticks":1,
       "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
       "pen":[20,40],"font":3,"size":9,"face":0,
       "len":9,"fullLen":9,"trunc":false,"text":"8/ 7/2026"},
      {"op":"text","port":"0x1eba6800","ticks":1,
       "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
       "pen":[20,120],"font":3,"size":9,"face":0,
       "len":38,"fullLen":38,"trunc":false,
       "text":"Set Daylight-Saving Time Automatically"},
      {"op":"text","port":"0x1eba6800","ticks":1,
       "a5":"0x00100000","psn":"0.29949953","displayEpoch":3,"generation":7,
       "pen":[20,200],"font":3,"size":9,"face":0,
       "len":15,"fullLen":15,"trunc":false,"text":"Server Options…"}],
     "nextCursor":256,"records":6,"more":false}
    """

    /// One second of the panel's live clock: erase the field, draw the
    /// time. Nothing here re-establishes anything.
    private static func clockTick(_ tick: Int) -> String {
        let ticks = 100 + tick
        return """
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1eba6800","ticks":\(ticks),
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "verb":2,"rect":[205,20,320,56],"ext":[0,0]},
          {"op":"text","port":"0x1eba6800","ticks":\(ticks),
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":3,"generation":7,
           "pen":[222,42],"font":3,"size":9,"face":0,
           "len":8,"fullLen":8,"trunc":false,"text":"\(Self.clock(tick))"}],
         "nextCursor":\(300 + tick * 32),"records":2,"more":false}
        """
    }

    private static func clock(_ tick: Int) -> String {
        String(format: "%02d:%02d:%02d", tick / 3600 % 24,
               tick / 60 % 60, tick % 60)
    }

    /* ── THE OTHER HALF OF THE SAME DECAY ───────────────────────────────
       The host re-arms the guest's trace on a 9-minute timer against a
       10-minute guest TTL, with nobody touching anything. Re-arming
       bumps the guest's `display_epoch`, so the next record opens an
       identity this host has never seen — and an EMPTY accumulator —
       while the window on the guest still holds every pixel it drew.
       The first thing a settled panel draws afterwards is one clock
       tick, and that one op settled as the entire published display.

       This needs no cap, no eviction and no disposal: it is the picture
       collapsing to whatever was redrawn in the seconds after a renewal
       the person never asked for, on a timer that matches "minutes
       apart, nothing touched". */

    func testARenewalReArmDoesNotCollapseTheWindowToItsNextClockTick()
        throws {
        let model = plane()
        _ = model.apply(try drain(Self.establishingPass), to: try scene())
        _ = model.apply(try drain(Self.clockTick(0)), to: try scene())

        // The 9-minute renewal: same window, fresh ring baseline, and the
        // guest's re-arm advances displayEpoch 3 → 4.
        model.carryForward = true
        let after = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"rect","port":"0x1eba6800","ticks":900,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":4,"generation":7,
           "verb":2,"rect":[205,20,320,56],"ext":[0,0]},
          {"op":"text","port":"0x1eba6800","ticks":900,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":4,"generation":7,
           "pen":[222,42],"font":3,"size":9,"face":0,
           "len":8,"fullLen":8,"trunc":false,"text":"00:09:00"}],
         "nextCursor":64,"records":2,"more":false}
        """), to: try scene())

        let text = try XCTUnwrap(after.scene.windows[0].display)
            .compactMap(\.text)
        XCTAssertTrue(text.contains("Current Date"),
                      "the renewal collapsed the window: \(text)")
        XCTAssertTrue(text.contains("Server Options…"))
        XCTAssertTrue(text.contains("00:09:00"), "and it is still live")
        XCTAssertTrue(after.sentence.contains("carried"))
    }

    /// The control for the test above: a RETARGET — a genuinely different
    /// window — must inherit nothing, or one window's pixels would be
    /// published as another's.
    func testARetargetInheritsNothingFromTheWindowItReplaced() throws {
        let model = plane()
        _ = model.apply(try drain(Self.establishingPass), to: try scene())
        XCTAssertFalse(model.carryForward,
                       "a renewal sets this; a retarget must not")

        let other = try scene(address: 0x2000)
        let after = model.apply(try drain("""
        {"cmd":"drain","ops":[
          {"op":"text","port":"0x00002000","ticks":900,
           "a5":"0x00100000","psn":"0.29949953",
           "displayEpoch":9,"generation":8,
           "pen":[20,18],"font":3,"size":9,"face":0,
           "len":5,"fullLen":5,"trunc":false,"text":"Fresh"}],
         "nextCursor":64,"records":1,"more":false}
        """), to: other)
        XCTAssertEqual(after.scene.windows[0].display?.compactMap(\.text),
                       ["Fresh"])
    }

    /* The coverage rule is allowed to keep an op it could have dropped
       and is never allowed to drop one still on the guest's screen, so
       these four are the ones that matter. Each fails if the
       corresponding conservatism is removed. */

    func testCoverageKeepsWhatItCannotMeasureOrProve() {
        func text(_ s: String, at pen: [Int]) -> DisplayOp {
            var op = DisplayOp(op: "text", ticks: 1)
            op.text = s; op.pen = pen; op.size = 9; op.fullLen = s.count
            return op
        }
        func rect(verb: Int, _ r: [Int]) -> DisplayOp {
            var op = DisplayOp(op: "rect", ticks: 2)
            op.verb = verb; op.rect = r
            return op
        }

        // A FRAME does not replace pixels, so it covers nothing.
        let framed = [text("Label", at: [20, 40]),
                      rect(verb: 0, [0, 0, 400, 200])]
        XCTAssertEqual(NOWMirrorContentPlane.coalesce(framed).count, 2)

        // An erase that covers the label DOES drop it.
        let erased = [text("Label", at: [20, 40]),
                      rect(verb: 2, [0, 0, 400, 200])]
        XCTAssertEqual(NOWMirrorContentPlane.coalesce(erased).count, 1)

        // Partial coverage is not coverage: the label runs past the erase.
        let clipped = [text("A very long label indeed", at: [20, 40]),
                       rect(verb: 2, [0, 0, 60, 200])]
        XCTAssertEqual(NOWMirrorContentPlane.coalesce(clipped).count, 2)

        // An oval does not fill its bounding rectangle, so it covers
        // nothing even when it paints.
        var oval = DisplayOp(op: "oval", ticks: 2)
        oval.verb = 1; oval.rect = [0, 0, 400, 200]
        XCTAssertEqual(
            NOWMirrorContentPlane.coalesce([text("Label", at: [20, 40]), oval])
                .count, 2)
    }

    func testAnEraseIsNotCreditedBeyondItsOwnClip() {
        var clip = DisplayOp(op: "state", ticks: 1)
        clip.kind = "clip"; clip.rect = [0, 0, 100, 100]
        var label = DisplayOp(op: "text", ticks: 1)
        label.text = "Outside"; label.pen = [200, 40]; label.size = 9
        label.fullLen = 7
        var erase = DisplayOp(op: "rect", ticks: 2)
        erase.verb = 2; erase.rect = [0, 0, 400, 400]
        // The erase names the whole window but is clipped to a corner, so
        // the label outside that corner survives.
        XCTAssertEqual(
            NOWMirrorContentPlane.coalesce([clip, label, erase]).count, 3)
    }

    func testCoverageIsJudgedInAbsoluteSpaceNotPortLocalNumbers() {
        var shift = DisplayOp(op: "state", ticks: 1)
        shift.kind = "origin"; shift.origin = [0, 200]
        var label = DisplayOp(op: "text", ticks: 1)
        label.text = "Row"; label.pen = [20, 40]; label.size = 9
        label.fullLen = 3
        var restore = DisplayOp(op: "state", ticks: 2)
        restore.kind = "origin"; restore.origin = [0, 0]
        var erase = DisplayOp(op: "rect", ticks: 2)
        erase.verb = 2; erase.rect = [0, 0, 400, 100]
        /* The label is drawn under an origin of [0,200] — absolutely at
           y ≈ -160 — while the erase after it is drawn at the port's own
           origin covering y 0…100. The port-local numbers say "covered";
           the machine says otherwise, and the machine is right. */
        XCTAssertEqual(
            NOWMirrorContentPlane.coalesce([shift, label, restore, erase])
                .count, 4)
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
