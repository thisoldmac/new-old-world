import XCTest
@testable import MirrorKit

/// **Can this item be put back where it was?**
///
/// The drag plane asks exactly one geometric question, and until 2026-08-07
/// the mirror could not answer it. `placed` was the only flag anything had,
/// and three producers set it from three different kinds of evidence — the
/// Finder's drawn box, the saved `fdLocation` grid, and a top-right stack this
/// side invented for volumes. A snap-back reading `placed` would have refused
/// nothing and returned desktop items to coordinates nobody had measured.
///
/// Each guard below was watched failing by mutation; the mutation is named on
/// the test that catches it.
final class DesktopHomeTests: XCTestCase {

    // MARK: - The ladder

    /// Mutation: default `origin` to `.drawn` when a producer did not say.
    /// Every pre-2026-08-07 fixture then claims a trustworthy home.
    func testAnUnstatedOriginIsNotAHome() {
        let item = Scene.DesktopItem(
            name: "Read Me", kind: "file", type: nil, creator: nil,
            x: 40, y: 40, placed: true, alias: false, invisible: false)
        XCTAssertNil(item.origin)
        XCTAssertFalse(item.homeIsTrustworthy,
                       "a producer that did not say where a position came "
                       + "from has not given us a home")
    }

    /// Mutation: `origin == .saved` counts as a home. The saved grid differed
    /// from the drawn box by (52, 25) at rest on the probe folder and
    /// diverged completely once a window scrolled.
    func testOnlyTheDrawnBoxIsAHome() {
        func item(_ o: Scene.PositionOrigin) -> Scene.DesktopItem {
            .init(name: "n", kind: "file", type: nil, creator: nil,
                  x: 0, y: 0, placed: true, alias: false, invisible: false,
                  origin: o)
        }
        XCTAssertTrue(item(.drawn).homeIsTrustworthy)
        XCTAssertFalse(item(.saved).homeIsTrustworthy)
        XCTAssertFalse(item(.unknown).homeIsTrustworthy)
    }

    // MARK: - The producers, each saying which rung it is on

