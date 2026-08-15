import AppKit
import SwiftUI

/// One browser surface for both filesystems. The host and guest adapters only
/// describe a tree and its operations; this controller owns mode switching and
/// routes every native control through the same selection/open contract.
///
/// AppKit remains responsible for the actual Finder-shaped controls:
/// NSCollectionView, NSTableView, NSOutlineView, and NSBrowser.
struct FilesNativeBrowser: View {
    let view: FilesBrowserView
    let adapter: any FilesBrowserAdapter

    var body: some View {
        FilesNativeBrowserModeRoot(view: view, adapter: adapter)
    }
}

@MainActor
struct FilesBrowserInteractionRouter {
    let selectAction: ([FilesBrowserRow]) -> Void
    let openAction: (FilesBrowserRow) -> Void

    init(select: @escaping ([FilesBrowserRow]) -> Void,
         open: @escaping (FilesBrowserRow) -> Void) {
        selectAction = select
        openAction = open
    }

    func select(_ rows: [FilesBrowserRow]) { selectAction(rows) }
    func open(_ row: FilesBrowserRow) { openAction(row) }
}

private struct FilesNativeBrowserModeRoot: View {
    let view: FilesBrowserView
    let adapter: any FilesBrowserAdapter

    var body: some View {
        let router = FilesBrowserInteractionRouter(
            select: adapter.setSelection,
            open: adapter.open)
        switch view {
        case .icons:
            FilesIconCollectionView(adapter: adapter, router: router)
        case .list:
            FileBrowserTable(adapter: adapter)
        case .tree:
            FilesTreeBrowser(
                rootDirectoryKey: adapter.rootDirectoryKey,
                contentRevision: adapter.contentRevision,
                children: adapter.children,
                requestChildren: adapter.requestChildren,
                icon: adapter.icon,
                select: { router.select([$0]) },
                open: router.open,
                menuItems: adapter.menuItems,
                perform: adapter.perform,
                pasteboardWriter: adapter.pasteboardWriter,
                promisedFileName: adapter.promisedFileName,
                writePromise: adapter.writePromise,
                draggingWillBegin: adapter.draggingWillBegin,
                draggingDidEnd: adapter.draggingDidEnd)
        case .columns:
            FilesColumnBrowser(
                rootDirectoryKey: adapter.rootDirectoryKey,
                currentDirectoryKey: adapter.currentDirectoryKey,
                autosaveName: adapter.columnsAutosaveName,
                contentRevision: adapter.contentRevision,
                localDragOperation: adapter.localDragOperation,
                contains: adapter.contains,
                children: adapter.children,
                requestChildren: adapter.requestChildren,
                icon: adapter.icon,
                select: { router.select([$0]) },
                open: router.open,
                menuItems: adapter.menuItems,
                perform: adapter.perform,
                pasteboardWriter: adapter.pasteboardWriter,
                promisedFileName: adapter.promisedFileName,
                writePromise: adapter.writePromise,
                draggingWillBegin: adapter.draggingWillBegin,
                draggingDidEnd: adapter.draggingDidEnd)
        }
    }
}

