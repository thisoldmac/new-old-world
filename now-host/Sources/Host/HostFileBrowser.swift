import AppKit
import SwiftUI

struct HostFileRow: Identifiable, Equatable, Sendable {
    let url: URL
    let isFolder: Bool
    let sizeBytes: Int
    let modified: Date?
    let kind: String

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
    var sortableDate: Date { modified ?? Date(timeIntervalSince1970: 0) }
}

struct HostFileLocation: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let symbol: String

    var id: String { url.standardizedFileURL.path }
}

@MainActor
final class HostFilesBrowserModel: ObservableObject {
    @Published private(set) var root: URL
    @Published private(set) var directory: URL
    @Published private(set) var items: [HostFileRow] = []
    @Published private(set) var columnListings: [String: [HostFileRow]] = [:]
    @Published private(set) var columnListingsRevision = 0
    @Published var selection: HostFileRow.ID?
    @Published private(set) var error: String?
    @Published private(set) var sidebarLocations: [HostFileLocation]

    private var sortKey = "name"
    private var sortAscending = true
    private var reloadGeneration = 0
    private var reloadTask: Task<Void, Never>?
    private var sidebarGeneration = 0
    private var sidebarTask: Task<Void, Never>?
    private var treeLoadingPaths: Set<String> = []
    private var navigation = FilesBrowserNavigationHistory<URL>()
    private let includesSystemLocations: Bool
    private var sharedFolder: URL
    private let iconCache = NSCache<NSString, NSImage>()
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(root: URL, includesSystemLocations: Bool = false) {
        let sharedFolder = Self.canonical(root)
        self.includesSystemLocations = includesSystemLocations
        self.sharedFolder = sharedFolder
        self.root = includesSystemLocations
            ? URL(fileURLWithPath: "/", isDirectory: true) : sharedFolder
        directory = sharedFolder
        sidebarLocations = [Self.location(
            sharedFolder,
            symbol: includesSystemLocations
                ? "folder.badge.gearshape" : "externaldrive")]
        refreshSidebarLocations()
        reload()
    }

    var canGoUp: Bool {
        !Self.sameLocation(directory, root)
    }

    var breadcrumbs: [HostFileLocation] {
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard Self.contains(directory, within: root) else { return [] }

        var locations = [HostFileLocation(
            url: root,
            name: FileManager.default.displayName(atPath: root.path),
            symbol: "externaldrive")]
        guard !Self.sameLocation(directory, root) else { return locations }

        let rootComponents = root.pathComponents
        var cursor = root
        for component in directory.pathComponents.dropFirst(rootComponents.count) {
            cursor.appendPathComponent(component, isDirectory: true)
            locations.append(HostFileLocation(
                url: cursor,
                name: FileManager.default.displayName(atPath: cursor.path),
                symbol: "folder"))
        }
        return locations
    }

    func setRoot(_ root: URL) {
        let sharedFolder = Self.canonical(root)
        guard !Self.sameLocation(sharedFolder, self.sharedFolder) else { return }
        self.sharedFolder = sharedFolder
        self.root = includesSystemLocations
            ? URL(fileURLWithPath: "/", isDirectory: true) : sharedFolder
        directory = sharedFolder
        navigation = .init()
        selection = nil
        columnListings = [:]
        columnListingsRevision += 1
        refreshSidebarLocations()
        reload()
    }

    private func refreshSidebarLocations() {
        sidebarGeneration += 1
        let generation = sidebarGeneration
        let sharedFolder = sharedFolder
        let includesSystemLocations = includesSystemLocations
        sidebarTask?.cancel()
        sidebarTask = Task { [weak self] in
            let locations = await Task.detached(priority: .utility) {
                Self.loadSidebarLocations(
                    sharedFolder: sharedFolder,
                    includesSystemLocations: includesSystemLocations)
            }.value
            guard let self, !Task.isCancelled,
                  generation == self.sidebarGeneration,
                  Self.sameLocation(sharedFolder, self.sharedFolder) else {
                return
            }
            self.sidebarLocations = locations
        }
    }

    func go(to location: HostFileLocation) {
        navigate(to: location.url)
    }

