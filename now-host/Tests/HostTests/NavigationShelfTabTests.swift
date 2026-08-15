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

    func testShelfMenuListsOnlyItsModulesWithDirectSelectionsAndDragPayloads()
        throws {
        let shelf = try XCTUnwrap(
            NavigationLayout.standard(for: .standard).shelf(id: .machine))

        let entries = NavigationShelfMenuEntry.entries(
            for: shelf, registry: .standard)

        XCTAssertEqual(entries.map(\.title), [
            "Hardware", "Software", "Processes", "Diagnostics",
        ])
        XCTAssertEqual(entries.map(\.payload), [
            .module("census"), .module("software"), .module("processes"),
            .module("diagnostics"),
        ])
        XCTAssertTrue(entries.allSatisfy {
            $0.selection.containingShelfID == .machine
        })
        XCTAssertFalse(entries.contains { $0.title == "Overview" },
            "Overview is shelf chrome, not a movable module")
    }

    func testShelfMenuHitRegionTracksTheIconInBothSidebarWidths() {
        XCTAssertTrue(SidebarMenuHitRegion.leadingIcon.contains(
            horizontalOffset: 20, width: 176))
        XCTAssertFalse(SidebarMenuHitRegion.leadingIcon.contains(
            horizontalOffset: 100, width: 176))
        XCTAssertTrue(SidebarMenuHitRegion.centeredIcon.contains(
            horizontalOffset: 26, width: 52))
        XCTAssertFalse(SidebarMenuHitRegion.centeredIcon.contains(
            horizontalOffset: 1, width: 52))
    }

    func testShelfRowsExposeNativeModuleMenusWithoutReplacingRowActivation()
        throws {
        let sidebar = try sidebarSource()
        let native = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNativeDragSurface.swift")
        let menu = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarShelfModuleMenu.swift")

        XCTAssertTrue(sidebar.contains("menuItems: shelfMenuItems"))
        XCTAssertTrue(sidebar.contains("menuHitRegion: collapsed"))
        XCTAssertTrue(sidebar.contains("SidebarShelfIcon("))
        XCTAssertTrue(native.contains("SidebarModuleMenuItemView"))
        XCTAssertTrue(menu.contains("item.payload.pasteboardValue"))
        XCTAssertTrue(menu.contains("item.action()"))
        XCTAssertTrue(native.contains("configuration?.activate?()"),
            "clicking outside the shelf icon must still navigate normally")
    }

    func testExperimentalTierFlowsFromDescriptorIntoNavigationChrome() throws {
        let mirror = try XCTUnwrap(ModuleRegistry.standard.module(id: "mirror"))
        let shelf = NavigationShelf(
            id: .user(UUID()), title: "Experiments",
            moduleIDs: [mirror.id])

        let tab = try XCTUnwrap(NavigationShelfTab.tabs(
            for: shelf, registry: .standard).first)
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNavigationContent.swift")
        let detail = try GateSource.hostSwift(
            "now-host/Sources/Host/ShelfDetailView.swift")

        XCTAssertEqual(mirror.tier, .experimental)
        XCTAssertEqual(tab.tier, .experimental)
        XCTAssertTrue(sidebar.contains("ModuleTierBadge(tier: module.tier"))
        XCTAssertTrue(detail.contains("ModuleTierBadge(tier: tab.tier"))
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

    func testPopulatedRowsUseContinuousNativeDropRegions() throws {
        let sidebar = try sidebarSource()

        XCTAssertTrue(sidebar.contains("SidebarNavigationListRow("))
        XCTAssertTrue(sidebar.contains("rowDropTargets:"))
        XCTAssertTrue(sidebar.contains(
            "beforeTarget: .zone(zone, index: index)"))
        XCTAssertTrue(sidebar.contains(
            "afterTarget: .zone(zone, index: index + 1)"))
        XCTAssertFalse(sidebar.contains(".offset(y: -10)"))
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
        XCTAssertTrue(dragSurface.contains(
            "effectiveAppearance.performAsCurrentDrawingAppearance"))
        XCTAssertFalse(dragSurface.contains(
            "NSApp.effectiveAppearance.performAsCurrentDrawingAppearance"))
        XCTAssertTrue(dragSurface.contains("cacheDisplay(in: sourceRect"))
        XCTAssertFalse(dragSurface.contains("NSImage(systemSymbolName:"))
        XCTAssertFalse(dragSurface.contains("private func dragImage(for payload"))
        XCTAssertFalse(dragSurface.contains("width: 24, height: 24"))
    }

    func testClosedShelfRowsSpringOpenForIndexedModuleDrops() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNavigationContent.swift")
        let dragSurface = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNativeDragSurface.swift")

        XCTAssertTrue(sidebar.contains(
            "springLoad: { activate(shelfSelection) }"))
        // The gate is still "a row with no spring-load handler never arms".
        // It reads unwrapped now because the check moved inside
        // `springLoadingTarget`, which binds the configuration first.
        XCTAssertTrue(dragSurface.contains(
            "configuration.springLoad != nil"))
    }

    func testNativeDragOverlayPublishesReliableHoverChanges() throws {
        let dragSurface = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNativeDragSurface.swift")

        XCTAssertTrue(dragSurface.contains("var hoverChanged: ((Bool) -> Void)?"))
        XCTAssertTrue(dragSurface.contains("NSTrackingArea("))
        XCTAssertTrue(dragSurface.contains("configuration?.hoverChanged?(true)"))
        XCTAssertTrue(dragSurface.contains("configuration?.hoverChanged?(false)"))
    }

    func testInteractiveNavigationChromeUsesNativeHoverTracking() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNavigationContent.swift")
        let tabs = try GateSource.hostSwift(
            "now-host/Sources/Host/ShelfDetailView.swift")
        let drawer = try GateSource.hostSwift(
            "now-host/Sources/Host/ModuleDrawerView.swift")

        XCTAssertGreaterThanOrEqual(
            sidebar.components(separatedBy: "hoverChanged:").count, 3)
        XCTAssertTrue(tabs.contains("hoverChanged: { isHovering = $0 }"))
        XCTAssertTrue(drawer.contains("hoverChanged: { isHovering = $0 }"))
    }

    func testShelvesRemainSelectableRowsWithDistinctSystemGlass() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNavigationContent.swift")
        let glass = try GateSource.hostSwift(
            "now-host/Sources/Host/GlassStyle.swift")

        XCTAssertTrue(sidebar.contains("kind: .shelf"))
        XCTAssertTrue(sidebar.contains("Color.clear.nowGlassShelf()"))
        XCTAssertTrue(glass.contains("func nowGlassShelf("))
        XCTAssertTrue(glass.contains("content.glassEffect(.clear"))
        XCTAssertTrue(glass.contains("content.background(.thinMaterial"))
        XCTAssertFalse(sidebar.contains("Section(header:"))
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
