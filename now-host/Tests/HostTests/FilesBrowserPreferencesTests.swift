import XCTest
import SwiftUI
@testable import Host

@MainActor
final class FilesBrowserPreferencesTests: XCTestCase {
    func testPeerDividerUsesAppKitsEffectiveDragRegionAndStartsHalfway() {
        XCTAssertEqual(
            FilesRightSidebarSplitController.defaultLeadingFraction, 0.5)
        let controller = FilesRightSidebarSplitController()
        _ = controller.install(leading: NSViewController(),
                               trailing: NSViewController(),
                               trailingCollapsed: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()

        XCTAssertTrue(controller.splitView.isVertical)
        XCTAssertEqual(controller.splitView.dividerStyle, .thin)
        XCTAssertEqual(controller.splitView.dividerThickness, 8,
                       "the host sidebar edge should be an aimable native handle")
        XCTAssertEqual(controller.splitView.arrangedSubviews[0].frame.width,
                       (900 - controller.splitView.dividerThickness) / 2,
                       accuracy: 2)
        let drawn = NSRect(
            x: controller.splitView.arrangedSubviews[0].frame.maxX,
            y: 0, width: controller.splitView.dividerThickness, height: 600)
        let effective = controller.splitView(
            controller.splitView,
            effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0)
        XCTAssertGreaterThanOrEqual(effective.width, drawn.width + 10,
                             "The native divider needs a forgiving hit target")
        let nativeSplit = controller.splitView as? FilesSplitView
        XCTAssertNotNil(nativeSplit)
        XCTAssertGreaterThanOrEqual(
            nativeSplit?.dividerInteractionRect(at: 0)?.width ?? 0,
            drawn.width + 12,
            "the resize cursor must cover the same forgiving native target")
    }

    func testPeerRightSideUsesOneFixedNativeRailWhenCollapsed() {
        let controller = FilesRightSidebarSplitController()
        let item = controller.install(leading: NSViewController(),
                                      trailing: NSViewController(),
                                      trailingCollapsed: false)

        XCTAssertFalse(item.canCollapse,
                       "the visible rail, not a second collapsed item, owns reopening")
        XCTAssertFalse(item.canCollapseFromWindowResize)
        XCTAssertFalse(item.isSpringLoaded,
                       "the rail itself is the AppKit spring destination")
        XCTAssertEqual(item.preferredThicknessFraction, 0.5)
        XCTAssertEqual(controller.splitViewItems[0]
            .preferredThicknessFraction, 0.5)

        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.setTrailingCollapsed(true)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(item.isCollapsed,
                       "the native trailing item must remain present as the rail")
        XCTAssertEqual(controller.splitView.arrangedSubviews[1].frame.width,
                       FilesRightSidebarSplitController.collapsedRailWidth,
                       accuracy: 1)
        XCTAssertEqual(item.minimumThickness,
                       FilesRightSidebarSplitController.collapsedRailWidth)
        XCTAssertEqual(item.maximumThickness,
                       FilesRightSidebarSplitController.collapsedRailWidth,
                       "a collapsed rail must not keep resizing")
        controller.setTrailingCollapsed(false)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(item.isCollapsed)
        XCTAssertEqual(controller.splitView.arrangedSubviews[0].frame.width,
                       (900 - controller.splitView.dividerThickness) / 2,
                       accuracy: 2)
    }

    func testCollapsedHostRailUsesItsWholeSurfaceToReopen() throws {
        let rail = FilesRightSidebarRailView(
            frame: NSRect(x: 0, y: 0, width: 54, height: 600))
        var expansionCount = 0
        rail.onExpand = { expansionCount += 1 }

        XCTAssertTrue(rail.hitTest(NSPoint(x: 27, y: 500)) === rail,
            "the rail below its icon must remain an active native handle")
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 27, y: 500),
            modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        rail.mouseUp(with: mouseUp)
        XCTAssertEqual(expansionCount, 1,
            "a click anywhere on the rail must reopen the host browser")
        XCTAssertTrue(rail.accessibilityPerformPress())
        XCTAssertEqual(expansionCount, 2,
            "the whole-surface handle and VoiceOver press share one action")
    }

    func testCollapsedHostRailWinsOverHostedContentsMinimumWidthInAWindow() {
        let controller = FilesRightSidebarSplitController()
        let hostedContent = NSHostingController(rootView:
            Color.clear.frame(minWidth: 360, minHeight: 300))
        let item = controller.install(
            leading: NSViewController(), trailing: hostedContent,
            trailingCollapsed: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .resizable], backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(item.minimumThickness,
                       FilesRightSidebarSplitController.collapsedRailWidth)
        XCTAssertEqual(item.maximumThickness,
                       FilesRightSidebarSplitController.collapsedRailWidth)
        XCTAssertEqual(controller.splitView.arrangedSubviews[1].frame.width,
                       FilesRightSidebarSplitController.collapsedRailWidth,
                       accuracy: 2,
                       "hidden browser content must leave the rail out of layout")

        window.orderOut(nil)
        withExtendedLifetime((window, controller, hostedContent)) {}
    }

