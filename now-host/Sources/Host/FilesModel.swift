import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

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
    /// Something that happened and was not a failure — a file that
    /// landed where nothing here can open it, say. It reads beside the
    /// error rather than as one, because calling a success an error
    /// teaches people to ignore the red text.
    @Published var lastNotice: String?
    @Published private(set) var transfer: TransferState?
    @Published var selection: FileRow.ID?
    /// Set only for the lifetime of a local one-folder drag. The sidebar
    /// reads source-owned state instead of accepting arbitrary text from
    /// the pasteboard.
    var draggedFolderPath: String?

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

    struct NewFolderPrompt: Identifiable, Equatable {
        let id = UUID()
        let initialName: String
    }

    /// Presentation state only. The sheet owns the editable draft so a
    /// late TextField update cannot resurrect a prompt that was dismissed
    /// before the guest's successful reply arrived.
    @Published private(set) var newFolderPrompt: NewFolderPrompt?

    func beginNewFolder() {
        newFolderPrompt = NewFolderPrompt(initialName: "untitled folder")
    }

    func cancelNewFolder() {
        newFolderPrompt = nil
    }

    func createFolderFromPrompt(named name: String) {
        newFolderPrompt = nil
        createFolder(named: name)
    }

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
        /// Set when this transfer was started by a double-click, so the
        /// progress row can say what is going to happen. A slow file
        /// that opens in thirty seconds and a slow file that opens never
        /// look identical until one of them says which it is.
        var opensWhenDone = false
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
    /// What the wire tells this page without being asked: how far a
    /// transfer has got, and that the folder it is showing is no longer
    /// what the last listing said.
    ///
    /// Scoped to the machine being browsed, because both are claims about
    /// ONE Mac's disk and a background guest's upload finishing must not
    /// reload a listing of a different machine's folder.
    private var busWatch: HostEventSubscription?
    private var pageCursor: Int?
    /// Identifies the full-folder read that owns `rows`. Two refreshes may
    /// be in flight at once (a mutation publishes an event before its own
    /// completion runs), and a path comparison cannot distinguish them
    /// when both asked for the same folder.
    private var listingGeneration = 0

    private lazy var promiseExporter = GuestFilePromiseExporter(
        listPage: { [weak self] path, cursor, completion in
            guard let self else {
                completion(.failure(FilesError.wire(
                    "The file browser is no longer available.")))
                return
            }
            self.listener.listFiles(path: path, cursor: cursor) { result in
                completion(result.mapError { FilesError.wire($0.message) })
            }
        },
        fetchFile: { [weak self] row, destination, completion in
            guard let self else {
                completion(.failure(FilesError.wire(
                    "The file browser is no longer available.")))
                return
            }
            self.fetchOneForPromise(row, to: destination,
                                    completion: completion)
        })

    init(
        listener: GuestListener,
        defaults: UserDefaults = .standard,
        artifactApprover: AgentIntegrationHostAdapter? = nil
    ) {
        self.listener = listener
        self.defaults = defaults
        self.artifactApprover = artifactApprover
        self.locationsStore = FileLocationsStore(defaults: defaults)
        self.convertText =
            defaults.object(forKey: Keys.convertText) as? Bool ?? true
        self.shareDirectory = listener.share.root
        let stored = defaults.string(forKey: Keys.downloads)
        self.downloadDirectory = stored.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory,
                                        in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        listener.convertServedText = convertText
        busWatch = listener.events.subscribe(
            scopedTo: { [weak self] in self?.connection.key }
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .transferProgressed(_, let received, let expected):
                guard var state = self.transfer else { return }
                state.received = received
                state.expected = expected
                self.transfer = state
            /* The page stops being true the moment anything changes the
               guest's disk — a change this window made, an agent's upload,
               a mutation over the command surface. It used to stay wrong
               until somebody clicked Refresh; the whole point of the bus is
               that nobody has to. Only when this page is showing a listing:
               a reload with nothing on screen would ask a question no
               person is waiting on the answer to. */
            case .fileTreeChanged(_, let side, _) where side == .guest:
                guard self.canBrowse, !self.rows.isEmpty else { return }
                self.refresh()
            default:
                break
            }
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
        guard connection != old else { return }
        if case .switched(let restored) =
            cache.focus(connection.key, parking: snapshot()) {
            listingGeneration += 1
            let fresh = restored ?? Snapshot()
            breadcrumb = fresh.breadcrumb
            rows = fresh.rows
            selection = fresh.selection
            shareRoot = fresh.shareRoot
            pageCursor = fresh.pageCursor
            history = fresh.history
            isLoading = false
            lastError = nil
            lastNotice = nil
            transfer = nil
            renaming = nil
            draggedFolderPath = nil
            newFolderPrompt = nil
            promiseExporter.cancelAll(
                reason: "The connected guest changed while files were being copied.")
            pendingChange = nil
            overwritePrompt = nil
            /* A queue of files is the one thing here that must NOT survive the
               switch, parked or otherwise. It is a list of things to WRITE,
               and the machine they were meant for is no longer the one on the
               other end of the wire — sending them anyway is the destructive
               version of the bug this whole slice is about. */
            if !queue.isEmpty {
                let dropped = queue.count
                lastError = "\(dropped) file\(dropped == 1 ? "" : "s") "
                    + "still waiting to send were dropped: they were meant for "
                    + "\(MachineNaming.simpleReference)."
            }
            queue = []
            queueTotal = 0
            queueDone = 0
            /* The sidebar is one machine's furniture, and the customisation
               of it is that machine's too. Discovered rows go with the old
               machine rather than being parked: they are a claim about a disk
               that is no longer on the other end of the wire. */
            discoveredLocations = []
            reloadStoredLocations()
        }

        /* A page may already be on screen when the same guest reconnects, so
           `onAppear` is not a connection hook. Every newly usable connection
           revalidates both the open folder and the guest-derived Places rows. */
        /* Even a disconnect owns the sidebar: a reply from the machine that
           just went away must not repopulate Places after it was cleared. A
           usable connection replaces that sweep as part of the one browser
           refresh operation. */
        if canBrowse { refreshBrowser() } else { cancelLocationDiscovery() }
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

    /// The human-facing refresh: both surfaces that describe the guest's disk.
    /// Internal mutation events use `refresh()` because they only invalidate
    /// the open listing; a toolbar click or a new connection revalidates the
    /// Places sidebar as well.
    func refreshBrowser() {
        cancelLocationDiscovery()
        load(path: path, resetRows: true) { [weak self] result in
            guard let self else { return }
            /* A listing normally names the share root, so let that one reply
               serve both the table and Places. Older guests may omit it; in
               that case discovery performs its own root probe. */
            if case .success(let listing) = result,
               let root = listing.root, !root.isEmpty {
                self.shareRoot = root
                self.discoverLocations(knownRoot: true)
            } else {
                self.discoverLocations()
            }
        }
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

    /// The most rows one folder will accumulate.
    ///
    /// Not a display limit — it is a bound on what a single reply chain
    /// may spend of this process's memory when a folder is pathological
    /// or a guest's cursor misbehaves. A classic Mac folder is nowhere
    /// near this; a System Folder is a few hundred. Reaching it is
    /// reported, never silent, because a listing that quietly stops is
    /// the defect this whole change exists to fix.
    static let rowCeiling = 4000

    private func load(
        path: String, resetRows: Bool, cursor: Int? = nil,
        firstPage: ((Result<FileListing, GuestListener.FileFailure>) -> Void)?
            = nil
    ) {
        guard canBrowse else { return }
        if resetRows {
            listingGeneration += 1
            rows = []
            pageCursor = nil
            selection = nil
        }
        let generation = listingGeneration
        isLoading = true
        lastError = nil
        lastNotice = nil
        listener.listFiles(path: path, cursor: cursor) { [weak self] result in
            guard let self else { return }
            // A newer full refresh owns this same path now. Its page is the
            // only one allowed to append; accepting both duplicates every
            // visible row without changing anything on the guest.
            guard generation == self.listingGeneration else { return }
            self.isLoading = false
            switch result {
            case .success(let listing):
                // A late page from a folder we already left is dropped.
                guard listing.path == self.path else { return }
                let prefix = listing.path.isEmpty ? "" : listing.path + ":"
                self.rows += listing.entries.map {
                    FileRow(entry: $0, path: prefix + $0.name)
                }
                if let root = listing.root, !root.isEmpty {
                    self.shareRoot = root
                }
                firstPage?(.success(listing))

                /* THE GUEST PAGES AT 16 PER FRAME, because a control
                   frame caps at 4 KB — so one reply is one PAGE, never
                   one folder. Until 2026-08-01 nothing asked for the
                   rest: `loadMoreIfNeeded` existed and no view called
                   it, so a browser showed the first sixteen entries of
                   every folder and gave no sign there were more. A file
                   browser that silently truncates is worse than one that
                   fails, because the person believes what they see.

                   So the pages are followed here rather than left to a
                   view's scroll position: what is on screen is a whole
                   folder or an explicit reason it is not. */
                guard listing.more, let next = listing.cursor else {
                    self.pageCursor = nil
                    return
                }

                /* A cursor that does not advance would spin this forever
                   against a guest that answers `more` without moving.
                   Stop and say so: a wire is allowed to be wrong, and
                   this side is not allowed to hang because of it. */
                if let asked = cursor, next <= asked {
                    self.pageCursor = nil
                    /* The machine that repeated itself is the one being
                       BROWSED, not this one — this side only asked. */
                    self.lastNotice = MachineNaming.startingSentence(
                        self.connection.peerLabel)
                        + " repeated the same listing position, so the "
                        + "folder is shown as far as it got "
                        + "(\(self.rows.count) items)."
                    return
                }
                if self.rows.count >= Self.rowCeiling {
                    self.pageCursor = nil
                    self.lastNotice = "Showing the first \(self.rows.count) "
                        + "items; this folder has more than this browser "
                        + "will hold at once."
                    return
                }

                self.pageCursor = next
                self.load(path: listing.path, resetRows: false, cursor: next)
            case .failure(let failure):
                self.lastError = failure.message
                self.pageCursor = nil
                firstPage?(.failure(failure))
            }
        }
    }

    // MARK: - Places worth one click

    /// The sidebar, as it is drawn: this connection's discoveries minus
    /// what a person threw out, plus what they pinned, in their order.
    @Published private(set) var locations: [FileLocation] = []
    @Published private(set) var isDiscoveringLocations = false

    /// This run's discoveries. Never persisted: a folder that was there
    /// last week and is not there today must not survive in a file.
    private var discoveredLocations: [FileLocation] = []
    private var storedLocations = FileLocationsStore.Stored()
    private let locationsStore: FileLocationsStore
    /// The connection already swept, so showing the page twice is not two
    /// sweeps. Guest keys are session-scoped, and retaining every old key
    /// would grow forever; an automatic connection refresh means only the
    /// current key can suppress an on-appear sweep.
    private var sweptMachine: GuestKey?
    /// Owns an in-flight Places sweep. A guest switch or explicit refresh may
    /// start a newer sweep before the old connection answers; only the newest
    /// one may publish locations.
    private var locationDiscoveryGeneration = 0

    private var currentMachine: GuestID? { connection.key?.machine }

    /// One sweep per connection, on the page's first appearance. A sweep
    /// is a handful of small requests, but it is a handful more than a
    /// person asked for, so it never repeats itself unprompted.
    func discoverLocationsIfNeeded() {
        guard let key = connection.key, sweptMachine != key else {
            return
        }
        discoverLocations()
    }

    /// Finds what of the classic furniture is actually reachable inside
    /// this machine's share, and omits the rest in silence.
    ///
    /// Two routes, in this order, because they are not equally good:
    /// `software.list` first, whose four System Folder domains are
    /// `FindFolder`-resolved on the guest and therefore carry that
    /// machine's own names; then plain probing, which is a guess that
    /// either lists or does not.
    func discoverLocations() {
        discoverLocations(knownRoot: false)
    }

    private func discoverLocations(knownRoot: Bool) {
        guard canBrowse, !isDiscoveringLocations else { return }
        sweptMachine = connection.key
        locationDiscoveryGeneration += 1
        let generation = locationDiscoveryGeneration
        isDiscoveringLocations = true
        if knownRoot {
            sweepFolderManager(index: 0, found: [], systemFolder: nil,
                               generation: generation)
            return
        }
        /* The share root comes FIRST, and not for the sidebar's top row:
           `software.list` answers in whole HFS paths, and turning one of
           those into something this browser can ask for needs to know
           what to subtract. Sweeping before the root was known threw away
           every Folder Manager answer for want of a prefix. */
        listener.listFiles(path: "") { [weak self] result in
            guard let self,
                  generation == self.locationDiscoveryGeneration else { return }
            switch result {
            case .success(let listing):
                if let root = listing.root, !root.isEmpty {
                    self.shareRoot = root
                }
                self.sweepFolderManager(index: 0, found: [],
                                        systemFolder: nil,
                                        generation: generation)
            case .failure(let failure):
                self.finishDiscovery(abandoned: failure.message,
                                     generation: generation)
            }
        }
    }

    /// Route one: ask for a page of each FindFolder-backed domain and
    /// read the folder out of where its entries live.
    private func sweepFolderManager(index: Int, found: [FileLocation],
                                    systemFolder: String?, generation: Int) {
        guard index < ClassicLocations.folderManagerDomains.count else {
            sweepSystemFolder(found: found, systemFolder: systemFolder,
                              generation: generation)
            return
        }
        let domain = ClassicLocations.folderManagerDomains[index]
        listener.listSoftware(domain: domain.domain, cursor: 1) {
            [weak self] result in
            guard let self,
                  generation == self.locationDiscoveryGeneration else { return }
            var found = found
            var systemFolder = systemFolder
            switch result {
            case .failure(let failure):
                guard !FileLocationResolver.isFatal(failure.code) else {
                    self.finishDiscovery(abandoned: failure.message,
                                         generation: generation)
                    return
                }
                // A guest too old for this domain simply does not
                // contribute; the probe route still can.
                break
            case .success(let listing):
                if let path = FileLocationResolver.folder(
                    fromSoftware: listing.entries, shareRoot: self.shareRoot) {
                    found.append(FileLocation(
                        path: path,
                        name: ClassicLocations.leafName(of: path),
                        symbol: domain.symbol, origin: .folderManager))
                    /* Every one of these four lives directly inside the
                       System Folder, so any of them names it — and names
                       it as that machine spells it, which is the whole
                       reason this route exists. */
                    if systemFolder == nil {
                        systemFolder = FileLocationResolver.parent(of: path)
                            ?? ""
                    }
                }
            }
            self.sweepFolderManager(index: index + 1, found: found,
                                    systemFolder: systemFolder,
                                    generation: generation)
        }
    }

    /// The System Folder itself: known already if a domain answered,
    /// otherwise the one thing left to guess at before its children can
    /// be probed.
    private func sweepSystemFolder(found: [FileLocation],
                                   systemFolder: String?, generation: Int) {
        if let systemFolder, !systemFolder.isEmpty {
            var found = found
            found.insert(FileLocation(
                path: systemFolder,
                name: ClassicLocations.leafName(of: systemFolder),
                symbol: ClassicLocations.systemFolder.symbol,
                origin: .folderManager), at: 0)
            sweepCandidates(index: 0, found: found,
                            systemFolder: systemFolder,
                            generation: generation)
            return
        }
        probe(ClassicLocations.systemFolder.names, at: 0, under: "",
              generation: generation) {
            [weak self] resolved in
            guard let self else { return }
            guard let resolved else {
                self.sweepCandidates(index: 0, found: found,
                                     systemFolder: nil,
                                     generation: generation)
                return
            }
            var found = found
            found.insert(FileLocation(
                path: resolved,
                name: ClassicLocations.leafName(of: resolved),
                symbol: ClassicLocations.systemFolder.symbol,
                origin: .probed), at: 0)
            self.sweepCandidates(index: 0, found: found,
                                 systemFolder: resolved,
                                 generation: generation)
        }
    }

    /// Route two: guess a name, ask for its listing, keep it if it comes
    /// back. A candidate whose every name refuses is omitted — the rule
    /// the whole sidebar rests on.
    private func sweepCandidates(index: Int, found: [FileLocation],
                                 systemFolder: String?, generation: Int) {
        guard index < ClassicLocations.candidates.count else {
            finishDiscovery(found: found, generation: generation)
            return
        }
        let candidate = ClassicLocations.candidates[index]
        /* A child of the System Folder cannot be probed when we never
           found the System Folder: joining onto nothing would probe the
           share root's own children under the same names, which is a
           different folder that may well exist. */
        guard let base = candidate.insideSystemFolder ? systemFolder : ""
        else {
            sweepCandidates(index: index + 1, found: found,
                            systemFolder: systemFolder,
                            generation: generation)
            return
        }
        probe(candidate.names, at: 0, under: base,
              generation: generation) { [weak self] resolved in
            guard let self else { return }
            var found = found
            if let resolved, !found.contains(where: { $0.path == resolved }) {
                found.append(FileLocation(
                    path: resolved, name: candidate.name,
                    symbol: candidate.symbol, origin: .probed))
            }
            self.sweepCandidates(index: index + 1, found: found,
                                 systemFolder: systemFolder,
                                 generation: generation)
        }
    }

    /// Tries names in order under one folder, answering with the first
    /// that lists. One `file.list` per name — bounded by the candidate
    /// table, and every one of them a page of at most sixteen entries.
    private func probe(_ names: [String], at index: Int, under base: String,
                       generation: Int,
                       completion: @escaping (String?) -> Void) {
        guard index < names.count else {
            completion(nil)
            return
        }
        let path = FileLocationResolver.join(base, names[index])
        listener.listFiles(path: path) { [weak self] result in
            guard let self,
                  generation == self.locationDiscoveryGeneration else { return }
            switch result {
            case .success(let listing):
                if let root = listing.root, !root.isEmpty {
                    self.shareRoot = root
                }
                completion(path)
            case .failure(let failure):
                guard !FileLocationResolver.isFatal(failure.code) else {
                    self.finishDiscovery(abandoned: failure.message,
                                         generation: generation)
                    return
                }
                self.probe(names, at: index + 1, under: base,
                           generation: generation,
                           completion: completion)
            }
        }
    }

    private func finishDiscovery(found: [FileLocation], generation: Int) {
        guard generation == locationDiscoveryGeneration else { return }
        isDiscoveringLocations = false
        var found = found
        found.insert(ClassicLocations.rootLocation(shareRoot: shareRoot),
                     at: 0)
        discoveredLocations = found
        republishLocations()
    }

    /// The wire went away mid-sweep. Everything not yet asked about is
    /// unknown, not absent — so nothing is recorded, and the machine is
    /// left un-swept so a reconnection tries again.
    private func finishDiscovery(abandoned reason: String, generation: Int) {
        guard generation == locationDiscoveryGeneration else { return }
        isDiscoveringLocations = false
        if sweptMachine == connection.key { sweptMachine = nil }
        lastNotice = "Could not finish looking for folders on "
            + "\(connection.peerLabel): \(reason)"
    }

    private func republishLocations() {
        locations = FileLocationsStore.merge(discovered: discoveredLocations,
                                             stored: storedLocations)
    }

    private func cancelLocationDiscovery() {
        locationDiscoveryGeneration += 1
        isDiscoveringLocations = false
    }

    private func reloadStoredLocations() {
        storedLocations = locationsStore.load(for: currentMachine)
        republishLocations()
    }

    private func saveStoredLocations() {
        locationsStore.save(storedLocations, for: currentMachine)
        republishLocations()
    }

    /// Goes to a location. The breadcrumb is the path, so the bar says
    /// where you landed exactly as it does after a double-click.
    func go(to location: FileLocation) {
        guard canBrowse else { return }
        breadcrumb = location.path.isEmpty
            ? [] : location.path.components(separatedBy: ":")
        load(path: path, resetRows: true)
    }

    /// What a person may drag into the sidebar: a folder this browser can
    /// currently SEE is a folder. Nil is a refusal, and refusing is the
    /// point — a path alone is not evidence of anything.
    func pinnableName(for path: String) -> String? {
        guard !path.isEmpty else { return nil }   // the root is always there
        if path == self.path { return ClassicLocations.leafName(of: path) }
        guard let row = rows.first(where: { $0.path == path }), row.isFolder
        else { return nil }
        return row.name
    }

    @discardableResult
    func pinLocation(path: String) -> Bool {
        guard let name = pinnableName(for: path) else { return false }
        guard !locations.contains(where: { $0.path == path }) else {
            return true                    // already there; a no-op, not a fault
        }
        storedLocations.pinned.append(FileLocation(
            path: path, name: name, symbol: "folder", origin: .pinned))
        // A location thrown out and then dragged back is no longer thrown
        // out, or the pin would vanish on the next sweep.
        storedLocations.hidden.removeAll { $0 == path }
        saveStoredLocations()
        return true
    }

    /// Takes a row out. A pinned one is forgotten; a discovered one is
    /// remembered as unwanted, because the next sweep would otherwise put
    /// it straight back.
    func removeLocation(_ location: FileLocation) {
        guard location.origin != .root else { return }
        storedLocations.pinned.removeAll { $0.path == location.path }
        if !location.isPinned,
           !storedLocations.hidden.contains(location.path) {
            storedLocations.hidden.append(location.path)
        }
        storedLocations.order.removeAll { $0 == location.path }
        saveStoredLocations()
    }

    func moveLocations(from source: IndexSet, to destination: Int) {
        var paths = locations.map(\.path)
        paths.move(fromOffsets: source, toOffset: destination)
        storedLocations.order = paths
        saveStoredLocations()
    }

    /// The way back for a sidebar someone emptied. Pins are theirs and
    /// stay; what this undoes is the throwing-out and the rearranging.
    func restoreRemovedLocations() {
        storedLocations.hidden = []
        storedLocations.order = []
        saveStoredLocations()
    }

    // MARK: - Download

    /// Fetches one file to this Mac.
    ///
    /// `into` is where it lands, defaulting to the downloads folder. The
    /// staging file goes to the same place on purpose: it is the same
    /// volume as the destination, so finishing a transfer is a rename
    /// rather than a copy of every byte a second time.
    func download(_ row: FileRow, container: String? = nil,
                  into directory: URL? = nil, thenOpen: Bool = false) {
        guard !row.isFolder else { return }
        /* One lane, and a click that quietly does nothing is the defect
           being reported elsewhere in this very feature. Say so. */
        guard transfer == nil else {
            lastError = FilesError.busy.errorDescription
            return
        }
        let destination = directory ?? downloadDirectory
        lastError = nil
        lastNotice = nil
        transfer = TransferState(name: row.name, direction: .incoming,
                                 received: 0, expected: row.sizeBytes,
                                 opensWhenDone: thenOpen)
        listener.getFile(path: row.path, container: container,
                         stagingDirectory: destination) {
            [weak self] result in
            guard let self else { return }
            self.transfer = nil
            switch result {
            case .success(let file):
                let landed = self.write(file, into: destination)
                /* Only a file that actually arrived is opened. A
                   cancelled or failed transfer arrives here as a
                   failure, so a stopped download never launches
                   anything — which is the whole point of being able to
                   stop it. */
                if thenOpen, let landed {
                    self.openLanded(landed)
                }
            case .failure(let failure):
                self.lastError = failure.message
            }
        }
    }

    /// What a double-click does: bring the file to the folder this Mac
    /// shares, then open it with whatever handles it here.
    ///
    /// **Why the shared folder and not the downloads folder.** It is the
    /// one place both machines already agree on — the file is then in
    /// reach of the guest as well, which is what makes "open it, look at
    /// it, send it back" a round trip rather than two unrelated copies.
    /// It is also an existing notion of a directory (`listener.share
    /// .root`, the same one "Reveal Shared Folder" opens), so this adds
    /// no second idea of where things go.
    ///
    /// A double-click on a folder navigates, as it always did. Nothing
    /// about a folder is downloadable, and the breadcrumb is what says
    /// where the navigation landed.
    func openOnThisMac(_ row: FileRow) {
        if row.isFolder {
            open(row)
        } else {
            download(row, into: shareDirectory, thenOpen: true)
        }
    }

    /// The moment after the bytes land, and the three rungs it climbs
    /// down.
    ///
    /// **A type this Mac cannot open is the ordinary case, not the edge
    /// one.** Classic files carry a type and creator rather than an
    /// extension, so most of what comes off that volume — a resource-only
    /// document, an `APPL` for a processor this Mac has not run in twenty
    /// years — lands as `something.bin` with nothing here claiming it.
    /// `FileConverter.outputName` is where that name is decided, and it
    /// deliberately does not invent an extension it cannot justify: a
    /// `.bin` that is honestly unidentified beats a `.txt` that is
    /// wrong.
    ///
    /// So the chain is: open it; failing that ASK which application to
    /// use, which is the answer a person actually has and this Mac does
    /// not; failing that (they cancelled, or the application refused it)
    /// reveal it in the Finder and say so. The transfer succeeded at
    /// every rung — none of this is an error. What is refused is the
    /// silent version, where a double-click ends in nothing at all.
    private func openLanded(_ url: URL) {
        if systemOpen.open(url) { return }
        guard let application = systemOpen.chooseApplication(url) else {
            revealUnopened(url)
            return
        }
        let name = application.deletingPathExtension().lastPathComponent
        systemOpen.openWith(url, application) { [weak self] opened in
            guard let self else { return }
            guard opened else {
                self.systemOpen.reveal(url)
                self.lastNotice = "\(name) would not open "
                    + "\(url.lastPathComponent). It is in "
                    + "\(self.shareDirectory.lastPathComponent)."
                return
            }
            self.lastNotice = "\(url.lastPathComponent) opened with \(name)."
        }
    }

    private func revealUnopened(_ url: URL) {
        systemOpen.reveal(url)
        lastNotice = "\(url.lastPathComponent) is in "
            + "\(shareDirectory.lastPathComponent) — \(MachineNaming.thisMac) "
            + "has nothing that opens it."
    }

    /// Opening, choosing and revealing, as one seam. The real thing is
    /// the Finder and a panel; a test watches the decision instead of
    /// launching an application on somebody's Mac or putting a modal
    /// dialog in front of a test runner.
    ///
    /// The two new members carry defaults that do NOTHING, so a test that
    /// constructs this with `open:`/`reveal:` alone gets the old
    /// behaviour rather than a chooser it never asked for.
    struct SystemOpen {
        var open: (URL) -> Bool
        var reveal: (URL) -> Void
        /// The native "choose an application" flow. Nil is a cancel, and
        /// a cancel is a decision — it falls through to reveal rather
        /// than being retried.
        var chooseApplication: (URL) -> URL? = { _ in nil }
        /// Open a file with a named application. Launching is genuinely
        /// asynchronous — the application has to start before it can
        /// refuse the document — so the answer arrives later, on the main
        /// actor, where the notice it produces is read.
        var openWith: (URL, URL, @escaping @MainActor (Bool) -> Void)
            -> Void = { _, _, done in Task { @MainActor in done(false) } }

        static let workspace = SystemOpen(
            open: { NSWorkspace.shared.open($0) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            chooseApplication: { url in
                /* NSWorkspace has no public "Open With…" panel, so this is
                   the panel the Finder's own Other… item shows: pick an
                   application bundle. Scoped to /Applications the way that
                   dialog is, but not confined to it. */
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.prompt = "Open"
                panel.message = "Choose an application to open "
                    + "“\(url.lastPathComponent)”."
                return panel.runModal() == .OK ? panel.url : nil
            },
            openWith: { file, application, done in
                NSWorkspace.shared.open(
                    [file], withApplicationAt: application,
                    configuration: NSWorkspace.OpenConfiguration()) {
                    _, error in
                    Task { @MainActor in done(error == nil) }
                }
            })
    }

    var systemOpen = SystemOpen.workspace

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
            case .failure(let failure)
                where failure.code == "exists" && !overwrite:
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

    /// Pulls an item for a drag to the Finder. AppKit may redeem every
    /// promise in a multi-row drag concurrently, while the guest has one
    /// transfer lane. The exporter serializes those requests and expands
    /// folders over the existing paged listing contract.
    func fetchForPromise(_ row: FileRow, to destination: URL,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        promiseExporter.enqueue(row, to: destination, completion: completion)
    }

    private func fetchOneForPromise(
        _ row: FileRow,
        to destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard transfer == nil else {
            completion(.failure(FilesError.busy))
            return
        }
        transfer = TransferState(name: row.name, direction: .incoming,
                                 received: 0, expected: row.sizeBytes,
                                 index: nil, total: nil)
        listener.getFile(
            path: row.path, container: nil,
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

    /// Writes a delivered file, into the downloads folder unless told
    /// otherwise.
    ///
    /// A name already taken is never overwritten, it is bumped. That
    /// mattered when everything landed in Downloads and it matters more
    /// now that a double-click lands in the SHARED folder: overwriting
    /// there would silently replace something the other machine can also
    /// see, which is a destructive change this browser asks about
    /// everywhere else.
    @discardableResult
    func write(_ file: GuestListener.FileDelivery,
               into directory: URL? = nil) -> URL? {
        let folder = directory ?? downloadDirectory
        let outputName = FileConverter.outputName(
            name: file.name, container: file.container)
        var url = folder.appendingPathComponent(sanitized(outputName))
        var bump = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (outputName as NSString).deletingPathExtension
            let ext = (outputName as NSString).pathExtension
            let name = ext.isEmpty ? "\(base) (\(bump))"
                                   : "\(base) (\(bump)).\(ext)"
            url = folder.appendingPathComponent(sanitized(name))
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
        LocalFileName.sanitized(name)
    }
}
