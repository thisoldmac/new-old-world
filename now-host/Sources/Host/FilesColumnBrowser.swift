import AppKit
import QuickLookUI
import SwiftUI

enum FilesColumnPath {
    static func selectionIndexes(
        root: String, target: String,
        children: (String) -> [FilesBrowserRow],
        contains: (String, String) -> Bool
    ) -> [Int]? {
        guard target != root else { return [] }
        var directory = root
        var indexes: [Int] = []
        var visited: Set<String> = []
        while directory != target, visited.insert(directory).inserted {
            let rows = children(directory)
            guard let index = rows.firstIndex(where: {
                $0.isFolder && contains(target, $0.path)
            }) else { return nil }
            indexes.append(index)
            directory = rows[index].path
        }
        return directory == target ? indexes : nil
    }

    static func selectionIndexes(
        root: String, itemIDs: [FilesBrowserRow.ID],
        children: (String) -> [FilesBrowserRow]
    ) -> [Int]? {
        var directory = root
        var indexes: [Int] = []
        for itemID in itemIDs {
            let rows = children(directory)
            guard let index = rows.firstIndex(where: { $0.id == itemID })
            else { return nil }
            indexes.append(index)
            directory = rows[index].path
        }
        return indexes
    }
}

/// One item-based AppKit column browser used by both file-system targets.
/// NSBrowser owns column expansion, keyboard selection, horizontal scrolling,
/// column resizing, and the leaf-only preview contract.
struct FilesColumnBrowser: NSViewRepresentable {
    let rootDirectoryKey: String
    let currentDirectoryKey: String
    let autosaveName: String
    let contentRevision: Int
    let localDragOperation: NSDragOperation
    let contains: (_ candidate: String, _ root: String) -> Bool
    let children: (_ directoryKey: String) -> [FilesBrowserRow]
    let requestChildren: (FilesBrowserRow) -> Void
    let icon: (FilesBrowserRow) -> NSImage
    let select: (FilesBrowserRow) -> Void
    let open: (FilesBrowserRow) -> Void
    let menuItems: (FilesBrowserRow, [FilesBrowserRow])
        -> [FilesBrowserMenuItem]
    let perform: (FilesBrowserAction, FilesBrowserRow?, [FilesBrowserRow])
        -> Void
    let pasteboardWriter: (
        FilesBrowserRow, NSFilePromiseProviderDelegate
    ) -> NSPasteboardWriting?
    let promisedFileName: (NSFilePromiseProvider) -> String
    let writePromise: (
        FilesBrowserRow, URL, @escaping (Error?) -> Void
    ) -> Void
    let draggingWillBegin: ([FilesBrowserRow]) -> Void
    let draggingDidEnd: () -> Void

