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
        XCTAssertTrue(sidebar.contains("upperItems: layout.upper"))
        XCTAssertTrue(sidebar.contains("lowerItems: layout.lower"))
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

    func testNativeToolbarOwnsTopChromeAndFooterOverlaysTheList() throws {
        let sidebar = try sidebarSource()

        XCTAssertFalse(sidebar.contains(".safeAreaInset(edge: .top"))
        XCTAssertTrue(sidebar.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertEqual(sidebar.components(separatedBy: ".nowGlassBar()").count,
                       2)
    }

    func testExpandedDrawerCarriesAPersistentLabel() throws {
        let drawer = try GateSource.hostSwift(
            "now-host/Sources/Host/ModuleDrawerView.swift")

        XCTAssertTrue(drawer.contains(
            "Label(\"Drawer\", systemImage: \"archivebox\")"))
        XCTAssertFalse(drawer.contains("if hovering"))
    }

    func testWindowShellUsesNativeUnifiedToolbarChrome() throws {
        let app = try GateSource.hostSwift(
            "now-host/Sources/Host/App.swift")
        let root = try GateSource.hostSwift(
            "now-host/Sources/Host/HostRootView.swift")
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")

        XCTAssertTrue(app.contains(
            "newWindow.styleMask.insert(.fullSizeContentView)"))
        XCTAssertTrue(app.contains("newWindow.toolbarStyle = .unified"))
        XCTAssertTrue(root.contains("HostShellToolbar("))
        XCTAssertTrue(root.contains("ToolbarItem(placement: .principal)"))
        XCTAssertTrue(root.contains("#if compiler(>=6.4)"))
        XCTAssertTrue(root.contains("#available(macOS 26.1, *)"))
        XCTAssertFalse(sidebar.contains("safeAreaInset(edge: .top"))
    }

    func testSidebarSelectionUsesSystemActiveAndInactiveColors() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNavigationContent.swift")

        XCTAssertTrue(sidebar.contains("@Environment(\\.controlActiveState)"))
        XCTAssertTrue(sidebar.contains(
            ".unemphasizedSelectedContentBackgroundColor"))
        XCTAssertTrue(sidebar.contains(".selectedContentBackgroundColor"))
        XCTAssertFalse(sidebar.contains("Color.accentColor.opacity(0.17)"))
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

    func testNativeHoverReflowsStableRowsAndCancelRestoresTheLayout() throws {
        let dragSurface = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNativeDragSurface.swift")
        let root = try GateSource.hostSwift(
            "now-host/Sources/Host/HostRootView.swift")
        let tabs = try GateSource.hostSwift(
            "now-host/Sources/Host/ShelfDetailView.swift")

        XCTAssertTrue(dragSurface.contains(
            "configuration?.previewDrop(payload, target)"))
        XCTAssertTrue(dragSurface.contains(
            "func draggingSession(_ session: NSDraggingSession"))
        XCTAssertTrue(root.contains("dragPreview = preview"))
        XCTAssertTrue(root.contains("dragPreview = nil"))
        XCTAssertTrue(tabs.contains("ShelfPillDropSlot("))
    }

    private func sidebarSource() throws -> String {
        try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")
            + GateSource.hostSwift(
                "now-host/Sources/Host/SidebarNavigationContent.swift")
    }
}
