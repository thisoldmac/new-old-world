import AppKit
import SwiftUI

/// A testable description of the browser shortcuts. AppKit includes state
/// flags such as Caps Lock in every key event, so only the modifiers that
/// participate in shortcuts are compared.
enum FileBrowserKeyAction: Equatable {
    case download
    case newFolder
    case open
    case trash

    static func resolve(modifiers: NSEvent.ModifierFlags, keyCode: UInt16,
                        characters: String?) -> FileBrowserKeyAction? {
        let shortcutFlags: NSEvent.ModifierFlags =
            [.command, .shift, .option, .control]
        let chord = modifiers.intersection(shortcutFlags)
        let character = characters?.lowercased()

        if chord == .command {
            if character == "d" { return .download }
            if keyCode == 51 || keyCode == 117 { return .trash }
        }
        if chord == [.command, .shift], character == "n" {
            return .newFolder
        }
        if chord.isEmpty, let key = character?.unicodeScalars.first,
           key == "\r" || key == "\u{3}" {
            return .open
        }
        return nil
    }
}

/// Common row metadata retained by the native table. The target adapters own
/// the concrete row's actions and transport semantics.
enum FilesBrowserRow: Identifiable, Equatable, Sendable {
    case guest(FileRow)
    case host(HostFileRow)

    var id: String {
        switch self {
        case .guest(let row): row.id
        case .host(let row): row.id
        }
    }

    var name: String {
        switch self {
        case .guest(let row): row.name
        case .host(let row): row.name
        }
    }

    var isFolder: Bool {
        switch self {
        case .guest(let row): row.isFolder
        case .host(let row): row.isFolder
        }
    }

    var kind: String {
        switch self {
        case .guest(let row): row.kind
        case .host(let row): row.kind
        }
    }

    var sizeBytes: Int {
        switch self {
        case .guest(let row): row.sizeBytes
        case .host(let row): row.sizeBytes
        }
    }

    var modified: Date? {
        switch self {
        case .guest(let row): row.modified
        case .host(let row): row.modified
        }
    }

    var symbolName: String {
        switch self {
        case .guest(let row): row.symbolName
        case .host(let row): row.isFolder ? "folder" : "doc"
        }
    }

    var conversionNote: String? {
        guard case .guest(let row) = self else { return nil }
        return row.conversionNote
    }

    var path: String {
        switch self {
        case .guest(let row): row.path
        case .host(let row): row.url.path
        }
    }

    var guestRow: FileRow? {
        guard case .guest(let row) = self else { return nil }
        return row
    }

    var hostRow: HostFileRow? {
        guard case .host(let row) = self else { return nil }
        return row
    }
}

enum FilesBrowserAction: String {
    case open
    case download
    case downloadMacBinary
    case rename
    case trash
    case newFolder
    case pin
    case copyPath
    case showInFinder
}

/// Finder's default list columns, shared by the host and guest adapters.
/// The identifier is deliberately stable because AppKit persists column order,
/// width, and visibility against it.
enum FilesListColumn: String, CaseIterable {
    case name
    case modified
    case size
    case kind

    var title: LocalizedStringResource {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: 255
        case .modified: 155
        case .size: 80
        case .kind: 125
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: 130
        case .modified: 110
        case .size: 64
        case .kind: 84
        }
    }

    var canHide: Bool { self != .name }
}

struct FilesBrowserMenuItem {
    let title: String
    let action: FilesBrowserAction?
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ title: String, _ action: FilesBrowserAction,
         key: String = "", modifiers: NSEvent.ModifierFlags = []) {
        self.title = title
        self.action = action
        self.key = key
        self.modifiers = modifiers
    }

    private init() {
        title = ""
        action = nil
        key = ""
        modifiers = []
    }

    static let separator = Self()
}

@MainActor
protocol FilesBrowserTableAdapter: AnyObject {
    var rows: [FilesBrowserRow] { get }
    var listAutosaveName: String { get }
    var localDragOperation: NSDragOperation { get }
    var registeredDraggedTypes: [NSPasteboard.PasteboardType] { get }
    var selectedRowIDs: Set<FilesBrowserRow.ID> { get }

    func icon(for row: FilesBrowserRow) -> NSImage
    func isRenaming(_ row: FilesBrowserRow) -> Bool
    func setSort(key: String, ascending: Bool)
    func setSelection(_ rows: [FilesBrowserRow])
    func menuItems(for row: FilesBrowserRow,
                   selection: [FilesBrowserRow]) -> [FilesBrowserMenuItem]
    func perform(_ action: FilesBrowserAction, clicked: FilesBrowserRow?,
                 selection: [FilesBrowserRow])
    func commitRename(_ row: FilesBrowserRow, to name: String)

