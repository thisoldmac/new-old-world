import Foundation

/// Derives a **Platinum tab strip** — the tabs, which one is front, the pane
/// they sit on, and the metrics the Appearance Manager drew them with — out of
/// a window's own drawing stream.
///
/// ## Why this exists, and why it is not "extract the tab bitmap"
///
/// There is no tab bitmap to extract. `docs/asset-extraction-offline.md`
/// opened `Apple platinum` (876 KB) and found `clut`/`scen`/`tvar`/`tthm`
/// parameters and not one pixel of window furniture: `DrawThemeTab` draws
/// procedurally. So the tab has to be DRAWN host-side, and the only question
/// worth arguing about is where its numbers come from.
///
/// They come from the guest. `DrawThemeTab` leaks most of itself through the
/// QuickDraw bottlenecks: for every tab it paints the label box, strokes three
/// horizontal lines across the top of it, and draws the title. What it does
/// NOT leak is the two slanted end caps and the black outline down their
/// edges — those go down a route the bottlenecks do not see, which is why the
/// mirror has rendered tab labels floating on flat grey since the panels were
/// first captured (`docs/fidelity-sweep-2026-08-07-a.md` verdict 4, three
/// independent reproductions).
///
/// This type reads the part that DID arrive and recovers the rest from it.
/// Everything the drawer needs is derived, not chosen:
///
/// | quantity | how it is known |
/// |---|---|
/// | tab boxes | the guest's own paint rects |
/// | which tab is front | it is the taller one — it overlaps the pane |
/// | face colour, per state | the fg colour at that paint |
/// | the three top-bevel colours | the fg colour at each of the three lines |
/// | pane top | tab top + the non-front tabs' height |
/// | **caps width** | **half the gap between two neighbouring tabs** |
///
/// That last row is the load-bearing one. `kThemeMetricLargeTabCapsWidth` is a
/// real Appearance metric and nothing in the stream names it — but the gap
/// between adjacent label boxes is exactly two caps, because the caps of
/// neighbouring tabs are what fills it. On the Appearance panel all five gaps
/// measure 24 and the caps measure 12 in the guest's own pixels. So the metric
/// is *measured from the guest's drawing*, per capture, and a machine with a
/// different theme reports its own number without anyone editing a constant.
///
/// ## Where it sits in the pipeline
///
/// This is `DrawnCellGrid`'s move, and it follows that file's two rules
/// (`docs/render-composition.md`, "P2 derived from P3's own evidence"):
/// the derivation lives in the renderer-free core, and the drawer paints
/// **only the difference between what P3 said and what we know** — the caps,
/// the outline, and the join where the front tab interrupts the pane's top
/// line. The label box, its bevel and its title stay the replay's, drawn from
/// the guest's own ops.
///
/// ## Header constants, and why they are a gate rather than a source
///
/// Universal Interfaces `Appearance.h` (Mac OS 9) states
/// `kThemeLargeTabHeight = 21`, `kThemeSmallTabHeight = 16`,
/// `kThemeTabPaneOverlap = 3`, `kThemeLargeTabHeightMax = 24`. The Appearance
/// panel's non-front tabs are 21 high and its front tab 24 — the header's
/// numbers exactly. They are used here as an ACCEPTANCE TEST, not as the
/// values: a run of same-height paint rects is a common enough shape that
/// claiming "these are tabs" needs a reason, and matching a named platform
/// metric is one. The heights themselves still come from the stream, so a
/// machine that answers `GetThemeMetric` differently (plan 016 P2) draws its
/// own tabs — `Metrics` is the seam where that answer replaces this default.
public enum DrawnTabStrip {

