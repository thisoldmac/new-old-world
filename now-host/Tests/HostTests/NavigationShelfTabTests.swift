import XCTest
@testable import Host

final class NavigationShelfTabTests: XCTestCase {
    func testMachineShelfBeginsWithOverviewThenItsStableModules() throws {
        let shelf = try XCTUnwrap(
            NavigationLayout.standard(for: .standard).shelf(id: .machine))

        let tabs = NavigationShelfTab.tabs(for: shelf, registry: .standard)

        XCTAssertEqual(tabs.map(\.title), [
            "Overview", "Hardware", "Software", "Processes", "Diagnostics",
        ])
        XCTAssertEqual(tabs.first?.selection,
                       NavigationSelection(destination: .shelfHero(.machine),
                                           containingShelfID: .machine))
        XCTAssertEqual(tabs.dropFirst().compactMap(\.moduleID),
                       ["census", "software", "processes", "diagnostics"])
    }

    func testNetworkShelfUsesConnectionsAsItsFirstPill() throws {
        let shelf = try XCTUnwrap(
            NavigationLayout.standard(for: .standard).shelf(id: .network))

        let tabs = NavigationShelfTab.tabs(for: shelf, registry: .standard)

        XCTAssertEqual(tabs.map(\.title),
                       ["Connections", "Networking", "MCP", "Web Proxy"])
        XCTAssertEqual(tabs.first?.moduleID, "settings")
        XCTAssertEqual(tabs.first?.selection,
                       NavigationSelection(destination: .module("settings"),
                                           containingShelfID: .network))
    }

    func testEveryShelfPillKeepsTheShelfAsItsNavigationOwner() {
        let layout = NavigationLayout.standard(for: .standard)

        for shelfID in [NavigationShelfID.screen, .files, .network, .machine] {
            let shelf = try! XCTUnwrap(layout.shelf(id: shelfID))
            let tabs = NavigationShelfTab.tabs(for: shelf, registry: .standard)

            XCTAssertFalse(tabs.isEmpty)
            XCTAssertTrue(tabs.allSatisfy {
                $0.selection.containingShelfID == shelfID
            })
        }
    }

    func testShelfMembersRenderAsDetailPillsInsteadOfSidebarRows() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")
        let detail = try GateSource.hostSwift(
            "now-host/Sources/Host/ShelfDetailView.swift")

        XCTAssertFalse(sidebar.contains("SidebarShelfTab"))
        XCTAssertTrue(detail.contains("ForEach(tabs)"))
        XCTAssertTrue(detail.contains("ShelfPillButton("))
    }

    func testSidebarUsesANativeListWithACompactPinnedUtilityArea() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")

        XCTAssertTrue(sidebar.contains("items: sidebar.layout.lower"))
        XCTAssertTrue(sidebar.contains("List {"))
        XCTAssertTrue(sidebar.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(sidebar.contains("SidebarUtilityArea("))
        XCTAssertTrue(sidebar.contains("items: items"))
        XCTAssertTrue(sidebar.contains("ModuleDrawerView("))
        XCTAssertFalse(sidebar.contains("GeometryReader"))
        XCTAssertFalse(sidebar.contains("Text(\"Navigation\")"))
    }

    func testConnectionsShelfUsesTheMainListAndItsProductName() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")

        XCTAssertTrue(sidebar.contains("case .network: \"Connections\""))
        XCTAssertFalse(sidebar.contains("case .network: \"Network\""))
    }

    func testDropTargetsOverlayRowsInsteadOfBecomingEmptyListRows() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")

        XCTAssertTrue(sidebar.contains("SidebarNavigationListRow("))
        XCTAssertTrue(sidebar.contains(".overlay(alignment: .top)"))
        XCTAssertFalse(sidebar.contains(".listRowInsets(EdgeInsets())"))
    }

    func testGlassChromeOverlaysTheScrollingSidebarContent() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")

        XCTAssertTrue(sidebar.contains(".safeAreaInset(edge: .top"))
        XCTAssertTrue(sidebar.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertEqual(sidebar.components(separatedBy: ".nowGlassBar()").count,
                       3)
    }

    func testExpandedDrawerCarriesAPersistentLabel() throws {
        let drawer = try GateSource.hostSwift(
            "now-host/Sources/Host/ModuleDrawerView.swift")

        XCTAssertTrue(drawer.contains("if !collapsed"))
        XCTAssertTrue(drawer.contains("Text(\"Drawer\")"))
        XCTAssertFalse(drawer.contains("if hovering"))
    }

    func testNativeDragPreviewSnapshotsTheRenderedNavigationElement() throws {
        let dragSurface = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNativeDragSurface.swift")

        XCTAssertTrue(dragSurface.contains(
            "let image = renderedElementSnapshot()"))
        XCTAssertTrue(dragSurface.contains("cacheDisplay(in: sourceRect"))
        XCTAssertFalse(dragSurface.contains("NSImage(systemSymbolName:"))
        XCTAssertFalse(dragSurface.contains("private func dragImage(for payload"))
        XCTAssertFalse(dragSurface.contains("width: 24, height: 24"))
    }
}
