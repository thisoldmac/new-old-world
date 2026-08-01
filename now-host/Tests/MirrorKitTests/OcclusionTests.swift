import XCTest
@testable import MirrorKit

/// First-sight capture is only safe for a window nothing covers, because
/// `capture` reads a SCREEN region: a covered window would come back holding
/// whatever sits on top of it. These pin that rule, since getting it subtly
/// wrong produces confident, mislabelled pixels rather than an obvious failure.
final class OcclusionTests: XCTestCase {

    private func win(_ title: String, _ l: Int, _ t: Int, _ r: Int, _ b: Int,
                     front: Bool = false, visible: Bool = true,
                     app: String = "SimpleText") -> Scene.Window {
        Scene.Window(id: "0.1/\(title)#0", app: app, psn: "0.1",
                     title: title, kind: 0,
                     rect: Rect(l: l, t: t, r: r, b: b),
                     front: front, z: 0, visible: visible, controls: [])
    }

    func testAWindowWithNothingInFrontIsNotOccluded() {
        let windows = [win("front", 0, 0, 100, 100, front: true),
                       win("back", 300, 300, 400, 400)]
        XCTAssertFalse(SceneGeometry.isOccluded(windows, index: 1),
                       "disjoint rects must not read as occlusion")
    }

    func testAnOverlappedWindowIsOccluded() {
        let windows = [win("front", 0, 0, 350, 350, front: true),
                       win("back", 300, 300, 400, 400)]
        XCTAssertTrue(SceneGeometry.isOccluded(windows, index: 1))
    }

    /// The strict case: even a sliver of overlap disqualifies a capture. Half
    /// the window would be right and the seam would be someone else's pixels,
    /// which is worse than showing nothing.
    ///
    /// Note the geometry, which caught a bad fixture on the way in: occlusion
    /// is judged against the CONTENT rect, inset 22px for the title bar. A
    /// window ending at y=305 covers the back window's title bar but none of
    /// its content, and is correctly NOT an occluder. The overlap has to reach
    /// past the inset to matter.
    func testPartialOverlapCounts() {
        let windows = [win("front", 0, 0, 305, 330, front: true),
                       win("back", 300, 300, 400, 400)]   // content t = 322
        XCTAssertTrue(SceneGeometry.isOccluded(windows, index: 1),
                      "an overlap reaching into the content contaminates it")
    }

    func testCoveringOnlyTheTitleBarIsNotOcclusion() {
        // The complement of the above, stated so the inset is deliberate rather
        // than incidental: we capture content, so chrome overlap is irrelevant.
        let windows = [win("front", 0, 0, 305, 305, front: true),
                       win("back", 300, 300, 400, 400)]
        XCTAssertFalse(SceneGeometry.isOccluded(windows, index: 1))
    }

    func testOnlyWindowsInFrontOfItCount() {
        // Scene order is front-first, so a HIGHER index is behind: it cannot
        // occlude us however much it overlaps.
        let windows = [win("me", 300, 300, 400, 400),
                       win("behind", 0, 0, 800, 800)]
        XCTAssertFalse(SceneGeometry.isOccluded(windows, index: 0),
                       "a window behind us must never count as occluding")
    }

    func testInvisibleWindowsDoNotOcclude() {
        let windows = [win("hidden", 0, 0, 800, 800, visible: false),
                       win("back", 300, 300, 400, 400)]
        XCTAssertFalse(SceneGeometry.isOccluded(windows, index: 1),
                       "a window the guest isn't showing covers nothing")
    }

    func testTheDesktopBackdropDoesNotOcclude() {
        // The Finder's full-screen desktop window is behind everything by
        // definition; treating it as an occluder would disable first-sight
        // capture for every window on the machine.
        let backdrop = win("Desktop", 0, 0, 800, 600, app: "Finder")
        let windows = [backdrop, win("doc", 100, 100, 200, 200)]
        XCTAssertFalse(SceneGeometry.isOccluded(windows, index: 1),
                       "the desktop backdrop must be ignored as an occluder")
    }

    func testADegenerateRectIsTreatedAsOccluded() {
        let windows = [win("empty", 50, 50, 50, 50)]
        XCTAssertTrue(SceneGeometry.isOccluded(windows, index: 0),
                      "a zero-area content rect has nothing worth capturing")
    }
}
