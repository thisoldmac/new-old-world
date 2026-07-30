import Foundation

/// The connected Mac's installed software, pulled over the wire.
///
/// The consume half of software.list: one `refresh` pages a whole
/// domain in (cursor-chained, like the process table), because a person
/// wants the inventory, not a scroll that fetches. Search filters the
/// rows already here — never the guest's disk — and Launch acts by the
/// entry's full path, the listing's launch key, so the guest's
/// name-ambiguity refusal can never fire from this page.
@MainActor
final class SoftwareModel: ObservableObject, GuestScopedModel {
    /// What one machine's inventory is, parked while another is driven.
    ///
    /// This one is CACHED rather than discarded because of what it costs
    /// the other machine to produce: rebuilding the Applications domain is
    /// a ~4 s sweep of the guest's disk, done by a cooperatively-scheduled
    /// classic Mac that is doing nothing else while it runs. Throwing that
    /// away because somebody glanced at the other Mac and came back would
    /// make the picker expensive to use, which is a good way to make a
    /// two-machine feature feel like a mistake.
    ///
    /// The domain travels with it: "which domain am I looking at" is a
    /// question about the machine in front of you, and returning to a Mac
    /// on Control Panels having left it on Control Panels is the whole
    /// point of parking anything.
    struct Snapshot {
        var rows: [SoftwareEntry] = []
        var domain: Domain = .apps
        var note: String?
        var fetchedAt: Date?
        var selection: SoftwareEntry.ID?
        var search = ""
    }

    private let cache = GuestStateCache<Snapshot>()

    /// The declared domains, in the guest page's order. The keys are the
    /// contract's; the labels are what a person reads.
    enum Domain: String, CaseIterable, Identifiable {
        case apps, extensions, cdevs, startup, apple

