import XCTest
@testable import MirrorKit

/// Scrollbar anatomy — pure geometry, no guest. Pressing the wrong region is
/// not a near-miss: an arrow scrolls a line, the track pages, and the far side
/// of the thumb pages the WRONG WAY. So the arithmetic gets pinned here.
final class ScrollbarTests: XCTestCase {

    /// The real vertical scrollbar off a live mac99 SimpleText window
    /// (2026-07-17): control-space rect, value 33 of 0…33 (scrolled to the
    /// bottom). Its global rect was [426,39,442,192] via the (4,40) content
    /// origin — the mapping the live test actually clicked through.
    private func live(value: Int = 33) -> Scene.Control {
        Scene.Control(ref: "ax2/x/window:untitled%202#0/control:#0/node:1",
                      role: "scrollbar", title: "",
                      rect: Rect(l: 422, t: -1, r: 438, b: 152),
                      enabled: true, visible: true,
                      value: value, min: 0, max: 33, checked: false)
    }

    /// A window whose content fits reports 0/0/0 and degrades to "control".
    /// That is honest, not a gap — and it must never look scrollable.
    func testNothingToScrollIsNotLive() {
        var c = live(); c.role = "control"; c.value = 0; c.min = 0; c.max = 0
        XCTAssertFalse(Scrollbar.isLive(c))
        XCTAssertNil(Scrollbar.part(c, atX: 430, y: 7))
        XCTAssertNil(Scrollbar.thumbRect(c))
    }

    func testLiveBarIsVerticalWithArrowsBoundingTheTrack() {
        let c = live()
        XCTAssertTrue(Scrollbar.isLive(c))
        XCTAssertTrue(Scrollbar.isVertical(c))
        let track = Scrollbar.track(c)
        XCTAssertEqual(track?.t, -1 + Scrollbar.arrow)   // below the up arrow
        XCTAssertEqual(track?.b, 152 - Scrollbar.arrow)  // above the down arrow
    }

    /// The two points the live run actually pressed, in control space. Their
    /// globals were (434,47) and (434,184) — both confirmed to scroll one line.
    func testArrowCentersMatchWhatTheGuestAccepted() {
        let c = live()
        let up = Scrollbar.center(c, .lineUp)
        let down = Scrollbar.center(c, .lineDown)
        XCTAssertEqual(up?.x, 430); XCTAssertEqual(up?.y, 7)      // +(4,40) = (434,47)
        XCTAssertEqual(down?.x, 430); XCTAssertEqual(down?.y, 144) // +(4,40) = (434,184)
    }

    func testPartResolvesEveryRegion() {
        let c = live(value: 16)                    // thumb mid-track
        XCTAssertEqual(Scrollbar.part(c, atX: 430, y: 0), .lineUp)
        XCTAssertEqual(Scrollbar.part(c, atX: 430, y: 148), .lineDown)
        guard let thumb = Scrollbar.thumbRect(c) else { return XCTFail("no thumb") }
        XCTAssertEqual(Scrollbar.part(c, atX: 430, y: (thumb.t + thumb.b) / 2), .thumb)
        XCTAssertEqual(Scrollbar.part(c, atX: 430, y: thumb.t - 2), .pageUp)
        XCTAssertEqual(Scrollbar.part(c, atX: 430, y: thumb.b + 2), .pageDown)
        XCTAssertNil(Scrollbar.part(c, atX: 500, y: 60), "outside the bar")
    }

    func testThumbTracksValueFromTopToBottom() {
        let top = Scrollbar.thumbRect(live(value: 0))
        let bottom = Scrollbar.thumbRect(live(value: 33))
        let track = Scrollbar.track(live())!
        XCTAssertEqual(top?.t, track.t, "value==min pins the thumb to the track top")
        XCTAssertEqual(bottom?.b, track.b, "value==max pins it to the bottom")
    }

    /// At an extreme the gap beyond the thumb collapses. Pressing "the page
    /// below" when the thumb is already at the bottom lands ABOVE it and pages
    /// backwards — the live bug this guard fixes. No target is the right answer.
    func testDegeneratePageGapIsNotATarget() {
        XCTAssertNil(Scrollbar.center(live(value: 33), .pageDown),
                     "thumb at the bottom: no page-down gap to press")
        XCTAssertNil(Scrollbar.center(live(value: 0), .pageUp),
                     "thumb at the top: no page-up gap to press")
        // The opposite side still has room.
        XCTAssertNotNil(Scrollbar.center(live(value: 33), .pageUp))
        XCTAssertNotNil(Scrollbar.center(live(value: 0), .pageDown))
    }

    func testThumbTargetIsMonotonicAndClamped() {
        let lo = Scrollbar.thumbTarget(live(), value: 0)!
        let hi = Scrollbar.thumbTarget(live(), value: 33)!
        XCTAssertLessThan(lo.y, hi.y, "larger value = further down")
        XCTAssertEqual(Scrollbar.thumbTarget(live(), value: 999)!.y, hi.y,
                       "out-of-range clamps to max")
    }

    /// OS 9 has no wheel driver, so a wheel notch maps to the arrow the user
    /// would have clicked — never an injected wheel event that silently no-ops.
    func testWheelMapsToLineClicksAndRespectsDirection() {
        let origin = (x: 4, y: 40)
        let down = ActionModel.wheel(3, on: live(value: 0), contentOrigin: origin)
        XCTAssertEqual(down.count, 3)
        XCTAssertEqual(down.first, .qmpClick(x: 434, y: 184), "down arrow, global")
        let up = ActionModel.wheel(-1, on: live(), contentOrigin: origin)
        XCTAssertEqual(up, [.qmpClick(x: 434, y: 47)], "up arrow, global")
        XCTAssertTrue(ActionModel.wheel(0, on: live(), contentOrigin: origin).isEmpty)
        // A bar with nothing to scroll gets no clicks at all.
        var dead = live(); dead.max = 0; dead.value = 0; dead.role = "control"
        XCTAssertTrue(ActionModel.wheel(3, on: dead, contentOrigin: origin).isEmpty)
    }

    /// The thumb is a DRAG, not a click — a click action for it would press
    /// the thumb and go nowhere.
    func testThumbIsNotAClickTarget() {
        let hit = HitTester.Target.scrollbar(windowID: "w", control: live(),
                                             part: .thumb, x: 434, y: 100)
        XCTAssertTrue(ActionModel.click(on: hit).isEmpty)
        // Arrows and pages DO click, through the QMP tracking plane.
        let arrow = HitTester.Target.scrollbar(windowID: "w", control: live(),
                                               part: .lineDown, x: 434, y: 184)
        XCTAssertEqual(ActionModel.click(on: arrow), [.qmpClick(x: 434, y: 184)])
    }
}
