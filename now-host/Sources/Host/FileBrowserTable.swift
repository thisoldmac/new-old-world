import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum GuestFilePromiseType {
    static func type(for item: FileRow) -> UTType {
        if item.isFolder { return .folder }
        return UTType(filenameExtension:
            (item.name as NSString).pathExtension) ?? .data
    }
}

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
        let table = BrowserTableView()
        table.coordinator = context.coordinator
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
           why dragging a row onto a folder did nothing. */
        table.registerForDraggedTypes(
            [.fileURL]
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
        /* The download glyph's own column, last and narrow. A column
           rather than an accessory floating over the name cell: the row
           is a drag source, and a view laid over one is a view the drag
           starts underneath. Unsorted and untitled — it is a control, and
           a header that sorted by it would sort by nothing. */
        let action = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier(Coordinator.actionColumn))
        action.title = ""
        action.width = 24
        action.minWidth = 24
        action.maxWidth = 24
        table.addTableColumn(action)

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
            case Coordinator.actionColumn:
                /* One click, one file, on this Mac. A folder has nothing
                   to download, and an empty cell says that better than a
                   disabled button nobody can explain. */
                guard !item.isFolder else { return nil }
                let button = NSButton()
                button.bezelStyle = .inline
                button.isBordered = false
                button.image = NSImage(
                    systemSymbolName: "arrow.down.circle",
                    accessibilityDescription: "Download")
                button.contentTintColor = .secondaryLabelColor
                button.imagePosition = .imageOnly
                button.target = self
                button.action = #selector(downloadClickedRow(_:))
                /* Identified by the file, not by the row number: a
                   listing reorders under a sort click, and a button that
                   remembered an index would then download its neighbour. */
                button.identifier = NSUserInterfaceItemIdentifier(item.id)
                button.toolTip = "Download \(item.name) to "
                    + parent.model.downloadDirectory.lastPathComponent
                button.setAccessibilityLabel("Download \(item.name)")
                return button
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
                /* Named after where it lands, because the two commands
                   below it land somewhere else: this one goes to the
                   folder this Mac shares, the downloads go to the
                   downloads folder. Same wording as the double-click,
                   which is this item. */
                menu.addItem(withTitle: "Open on This Mac",
                             action: #selector(openRow),
                             keyEquivalent: "").target = self
                // ⌘D is advertised here and implemented in the table's
                // keyDown, so the shortcut a person reads in the menu is
                // the shortcut that works with the menu closed.
                let download = menu.addItem(withTitle: "Download",
                                            action: #selector(downloadRow),
                                            keyEquivalent: "d")
                download.target = self
                download.keyEquivalentModifierMask = .command
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
            if row.isFolder {
                // The keyboard's half of drag-to-add. A sidebar that can
                // only be filled by dragging is a sidebar some people
                // cannot fill.
                menu.addItem(withTitle: "Add to Sidebar",
                             action: #selector(pinRow),
                             keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Copy Path", action: #selector(copyPath),
                         keyEquivalent: "").target = self
        }

        /// The download glyph in the row, and the ⌘D that reaches the same
        /// place without a mouse.
        @objc fileprivate func downloadClickedRow(_ sender: NSButton) {
            guard let id = sender.identifier?.rawValue,
                  let row = rows.first(where: { $0.id == id }) else { return }
            parent.model.download(row)
        }

        /// Downloads the selection. Folders in it are skipped rather than
        /// refusing the whole thing — a mixed selection is ordinary.
        func downloadSelection() {
            for row in selectedRows where !row.isFolder {
                parent.model.download(row)
                // One transfer lane: the second would only be refused, and
                // the refusal is the model's to report.
                break
            }
        }

        func openSelection() {
            if let row = selectedRows.first { parent.onOpen(row) }
        }

        @objc private func pinRow() {
            if let row = clickedRow, row.isFolder {
                parent.model.pinLocation(path: row.path)
            }
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
            parent.model.beginNewFolder()
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

        /// The narrow column the download glyph lives in.
        static let actionColumn = "download"

        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let item = item(at: row) else { return nil }
            let type = GuestFilePromiseType.type(for: item)
            let provider = NSFilePromiseProvider(fileType: type.identifier,
                                                 delegate: self)
            // The provider owns this drag's row for exactly as long as
            // AppKit owns the promise. A coordinator dictionary leaked one
            // entry for every drag that ended without a Finder drop.
            provider.userInfo = item
            return provider
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            (provider.userInfo as? FileRow)?.name ?? "Untitled"
        }

        func operationQueue(for provider: NSFilePromiseProvider)
            -> OperationQueue { queue }

        /// Called when the drop lands: this is when the file actually
        /// crosses the wire, which is the whole point of a promise —
        /// nothing is transferred for a drag that goes nowhere.
        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            Task { @MainActor in
                guard let row = provider.userInfo as? FileRow else {
                    completionHandler(FilesModuleModel.FilesError
                        .wire("that file is no longer listed"))
                    return
                }
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
            parent.model.draggedFolderPath = dragging.count == 1
                && dragging[0].isFolder ? dragging[0].path : nil
        }

        func tableView(_ tableView: NSTableView,
                       draggingSession session: NSDraggingSession,
                       endedAt point: NSPoint,
                       operation: NSDragOperation) {
            dragging = []
            parent.model.draggedFolderPath = nil
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

    /// The table, with the keyboard's half of what the row's controls do.
    ///
    /// The download glyph is a button in a cell, so Full Keyboard Access
    /// already reaches it — but only by tabbing through every row before
    /// it, which is not reaching. ⌘D acts on the selection the way the
    /// context menu's Download does, and Return opens it the way a
    /// double-click does. Both are the *same* model calls; the point is a
    /// second door, not a second behaviour.
    @MainActor
    final class BrowserTableView: NSTableView {
        weak var coordinator: Coordinator?

        override func keyDown(with event: NSEvent) {
            let command = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask) == .command
            if command, event.charactersIgnoringModifiers?.lowercased() == "d" {
                coordinator?.downloadSelection()
                return
            }
            // Return/Enter, the Finder's own "open this".
            if !command, let key = event.charactersIgnoringModifiers?.unicodeScalars.first,
               key == "\r" || key == "\u{3}" {
                coordinator?.openSelection()
                return
            }
            super.keyDown(with: event)
        }
    }
}
