import XCTest
import MirrorKit
import MirrorKitUI
@testable import Host

/// The gate for `MirrorKit.DrawnCellGrid` — P2 derived from P3's own
/// evidence.
///
/// Every positive number here was MEASURED off the machine first
/// (open-issues.md, "Sherlock's channel grid is fully derivable without
/// pixels", 2026-08-06) and is asserted against the committed live capture
/// rather than restated: eight columns by two rows of 51×46 cells, pitch 55
/// and 50, at x = 27 + 55k and y = 21 / 71, with the selected cell readable
/// from the sprite source rect alone.
///
/// The NEGATIVES carry as much weight as the positives. A derivation that
/// finds a plausible grid in a window that has none is worse than one that
/// finds nothing, so five other live captures — both Finder views, both
/// control panels and NOW's own window — are asserted to produce no cells,
/// and two synthetic streams pin the two ways a near-grid must be refused.
@MainActor
final class DrawnCellGridTests: XCTestCase {

    private func plane() -> NOWMirrorContentPlane {
        NOWMirrorContentPlane(listener: GuestListener(
            identity: .init(version: "test", name: "Test Host")))
    }

    private func capture(_ name: String) throws -> QDTraceDecode.Drain {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json",
            subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(QDTraceDecode.drain(object))
    }

    /// The composed window, exactly as the renderer receives it: the plane
    /// joins the capture, publishes the display, and attaches the derived
    /// cells beside it.
    private func window(_ fixture: String, address: UInt32,
                        psn: String) throws -> MirrorKit.Scene.Window {
        try composed(fixture, address: address, psn: psn).windows[0]
    }

