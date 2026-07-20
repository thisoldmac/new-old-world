import AppKit
import Combine
import Foundation

/// One row in the browser: a guest listing entry plus what a pull of it
/// would do.
struct FileRow: Identifiable, Equatable {
    var entry: FileEntry
    var path: String

    var id: String { path.isEmpty ? entry.name : path }
    var name: String { entry.name }
    var isFolder: Bool { entry.isFolder }

    var kind: String {
        if entry.isFolder { return "Folder" }
        guard let type = entry.fileType, !type.isEmpty else {
            return "Document"
        }
        switch type {
        case "APPL": return "Application"
        case "TEXT", "ttro": return "Text"
        case "PICT": return "Picture"
        case "GIFf": return "GIF image"
        case "JPEG": return "JPEG image"
        case "MooV": return "QuickTime movie"
        case "ZIP ", "SIT!", "SITD": return "Archive"
        case "sfil": return "Sound"
        case "FNDR", "ZSYS": return "System"
        default: return type
        }
    }

    var sizeBytes: Int {
        (entry.dataBytes ?? 0) + (entry.rsrcBytes ?? 0)
    }

    var modified: Date? {
        entry.modified.flatMap(ClassicDate.date(from:))
    }

    /// What a download would do — shown as a badge so automatic never
    /// means opaque.
    var conversionNote: String? {
        guard !entry.isFolder else { return nil }
        let container = (entry.dataBytes ?? 0) == 0
            && (entry.rsrcBytes ?? 0) > 0 ? "macbinary" : "data"
        return FileConverter.plan(fileType: entry.fileType,
                                  name: entry.name, container: container)
    }

    var symbolName: String {
        if entry.isFolder { return "folder" }
        switch entry.fileType {
        case "APPL": return "app.dashed"
        case "TEXT", "ttro": return "doc.text"
        case "PICT", "GIFf", "JPEG": return "photo"
        case "MooV": return "film"
        case "ZIP ", "SIT!", "SITD": return "shippingbox"
        case "sfil": return "waveform"
        default:
            return (entry.rsrcBytes ?? 0) > 0 && (entry.dataBytes ?? 0) == 0
                ? "doc.badge.gearshape" : "doc"
        }
    }
}

@MainActor
final class FilesModuleModel: ObservableObject {
    @Published var connection: GuestConnectionState = .disconnected
    /// Path components from the share root; empty = the root itself.
    @Published private(set) var breadcrumb: [String] = []
    @Published private(set) var rows: [FileRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var transfer: TransferState?
    @Published var selection: FileRow.ID?

    /// Where downloads land. Separate from the screenshots landing pad:
    /// files are files.
    @Published var downloadDirectory: URL {
        didSet {
            defaults.set(downloadDirectory.path, forKey: Keys.downloads)
        }
    }

    /// A file the guest already has under this name. Sending it again
    /// is the one destructive thing this module does, so it waits for a
    /// human rather than resolving itself.
    struct OverwritePrompt: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var url: URL
        var folder: String
    }

    @Published var overwritePrompt: OverwritePrompt?

    /// Inbound text conversion is destructive in a way downloading is
    /// not — a file that only looked like text comes out changed — so it
    /// can be switched off.
    @Published var convertText: Bool {
        didSet { defaults.set(convertText, forKey: Keys.convertText) }
    }

    struct TransferState: Equatable {
        var name: String
        var direction: Direction
        var received: Int
        var expected: Int

        enum Direction { case incoming, outgoing }
        var fraction: Double {
            expected > 0 ? min(1, Double(received) / Double(expected)) : 0
        }
    }

    var path: String { breadcrumb.joined(separator: ":") }
    var canBrowse: Bool { connection.canCapture }

    private enum Keys {
        static let downloads = "files.downloadDirectory"
        static let convertText = "files.convertText"
    }

    private let listener: GuestListener
    private let defaults: UserDefaults
    private var progressWatch: AnyCancellable?
    private var pageCursor: Int?

