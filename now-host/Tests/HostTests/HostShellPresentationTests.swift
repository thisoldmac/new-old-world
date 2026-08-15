import XCTest
@testable import Host

final class HostShellPresentationTests: XCTestCase {
    /// The unified full-size titlebar intentionally lets the sidebar material
    /// continue behind AppKit's traffic lights. The divider itself must stay
    /// beyond that cluster when the navigation rows collapse to icons.
    func testCollapsedSidebarKeepsTheDividerClearOfWindowControls() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")

        XCTAssertTrue(source.contains(
            "content.navigationSplitViewColumnWidth(120)"))
        XCTAssertFalse(source.contains(
            "content.navigationSplitViewColumnWidth(64)"))
    }

    /// A `Label` inside a toolbar inherits the toolbar's icon-only label
    /// style. The picker uses its own label view so the selected machine name
    /// and its live connection dot remain visible together.
    func testGuestPickerCarriesNameAndLiveStatusIntoTheToolbar() throws {
        let root = try GateSource.hostSwift(
            "now-host/Sources/Host/HostRootView.swift")
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSidebarView.swift")

        XCTAssertTrue(root.contains("monitor: state.guestStatus"))
        XCTAssertTrue(root.contains("status: monitor.status"))
        XCTAssertTrue(sidebar.contains(
            "GuestSelectionLabel(name: activeLabel, status: status)"))
        XCTAssertTrue(sidebar.contains(
            "GuestConnectionStatusDot(status: status)"))
    }

    func testCollapsedRowsUseDelayedNativeHoverDisclosure() throws {
        let sidebar = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarNavigationContent.swift")
        let native = try GateSource.hostSwift(
            "now-host/Sources/Host/SidebarHoverDisclosure.swift")

        XCTAssertTrue(sidebar.contains("hoverDisclosure: collapsed"))
        XCTAssertTrue(native.contains("NSPopover"))
        XCTAssertTrue(native.contains("450_000_000"),
                      "the disclosure should wait long enough to ignore cursor transit")
        XCTAssertTrue(native.contains("behavior = .transient"))
    }

    func testLiquidGlassControlIsContinuous() throws {
        let settings = try GateSource.hostSwift(
            "now-host/Sources/Host/HostSettingsView.swift")

        XCTAssertTrue(settings.contains("Slider(value: glassAmount, in: 0...1)"))
        XCTAssertFalse(settings.contains("Slider(value: glassAmount, in: 0...1, step:"))
    }
}