    init(
        rootDirectoryKey: String,
        currentDirectoryKey: String,
        autosaveName: String,
        contentRevision: Int,
        localDragOperation: NSDragOperation,
        contains: @escaping (_ candidate: String, _ root: String) -> Bool,
        children: @escaping (_ directoryKey: String) -> [FilesBrowserRow],
        requestChildren: @escaping (FilesBrowserRow) -> Void,
        icon: @escaping (FilesBrowserRow) -> NSImage,
        select: @escaping (FilesBrowserRow) -> Void,
        open: @escaping (FilesBrowserRow) -> Void,
        menuItems: @escaping (FilesBrowserRow, [FilesBrowserRow])
            -> [FilesBrowserMenuItem] = { _, _ in [] },
        perform: @escaping (
            FilesBrowserAction, FilesBrowserRow?, [FilesBrowserRow]
        ) -> Void = { _, _, _ in },
        pasteboardWriter: @escaping (
            FilesBrowserRow, NSFilePromiseProviderDelegate
        ) -> NSPasteboardWriting? = { _, _ in nil },
        promisedFileName: @escaping (NSFilePromiseProvider) -> String = {
            _ in "Untitled"
        },
        writePromise: @escaping (
            FilesBrowserRow, URL, @escaping (Error?) -> Void
        ) -> Void = { _, _, completion in
            completion(CocoaError(.fileWriteUnknown))
        },
        draggingWillBegin: @escaping ([FilesBrowserRow]) -> Void = { _ in },
        draggingDidEnd: @escaping () -> Void = {}
    ) {
        self.rootDirectoryKey = rootDirectoryKey
        self.currentDirectoryKey = currentDirectoryKey
        self.autosaveName = autosaveName
        self.contentRevision = contentRevision
        self.localDragOperation = localDragOperation
        self.contains = contains
        self.children = children
        self.requestChildren = requestChildren
        self.icon = icon
        self.select = select
        self.open = open
        self.menuItems = menuItems
        self.perform = perform
        self.pasteboardWriter = pasteboardWriter
        self.promisedFileName = promisedFileName
        self.writePromise = writePromise
        self.draggingWillBegin = draggingWillBegin
        self.draggingDidEnd = draggingDidEnd
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = FilesDraggingBrowser()
        browser.delegate = context.coordinator
        browser.target = context.coordinator
        browser.action = #selector(Coordinator.selectionChanged(_:))
        browser.doubleAction = #selector(Coordinator.openSelection(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        browser.menu = menu
        browser.allowsMultipleSelection = false
        browser.allowsEmptySelection = true
        browser.takesTitleFromPreviousColumn = false
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.separatesColumns = true
        browser.columnResizingType = .userColumnResizing
        browser.prefersAllColumnUserResizing = false
        browser.minColumnWidth = 176
        browser.setDefaultColumnWidth(232)
        browser.rowHeight = 24
        browser.backgroundColor = .controlBackgroundColor
        browser.columnsAutosaveName = autosaveName
        browser.setDraggingSourceOperationMask(localDragOperation,
                                               forLocal: true)
        browser.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.localDragOperation = localDragOperation
        browser.dragCoordinator = context.coordinator
        context.coordinator.browser = browser
        browser.loadColumnZero()
        return browser
    }

