import AppKit
import XCTest
@testable import Host

@MainActor
final class FilesBrowserNavigationTests: XCTestCase {
    func testFreshGuestAndHostBrowsersDefaultToTree() throws {
        let suite = "files.browser.navigation.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))

        var model: FilesModuleModel? = FilesModuleModel(
            listener: listener, defaults: defaults)
        XCTAssertEqual(model?.browserView, .tree)
        XCTAssertEqual(model?.hostBrowserView, .tree)

        model?.browserView = .columns
        model?.hostBrowserView = .icons
        model = nil

        let reopened = FilesModuleModel(listener: listener, defaults: defaults)
        XCTAssertEqual(reopened.browserView, .columns)
        XCTAssertEqual(reopened.hostBrowserView, .icons)
    }

    func testNavigationHistoryReturnsBackwardAndForwardWithoutLoops() {
        var history = FilesBrowserNavigationHistory<String>()
        history.recordNavigation(from: "", to: "System Folder")
        history.recordNavigation(from: "System Folder",
                                 to: "System Folder:Extensions")

        XCTAssertEqual(history.goBack(from: "System Folder:Extensions"),
                       "System Folder")
        XCTAssertEqual(history.goBack(from: "System Folder"), "")
        XCTAssertNil(history.goBack(from: ""))
        XCTAssertEqual(history.goForward(from: ""), "System Folder")

        history.recordNavigation(from: "System Folder", to: "Applications")
        XCTAssertFalse(history.canGoForward,
                       "a new branch must discard the forward stack")
    }

    func testMouseButtonsAndSwipeResolveToBrowserHistoryActions() {
        XCTAssertEqual(FilesBrowserNavigationInput.action(forMouseButton: 3),
                       .back)
        XCTAssertEqual(FilesBrowserNavigationInput.action(forMouseButton: 4),
                       .forward)
        XCTAssertNil(FilesBrowserNavigationInput.action(forMouseButton: 2))
        XCTAssertEqual(FilesBrowserNavigationInput.action(forSwipeDeltaX: -1),
                       .back)
        XCTAssertEqual(FilesBrowserNavigationInput.action(forSwipeDeltaX: 1),
                       .forward)
        XCTAssertNil(FilesBrowserNavigationInput.action(forSwipeDeltaX: 0))
    }

    func testClassicRelativePathMarkersAreNotBrowserRows() {
        let folder: (String) -> FileEntry = {
            FileEntry(name: $0, kind: "folder", fileType: nil, creator: nil,
                      dataBytes: nil, rsrcBytes: nil, modified: nil)
        }
        XCTAssertTrue(FilesModuleModel.isVirtualDirectoryEntry(folder(":")))
        XCTAssertTrue(FilesModuleModel.isVirtualDirectoryEntry(folder("::")))
        XCTAssertFalse(FilesModuleModel.isVirtualDirectoryEntry(folder(".")),
                       "periods are legal Classic Mac filename characters")
        XCTAssertFalse(FilesModuleModel.isVirtualDirectoryEntry(folder("System Folder")))
    }

