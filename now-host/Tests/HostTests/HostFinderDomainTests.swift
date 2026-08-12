import XCTest
import MirrorKit
@testable import Host

final class HostFinderDomainTests: XCTestCase {
    func testHostWindowProjectsSelectionIntoRenderedFinderState() {
        var window = fixtureWindow()
        window.selectedNames = ["Read Me"]

        let projected = HostFinderDomain.projectedWindow(window, z: 0)

        XCTAssertEqual(projected.finder?.selectedNames, ["Read Me"])
        XCTAssertEqual(projected.items?.map(\.name), ["Applications", "Read Me"])
        XCTAssertEqual(projected.ref, window.id)
        XCTAssertTrue(FinderItems.isHostOwnedWindow(projected))
    }

    func testListRowsAreHitAsItemsRatherThanBareWindowContent() {
        var window = fixtureWindow()
        window.view = .name
        let projected = HostFinderDomain.projectedWindow(window, z: 0)
        let scene = scene(with: projected)
        let item = try! XCTUnwrap(projected.items?.first)
        let origin = FinderItems.contentOrigin(projected)

        let hit = HitTester.hitTest(scene,
                                    x: origin.x + item.x + 8,
                                    y: origin.y + item.y + 8)

        guard case .windowItem(let id, let name, _, _) = hit else {
            return XCTFail("expected a Finder row, got \(hit)")
        }
        XCTAssertEqual(id, window.id)
        XCTAssertEqual(name, "Applications")
    }

    func testDescendingSortIsStableForEqualKeys() {
        var window = fixtureWindow()
        window.entries = [
            entry("b", kind: "file", bytes: 4),
            entry("a", kind: "file", bytes: 4),
            entry("c", kind: "file", bytes: 4),
        ]
        window.sort = .size
        window.ascending = false

        XCTAssertEqual(HostFinderDomain.sortedEntries(of: window).map(\.name),
                       ["c", "b", "a"])
    }

    func testHostFinderMenuProvidesTheMacOS86CoreSurface() {
        let bar = HostFinderDomain.finderMenubar(from: nil)

        XCTAssertEqual(bar.app, "Finder")
        XCTAssertEqual(bar.menus.map(\.title),
                       ["", "File", "Edit", "View", "Special", "Help", ""])
        XCTAssertEqual(bar.menus.dropFirst().prefix(5).compactMap(\.left),
                       [43, 78, 116, 159, 218])
        XCTAssertEqual(bar.menus.first(where: { $0.title == "View" })?
            .items.filter(\.enabled).map(\.title),
            ["as Icons", "as Buttons", "as List", "Clean Up", "Arrange",
             "View Options…"])
        XCTAssertEqual(bar.menus.first(where: { $0.title == "Edit" })?
            .items.map(\.title),
            ["Undo", "-", "Cut", "Copy", "Paste", "Clear", "Select All",
             "Show Clipboard", "-", "Preferences…"])
        XCTAssertEqual(bar.menus.first(where: { $0.title == "Special" })?
            .items.suffix(3).map(\.title), ["Sleep", "Restart", "Shut Down"])
        XCTAssertEqual(bar.menus.last?.id, -16489)
    }

    func testListViewProjectsNativeFinderColumnHeaders() {
        var window = fixtureWindow()
        window.view = .name

        let projected = HostFinderDomain.projectedWindow(window, z: 0)
        let headers = projected.controls.filter {
            $0.semantic?.kind == "columnHeader"
        }

        XCTAssertEqual(headers.map(\.title),
                       ["Name", "Date Modified", "Size", "Kind"])
        XCTAssertEqual(headers.compactMap { $0.semantic?.kind },
                       Array(repeating: "columnHeader", count: 4))
    }

    func testCatalogMetadataSurvivesFinderProjection() {
        var window = fixtureWindow()
        window.entries[0].dataBytes = 1_024
        window.entries[0].rsrcBytes = 257
        window.entries[0].modified = 3_869_266_040

        let metadata = HostFinderDomain.projectedWindow(window, z: 0)
            .finder?.itemMetadata["Read Me"]

        XCTAssertEqual(metadata?.dataBytes, 1_024)
        XCTAssertEqual(metadata?.rsrcBytes, 257)
        XCTAssertEqual(metadata?.modified, 3_869_266_040)
    }

    private func fixtureWindow() -> HostFinderDomain.Window {
        .init(id: HostFinderDomain.windowID(1), path: "",
              rootLabel: "Macintosh HD:",
              frame: Rect(l: 80, t: 40, r: 500, b: 350),
              entries: [entry("Read Me", kind: "file"),
                        entry("Applications", kind: "folder")])
    }

    private func entry(_ name: String, kind: String, bytes: Int = 1)
        -> FileEntry {
        .init(name: name, kind: kind, fileType: nil, creator: nil,
              dataBytes: bytes, rsrcBytes: 0, modified: 0)
    }

    private func scene(with window: Scene.Window) -> Scene {
        .init(version: 1, seq: 1, source: "test", capturedAt: 0,
              screen: .init(w: 640, h: 480), apps: [], processes: nil,
              menubar: nil, windows: [window], desktopItems: nil,
              meta: .init(errors: []))
    }
}
