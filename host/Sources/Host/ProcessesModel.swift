import Foundation

/// The connected Mac's running processes, pulled over the wire.
///
/// The consume half of the process.* family made visible: one `refresh`
/// asks `process.list` and pages the whole table in, because a process
/// list is small and a human wants all of it, not a scroll that fetches.
/// It shows what the guest serves and nothing it does not — the read is
/// honest about being a snapshot from the moment it was asked.
@MainActor
final class ProcessesModel: ObservableObject {
    @Published var connection: GuestConnectionState = .disconnected
    @Published private(set) var rows: [ProcessEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// When the shown list was fetched, so the header can say how fresh
    /// it is — a process list goes stale the instant it is read.
    @Published private(set) var fetchedAt: Date?
    @Published var selection: ProcessEntry.ID?

    private let listener: GuestListener
    /// Guards against a slow page landing after the human hit Refresh:
    /// each refresh takes a token, and only the current token may append.
    private var loadToken = 0

    init(listener: GuestListener) {
        self.listener = listener
    }

    var canBrowse: Bool { connection.canCapture }

    /// Two buckets a person reads at a glance: what has a face, and what
    /// runs behind everything. The Finder sits with the applications —
    /// it is one, and hiding it under "background" would read as wrong to
    /// anyone who knows the machine.
    enum Group: Int, CaseIterable {
        case applications, background

        var title: String {
            switch self {
            case .applications: return "Applications"
            case .background: return "Background"
            }
        }
    }

    static func group(of entry: ProcessEntry) -> Group {
        entry.kind == "background" ? .background : .applications
    }

    /// Rows for one group, the front process first, then by name — the
    /// same order the guest's own Processes page settled on.
    func rows(in group: Group) -> [ProcessEntry] {
        rows.filter { Self.group(of: $0) == group }
            .sorted { lhs, rhs in
                if (lhs.front ?? false) != (rhs.front ?? false) {
                    return lhs.front ?? false
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    func refresh() {
        guard canBrowse else { return }
        loadToken += 1
        rows = []
        selection = nil
        lastError = nil
        load(cursor: nil, token: loadToken)
    }

    /// One page, chaining straight into the next while `more` holds, so a
    /// refresh settles on the whole table rather than a first page.
    private func load(cursor: Int?, token: Int) {
        isLoading = true
        listener.listProcesses(cursor: cursor) { [weak self] result in
            guard let self, token == self.loadToken else { return }
            switch result {
            case .success(let listing):
                self.rows += listing.processes
                if listing.more, let next = listing.cursor {
                    self.load(cursor: next, token: token)
                } else {
                    self.isLoading = false
                    self.fetchedAt = Date()
                }
            case .failure(let failure):
                self.isLoading = false
                self.lastError = failure.message
            }
        }
    }
}

extension ProcessEntry {
    /// A face-forward kind label. The wire word is honest but terse;
    /// this is what a person reads in the row.
    var kindLabel: String {
        switch kind {
        case "finder": return "Finder"
        case "background": return "Background"
        default: return "Application"
        }
    }

    /// The two 4CCs as one caption, when the server sent them. The host's
    /// own list (the mirror direction) has neither, so this is empty
    /// there rather than a pair of blanks.
    var signatureLabel: String? {
        let parts = [code, creator].compactMap { code -> String? in
            guard let code, !code.isEmpty else { return nil }
            return code
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Partition size, in the unit that keeps the number legible.
    var sizeLabel: String? {
        guard let kb = sizeKB, kb > 0 else { return nil }
        if kb < 1024 { return "\(kb) KB" }
        return String(format: "%.1f MB", Double(kb) / 1024.0)
    }
}
