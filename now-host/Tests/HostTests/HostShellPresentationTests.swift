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
            "content.navigationSplitViewColumnWidth(136)"))
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
}
