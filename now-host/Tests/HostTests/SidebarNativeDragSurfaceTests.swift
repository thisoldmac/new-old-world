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

    /// The arming seam, pinned where it is written.
    ///
    /// `NavigationRowDropTargets.springLoadingTarget` is unit-tested on its
    /// own, but the defect was the view asking the *band* under the pointer
    /// instead — and a call site reverting to `accepted(_:)` here would be
    /// silent: every pure test still passes, and the flash simply never
    /// fires again. Reading source is deliberate; the failure is an absence.
    func testSpringLoadingIsArmedFromTheRowSeamAndKeepsItsOwnState()
        throws {
        let source = try readSource()
        XCTAssertTrue(
            source.contains("springLoadingTarget(draggingInfo)"),
            "spring loading must arm from the row, not from the insertion "
              + "band the pointer happens to be over")
        XCTAssertTrue(
            source.contains("feedback: &springFeedback"),
            "arming shares state with the insertion line again — crossing a "
              + "band boundary would restart the hover dwell from zero")
    }

    // MARK: - Fixtures

    private func offscreenWindow() -> NSWindow {
        // Far off any screen so the real pointer can never be inside it and
        // the hover answer is deterministic on whatever Mac runs this.
        NSWindow(contentRect: NSRect(x: -20_000, y: -20_000,
                                     width: 200, height: 40),
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
