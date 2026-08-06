import Foundation

/// Derives a REPEATED-CELL GRID out of a window's drawing stream: the cells'
/// positions, their identity within the grid, and — where the art itself
/// says so — which one is selected.
///
/// **Why this is not in the replay.** A grid of cells with hit rects and a
/// selected index is semantic knowledge (P2), not a drawing rule (P3): it
/// says what the region IS, not what was painted there. `DisplayReplay`
/// already accumulated two placeholder heuristics by accident, and
/// `docs/render-composition.md` exists to stop exactly that drift. So the
/// derivation lives here, in the renderer-free core beside `Scene.Control`
/// and `HitTester` — the two things a derived grid must feed — and the
/// renderer only ever sees ordinary typed controls.
///
/// **The idiom it reads, measured 2026-08-06 on Sherlock 2** (open-issues,
/// "Sherlock's channel grid is fully derivable without pixels"): the
/// application does NOT blit each cell to its own rectangle. It moves the
/// PORT ORIGIN and blits every cell to one constant destination —
/// `(0,0,51,46)` for Sherlock's channel wells. The grid is therefore in the
/// `state`/`origin` ops preceding each blit, and a reader that looks at
/// destination rectangles alone sees sixteen blits stacked in one corner.
///
/// Two consequences the code below turns into rules:
///
/// - A CANDIDATE is a set of blits sharing one literal destination rect,
///   placed at distinct screen positions by the origin. That is the
///   signature of the idiom, and nothing else in a capture looks like it.
/// - SELECTION IS IN THE SOURCE RECT. Sherlock's selected well comes from
///   one region of its sprite sheet and its fifteen unselected siblings
///   from another, so the odd-one-out source names the selected cell with
///   no pixels involved. That inference is deliberately narrow: exactly two
///   distinct sources, exactly one cell holding the minority. Anything else
///   claims no selection rather than guessing one, because "cell 3 is
///   selected" is a strong claim and a wrong one reads as a broken mirror.
///
/// Nothing here knows what a cell MEANS. The channel names are not in the
/// bottlenecks — the icon pixels come from resources by a route the stream
/// does not show — so a derived cell is titleless on purpose.
public enum DrawnCellGrid {

    /// One cell, in the same content-local coordinates as `Scene.Control.rect`.
    public struct Cell: Equatable, Sendable {
        /// Reading order within the grid: row-major, zero-based.
        public var index: Int
        public var row: Int
        public var column: Int
        public var rect: Rect
        /// True only where the art distinguished this cell from its
        /// siblings. `false` is "not shown as selected", never "unknown":
        /// a grid whose selection could not be read reports `selected`
        /// nowhere and sets `selectionKnown` false.
        public var selected: Bool

        public init(index: Int, row: Int, column: Int, rect: Rect,
                    selected: Bool) {
            self.index = index
            self.row = row
            self.column = column
            self.rect = rect
            self.selected = selected
        }
    }

    public struct Grid: Equatable, Sendable {
        public var cells: [Cell]
        public var rows: Int
        public var columns: Int
        /// Whether the source-rect inference produced a selected cell.
        public var selectionKnown: Bool
        /// The union of every cell, useful as the grid's own region.
        public var bounds: Rect

        public init(cells: [Cell], rows: Int, columns: Int,
                    selectionKnown: Bool, bounds: Rect) {
            self.cells = cells
            self.rows = rows
            self.columns = columns
            self.selectionKnown = selectionKnown
            self.bounds = bounds
        }
    }

    /// A grid must be a grid, not two things that happen to line up.
    static let minimumCells = 4
    /// Below this a "cell" is a list-row icon or a scrollbar arrow, and the
    /// repeated-blit signature stops meaning a picker.
    static let minimumCellSide = 20
    /// Positions are exact arithmetic on the guest's own integers, so the
    /// lattice tolerance is zero. It is named rather than inlined because
    /// a future producer that interpolates would need to relax it, and
    /// that would be a decision, not a tweak.
    static let latticeTolerance = 0

