import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// The tab, end to end: what the guest's stream says, what `DrawnTabStrip`
/// makes of it, and what a person then sees.
///
/// ## The fixture is real, and that matters
///
/// `appearanceOps()` is the Mac OS 9.1 Appearance control panel's own tab
/// drawing, transcribed op for op and colour for colour out of sweep A pass 1
/// (`p1/panels/appearance.json`, port `0x203d61b0`, displayEpoch 4). Nothing
/// in it was invented, and the numbers it carries are the ones every claim in
/// `DrawnTabStrip` was derived from: six label boxes at y 10, the front one
/// three pixels taller, gaps of 24 between every neighbouring pair, and the
/// pane at y 31.
///
/// It is geometry and grey levels, not pixels: no part of Apple's artwork is
/// checked in here. The guest's actual SCREENDUMP — which is Apple's pixels —
/// stays in the private asset store, and `testAgainstTheGuestsOwnPixels`
/// skips without it.
@MainActor
final class PlatinumTabTests: XCTestCase {

    // MARK: - The capture, transcribed

    private func state(_ kind: String, _ rgb: [Int]) -> DisplayOp {
        var op = DisplayOp(op: "state", ticks: 0)
        op.kind = kind
        op.rgb = rgb
        return op
    }

    private func rect(_ verb: Int, _ r: [Int]) -> DisplayOp {
        var op = DisplayOp(op: "rect", ticks: 0)
        op.verb = verb
        op.rect = r
        return op
    }

    private func line(_ from: [Int], _ to: [Int]) -> DisplayOp {
        var op = DisplayOp(op: "line", ticks: 0)
        op.from = from
        op.to = to
        return op
    }

    private func text(_ s: String, at pen: [Int]) -> DisplayOp {
        var op = DisplayOp(op: "text", ticks: 0)
        op.text = s
        op.pen = pen
        op.font = 0
        op.size = 0
        op.len = s.count
        op.fullLen = s.count
        return op
    }

    private func grey(_ v: Int) -> [Int] { [v, v, v] }

    /// One tab exactly as `DrawThemeTab` emitted it: paint the label box,
    /// three lines across its top, then the title.
    private func tab(_ l: Int, _ r: Int, front: Bool,
                     title: String) -> [DisplayOp] {
        let t = 10
        let b = front ? 34 : 31
        return [
            state("fg", grey(front ? 0xEEEE : 0xCCCC)),
            rect(1, [l, t, r, b]),
            state("fg", grey(0)),
            line([l, t], [r, t]),
            state("fg", grey(0xCCCC)),
            line([l, t + 1], [r - 1, t + 1]),
            state("fg", grey(front ? 0xFFFF : 0xDDDD)),
            line([l, t + 2], [r - 1, t + 2]),
            state("fg", grey(0)),
            text(title, at: [l, 25]),
        ]
    }

    private func appearanceOps() -> [DisplayOp] {
        var ops: [DisplayOp] = [
            state("fg", grey(0)),
            state("bg", grey(0xDDDD)),
            rect(2, [-1, 10, 465, 311]),
            state("fg", grey(0xEEEE)),
            rect(1, [-1, 31, 465, 311]),
            state("fg", grey(0)),
            rect(0, [-1, 31, 465, 311]),
            state("fg", grey(0xCCCC)),
            line([0, 308], [0, 32]),
            line([0, 32], [462, 32]),
            state("fg", grey(0xFFFF)),
            line([1, 307], [1, 33]),
            line([1, 33], [461, 33]),
        ]
        ops += tab(16, 65, front: true, title: "Themes")
        ops += tab(89, 166, front: false, title: "Appearance")
        ops += tab(190, 224, front: false, title: "Fonts")
        ops += tab(248, 299, front: false, title: "Desktop")
        ops += tab(323, 362, front: false, title: "Sound")
        ops += tab(386, 434, front: false, title: "Options")
        return ops
    }

    // MARK: - Derivation

    func testTheAppearancePanelsSixTabsAreRead() throws {
        let strips = DrawnTabStrip.derive(from: appearanceOps())
        XCTAssertEqual(strips.count, 1, "one strip, at one top")
        let strip = try XCTUnwrap(strips.first)
        XCTAssertEqual(strip.tabs.count, 6)
        XCTAssertEqual(strip.tabs.map(\.title),
                       ["Themes", "Appearance", "Fonts", "Desktop", "Sound",
                        "Options"])
        XCTAssertEqual(strip.tabs.map(\.isFront),
                       [true, false, false, false, false, false])
    }