    /// The heights a run of boxes must match before it may be called a tab
    /// strip, and the pane overlap that identifies the front one.
    ///
    /// Defaults are Universal Interfaces `Appearance.h` on the CarbonLib 1.6
    /// floor. The named `GetThemeMetric` selectors that replace them are
    /// `kThemeMetricLargeTabHeight` (10), `kThemeMetricSmallTabHeight` (15)
    /// and `kThemeMetricTabFrameOverlap` (12) — plan 016 P2's query pass.
    public struct Metrics: Equatable, Sendable {
        /// `kThemeSmallTabHeight` / `kThemeLargeTabHeight`.
        public var tabHeights: [Int]
        /// `kThemeTabPaneOverlap` — how far the front tab reaches into the
        /// pane, which is also how many bevel lines its top carries.
        public var paneOverlap: Int
        /// The range a derived `kThemeMetricLargeTabCapsWidth` must fall in.
        /// Not a value: the caps width is measured per capture. This only
        /// stops a run of evenly-spaced boxes 200 px apart being read as tabs.
        public var capsWidthRange: ClosedRange<Int>

        public init(tabHeights: [Int] = [16, 21],
                    paneOverlap: Int = 3,
                    capsWidthRange: ClosedRange<Int> = 4...20) {
            self.tabHeights = tabHeights
            self.paneOverlap = paneOverlap
            self.capsWidthRange = capsWidthRange
        }

        public static let appearanceManager = Metrics()
    }

    /// One tab. `labelRect` is the guest's own paint rect in port-local
    /// coordinates — the box the title sits in, NOT the tab's outline, which
    /// is `capsWidth` wider on each side.
    public struct Tab: Equatable, Sendable {
        public var index: Int
        public var labelRect: Rect
        /// The title, when a text op landed inside this tab. `nil` is "the
        /// stream did not say", never "untitled".
        public var title: String?
        /// True for the tab that overlaps the pane. At most one is front; a
        /// strip where none does reports `false` everywhere rather than
        /// guessing the first.
        public var isFront: Bool
        /// The fg colour of the paint that filled this tab, as the guest sent
        /// it: `[r, g, b]`, 0–65535 per channel.
        public var face: [Int]?
        /// The fg colours of the three lines across the tab's top, in the
        /// order the guest drew them: frame, then two bevel rows. The last is
        /// the inner highlight the caps continue — white on the front tab,
        /// one step lighter than the face on the others.
        public var topLines: [[Int]?]

        public init(index: Int, labelRect: Rect, title: String?,
                    isFront: Bool, face: [Int]?, topLines: [[Int]?]) {
            self.index = index
            self.labelRect = labelRect
            self.title = title
            self.isFront = isFront
            self.face = face
            self.topLines = topLines
        }
    }

    /// A row of tabs and the pane under them.
    public struct Strip: Equatable, Sendable {
        public var tabs: [Tab]
        /// Port-local y of the pane's own top frame line: the tabs' top plus
        /// the non-front tabs' height.
        public var paneTop: Int
        /// `kThemeMetricLargeTabCapsWidth`, measured as half the gap between
        /// neighbours in THIS capture.
        public var capsWidth: Int
        /// The non-front tabs' height — one of `Metrics.tabHeights`.
        public var tabHeight: Int

        public init(tabs: [Tab], paneTop: Int, capsWidth: Int, tabHeight: Int) {
            self.tabs = tabs
            self.paneTop = paneTop
            self.capsWidth = capsWidth
            self.tabHeight = tabHeight
        }
    }

    // MARK: - Derivation

    /// Reads every tab strip in one port's op stream.
    ///
    /// Ops are taken in guest order; `state`/`origin` is honoured so the rects
    /// are in the same content-local space `Scene.Control.rect` uses.
    public static func derive(from ops: [DisplayOp],
                              metrics: Metrics = .appearanceManager) -> [Strip] {
        let candidates = self.candidates(in: ops)
        guard candidates.count >= 2 else { return [] }

        var byTop: [Int: [Candidate]] = [:]
        for c in candidates { byTop[c.rect.t, default: []].append(c) }

        var strips: [Strip] = []
        for (_, group) in byTop.sorted(by: { $0.key < $1.key }) {
            if let strip = self.strip(from: group, metrics: metrics) {
                strips.append(strip)
            }
        }
        return strips
    }

    /// A paint rect that carries a tab's three-line top bevel.
    struct Candidate {
        var rect: Rect
        var face: [Int]?
        var topLines: [[Int]?]
        var title: String?
    }

