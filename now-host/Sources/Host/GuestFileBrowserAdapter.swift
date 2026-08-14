import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GuestFilePromiseDescriptor: Equatable {
    var type: UTType
    var requiresMacBinary: Bool

    static func describe(_ item: FileRow) -> Self {
        if item.isFolder {
            return Self(type: .folder, requiresMacBinary: false)
        }
        let extensionType = UTType(filenameExtension:
            (item.name as NSString).pathExtension)
        let classicType: UTType?
        switch item.entry.fileType {
        case "APPL": classicType = .application
        case "TEXT", "ttro", "utxt": classicType = .plainText
        case "PICT": classicType = .image
        case "GIFf": classicType = .gif
        case "JPEG": classicType = .jpeg
        case "MooV": classicType = .movie
        case "ZIP ": classicType = .zip
        default: classicType = nil
        }
        /* Promise the destination file's type, not the MacBinary envelope
           used while a classic file crosses the wire. */
        let type = extensionType ?? classicType ?? .data
        let hasResourceFork = (item.entry.rsrcBytes ?? 0) > 0
        let hasFinderIdentity = [item.entry.fileType, item.entry.creator]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && $0 != "????" }
        return Self(type: type,
                    requiresMacBinary: hasResourceFork
                        || hasFinderIdentity)
    }
}

@MainActor
final class GuestFileBrowserAdapter: FilesBrowserAdapter {
    private let model: FilesModuleModel
    private let guestRows: [FileRow]
    private let onOpen: (FileRow) -> Void
    private let sort: Binding<[KeyPathComparator<FileRow>]>

    init(model: FilesModuleModel, rows: [FileRow],
         onOpen: @escaping (FileRow) -> Void,
         sort: Binding<[KeyPathComparator<FileRow>]>) {
        self.model = model
        guestRows = rows
        self.onOpen = onOpen
        self.sort = sort
    }