    func updateNSView(_ browser: NSBrowser, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if !contains(currentDirectoryKey, coordinator.rootDirectoryKey) {
            coordinator.resetRoot(to: currentDirectoryKey)
            browser.loadColumnZero()
            return
        }
        if coordinator.contentRevision != contentRevision {
            coordinator.contentRevision = contentRevision
            coordinator.reloadColumnsPreservingSelection(in: browser)
        }
        if coordinator.currentDirectoryKey != currentDirectoryKey {
            coordinator.currentDirectoryKey = currentDirectoryKey
            coordinator.selectDirectory(currentDirectoryKey, in: browser)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate,
                             NSFilePromiseProviderDelegate, NSMenuDelegate {
        var parent: FilesColumnBrowser
        private(set) var rootDirectoryKey: String
        var currentDirectoryKey: String
        var contentRevision: Int
        weak var browser: NSBrowser?
        private var nodes: [String: Node] = [:]
        private var childrenByDirectory: [String: [Node]] = [:]
        private var isRestoringSelection = false
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        init(parent: FilesColumnBrowser) {
            self.parent = parent
            rootDirectoryKey = parent.rootDirectoryKey
            currentDirectoryKey = parent.currentDirectoryKey
            contentRevision = parent.contentRevision
        }

        func resetRoot(to key: String) {
            rootDirectoryKey = key
            currentDirectoryKey = key
            nodes.removeAll(keepingCapacity: true)
            childrenByDirectory.removeAll(keepingCapacity: true)
        }

        func selectDirectory(_ key: String, in browser: NSBrowser) {
            guard key != rootDirectoryKey else {
                browser.selectionIndexPath = nil
                if browser.lastColumn > 0 { browser.lastColumn = 0 }
                return
            }
            guard let indexes = FilesColumnPath.selectionIndexes(
                root: rootDirectoryKey, target: key,
                children: parent.children, contains: parent.contains)
            else { return }
            browser.selectionIndexPath = IndexPath(indexes: indexes)
            browser.scrollColumnToVisible(browser.lastColumn)
        }

        func invalidateChildren() {
            childrenByDirectory.removeAll(keepingCapacity: true)
            nodes.removeAll(keepingCapacity: true)
        }

        func reloadColumnsPreservingSelection(in browser: NSBrowser) {
            let selectedIDs = selectedItemIDs(in: browser)
            invalidateChildren()
            if browser.lastColumn < 0 {
                browser.loadColumnZero()
            } else {
                for column in stride(from: browser.lastColumn,
                                     through: 0, by: -1) {
                    browser.reloadColumn(column)
                }
            }
            guard !selectedIDs.isEmpty,
                  let indexes = FilesColumnPath.selectionIndexes(
                    root: rootDirectoryKey,
                    itemIDs: selectedIDs,
                    children: parent.children) else { return }
            isRestoringSelection = true
            browser.selectionIndexPath = IndexPath(indexes: indexes)
            isRestoringSelection = false
            browser.scrollColumnToVisible(browser.lastColumn)
        }

        func browser(_ browser: NSBrowser,
                     numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? Node, node.row.isFolder {
                parent.requestChildren(node.row)
            }
            return nodes(for: directoryKey(for: item)).count
        }

        func browser(_ browser: NSBrowser, child index: Int,
                     ofItem item: Any?) -> Any {
            nodes(for: directoryKey(for: item))[index]
        }

        func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
            (item as? Node)?.row.isFolder == false
        }

        func browser(_ browser: NSBrowser,
                     objectValueForItem item: Any?) -> Any? {
            (item as? Node)?.row.name
        }

        func browser(_ sender: NSBrowser, willDisplayCell cell: Any,
                     atRow row: Int, column: Int) {
            guard let browserCell = cell as? NSBrowserCell,
                  let node = sender.item(atRow: row, inColumn: column)
                    as? Node else { return }
            browserCell.image = parent.icon(node.row)
        }

        func browser(_ browser: NSBrowser,
                     previewViewControllerForLeafItem item: Any)
            -> NSViewController? {
            guard let node = item as? Node,
                  !node.row.isFolder else { return nil }
            if let hostRow = node.row.hostRow {
                return FilesQuickLookPreviewController(url: hostRow.url)
            }
            return NSHostingController(rootView: FilesColumnLeafPreview(
                item: node.row,
                icon: parent.icon(node.row),
                open: { [weak self] in
                    guard let self else { return }
                    self.parent.open(node.row)
                }))
        }

        @available(macOS 27.0, *)
        func browser(_ browser: NSBrowser, pasteboardWriterForRow row: Int,
                     column: Int) -> NSPasteboardWriting? {
            guard let node = browser.item(atRow: row, inColumn: column)
                    as? Node else { return nil }
            (browser as? FilesDraggingBrowser)?.pendingDraggedRows = [node.row]
            return parent.pasteboardWriter(node.row, self)
        }

        func browser(_ browser: NSBrowser,
                     writeRowsWith rowIndexes: IndexSet,
                     inColumn column: Int,
                     to pasteboard: NSPasteboard) -> Bool {
            let writers = rowIndexes.compactMap { row -> NSPasteboardWriting? in
                guard let node = browser.item(atRow: row, inColumn: column)
                        as? Node else { return nil }
                return parent.pasteboardWriter(node.row, self)
            }
            (browser as? FilesDraggingBrowser)?.pendingDraggedRows =
                rowIndexes.compactMap { row in
                    (browser.item(atRow: row, inColumn: column) as? Node)?.row
                }
            return !writers.isEmpty && pasteboard.writeObjects(writers)
        }

        func beginDragging(_ rows: [FilesBrowserRow]) {
            parent.draggingWillBegin(rows)
        }

        func endDragging() {
            parent.draggingDidEnd()
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            parent.promisedFileName(provider)
        }

        func operationQueue(for provider: NSFilePromiseProvider)
            -> OperationQueue { promiseQueue }

        func filePromiseProvider(
            _ provider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            let completion = FilesPromiseCompletion(completionHandler)
            guard let row = FilesBrowserRow.promisePayload(from: provider) else {
                Task { @MainActor in
                    completion.finish(CocoaError(.fileNoSuchFile))
                }
                return
            }
            Task { @MainActor in
                self.parent.writePromise(row, url, completion.finish)
            }
        }

        @objc func selectionChanged(_ sender: NSBrowser) {
            guard !isRestoringSelection else { return }
            guard let node = selectedNode(in: sender) else { return }
            parent.select(node.row)
        }

        @objc func openSelection(_ sender: NSBrowser) {
            guard let node = selectedNode(in: sender) else { return }
            if node.row.isFolder {
                parent.select(node.row)
            } else {
                parent.open(node.row)
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let browser, let clicked = clickedNode(in: browser) else {
                return
            }
            let selection = selectedNode(in: browser).map { [$0.row] } ?? []
            for specification in parent.menuItems(clicked.row, selection) {
                guard let action = specification.action else {
                    menu.addItem(.separator())
                    continue
                }
                let item = menu.addItem(
                    withTitle: specification.title,
                    action: #selector(performMenuAction(_:)),
                    keyEquivalent: specification.key)
                item.target = self
                item.keyEquivalentModifierMask = specification.modifiers
                item.representedObject = action.rawValue
            }
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let browser,
                  let raw = sender.representedObject as? String,
                  let action = FilesBrowserAction(rawValue: raw) else { return }
            let clicked = clickedNode(in: browser)?.row
            let selection = selectedNode(in: browser).map { [$0.row] } ?? []
            parent.perform(action, clicked, selection)
        }

        private func clickedNode(in browser: NSBrowser) -> Node? {
            guard browser.clickedColumn >= 0, browser.clickedRow >= 0 else {
                return nil
            }
            return browser.item(atRow: browser.clickedRow,
                                inColumn: browser.clickedColumn) as? Node
        }

        private func selectedNode(in browser: NSBrowser) -> Node? {
            let column = browser.selectedColumn
            guard column >= 0 else { return nil }
            let row = browser.selectedRow(inColumn: column)
            guard row >= 0 else { return nil }
            return browser.item(atRow: row, inColumn: column) as? Node
        }

        private func selectedItemIDs(in browser: NSBrowser)
            -> [FilesBrowserRow.ID] {
            guard let indexPath = browser.selectionIndexPath else { return [] }
            return (0..<indexPath.count).compactMap { column in
                browser.item(atRow: indexPath[column], inColumn: column)
                    .flatMap { ($0 as? Node)?.row.id }
            }
        }

        private func directoryKey(for item: Any?) -> String {
            (item as? Node)?.row.path ?? rootDirectoryKey
        }

        private func nodes(for directory: String) -> [Node] {
            if let cached = childrenByDirectory[directory] { return cached }
            let loaded = parent.children(directory).map { row in
                if let node = nodes[row.id] {
                    node.row = row
                    return node
                }
                let node = Node(row)
                nodes[row.id] = node
                return node
            }
            childrenByDirectory[directory] = loaded
            return loaded
        }
    }

    @MainActor
    private final class Node: NSObject {
        var row: FilesBrowserRow

        init(_ row: FilesBrowserRow) {
            self.row = row
        }
    }
}

/// Local files use the same Quick Look surface Finder uses. Remote guest files
/// retain the metadata preview because they have no local URL until redeemed.
@MainActor
final class FilesQuickLookPreviewController: NSViewController {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        guard let preview = QLPreviewView(frame: .zero, style: .compact)
        else {
            view = NSView()
            return
        }
        preview.previewItem = url as NSURL
        preview.autostarts = true
        view = preview
    }
}

/// NSBrowser's delegate drag lifecycle is macOS 27-only. The browser itself
/// remains the dragging source on every supported release, so owning the
/// NSDraggingSource callbacks here keeps guest move state correct on 13–26.
@MainActor
private final class FilesDraggingBrowser: NSBrowser, NSDraggingSource {
    weak var dragCoordinator: FilesColumnBrowser.Coordinator?
    var pendingDraggedRows: [FilesBrowserRow] = []
    var localDragOperation: NSDragOperation = .copy

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation {
        context == .withinApplication ? localDragOperation : .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint) {
        dragCoordinator?.beginDragging(pendingDraggedRows)
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragCoordinator?.endDragging()
        pendingDraggedRows = []
    }
}

private struct FilesColumnLeafPreview: View {
    let item: FilesBrowserRow
    let icon: NSImage
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
            Text(item.name).font(.title3.weight(.semibold))
            LabeledContent("Kind", value: item.kind)
            LabeledContent(
                "Size",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(item.sizeBytes), countStyle: .file))
            Text(item.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button("Open") { open() }
        }
        .padding(22)
        .frame(minWidth: 250, idealWidth: 280, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
