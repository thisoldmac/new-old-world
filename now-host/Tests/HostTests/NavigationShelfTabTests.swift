import XCTest
@testable import Host

@MainActor
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

    func testDebugShelfUsesConsoleThenLogs() throws {
        let shelf = try XCTUnwrap(
            NavigationLayout.standard(for: .standard).shelf(id: .debug))

        let tabs = NavigationShelfTab.tabs(for: shelf, registry: .standard)

        XCTAssertEqual(tabs.map(\.title), ["Console", "Logs"])
        XCTAssertEqual(tabs.first?.selection,
                       NavigationSelection(destination: .module("console"),
                                           containingShelfID: .debug))
    }

    func testEveryShelfPillKeepsTheShelfAsItsNavigationOwner() {
        let layout = NavigationLayout.standard(for: .standard)

        for shelfID in [NavigationShelfID.screen, .files, .debug,
                        .network, .machine] {
            let shelf = try! XCTUnwrap(layout.shelf(id: shelfID))
            let tabs = NavigationShelfTab.tabs(for: shelf, registry: .standard)

            XCTAssertFalse(tabs.isEmpty)
            XCTAssertTrue(tabs.allSatisfy {
                $0.selection.containingShelfID == shelfID
            })
        }
    }

    func testShelfMembersRenderAsDetailPillsInsteadOfSidebarRows() throws {
        let sidebar = try sidebarSource()
        let detail = try GateSource.hostSwift(
            "now-host/Sources/Host/ShelfDetailView.swift")

        XCTAssertFalse(sidebar.contains("SidebarShelfTab"))
        XCTAssertTrue(detail.contains("ForEach(tabs)"))
        XCTAssertTrue(detail.contains("ShelfPillButton("))
    }

    func testSidebarUsesTwoStacksInsideOneNativeListCanvas() throws {
        let sidebar = try sidebarSource()

        XCTAssertTrue(sidebar.contains("List {"))
        XCTAssertTrue(sidebar.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(sidebar.contains("SidebarNavigationCanvas("))
        XCTAssertTrue(sidebar.contains("upperItems: sidebar.layout.upper"))
        XCTAssertTrue(sidebar.contains("lowerItems: sidebar.layout.lower"))
        XCTAssertTrue(sidebar.contains("ModuleDrawerView("))
        XCTAssertTrue(sidebar.contains("GeometryReader"))
        XCTAssertFalse(sidebar.contains("Text(\"Navigation\")"))
    }

    func testFullShelfRowsListMembersWhileModulesKeepTheirSummary() throws {
        let sidebar = try sidebarSource()

        XCTAssertTrue(sidebar.contains("Text(module.summary)"))
        XCTAssertTrue(sidebar.contains("Text(moduleList)"))
        XCTAssertTrue(sidebar.contains("if !compact"))
    }

    func testNewShelfInlineEditorUsesNativeFocusAndDefaultTitle() throws {
        let sidebar = try sidebarSource()

        XCTAssertTrue(sidebar.contains("TextField(\"Shelf name\""))
        XCTAssertTrue(sidebar.contains("@FocusState"))
        XCTAssertTrue(sidebar.contains("shelfBeingRenamed"))
        XCTAssertTrue(sidebar.contains(".onExitCommand"))
        XCTAssertTrue(sidebar.contains("cancelShelfCreation"))
    }

    func testConnectionsShelfUsesTheMainListAndItsProductName() throws {
        let sidebar = try sidebarSource()

        XCTAssertTrue(sidebar.contains("case .network: \"Connections\""))
        XCTAssertFalse(sidebar.contains("case .network: \"Network\""))
    }

    func testDropTargetsOverlayRowsInsteadOfBecomingEmptyListRows() throws {
        let sidebar = try sidebarSource()

        XCTAssertTrue(sidebar.contains("SidebarNavigationListRow("))
        XCTAssertTrue(sidebar.contains(".overlay(alignment: .top)"))
        XCTAssertFalse(sidebar.contains(".listRowInsets(EdgeInsets())"))
    }

    func testTheNativeCanvasHostOwnsTheOtherwiseEmptyDropArea() throws {
        let sidebar = try sidebarSource()
        let native = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNativeDragSurface.swift")
            + GateSource.hostSwift(
                "now-host/Sources/Host/SidebarCanvasDropHost.swift")

        XCTAssertTrue(sidebar.contains("SidebarCanvasDropHost("))
        XCTAssertFalse(sidebar.contains(".onDrop("))
        XCTAssertTrue(native.contains("final class NativeSidebarCanvasDropView"))
        XCTAssertEqual(native.components(
            separatedBy: "registerForDraggedTypes").count, 4)
        XCTAssertTrue(native.contains("NavigationSidebarDropResolver.target("))
    }

    func testGlassChromeOverlaysTheScrollingSidebarContent() throws {
        let sidebar = try sidebarSource()

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

    private func sidebarSource() throws -> String {
        try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")
            + GateSource.hostSwift(
                "now-host/Sources/Host/SidebarNavigationContent.swift")
    }
}