    var rows: [FilesBrowserRow] { guestRows.map(FilesBrowserRow.guest) }
    var rootDirectoryKey: String { model.path }
    var currentDirectoryKey: String { model.path }
    var contentRevision: Int { model.columnListingsRevision }
    var columnsAutosaveName: String { "FilesGuestColumns" }
    var localDragOperation: NSDragOperation { .move }
    var selectedRowIDs: Set<FilesBrowserRow.ID> {
        model.selection.map { [$0] } ?? []
    }
    var registeredDraggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
    }

    func icon(for row: FilesBrowserRow) -> NSImage {
        NSImage(systemSymbolName: row.symbolName,
                accessibilityDescription: nil) ?? NSImage()
    }

    func contains(_ candidate: String, within root: String) -> Bool {
        let candidate = candidate.lowercased()
        let root = root.lowercased()
        return root.isEmpty || candidate == root
            || candidate.hasPrefix(root + ":")
    }

    func children(of directoryKey: String) -> [FilesBrowserRow] {
        if directoryKey == model.path {
            return guestRows.map(FilesBrowserRow.guest)
        }
        return (model.columnListings[directoryKey] ?? [])
            .map(FilesBrowserRow.guest)
    }

    func requestChildren(of row: FilesBrowserRow) {
        guard let guest = row.guestRow else { return }
        model.loadTreeChildren(of: guest)
    }

    func isRenaming(_ row: FilesBrowserRow) -> Bool {
        model.renaming == row.id
    }

    func setSort(key: String, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "kind":
            sort.wrappedValue = [KeyPathComparator(\FileRow.kind,
                                                   order: order)]
        case "size":
            sort.wrappedValue = [KeyPathComparator(\FileRow.sizeBytes,
                                                   order: order)]
        case "modified":
            sort.wrappedValue = [KeyPathComparator(\FileRow.sortableDate,
                                                   order: order)]
        default:
            sort.wrappedValue = [KeyPathComparator(\FileRow.name,
                                                   order: order)]
        }
    }

    func setSelection(_ rows: [FilesBrowserRow]) {
        model.selection = rows.first?.id
    }

    func menuItems(for row: FilesBrowserRow,
                   selection: [FilesBrowserRow]) -> [FilesBrowserMenuItem] {
        var items: [FilesBrowserMenuItem] = []
        if row.isFolder {
            items.append(.init("Open", .open))
        } else {
            items.append(.init("Open on This Mac", .open))
            items.append(.init("Download", .download,
                               key: "d", modifiers: .command))
            items.append(.init("Download as MacBinary", .downloadMacBinary))
        }
        items.append(.separator)
        items.append(.init("Rename", .rename))
        let trashTitle = selection.count > 1
            && selection.contains(where: { $0.id == row.id })
            ? "Move \(selection.count) Items to Trash"
            : "Move to Trash"
        items.append(.init(trashTitle, .trash))
        items.append(.separator)
        items.append(.init("New Folder", .newFolder,
                           key: "n", modifiers: [.command, .shift]))
        if row.isFolder {
            items.append(.init("Add to Sidebar", .pin))
        }
        items.append(.init("Copy Path", .copyPath))
        return items
    }

    func perform(_ action: FilesBrowserAction, clicked: FilesBrowserRow?,
                 selection: [FilesBrowserRow]) {
        let selected = selection.compactMap(\.guestRow)
        let clicked = clicked?.guestRow
        switch action {
        case .open:
            if let row = clicked ?? selected.first { onOpen(row) }
        case .download:
            let candidates = clicked.map { [$0] } ?? selected
            if let row = candidates.first(where: { !$0.isFolder }) {
                model.download(row)
            }
        case .downloadMacBinary:
            if let row = clicked, !row.isFolder {
                model.download(row, container: "macbinary")
            }
        case .rename:
            model.renaming = clicked?.id
        case .trash:
            guard let clicked else {
                if !selected.isEmpty { model.requestTrash(selected) }
                return
            }
            model.requestTrash(selected.contains(where: { $0.id == clicked.id })
                ? selected : [clicked])
        case .newFolder:
            model.beginNewFolder()
        case .pin:
            if let clicked, clicked.isFolder {
                model.pinLocation(path: clicked.path)
            }
        case .copyPath:
            guard let row = clicked ?? selected.first else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.path, forType: .string)
        case .showInFinder:
            break
        }
    }

    func commitRename(_ row: FilesBrowserRow, to name: String) {
        model.renaming = nil
        guard let guest = row.guestRow else { return }
        model.requestRename(guest, to: name)
    }

    func pasteboardWriter(for row: FilesBrowserRow,
                          promiseDelegate: NSFilePromiseProviderDelegate?)
        -> NSPasteboardWriting? {
        guard let guest = row.guestRow, let promiseDelegate else { return nil }
        let descriptor = GuestFilePromiseDescriptor.describe(guest)
        let provider = NSFilePromiseProvider(
            fileType: descriptor.type.identifier,
            delegate: promiseDelegate)
        provider.userInfo = guest
        return provider
    }

    func promisedFileName(_ provider: NSFilePromiseProvider) -> String {
        (provider.userInfo as? FileRow)?.name ?? "Untitled"
    }

    func writePromise(_ browserRow: FilesBrowserRow, to url: URL,
                      completion: @escaping (Error?) -> Void) {
        guard let row = browserRow.guestRow else {
            completion(FilesModuleModel.FilesError
                .wire("that file is no longer listed"))
            return
        }
        model.fetchForPromise(row, to: url) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    func validateDrop(_ info: NSDraggingInfo, tableView: NSTableView,
                      proposedRow: FilesBrowserRow?,
                      operation: NSTableView.DropOperation,
                      dragging: [FilesBrowserRow]) -> NSDragOperation {
        if info.draggingSource as? NSTableView === tableView {
            guard operation == .on, proposedRow?.isFolder == true,
                  !dragging.contains(where: { $0.id == proposedRow?.id })
            else { return [] }
            return .move
        }
        if operation == .on, proposedRow?.isFolder == true { return .copy }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func draggingWillBegin(_ rows: [FilesBrowserRow]) {
        let guest = rows.compactMap(\.guestRow)
        model.draggedRows = guest
        model.draggedFolderPath = guest.count == 1 && guest[0].isFolder
            ? guest[0].path : nil
    }

    func draggingDidEnd() {
        model.draggedRows = []
        model.draggedFolderPath = nil
    }

    func acceptDrop(_ info: NSDraggingInfo, tableView: NSTableView,
                    proposedRow: FilesBrowserRow?,
                    operation: NSTableView.DropOperation,
                    dragging: [FilesBrowserRow]) -> Bool {
        if info.draggingSource as? NSTableView === tableView {
            guard operation == .on,
                  let target = proposedRow?.guestRow, target.isFolder else {
                return false
            }
            let rows = dragging.compactMap(\.guestRow)
            guard !rows.isEmpty else { return false }
            model.requestMove(rows, toFolder: target.path)
            return true
        }
        let urls = (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        let target = operation == .on ? proposedRow?.guestRow : nil
        model.enqueue(urls, into: target?.isFolder == true ? target?.path : nil)
        return true
    }
}
