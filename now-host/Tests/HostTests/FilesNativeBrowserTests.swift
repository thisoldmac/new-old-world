import AppKit
import XCTest
@testable import Host

@MainActor
final class FilesNativeBrowserTests: XCTestCase {
    func testOneInteractionRouterOwnsSingleAndDoubleClickSemantics() {
        let row = FilesBrowserRow.host(HostFileRow(
            url: URL(fileURLWithPath: "/tmp/Folder"), isFolder: true,
            sizeBytes: 0, modified: nil, kind: "Folder"))
        var selections: [[FilesBrowserRow]] = []
        var opened: [FilesBrowserRow] = []
        let router = FilesBrowserInteractionRouter(
            select: { selections.append($0) },
            open: { opened.append($0) })

        router.select([row])
        XCTAssertEqual(selections, [[row]])
        XCTAssertTrue(opened.isEmpty,
                      "a normal click selects; it must not also navigate")

        router.open(row)
        XCTAssertEqual(opened, [row],
                       "double-click and Return share one open path")
    }

    func testResponsivePolicyProgressivelyReducesChrome() {
        XCTAssertEqual(FilesResponsivePolicy.presentation(for: 1500),
                       .spacious)
        XCTAssertEqual(FilesResponsivePolicy.presentation(for: 1320),
                       .compactSidebars)
        XCTAssertEqual(FilesResponsivePolicy.presentation(for: 1120),
                       .compactChrome)
        XCTAssertEqual(FilesResponsivePolicy.presentation(for: 1_080),
                       .compactChrome)
        XCTAssertEqual(FilesResponsivePolicy.presentation(for: 980),
                       .guestOnly,
                       "a typical module width beside the app sidebar must not squeeze two browsers together")
        XCTAssertEqual(FilesResponsivePolicy.presentation(for: 620),
                       .guestOnly)
    }

    func testResponsivePresentationDoesNotRewriteSavedPreferences() {
        let preferences = FilesResponsivePreferences(
            guestSidebarCompact: false,
            hostSidebarCompact: false,
            hostPaneCollapsed: false)

        let compact = FilesResponsivePolicy.resolve(
            width: 1_080, preferences: preferences)
        XCTAssertTrue(compact.guestSidebarCompact)
        XCTAssertTrue(compact.hostSidebarCompact)
        XCTAssertFalse(compact.hostPaneCollapsed)
        XCTAssertEqual(preferences.hostSidebarCompact, false,
                       "derived presentation must not become a saved choice")

        let narrow = FilesResponsivePolicy.resolve(
            width: 980, preferences: preferences)
        XCTAssertTrue(narrow.hostPaneCollapsed)
        XCTAssertEqual(preferences.hostPaneCollapsed, false)
    }

    func testBothTargetsInstantiateOnlyTheSharedNativePrimitive() throws {
        let guest = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesWorkspaceViews.swift")
        let host = try GateSource.hostSwift(
            "now-host/Sources/Host/HostBrowserViews.swift")
        let primitive = try GateSource.hostSwift(
            "now-host/Sources/Host/FilesNativeBrowser.swift")

        XCTAssertTrue(guest.contains("FilesNativeBrowser("))
        XCTAssertTrue(host.contains("FilesNativeBrowser("))
        for legacyRoot in ["FilesBrowserContent(", "FilesIconBrowser(",
                           "FilesTreeBrowser(", "FilesColumnBrowser(",
                           "FileBrowserTable("] {
            XCTAssertFalse(guest.contains(legacyRoot))
            XCTAssertFalse(host.contains(legacyRoot))
        }
        XCTAssertTrue(primitive.contains("NSCollectionView"))
        XCTAssertTrue(primitive.contains("FileBrowserTable(adapter:"))
        XCTAssertTrue(primitive.contains("FilesTreeBrowser("))
        XCTAssertTrue(primitive.contains("FilesColumnBrowser("))
        XCTAssertTrue(primitive.contains("FilesBrowserAdapter"))
        XCTAssertFalse(primitive.contains("objectWillChange.send()"),
            "native controls must not be invalidated on every SwiftUI update")
        XCTAssertFalse(primitive.contains("NSHostingController"),
            "the shared router should not nest SwiftUI inside AppKit inside SwiftUI")
    }
}