        var id: String { rawValue }
        var label: String {
            switch self {
            case .apps: return "Applications"
            case .extensions: return "Extensions"
            case .cdevs: return "Control Panels"
            case .startup: return "Startup Items"
            case .apple: return "Apple Menu Items"
            }
        }
    }

    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }
    @Published var domain: Domain = .apps {
        // Restoring a parked domain must not re-ask the wire: the rows for
        // it are being restored in the same breath.
        didSet { if domain != oldValue, !isRestoring { refresh() } }
    }
    private var isRestoring = false
    @Published private(set) var rows: [SoftwareEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// The listing's honest edges — "no such domain", a truncated
    /// inventory — surfaced verbatim, never swallowed.
    @Published private(set) var note: String?
    @Published private(set) var fetchedAt: Date?
    @Published var selection: SoftwareEntry.ID?
    @Published var search = ""
    /// A launch is waiting on the guest; the button disables so one
    /// click cannot stack another.
    @Published private(set) var actionInFlight = false
    /// What the last launch said — "launched SimpleText", or the
    /// guest's refusal, verbatim.
    @Published private(set) var lastAction: String?
    /// The last sweep-cost measurement, in the guest's own rows. Not parked
    /// with the inventory: it is a measurement of one moment on one disk, and
    /// showing yesterday's timings beside today's Refresh button would read
    /// as a current fact about the machine.
    @Published private(set) var sweepCost: [SweepRow]?

    private let listener: GuestListener
    /// Guards against a slow page landing after a refresh or a domain
    /// switch: each load takes a token, only the current token appends.
    private var loadToken = 0

    init(listener: GuestListener) {
        self.listener = listener
    }

    var canBrowse: Bool { connection.canCapture }

    var selectedEntry: SoftwareEntry? {
        rows.first { $0.id == selection }
    }

    /// The rows a person sees: the wire's inventory narrowed by the
    /// search field, sorted by name. Filtering is client-side over
    /// what is already here — the guest's disk is never re-asked per
    /// keystroke (the guest page's rule, kept on this side too).
    var visibleRows: [SoftwareEntry] {
        let filtered = search.isEmpty
            ? rows
            : rows.filter { Self.matches($0, query: search) }
        return filtered.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    static func matches(_ entry: SoftwareEntry, query: String) -> Bool {
        entry.name.range(of: query, options: .caseInsensitive) != nil
    }

    /// The inventory belongs to one connection; a redeployed guest has a
    /// different disk state. Drop the table the instant the connection
    /// does — the reconnect re-reads on its own from the view.
    ///
    /// A SWITCH is the other case, and it is not a drop: the outgoing
    /// machine's inventory is parked under its key and the incoming
    /// machine's is restored, so neither is ever shown under the other's
    /// name and neither has to be swept again.
    private func connectionChanged(from old: GuestConnectionState) {
        guard connection != old else { return }
        switch cache.focus(connection.key, parking: snapshot()) {
        case .switched(let restored):
            restore(restored ?? Snapshot())
        case .unchanged:
            guard !connection.canCapture else { return }
            rows = []
            fetchedAt = nil
            lastError = nil
            note = nil
            lastAction = nil
            sweepCost = nil
            loadToken += 1
            isLoading = false
        }
    }

    /// A machine that disconnects loses its parked inventory, for exactly
    /// the reason the live one is dropped above: the next time this Mac
    /// dials in it may have been redeployed, and an inventory taken before
    /// that is a page of files that are no longer there. This is the only
    /// model here that forgets — the others cache a record of what a person
    /// did or what the hardware is, neither of which a reconnect invalidates.
    func guestLeft(_ key: GuestKey) {
        cache.forget(key)
    }

    private func snapshot() -> Snapshot {
        Snapshot(rows: rows, domain: domain, note: note,
                 fetchedAt: fetchedAt, selection: selection, search: search)
    }

    private func restore(_ snapshot: Snapshot) {
        // A page still in flight belongs to the machine we just left.
        loadToken += 1
        isLoading = false
        actionInFlight = false
        lastError = nil
        lastAction = nil
        // A timing measured on the machine we just left is not a fact about
        // the one we just arrived at.
        sweepCost = nil
        isRestoring = true
        domain = snapshot.domain
        isRestoring = false
        rows = snapshot.rows
        note = snapshot.note
        fetchedAt = snapshot.fetchedAt
        selection = snapshot.selection
        search = snapshot.search
    }

    func refresh() {
        guard canBrowse else { return }
        loadToken += 1
        rows = []
        note = nil
        lastError = nil
        load(cursor: nil, token: loadToken)
    }

    /// Launch the selected entry on the guest, by its full path — the
    /// listing's launch key. The guest replies with what launched or
    /// why not, and either way the words shown are the guest's own.
    func launch(_ entry: SoftwareEntry) {
        guard entry.isLaunchable, !actionInFlight else { return }
        actionInFlight = true
        lastError = nil
        lastAction = nil
        listener.runCommand("launch", args: ["target": entry.path]) {
            [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            if result.ok {
                self.lastAction = result.output?["launch"]?
                    .first?.last ?? "Launched"
            } else {
                self.lastError = result.error?.message ?? "The Mac declined"
            }
        }
    }

    /// Reveal the selected entry in the guest's own Finder, by its full
    /// path — the reveal key doubles the launch key. Read-only on the
    /// guest: it selects the item and brings the Finder forward, opening
    /// nothing, so anything with a path is revealable (an extension, a
    /// control panel), not only applications. The words shown are the
    /// guest's own.
    func reveal(_ entry: SoftwareEntry) {
        guard entry.isRevealable, !actionInFlight else { return }
        actionInFlight = true
        lastError = nil
        lastAction = nil
        listener.runCommand("reveal", args: ["target": entry.path]) {
            [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            if result.ok {
                self.lastAction = result.output?["reveal"]?
                    .first?.last ?? "Revealed"
            } else {
                self.lastError = result.error?.message ?? "The Mac declined"
            }
        }
    }

    /// Measure what producing the Applications inventory costs this Mac —
    /// the guest's `catsearch` probe.
    ///
    /// Every other action on this page SPENDS the inventory; this one asks
    /// what it costs to build, which is the question a person has when the
    /// Applications sweep feels slow. It is the expensive one on the page:
    /// the guest gives up after 20 s per pass and runs two, so the button
    /// stays disabled while it runs and the rows come back in the guest's own
    /// words — including whether the volume supports CatSearch at all, which
    /// is the case where the answer is narrower rather than shorter.
    ///
    /// No local timeout here, unlike the agent path: a person watching a
    /// spinner can see that nothing has come back, which is the same reason
    /// the console's watchdog is generous.
    func measureCatalogSearch() {
        guard canBrowse, !actionInFlight else { return }
        actionInFlight = true
        lastError = nil
        lastAction = nil
        sweepCost = nil
        listener.runCommand("catsearch") { [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            guard result.ok, let rows = result.output?["catsearch"] else {
                self.lastError = result.error?.message
                    ?? "The Mac could not measure the sweep"
                return
            }
            self.sweepCost = rows.map {
                SweepRow(label: $0.first ?? "",
                         value: $0.count > 1 ? $0[1] : "")
            }
        }
    }

    /// One row of the last sweep measurement, as the guest wrote it.
    struct SweepRow: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// One page, chaining into the next while `more` holds. Cursor 1 is
    /// where the guest rebuilds its inventory — for Applications that is
    /// the whole ~4 s sweep, which the 30 s watchdog already allows.
    private func load(cursor: Int?, token: Int) {
        isLoading = true
        listener.listSoftware(domain: domain.rawValue,
                              cursor: cursor) { [weak self] result in
            guard let self, token == self.loadToken else { return }
            switch result {
            case .success(let listing):
                self.rows += listing.entries
                if let note = listing.note {
                    self.note = note
                }
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

extension SoftwareEntry {
    /// Size in the unit that keeps the number legible; nothing for a
    /// size the guest could not read (-1) rather than a lying "0 KB".
    var sizeLabel: String? {
        guard let k = sizeK, k >= 0 else { return nil }
        if k < 1024 { return "\(k) KB" }
        return String(format: "%.1f MB", Double(k) / 1024.0)
    }

    /// The one word a person scans: running, off, or nothing.
    var stateLabel: String {
        if running == true { return "running" }
        if off == true { return "off" }
        return ""
    }

    /// The two 4CCs as one caption, when the guest sent them.
    var kindLabel: String? {
        let parts = [type, creator].compactMap { code -> String? in
            guard let code, !code.isEmpty else { return nil }
            return code
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " / ")
    }
}
