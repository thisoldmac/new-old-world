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
        table.registerForDraggedTypes([.fileURL])
        table.sortDescriptors = [
            NSSortDescriptor(key: "name", ascending: true),
        ]
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

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
        context.coordinator.rows = rows
        (scroll.documentView as? NSTableView)?.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource,
                             NSTableViewDelegate, NSFilePromiseProviderDelegate {
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

        @objc func doubleClicked(_ sender: Any) {
            guard let table, let item = item(at: table.clickedRow) else {
                return
            }
            parent.onOpen(item)
        }

        // MARK: - Dragging out (file promises)

        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            // Folders would need a recursive pull; files only for now.
            guard let item = item(at: row), !item.isFolder else {
                return nil
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
                self.parent.model.fetchForPromise(row) { result in
                    switch result {
                    case .success(let converted):
                        do {
                            try converted.data.write(to: url)
                            completionHandler(nil)
                        } catch {
                            completionHandler(error)
                        }
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
            guard info.draggingSource == nil else { return [] }
            // Dropping ON a folder means into it; anywhere else means
            // the folder being browsed.
            if operation == .on, item(at: row)?.isFolder == true {
                return .copy
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
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
