import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GuestFilePromiseDescriptor: Equatable {
    var type: UTType
    var requiresMacBinary: Bool

    /// The tag class classic four-character Finder types live under. Not a
    /// named member of `UTTagClass`, which declares only the filename
    /// extension and MIME cases; the identifier is CoreServices'
    /// `kUTTagClassOSType` and is what the system's own classic-type
    /// lookups still use.
    static var osTypeTagClass: UTTagClass {
        UTTagClass(rawValue: "com.apple.ostype")
    }

    /// Deliberate answers that beat whatever the OSType tag lookup
    /// synthesizes, kept because a person chose them: `TEXT` reads better
    /// as `public.plain-text` than as the traditional-Mac text type, and
    /// `APPL` as an application rather than an application *bundle*. These
    /// are OVERRIDES on top of the derivation below, not a replacement for
    /// it — every other classic type now gets a real answer instead of
    /// falling to generic `public.data`.
    static func curatedType(for osType: String?) -> UTType? {
        switch osType {
        case "APPL": return .application
        case "TEXT", "ttro", "utxt": return .plainText
        case "PICT": return .image
        case "GIFf": return .gif
        case "JPEG": return .jpeg
        case "MooV": return .movie
        case "ZIP ": return .zip
        default: return nil
        }
    }

    /// The type derived from the guest's own four-character Finder type.
    ///
    /// `conformingTo: .data` matters: for an OSType the system does not
    /// know it synthesizes a dynamic type, and a dynamic type that
    /// conforms to nothing is worse than `public.data` — every receiver
    /// refuses it. Anchored to `public.data`, the dynamic type carries
    /// more information than `public.data` while still being accepted
    /// everywhere `public.data` is.
    static func derivedType(for osType: String?) -> UTType? {
        guard let osType, osType.count == 4, osType != "????" else {
            return nil
        }
        return UTType(tag: osType, tagClass: osTypeTagClass,
                      conformingTo: .data)
    }

    /// The type a modern extension in the guest's own name identifies.
    ///
    /// Only a DECLARED type counts. Classic names are full of dots that
    /// are not extensions — "System 7.5.3", "Photoshop 3.0" — and
    /// `UTType(filenameExtension:)` answers those with a dynamic type
    /// conforming to nothing rather than with nil. That answer used to win
    /// outright, so a great many classic files were advertised under a UTI
    /// no application has ever heard of, which is exactly the shape of
    /// "the Desktop takes it and nothing else will".
    static func extensionType(for name: String) -> UTType? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              !type.isDynamic else { return nil }
        return type
    }

    static func describe(_ item: FileRow) -> Self {
        if item.isFolder {
            return Self(type: .folder, requiresMacBinary: false)
        }
        /* Promise the destination file's type, not the MacBinary envelope
           used while a classic file crosses the wire. */
        let type = extensionType(for: item.name)
            ?? curatedType(for: item.entry.fileType)
            ?? derivedType(for: item.entry.fileType)
            ?? .data
        let hasResourceFork = (item.entry.rsrcBytes ?? 0) > 0
        let hasFinderIdentity = [item.entry.fileType, item.entry.creator]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && $0 != "????" }
        return Self(type: type,
                    requiresMacBinary: hasResourceFork
                        || hasFinderIdentity)
    }

    /// The name AppKit should materialize, carrying an extension that
    /// agrees with the type the pasteboard already declared.
    ///
    /// `filePromiseProvider(_:fileNameForType:)` is handed the declared UTI
    /// precisely so the delegate can do this; the old implementation
    /// returned the bare guest name, so a classic extension-less file
    /// landed as a file whose name contradicted its own advertised type.
    /// The type is read back from what was declared rather than recomputed,
    /// so the two cannot drift.
    ///
    /// A type with no preferred extension (`public.data`, `public.folder`,
    /// an application, a synthesized dynamic type) leaves the name alone —
    /// inventing one would be a guess, and a wrong extension is worse than
    /// none. The name is put through the same HFS projection as promised
    /// folder children, because a guest name may legally contain the one
    /// character a POSIX path may not.
    static func promisedName(_ name: String, declared identifier: String)
        -> String {
        let name = LocalFileName.sanitized(name)
        guard let ext = UTType(identifier)?.preferredFilenameExtension,
              !ext.isEmpty else { return name }
        guard (name as NSString).pathExtension.caseInsensitiveCompare(ext)
                != .orderedSame else { return name }
        return name + "." + ext
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
        guard let row = provider.userInfo as? FileRow else { return "Untitled" }
        return GuestFilePromiseDescriptor.promisedName(
            row.name, declared: provider.fileType)
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
        /* Claim only what `acceptDrop` below can actually redeem. This used
           to return `.copy` for anything at all, so a promise-only source
           — a photo dragged straight out of Photos, a Mail attachment with
           no file on disk yet — showed the green plus for the whole drag
           and then did nothing on release, with no error anywhere. */
        guard Self.canReadExternalDrop(info.draggingPasteboard) else {
            return []
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
        let target = operation == .on ? proposedRow?.guestRow : nil
        let folder = target?.isFolder == true ? target?.path : nil
        switch Self.externalDrop(on: info.draggingPasteboard) {
        case .urls(let urls):
            model.enqueue(urls, into: folder)
            return true
        case .promises(let receivers):
            receive(receivers, into: folder)
            return true
        case .unreadable:
            return false
        }
    }

    /// What an external drag is actually carrying.
    ///
    /// The table registers for file URLs **and** for every type
    /// `NSFilePromiseReceiver` can read, so both must be redeemable here;
    /// registering for a type nothing redeems is how a drag can look
    /// accepted for its whole length and land nowhere.
    enum ExternalDrop {
        case urls([URL])
        case promises([NSFilePromiseReceiver])
        case unreadable
    }

    static func externalDrop(on pasteboard: NSPasteboard) -> ExternalDrop {
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return .urls(urls) }
        let receivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil) as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty { return .promises(receivers) }
        return .unreadable
    }

    /// The same question `externalDrop` answers, asked without materialising
    /// anything — `validateDrop` runs on every mouse move of a drag.
    /// `GuestFileBrowserAdapterDropTests` pins the two to the same verdict,
    /// because a cheap predicate that drifts from the expensive one is the
    /// bug this pair exists to prevent.
    static func canReadExternalDrop(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(
                forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    /// Stages a promise-only source into a private directory and hands each
    /// file to the ordinary upload queue as it lands, rather than waiting
    /// for the whole set: `enqueue` appends, so a slow promise does not hold
    /// up the ones already written.
    private func receive(_ receivers: [NSFilePromiseReceiver],
                         into folder: String?) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-drop-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
        } catch {
            model.reportChangeFailure(error.localizedDescription)
            return
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let sink = GuestPromiseDropSink(model: model, folder: folder)
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: staging, options: [:],
                operationQueue: queue) { url, error in
                sink.received(url, failure: error?.localizedDescription)
            }
        }
    }
}

/// AppKit calls a promise reader on the queue the destination supplied, with
/// arguments it never marked `Sendable`. Same shape as
/// `FilesPromiseCompletion`: take ownership once, and touch the model only
/// from the main actor. The error is reduced to its message at the boundary
/// so nothing non-`Sendable` crosses.
private final class GuestPromiseDropSink: @unchecked Sendable {
    private let model: FilesModuleModel
    private let folder: String?

    init(model: FilesModuleModel, folder: String?) {
        self.model = model
        self.folder = folder
    }

    func received(_ url: URL, failure: String?) {
        let model = model
        let folder = folder
        Task { @MainActor in
            if let failure {
                model.reportChangeFailure(failure)
                return
            }
            model.enqueue([url], into: folder)
        }
    }
}