    static func candidates(in ops: [DisplayOp]) -> [Candidate] {
        var out: [Candidate] = []
        var fg: [Int]?
        var originH = 0, originV = 0
        var i = 0

        func local(_ r: [Int]) -> Rect {
            Rect(l: r[0] - originH, t: r[1] - originV,
                 r: r[2] - originH, b: r[3] - originV)
        }

        while i < ops.count {
            let op = ops[i]
            if op.op == "state" {
                switch op.kind {
                case "fg": fg = op.rgb
                case "origin":
                    if let o = op.origin, o.count == 2 { originH = o[0]; originV = o[1] }
                default: break
                }
                i += 1
                continue
            }
            guard op.op == "rect", op.verb == 1,
                  let r = op.rect, r.count == 4 else { i += 1; continue }
            let box = local(r)
            guard box.width > 4, box.height > 4 else { i += 1; continue }

            // The three lines across the top, skipping the state ops that
            // colour them. Anything else between them and the paint means
            // this rect is not a tab.
            var lines: [[Int]?] = []
            var lineFG = fg
            var j = i + 1
            while j < ops.count, lines.count < 3 {
                let next = ops[j]
                if next.op == "state" {
                    if next.kind == "fg" { lineFG = next.rgb }
                    j += 1
                    continue
                }
                guard next.op == "line",
                      let f = next.from, let t = next.to,
                      f.count == 2, t.count == 2 else { break }
                let row = box.t + lines.count
                // Row `n` spans the box's own width. The guest draws the
                // frame line full width and the two bevel rows one short,
                // so the right end is allowed to fall one inside.
                guard f[1] - originV == row, t[1] - originV == row,
                      f[0] - originH == box.l,
                      t[0] - originH >= box.r - 1, t[0] - originH <= box.r
                else { break }
                lines.append(lineFG)
                j += 1
            }
            guard lines.count == 3 else { i += 1; continue }

            // The title, if the next drawing op is text inside the box.
            var title: String?
            var k = j
            while k < ops.count {
                let next = ops[k]
                if next.op == "state" { k += 1; continue }
                if next.op == "text", let s = next.text, !s.isEmpty,
                   let p = next.pen, p.count == 2 {
                    let v = p[1] - originV
                    let h = p[0] - originH
                    if v > box.t, v <= box.b, h >= box.l, h < box.r { title = s }
                }
                break
            }

            out.append(Candidate(rect: box, face: fg, topLines: lines,
                                 title: title))
            i = j
        }
        return out
    }

    static func strip(from group: [Candidate], metrics: Metrics) -> Strip? {
        guard group.count >= 2 else { return nil }
        let sorted = group.sorted { $0.rect.l < $1.rect.l }

        // Every gap between neighbours must be the same, and even: it is two
        // caps wide, one from each tab.
        var gaps: [Int] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            gaps.append(b.rect.l - a.rect.r)
        }
        guard let gap = gaps.first, gaps.allSatisfy({ $0 == gap }),
              gap > 0, gap % 2 == 0 else { return nil }
        let capsWidth = gap / 2
        guard metrics.capsWidthRange.contains(capsWidth) else { return nil }

        // Heights: the non-front tabs agree, and the front one (if any) is
        // exactly `paneOverlap` taller because it reaches into the pane.
        let heights = Set(sorted.map(\.rect.height))
        guard heights.count <= 2, let base = heights.min() else { return nil }
        guard metrics.tabHeights.contains(base) else { return nil }
        var frontHeight: Int?
        if heights.count == 2 {
            guard let tall = heights.max(),
                  tall - base == metrics.paneOverlap else { return nil }
            // Exactly one tab may be front.
            guard sorted.filter({ $0.rect.height == tall }).count == 1 else {
                return nil
            }
            frontHeight = tall
        }

        let top = sorted[0].rect.t
        let tabs = sorted.enumerated().map { i, c in
            Tab(index: i, labelRect: c.rect, title: c.title,
                isFront: frontHeight != nil && c.rect.height == frontHeight,
                face: c.face, topLines: c.topLines)
        }
        return Strip(tabs: tabs, paneTop: top + base,
                     capsWidth: capsWidth, tabHeight: base)
    }
}