    func validateSidebarDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]) {
            return .copy
        }
        return pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    func acceptSidebarDrop(_ info: NSDraggingInfo,
                           into location: HostFileLocation) -> Bool {
        let pasteboard = info.draggingPasteboard
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver] ?? []
        if !receivers.isEmpty {
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: location.url,
                    options: [:], operationQueue: promiseQueue
                ) { [weak self] _, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error { self.error = error.localizedDescription }
                        if Self.sameLocation(self.directory, location.url) {
                            self.reload()
                        }
                    }
                }
            }
            return true
        }

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        copySidebarDrop(urls, into: location.url)
        return true
    }

    private func copySidebarDrop(_ urls: [URL], into destination: URL) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> String? in
                do {
                    for source in urls {
                        let target = destination.appendingPathComponent(
                            source.lastPathComponent,
                            isDirectory: source.hasDirectoryPath)
                        let canonicalSource = source.standardizedFileURL
                            .resolvingSymlinksInPath().standardizedFileURL
                        let canonicalTarget = target.standardizedFileURL
                            .resolvingSymlinksInPath().standardizedFileURL
                        if canonicalSource == canonicalTarget {
                            continue
                        }
                        try FileManager.default.copyItem(at: source, to: target)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            if let result { self.error = result }
            if Self.sameLocation(self.directory, destination) { self.reload() }
        }
    }

    func isCurrentLocation(_ location: HostFileLocation) -> Bool {
        Self.sameLocation(directory, location.url)
    }

    func reload() {
        if includesSystemLocations { refreshSidebarLocations() }
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = directory
        let key = sortKey
        let ascending = sortAscending
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.loadRows(at: directory, key: key,
                              ascending: ascending)
            }.value
            guard let self, !Task.isCancelled,
                  generation == self.reloadGeneration else { return }
            switch result {
            case .success(let rows):
                self.items = rows
                self.columnListings[directory.path] = rows
                while self.columnListings.count > 64,
                      let key = self.columnListings.keys.first(where: {
                          $0 != self.directory.path
                      }) {
                    self.columnListings.removeValue(forKey: key)
                }
                self.columnListingsRevision += 1
                self.error = nil
            case .failure(let message):
                self.items = []
                self.error = message
            }
        }
    }

    func goUp() {
        let current = directory.standardizedFileURL
        let root = root.standardizedFileURL
        guard !Self.sameLocation(current, root) else { return }

        let parent = current
            .deletingLastPathComponent()
            .standardizedFileURL
        guard Self.contains(parent, within: root) else { return }
        navigate(to: parent)
    }

    func open(_ row: HostFileRow) {
        if row.isFolder {
            navigate(to: row.url)
        } else {
            NSWorkspace.shared.open(row.url)
        }
    }

    var canGoBack: Bool { navigation.canGoBack }
    var canGoForward: Bool { navigation.canGoForward }

    func goBack() {
        guard let destination = navigation.goBack(from: directory) else { return }
        navigate(to: destination, recordingHistory: false)
    }

    func goForward() {
        guard let destination = navigation.goForward(from: directory) else { return }
        navigate(to: destination, recordingHistory: false)
    }

    func select(_ row: HostFileRow?) {
        selection = row?.id
    }

    func loadTreeChildren(of row: HostFileRow) {
        let path = row.url.standardizedFileURL.path
        guard row.isFolder, Self.contains(row.url, within: root),
              columnListings[path] == nil,
              treeLoadingPaths.insert(path).inserted else { return }
        let key = sortKey
        let ascending = sortAscending
        let expectedRoot = root
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.loadRows(at: row.url, key: key, ascending: ascending)
            }.value
            guard let self else { return }
            self.treeLoadingPaths.remove(path)
            guard Self.sameLocation(expectedRoot, self.root) else { return }
            switch result {
            case .success(let rows):
                self.columnListings[path] = rows
                while self.columnListings.count > 64,
                      let old = self.columnListings.keys.first(where: {
                          $0 != self.directory.path && $0 != path
                      }) {
                    self.columnListings.removeValue(forKey: old)
                }
                self.columnListingsRevision += 1
            case .failure(let message):
                self.error = message
            }
        }
    }

    func icon(for row: FilesBrowserRow) -> NSImage {
        guard let host = row.hostRow else { return NSImage() }
        let key = host.url.standardizedFileURL.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: host.url.path)
        iconCache.setObject(image, forKey: key)
        return image
    }

    private func navigate(to url: URL, recordingHistory: Bool = true) {
        let destination = Self.canonical(url)
        guard Self.contains(destination, within: root),
              Self.isDirectory(destination),
              !Self.sameLocation(destination, directory) else { return }
        if recordingHistory {
            navigation.recordNavigation(from: directory, to: destination)
        }
        directory = destination
        selection = nil
        reload()
    }

    func setSort(key: String, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        applySort()
    }

    private func applySort() {
        items = Self.sorted(items, key: sortKey, ascending: sortAscending)
    }

    private enum LoadResult: Sendable {
        case success([HostFileRow])
        case failure(String)
    }

    nonisolated private static func loadRows(
        at directory: URL, key: String, ascending: Bool
    ) -> LoadResult {
        do {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .fileSizeKey,
                .contentModificationDateKey, .localizedTypeDescriptionKey,
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            let rows = urls.map { url in
                let values = try? url.resourceValues(forKeys: keys)
                let isFolder = values?.isDirectory == true
                return HostFileRow(
                    url: url.standardizedFileURL,
                    isFolder: isFolder,
                    sizeBytes: isFolder ? 0 : values?.fileSize ?? 0,
                    modified: values?.contentModificationDate,
                    kind: values?.localizedTypeDescription
                        ?? (isFolder ? "Folder" : "Document"))
            }
            return .success(sorted(rows, key: key, ascending: ascending))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    nonisolated private static func sorted(
        _ rows: [HostFileRow], key: String, ascending: Bool
    ) -> [HostFileRow] {
        let ordered: (HostFileRow, HostFileRow) -> Bool = { a, b in
            let result: ComparisonResult
            switch key {
            case "kind":
                result = a.kind.localizedStandardCompare(b.kind)
            case "size":
                result = a.sizeBytes == b.sizeBytes
                    ? a.name.localizedStandardCompare(b.name)
                    : (a.sizeBytes < b.sizeBytes ? .orderedAscending
                                                : .orderedDescending)
            case "modified":
                result = a.sortableDate == b.sortableDate
                    ? a.name.localizedStandardCompare(b.name)
                    : (a.sortableDate < b.sortableDate ? .orderedAscending
                                                       : .orderedDescending)
            default:
                result = a.name.localizedStandardCompare(b.name)
            }
            if result == .orderedSame, key != "name" {
                return a.name.localizedStandardCompare(b.name)
                    == .orderedAscending
            }
            return result == .orderedAscending
        }
        return rows.sorted { ascending ? ordered($0, $1) : ordered($1, $0) }
    }

    nonisolated private static func loadSidebarLocations(
        sharedFolder: URL, includesSystemLocations: Bool
    ) -> [HostFileLocation] {
        guard includesSystemLocations else {
            var locations = [HostFileLocation(
                url: sharedFolder,
                name: FileManager.default.displayName(atPath: sharedFolder.path),
                symbol: "externaldrive")]
            for (name, symbol) in conventionalFolders {
                let url = sharedFolder.appendingPathComponent(
                    name, isDirectory: true)
                guard isDirectory(url) else { continue }
                locations.append(location(url, symbol: symbol))
            }
            return locations
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let manager = FileManager.default
        let favorites = systemFavoriteLocations(fileManager: manager)
        let volumes = manager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey],
            options: [.skipHiddenVolumes])?.filter { volume in
                (try? volume.resourceValues(
                    forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable)
                    != false
            } ?? []
        return standardSidebarLocations(
            sharedFolder: sharedFolder, home: home,
            favoriteLocations: favorites, mountedVolumes: volumes,
            isDirectory: isDirectory)
    }

    nonisolated static func standardSidebarLocations(
        sharedFolder: URL, home: URL,
        favoriteLocations: [HostFileLocation], mountedVolumes: [URL],
        isDirectory: (URL) -> Bool
    ) -> [HostFileLocation] {
        var locations = [HostFileLocation(
            url: sharedFolder.standardizedFileURL,
            name: FileManager.default.displayName(atPath: sharedFolder.path),
            symbol: "folder.badge.gearshape")]
        let homeLocation = location(home, symbol: "house")
        if !locations.contains(where: { $0.id == homeLocation.id }) {
            locations.append(homeLocation)
        }
        for favorite in favoriteLocations where isDirectory(favorite.url) {
            guard !locations.contains(where: { $0.id == favorite.id }) else {
                continue
            }
            locations.append(favorite)
        }
        for volume in mountedVolumes where isDirectory(volume) {
            let item = location(volume, symbol: "externaldrive")
            guard !locations.contains(where: { $0.id == item.id }) else {
                continue
            }
            locations.append(item)
        }
        return locations
    }

    nonisolated private static func systemFavoriteLocations(
        fileManager: FileManager
    ) -> [HostFileLocation] {
        let searches: [(FileManager.SearchPathDirectory,
                        FileManager.SearchPathDomainMask, String)] = [
            (.desktopDirectory, .userDomainMask, "desktopcomputer"),
            (.documentDirectory, .userDomainMask, "doc"),
            (.downloadsDirectory, .userDomainMask, "arrow.down.circle"),
            (.applicationDirectory, .localDomainMask, "square.grid.3x3"),
            (.moviesDirectory, .userDomainMask, "film"),
            (.musicDirectory, .userDomainMask, "music.note"),
            (.picturesDirectory, .userDomainMask, "photo"),
        ]
        return searches.compactMap { directory, domain, symbol in
            guard let url = fileManager.urls(for: directory, in: domain).first
            else { return nil }
            return location(url, symbol: symbol)
        }
    }

    nonisolated private static let conventionalFolders: [(String, String)] = [
        ("Desktop", "desktopcomputer"),
        ("Documents", "doc"),
        ("Downloads", "arrow.down.circle"),
        ("Applications", "square.grid.3x3"),
        ("Movies", "film"),
        ("Music", "music.note"),
        ("Pictures", "photo"),
    ]

    nonisolated private static func location(
        _ url: URL, symbol: String
    ) -> HostFileLocation {
        let url = url.standardizedFileURL
        return HostFileLocation(
            url: url,
            name: FileManager.default.displayName(atPath: url.path),
            symbol: symbol)
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        // Preserve the standardized URL used for presentation, but resolve
        // aliases for the boundary comparison so /var and /private/var cannot
        // disagree about whether a legitimate child is inside the root.
        let candidatePath = canonical(candidate).path
        let rootPath = canonical(root).path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        canonical(lhs) == canonical(rhs)
    }
}

@MainActor
final class HostFileBrowserAdapter: FilesBrowserAdapter {
    private let model: HostFilesBrowserModel

    init(model: HostFilesBrowserModel) {
        self.model = model
    }

    var rows: [FilesBrowserRow] { model.items.map(FilesBrowserRow.host) }
    var rootDirectoryKey: String { model.directory.path }
    var currentDirectoryKey: String { model.directory.path }
    var contentRevision: Int { model.columnListingsRevision }
    var columnsAutosaveName: String { "FilesHostColumns" }
    var localDragOperation: NSDragOperation { .copy }
    var selectedRowIDs: Set<FilesBrowserRow.ID> {
        model.selection.map { [$0] } ?? []
    }

    func icon(for row: FilesBrowserRow) -> NSImage {
        model.icon(for: row)
    }

    func contains(_ candidate: String, within root: String) -> Bool {
        let root = root == "/" ? "/" : root + "/"
        return candidate == String(root.dropLast())
            || candidate.hasPrefix(root)
    }

    func children(of directoryKey: String) -> [FilesBrowserRow] {
        if directoryKey == model.directory.path {
            return model.items.map(FilesBrowserRow.host)
        }
        return (model.columnListings[directoryKey] ?? [])
            .map(FilesBrowserRow.host)
    }

    func requestChildren(of row: FilesBrowserRow) {
        guard let host = row.hostRow else { return }
        model.loadTreeChildren(of: host)
    }

    func setSort(key: String, ascending: Bool) {
        model.setSort(key: key, ascending: ascending)
    }

    func setSelection(_ rows: [FilesBrowserRow]) {
        model.select(rows.first?.hostRow)
    }

    func menuItems(for row: FilesBrowserRow,
                   selection: [FilesBrowserRow]) -> [FilesBrowserMenuItem] {
        [
            .init("Open", .open),
            .init("Show in Finder", .showInFinder),
            .separator,
            .init("Copy Path", .copyPath),
        ]
    }

    func perform(_ action: FilesBrowserAction, clicked: FilesBrowserRow?,
                 selection: [FilesBrowserRow]) {
        let row = clicked ?? selection.first
        guard let host = row?.hostRow else { return }
        switch action {
        case .open:
            model.open(host)
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([host.url])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host.url.path, forType: .string)
        default:
            break
        }
    }

    func pasteboardWriter(for row: FilesBrowserRow,
                          promiseDelegate: NSFilePromiseProviderDelegate?)
        -> NSPasteboardWriting? {
        guard let host = row.hostRow else { return nil }
        return host.url as NSURL
    }
}

