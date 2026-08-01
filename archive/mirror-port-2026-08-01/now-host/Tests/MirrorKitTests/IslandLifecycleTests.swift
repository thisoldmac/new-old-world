import XCTest
@testable import MirrorKit

/// The island focus lifecycle: a window keeps its last captured interior when
/// it is not frontmost, only the front window re-captures, and the cache does
/// not grow forever. Pure host state — no guest, no wire.
final class IslandLifecycleTests: XCTestCase {

    // MARK: - Fixtures

    private func window(psn: String, title: String, z: Int, front: Bool,
                        rect: Rect = Rect(l: 10, t: 40, r: 210, b: 140))
        -> Scene.Window {
        Scene.Window(id: "\(psn)/\(title)#\(z)", app: "App\(psn)", psn: psn,
                     title: title, kind: 0, rect: rect, front: front, z: z,
                     visible: true, controls: [], text: nil, items: nil,
                     display: nil, island: nil)
    }

    private func scene(_ windows: [Scene.Window]) -> Scene {
        Scene(version: 0, seq: 1, source: "mock", capturedAt: 0,
              screen: .init(w: 800, h: 600),
              apps: [], processes: nil, menubar: nil, windows: windows,
              desktopItems: nil, meta: .init(errors: []))
    }

    private func island(w: Int, h: Int, fill: UInt8) -> PixelIsland {
        PixelIsland(width: w, height: h,
                    rgba: Data([UInt8](repeating: fill, count: w * h * 4)),
                    originX: 0, originY: 0, scale: 1)
    }

    /// The policy, with no machine behind it.
    ///
    /// It used to be a `ScenePoller` aimed at a closed port, which worked
    /// because `WireClient` connected lazily — a test that depended on the
    /// transport failing to prove the transport was not used. The fetch is
    /// now a closure, so "no capture rode this poll" is asserted directly:
    /// `CaptureSpy` records every rect it was asked for, and the assertion
    /// names them.
    private func islands() -> SceneIslands { SceneIslands() }

    /// A capture that must not happen. Records the call so the assertion
    /// names the rect that was asked for rather than just failing.
    private final class CaptureSpy {
        private(set) var asked: [Rect] = []
        func capture(_ rect: Rect) throws -> PixelIsland {
            asked.append(rect)
            throw PixelIslandError.badReply("no machine in this test")
        }
    }

    // MARK: - Keying

    /// The bug this guards: `win.id` ends in the window's index in its app's
    /// window list, which the guest emits in z-order (`mirrorverbs.c` walks the
    /// WindowList front-first and writes `z = window_count`). Raising the back
    /// document of a two-window app swaps both ids — so an id-keyed cache misses
    /// on every raise, which is exactly when the held pixels are needed.
    func testCacheKeySurvivesARaiseThatRenumbersWindowIDs() {
        let before = [window(psn: "1.2", title: "Notes", z: 0, front: true),
                      window(psn: "1.2", title: "Budget", z: 1, front: false)]
        let after = [window(psn: "1.2", title: "Budget", z: 0, front: true),
                     window(psn: "1.2", title: "Notes", z: 1, front: false)]

        // The ids DID change (this is the hazard, asserted, not assumed).
        XCTAssertNotEqual(before[0].id, after[1].id)
        XCTAssertEqual(before[0].id, "1.2/Notes#0")
        XCTAssertEqual(after[1].id, "1.2/Notes#1")

        // The cache keys did not: Notes keeps its key, in either order.
        let keysBefore = IslandStore.keys(for: before)
        let keysAfter = IslandStore.keys(for: after)
        XCTAssertEqual(keysBefore[0], keysAfter[1])   // Notes
        XCTAssertEqual(keysBefore[1], keysAfter[0])   // Budget
    }

    /// A moved window keeps its pixels — moving does not change the content.
    func testCacheKeySurvivesAMove() {
        let a = window(psn: "1.2", title: "Notes", z: 0, front: false)
        var b = a
        b.rect = Rect(l: 300, t: 200, r: 500, b: 300)
        XCTAssertEqual(IslandStore.keys(for: [a]), IslandStore.keys(for: [b]))
    }

    /// Two same-titled windows in one app must not share one island. They are
    /// separated by corner, which is stable across a raise (unlike z-order).
    func testSameTitledWindowsGetDistinctStableKeys() {
        let one = window(psn: "1.2", title: "untitled", z: 0, front: true)
        var two = window(psn: "1.2", title: "untitled", z: 1, front: false)
        two.rect = Rect(l: 60, t: 90, r: 260, b: 190)
        let keys = IslandStore.keys(for: [one, two])
        XCTAssertNotEqual(keys[0], keys[1])
        // Raise the second: same two keys, swapped positions.
        var raisedOne = one; raisedOne.front = false; raisedOne.z = 1
        var raisedTwo = two; raisedTwo.front = true; raisedTwo.z = 0
        let after = IslandStore.keys(for: [raisedTwo, raisedOne])
        XCTAssertEqual(Set(keys), Set(after))
    }

