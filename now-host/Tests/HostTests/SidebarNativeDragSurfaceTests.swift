import AppKit
import XCTest
@testable import Host

/// The two sidebar-row behaviours that only break once AppKit is holding the
/// mouse: a modal menu eating the exit event, and spring loading being armed
/// against the wrong thing. Both were reported from a running build while the
/// code read as correct and the suites read as green.
@MainActor
final class SidebarNativeDragSurfaceTests: XCTestCase {

    /// `NSMenu.popUp` runs its own tracking loop, so the `mouseExited` that
    /// would clear the row's highlight is spent inside it. The row stayed lit
    /// until an unrelated enter/exit cycle happened to clear it.
    ///
    /// The order is the assertion. A resync that ran *before* the menu would
    /// be overwritten by the very event the menu is about to swallow.
    func testShelfMenuResynchronisesHoverAfterTheMenuCloses() throws {
        let window = offscreenWindow()
        let view = NativeNavigationDragView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(view)

        var log: [String] = []
        view.presentMenu = { _, _, _ in log.append("menu") }
        view.apply(configuration(hoverChanged: { log.append("hover:\($0)") }))

        view.showConfiguredMenu(with: try clickEvent(in: window))

        XCTAssertEqual(log, ["menu", "hover:false"],
                       "the row's hover state must be recomputed once the "
                         + "modal menu has given mouse dispatch back")
        window.orderOut(nil)
        withExtendedLifetime((window, view)) {}
    }

    /// The resync asks the pointer rather than assuming `false`: a person who
    /// dismissed the menu with Escape still has the pointer on the row, and
    /// unlighting it there is the same wrong state in the other direction.
    func testHoverResyncReadsThePointerRatherThanForcingAValue() throws {
        let source = try readSource()
        XCTAssertTrue(
            source.contains("mouseLocationOutsideOfEventStream"),
            "hover after the menu must come from where the pointer is")
        XCTAssertTrue(source.contains("synchroniseHoverWithPointer()"))
    }

    /// The whole row arms, not the band under the pointer.
    ///
    /// This is the H6 defect itself: arming resolved the band and refused
    /// unless *that* supported spring loading, and two of a row's three bands
    /// are `.zone` insertions, which never do. AppKit was told "no spring
    /// loading here" for most of the row, so the dwell it runs never
    /// completed and `springLoadingActivated` — the only caller of the double
    /// flash — had nothing to fire from.
    func testTheWholeRowArmsSpringLoadingNotJustItsCentre() throws {
        let row = try dragRow()

        for label in ["insertion band above", "centre", "insertion band below"] {
            let point = try XCTUnwrap(rowPoints[label])
            XCTAssertTrue(
                row.view.springLoadingEntered(row.info(at: point))
                    .contains(.enabled),
                "the \(label) must still arm the row for spring loading")
        }
    }

    /// Crossing a band boundary must not re-arm.
    ///
    /// Insertion feedback and the arm cannot share one state: the insertion
    /// line has to be reset on every crossing, and resetting the arm with it
    /// restarts AppKit's dwell — and, when a dwell does complete, offers a
    /// second activation for a row already sprung.
    func testCrossingABandDoesNotRearmTheRow() throws {
        let row = try dragRow()
        let centre = try XCTUnwrap(rowPoints["centre"])
        let above = try XCTUnwrap(rowPoints["insertion band above"])

        _ = row.view.draggingEntered(row.info(at: centre))
        _ = row.view.springLoadingEntered(row.info(at: centre))
        row.view.springLoadingActivated(true, draggingInfo: row.info(at: centre))
        XCTAssertEqual(row.springLoads.count, 1)
        XCTAssertNotNil(
            row.view.layer?.animation(forKey: "navigation-double-flash"),
            "the flash is the visible half of an activation")

        // Out to the gap above the row and back — the pointer never left it.
        _ = row.view.draggingUpdated(row.info(at: above))
        _ = row.view.springLoadingUpdated(row.info(at: above))
        _ = row.view.draggingUpdated(row.info(at: centre))
        _ = row.view.springLoadingUpdated(row.info(at: centre))
        row.view.springLoadingActivated(true, draggingInfo: row.info(at: centre))

        XCTAssertEqual(row.springLoads.count, 1,
                       "the row was already sprung; wandering across its own "
                         + "band boundary must not spring it again")
    }