    /// The measurement this whole approach rests on: nothing in the stream
    /// names `kThemeMetricLargeTabCapsWidth`, but the gap between two
    /// neighbouring label boxes is two caps, so the metric falls out of the
    /// guest's own drawing. On this panel that is 24 / 2 = 12, and 12 is what
    /// the machine's pixels measure.
    func testTheCapsWidthIsMeasuredFromTheGapBetweenTabs() throws {
        let strip = try XCTUnwrap(DrawnTabStrip.derive(from: appearanceOps())
            .first)
        XCTAssertEqual(strip.capsWidth, 12)
        XCTAssertEqual(strip.tabHeight, 21, "kThemeLargeTabHeight")
        XCTAssertEqual(strip.paneTop, 31, "tab top + kThemeLargeTabHeight")
    }

    /// Every colour the drawer uses comes from the guest, so a machine on a
    /// different theme draws its own tab without anyone editing a constant.
    func testTheColoursComeFromTheStream() throws {
        let strip = try XCTUnwrap(DrawnTabStrip.derive(from: appearanceOps())
            .first)
        let front = try XCTUnwrap(strip.tabs.first { $0.isFront })
        let back = try XCTUnwrap(strip.tabs.first { !$0.isFront })
        XCTAssertEqual(front.face, [0xEEEE, 0xEEEE, 0xEEEE])
        XCTAssertEqual(back.face, [0xCCCC, 0xCCCC, 0xCCCC])
        XCTAssertEqual(front.topLines[0], [0, 0, 0], "the frame is black")
        XCTAssertEqual(front.topLines[2], [0xFFFF, 0xFFFF, 0xFFFF],
                       "the front tab's inner highlight is white")
        XCTAssertEqual(back.topLines[2], [0xDDDD, 0xDDDD, 0xDDDD],
                       "and a non-front tab's is one step lighter than CCCCCC")
    }

    // MARK: - The refusals

    /// A grid of same-height boxes is a common shape and calling it a tab
    /// strip is a strong claim. Each of these is a real thing a panel draws,
    /// and none of them may be read as tabs.
    func testThingsThatAreNotTabs() {
        // Boxes with no three-line top bevel: a row of plain filled rects.
        var plain: [DisplayOp] = [state("fg", grey(0xCCCC))]
        plain += [rect(1, [16, 10, 65, 31]), rect(1, [89, 10, 166, 31])]
        XCTAssertTrue(DrawnTabStrip.derive(from: plain).isEmpty,
                      "a fill with no bevel is not a tab")

        // Right height, right bevel, but the gaps disagree — so nothing
        // fixes what a cap is wide, and the strip must be refused.
        var uneven = tab(16, 65, front: false, title: "a")
        uneven += tab(89, 166, front: false, title: "b")
        uneven += tab(200, 240, front: false, title: "c")
        XCTAssertTrue(DrawnTabStrip.derive(from: uneven).isEmpty,
                      "unequal gaps leave the caps width unmeasurable")

        // A height no Appearance metric names.
        var wrongHeight: [DisplayOp] = []
        for (l, r) in [(16, 65), (89, 166)] {
            wrongHeight += [
                state("fg", grey(0xCCCC)), rect(1, [l, 10, r, 45]),
                state("fg", grey(0)), line([l, 10], [r, 10]),
                line([l, 11], [r - 1, 11]), line([l, 12], [r - 1, 12]),
            ]
        }
        XCTAssertTrue(DrawnTabStrip.derive(from: wrongHeight).isEmpty,
                      "35 is not kThemeSmallTabHeight or kThemeLargeTabHeight")

        // Two tabs both claiming to be front.
        var twoFronts = tab(16, 65, front: true, title: "a")
        twoFronts += tab(89, 166, front: true, title: "b")
        XCTAssertTrue(DrawnTabStrip.derive(from: twoFronts).isEmpty,
                      "at most one tab overlaps the pane")
    }

    // MARK: - Pixels