private struct FilesIconCollectionView: NSViewRepresentable {
    let adapter: any FilesBrowserAdapter
    let router: FilesBrowserInteractionRouter

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 124, height: 104)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14,
                                           bottom: 14, right: 14)

        let collection = FilesIconCollection()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.coordinator = context.coordinator
        collection.registerForDraggedTypes(adapter.registeredDraggedTypes)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        collection.menu = menu
        collection.register(FilesIconCollectionItem.self,
                            forItemWithIdentifier: Coordinator.itemID)
        collection.setDraggingSourceOperationMask(
            adapter.localDragOperation, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        collection.addGestureRecognizer(doubleClick)

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        collection.backgroundColors = [.controlBackgroundColor]
        context.coordinator.collection = collection
        context.coordinator.reload(with: adapter.rows)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload(with: adapter.rows)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource,
                             NSCollectionViewDelegate,
                             NSFilePromiseProviderDelegate, NSMenuDelegate {
        static let itemID = NSUserInterfaceItemIdentifier("FilesIconItem")
        var parent: FilesIconCollectionView
        var rows: [FilesBrowserRow] = []
        weak var collection: NSCollectionView?
        private var restoringSelection = false
        var contextIndexPath: IndexPath?
        private var springLoadingIndexPath: IndexPath?
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        init(parent: FilesIconCollectionView) { self.parent = parent }

        func reload(with newRows: [FilesBrowserRow]) {
            guard let collection else {
                rows = newRows
                return
            }
            if rows != newRows {
                rows = newRows
                collection.reloadData()
            }
            let selection = Set(parent.adapter.selectedRowIDs)
            let indexes = Set(rows.indices.compactMap { index in
                selection.contains(rows[index].id)
                    ? IndexPath(item: index, section: 0) : nil
            })
            guard collection.selectionIndexPaths != indexes else { return }
            restoringSelection = true
            collection.selectionIndexPaths = indexes
            restoringSelection = false
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            rows.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath)
            -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: Self.itemID, for: indexPath)
            guard let item = item as? FilesIconCollectionItem,
                  rows.indices.contains(indexPath.item) else { return item }
            let row = rows[indexPath.item]
            item.configure(name: row.name, icon: parent.adapter.icon(for: row),
                           toolTip: row.path)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !restoringSelection else { return }
            parent.router.select(rows(at: indexPaths))
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard !restoringSelection else { return }
            parent.router.select(rows(at: collectionView.selectionIndexPaths))
        }

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath)
            -> NSPasteboardWriting? {
            guard rows.indices.contains(indexPath.item) else { return nil }
            return parent.adapter.pasteboardWriter(
                for: rows[indexPath.item], promiseDelegate: self)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            parent.adapter.draggingWillBegin(rows(at: indexPaths))
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            parent.adapter.draggingDidEnd()
        }

        @objc func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended, let collection else { return }
            let point = recognizer.location(in: collection)
            guard let index = collection.indexPathForItem(at: point),
                  rows.indices.contains(index.item) else { return }
            parent.router.open(rows[index.item])
        }

        func openSelection() {
            guard let row = rows(at: collection?.selectionIndexPaths ?? []).first
            else { return }
            parent.router.open(row)
        }

        func performKeyAction(_ action: FilesBrowserAction) {
            let selection = rows(at: collection?.selectionIndexPaths ?? [])
            parent.adapter.perform(action, clicked: selection.first,
                                   selection: selection)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let index = contextIndexPath,
                  rows.indices.contains(index.item) else { return }
            let clicked = rows[index.item]
            let selection = rows(at: collection?.selectionIndexPaths ?? [])
            for specification in parent.adapter.menuItems(
                for: clicked, selection: selection) {
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
            guard let raw = sender.representedObject as? String,
                  let action = FilesBrowserAction(rawValue: raw) else { return }
            let clicked = contextIndexPath.flatMap { index in
                rows.indices.contains(index.item) ? rows[index.item] : nil
            }
            let selection = rows(at: collection?.selectionIndexPaths ?? [])
            parent.adapter.perform(action, clicked: clicked,
                                   selection: selection)
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            parent.adapter.promisedFileName(provider)
        }

        func operationQueue(for provider: NSFilePromiseProvider)
            -> OperationQueue { promiseQueue }

        func filePromiseProvider(
            _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
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
                self.parent.adapter.writePromise(
                    row, to: url, completion: completion.finish)
            }
        }

        func springLoadingOptions(
            in collection: NSCollectionView, for info: NSDraggingInfo
        ) -> NSSpringLoadingOptions {
            let point = collection.convert(info.draggingLocation, from: nil)
            guard let index = collection.indexPathForItem(at: point),
                  rows.indices.contains(index.item), rows[index.item].isFolder
            else {
                springLoadingIndexPath = nil
                return .disabled
            }
            if springLoadingIndexPath != index {
                setSpringLoadingHighlight(false, in: collection)
                springLoadingIndexPath = index
                info.resetSpringLoading()
            }
            return .enabled
        }

        func updateSpringLoadingHighlight(
            in collection: NSCollectionView, for info: NSDraggingInfo
        ) {
            setSpringLoadingHighlight(
                info.springLoadingHighlight != .none, in: collection)
        }

        func activateSpringLoadedItem() {
            guard let index = springLoadingIndexPath,
                  rows.indices.contains(index.item), rows[index.item].isFolder
            else { return }
            springLoadingIndexPath = nil
            parent.router.open(rows[index.item])
        }

        func clearSpringLoading(in collection: NSCollectionView) {
            setSpringLoadingHighlight(false, in: collection)
            springLoadingIndexPath = nil
        }

        private func setSpringLoadingHighlight(
            _ highlighted: Bool, in collection: NSCollectionView
        ) {
            guard let index = springLoadingIndexPath,
                  let item = collection.item(at: index)
                    as? FilesIconCollectionItem else { return }
            item.setSpringLoadingHighlight(highlighted)
        }

        private func rows(at paths: Set<IndexPath>) -> [FilesBrowserRow] {
            paths.sorted { $0.item < $1.item }.compactMap {
                rows.indices.contains($0.item) ? rows[$0.item] : nil
            }
        }
    }
}

@MainActor
private final class FilesIconCollection: NSCollectionView,
    NSSpringLoadingDestination {
    weak var coordinator: FilesIconCollectionView.Coordinator?

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
        if activated { coordinator?.activateSpringLoadedItem() }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.contextIndexPath = indexPathForItem(at: point)
        if let index = coordinator?.contextIndexPath,
           !selectionIndexPaths.contains(index) {
            selectionIndexPaths = [index]
        }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let action = FileBrowserKeyAction.resolve(
            modifiers: event.modifierFlags, keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers)
        switch action {
        case .open:
            coordinator?.openSelection()
        case .download:
            coordinator?.performKeyAction(.download)
        case .newFolder:
            coordinator?.performKeyAction(.newFolder)
        case .trash:
            coordinator?.performKeyAction(.trash)
        case nil:
            super.keyDown(with: event)
        }
    }
}

private final class FilesIconCollectionItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = FilesStyle.rowSelectionCornerRadius
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.font = .systemFont(ofSize: 13)
        view.addSubview(icon)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 7),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                           constant: 6),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                            constant: -6),
        ])
    }

    override var isSelected: Bool {
        didSet {
            updateBackground()
        }
    }

    private var isSpringLoadingHighlighted = false

    func setSpringLoadingHighlight(_ highlighted: Bool) {
        guard isSpringLoadingHighlighted != highlighted else { return }
        isSpringLoadingHighlighted = highlighted
        updateBackground()
    }

    private func updateBackground() {
        let alpha: CGFloat = isSpringLoadingHighlighted ? 0.30
            : isSelected ? 0.20 : 0
        view.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(alpha).cgColor
    }

    func configure(name: String, icon image: NSImage, toolTip: String) {
        icon.image = image
        label.stringValue = name
        view.toolTip = toolTip
        view.setAccessibilityLabel(name)
    }
}