    /// Mutation: drop the `origin:` argument from `SceneBuilder.desktopItems`.
    /// The catalog's saved grid then reads as unstated rather than as saved,
    /// which is a *different* wrong answer and one this test still catches —
    /// so the assertion names `.saved` exactly.
    func testTheCatalogSaysSaved() {
        let items = SceneBuilder.desktopItems(from: [
            "items": [
                ["name": "Filed", "kind": "file",
                 "loc": ["h": 100, "v": 60], "flags": 0],
                ["name": "Never filed", "kind": "file",
                 "loc": ["h": 0, "v": 0], "flags": 0],
            ],
        ])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].origin, .saved)
        XCTAssertFalse(items[0].homeIsTrustworthy)
        /* {0,0} is not a position at all — `placed` already said so, and the
           provenance agrees rather than contradicting it. */
        XCTAssertEqual(items[1].origin, .unknown)
        XCTAssertFalse(items[1].placed)
    }

    /// Mutation: restore `item.placed = true` in `placeVolumes` without the
    /// `.unknown`. This is the exact line the drag lane refused to build on.
    func testAnInventedVolumePositionIsNotAHome() {
        let vols = [Scene.DesktopItem(
            name: "Macintosh HD", kind: "disk", type: nil, creator: nil,
            x: 0, y: 0, placed: false, alias: false, invisible: false)]
        let out = ScenePoller.placeVolumes(vols, screen: .init(w: 800, h: 600))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].placed, "it is still drawn — a disk absent from "
                      + "the picture is worse than one in the wrong place")
        XCTAssertEqual(out[0].origin, .unknown)
        XCTAssertFalse(out[0].homeIsTrustworthy,
                       "placeVolumes MADE THIS POSITION UP")
    }

    /// A volume the guest did place keeps whatever provenance it arrived
    /// with; `placeVolumes` only fills gaps.
    func testPlaceVolumesDoesNotOverwriteAKnownPosition() {
        let vols = [Scene.DesktopItem(
            name: "Macintosh HD", kind: "disk", type: nil, creator: nil,
            x: 700, y: 40, placed: true, alias: false, invisible: false,
            origin: .drawn)]
        let out = ScenePoller.placeVolumes(vols, screen: .init(w: 800, h: 600))
        XCTAssertEqual(out[0].x, 700)
        XCTAssertEqual(out[0].origin, .drawn)
    }

    // MARK: - The desktop clause

    private static let deskOutput =
        "D|Macintosh HD|700,40,732,72;;"
        + "D|Read Me|40,60,72,92;;"
        + "D|Macintosh HD|1,1,33,33;;"          // the `disks` loop repeats it
        + "D|Torn|40,60;;"                      // a half-read box
        + "D|Truncated too|;;"

    /// Mutation: keep the LAST record for a name instead of the first. The
    /// `disks` loop then overwrites every drawn desktop box with its own.
    func testTheDesktopIsParsedFromDrawnBoxesAndDeduped() {
        let report = FinderItems.parseDesktop(Self.deskOutput)
        XCTAssertEqual(report.items.map(\.name), ["Macintosh HD", "Read Me"],
                       "a torn record is dropped, not half-believed")
        XCTAssertEqual(report.items[0].x, 700)
        XCTAssertEqual(report.items[0].y, 40)
        XCTAssertEqual(report.items[0].w, 32)
        XCTAssertEqual(report.items[0].h, 32)
        XCTAssertFalse(report.truncated)
    }

    /// Mutation: let the `X|` marker fall through to the `T|` case. The
    /// desktop's truncation then reports against whichever folder window
    /// happened to be parsed last.
    func testTheDesktopCapIsItsOwnMarker() {
        let report = FinderItems.parseDesktop("D|A|1,2,3,4;;X|;;")
        XCTAssertTrue(report.truncated)
        let windows = FinderItems.parse(
            "W|Docs|HD:Docs:;;I|f|1,2,3,4;;D|A|1,2,3,4;;X|;;")
        XCTAssertEqual(windows.count, 1)
        XCTAssertFalse(windows[0].truncated,
                       "the desktop's cap is not the window's")
        XCTAssertEqual(windows[0].items.count, 1,
                       "a D record is not an item of the last window")
    }

    /// The script asks for `bounds`, not `position`, and asks the desktop the
    /// same question every folder window is asked. Stated as a test because
    /// `position` is what the deleted `disksScript` used, and reverting to it
    /// would be invisible in a diff of behaviour.
    func testTheDesktopClauseAsksForBounds() {
        let script = FinderItems.windowsScript()
        XCTAssertTrue(script.contains("items of desktop"))
        XCTAssertTrue(script.contains("repeat with t in disks"))
        XCTAssertFalse(script.contains("position of"),
                       "`position of` answers the SAVED grid in a list view")
    }

    // MARK: - The join

    /// Mutation: give every merged item `.drawn`, including the ones the
    /// Finder never reported. An item hidden behind the truncation cap then
    /// claims a home computed from the saved grid.
    func testAnUndrawnItemKeepsItsOwnProvenance() {
        let existing = [
            Scene.DesktopItem(name: "Read Me", kind: "file", type: "TEXT",
                              creator: "ttxt", x: 12, y: 34, placed: true,
                              alias: false, invisible: false, origin: .saved),
            Scene.DesktopItem(name: "Past the cap", kind: "file", type: nil,
                              creator: nil, x: 90, y: 90, placed: true,
                              alias: false, invisible: false, origin: .saved),
        ]
        let merged = FinderItems.mergeDesktop(
            drawn: [.init(name: "Read Me", x: 40, y: 60, w: 32, h: 32)],
            existing: existing)

        let readMe = merged.first { $0.name == "Read Me" }
        XCTAssertEqual(readMe?.x, 40, "the drawn box wins over the grid")
        XCTAssertEqual(readMe?.origin, .drawn)
        XCTAssertEqual(readMe?.type, "TEXT",
                       "the catalog keeps its say on identity")

        let unseen = merged.first { $0.name == "Past the cap" }
        XCTAssertEqual(unseen?.x, 90)
        XCTAssertEqual(unseen?.origin, .saved,
                       "it did not inherit a provenance from its neighbours")
    }

    /// An item the Finder draws but the catalog never described is still
    /// carried — the position is what makes it addressable.
    func testADrawnItemWithNoCatalogEntryIsCarried() {
        let merged = FinderItems.mergeDesktop(
            drawn: [.init(name: "Mystery", x: 8, y: 8, w: 32, h: 32)],
            existing: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].kind, "file")
        XCTAssertTrue(merged[0].homeIsTrustworthy)
    }

    /// Mutation: drop the `invisible` guard. The entry then comes back
    /// `placed`, visible and `.drawn` — a file the machine hides, given a
    /// trustworthy home by the join.
    ///
    /// The entry is not DELETED, because deleting what a producer said is not
    /// this function's business; it passes through untouched, and every reader
    /// already skips `invisible`.
    func testAnInvisibleEntryIsNotResurrectedByADrawnBox() {
        let merged = FinderItems.mergeDesktop(
            drawn: [.init(name: "Desktop DB", x: 8, y: 8, w: 32, h: 32)],
            existing: [.init(name: "Desktop DB", kind: "file", type: nil,
                             creator: nil, x: 0, y: 0, placed: false,
                             alias: false, invisible: true)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].invisible)
        XCTAssertFalse(merged[0].placed)
        XCTAssertNil(merged[0].origin,
                     "no drawn box was granted to something the Finder hides")
    }

    /// A window item's box comes from the Finder too, and says so.
    func testWindowItemsAreDrawn() {
        let merged = FinderItems.merge(
            placed: [.init(name: "f", x: 4, y: 8, w: 16, h: 16)],
            catalog: [])
        XCTAssertEqual(merged[0].origin, .drawn)
        XCTAssertTrue(merged[0].homeIsTrustworthy)
    }
}

