import Foundation
import NOWAgentIntegration

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
        /// Every domain this machine has been swept for, not just the one
        /// on screen. Flipping the picker to Extensions and back used to
        /// cost two whole sweeps; the picker is the cheapest thing on the
        /// page to click and was the most expensive thing to click.
        var listings: [Domain: Listing] = [:]
        var domain: Domain = .apps
        var selection: SoftwareEntry.ID?
        var search = ""
    }

    /// One machine's inventory of ONE domain, whole, and when it was taken.
    ///
    /// Banked only when the last page lands: a half-swept domain is not a
    /// listing, and caching one would turn a dropped connection into a
    /// permanently short inventory that never re-asks.
    struct Listing: Equatable {
        var rows: [SoftwareEntry]
        var note: String?
        var fetchedAt: Date
    }

    /// Keyed on `GuestKey` — the SESSION id — and deliberately not on the
    /// other two identities this codebase keeps apart (see GuestIdentity):
    ///
    /// - Not `GuestID` (the machine). That key would let a listing survive
    ///   a reconnect, which is what a durable cache normally wants and is
    ///   wrong here twice over: this project redeploys the guest between
    ///   dials, so the disk that produced the listing may not be the disk
    ///   that answers next; and `ConnectedGuest.idIsAnchored` is FALSE at
    ///   loopback, so on this desk the machine id's stability across a
    ///   reconnect is a guess. A confident file listing shown under a
    ///   guessed identity is a wrong answer about a different Mac, which is
    ///   strictly worse than the sweep it saves.
    /// - Not `GuestAddress` (the socket). Every emulated guest reaches this
    ///   host from 127.0.0.1, so the address merges Macs rather than
    ///   separating them, and a real machine can change address anyway.
    ///
    /// The session id therefore invalidates in exactly the two places it
    /// should: a new dial is a new session (a listing never crosses a
    /// reconnect), and a switch between two live sessions parks each
    /// machine's listings under its own key rather than showing one Mac's
    /// software under the other's name.
    private let cache = GuestStateCache<Snapshot>()

    /// The focused machine's banked sweeps, one per domain. The published
    /// `rows`/`note`/`fetchedAt` below are a view onto `listings[domain]`
    /// while nothing is in flight.
    private var listings: [Domain: Listing] = [:]

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
        didSet {
            guard domain != oldValue, !isRestoring else { return }
            // A page still in flight belongs to the domain we just left.
            loadToken += 1
            isLoading = false
            show(listings[domain])
            // A domain already swept on this machine is shown, not re-asked;
            // one never swept still costs its one sweep.
            openIfNeeded()
        }
    }
    private var isRestoring = false
    @Published private(set) var rows: [SoftwareEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// The listing's honest edges — "no such domain", a truncated
    /// inventory — surfaced verbatim, never swallowed.
    @Published private(set) var note: String?
    @Published private(set) var fetchedAt: Date?
    /// When a rescan asked for and failed, while the rows on screen are the
    /// PREVIOUS sweep's. Set only in that case: a failure with nothing to
    /// fall back to is an empty page with an error on it, and a failure that
    /// silently left the old rows wearing a fresh timestamp is the thing
    /// this exists to prevent.
    @Published private(set) var rescanFailedAt: Date?
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
    /// What the machines on the wire have said they can do. Shared with every
    /// other page that gates a control, injectable so a test gets its own.
    let capabilities: GuestCapabilityRecord
    /// Guards against a slow page landing after a refresh or a domain
    /// switch: each load takes a token, only the current token appends.
    private var loadToken = 0

    init(listener: GuestListener,
         capabilities: GuestCapabilityRecord = .shared) {
        self.listener = listener
        self.capabilities = capabilities
    }

    var canBrowse: Bool { connection.canCapture }

    /// **Whether Launch means anything for this item, on this Mac** — the two
    /// questions in one answer, and they are different questions.
    ///
    /// `isLaunchable` is a third fact again and stays where it is: it says the
    /// machine named a path, which is honesty about the listing rather than
    /// about the item or the wire. What was missing is the item's own kind. A
    /// system extension has a path, so the button was live on one, and the
    /// guest refused it after a round trip with "not an application" — its own
    /// rule, learned the slow way. It is the same rule, said before the trip.
    func launchGate(_ entry: SoftwareEntry) -> GuestCapabilityGate.Decision {
        GuestCapabilityGate.decide(
            LaunchSoftwareProjection.self, performing: .launch,
            on: entry.itemKind, named: entry.name,
            in: capabilities.evidence(for: connection, listener: listener))
    }

    /// The sentence a dark Launch button owes the reader, and nil while it
    /// works — including for the merely unproven case, which is enabled and
    /// does not get to nag.
    func launchUnavailableNote(_ entry: SoftwareEntry) -> String? {
        let decision = launchGate(entry)
        guard decision.deservesAVisibleReason else { return nil }
        return decision.explanation
    }

    var selectedEntry: SoftwareEntry? {
        rows.first { $0.id == selection }
    }

    /// The items a person sees: the wire's inventory narrowed by the
    /// search field. Filtering is client-side over what is already here —
    /// the guest's disk is never re-asked per keystroke (the guest page's
    /// rule, kept on this side too).
    var visibleEntries: [SoftwareEntry] {
        search.isEmpty
            ? rows
            : rows.filter { Self.matches($0, query: search) }
    }

    /// How many ITEMS are shown, which is not how many rows are drawn once
    /// duplicates collapse. The guest's status line counts items too
    /// (`sw_status_text`), so the two surfaces report the same number.
    var visibleItemCount: Int { visibleEntries.count }

    /// Which duplicate groups are open, by container id.
    ///
    /// Collapsed by default, which is the guest's state on a rebuild —
    /// gathering duplicates is only worth doing if the gathered form is
    /// what you land on.
    @Published var expandedGroups: Set<String> = []

    /// The table's rows: the visible items, sorted and with duplicates
    /// gathered under a container, exactly as the guest's own Software page
    /// does it — flattened for a `Table` that cannot draw a tree before
    /// macOS 14, so a closed group's members are simply not in the list,
    /// which is also what the guest's Data Browser does to them.
    var visibleRows: [SoftwareRow] {
        Self.flatten(Self.rows(for: visibleEntries),
                     expanded: expandedGroups)
    }

    func toggle(group id: SoftwareRow.ID) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
        } else {
            expandedGroups.insert(id)
        }
    }

    /// Container rows, then their members while the container is open.
    static func flatten(_ tree: [SoftwareRow],
                        expanded: Set<String>) -> [SoftwareRow] {
        var out: [SoftwareRow] = []
        for row in tree {
            out.append(row)
            if let children = row.children, expanded.contains(row.id) {
                out.append(contentsOf: children.map { $0.indented() })
            }
        }
        return out
    }

    static func matches(_ entry: SoftwareEntry, query: String) -> Bool {
        entry.name.range(of: query, options: .caseInsensitive) != nil
    }

    // MARK: duplicate groups

    /// One row of the table: an item, or the container for a run of items
    /// that share a name.
    ///
    /// A container is a disclosure, never a selection — the guest's rule
    /// (`kDataBrowserItemIsSelectableProperty` is false for a group row),
    /// so the detail pane and its actions always name one real file.
    struct SoftwareRow: Identifiable {
        /// Leaf: the entry's own id (its path). Container: the shared name
        /// behind a NUL, which no HFS path can contain, so a group can
        /// never collide with an item.
        let id: String
        /// The item this row IS, or nil when the row is a group container.
        let entry: SoftwareEntry?
        /// What this row stands for: the one item, or the group's members
        /// in the order they are disclosed.
        let members: [SoftwareEntry]
        let children: [SoftwareRow]?
        /// 1 for a row shown under an open container, 0 otherwise. Carried
        /// on the row rather than inferred at draw time, so the indent
        /// cannot disagree with the flattening that produced it.
        var depth: Int = 0

        func indented() -> SoftwareRow {
            var copy = self
            copy.depth = 1
            return copy
        }

        var isGroup: Bool { entry == nil }
        var name: String { members.first?.name ?? "" }

        /// The version column. A container has no version — it has a COUNT,
        /// which is the guest's answer in the same column ("%d items").
        var versionText: String {
            guard let entry else { return "\(members.count) items" }
            return entry.version ?? "–"
        }

        /// True when this row is drawing a placeholder rather than a fact,
        /// so the view can grey it without re-deriving why.
        var versionIsKnown: Bool { isGroup || entry?.version != nil }

        /// A container sums its members' sizes, skipping the ones the guest
        /// could not read — the guest's `if (m->size_k > 0)`, which is why
        /// an unreadable member shrinks the total rather than poisoning it.
        var sizeText: String {
            guard let entry else {
                let total = members.reduce(into: 0) { sum, member in
                    if let k = member.sizeK, k > 0 { sum += k }
                }
                return SoftwareEntry.sizeLabel(kilobytes: total) ?? ""
            }
            return entry.sizeLabel ?? ""
        }

        /// A container reads "running" when ANY member is, which is the
        /// question a person collapsing five SimpleTexts is asking.
        var isRunning: Bool {
            guard let entry else { return members.contains { $0.running == true } }
            return entry.running == true
        }

        var stateText: String {
            guard let entry else { return isRunning ? "running" : "" }
            return entry.stateLabel
        }
    }

    /// Whether an id names a group container rather than an item.
    static func isGroupID(_ id: SoftwareRow.ID) -> Bool {
        id.hasPrefix(groupIDPrefix)
    }

    private static let groupIDPrefix = "\u{0}group:"

    /// Gather duplicates the way the guest's Software page already does.
    ///
    /// The rule is the guest's, read off `compute_groups` in
    /// `now-guest-ppc/src/software/software_module.c` and reproduced rather
    /// than reinvented — two surfaces that group differently disagree
    /// invisibly, which is worse than neither grouping at all:
    ///
    /// 1. Sort the domain's items by name under an **ASCII case fold**
    ///    (`A`–`Z` lowered by 32, compared byte by byte, shorter name first
    ///    on a prefix), ties broken by arrival order so the sort is stable.
    /// 2. Walk the sorted run: items are in the same group while their name
    ///    equals the run's FIRST name case-insensitively.
    /// 3. A run of **two or more** becomes one container; a run of one stays
    ///    a plain row. There is no group of one, on either surface.
    ///
    /// Scope matches too: the guest groups within the domain it is showing,
    /// which is what `rows` holds here.
    ///
    /// The one place this can diverge is a pair of names differing only in
    /// the case of a NON-ASCII Mac Roman letter (`é`/`É`): the guest's
    /// `EqualString(…, false, true)` folds those, step 1's ASCII fold does
    /// not, and step 2 here uses Foundation's case-insensitive compare. The
    /// guest's own sort does not bring such a pair adjacent either, so it
    /// only groups them when nothing sorts between — noted rather than
    /// smoothed over, because the honest statement of a rule includes where
    /// it stops.
    static func rows(for entries: [SoftwareEntry]) -> [SoftwareRow] {
        let sorted = entries.enumerated().sorted { lhs, rhs in
            let a = foldedName(lhs.element.name)
            let b = foldedName(rhs.element.name)
            if a != b { return a.lexicographicallyPrecedes(b) }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var out: [SoftwareRow] = []
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count, sameName(sorted[i], sorted[j]) { j += 1 }
            let run = Array(sorted[i..<j])
            if run.count >= 2 {
                out.append(SoftwareRow(
                    id: groupIDPrefix + run[0].name,
                    entry: nil,
                    members: run,
                    children: run.map(leaf)))
            } else {
                out.append(leaf(run[0]))
            }
            i = j
        }
        return out
    }

    private static func leaf(_ entry: SoftwareEntry) -> SoftwareRow {
        SoftwareRow(id: entry.id, entry: entry, members: [entry],
                    children: nil)
    }

    /// The guest's `cmp_by_name` fold: ASCII upper-case lowered, everything
    /// else left as its own byte.
    private static func foldedName(_ name: String) -> [UInt8] {
        name.utf8.map { $0 >= 65 && $0 <= 90 ? $0 &+ 32 : $0 }
    }

    /// The guest's `same_name` — `EqualString(a, b, false, true)`, which is
    /// case-insensitive and diacritic-SENSITIVE. `.caseInsensitive` alone is
    /// the Foundation comparison with those same two answers; adding
    /// `.diacriticInsensitive` would make `Résumé` and `Resume` one item on
    /// this side and two on the guest.
    private static func sameName(_ a: SoftwareEntry,
                                 _ b: SoftwareEntry) -> Bool {
        a.name.compare(b.name, options: .caseInsensitive) == .orderedSame
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
            // The session ended. Every banked sweep went with it — see the
            // cache's own note on why the session id is the key.
            listings = [:]
            rows = []
            fetchedAt = nil
            rescanFailedAt = nil
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
        // A sweep still in flight is not banked; only whole listings park.
        Snapshot(listings: listings, domain: domain,
                 selection: selection, search: search)
    }

    private func restore(_ snapshot: Snapshot) {
        // A page still in flight belongs to the machine we just left.
        loadToken += 1
        isLoading = false
        actionInFlight = false
        lastAction = nil
        // A timing measured on the machine we just left is not a fact about
        // the one we just arrived at.
        sweepCost = nil
        listings = snapshot.listings
        isRestoring = true
        domain = snapshot.domain
        isRestoring = false
        show(listings[domain])
        selection = snapshot.selection
        search = snapshot.search
    }

    /// Put a banked listing (or nothing) on screen, without asking the wire.
    private func show(_ listing: Listing?) {
        rows = listing?.rows ?? []
        note = listing?.note
        fetchedAt = listing?.fetchedAt
        lastError = nil
        rescanFailedAt = nil
    }

    /// The page was opened, or a connection arrived under it.
    ///
    /// Enumerating a domain costs the OTHER Mac a multi-second disk sweep it
    /// does while doing nothing else, so it happens once per machine per
    /// domain and not once per glance at the page. Everything after that is
    /// the person's `refresh()`.
    func openIfNeeded() {
        guard canBrowse, !isLoading, listings[domain] == nil else { return }
        sweep()
    }

    /// The manual rescan. The ONLY thing on this page that re-asks a domain
    /// the machine has already answered — which is what makes the button
    /// worth having rather than decoration over an automatic refetch.
    func refresh() {
        guard canBrowse, !isLoading else { return }
        sweep()
    }

    private func sweep() {
        loadToken += 1
        rows = []
        note = nil
        fetchedAt = nil
        lastError = nil
        rescanFailedAt = nil
        load(domain: domain, cursor: nil, token: loadToken)
    }

    /// Launch the selected entry on the guest, by its full path — the
    /// listing's launch key. The guest replies with what launched or
    /// why not, and either way the words shown are the guest's own.
    func launch(_ entry: SoftwareEntry) {
        guard entry.isLaunchable, !actionInFlight else { return }
        actionInFlight = true
        lastError = nil
        lastAction = nil
        listener.runScheduledCommand(
            "launch", args: ["target": entry.path],
            purpose: .interaction("launch software"),
            workClass: .humanInteractive) {
            [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            if result.ok {
                self.lastAction = result.output?["launch"]?
                    .first?.last ?? "Launched"
            } else {
                self.lastError = result.error?.message
                    ?? "\(MachineNaming.title(self.connection)) declined"
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
        listener.runScheduledCommand(
            "reveal", args: ["target": entry.path],
            purpose: .interaction("reveal software"),
            workClass: .humanInteractive) {
            [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            if result.ok {
                self.lastAction = result.output?["reveal"]?
                    .first?.last ?? "Revealed"
            } else {
                self.lastError = result.error?.message
                    ?? "\(MachineNaming.title(self.connection)) declined"
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
        listener.runScheduledCommand(
            "catsearch", purpose: .bulk("software catalog search"),
            workClass: .bulk) { [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            guard result.ok, let rows = result.output?["catsearch"] else {
                self.lastError = result.error?.message
                    ?? "\(MachineNaming.title(self.connection)) could not "
                    + "measure the scan"
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
    private func load(domain: Domain, cursor: Int?, token: Int) {
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
                    self.load(domain: domain, cursor: next, token: token)
                } else {
                    self.isLoading = false
                    let at = Date()
                    self.fetchedAt = at
                    // Banked here and only here: the domain is whole.
                    self.listings[domain] = Listing(
                        rows: self.rows, note: self.note, fetchedAt: at)
                }
            case .failure(let failure):
                self.isLoading = false
                self.lastError = failure.message
                // A failed rescan must not cost a good answer — and must
                // not let one pass for new. The previous listing comes back
                // wearing its OWN timestamp, and `rescanFailedAt` is what
                // the footer says out loud.
                if let previous = self.listings[domain] {
                    self.rows = previous.rows
                    self.note = previous.note
                    self.fetchedAt = previous.fetchedAt
                    self.rescanFailedAt = Date()
                }
            }
        }
    }
}

extension SoftwareEntry {
    /// Size in the unit that keeps the number legible; nothing for a
    /// size the guest could not read (-1) rather than a lying "0 KB".
    var sizeLabel: String? {
        Self.sizeLabel(kilobytes: sizeK)
    }

    /// The same rendering for a group container's summed size, which is not
    /// any one entry's `sizeK`.
    static func sizeLabel(kilobytes: Int?) -> String? {
        guard let k = kilobytes, k >= 0 else { return nil }
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