struct FilesHostFolderTitle: View {
    @ObservedObject var model: HostFilesBrowserModel

    var body: some View {
        FilesCurrentFolderControl(
            display: .host(breadcrumbs: model.breadcrumbs,
                           source: String(localized: "Local")),
            isEnabled: true,
            select: { id in
                guard let location = model.breadcrumbs.first(where: {
                    $0.url.standardizedFileURL.path == id
                }) else { return }
                model.go(to: location)
            }
        )
        .frame(minWidth: 96, idealWidth: 180, maxWidth: 320,
               minHeight: FilesStyle.controlHeight)
    }
}

struct HostFilesBrowserActions: View {
    @ObservedObject var model: HostFilesBrowserModel

    var body: some View {
        FilesToolbarActionButton(
            symbol: "arrow.clockwise", label: "Refresh",
            help: String(localized: "Refresh files on this Mac"),
            isEnabled: true, action: model.reload)
            .padding(3)
            .nowGlassPanel(cornerRadius: FilesStyle.controlHeight)
    }
}

struct HostFilesSidebar: View {
    @ObservedObject var model: HostFilesBrowserModel
    let compact: Bool
    let toggleCompact: () -> Void

    private static var draggedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
        return types
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                HStack(spacing: 6) {
                    FilesBrowserSidebarToggle(
                        compact: compact, action: toggleCompact)
                    Text("Places")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, FilesStyle.chromeHorizontalPadding)
                .frame(height: 32)
            } else {
                FilesBrowserSidebarToggle(
                    compact: compact, action: toggleCompact)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            List(model.sidebarLocations) { location in
                FilesNativeSidebarRow(
                    title: location.name,
                    symbolName: location.symbol,
                    compact: compact,
                    isActive: model.isCurrentLocation(location),
                    isEnabled: true,
                    toolTip: location.url.path,
                    draggedTypes: Self.draggedTypes,
                    activate: { model.go(to: location) },
                    validateDrop: { model.validateSidebarDrop($0) },
                    acceptDrop: {
                        model.acceptSidebarDrop($0, into: location)
                    })
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 30 : 28)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: compact ? 52 : 176)
        .animation(.easeInOut(duration: 0.18), value: compact)
        .background(FilesSidebarVibrancyBackground())
    }
}

struct FilesHostBrowserView: View {
    @ObservedObject var model: HostFilesBrowserModel
    let view: FilesBrowserView

    var body: some View {
        FilesBrowserNavigationHost(
            goBack: model.goBack, goForward: model.goForward) {
                HostBrowserContent(model: model, view: view)
                .overlay {
                    if let error = model.error {
                        HostFilesBrowserUnavailable(
                            title: "Could Not List Folder",
                            symbol: "exclamationmark.folder",
                            detail: error)
                    } else if model.items.isEmpty {
                        HostFilesBrowserUnavailable(
                            title: "This Folder Is Empty", symbol: "folder")
                    }
                }
            }
    }
}

private struct HostFilesBrowserUnavailable: View {
    let title: LocalizedStringResource
    let symbol: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 32))
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.secondary)
        .padding()
    }
}