    func pasteboardWriter(for row: FilesBrowserRow,
                          promiseDelegate: NSFilePromiseProviderDelegate?)
        -> NSPasteboardWriting?
    func promisedFileName(_ provider: NSFilePromiseProvider) -> String
    func writePromise(_ row: FilesBrowserRow, to url: URL,
                      completion: @escaping (Error?) -> Void)

    func validateDrop(_ info: NSDraggingInfo, tableView: NSTableView,
                      proposedRow: FilesBrowserRow?,
                      operation: NSTableView.DropOperation,
                      dragging: [FilesBrowserRow]) -> NSDragOperation
    func draggingWillBegin(_ rows: [FilesBrowserRow])
    func draggingDidEnd()
    func acceptDrop(_ info: NSDraggingInfo, tableView: NSTableView,
                    proposedRow: FilesBrowserRow?,
                    operation: NSTableView.DropOperation,
                    dragging: [FilesBrowserRow]) -> Bool
}

/// The filesystem boundary consumed by the single native browser primitive.
/// AppKit owns presentation and interaction; adapters translate those actions
/// to a local URL tree or the guest's asynchronous HFS namespace.
@MainActor
protocol FilesBrowserAdapter: FilesBrowserTableAdapter {
    var rootDirectoryKey: String { get }
    var currentDirectoryKey: String { get }
    var contentRevision: Int { get }
    var columnsAutosaveName: String { get }

    func contains(_ candidate: String, within root: String) -> Bool
    func children(of directoryKey: String) -> [FilesBrowserRow]
    func requestChildren(of row: FilesBrowserRow)
}

extension FilesBrowserAdapter {
    var listAutosaveName: String { "\(columnsAutosaveName).List.v2" }

    func open(_ row: FilesBrowserRow) {
        perform(.open, clicked: row, selection: [row])
    }
}

extension FilesBrowserTableAdapter {
    var listAutosaveName: String { "FilesBrowserList" }
    var registeredDraggedTypes: [NSPasteboard.PasteboardType] { [.fileURL] }
    var selectedRowIDs: Set<FilesBrowserRow.ID> { [] }
    func isRenaming(_ row: FilesBrowserRow) -> Bool { false }
    func setSelection(_ rows: [FilesBrowserRow]) {}
    func commitRename(_ row: FilesBrowserRow, to name: String) {}
    func promisedFileName(_ provider: NSFilePromiseProvider) -> String {
        "Untitled"
    }
    func writePromise(_ row: FilesBrowserRow, to url: URL,
                      completion: @escaping (Error?) -> Void) {
        completion(CocoaError(.fileWriteUnknown))
    }
    func validateDrop(_ info: NSDraggingInfo, tableView: NSTableView,
                      proposedRow: FilesBrowserRow?,
                      operation: NSTableView.DropOperation,
                      dragging: [FilesBrowserRow]) -> NSDragOperation { [] }
    func draggingWillBegin(_ rows: [FilesBrowserRow]) {}
    func draggingDidEnd() {}
    func acceptDrop(_ info: NSDraggingInfo, tableView: NSTableView,
                    proposedRow: FilesBrowserRow?,
                    operation: NSTableView.DropOperation,
                    dragging: [FilesBrowserRow]) -> Bool { false }
}

/// The single first-party AppKit browser root used for guest and host files.
/// Target adapters own guest mutations/promises and host URL operations; this
/// type owns only NSTableView presentation and event routing.
struct FileBrowserTable: NSViewRepresentable {
    private let adapter: any FilesBrowserTableAdapter
    private var rows: [FilesBrowserRow] { adapter.rows }