    /// Every repeated-cell grid in one window's composed display list.
    ///
    /// `ops` are the ops the renderer will draw — post-join, in window
    /// content coordinates — so the rects come out ready to be a
    /// `Scene.Control.rect` and a `HitTester` target.
    public static func derive(from ops: [DisplayOp]) -> [Grid] {
        var originH = 0
        var originV = 0
        /// Keyed by the LITERAL destination rect, which is what the idiom
        /// holds constant.
        var candidates: [[Int]: [Placed]] = [:]
        var order: [[Int]] = []

        for op in ops {
            if op.op == "state" {
                if op.kind == "origin", let o = op.origin, o.count == 2 {
                    originH = o[0]
                    originV = o[1]
                }
                continue
            }
            guard op.op == "bits", let dst = op.dst, dst.count == 4,
                  let src = op.src, src.count == 4 else { continue }
            let rect = Rect(l: dst[0] - originH, t: dst[1] - originV,
                            r: dst[2] - originH, b: dst[3] - originV)
            guard rect.width >= minimumCellSide,
                  rect.height >= minimumCellSide else { continue }
            if candidates[dst] == nil {
                candidates[dst] = []
                order.append(dst)
            }
            candidates[dst]!.append(Placed(rect: rect, source: src))
        }

        var grids: [Grid] = []
        for dst in order {
            guard let placed = candidates[dst],
                  let grid = lattice(placed) else { continue }
            grids.append(grid)
        }
        /* An INNER lattice is the outer one's content, not a second grid.
           Sherlock blits a 32×32 channel icon inside every well, under the
           same origins, so the icons form a perfectly good lattice of
           their own — and reporting it would put a second, smaller
           targetable control inside each cell. The enclosing cell is the
           control; what it contains is its picture. */
        return grids.filter { grid in
            !grids.contains { other in
                other != grid && encloses(other, grid)
            }
        }
    }

    private struct Placed: Equatable {
        var rect: Rect
        var source: [Int]
    }

    /// Whether every cell of `inner` sits inside some cell of `outer`.
    private static func encloses(_ outer: Grid, _ inner: Grid) -> Bool {
        guard outer.cells.count >= inner.cells.count else { return false }
        return inner.cells.allSatisfy { cell in
            outer.cells.contains { contains($0.rect, cell.rect) }
        }
    }

    private static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.l >= outer.l && inner.t >= outer.t
            && inner.r <= outer.r && inner.b <= outer.b
    }

    /// Turn one constant-destination candidate into a grid, or refuse.
    private static func lattice(_ placed: [Placed]) -> Grid? {
        /* One repaint may draw the same grid more than once — the fixture
           that measured this carries two — so a position seen twice is the
           SAME cell, and the LAST drawing of it is the current one. */
        var latest: [String: Placed] = [:]
        var seen: [String] = []
        for item in placed {
            let key = "\(item.rect.l),\(item.rect.t)"
            if latest[key] == nil { seen.append(key) }
            latest[key] = item
        }
        let cellsUnordered = seen.compactMap { latest[$0] }
        guard cellsUnordered.count >= minimumCells else { return nil }

        let columnsAt = Set(cellsUnordered.map(\.rect.l)).sorted()
        let rowsAt = Set(cellsUnordered.map(\.rect.t)).sorted()
        guard columnsAt.count >= 2 || rowsAt.count >= 2 else { return nil }
        guard evenlySpaced(columnsAt), evenlySpaced(rowsAt) else { return nil }
        /* A LATTICE IS FULL, and refusing a partial one is what keeps this
           from typing an accidental alignment as a picker: eight columns
           and two rows must be sixteen cells, all present, all the same
           size. */
        guard cellsUnordered.count == columnsAt.count * rowsAt.count else {
            return nil
        }
        let size = cellsUnordered[0].rect
        guard cellsUnordered.allSatisfy({
            $0.rect.width == size.width && $0.rect.height == size.height
        }) else { return nil }

        /* The odd source out is the selected cell. Anything but a clean
           majority/minority split of exactly two sources says nothing. */
        var bySource: [String: [Placed]] = [:]
        for item in cellsUnordered {
            bySource[item.source.map(String.init).joined(separator: ","),
                     default: []].append(item)
        }
        var selectedKey: String?
        if bySource.count == 2,
           let minority = bySource.first(where: { $0.value.count == 1 }),
           bySource.values.contains(where: { $0.count == cellsUnordered.count - 1 }) {
            selectedKey = "\(minority.value[0].rect.l),\(minority.value[0].rect.t)"
        }

        var cells: [Cell] = []
        var index = 0
        for (row, top) in rowsAt.enumerated() {
            for (column, left) in columnsAt.enumerated() {
                guard let item = latest["\(left),\(top)"] else { return nil }
                cells.append(Cell(index: index, row: row, column: column,
                                  rect: item.rect,
                                  selected: "\(left),\(top)" == selectedKey))
                index += 1
            }
        }
        let bounds = Rect(l: columnsAt[0], t: rowsAt[0],
                          r: columnsAt[columnsAt.count - 1] + size.width,
                          b: rowsAt[rowsAt.count - 1] + size.height)
        return Grid(cells: cells, rows: rowsAt.count,
                    columns: columnsAt.count,
                    selectionKnown: selectedKey != nil, bounds: bounds)
    }

    private static func evenlySpaced(_ values: [Int]) -> Bool {
        guard values.count > 2 else { return true }
        let pitch = values[1] - values[0]
        guard pitch > 0 else { return false }
        for i in 1..<values.count where
            abs((values[i] - values[i - 1]) - pitch) > latticeTolerance {
            return false
        }
        return true
    }
}