    init(listener: GuestListener, defaults: UserDefaults = .standard) {
        self.listener = listener
        self.defaults = defaults
        self.convertText =
            defaults.object(forKey: Keys.convertText) as? Bool ?? true
        let stored = defaults.string(forKey: Keys.downloads)
        self.downloadDirectory = stored.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory,
                                        in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        progressWatch = listener.$captureProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self, var state = self.transfer,
                      let progress else { return }
                state.received = progress.received
                state.expected = progress.expected
                self.transfer = state
            }
    }

    // MARK: - Browsing

    func refresh() {
        load(path: path, resetRows: true)
    }

    func open(_ row: FileRow) {
        guard row.isFolder else { return }
        breadcrumb.append(row.name)
        load(path: path, resetRows: true)
    }

    func goUp() {
        guard !breadcrumb.isEmpty else { return }
        breadcrumb.removeLast()
        load(path: path, resetRows: true)
    }

    /// Jump to a breadcrumb component; -1 is the share root.
    func jump(toDepth depth: Int) {
        guard depth < breadcrumb.count else { return }
        breadcrumb = depth < 0 ? [] : Array(breadcrumb.prefix(depth + 1))
        load(path: path, resetRows: true)
    }

    func loadMoreIfNeeded() {
        guard let cursor = pageCursor, !isLoading else { return }
        load(path: path, resetRows: false, cursor: cursor)
    }

    private func load(path: String, resetRows: Bool, cursor: Int? = nil) {
        guard canBrowse else { return }
        if resetRows {
            rows = []
            pageCursor = nil
            selection = nil
        }
        isLoading = true
        lastError = nil
        listener.listFiles(path: path, cursor: cursor) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .success(let listing):
                // A late page from a folder we already left is dropped.
                guard listing.path == self.path else { return }
                let prefix = listing.path.isEmpty ? "" : listing.path + ":"
                self.rows += listing.entries.map {
                    FileRow(entry: $0, path: prefix + $0.name)
                }
                self.pageCursor = listing.more ? listing.cursor : nil
            case .failure(let failure):
                self.lastError = failure.message
                self.pageCursor = nil
            }
        }
    }

    // MARK: - Download

    func download(_ row: FileRow, container: String? = nil) {
        guard !row.isFolder, transfer == nil else { return }
        lastError = nil
        transfer = TransferState(name: row.name, direction: .incoming,
                                 received: 0, expected: row.sizeBytes)
        listener.getFile(path: row.path,
                         container: container) { [weak self] result in
            guard let self else { return }
            self.transfer = nil
            switch result {
            case .success(let file):
                self.write(file)
            case .failure(let failure):
                self.lastError = failure.message
            }
        }
    }

    func cancelTransfer() {
        listener.cancelFile()
    }

    // MARK: - Sending

    /// Sends a file from anywhere on this Mac into the folder being
    /// browsed. The share bounds what the other machine may reach on its
    /// own; it never bounds what a human deliberately sends, so the
    /// source is any file at all.
    func send(_ url: URL, overwrite: Bool = false) {
        guard canBrowse, transfer == nil else { return }
        guard let data = try? Data(contentsOf: url) else {
            lastError = "Could not read \(url.lastPathComponent)"
            return
        }
        let plan = OutboundFile.plan(url: url, data: data,
                                     convertText: convertText)
        lastError = nil
        transfer = TransferState(name: plan.name, direction: .outgoing,
                                 received: 0, expected: plan.bytes.count)
        let folder = path
        listener.putFile(name: plan.name, into: folder,
                         container: plan.container, bytes: plan.bytes,
                         fileType: plan.fileType, creator: plan.creator,
                         modified: nil,
                         overwrite: overwrite) { [weak self] result in
            guard let self else { return }
            self.transfer = nil
            switch result {
            case .success:
                self.refresh()
            case .failure(let failure) where failure.code == "exists":
                // Not an error: the human has a decision to make.
                self.overwritePrompt = OverwritePrompt(
                    name: plan.name, url: url, folder: folder)
            case .failure(let failure):
                self.lastError = failure.message
            }
        }
    }

    func confirmOverwrite() {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        send(prompt.url, overwrite: true)
    }

    func cancelOverwrite() {
        overwritePrompt = nil
    }

    @discardableResult
    func write(_ file: GuestListener.FileDelivery) -> URL? {
        let converted = FileConverter.convert(
            name: file.name, container: file.container,
            fileType: file.fileType, bytes: file.bytes)
        var url = downloadDirectory
            .appendingPathComponent(sanitized(converted.name))
        var bump = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (converted.name as NSString).deletingPathExtension
            let ext = (converted.name as NSString).pathExtension
            let name = ext.isEmpty ? "\(base) (\(bump))"
                                   : "\(base) (\(bump)).\(ext)"
            url = downloadDirectory.appendingPathComponent(sanitized(name))
            bump += 1
        }
        do {
            try converted.data.write(to: url)
            if let modified = file.modified,
               let date = ClassicDate.date(from: modified) {
                try? FileManager.default.setAttributes(
                    [.modificationDate: date], ofItemAtPath: url.path)
            }
            return url
        } catch {
            lastError = "Could not save \(converted.name): "
                + error.localizedDescription
            return nil
        }
    }

    /// HFS names can hold "/" (which is the path separator here) and the
    /// classic side allows leading dots; make the name safe for APFS
    /// without renaming beyond recognition.
    private func sanitized(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "/", with: ":")
        if out.hasPrefix(".") { out = "_" + out.dropFirst() }
        return out.isEmpty ? "Untitled" : out
    }
}
