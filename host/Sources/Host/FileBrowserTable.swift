import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The browser's table, in AppKit.
///
/// SwiftUI's Table cannot be a drag SOURCE for files: dragging a row
/// moves the selection instead, and file promises — the only honest way
/// to drag a file that does not exist locally yet — have no equivalent.
/// A Finder-shaped browser needs both, so this is an NSTableView with
/// its own drag source, drop destination, and multiple selection, which
/// is also how it behaves the way a Mac user expects.
struct FileBrowserTable: NSViewRepresentable {
    @ObservedObject var model: FilesModuleModel
    var rows: [FileRow]
    var onOpen: (FileRow) -> Void
    @Binding var sort: [KeyPathComparator<FileRow>]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 20
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        /* A drag out of here carries a file PROMISE, not a URL, so the
           table has to accept promise types or a drag that started in
           this very view is never offered to validateDrop — which is
           why dragging a row onto a folder did nothing. Folders drag
           under a private type, since they have no promise. */
        table.registerForDraggedTypes(
            [.fileURL, Coordinator.localRow]
            + NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType($0)
            })
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.sortDescriptors = [
            NSSortDescriptor(key: "name", ascending: true),
        ]
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Inside the browser a drag rearranges the share rather than
        // copying out of it, so the two directions differ.
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        for (id, title, width) in [
            ("name", "Name", CGFloat(260)), ("kind", "Kind", 120),
            ("size", "Size", 90), ("modified", "Modified", 150),
        ] {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype =
                NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Reload ONLY when the contents actually changed. SwiftUI
        // re-runs this for any state change — a ticking clock was enough
        // — and reloadData drops the selection every time, which is why
        // a selection would survive a moment and then vanish.
        guard context.coordinator.rows != rows else { return }
        let table = scroll.documentView as? NSTableView
        let selectedIDs = Set(context.coordinator.selectedRows.map(\.id))
        context.coordinator.rows = rows
        table?.reloadData()
        // Keep the same FILES selected across a refresh, not the same
        // row numbers: a listing can reorder under you.
        let restored = IndexSet(rows.indices.filter {
            selectedIDs.contains(rows[$0].id)
        })
        if !restored.isEmpty {
            table?.selectRowIndexes(restored, byExtendingSelection: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource,
                             NSTableViewDelegate, NSMenuDelegate,
                             NSFilePromiseProviderDelegate {
        var parent: FileBrowserTable
        var rows: [FileRow] = []
        weak var table: NSTableView?
        /// Rows being dragged, keyed by the promise handed to the Finder,
        /// since the Finder asks for the bytes long after the drag began.
        private var promised: [ObjectIdentifier: FileRow] = [:]
        private let queue = OperationQueue()

        init(_ parent: FileBrowserTable) {
            self.parent = parent
        }

        // MARK: - Contents

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        /// AppKit passes row -1 for "on the table, not on a row", and a
        /// bare `row < rows.count` is true for -1. Every index from
        /// AppKit goes through here.
        private func item(at index: Int) -> FileRow? {
            index >= 0 && index < rows.count ? rows[index] : nil
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let item = item(at: row), let column = tableColumn else {
                return nil
            }
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: 12)

            switch column.identifier.rawValue {
            case "name":
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 5
                let icon = NSImageView(image: NSImage(
                    systemSymbolName: item.symbolName,
                    accessibilityDescription: nil) ?? NSImage())
                icon.contentTintColor = item.isFolder
                    ? .controlAccentColor : .secondaryLabelColor
                text.stringValue = item.name
                if parent.model.renaming == item.id {
                    // A rename is an edit of the name in place, which is
                    // how it works everywhere else on this machine.
                    text.isEditable = true
                    text.isSelectable = true
                    text.isBordered = true
                    text.drawsBackground = true
                    text.target = self
                    text.action = #selector(commitRename(_:))
                    text.identifier = NSUserInterfaceItemIdentifier(item.id)
                    /* becomeFirstResponder on a field that is not in a
                       window yet quietly fails, which left the row
                       editable but unfocused. Ask the window once the
                       view is actually in one, then select the base
                       name the way the Finder does — the extension is
                       rarely what you are changing. */
                    DispatchQueue.main.async { [weak text] in
                        guard let text, let window = text.window else {
                            return
                        }
                        window.makeFirstResponder(text)
                        guard let editor = text.currentEditor() else { return }
                        let name = text.stringValue
                        let stem = (name as NSString).deletingPathExtension
                        editor.selectedRange = stem.isEmpty || stem == name
                            ? NSRange(location: 0, length: (name as NSString).length)
                            : NSRange(location: 0, length: (stem as NSString).length)
                    }
                }
                stack.addArrangedSubview(icon)
                stack.addArrangedSubview(text)
                if let note = item.conversionNote {
                    let badge = NSTextField(labelWithString: note)
                    badge.font = .systemFont(ofSize: 9)
                    badge.textColor = .secondaryLabelColor
                    stack.addArrangedSubview(badge)
                }
                return stack
            case "kind":
                text.stringValue = item.kind
                text.textColor = .secondaryLabelColor
            case "size":
                text.stringValue = item.isFolder ? "—"
                    : ByteCountFormatter.string(
                        fromByteCount: Int64(item.sizeBytes),
                        countStyle: .file)
                text.alignment = .right
                text.textColor = .secondaryLabelColor
            default:
                text.stringValue = item.modified.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "—"
                text.textColor = .secondaryLabelColor
            }
            return text
        }

        /// Header clicks. The comparators live in SwiftUI state so the
        /// sort survives a reload; without this the columns looked
        /// sortable and did nothing.
        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key else { return }
            let ascending = descriptor.ascending
            let order: SortOrder = ascending ? .forward : .reverse
            switch key {
            case "kind":
                parent.sort = [KeyPathComparator(\FileRow.kind,
                                                 order: order)]
            case "size":
                parent.sort = [KeyPathComparator(\FileRow.sizeBytes,
                                                 order: order)]
            case "modified":
                parent.sort = [KeyPathComparator(\FileRow.sortableDate,
                                                 order: order)]
            default:
                parent.sort = [KeyPathComparator(\FileRow.name,
                                                 order: order)]
            }
        }

        var selectedRows: [FileRow] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { item(at: $0) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            // The module's actions follow the selection; without this
            // they had nothing to act on and stayed hidden.
            parent.model.selection = selectedRows.first?.id
        }

        /// Right-click acts on the row under the cursor, like the Finder,
        /// rather than on whatever happened to be selected before.
        @objc func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let row = item(at: table.clickedRow) else {
                return
            }
            if row.isFolder {
                menu.addItem(withTitle: "Open", action: #selector(openRow),
                             keyEquivalent: "").target = self
            } else {
                menu.addItem(withTitle: "Download",
                             action: #selector(downloadRow),
                             keyEquivalent: "").target = self
                menu.addItem(withTitle: "Download as MacBinary",
                             action: #selector(downloadRowAsMacBinary),
                             keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename", action: #selector(renameRow),
                         keyEquivalent: "").target = self
            let selected = selectedRows
            let trashTitle = selected.count > 1
                && selected.contains(where: { $0.id == row.id })
                ? "Move \(selected.count) Items to Trash"
                : "Move to Trash"
            menu.addItem(withTitle: trashTitle, action: #selector(trashRows),
                         keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "New Folder",
                         action: #selector(newFolder),
                         keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Path", action: #selector(copyPath),
                         keyEquivalent: "").target = self
        }

        @objc private func renameRow() {
            if let row = clickedRow { parent.model.renaming = row.id }
        }

        /// Right-click acts on the clicked row, unless it is part of the
        /// current selection — then it acts on all of it, like the Finder.
        @objc private func trashRows() {
            guard let row = clickedRow else { return }
            let selected = selectedRows
            parent.model.requestTrash(
                selected.contains(where: { $0.id == row.id })
                    ? selected : [row])
        }

        @objc private func newFolder() {
            parent.model.newFolderName = "untitled folder"
        }

        @objc private func commitRename(_ sender: NSTextField) {
            let id = sender.identifier?.rawValue
            parent.model.renaming = nil
            guard let id, let row = rows.first(where: { $0.id == id }) else {
                return
            }
            parent.model.requestRename(row, to: sender.stringValue)
        }

        private var clickedRow: FileRow? {
            guard let table else { return nil }
            return item(at: table.clickedRow)
        }

        @objc private func openRow() {
            if let row = clickedRow { parent.onOpen(row) }
        }

        @objc private func downloadRow() {
            if let row = clickedRow { parent.model.download(row) }
        }

        @objc private func downloadRowAsMacBinary() {
            if let row = clickedRow {
                parent.model.download(row, container: "macbinary")
            }
        }

        @objc private func copyPath() {
            guard let row = clickedRow else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.path, forType: .string)
        }

        @objc func doubleClicked(_ sender: Any) {
            guard let table, let item = item(at: table.clickedRow) else {
                return
            }
            parent.onOpen(item)
        }

        // MARK: - Dragging out (file promises)

        /// Marks a drag as one of ours. A folder has nothing to promise
        /// the Finder but can still be moved inside the share, so it
        /// travels under this alone.
        static let localRow =
            NSPasteboard.PasteboardType("dev.newoldworld.now.row")

        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let item = item(at: row) else { return nil }
            if item.isFolder {
                // Draggable within the share; dragging one OUT would
                // need a recursive pull, which the Finder will not get.
                let entry = NSPasteboardItem()
                entry.setString(item.id, forType: Coordinator.localRow)
                return entry
            }
            let type = UTType(filenameExtension:
                (item.name as NSString).pathExtension) ?? .data
            let provider = NSFilePromiseProvider(fileType: type.identifier,
                                                 delegate: self)
            promised[ObjectIdentifier(provider)] = item
            return provider
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            promised[ObjectIdentifier(provider)]?.name ?? "Untitled"
        }

        func operationQueue(for provider: NSFilePromiseProvider)
            -> OperationQueue { queue }

        /// Called when the drop lands: this is when the file actually
        /// crosses the wire, which is the whole point of a promise —
        /// nothing is transferred for a drag that goes nowhere.
        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            let key = ObjectIdentifier(provider)
            Task { @MainActor in
                guard let row = self.promised[key] else {
                    completionHandler(FilesModuleModel.FilesError
                        .wire("that file is no longer listed"))
                    return
                }
                self.promised[key] = nil
                self.parent.model.fetchForPromise(row, to: url) { result in
                    switch result {
                    case .success:
                        completionHandler(nil)
                    case .failure(let error):
                        completionHandler(error)
                    }
                }
            }
        }

        // MARK: - Dropping in

        func tableView(_ tableView: NSTableView,
                       validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation)
            -> NSDragOperation {
            if info.draggingSource != nil {
                // A drag that started here is a move within the share,
                // and it only means something over a folder — dropping
                // between rows would be a reorder, which HFS has no
                // notion of.
                guard operation == .on, let target = item(at: row),
                      target.isFolder,
                      !dragging.contains(where: { $0.id == target.id })
                else { return [] }
                return .move
            }
            // Dropping ON a folder means into it; anywhere else means
            // the folder being browsed.
            if operation == .on, item(at: row)?.isFolder == true {
                return .copy
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        /// The rows a local drag is carrying. The pasteboard holds file
        /// promises for the outside world, which say nothing about where
        /// these rows came from, so the source side remembers.
        private var dragging: [FileRow] = []

        func tableView(_ tableView: NSTableView,
                       draggingSession session: NSDraggingSession,
                       willBeginAt point: NSPoint,
                       forRowIndexes rowIndexes: IndexSet) {
            dragging = rowIndexes.compactMap { item(at: $0) }
        }

        func tableView(_ tableView: NSTableView,
                       draggingSession session: NSDraggingSession,
                       endedAt point: NSPoint,
                       operation: NSDragOperation) {
            dragging = []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            if info.draggingSource != nil {
                guard dropOperation == .on, let target = item(at: row),
                      target.isFolder, !dragging.isEmpty else { return false }
                parent.model.requestMove(dragging, toFolder: target.path)
                return true
            }
            let urls = (info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            let target = dropOperation == .on ? item(at: row) : nil
            parent.model.enqueue(urls,
                                 into: target?.isFolder == true
                                     ? target?.path : nil)
            return true
        }
    }
}