extension DrawnCellGrid {

    /// The semantic kind a derived cell carries.
    ///
    /// It is deliberately a name no guest probe emits. A cell's evidence is
    /// the application's own drawing, not a ControlRecord, and typing it as
    /// `imageWell` or `pushButton` would put a derived claim into the same
    /// vocabulary as a proven one — which is the direction that reads as a
    /// broken mirror when it is wrong.
    public static let cellKind = "drawnCell"
    /// Marks a control this file derived, so a reader can tell it apart from
    /// anything the guest reported. It is not "presentation-inference" — the
    /// evidence is real drawing — but it is not a probe either.
    public static let provenance = "drawing-derivation"

    /// `ref` prefix for a derived cell. No act plane can address one: there
    /// is no guest reference behind it, and `Semantics.authorizesAction`
    /// stays false because no action is claimed. What the ref buys is
    /// IDENTITY — the same cell keeps the same name across repaints, so a
    /// `HitTester` result and an operation log can talk about "cell 3"
    /// instead of about a coordinate.
    public static let refPrefix = "drawn-cell"

    /// Derived cells as ordinary scene controls, ready to be appended to a
    /// window. Titleless on purpose: the channel names are not in the
    /// drawing stream and inventing them is the one thing this must not do.
    public static func controls(from ops: [DisplayOp]) -> [Scene.Control] {
        var out: [Scene.Control] = []
        for (index, grid) in derive(from: ops).enumerated() {
            for cell in grid.cells {
                var semantic = Scene.Semantics(
                    knowledge: .known, kind: cellKind,
                    provenance: provenance, completeness: .complete)
                if grid.selectionKnown {
                    semantic.state = cell.selected ? "selected" : "unselected"
                }
                out.append(Scene.Control(
                    ref: "\(refPrefix):\(index):\(cell.index)",
                    role: "control", title: "", rect: cell.rect,
                    enabled: true, visible: true,
                    checked: grid.selectionKnown && cell.selected,
                    semantic: semantic))
            }
        }
        return out
    }

    /// Append derived cells to a window's controls, replacing any this file
    /// added before. A window with no grid keeps exactly the controls it
    /// arrived with — the negative case matters more than the positive one,
    /// because a plausible grid over a window that has none is worse than
    /// no grid at all.
    public static func attach(to window: inout Scene.Window) {
        window.controls.removeAll { $0.ref.hasPrefix("\(refPrefix):") }
        guard let ops = window.display, !ops.isEmpty else { return }
        window.controls.append(contentsOf: controls(from: ops))
    }
}
