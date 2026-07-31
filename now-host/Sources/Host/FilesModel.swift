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

    /// Sorting needs a total order; undated items sort oldest rather
    /// than scattering.
    var sortableDate: Date {
        modified ?? Date(timeIntervalSince1970: 0)
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
final class FilesModuleModel: ObservableObject, GuestScopedModel {
    /// Where one machine's browser was left, parked while another is
    /// driven.
    ///
    /// The load-bearing member is the BREADCRUMB, and it is the clearest
    /// case in the whole slice: `Macintosh HD:System Folder:Extensions` is
    /// not a path that means something different on the other Mac, it is a
    /// path that may not exist there at all. Restoring a person to where
    /// they were on each machine is also what a file browser is expected to
    /// do; the rows come with it because they are that path's listing and
    /// the two are meaningless apart.
    ///
    /// It survives a disconnect the way it always has — nothing here
    /// cleared on one — so a machine that drops mid-browse and comes back
    /// is still in its own folder.
    struct Snapshot {
        var breadcrumb: [String] = []
        var rows: [FileRow] = []
        var selection: FileRow.ID?
        var shareRoot: String?
        var pageCursor: Int?
        var history: [FileChange] = []
    }

    private let cache = GuestStateCache<Snapshot>()

    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }
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
    /// human rather than resolving itself. Mid-queue it offers to skip,
    /// because answering one collision should not abandon the rest.
    struct OverwritePrompt: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var url: URL
        var folder: String
        var remaining: Int
    }

    /// One file waiting to go, with where it lands. A dropped FOLDER
    /// becomes many of these, each carrying the subpath it should keep,
    /// which is why the destination travels with the item rather than
    /// being read from wherever the browser happens to be by then.
    struct QueueItem: Equatable {
        var url: URL
        var folder: String
    }

    /// The wire carries one transfer at a time, so a multi-file drop is
    /// a queue rather than a refusal.
    @Published private(set) var queue: [QueueItem] = []
    private var queueTotal = 0
    private var queueDone = 0

    @Published var overwritePrompt: OverwritePrompt?

    /// Changing the share: what is being asked about, what has been done
    /// this session, and whether a change is in flight. See FileChanges.
    @Published var pendingChange: PendingChange?
    @Published var history: [FileChange] = []
    @Published var isChanging = false

    /// Renaming happens in the row itself; this is which row is open for
    /// editing, so the browser and the module agree on one at a time.
    @Published var renaming: FileRow.ID?

    /// A folder being named before it exists, so it is a sheet rather
    /// than a row that is not there yet.
    @Published var newFolderName: String?

    func reportChangeFailure(_ message: String) {
        lastError = message
    }

    func reportChangeOK() {
        lastError = nil
    }

    /// Inbound text conversion is destructive in a way downloading is
    /// not — a file that only looked like text comes out changed — so it
    /// can be switched off.
    /// What this Mac shares back. The guest reaches it on its own
    /// initiative, so it lives beside — not inside — the folder we
    /// download into: one is what they may take, the other is where
    /// what we take lands.
    /// What the guest says it is sharing, in its own spelling
    /// ("Macintosh HD:Lab:"). The breadcrumb names that place rather
    /// than calling it "Share", which told you nothing about which
    /// folder you were looking into.
    @Published private(set) var shareRoot: String?

    /// The path as the bar draws it: the disk, the published folder, the
    /// folders inside it, and whatever the width made us fold away. The
    /// decomposition lives in `FilePathBar`; this is only the join of it
    /// to what this window currently knows.
    ///
    /// It replaced a lone crumb that showed the last component of the
    /// share root and nothing else — which named a folder without ever
    /// saying which disk it was on, and left an up button as the only way
    /// to move.
    var pathItems: [FilePathBar.Item] {
        FilePathBar.items(shareRoot: shareRoot, breadcrumb: breadcrumb)
    }

    /// The whole path in the guest's own spelling, for the bar's tooltip.
    var fullPath: String {
        FilePathBar.fullPath(shareRoot: shareRoot, breadcrumb: breadcrumb)
    }

    /// Why the bar looks the way it does, so it always says something.
    /// A failed listing keeps its crumbs: where you tried to be is what
    /// you need in order to go somewhere else.
    var pathStatus: FilePathBar.Status {
        if !canBrowse { return .noGuest }
        if let error = lastError { return .failed(error) }
        if shareRoot != nil { return .ready }
        return isLoading ? .loading : .unlisted
    }

    @Published var shareDirectory: URL {
        didSet {
            listener.share.root = shareDirectory
        }
    }

    @Published var convertText: Bool {
        didSet {
            defaults.set(convertText, forKey: Keys.convertText)
            listener.convertServedText = convertText
        }
    }

    struct TransferState: Equatable {
        var name: String
        var direction: Direction
        var received: Int
        var expected: Int
        /// Position in a multi-file drop, 1-based; nil when alone.
        var index: Int?
        var total: Int?
        var startedAt = Date()

        enum Direction { case incoming, outgoing }

        /// Handing the last chunk to the OS is not the same as the other
        /// machine having it: the bar counts bytes accepted for sending,
        /// and the classic Mac reads them far slower than we write them.
        /// Everything after that point is real work with nothing local
        /// left to measure, so the UI stops pretending to have a
        /// percentage and says what is actually going on.
        var isAwaitingReceipt: Bool {
            direction == .outgoing && expected > 0 && received >= expected
        }
        var fraction: Double {
            expected > 0 ? min(1, Double(received) / Double(expected)) : 0
        }
    }

    var path: String { breadcrumb.joined(separator: ":") }
    var canBrowse: Bool { connection.canCapture }

    /// Failures that say the wire is gone rather than that one file was
    /// unacceptable.
    private static let fatalToAQueue: Set<String> = [
        "disconnected", "timeout", "cancelled",
    ]

    private enum Keys {
        static let downloads = "files.downloadDirectory"
        static let convertText = "files.convertText"
    }

    internal let listener: GuestListener
    private let defaults: UserDefaults
    private let artifactApprover: AgentIntegrationHostAdapter?
    private var progressWatch: AnyCancellable?
    private var pageCursor: Int?

    init(
        listener: GuestListener,
        defaults: UserDefaults = .standard,
        artifactApprover: AgentIntegrationHostAdapter? = nil
    ) {
        self.listener = listener
        self.defaults = defaults
        self.artifactApprover = artifactApprover
        self.convertText =
            defaults.object(forKey: Keys.convertText) as? Bool ?? true
        self.shareDirectory = listener.share.root
        let stored = defaults.string(forKey: Keys.downloads)
        self.downloadDirectory = stored.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory,
                                        in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        listener.convertServedText = convertText
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

    /// The rows in display order, sorted once per change rather than
    /// once per `body`. A transfer republishes progress per frame, and
    /// sorting the listing on every one of those is work nothing asked
    /// for — the listing did not change.
    private var sortCache: (order: [KeyPathComparator<FileRow>],
                            rows: [FileRow], sorted: [FileRow])?

    func sorted(using order: [KeyPathComparator<FileRow>]) -> [FileRow] {
        if let cache = sortCache, cache.order == order, cache.rows == rows {
            return cache.sorted
        }
        let sorted = rows.sorted(using: order)
        sortCache = (order, rows, sorted)
        return sorted
    }

    // MARK: - Which machine is being browsed

    private func connectionChanged(from old: GuestConnectionState) {
        guard connection != old,
              case .switched(let restored) =
                cache.focus(connection.key, parking: snapshot())
        else { return }
        let fresh = restored ?? Snapshot()
        breadcrumb = fresh.breadcrumb
        rows = fresh.rows
        selection = fresh.selection
        shareRoot = fresh.shareRoot
        pageCursor = fresh.pageCursor
        history = fresh.history
        isLoading = false
        lastError = nil
        transfer = nil
        renaming = nil
        newFolderName = nil
        pendingChange = nil
        overwritePrompt = nil
        /* A queue of files is the one thing here that must NOT survive the
           switch, parked or otherwise. It is a list of things to WRITE, and
           the machine they were meant for is no longer the one on the other
           end of the wire — sending them anyway is the destructive version
           of the bug this whole slice is about. Dropping them says so out
           loud rather than resuming against the wrong Mac later. */
        if !queue.isEmpty {
            let dropped = queue.count
            lastError = "\(dropped) file\(dropped == 1 ? "" : "s") "
                + "still waiting to send were dropped: they were meant for "
                + "the other Mac."
        }
        queue = []
        queueTotal = 0
        queueDone = 0
    }

    private func snapshot() -> Snapshot {
        Snapshot(breadcrumb: breadcrumb, rows: rows, selection: selection,
                 shareRoot: shareRoot, pageCursor: pageCursor,
                 history: history)
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
                if let root = listing.root, !root.isEmpty {
                    self.shareRoot = root
                }
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
        listener.getFile(path: row.path, container: container,
                         stagingDirectory: downloadDirectory) {
            [weak self] result in
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

    func approveForAgent(_ url: URL)
        -> Result<AgentIntegrationArtifactApprovalNotice,
                  AgentIntegrationArtifactApprovalError> {
        guard let artifactApprover else {
            return .failure(.unavailable(
                "Artifact approval staging is unavailable"))
        }
        return artifactApprover.approveArtifact(
            sourceURL: url,
            destination: path,
            convertText: convertText)
    }

    /// Sends a file from anywhere on this Mac into the folder being
    /// browsed. The share bounds what the other machine may reach on its
    /// own; it never bounds what a human deliberately sends, so the
    /// source is any file at all.
    /// How many files one drop may expand into. A dropped folder can
    /// hold thousands; at this wire's speed that is hours, so it is
    /// refused with a count rather than started and abandoned.
    static let dropFileLimit = 500

    /// Enqueues a drop. A dropped folder is walked, and each file keeps
    /// its position beneath it. `into` is the destination folder for the
    /// drop itself (a folder row, or the folder being browsed).
    func enqueue(_ urls: [URL], into folder: String? = nil) {
        guard canBrowse, !urls.isEmpty else { return }
        let base = folder ?? path
        var items: [QueueItem] = []
        var skipped = 0
        for url in urls {
            expand(url, into: base, items: &items, skipped: &skipped)
        }
        guard !items.isEmpty else {
            if skipped > 0 {
                lastError = "Nothing to send — \(skipped) item"
                    + (skipped == 1 ? "" : "s") + " skipped."
            }
            return
        }
        if items.count > Self.dropFileLimit {
            lastError = "That is \(items.count) files; "
                + "\(Self.dropFileLimit) at a time is the limit."
            return
        }
        queue.append(contentsOf: items)
        queueTotal = queueDone + queue.count
        if skipped > 0 {
            lastError = "\(skipped) item"
                + (skipped == 1 ? " was" : "s were") + " skipped."
        }
        startNextIfIdle()
    }

    /// Walks a dropped URL into files. Folders keep their shape on the
    /// other side; empty ones do not survive, since nothing carries a
    /// folder on its own. Hidden files are left behind — a classic Mac
    /// has no use for .DS_Store.
    private func expand(_ url: URL, into folder: String,
                        items: inout [QueueItem], skipped: inout Int) {
        let name = url.lastPathComponent
        if name.hasPrefix(".") {
            skipped += 1
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory)
        else {
            skipped += 1
            return
        }
        guard isDirectory.boolValue else {
            items.append(QueueItem(url: url, folder: folder))
            return
        }
        let child = folder.isEmpty
            ? OutboundFile.hfsName(name)
            : folder + ":" + OutboundFile.hfsName(name)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []
        if contents.isEmpty {
            skipped += 1          // an empty folder has nothing to carry
            return
        }
        for entry in contents.sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            expand(entry, into: child, items: &items, skipped: &skipped)
        }
    }

    private func startNextIfIdle() {
        guard transfer == nil, overwritePrompt == nil,
              !queue.isEmpty else {
            if queue.isEmpty && transfer == nil {
                queueTotal = 0
                queueDone = 0
            }
            return
        }
        let item = queue.removeFirst()
        send(item.url, into: item.folder)
    }

    /// Abandons everything not yet sent; the one in flight is cancelled
    /// separately, so stopping a queue never loses a finished file.
    func clearQueue() {
        queue = []
        queueTotal = 0
        queueDone = 0
    }

    func send(_ url: URL, into folder: String? = nil,
              overwrite: Bool = false) {
        guard canBrowse, transfer == nil else { return }
        guard let data = try? Data(contentsOf: url) else {
            lastError = "Could not read \(url.lastPathComponent)"
            return
        }
        let plan = OutboundFile.plan(url: url, data: data,
                                     convertText: convertText)
        // Keep the file's own date. Landing everything stamped "now"
        // makes a transferred folder useless for telling what changed.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
            .flatMap(ClassicDate.guestWireSeconds(from:))
        lastError = nil
        queueDone += 1
        transfer = TransferState(
            name: plan.name, direction: .outgoing, received: 0,
            expected: plan.bytes.count,
            index: queueTotal > 1 ? queueDone : nil,
            total: queueTotal > 1 ? queueTotal : nil)
        let folder = folder ?? path
        listener.putFile(name: plan.name, into: folder,
                         container: plan.container, bytes: plan.bytes,
                         fileType: plan.fileType, creator: plan.creator,
                         modified: modified,
                         overwrite: overwrite) { [weak self] result in
            guard let self else { return }
            self.transfer = nil
            switch result {
            case .success:
                self.refresh()
                self.startNextIfIdle()
            case .failure(let failure) where failure.code == "exists":
                // Not an error: the human has a decision to make, and
                // the queue waits rather than racing past it.
                self.queueDone -= 1
                self.overwritePrompt = OverwritePrompt(
                    name: plan.name, url: url, folder: folder,
                    remaining: self.queue.count)
            case .failure(let failure):
                self.lastError = failure.message
                // A connection that has gone away will fail every file
                // behind this one too. Stop, rather than turning one
                // problem into twenty error messages.
                if Self.fatalToAQueue.contains(failure.code) {
                    if !self.queue.isEmpty {
                        self.lastError = failure.message
                            + " — \(self.queue.count) file"
                            + (self.queue.count == 1 ? "" : "s")
                            + " not sent."
                    }
                    self.clearQueue()
                } else {
                    self.startNextIfIdle()
                }
            }
        }
    }

    func confirmOverwrite() {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        send(prompt.url, into: prompt.folder, overwrite: true)
    }

    /// Leaves that file alone and carries on with the rest.
    func skipOverwrite() {
        overwritePrompt = nil
        startNextIfIdle()
    }

    /// Answering "stop" abandons what is queued behind it too.
    func cancelOverwrite() {
        overwritePrompt = nil
        clearQueue()
    }

    /// Pulls a file for a drag to the Finder. The Finder asks for the
    /// bytes only when the drop lands, so this is the moment the file
    /// actually crosses — and the one transfer lane still applies, so a
    /// promise asked for mid-transfer is refused rather than queued
    /// behind something the Finder is not waiting for.
    func fetchForPromise(_ row: FileRow, to destination: URL,
                         container: String? = nil,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard transfer == nil else {
            completion(.failure(FilesError.busy))
            return
        }
        transfer = TransferState(name: row.name, direction: .incoming,
                                 received: 0, expected: row.sizeBytes,
                                 index: nil, total: nil)
        listener.getFile(
            path: row.path, container: container,
            stagingDirectory: destination.deletingLastPathComponent()) {
            [weak self] result in
            guard let self else { return }
            self.transfer = nil
            switch result {
            case .success(let file):
                do {
                    try self.materialize(file, to: destination)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let failure):
                self.lastError = failure.message
                completion(.failure(FilesError.wire(failure.message)))
            }
        }
    }

    enum FilesError: LocalizedError {
        case busy
        case wire(String)

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Another transfer is already running."
            case .wire(let message):
                return message
            }
        }
    }

    @discardableResult
    func write(_ file: GuestListener.FileDelivery) -> URL? {
        let outputName = FileConverter.outputName(
            name: file.name, container: file.container)
        var url = downloadDirectory
            .appendingPathComponent(sanitized(outputName))
        var bump = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (outputName as NSString).deletingPathExtension
            let ext = (outputName as NSString).pathExtension
            let name = ext.isEmpty ? "\(base) (\(bump))"
                                   : "\(base) (\(bump)).\(ext)"
            url = downloadDirectory.appendingPathComponent(sanitized(name))
            bump += 1
        }
        do {
            try materialize(file, to: url)
            return url
        } catch {
            lastError = "Could not save \(outputName): "
                + error.localizedDescription
            return nil
        }
    }

    private func materialize(_ file: GuestListener.FileDelivery,
                             to destination: URL) throws {
        try FileConverter.materialize(
            name: file.name, container: file.container,
            fileType: file.fileType, staged: file.staged, to: destination)
        if let modified = file.modified,
           let date = ClassicDate.date(from: modified) {
            try? FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: destination.path)
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