    func testPeerRightSideSurvivesRepeatedCollapseAndReopenCycles() {
        let controller = FilesRightSidebarSplitController()
        let item = controller.install(leading: NSViewController(),
                                      trailing: NSViewController(),
                                      trailingCollapsed: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.splitView.setPosition(340, ofDividerAt: 0)

        for _ in 0..<4 {
            controller.setTrailingCollapsed(true)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(item.maximumThickness,
                           FilesRightSidebarSplitController.collapsedRailWidth)
            XCTAssertEqual(controller.splitView.arrangedSubviews[1].frame.width,
                           FilesRightSidebarSplitController.collapsedRailWidth,
                           accuracy: 1)

            controller.setTrailingCollapsed(false)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(item.maximumThickness,
                           NSSplitViewItem.unspecifiedDimension)
            XCTAssertEqual(controller.splitView.arrangedSubviews[0].frame.width,
                           340, accuracy: 2,
                           "reopening must restore the same usable divider")
        }
    }

    func testPeerDividerRestoresTheUsersPositionAndKeepsItsRatioOnRelayout() {
        let controller = FilesRightSidebarSplitController()
        _ = controller.install(leading: NSViewController(),
                               trailing: NSViewController(),
                               trailingCollapsed: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()

        controller.splitView.setPosition(330, ofDividerAt: 0)
        controller.setTrailingCollapsed(true)
        controller.setTrailingCollapsed(false)

        let restored = controller.splitView.arrangedSubviews[0].frame.width
        XCTAssertEqual(restored, 330, accuracy: 2,
                       "restoring the peer must not discard an intentional resize")

        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        let available = controller.splitView.bounds.width
            - controller.splitView.dividerThickness
        XCTAssertEqual(
            controller.splitView.arrangedSubviews[0].frame.width / available,
            330 / (900 - controller.splitView.dividerThickness),
            accuracy: 0.02,
            "ordinary relayout should retain the user's peer proportion")
    }

    func testPeerDividerFractionSurvivesControllerRecreation() {
        let first = FilesRightSidebarSplitController()
        _ = first.install(leading: NSViewController(),
                          trailing: NSViewController(),
                          trailingCollapsed: false)
        first.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        first.view.layoutSubtreeIfNeeded()
        first.viewDidLayout()
        first.splitView.setPosition(330, ofDividerAt: 0)
        first.setTrailingCollapsed(true)

        let second = FilesRightSidebarSplitController()
        _ = second.install(leading: NSViewController(),
                           trailing: NSViewController(),
                           trailingCollapsed: false,
                           leadingFraction: first.expandedLeadingFraction)
        second.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        second.view.layoutSubtreeIfNeeded()
        second.viewDidLayout()

        XCTAssertEqual(second.splitView.arrangedSubviews[0].frame.width,
                       330, accuracy: 2,
                       "Columns must not erase the module's divider state")
    }

    func testGuestAndHostUseAFullRightSidebarRatherThanGuestOwnedChrome() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceShell.swift")
        let splitSource = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeSplitViews.swift")
        let hostBrowserSource = try GateSource.hostSwift(
            "now-host/Sources/Host/HostFileBrowser.swift")

        XCTAssertTrue(source.contains("FilesRightSidebarSplitView("))
        XCTAssertTrue(source.contains("isTrailingCollapsed:"))
        XCTAssertTrue(source.contains("leadingFraction: $mainPaneFraction"))
        XCTAssertTrue(source.contains("leading: FilesGuestPane("))
        XCTAssertTrue(source.contains("trailing: FilesRightSidebar("))
        XCTAssertTrue(source.contains(
            "titleAccessory: FilesRightSidebarToggle("),
            "the right sidebar must own its expanded collapse control")
        XCTAssertTrue(splitSource.contains(
            "FilesRightSidebarContainerController"),
            "the native trailing item must own both content and reopen rail")
        XCTAssertFalse(splitSource.contains("HStack(spacing: 0)"),
            "SwiftUI must not place a second rail outside the native split")
        XCTAssertFalse(source.contains("FilesGuestHeaderControls"),
                       "the guest must not own the right sidebar toggle")
        XCTAssertFalse(source.contains("let toggleHost:"),
                       "right-sidebar control must not route through the guest")
        XCTAssertTrue(source.contains("HostFilesSidebar("),
                      "the host peer needs the same navigable sidebar shape")
        XCTAssertTrue(source.contains("hostSidebarCompact"),
                      "the host sidebar must collapse to icons rather than hide")
        XCTAssertTrue(source.contains("model.hostSidebarCompact.toggle()"),
                      "the host sidebar state must outlive this view")
        XCTAssertTrue(source.contains("model.hostPaneCollapsed = collapsed"),
                      "the host peer collapse state must outlive this view")
        XCTAssertTrue(hostBrowserSource.contains("FilesHostFolderTitle"),
                      "the host toolbar must expose the native folder title")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "FilesBrowserRoot(").count - 1,
            2, "guest and host must use the same browser root")
        XCTAssertFalse(source.contains("HostBrowserPane"))
        XCTAssertTrue(source.contains("FilesHostModePill(mode: $mode"))
        XCTAssertTrue(source.contains("No Mac Connected"))
        XCTAssertTrue(splitSource.contains(
            "preferredThicknessFraction = 0.5"))
        XCTAssertTrue(splitSource.contains("canCollapse = false"))
        XCTAssertTrue(splitSource.contains("Show This Mac"))
        XCTAssertTrue(splitSource.contains("Hide This Mac"))
        XCTAssertFalse(source.contains("TabView"))
        XCTAssertFalse(splitSource.contains("override func mouseDragged"),
                       "AppKit must own divider dragging")
        XCTAssertTrue(splitSource.contains("override func drawDivider(in rect:"),
                      "the wider host edge should draw its grip in AppKit")
        XCTAssertTrue(splitSource.contains("usesSidebarHandle = true"),
                      "Finder-style column dividers must stay standard")
    }

    func testCompactPlacesKeepRowOwnedHelpDropAndSelectionBehavior() throws {
        let shell = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceShell.swift")
        let row = try GateSource.hostSwift(
            "now-host/Sources/Host/FileLocationRow.swift")
        let nativeRow = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeSidebarRow.swift")

        XCTAssertTrue(shell.contains("compact: compact"),
                      "the icon rail must keep using the full Place row")
        XCTAssertTrue(shell.contains("model.locations.isEmpty && !compact"),
                      "compact Places must not squeeze empty-state text into the icon rail")
        XCTAssertTrue(row.contains("toolTip: help"))
        XCTAssertTrue(row.contains("draggedTypes: Self.draggedTypes"))
        XCTAssertTrue(nativeRow.contains("NSSpringLoadingDestination"),
                      "both Place widths must use AppKit drag and spring loading")
        XCTAssertTrue(row.contains("model.isCurrentLocation(location)"),
                      "selection must share the model's navigation equality")
    }

    func testNativeFileDragAffordancesStaySharedAcrossBrowserModes() throws {
        let table = try GateSource.hostSwift(
            "now-host/Sources/Host/FileBrowserTable.swift")
        let tree = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesTreeBrowser.swift")
        let icons = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeBrowser.swift")
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeSidebarRow.swift")
        let host = try GateSource.hostSwift(
            "now-host/Sources/Host/HostFileBrowser.swift")

        for source in [table, tree, icons, sidebar] {
            XCTAssertTrue(source.contains("NSSpringLoadingDestination"))
            XCTAssertTrue(source.contains("wantsPeriodicDraggingUpdates"),
                "drag destinations need stationary updates for edge autoscroll")
            XCTAssertTrue(source.contains("override func draggingEnded"),
                "cancelled drags must clear spring-loaded target state")
        }
        XCTAssertTrue(table.contains("info.resetSpringLoading()"),
            "moving between list rows must restart AppKit's user-tuned delay")
        XCTAssertTrue(tree.contains("info.resetSpringLoading()"),
            "moving between tree rows must restart AppKit's user-tuned delay")
        XCTAssertTrue(icons.contains("info.resetSpringLoading()"),
            "moving between icons must restart AppKit's user-tuned delay")
        let columns = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesColumnBrowser.swift")
        XCTAssertTrue(columns.contains(
            "FilesDraggingBrowser: NSBrowser, NSDraggingSource"),
            "column drag lifecycle must work before macOS 27")
        XCTAssertTrue(columns.contains(
            "dragCoordinator?.beginDragging(pendingDraggedRows)"),
            "column drags must identify guest rows to sidebar destinations")
        XCTAssertTrue(columns.contains("dragCoordinator?.endDragging()"),
            "column drags must clear their guest-row source state")
        XCTAssertTrue(columns.contains(
            "setDraggingSourceOperationMask(localDragOperation"),
            "column drags must preserve guest move versus host copy semantics")
        XCTAssertTrue(sidebar.contains("springLoadingActivated"))
        XCTAssertTrue(sidebar.contains("performDragOperation"),
            "spring activation and final drop must stay separate callbacks")
        XCTAssertTrue(sidebar.contains("setAccessibilitySelected(isActive)"),
            "the native row must expose the active location to VoiceOver")
        XCTAssertTrue(sidebar.contains("guard isEnabled else"),
            "disconnected guest locations must not accept or spring-load drops")
        XCTAssertTrue(host.contains("FilesNativeSidebarRow("),
            "the host sidebar should use the same AppKit destination row")
        XCTAssertTrue(host.contains("receivePromisedFiles("),
            "guest file promises dropped on a host place must be received there")
    }

    func testFilesChromeUsesIndependentPanesAndSubduedAttachedBars() throws {
        let hostSource = GateSource.repoRoot
            .appendingPathComponent("now-host/Sources/Host")
        let supportingFiles = Set([
            "FileBrowserTable.swift", "FileLocationRow.swift",
            "GuestFileBrowserAdapter.swift", "HostFileBrowser.swift",
        ])
        let paths = try FileManager.default
            .contentsOfDirectory(at: hostSource,
                                 includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter {
                $0.hasSuffix(".swift")
                    && ($0.hasPrefix("Files") || supportingFiles.contains($0))
            }
            .map { "now-host/Sources/Host/\($0)" }
        let filesSource = try paths.map(GateSource.hostSwift).joined()
        let shell = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceShell.swift")
        let style = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesStyle.swift")
        let content = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeBrowser.swift")
        let nativeRow = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeSidebarRow.swift")

        XCTAssertFalse(filesSource.contains(".glassEffect("),
            "Files chrome must inherit OS and accessibility fallback policy")
        XCTAssertFalse(filesSource.contains(".thinMaterial"),
            "Files must not bypass the app-owned glass compatibility boundary")
        XCTAssertGreaterThanOrEqual(
            shell.components(separatedBy: ".nowGlassPanel(").count - 1, 2,
            "the breadcrumb and peer-mode capsule are floating chrome")
        XCTAssertFalse(shell.contains(".nowGlassBar()"),
            "attached title and navigation bars should not float above panes")
        XCTAssertTrue(shell.contains(".filesPaneChrome()"),
            "both machines should share the same subdued attached chrome")
        XCTAssertTrue(shell.contains(".filesPaneSurface()"),
            "the shared root should make each machine its own container")
        XCTAssertFalse(shell.contains(".clipShape(FilesStyle.outerSurfaceShape)"),
            "the workspace must not merge both machines into one outer slab")
        XCTAssertTrue(style.contains(".clipShape(FilesStyle.outerSurfaceShape)"))
        XCTAssertTrue(style.contains(".allowsHitTesting(false)"),
            "pane decoration must never intercept the native divider")
        XCTAssertTrue(style.contains("FilesStyle.outerSurfaceShape"))
        XCTAssertTrue(shell.contains("FilesStyle.controlShape"))
        XCTAssertTrue(content.contains("FilesStyle.rowSelectionCornerRadius"))
        XCTAssertTrue(nativeRow.contains(
            "FilesStyle.rowSelectionCornerRadius"))
    }

    func testSharedBrowserChromeUsesFinderStyleFolderTitleAndOneNativeRow()
        throws {
        let shell = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceShell.swift")
        let module = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesModuleView.swift")
        let host = try GateSource.hostSwift(
            "now-host/Sources/Host/HostFileBrowser.swift")
        let folderControl = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesCurrentFolderControl.swift")

        XCTAssertFalse(module.contains("private var header: some View"),
            "Files should open directly into the two browser containers")
        XCTAssertFalse(module.contains(
            "Move files between this Mac and the old world Mac."))
        XCTAssertTrue(shell.contains(
            "navigationControls: FilesNavigationButtons("))
        XCTAssertTrue(shell.contains(
            "viewControls: FilesBrowserViewPicker("))
        XCTAssertTrue(shell.contains("locationControl"))
        XCTAssertTrue(shell.contains("FilesGuestFolderTitle(model: model)"))
        XCTAssertTrue(host.contains("FilesHostFolderTitle"))
        XCTAssertTrue(folderControl.contains("FilesCurrentFolderButton"))
        XCTAssertTrue(folderControl.contains("rightMouseDown(with event:"))
        XCTAssertTrue(folderControl.contains(".contains(.command)"))
        XCTAssertTrue(folderControl.contains("NSMenu.popUpContextMenu"),
            "right-click and command-click must reveal the ancestor path")
        XCTAssertFalse(shell.contains("FilesGuestPathBar"))
        XCTAssertFalse(host.contains("HostFilesPathBar"))
        XCTAssertFalse(shell.contains("Approve One-Time Agent Transfer"),
            "the browser must not expose the agent-only approval stub")
        XCTAssertFalse(module.contains("approveForAgent("),
            "the Files view must not retain a hidden route to that stub")
        XCTAssertTrue(shell.contains("FilesGuestActions("))
        XCTAssertTrue(host.contains("HostFilesBrowserActions"))
    }

    func testCompactViewMenuAndGuestListHaveNoExtraWrapperOrActionColumn()
        throws {
        let shell = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceShell.swift")
        let table = try GateSource.hostSwift(
            "now-host/Sources/Host/FileBrowserTable.swift")
        let guest = try GateSource.hostSwift(
            "now-host/Sources/Host/GuestFileBrowserAdapter.swift")

        XCTAssertTrue(shell.contains("Toggle(isOn: Binding("),
            "compact view choices should be direct, checkmarked commands")
        XCTAssertTrue(shell.contains(
            ".accessibilityValue(Text(selection.title))"),
            "the compact picker should expose its current view")
        XCTAssertFalse(shell.contains(
            "Menu {\n                Picker(label, selection: $selection)"),
            "the compact menu must not add a Guest browser view submenu")
        XCTAssertFalse(table.contains("showsActionColumn"),
            "list view should contain file metadata columns only")
        XCTAssertFalse(table.contains("actionColumn = \"download\""))
        XCTAssertFalse(guest.contains("var showsActionColumn"))
        XCTAssertFalse(guest.contains("func downloadToolTip"))
    }

    func testFolderTitleBuildsNativeGuestAndHostAncestorMenus() {
        let guest = FilesCurrentFolderDisplay.guest(
            shareRoot: "Macintosh HD:Shared",
            breadcrumb: ["Projects", "NOW"], source: "PowerBook")
        XCTAssertEqual(guest.title, "NOW")
        XCTAssertEqual(guest.source, "PowerBook")
        XCTAssertEqual(guest.toolTip,
                       "Macintosh HD:Shared:Projects:NOW")
        XCTAssertEqual(guest.path.map(\.id), ["-1", "0", "1"])
        XCTAssertEqual(guest.path.map(\.title),
                       ["Shared", "Projects", "NOW"])

        let root = HostFileLocation(
            url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
            symbol: "externaldrive")
        let desktop = HostFileLocation(
            url: URL(fileURLWithPath: "/Users/test/Desktop"),
            name: "Desktop", symbol: "folder")
        let host = FilesCurrentFolderDisplay.host(
            breadcrumbs: [root, desktop], source: "Local")
        XCTAssertEqual(host.title, "Desktop")
        XCTAssertEqual(host.source, "Local")
        XCTAssertEqual(host.path.map(\.title), ["Macintosh HD", "Desktop"])
    }

    func testListViewUsesFinderColumnsAndNativeHeaderCustomization() throws {
        XCTAssertEqual(FilesListColumn.allCases,
                       [.name, .modified, .size, .kind])
        XCTAssertFalse(FilesListColumn.name.canHide)
        XCTAssertTrue(FilesListColumn.modified.canHide)
        XCTAssertLessThanOrEqual(
            FilesListColumn.allCases.map(\.defaultWidth).reduce(0, +),
            620,
            "the Finder column set must fit one half of a normal split workspace")

        let table = try GateSource.hostSwift(
            "now-host/Sources/Host/FileBrowserTable.swift")
        XCTAssertTrue(table.contains("table.autosaveTableColumns = true"))
        XCTAssertTrue(table.contains(
            "table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle"),
            "all four Finder columns must contract together with the pane")
        XCTAssertTrue(table.contains("\\(columnsAutosaveName).List.v2"),
            "the corrected defaults need a one-time autosave migration")
        XCTAssertTrue(table.contains("table.headerView?.menu = columnsMenu"))
        XCTAssertTrue(table.contains("column.isHidden.toggle()"))
        XCTAssertTrue(table.contains("specification.canHide"))
        XCTAssertTrue(table.contains("table.style = .fullWidth"))
        XCTAssertTrue(table.contains(
            "table.usesAlternatingRowBackgroundColors = false"))
        XCTAssertTrue(table.contains("scroll.hasHorizontalScroller = true"),
            "a narrow pane must scroll to trailing columns instead of clipping them")
    }

    func testColumnViewUsesQuickLookOnlyForHostLeaves() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesColumnBrowser.swift")
        XCTAssertTrue(source.contains("!node.row.isFolder"))
        XCTAssertTrue(source.contains("FilesQuickLookPreviewController"))
        XCTAssertTrue(source.contains("QLPreviewView(frame: .zero"))
        XCTAssertTrue(source.contains("FilesColumnLeafPreview("),
            "guest leaves need a metadata preview until redeemed locally")
    }

    func testCollapsedHostRailOwnsDelayedNativeDisclosureAndSpringLoading()
        throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeSplitViews.swift")
        XCTAssertTrue(source.contains("NSTrackingArea("))
        XCTAssertTrue(source.contains("static let hoverDelay"))
        XCTAssertTrue(source.contains("NSPopover()"))
        XCTAssertTrue(source.contains("preferredEdge: .minX"),
            "the trailing rail label should float inward, centered on the rail")
        XCTAssertTrue(source.contains("contentTintColor = .secondaryLabelColor"),
            "the symbol tint must resolve through the active AppKit appearance")
        XCTAssertTrue(source.contains("NSSpringLoadingDestination"))
        XCTAssertFalse(source.contains("disclosedRailWidth"),
            "hover disclosure must never resize and then recompress the split")
        XCTAssertFalse(source.contains("onDisclosureChanged"))
        XCTAssertTrue(source.contains("allowsSidebarDividerResize = !collapsed"),
            "the integrated rail must lock its native divider while collapsed")
    }

    func testCollapsedHostRailUsesCenteredInteractiveHandle() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeSplitViews.swift")
        XCTAssertTrue(source.contains("systemSymbolName: \"chevron.left\""))
        XCTAssertTrue(source.contains("iconView.centerYAnchor"),
            "the reopen affordance belongs at the rail center")
        XCTAssertTrue(source.contains("cursor: .pointingHand"),
            "the whole collapsed rail is an interactive reopen target")
        XCTAssertTrue(source.contains("static let hoverScale"))
        XCTAssertTrue(source.contains(
            "accessibilityDisplayShouldReduceMotion"))
        XCTAssertFalse(source.contains(
            "iconView.topAnchor.constraint(equalTo: topAnchor"))
    }

    func testNativeBrowserModesShareANonVibrantSurface() throws {
        let icons = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeBrowser.swift")
        let tree = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesTreeBrowser.swift")
        let list = try GateSource.hostSwift(
            "now-host/Sources/Host/FileBrowserTable.swift")
        let columns = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesColumnBrowser.swift")
        XCTAssertTrue(icons.contains(
            "collection.backgroundColors = [.controlBackgroundColor]"))
        XCTAssertTrue(tree.contains("outline.style = .plain"),
            "the content tree must not opt into sidebar vibrancy")
        XCTAssertTrue(tree.contains(
            "outline.backgroundColor = .controlBackgroundColor"))
        XCTAssertTrue(list.contains(
            "table.backgroundColor = .controlBackgroundColor"))
        XCTAssertTrue(columns.contains(
            "browser.backgroundColor = .controlBackgroundColor"))
    }

    func testSidebarSymbolsReResolveAcrossAppearanceChanges() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeSidebarRow.swift")
        XCTAssertTrue(source.contains("image?.isTemplate = true"))
        XCTAssertTrue(source.contains("viewDidChangeEffectiveAppearance"))
        XCTAssertTrue(source.contains(
            "performAsCurrentDrawingAppearance"))
        XCTAssertTrue(source.contains("usingColorSpace(.deviceRGB)"))
    }

    @MainActor
    func testSidebarSymbolTintActuallyChangesWithEffectiveAppearance() throws {
        let button = FilesSidebarRowButton()
        button.appearance = NSAppearance(named: .aqua)
        button.configure(
            title: "Desktop", symbolName: "folder", compact: true,
            isActive: false, isEnabled: true, toolTip: "Desktop",
            activate: {}, validateDrop: { _ in [] }, acceptDrop: { _ in false })
        let light = try XCTUnwrap(button.contentTintColor)
            .usingColorSpace(.deviceRGB)

        button.appearance = NSAppearance(named: .darkAqua)
        button.viewDidChangeEffectiveAppearance()
        let dark = try XCTUnwrap(button.contentTintColor)
            .usingColorSpace(.deviceRGB)

        XCTAssertTrue(button.image?.isTemplate == true)
        XCTAssertNotEqual(light, dark,
            "semantic sidebar tint must be re-resolved, not cached as white")
    }

    func testGuestAndHostUseTheSameNativeFileBrowser() throws {
        let views = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceViews.swift")
        let table = try GateSource.hostSwift(
            "now-host/Sources/Host/FileBrowserTable.swift")
        let guest = try GateSource.hostSwift(
            "now-host/Sources/Host/GuestFileBrowserAdapter.swift")
        let host = try GateSource.hostSwift(
            "now-host/Sources/Host/HostFileBrowser.swift")
        let hostViews = try GateSource.hostSwift(
            "now-host/Sources/Host/HostBrowserViews.swift")
        let content = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeBrowser.swift")
        let tree = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesTreeBrowser.swift")

        XCTAssertTrue(views.contains("FilesNativeBrowser("))
        XCTAssertTrue(hostViews.contains("FilesNativeBrowser("))
        XCTAssertEqual(
            content.components(separatedBy: "switch view").count - 1, 1,
            "all view-mode routing belongs to the shared browser root")
        XCTAssertTrue(content.contains("case .tree:"))
        XCTAssertTrue(tree.contains(
            "let outline = FilesSpringLoadingOutlineView()"),
            "tree mode should retain an NSOutlineView subclass with native spring loading")
        XCTAssertTrue(content.contains("FileBrowserTable(adapter: adapter)"))
        XCTAssertTrue(content.contains("FilesIconCollectionView("))
        XCTAssertFalse(hostViews.contains("List(model.items"),
            "the host must not regress to a gesture-driven SwiftUI list")
        XCTAssertFalse(views.contains("HostFilesBrowserContent"))
        XCTAssertTrue(table.contains("let table = BrowserTableView()"))
        XCTAssertTrue(table.contains(
            "table.doubleAction = #selector(Coordinator.doubleClicked"))
        XCTAssertTrue(table.contains(
            "coordinator?.performKeyAction(.open)"))
        XCTAssertTrue(table.contains(
            "private let adapter: any FilesBrowserTableAdapter"))
        XCTAssertFalse(table.contains("FilesBrowserTableTarget"))
        XCTAssertFalse(table.contains("FilesModuleModel"),
            "guest ownership belongs in its target adapter")
        XCTAssertFalse(table.contains("HostFilesBrowserModel"),
            "host ownership belongs in its target adapter")
        XCTAssertTrue(guest.contains(
            "final class GuestFileBrowserAdapter: FilesBrowserAdapter"))
        XCTAssertTrue(host.contains(
            "final class HostFileBrowserAdapter: FilesBrowserAdapter"))
        XCTAssertTrue(host.contains("return host.url as NSURL"),
            "host drags must publish the native file URL pasteboard type")
    }

    func testHostTargetListsMetadataAndNavigatesFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-host-browser-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let file = root.appendingPathComponent("Document.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: file)

        let model = HostFilesBrowserModel(root: root)
        try await waitUntil("host root listing") { model.items.count == 2 }
        XCTAssertEqual(model.items.map(\.name), ["Document.txt", "Folder"])
        XCTAssertEqual(model.items.first(where: {
            $0.name == "Document.txt"
        })?.sizeBytes, 5)
        let folderRow = try XCTUnwrap(model.items.first(where: \.isFolder))

        model.open(folderRow)
        try await waitUntil("host folder listing") {
            model.directory.standardizedFileURL
                == folder.standardizedFileURL && model.items.isEmpty
        }
        XCTAssertEqual(model.directory.standardizedFileURL,
                       folder.standardizedFileURL)
        XCTAssertTrue(model.canGoUp)
        model.goUp()
        try await waitUntil("host parent listing") { model.items.count == 2 }
        XCTAssertEqual(model.directory.standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertFalse(model.canGoUp)

        let adapter = HostFileBrowserAdapter(model: model)
        XCTAssertEqual(adapter.menuItems(for: .host(folderRow), selection: [])
            .compactMap(\.action), [.open, .showInFinder, .copyPath])
        XCTAssertEqual((adapter.pasteboardWriter(
            for: .host(try XCTUnwrap(model.items.first {
                $0.name == "Document.txt"
            })), promiseDelegate: nil) as? NSURL)?.path,
            file.path)

        let larger = root.appendingPathComponent("Larger.bin")
        try Data(repeating: 1, count: 10).write(to: larger)
        model.reload()
        try await waitUntil("host refreshed listing") { model.items.count == 3 }
        adapter.setSort(key: "size", ascending: false)
        XCTAssertEqual(model.items.first?.name, "Larger.bin")

        let outside = HostFileRow(
            url: root.deletingLastPathComponent(), isFolder: true,
            sizeBytes: 0, modified: nil, kind: "Folder")
        model.open(outside)
        XCTAssertEqual(model.directory.standardizedFileURL,
                       root.standardizedFileURL,
                       "host navigation must not escape its standardized root")

        let alias = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-host-browser-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(
            atPath: alias.path, withDestinationPath: root.path)
        let aliasModel = HostFilesBrowserModel(root: alias)
        try await waitUntil("host alias-root listing") {
            aliasModel.items.count == 3
        }
        let aliasFolder = try XCTUnwrap(
            aliasModel.items.first(where: \.isFolder),
            "alias root error=\(aliasModel.error ?? "none") "
                + "items=\(aliasModel.items.map { $0.name })")
        aliasModel.open(aliasFolder)
        aliasModel.goUp()
        XCTAssertFalse(aliasModel.canGoUp,
            "returning through a symlink alias must still recognize the root")
    }

    func testHostTargetExposesRootRelativeBreadcrumbsAndSidebarPlaces()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-host-places-\(UUID().uuidString)")
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let documents = root.appendingPathComponent(
            "Documents", isDirectory: true)
        let project = desktop.appendingPathComponent(
            "Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: documents, withIntermediateDirectories: true)

        let model = HostFilesBrowserModel(root: root)
        try await waitUntil("host sidebar places") {
            model.sidebarLocations.count == 3 && model.items.count == 2
        }

        XCTAssertEqual(model.sidebarLocations.map(\.name),
                       [root.lastPathComponent, "Desktop", "Documents"])
        XCTAssertEqual(model.breadcrumbs.map(\.name),
                       [root.lastPathComponent])

        let desktopPlace = try XCTUnwrap(
            model.sidebarLocations.first { $0.name == "Desktop" })
        model.go(to: desktopPlace)
        try await waitUntil("host Desktop listing") {
            model.directory == desktop.resolvingSymlinksInPath()
                && model.items.count == 1
        }
        XCTAssertTrue(model.isCurrentLocation(desktopPlace))

        model.open(try XCTUnwrap(model.items.first))
        try await waitUntil("host Project listing") {
            model.directory == project.resolvingSymlinksInPath()
        }
        XCTAssertEqual(model.breadcrumbs.map(\.name),
                       [root.lastPathComponent, "Desktop", "Project"])

        model.go(to: try XCTUnwrap(model.breadcrumbs.first))
        try await waitUntil("host breadcrumb root") {
            model.directory == root.resolvingSymlinksInPath()
                && model.items.count == 2
        }
        XCTAssertFalse(model.canGoUp)
    }

    func testBrowserChoicesPersistTogether() throws {
        let suite = "files.browser.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        var model: FilesModuleModel? = FilesModuleModel(
            listener: listener, defaults: defaults)

        model?.startupDirectory = .custom
        model?.customStartupPath = "System Folder:Extensions"
        model?.browserView = .columns
        model = nil

        let reopened = FilesModuleModel(listener: listener, defaults: defaults)
        XCTAssertEqual(reopened.startupDirectory, .custom)
        XCTAssertEqual(reopened.customStartupPath,
                       "System Folder:Extensions")
        XCTAssertEqual(reopened.browserView, .columns)
    }

    func testHostSidebarDefaultsCompactAndPersistsItsLastState() throws {
        let suite = "files.browser.host-sidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))

        var model: FilesModuleModel? = FilesModuleModel(
            listener: listener, defaults: defaults)
        XCTAssertEqual(model?.hostSidebarCompact, true)

        model?.hostSidebarCompact = false
        model = nil
        model = FilesModuleModel(listener: listener, defaults: defaults)
        XCTAssertEqual(model?.hostSidebarCompact, false)

        model?.hostSidebarCompact = true
        model = nil
        let reopened = FilesModuleModel(listener: listener, defaults: defaults)
        XCTAssertEqual(reopened.hostSidebarCompact, true)
    }

    func testHostPeerDefaultsExpandedAndPersistsItsLastState() throws {
        let suite = "files.browser.host-peer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))

        var model: FilesModuleModel? = FilesModuleModel(
            listener: listener, defaults: defaults)
        XCTAssertEqual(model?.hostPaneCollapsed, false)

        model?.hostPaneCollapsed = true
        model = nil
        model = FilesModuleModel(listener: listener, defaults: defaults)
        XCTAssertEqual(model?.hostPaneCollapsed, true)

        model?.hostPaneCollapsed = false
        model = nil
        let reopened = FilesModuleModel(listener: listener, defaults: defaults)
        XCTAssertEqual(reopened.hostPaneCollapsed, false)
    }

    func testGuestReconnectKeepsTheFolderForTheSameMachine() throws {
        let suite = "files.browser.same-machine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let model = FilesModuleModel(listener: listener, defaults: defaults)
        let machine = try XCTUnwrap(GuestID("powerbook-1400"))

        model.startupDirectory = .shareRoot
        model.connection = .connected(
            name: "PowerBook 1400",
            key: GuestKey(machine: machine, session: UUID()))
        model.go(toPath: "Projects:New Old World")
        XCTAssertEqual(model.path, "Projects:New Old World")

        model.connection = .disconnected
        model.connection = .connected(
            name: "PowerBook 1400",
            key: GuestKey(machine: machine, session: UUID()))

        XCTAssertEqual(model.path, "Projects:New Old World",
                       "a new socket must not turn the same Mac into a new browser")
    }

    func testCustomStartupPathIsAppliedWhenMachineFirstAppears() async throws {
        let result = try await exerciseStartup(
            .custom, path: "System Folder:Extensions", available: true)

        XCTAssertEqual(result.path, "System Folder:Extensions")
        XCTAssertNil(result.error)
        XCTAssertNil(result.notice)
    }

    func testInvalidCustomStartupFallsBackHonestlyToShareRoot() async throws {
        let result = try await exerciseStartup(
            .custom, path: "Missing", available: false)

        XCTAssertEqual(result.notice,
                       "The startup folder “Missing” is not available. "
                        + "Showing the share root instead: "
                        + "Missing is not available")
        XCTAssertEqual(result.path, "")
        XCTAssertNil(result.error)
    }

    func testShareRootAndLastUsedStartupChoicesApplyPerMachine() async throws {
        let root = try await exerciseStartup(
            .shareRoot, path: "", available: true)
        let last = try await exerciseStartup(
            .lastUsed, path: "Projects:NOW", available: true)

        XCTAssertEqual(root.path, "")
        XCTAssertEqual(last.path, "Projects:NOW")
        XCTAssertNil(root.error)
        XCTAssertNil(last.error)
    }

    func testInvalidLastUsedStartupFallsBackHonestlyToShareRoot() async throws {
        let result = try await exerciseStartup(
            .lastUsed, path: "Former Folder", available: false)

        XCTAssertEqual(result.path, "")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.notice,
                       "The startup folder “Former Folder” is not available. "
                        + "Showing the share root instead: "
                        + "Former Folder is not available")
    }

    func testOrdinaryNavigationRefusalDoesNotBecomeStartupFallback()
        async throws {
        let result = try await exerciseStartup(
            .custom, path: "Projects", available: true,
            ordinaryRefusalPath: "Missing")

        XCTAssertEqual(result.path, "Missing")
        XCTAssertEqual(result.error, "Missing is not available")
        XCTAssertNil(result.notice)
    }

    func testGuestPathNavigationNormalizesEmptySegmentsAndHFSCase() throws {
        let suite = "files.browser.paths.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let model = FilesModuleModel(listener: listener, defaults: defaults)
        model.connection = .connected(named: "Guest A")

        model.go(to: FileLocation(
            path: "System Folder::Extensions:", name: "Extensions",
            symbol: "folder", origin: .pinned))

        XCTAssertEqual(model.path, "System Folder:Extensions")
        XCTAssertEqual(model.pinnableName(
            for: "system folder:extensions:"), "Extensions",
            "HFS spelling variants must still name the active directory")
    }

    func testGuestAdapterRestoresSelectionIntoANewNativeTable() {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let model = FilesModuleModel(listener: listener)
        let row = FileRow(entry: FileEntry(
            name: "Read Me", kind: "file", fileType: "TEXT",
            creator: "ttxt", dataBytes: 4, rsrcBytes: 0,
            modified: nil, identity: "read-me"), path: "Read Me")
        model.selection = row.id
        let adapter = GuestFileBrowserAdapter(
            model: model, rows: [row], onOpen: { _ in },
            sort: .constant([]))

        XCTAssertEqual(adapter.selectedRowIDs, [row.id])
    }

    private func exerciseStartup(
        _ choice: FilesStartupDirectory,
        path: String,
        available: Bool,
        ordinaryRefusalPath: String? = nil
    ) async throws -> (path: String, error: String?, notice: String?) {
        let suite = "files.browser.startup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        defer { listener.stop() }
        try await waitUntil("listener") {
            if case .listening = listener.state { return true }
            return false
        }
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "test",
            name: "Guest A", os: "9.1", chunk: 8192)))
        try await waitUntil("guest") {
            if case .connected = listener.state { return true }
            return false
        }
        let key = try XCTUnwrap(listener.activeKey)
        guest.onMessage = { message in
            switch message {
            case .fileList(let request)
                where request.path == ordinaryRefusalPath:
                try? guest.send(.fileRefuse(FileRefuse(
                    id: request.id, code: "no-such-folder",
                    reason: "\(request.path) is not available")))
            case .fileList(let request) where request.path == path:
                if available {
                    try? guest.send(.fileListing(FileListing(
                        id: request.id, path: path, entries: [], more: false,
                        cursor: nil, root: "Macintosh HD:")))
                } else {
                    try? guest.send(.fileRefuse(FileRefuse(
                        id: request.id, code: "no-such-folder",
                        reason: "\(path) is not available")))
                }
            case .fileList(let request) where request.path.isEmpty:
                try? guest.send(.fileListing(FileListing(
                    id: request.id, path: "", entries: [], more: false,
                    cursor: nil, root: "Macintosh HD:")))
            case .fileList(let request):
                try? guest.send(.fileRefuse(FileRefuse(
                    id: request.id, code: "no-such-folder",
                    reason: "\(request.path) is not available")))
            case .softwareList(let request):
                try? guest.send(.softwareListing(SoftwareListing(
                    id: request.id, domain: request.domain, entries: [],
                    more: false, cursor: nil, note: nil)))
            default:
                break
            }
        }
        if choice == .lastUsed {
            defaults.set(path, forKey: "files.lastPath.\(key.machine.slug)")
        }
        let model = FilesModuleModel(listener: listener, defaults: defaults)
        model.startupDirectory = choice
        if choice == .custom { model.customStartupPath = path }
        model.connection = .connected(name: "Guest A", key: key)

        if available {
            try await waitUntil("startup listing") {
                model.path == path && !model.isLoading
            }
        } else {
            try await waitUntil("startup fallback") {
                model.path.isEmpty && model.lastNotice != nil
            }
        }
        if let ordinaryRefusalPath {
            try await waitUntil("startup Places discovery") {
                !model.isDiscoveringLocations
            }
            model.go(toPath: ordinaryRefusalPath)
            try await waitUntil("ordinary navigation refusal") {
                model.lastError == "\(ordinaryRefusalPath) is not available"
            }
        }
        return (model.path, model.lastError, model.lastNotice)
    }

}