    init(adapter: any FilesBrowserTableAdapter) {
        self.adapter = adapter
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BrowserTableView()
        table.coordinator = context.coordinator
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.rowSizeStyle = .default
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes(adapter.registeredDraggedTypes)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.sortDescriptors = [
            NSSortDescriptor(key: "name", ascending: true),
        ]
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(adapter.localDragOperation,
                                             forLocal: true)

        for specification in FilesListColumn.allCases {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(
                    specification.rawValue))
            column.title = String(localized: specification.title)
            column.width = specification.defaultWidth
            column.minWidth = specification.minimumWidth
            column.sortDescriptorPrototype =
                NSSortDescriptor(key: specification.rawValue, ascending: true)
            table.addTableColumn(column)
        }
        table.autosaveName = NSTableView.AutosaveName(
            adapter.listAutosaveName)
        table.autosaveTableColumns = true
        let columnsMenu = NSMenu(title: String(localized: "Columns"))
        columnsMenu.autoenablesItems = false
        columnsMenu.delegate = context.coordinator
        table.headerView?.menu = columnsMenu
        context.coordinator.headerMenu = columnsMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let newRows = adapter.rows
        guard context.coordinator.rows != newRows else { return }
        let table = scroll.documentView as? NSTableView
        let tableSelection = Set(context.coordinator.selectedRows.map(\.id))
        let selectedIDs = tableSelection.isEmpty
            ? adapter.selectedRowIDs : tableSelection
        context.coordinator.rows = newRows
        table?.reloadData()
        let restored = IndexSet(newRows.indices.filter {
            selectedIDs.contains(newRows[$0].id)
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
        var rows: [FilesBrowserRow] = []
        weak var table: NSTableView?
        weak var headerMenu: NSMenu?
        private let queue = OperationQueue()
        private var dragging: [FilesBrowserRow] = []
        private var springLoadingRow: Int?

        init(_ parent: FileBrowserTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        private func item(at index: Int) -> FilesBrowserRow? {
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
                return nameCell(for: item, text: text)
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

        private func nameCell(for item: FilesBrowserRow,
                              text: NSTextField) -> NSView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 5
            let icon = NSImageView(image: parent.adapter.icon(for: item))
            icon.imageScaling = .scaleProportionallyDown
            icon.setFrameSize(NSSize(width: 16, height: 16))
            if item.hostRow == nil {
                icon.contentTintColor = item.isFolder
                    ? .controlAccentColor : .secondaryLabelColor
            }
            text.stringValue = item.name
            if parent.adapter.isRenaming(item) {
                configureRename(text, for: item)
            }
            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(text)
            stack.toolTip = item.path
            if let note = item.conversionNote {
                let badge = NSTextField(labelWithString: note)
                badge.font = .systemFont(ofSize: 9)
                badge.textColor = .secondaryLabelColor
                stack.addArrangedSubview(badge)
            }
            return stack
        }

        private func configureRename(_ text: NSTextField,
                                     for item: FilesBrowserRow) {
            text.isEditable = true
            text.isSelectable = true
            text.isBordered = true
            text.drawsBackground = true
            text.target = self
            text.action = #selector(commitRename(_:))
            text.identifier = NSUserInterfaceItemIdentifier(item.id)
            DispatchQueue.main.async { [weak text] in
                guard let text, let window = text.window else { return }
                window.makeFirstResponder(text)
                guard let editor = text.currentEditor() else { return }
                let name = text.stringValue
                let stem = (name as NSString).deletingPathExtension
                editor.selectedRange = stem.isEmpty || stem == name
                    ? NSRange(location: 0, length: (name as NSString).length)
                    : NSRange(location: 0, length: (stem as NSString).length)
            }
        }

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key else { return }
            parent.adapter.setSort(key: key, ascending: descriptor.ascending)
        }

        var selectedRows: [FilesBrowserRow] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { item(at: $0) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            parent.adapter.setSelection(selectedRows)
        }

        @objc func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                populateColumnsMenu(menu)
                return
            }
            guard let table, let row = item(at: table.clickedRow) else { return }
            for specification in parent.adapter.menuItems(
                for: row, selection: selectedRows) {
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

        private func populateColumnsMenu(_ menu: NSMenu) {
            guard let table else { return }
            for specification in FilesListColumn.allCases {
                guard let column = table.tableColumn(withIdentifier:
                    NSUserInterfaceItemIdentifier(specification.rawValue))
                else { continue }
                let item = menu.addItem(
                    withTitle: String(localized: specification.title),
                    action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = specification.rawValue
                item.state = column.isHidden ? .off : .on
                item.isEnabled = specification.canHide
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let table,
                  let rawValue = sender.representedObject as? String,
                  let specification = FilesListColumn(rawValue: rawValue),
                  specification.canHide,
                  let column = table.tableColumn(withIdentifier:
                    NSUserInterfaceItemIdentifier(rawValue))
            else { return }
            column.isHidden.toggle()
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let action = FilesBrowserAction(rawValue: raw) else { return }
            parent.adapter.perform(action, clicked: clickedRow,
                                   selection: selectedRows)
        }

        @objc private func commitRename(_ sender: NSTextField) {
            guard let id = sender.identifier?.rawValue,
                  let row = rows.first(where: { $0.id == id }) else { return }
            parent.adapter.commitRename(row, to: sender.stringValue)
        }

        private var clickedRow: FilesBrowserRow? {
            guard let table else { return nil }
            return item(at: table.clickedRow)
        }

        func performKeyAction(_ action: FilesBrowserAction) {
            parent.adapter.perform(action, clicked: nil,
                                   selection: selectedRows)
        }

        @objc func doubleClicked(_ sender: Any) {
            guard let table, let item = item(at: table.clickedRow) else { return }
            parent.adapter.perform(.open, clicked: item,
                                   selection: selectedRows)
        }

        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let item = item(at: row) else { return nil }
            return parent.adapter.pasteboardWriter(
                for: item, promiseDelegate: self)
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            parent.adapter.promisedFileName(provider)
        }

        func operationQueue(for provider: NSFilePromiseProvider)
            -> OperationQueue { queue }

        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
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

        func tableView(_ tableView: NSTableView,
                       validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation)
            -> NSDragOperation {
            parent.adapter.validateDrop(
                info, tableView: tableView, proposedRow: item(at: row),
                operation: operation, dragging: dragging)
        }

        func tableView(_ tableView: NSTableView,
                       draggingSession session: NSDraggingSession,
                       willBeginAt point: NSPoint,
                       forRowIndexes rowIndexes: IndexSet) {
            dragging = rowIndexes.compactMap { item(at: $0) }
            parent.adapter.draggingWillBegin(dragging)
        }

        func tableView(_ tableView: NSTableView,
                       draggingSession session: NSDraggingSession,
                       endedAt point: NSPoint,
                       operation: NSDragOperation) {
            dragging = []
            parent.adapter.draggingDidEnd()
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            parent.adapter.acceptDrop(
                info, tableView: tableView, proposedRow: item(at: row),
                operation: dropOperation, dragging: dragging)
        }

        func springLoadingOptions(
            in tableView: NSTableView, for info: NSDraggingInfo
        ) -> NSSpringLoadingOptions {
            let point = tableView.convert(info.draggingLocation, from: nil)
            let row = tableView.row(at: point)
            guard item(at: row)?.isFolder == true else {
                springLoadingRow = nil
                return .disabled
            }
            if springLoadingRow != row {
                springLoadingRow = row
                info.resetSpringLoading()
            }
            return .enabled
        }

        func updateSpringLoadingHighlight(
            in tableView: NSTableView, for info: NSDraggingInfo
        ) {
            let row = info.springLoadingHighlight == .none
                ? -1 : springLoadingRow ?? -1
            tableView.setDropRow(row, dropOperation: .on)
        }

        func activateSpringLoadedRow() {
            guard let row = springLoadingRow,
                  let item = item(at: row), item.isFolder else { return }
            springLoadingRow = nil
            parent.adapter.perform(.open, clicked: item, selection: [item])
        }

        func clearSpringLoading(in tableView: NSTableView) {
            springLoadingRow = nil
            tableView.setDropRow(-1, dropOperation: .on)
        }
    }

    @MainActor
    final class BrowserTableView: NSTableView, NSSpringLoadingDestination {
        weak var coordinator: Coordinator?

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
            if activated { coordinator?.activateSpringLoadedRow() }
        }

        func springLoadingHighlightChanged(_ draggingInfo: NSDraggingInfo) {
            coordinator?.updateSpringLoadingHighlight(
                in: self, for: draggingInfo)
        }

        func springLoadingExited(_ draggingInfo: NSDraggingInfo) {
            coordinator?.clearSpringLoading(in: self)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            coordinator?.clearSpringLoading(in: self)
            super.draggingEnded(sender)
        }

        override func keyDown(with event: NSEvent) {
            let action = FileBrowserKeyAction.resolve(
                modifiers: event.modifierFlags, keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers)
            switch action {
            case .download:
                coordinator?.performKeyAction(.download)
            case .newFolder:
                coordinator?.performKeyAction(.newFolder)
            case .open:
                coordinator?.performKeyAction(.open)
            case .trash:
                coordinator?.performKeyAction(.trash)
            case nil:
                super.keyDown(with: event)
            }
        }
    }
}