    /// Arming ignores the bands; activating does not.
    ///
    /// A dwell spent aiming at the gap between two rows is aiming at an
    /// insertion, and springing the row open there is H7 in another costume —
    /// the shelf expands and the stack moves out from under a pointer that
    /// was deliberately held still.
    func testADwellAimedAtTheGapDoesNotSpringTheRowOpen() throws {
        let row = try dragRow()
        let above = try XCTUnwrap(rowPoints["insertion band above"])
        let centre = try XCTUnwrap(rowPoints["centre"])

        _ = row.view.draggingEntered(row.info(at: above))
        _ = row.view.springLoadingEntered(row.info(at: above))
        // Settled on the row, so the 20% band applies and this really is an
        // insertion rather than a first-contact centre.
        _ = row.view.draggingUpdated(row.info(at: above))
        row.view.springLoadingActivated(true, draggingInfo: row.info(at: above))
        XCTAssertEqual(row.springLoads.count, 0,
                      "an insertion line does not open anything")

        _ = row.view.draggingUpdated(row.info(at: centre))
        _ = row.view.springLoadingUpdated(row.info(at: centre))
        row.view.springLoadingActivated(true, draggingInfo: row.info(at: centre))
        XCTAssertEqual(row.springLoads.count, 1,
                       "and the activation the person did aim must still land")
    }

    // MARK: - Fixtures

    /// Window points, for a 100pt-tall row whose view fills its window. The
    /// view is flipped and the window is not, so a window y of 100 is the top
    /// of the row.
    private let rowPoints: [String: NSPoint] = [
        "insertion band above": NSPoint(x: 100, y: 96),
        "centre": NSPoint(x: 100, y: 50),
        "insertion band below": NSPoint(x: 100, y: 4)
    ]

    private struct DragRow {
        let view: NativeNavigationDragView
        let window: NSWindow
        let pasteboard: NSPasteboard
        let springLoads: SpringLoadLog

        func info(at windowPoint: NSPoint) -> StubDraggingInfo {
            StubDraggingInfo(location: windowPoint, pasteboard: pasteboard)
        }
    }

    /// A shelf row: its centre is the shelf itself, its outer bands insert
    /// into the zone around it. That is the shape H6 and H7 were reported on.
    private func dragRow() throws -> DragRow {
        let window = offscreenWindow(height: 100)
        let view = NativeNavigationDragView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(view)

        let payload = NavigationDraggedItem.module("chat")
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("now-test-nav-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(try XCTUnwrap(payload.pasteboardValue),
                             forType: NativeNavigationDragView.pasteboardType)

        let springLoads = SpringLoadLog()
        view.apply(NativeNavigationDragView.Configuration(
            payload: payload,
            target: .shelf(.network, beforeModuleID: nil),
            canDrop: { _, _ in true },
            previewDrop: { _, _ in true },
            performDrop: { _, _ in true },
            dragEnded: nil,
            activate: nil,
            springLoad: { springLoads.count += 1 },
            hoverChanged: nil,
            hoverDisclosure: nil,
            rowDropTargets: NavigationRowDropTargets(
                before: .zone(.upper, index: 0),
                center: .shelf(.network, beforeModuleID: nil),
                after: .zone(.upper, index: 1)),
            menuItems: [],
            menuHitRegion: .none))

        addTeardownBlock { pasteboard.releaseGlobally() }
        return DragRow(view: view, window: window,
                       pasteboard: pasteboard, springLoads: springLoads)
    }

    private func offscreenWindow(height: CGFloat = 40) -> NSWindow {
        // Far off any screen so the real pointer can never be inside it and
        // the hover answer is deterministic on whatever Mac runs this.
        NSWindow(contentRect: NSRect(x: -20_000, y: -20_000,
                                     width: 200, height: height),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    private func clickEvent(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func configuration(hoverChanged: @escaping (Bool) -> Void)
        -> NativeNavigationDragView.Configuration {
        NativeNavigationDragView.Configuration(
            payload: .shelf(.network),
            target: .shelf(.network, beforeModuleID: nil),
            canDrop: { _, _ in true },
            previewDrop: { _, _ in true },
            performDrop: { _, _ in true },
            dragEnded: nil,
            activate: nil,
            springLoad: {},
            hoverChanged: hoverChanged,
            hoverDisclosure: nil,
            rowDropTargets: nil,
            menuItems: [SidebarNativeMenuItem(
                title: "Connections", symbol: "network",
                payload: .shelf(.network), action: {}, dragEnded: { _ in })],
            menuHitRegion: .leadingIcon)
    }

    private func readSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "now-host/Sources/Host/SidebarNativeDragSurface.swift"),
            encoding: .utf8)
    }
}

/// How many times the row sprang. A reference so the configuration's escaping
/// closure and the assertion are looking at the same count.
final class SpringLoadLog {
    var count = 0
}

/// The drag AppKit would be holding. Everything the row asks of it is here —
/// where the pointer is and what is on the pasteboard — and the rest is the
/// protocol's own surface, which has to be spelled out to conform.
final class StubDraggingInfo: NSObject, NSDraggingInfo {
    private let location: NSPoint
    private let pasteboard: NSPasteboard

    init(location: NSPoint, pasteboard: NSPasteboard) {
        self.location = location
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .standard }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>)
            -> Void) {}
}