    private func composed(_ fixture: String, address: UInt32,
                          psn: String) throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "now-scene-ir-v1", withExtension: "json",
            subdirectory: "Fixtures"))
        var scene = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: url))
        for index in scene.windows.indices {
            scene.windows[index].front = false
            scene.windows[index].psn = "0.99999999"
        }
        scene.windows[0].front = true
        scene.windows[0].addr = address
        scene.windows[0].psn = psn
        scene.windows[0].display = nil
        scene.windows[0].controls = []
        scene.windows[0].items = nil
        return plane().apply(try capture(fixture), to: scene).scene
    }

    private func cells(_ window: MirrorKit.Scene.Window)
        -> [MirrorKit.Scene.Control] {
        window.controls.filter {
            $0.semantic?.kind == MirrorKit.DrawnCellGrid.cellKind
        }
    }

    // MARK: - The measurement, re-derived from the committed capture

    func testSherlockChannelGridMatchesTheMeasuredGeometry() throws {
        let win = try window("qdtrace-drain-sherlock-live",
                             address: 0x1e9a0780, psn: "0.35979266")
        let grid = cells(win)
        XCTAssertEqual(grid.count, 16, "8 columns × 2 rows")

        for (index, cell) in grid.enumerated() {
            let rect = try XCTUnwrap(cell.rect)
            let row = index / 8
            let column = index % 8
            XCTAssertEqual(rect.l, 27 + 55 * column,
                           "cell \(index) sits at x = 27 + 55k")
            XCTAssertEqual(rect.t, row == 0 ? 21 : 71,
                           "cell \(index) sits on row \(row)")
            XCTAssertEqual(rect.width, 51)
            XCTAssertEqual(rect.height, 46)
        }
    }

    /// Selection, which is the fact nothing else on this side can supply.
    func testSelectionIsReadFromTheSpriteSourceAlone() throws {
        let win = try window("qdtrace-drain-sherlock-live",
                             address: 0x1e9a0780, psn: "0.35979266")
        let grid = cells(win)
        let selected = grid.filter(\.checked)
        XCTAssertEqual(selected.count, 1, "exactly one cell is selected")
        XCTAssertEqual(try XCTUnwrap(selected.first?.rect).l, 27)
        XCTAssertEqual(try XCTUnwrap(selected.first?.rect).t, 21)
        XCTAssertEqual(selected.first?.semantic?.state, "selected")
        XCTAssertEqual(grid.filter { $0.semantic?.state == "unselected" }
                        .count, 15)
    }

    /// The second Sherlock capture, taken through the resident's
    /// hook-at-birth route, must agree cell for cell. Two captures of one
    /// window disagreeing would mean the derivation reads the capture
    /// rather than the machine.
    func testBothSherlockCapturesAgree() throws {
        let live = cells(try window("qdtrace-drain-sherlock-live",
                                    address: 0x1e9a0780, psn: "0.35979266"))
        let hooked = cells(try window("qdtrace-drain-sherlock-hooked",
                                      address: 0x1e99ffc0, psn: "0.35520514"))
        XCTAssertEqual(live.map(\.rect), hooked.map(\.rect))
        XCTAssertEqual(live.map(\.checked), hooked.map(\.checked))
    }

    /// A derived cell is titleless, unaddressable and marked as derived.
    /// The channel NAMES are not in the drawing stream; an act plane must
    /// not be able to press one by reference, because there is no guest
    /// reference behind it.
    func testDerivedCellsClaimNoMoreThanTheStreamSupports() throws {
        let win = try window("qdtrace-drain-sherlock-live",
                             address: 0x1e9a0780, psn: "0.35979266")
        for cell in cells(win) {
            XCTAssertEqual(cell.title, "", "no invented channel name")
            XCTAssertEqual(cell.semantic?.provenance,
                           MirrorKit.DrawnCellGrid.provenance)
            XCTAssertNil(cell.semantic?.action)
            XCTAssertFalse(try XCTUnwrap(cell.semantic).authorizesAction,
                           "a derived cell cannot authorize an act")
        }
        XCTAssertEqual(Set(cells(win).map(\.ref)).count, 16,
                       "every cell has its own identity")
    }

    /// What the cells buy the act plane: a click in the grid now resolves
    /// to a named cell instead of falling through to bare window content.
    func testAClickInTheGridResolvesToACell() throws {
        let scene = try composed("qdtrace-drain-sherlock-live",
                                 address: 0x1e9a0780, psn: "0.35979266")
        let win = scene.windows[0]

        /* Cell 0's centre, in guest screen coordinates: content-local
           (27+25, 21+23) pushed down by the title bar. */
        let target = HitTester.hitTest(
            scene, x: win.rect.l + 27 + 25,
            y: win.rect.t + HitTester.titlebar + 21 + 23)
        guard case .control(_, let control) = target else {
            return XCTFail("the grid did not take the click: \(target)")
        }
        XCTAssertEqual(control.semantic?.kind,
                       MirrorKit.DrawnCellGrid.cellKind)
        XCTAssertTrue(control.checked, "that is the selected cell")
    }

    // MARK: - The negatives

    /// Five other live captures, none of which has a grid. This is the
    /// assertion that would catch a derivation loose enough to find one
    /// anywhere: control panels and Finder views both blit the same
    /// destination repeatedly, and neither is a picker.
    func testWindowsWithoutAGridProduceNoCells() throws {
        let others: [(String, UInt32, String)] = [
            ("qdtrace-drain-blitsrc-finder-list", 0x00a03580, "0.29949953"),
            ("qdtrace-drain-blitsrc-finder-buttons", 0x00a03580, "0.29949953"),
            ("qdtrace-drain-cp-datetime-hooked", 0x1f6fd590, "0.34734082"),
            ("qdtrace-drain-cp-memory", 0x1e9dffa0, "0.36438017"),
            ("qdtrace-drain-now-window", 0x1ecb4550, "0.29360131"),
        ]
        for (fixture, address, psn) in others {
            let win = try window(fixture, address: address, psn: psn)
            XCTAssertNotNil(win.display, "\(fixture) composed nothing at all")
            XCTAssertTrue(cells(win).isEmpty,
                          "\(fixture) grew a grid it does not have")
        }
    }

    /// A window with no drawing at all keeps exactly the controls it
    /// arrived with.
    func testNoDisplayMeansNoCells() throws {
        var win = try window("qdtrace-drain-sherlock-live",
                             address: 0x1e9a0780, psn: "0.35979266")
        XCTAssertEqual(cells(win).count, 16)
        win.display = nil
        MirrorKit.DrawnCellGrid.attach(to: &win)
        XCTAssertTrue(cells(win).isEmpty,
                      "the cells went with the drawing that proved them")
        XCTAssertTrue(MirrorKit.DrawnCellGrid.controls(from: []).isEmpty)
    }

    // MARK: - The two ways a near-grid must be refused

    private func blit(at origin: [Int], src: [Int],
                      dst: [Int] = [0, 0, 51, 46]) -> [DisplayOp] {
        var state = DisplayOp(op: "state", ticks: 0)
        state.kind = "origin"
        state.origin = origin
        var bits = DisplayOp(op: "bits", ticks: 0)
        bits.src = src
        bits.dst = dst
        return [state, bits]
    }

    /// A row with a hole in it is not a lattice. Eight columns and two rows
    /// must be sixteen cells: an application that happens to blit one
    /// destination at a few aligned places must not become a picker.
    func testAPartialLatticeIsRefused() {
        var ops: [DisplayOp] = []
        for k in 0..<8 {
            ops += blit(at: [-(27 + 55 * k), -21], src: [209, 231, 260, 277])
        }
        for k in 0..<7 {          // one cell short of the second row
            ops += blit(at: [-(27 + 55 * k), -71], src: [209, 231, 260, 277])
        }
        XCTAssertTrue(MirrorKit.DrawnCellGrid.derive(from: ops).isEmpty)
    }

    /// Selection is claimed only on a clean two-source split with exactly
    /// one odd cell. Three distinct sprite sources say something this
    /// derivation does not understand, so it reports the grid and refuses
    /// the selection rather than picking one.
    func testAmbiguousSourcesClaimNoSelection() {
        var ops: [DisplayOp] = []
        let sources = [[142, 149, 193, 195], [209, 231, 260, 277],
                       [1, 1, 52, 47]]
        for row in 0..<2 {
            for k in 0..<8 {
                ops += blit(at: [-(27 + 55 * k), -(21 + 50 * row)],
                            src: sources[(row * 8 + k) % 3])
            }
        }
        let grids = MirrorKit.DrawnCellGrid.derive(from: ops)
        XCTAssertEqual(grids.count, 1, "the geometry is still a grid")
        XCTAssertFalse(try! XCTUnwrap(grids.first).selectionKnown)
        XCTAssertTrue(try! XCTUnwrap(grids.first).cells
            .allSatisfy { !$0.selected })
        XCTAssertTrue(MirrorKit.DrawnCellGrid.controls(from: ops)
            .allSatisfy { $0.semantic?.state == nil })
    }

    /// The channel ICONS are a perfectly good lattice of their own, inside
    /// the wells. They are the cells' content, not a second grid, and a
    /// second targetable control inside every cell is what this rule
    /// prevents.
    func testAnInnerLatticeIsTheCellsContentNotASecondGrid() {
        var ops: [DisplayOp] = []
        for row in 0..<2 {
            for k in 0..<8 {
                let origin = [-(27 + 55 * k), -(21 + 50 * row)]
                ops += blit(at: origin, src: [209, 231, 260, 277])
                ops += blit(at: origin, src: [0, 0, 32, 32],
                            dst: [10, 8, 42, 40])
            }
        }
        let grids = MirrorKit.DrawnCellGrid.derive(from: ops)
        XCTAssertEqual(grids.count, 1, "the wells, not the icons inside them")
        XCTAssertEqual(grids.first?.cells.first?.rect.width, 51)
    }
}