    func testNativeTreeAndColumnModesUseDistinctAppKitControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Host/FilesColumnBrowser.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NSBrowser"))
        XCTAssertTrue(source.contains("previewViewControllerForLeafItem"))
        XCTAssertTrue(source.contains("isLeafItem"))
        let tree = try String(contentsOf: root.appendingPathComponent(
            "Sources/Host/FilesTreeBrowser.swift"), encoding: .utf8)
        XCTAssertTrue(tree.contains("NSOutlineView"))
        let content = try String(contentsOf: root.appendingPathComponent(
            "Sources/Host/FilesNativeBrowser.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("case .tree:"))
        XCTAssertTrue(content.contains("FilesTreeBrowser("))
        XCTAssertFalse(content.contains("case .list, .tree"))
    }

    func testColumnPathResolvesNestedDirectorySelection() {
        let folder: (String, String) -> FilesBrowserRow = { name, path in
            .guest(FileRow(entry: FileEntry(
                name: name, kind: "folder", fileType: nil, creator: nil,
                dataBytes: nil, rsrcBytes: nil, modified: nil), path: path))
        }
        let rows = [
            "": [folder("System Folder", "System Folder")],
            "System Folder": [folder("Extensions",
                                      "System Folder:Extensions")],
        ]
        let indexes = FilesColumnPath.selectionIndexes(
            root: "", target: "System Folder:Extensions",
            children: { rows[$0] ?? [] },
            contains: { candidate, root in
                root.isEmpty || candidate == root
                    || candidate.hasPrefix(root + ":")
            })
        XCTAssertEqual(indexes, [0, 0])
    }

    func testColumnPathRestoresStableItemsAfterAListingRefresh() {
        let folder: (String, String) -> FilesBrowserRow = { name, path in
            .guest(FileRow(entry: FileEntry(
                name: name, kind: "folder", fileType: nil, creator: nil,
                dataBytes: nil, rsrcBytes: nil, modified: nil), path: path))
        }
        let rows = [
            "": [folder("Applications", "Applications"),
                 folder("System Folder", "System Folder")],
            "System Folder": [folder("Extensions",
                                      "System Folder:Extensions")],
        ]

        let indexes = FilesColumnPath.selectionIndexes(
            root: "",
            itemIDs: [rows[""]![1].id,
                      rows["System Folder"]![0].id],
            children: { rows[$0] ?? [] })

        XCTAssertEqual(indexes, [1, 0],
            "a refresh must restore the same items rather than dismissing the open column")
    }

    func testColumnRefreshKeepsTheOpenColumnSelection() throws {
        let folder = FilesBrowserRow.guest(FileRow(entry: FileEntry(
            name: "System Folder", kind: "folder", fileType: nil,
            creator: nil, dataBytes: nil, rsrcBytes: nil, modified: nil),
            path: "System Folder"))
        let child = FilesBrowserRow.guest(FileRow(entry: FileEntry(
            name: "Extensions", kind: "folder", fileType: nil,
            creator: nil, dataBytes: nil, rsrcBytes: nil, modified: nil),
            path: "System Folder:Extensions"))
        let rows = ["": [folder], "System Folder": [child]]
        let component = FilesColumnBrowser(
            rootDirectoryKey: "", currentDirectoryKey: "",
            autosaveName: "ColumnRefreshTest", contentRevision: 0,
            localDragOperation: .copy,
            contains: { candidate, root in
                root.isEmpty || candidate == root
                    || candidate.hasPrefix(root + ":")
            },
            children: { rows[$0] ?? [] },
            requestChildren: { _ in },
            icon: { _ in NSImage() },
            select: { _ in }, open: { _ in })
        let coordinator = component.makeCoordinator()
        let browser = NSBrowser()
        browser.delegate = coordinator
        browser.allowsEmptySelection = true
        browser.loadColumnZero()
        browser.selectionIndexPath = IndexPath(indexes: [0])
        XCTAssertEqual(browser.selectionIndexPath, IndexPath(indexes: [0]))

        coordinator.reloadColumnsPreservingSelection(in: browser)

        XCTAssertEqual(browser.selectionIndexPath, IndexPath(indexes: [0]))
        XCTAssertGreaterThanOrEqual(browser.lastColumn, 1,
            "loading a child listing must not make its selected parent collapse")
    }

    func testSupportedHostPlacesIncludeHomeFavoritesAndVolumes() {
        let root = URL(fileURLWithPath: "/tmp/Shared")
        let home = URL(fileURLWithPath: "/Users/Test")
        let localizedDownloads = URL(
            fileURLWithPath: "/Users/Test/Téléchargements")
        let volume = URL(fileURLWithPath: "/Volumes/Archive")
        let locations = HostFilesBrowserModel.standardSidebarLocations(
            sharedFolder: root, home: home,
            favoriteLocations: [.init(
                url: localizedDownloads, name: "Downloads",
                symbol: "arrow.down.circle")],
            mountedVolumes: [volume],
            isDirectory: { _ in true })

        XCTAssertEqual(locations.first?.url, root.standardizedFileURL)
        XCTAssertTrue(locations.contains { $0.url.path == home.path })
        XCTAssertTrue(locations.contains {
            $0.url.path == localizedDownloads.path
        })
        XCTAssertTrue(locations.contains { $0.url.path == volume.path })
    }

    func testHostPlacesDoNotDuplicateHomeWhenItIsShared() {
        let home = URL(fileURLWithPath: "/Users/Test")
        let locations = HostFilesBrowserModel.standardSidebarLocations(
            sharedFolder: home, home: home, favoriteLocations: [],
            mountedVolumes: [], isDirectory: { _ in true })
        XCTAssertEqual(locations.filter { $0.url == home }.count, 1)
    }

    func testNavigationButtonsCarrySpokenActionLabels() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Host/FilesBrowserNavigation.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityLabel(help)"))
    }
}