    /// Where the guest's content lands in a render, given the window rect
    /// below: `frame.l + 1` and `frame.t + Platinum.contentTop`.
    ///
    /// Chosen so the rendered content sits at the same screen coordinates the
    /// guest's own content did in the sweep-A screendump — world (0,0) at
    /// screen (166, 90) — which is what makes the comparison below a
    /// comparison of the TAB and not of the window chrome's placement.
    private let frame = Rect(l: 165, t: 68, r: 631, b: 400)

    private func appearanceScene() -> Scene {
        let window = Scene.Window(
            id: "0.36372482/Appearance#0", app: "Appearance",
            psn: "0.36372482", title: "Appearance", kind: 2000,
            rect: frame, front: true, z: 0, visible: true, controls: [],
            text: nil, items: nil, display: appearanceOps(), island: nil)
        return Scene(version: 0, seq: 1, source: "fixture", capturedAt: 0,
                     screen: .init(w: 800, h: 600), apps: [], processes: nil,
                     menubar: nil, windows: [window], desktopItems: nil,
                     meta: .init(errors: []))
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int)
        -> (Int, Int, Int) {
        guard let c = rep.colorAt(x: x, y: y) else { return (-1, -1, -1) }
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }

    /// The defect this whole file exists to close: the caps.
    ///
    /// Before `PlatinumTab`, the pixel below is background — the tab labels
    /// sat on flat grey with no outline anywhere (fidelity sweep 2026-08-07-a
    /// verdict 4, reproduced on three VMs and four guest builds). Comment out
    /// the tab pass in `DisplayReplay` and this fails.
    func testTheFrontTabsLeftCapIsDrawn() throws {
        let png = try RenderShot.png(scene: appearanceScene())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        // Halfway down the front tab's left cap: outside the label box
        // (which starts at screen x 182), inside the tab.
        let inCap = pixel(rep, 179, 112)
        XCTAssertGreaterThan(inCap.0, 200,
                             "the cap interior carries the tab's face, not background")
        // And the outline is dark somewhere on the slant to its left.
        let onSlant = (172...178).map { pixel(rep, $0, 112).0 }
        XCTAssertTrue(onSlant.contains { $0 < 128 },
                      "the slanted outline crosses this row: \(onSlant)")
    }

    /// The join. A front tab has no bottom edge — it opens into the pane —
    /// and the pane's own frame line stops at its caps and resumes after
    /// them. Getting this wrong is what makes a drawn tab look pasted on.
    func testTheFrontTabInterruptsThePaneLineAndTheOthersDoNot() throws {
        let png = try RenderShot.png(scene: appearanceScene())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let paneRow = 90 + 31          // world y 31
        let underFront = pixel(rep, 205, paneRow)
        XCTAssertGreaterThan(underFront.0, 200,
                             "no frame line under the front tab")
        let underBack = pixel(rep, 300, paneRow)
        XCTAssertLessThan(underBack.0, 128,
                          "but the pane's line is there under a non-front tab")
    }

    /// The tab pass must not repaint the title the replay already drew.
    func testTheTitleSurvives() throws {
        let png = try RenderShot.png(scene: appearanceScene())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        // "Themes" is drawn from screen x 182, baseline y 115.
        let inked = (183...228).contains { x in
            (106...115).contains { y in pixel(rep, x, y).0 < 100 }
        }
        XCTAssertTrue(inked, "the front tab's title is still on the canvas")
    }

