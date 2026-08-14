import AppKit
import SwiftUI

/// One native outline browser for guest and host targets. Target models own
/// loading and file operations; the outline owns hierarchy, disclosure,
/// selection, keyboard behavior, and drag source semantics.
struct FilesTreeBrowser: NSViewRepresentable {
    let rootDirectoryKey: String
    let contentRevision: Int
    let children: (String) -> [FilesBrowserRow]
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
        contentRevision: Int,
        children: @escaping (String) -> [FilesBrowserRow],
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
        self.contentRevision = contentRevision
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

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FilesSpringLoadingOutlineView()
        outline.coordinator = context.coordinator
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Name"
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        // This is file content, not navigation furniture. Source-list style
        // adds sidebar vibrancy and made Tree the only glass browser mode.
        outline.style = .plain
        outline.backgroundColor = .controlBackgroundColor
        outline.rowHeight = 24
        outline.allowsMultipleSelection = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openSelection(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let outline = scroll.documentView as? NSOutlineView else {
            return
        }
        if coordinator.rootDirectoryKey != rootDirectoryKey {
            coordinator.resetRoot(to: rootDirectoryKey)
            outline.reloadData()
            return
        }
        guard coordinator.contentRevision != contentRevision else { return }
        coordinator.contentRevision = contentRevision
        coordinator.invalidateChildren()
        outline.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource,
                             NSOutlineViewDelegate,
                             NSFilePromiseProviderDelegate, NSMenuDelegate {
        var parent: FilesTreeBrowser
        private(set) var rootDirectoryKey: String
        var contentRevision: Int
        weak var outline: NSOutlineView?
        private var nodes: [String: Node] = [:]
        private var childrenByDirectory: [String: [Node]] = [:]
        private var springLoadingNode: Node?
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        init(parent: FilesTreeBrowser) {
            self.parent = parent
            rootDirectoryKey = parent.rootDirectoryKey
            contentRevision = parent.contentRevision
        }

        func resetRoot(to key: String) {
            rootDirectoryKey = key
            nodes.removeAll(keepingCapacity: true)
            childrenByDirectory.removeAll(keepingCapacity: true)
        }

        func invalidateChildren() {
            childrenByDirectory.removeAll(keepingCapacity: true)
        }

        func outlineView(_ outlineView: NSOutlineView,
                         numberOfChildrenOfItem item: Any?) -> Int {
            nodes(for: directoryKey(for: item)).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int,
                         ofItem item: Any?) -> Any {
            nodes(for: directoryKey(for: item))[index]
        }

        func outlineView(_ outlineView: NSOutlineView,
                         isItemExpandable item: Any) -> Bool {
            (item as? Node)?.row.isFolder == true
        }

        func outlineView(_ outlineView: NSOutlineView,
                         viewFor tableColumn: NSTableColumn?, item: Any)
            -> NSView? {
            guard let node = item as? Node else { return nil }
            let cell = NSTableCellView()
            let image = NSImageView(image: parent.icon(node.row))
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            let text = NSTextField(labelWithString: node.row.name)
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(image)
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor,
                                                constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor,
                                               constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = image
            cell.textField = text
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow)
                    as? Node else { return }
            parent.select(node.row)
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? Node
            else { return }
            parent.requestChildren(node.row)
        }

        func outlineView(_ outlineView: NSOutlineView,
                         pasteboardWriterForItem item: Any)
            -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            return parent.pasteboardWriter(node.row, self)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            parent.draggingWillBegin(draggedItems.compactMap {
                ($0 as? Node)?.row
            })
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            parent.draggingDidEnd()
        }

        @objc func openSelection(_ sender: NSOutlineView) {
            guard sender.selectedRow >= 0,
                  let node = sender.item(atRow: sender.selectedRow)
                    as? Node else { return }
            parent.open(node.row)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline,
                  outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow)
                    as? Node else { return }
            let selection = selectedRows(in: outline)
            for specification in parent.menuItems(node.row, selection) {
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
            guard let outline,
                  let raw = sender.representedObject as? String,
                  let action = FilesBrowserAction(rawValue: raw) else { return }
            let clicked = outline.clickedRow >= 0
                ? (outline.item(atRow: outline.clickedRow) as? Node)?.row : nil
            parent.perform(action, clicked, selectedRows(in: outline))
        }

        private func selectedRows(in outline: NSOutlineView)
            -> [FilesBrowserRow] {
            outline.selectedRowIndexes.compactMap {
                (outline.item(atRow: $0) as? Node)?.row
            }
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

        func springLoadingOptions(
            in outline: NSOutlineView, for info: NSDraggingInfo
        ) -> NSSpringLoadingOptions {
            let point = outline.convert(info.draggingLocation, from: nil)
            let row = outline.row(at: point)
            guard row >= 0,
                  let node = outline.item(atRow: row) as? Node,
                  node.row.isFolder else {
                springLoadingNode = nil
                return .disabled
            }
            if springLoadingNode !== node {
                springLoadingNode = node
                info.resetSpringLoading()
            }
            return .enabled
        }

        func updateSpringLoadingHighlight(
            in outline: NSOutlineView, for info: NSDraggingInfo
        ) {
            guard info.springLoadingHighlight != .none,
                  let node = springLoadingNode else {
                outline.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return
            }
            outline.setDropItem(node,
                                dropChildIndex: NSOutlineViewDropOnItemIndex)
        }

        func activateSpringLoadedNode(in outline: NSOutlineView) {
            guard let node = springLoadingNode else { return }
            parent.requestChildren(node.row)
            outline.expandItem(node)
        }

        func clearSpringLoading(in outline: NSOutlineView) {
            springLoadingNode = nil
            outline.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
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
        init(_ row: FilesBrowserRow) { self.row = row }
    }
}

@MainActor
private final class FilesSpringLoadingOutlineView: NSOutlineView,
    NSSpringLoadingDestination {
    weak var coordinator: FilesTreeBrowser.Coordinator?

    override func draggingUpdated(_ sender: NSDraggingInfo)
        -> NSDragOperation {
        FilesNativeDragAutoscroll.update(self)
        return super.draggingUpdated(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    func springLoadingEntered(_ draggingInfo: NSDraggingInfo)
        -> NSSpringLoadingOptions {
        coordinator?.springLoadingOptions(in: self, for: draggingInfo)
            ?? .disabled
    }

    func springLoadingUpdated(_ draggingInfo: NSDraggingInfo)
        -> NSSpringLoadingOptions {
        coordinator?.springLoadingOptions(in: self, for: draggingInfo)
            ?? .disabled
    }

    func springLoadingActivated(_ activated: Bool,
                                draggingInfo: NSDraggingInfo) {
        if activated { coordinator?.activateSpringLoadedNode(in: self) }
    }

    func springLoadingHighlightChanged(_ draggingInfo: NSDraggingInfo) {
        coordinator?.updateSpringLoadingHighlight(in: self, for: draggingInfo)
    }

    func springLoadingExited(_ draggingInfo: NSDraggingInfo) {
        coordinator?.clearSpringLoading(in: self)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        coordinator?.clearSpringLoading(in: self)
        super.draggingEnded(sender)
    }
}
