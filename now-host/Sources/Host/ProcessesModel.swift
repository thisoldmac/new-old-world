import Foundation
import NOWAgentIntegration

/// The connected Mac's running processes, pulled over the wire.
///
/// The consume half of the process.* family made visible: one `refresh`
/// asks `process.list` and pages the whole table in, because a process
/// list is small and a human wants all of it, not a scroll that fetches.
/// It shows what the guest serves and nothing it does not — the read is
/// honest about being a snapshot from the moment it was asked.
@MainActor
final class ProcessesModel: ObservableObject, GuestScopedModel {
    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }
    @Published private(set) var rows: [ProcessEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// When the shown list was fetched, so the header can say how fresh
    /// it is — a process list goes stale the instant it is read.
    @Published private(set) var fetchedAt: Date?
    @Published var selection: ProcessEntry.ID?
    /// A drive verb (front / quit / screenshot) is waiting on the guest.
    /// Buttons disable while it is, so one click cannot stack another.
    @Published private(set) var actionInFlight = false

    /// "Screenshot App" hands the target's PSN here; the host routes it to
    /// the Screenshots module, which asks the guest for a window-cropped
    /// capture. Kept as a hook so the model does not reach across modules.
    var onScreenshotApp: ((Int, Int) -> Void)?

    private let listener: GuestListener
    /// What the machines on the wire have said they can do. Shared with every
    /// other page that gates a control, injectable so a test gets its own.
    let capabilities: GuestCapabilityRecord
    /// Guards against a slow page landing after the human hit Refresh:
    /// each refresh takes a token, and only the current token may append.
    private var loadToken = 0

    init(listener: GuestListener,
         capabilities: GuestCapabilityRecord = .shared) {
        self.listener = listener
        self.capabilities = capabilities
    }

    var canBrowse: Bool { connection.canCapture }

    /// The row a person has selected, if it is still in the list.
    var selectedEntry: ProcessEntry? {
        rows.first { $0.id == selection }
    }

    /// **Whether bringing this process forward means anything, on this Mac.**
    ///
    /// The kind is the guest's own classification, not a type code read on
    /// this side: a faceless process has no windows and no menu bar, so there
    /// is nothing to bring forward whichever Mac is attached. `isDrivable` is
    /// a third fact and stays where it is — it says this ROW arrived without a
    /// PSN, which is about the listing rather than the process or the wire,
    /// and is not restated here.
    func bringToFrontGate(_ entry: ProcessEntry)
        -> GuestCapabilityGate.Decision {
        GuestCapabilityGate.decide(
            BringToFrontProjection.self, performing: .bringToFront,
            on: entry.itemKind, named: entry.name,
            in: capabilities.evidence(for: connection, listener: listener))
    }

    /// The sentence a dark Bring to Front button owes the reader, and nil
    /// while it works — including for the merely unproven case, which stays
    /// enabled and does not get to nag. Nil with nothing selected: a control
    /// dark for want of a selection is explained by the empty selection.
    ///
    /// Takes the row rather than reading `selectedEntry` itself, so the answer
    /// is a function of what the page is showing and can be asked without a
    /// wire, a listing, or a Mac.
    func bringToFrontNote(for entry: ProcessEntry?) -> String? {
        guard let entry else { return nil }
        let decision = bringToFrontGate(entry)
        guard decision.deservesAVisibleReason else { return nil }
        return decision.explanation
    }

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

    /// The process table belongs to one connection. When the Mac goes
    /// away — most sharply on a redeploy, where a fresh guest reconnects
    /// with a new set of PSNs — the rows we still hold name processes that
    /// no longer exist, and driving one by its stale PSN fails closed. So
    /// drop the table the instant the connection does: a stale list never
    /// lingers into the next one, and because the rows are now empty the
    /// reconnect (or a reopened pane) reads afresh on its own, with no
    /// manual Refresh. This only clears — the re-read is driven from the
    /// view, past the state change the listener has yet to see.
    ///
    /// **The one model here that parks nothing.** Every other module caches
    /// something worth keeping per machine; a process table is worth
    /// keeping for about as long as it takes to read it. It goes stale on
    /// its own machine in seconds — that is why the header says when it was
    /// fetched — so parking it would buy a page of rows that are wrong in
    /// the same way the shared-across-guests version was wrong, only
    /// quieter. Switching guests therefore clears it exactly as
    /// disconnecting does, and the view re-reads.
    private func connectionChanged(from old: GuestConnectionState) {
        let switched = connection.key != nil && connection.key != old.key
        guard connection != old, !connection.canCapture || switched else {
            return
        }
        rows = []
        selection = nil
        fetchedAt = nil
        lastError = nil
        // A page still in flight from the old connection must not append.
        loadToken += 1
        isLoading = false
    }

    func refresh() {
        guard canBrowse else { return }
        loadToken += 1
        rows = []
        // Selection is kept, not cleared: a refresh after driving a process
        // should leave the same row picked if it is still running, and drop
        // the highlight by itself if it has gone.
        lastError = nil
        load(cursor: nil, token: loadToken)
    }

    /// Bring the selected process to the front of the guest's screen.
    func bringToFront(_ entry: ProcessEntry) { drive(entry, .front) }

    /// Ask the selected process to quit — a request it may decline.
    func askToQuit(_ entry: ProcessEntry) { drive(entry, .quit) }

    /// Capture just this process's window. The whole sequence — front it,
    /// let it repaint, crop to its window, deliver — happens on the guest
    /// (process.shot); here we only route the target to the Screenshots
    /// module, where the image lands.
    func screenshotApp(_ entry: ProcessEntry) {
        guard let high = entry.psnHigh, let low = entry.psnLow else { return }
        lastError = nil
        onScreenshotApp?(high, low)
    }

    private func drive(_ entry: ProcessEntry,
                       _ verb: GuestListener.ProcessVerb) {
        guard let high = entry.psnHigh, let low = entry.psnLow,
              !actionInFlight else { return }
        actionInFlight = true
        lastError = nil
        listener.driveProcess(psnHigh: high, psnLow: low,
                              verb: verb) { [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            switch result {
            case .success(let r) where r.ok:
                // Front changed, or a quit was sent: re-read so the front
                // flag moves and a process that took the hint drops out.
                self.refresh()
            case .success(let r):
                self.lastError = r.reason ?? "The Mac declined"
            case .failure(let f):
                self.lastError = f.message
            }
        }
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