    /// The honest measurement: this render against the machine's own pixels.
    ///
    /// Opt-in, because the reference is a QMP screendump of Mac OS 9 and
    /// Apple's pixels do not live in this repository. Point
    /// `NOW_TAB_REFERENCE` at `sweep-2026-08-07-a/p1/panels/appearance-guest.ppm`
    /// in the private asset store. It REPORTS rather than asserts a
    /// threshold: the caps are anti-aliased by Core Graphics here and by a
    /// prepared stencil there, so a per-pixel equality gate would fail for a
    /// reason that is not a defect. The number belongs in a document, and
    /// `docs/deriving-a-drawn-procedure.md` is where it is.
    func testAgainstTheGuestsOwnPixels() throws {
        guard let path = ProcessInfo.processInfo
            .environment["NOW_TAB_REFERENCE"] else {
            throw XCTSkip("set NOW_TAB_REFERENCE to the guest screendump")
        }
        let guest = try Self.ppm(at: path)
        let png = try RenderShot.png(scene: appearanceScene())
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        if let out = ProcessInfo.processInfo.environment["NOW_TAB_RENDER_OUT"] {
            try png.write(to: URL(fileURLWithPath: out))
        }

        // The tab strip in screen coordinates: the whole row of tabs plus
        // three rows of the pane below them. World (0,0) is screen (166, 90),
        // so this is world y 9…36 — the row of tabs, the pane's frame and
        // its two bevel rows.
        let (x0, y0, x1, y1) = (166, 99, 620, 126)
        // The label boxes, in the same screen coordinates. Reported
        // separately because what is inside them is the FONT's fidelity, not
        // the tab's: the pack carries no Charcoal strike, so every title
        // renders in Chicago, which is wider (docs/render-composition.md).
        // Mixing the two would let a font gap be read as a chrome one.
        let labels = [(182, 231), (255, 332), (356, 390), (414, 465),
                      (489, 528), (552, 600)]
        func inLabel(_ x: Int) -> Bool {
            labels.contains { x >= $0.0 && x < $0.1 }
        }

        var all: [Int] = [], chrome: [Int] = []
        var allExact = 0, chromeExact = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let a = pixel(rep, x, y)
                let b = guest.pixel(x, y)
                let d = max(abs(a.0 - b.0), max(abs(a.1 - b.1),
                                                abs(a.2 - b.2)))
                all.append(d)
                if d == 0 { allExact += 1 }
                if !inLabel(x) {
                    chrome.append(d)
                    if d == 0 { chromeExact += 1 }
                }
            }
        }
        func report(_ name: String, _ d: [Int], _ exact: Int) {
            let s = d.sorted()
            print("### TAB-DELTA \(name) n=\(s.count) exact=\(exact) "
                + "(\(String(format: "%.1f", 100.0 * Double(exact) / Double(s.count)))%) "
                + "p50=\(s[s.count / 2]) "
                + "p95=\(s[Int(Double(s.count) * 0.95)]) "
                + "max=\(s.last ?? 0)")
        }
        report("strip", all, allExact)
        report("chrome-only", chrome, chromeExact)

        /* THE GEOMETRY CLAIM, ASSERTED RATHER THAN REPORTED. The residual
           above is anti-aliasing: Apple composites a prepared stencil down
           the slant and Core Graphics blends its own. What must NOT differ
           is WHERE the slant is, and that is checkable — the darkest column
           in each row of a cap. If the caps width, the corner or the slope
           were wrong this drifts immediately, and a percentage would have
           hidden it. */
        var offBy: [Int] = []
        for y in 102...120 {
            // The leftmost dark column, which on these rows is the outline
            // and nothing else — the title starts at x 182.
            guard let mine = (168...181).first(where: { pixel(rep, $0, y).0 < 110 }),
                  let theirs = (168...181).first(where: { guest.pixel($0, y).0 < 110 })
            else { continue }
            offBy.append(abs(mine - theirs))
        }
        XCTAssertEqual(offBy.count, 19, "every row of the cap was found")
        XCTAssertLessThanOrEqual(offBy.max() ?? 99, 1,
            "the front tab's left slant sits where the machine draws it: \(offBy)")
        // 13 of the 19 rows land on the machine's own column and the other
        // six are one pixel out — measured 2026-08-07. The bound is the
        // measurement plus room for a rounding change, not a target.
        XCTAssertLessThanOrEqual(offBy.filter { $0 > 0 }.count, 8,
            "and lands exactly on most of them: \(offBy)")
    }

    struct PPM {
        let width: Int, height: Int, bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return (-1, -1, -1) }
            let i = (y * width + x) * 3
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
    }

    static func ppm(at path: String) throws -> PPM {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var i = 0
        func token() -> String {
            while i < data.count, data[i] == 0x20 || data[i] == 0x0A
                || data[i] == 0x0D || data[i] == 0x09 { i += 1 }
            var out = ""
            while i < data.count, !(data[i] == 0x20 || data[i] == 0x0A
                || data[i] == 0x0D || data[i] == 0x09) {
                out.append(Character(UnicodeScalar(data[i]))); i += 1
            }
            return out
        }
        guard token() == "P6" else { throw XCTSkip("not a binary PPM") }
        let w = Int(token()) ?? 0
        let h = Int(token()) ?? 0
        _ = token()
        i += 1
        return PPM(width: w, height: h, bytes: [UInt8](data[i...]))
    }
}