/// **The guest's own words, recorded 2026-08-07 on mac99 / OS 9.1.**
///
/// Everything above is fixtures this side wrote, and a test that constructs
/// the message it then parses tests one half twice. This is the desktop
/// clause's answer from a real Macintosh, pasted verbatim from
/// `script`'s `output` field with only the OSA source-form quotes stripped.
///
/// The run that produced it: `scripts/spin-up-ppc` on a private clone
/// (anchor 1920 / wire 5470), build `1a8ffb91f636`. The same session moved
/// `HELLO_CLAUDE.txt` with `set position of` and watched `bounds of` follow
/// it — 608,92,640,124 → 120,320,152,352 → 240,548,272,580 — with a QMP
/// screendump showing the icon in its new place. That is what "the drawn box
/// is live" means, on a machine rather than in a fixture.
///
/// **This build served neither `list` nor `volumes`** (`unknown-command`),
/// which is the sharpest thing the run said: without the desktop clause this
/// guest's desktop would have arrived EMPTY. The saved grid is not a weaker
/// source here, it is no source at all.
final class DesktopClauseLiveOutputTests: XCTestCase {

    private static let recorded =
        "D|Trash|716,510,748,542;;D|Macintosh HD|736,28,768,60;;"
        + "D|Browse the Internet|716,187,748,219;;D|DevHarness|608,476,640,508;;"
        + "D|From Claude.txt|608,540,640,572;;D|harness|480,28,512,60;;"
        + "D|harness.log|736,92,768,124;;D|HELLO_CLAUDE.txt|608,92,640,124;;"
        + "D|HelloWorld|608,348,640,380;;D|Mail|716,268,748,300;;"
        + "D|QuickTime Player|716,349,748,381;;"
        + "D|Register with Apple|716,430,748,462;;"
        + "D|Rumpus 2.0 PRO (Classic)|559,289,591,321;;"
        + "D|Rumpus_Pro2.0 Folder|608,156,640,188;;"
        + "D|Rumpus_Pro2.0.sit|608,412,640,444;;D|runner.debug|480,156,512,188;;"
        + "D|runner.port|480,220,512,252;;D|Sherlock 2|557,26,589,58;;"
        + "D|TBTRunner|480,92,512,124;;D|Macintosh HD|736,28,768,60;;"

    func testTheRecordedDesktopParsesIntoTrustworthyHomes() {
        let report = FinderItems.parseDesktop(Self.recorded)
        XCTAssertFalse(report.truncated)
        XCTAssertEqual(report.items.count, 19,
                       "20 records, and Macintosh HD appears twice")
        for item in report.items {
            XCTAssertEqual(item.w, 32)
            XCTAssertEqual(item.h, 32, "an icon-view desktop draws 32x32")
        }
        let merged = FinderItems.mergeDesktop(drawn: report.items,
                                              existing: [])
        XCTAssertTrue(merged.allSatisfy(\.homeIsTrustworthy))
        /* The Trash is on the desktop and is NOT in the Desktop Folder, so
           the saved-grid path could never have seen it at all. */
        XCTAssertNotNil(merged.first { $0.name == "Trash" })
    }

    /// The `disks` loop repeats what `items of desktop` already gave, and the
    /// Finder answers the SAME box both times — which is what makes
    /// "first record wins" inert rather than a coin toss.
    ///
    /// Recorded rather than reasoned: this is the pair of records that
    /// actually arrived.
    func testTheDuplicateDiskRecordAgreesWithItself() {
        let both = Self.recorded.components(separatedBy: ";;")
            .filter { $0.hasPrefix("D|Macintosh HD|") }
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both[0], both[1])
        XCTAssertEqual(
            FinderItems.parseDesktop(Self.recorded)
                .items.filter { $0.name == "Macintosh HD" }.count, 1)
    }

    /// The mirror can aim at every one of them. Mutation: restore the old
    /// `placed`-only gate and the disk's invented position passes too.
    func testEveryRecordedItemCouldBeDragged() {
        let items = FinderItems.mergeDesktop(
            drawn: FinderItems.parseDesktop(Self.recorded).items,
            existing: [])
        let scene = Scene(version: 2, seq: 1, source: "mac99", capturedAt: 0,
                          screen: .init(w: 800, h: 600), apps: [],
                          processes: nil, menubar: nil, windows: [],
                          desktopItems: items, meta: .init(errors: []))
        for item in items {
            switch DragTargeting.subject(scene, x: item.x + 8,
                                         y: item.y + 8) {
            case .success(let s):
                XCTAssertEqual(s.name, item.name)
            case .failure(let r):
                XCTFail("\(item.name): \(r.message)")
            }
        }
    }
}