    // MARK: - Attach

    /// The change: a window that is not frontmost gets its held pixels back
    /// instead of nothing, and the front window reuses its own cached island
    /// when the content signature is unchanged (no capture, no wire).
    func testUnfocusedWindowsKeepTheirLastCapturedInterior() async {
        var p = islands()
        let spy = CaptureSpy()
        let front = window(psn: "1.2", title: "Notes", z: 0, front: true)
        let back = window(psn: "3.4", title: "Budget", z: 1, front: false)
        let backdrop = window(psn: "5.6", title: "Nothing", z: 2, front: false)
        var s = scene([front, back, backdrop])
        let keys = IslandStore.keys(for: s.windows)

        // Seed: both the front and the back window have been captured before.
        let content = SceneGeometry.contentRect(front)
        p.islands.pixels[keys[0]] = island(w: 4, h: 4, fill: 1)
        p.islands.contentKey[keys[0]] =
            "\(content.l),\(content.t),\(content.r),\(content.b)@0"
        p.islands.pixels[keys[1]] = island(w: 4, h: 4, fill: 2)

        await p.attach(&s, poll: 1, capture: spy.capture)

        XCTAssertEqual(s.windows[0].island?.rgba.first, 1,
                       "front window reuses its cached island unchanged")
        XCTAssertEqual(s.windows[1].island?.rgba.first, 2,
                       "an unfocused window keeps its last captured interior")
        XCTAssertNil(s.windows[2].island,
                     "a window never captured has no pixels to invent")
        XCTAssertEqual(p.bytesFetched, 0, "no capture rode this poll")
        XCTAssertEqual(spy.asked, [], """
            a capture was attempted: \(spy.asked). The front window's \
            content signature was unchanged and the other two are held or \
            occluded, so this poll must touch no machine at all.
            """)
    }

    /// Stale geometry: a window resized while unfocused still gets its pixels
    /// (the renderer clips them at the content rect). Never blank, never scaled.
    func testResizedUnfocusedWindowStillGetsItsPixels() async {
        var p = islands()
        let spy = CaptureSpy()
        var back = window(psn: "3.4", title: "Budget", z: 1, front: false)
        let key = IslandStore.keys(for: [back])[0]
        p.islands.pixels[key] = island(w: 200, h: 100, fill: 7)
        back.rect = Rect(l: 10, t: 40, r: 90, b: 300)   // narrower and taller
        var s = scene([back])
        await p.attach(&s, poll: 1, capture: spy.capture)
        XCTAssertEqual(s.windows[0].island?.width, 200,
                       "held at capture size — clipped by the renderer, not scaled")
    }

    // MARK: - Eviction

    func testClosedWindowsAreEvictedAfterTheGracePeriod() {
        var store = IslandStore()
        store.gracePolls = 3
        store.pixels["gone"] = island(w: 2, h: 2, fill: 1)
        store.pixels["live"] = island(w: 2, h: 2, fill: 2)
        store.touch(["gone", "live"], seq: 1)

        // Within the grace window a missing window keeps its pixels: an app
        // whose oracle read errors for a frame must not lose its interior.
        store.touch(["live"], seq: 3)
        store.evict(living: ["live"], seq: 3)
        XCTAssertEqual(store.heldKeys, ["gone", "live"])

        // Past it, the entry is dropped from every dictionary.
        store.touch(["live"], seq: 4)
        store.evict(living: ["live"], seq: 4)
        XCTAssertEqual(store.heldKeys, ["live"])
        XCTAssertNil(store.seen["gone"])
        XCTAssertNil(store.contentKey["gone"])
        XCTAssertNil(store.tick["gone"])
    }

    /// A long session opening and closing windows must not accumulate islands.
    func testCacheStaysBoundedOverManyWindowGenerations() async {
        var p = islands()
        let spy = CaptureSpy()
        p.gracePolls = 2
        for generation in 0..<20 {
            var s = scene([window(psn: "1.\(generation)",
                                  title: "doc\(generation)", z: 0,
                                  front: false)])
            let key = IslandStore.keys(for: s.windows)[0]
            await p.attach(&s, poll: generation + 1, capture: spy.capture)
            p.islands.pixels[key] = island(w: 2, h: 2, fill: 1)  // as if captured
        }
        XCTAssertLessThanOrEqual(p.islands.heldKeys.count, 3,
                                 "islands: \(p.islands.heldKeys)")
    }
}
