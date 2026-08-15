import Combine
import Foundation
import NOWAgentIntegration

/// What this host would tell a caller that named a machine — read back to
/// the person, in the person's own window.
///
/// **It is not computed here.** Every value on this type comes from the
/// host's own `addressingRefusal`, the one function that decides whether a
/// request reaches the machine a caller meant. A pane that re-derived "is
/// this addressable" from the roster would be a second opinion, and the
/// first time the two disagreed the person would be reading the wrong one.
/// So the model asks and reports, and the `message` is the host's sentence
/// verbatim rather than a paraphrase.
struct ConnectionAddressing: Equatable, Sendable {
    /// The four typed outcomes the addressing surface actually has, plus
    /// the two shapes that are not a machine's fault: nothing is connected
    /// at all, and a code this build does not recognise.
    enum Outcome: Equatable, Sendable {
        /// The host would answer for this machine.
        case answered
        /// Connected, but the host is driving another Mac. Fixed by
        /// driving this one — which is why the row carries a control.
        case notAddressed
        /// The host has no live connection to this machine.
        case notConnected
        /// That session has ended. Only ever the answer to a SESSION id;
        /// the machine id still reaches whatever is connected now.
        case sessionEnded
        /// Nothing at all is connected, so there is no machine to be not
        /// driving. Distinct from `notConnected`, because "you named a Mac
        /// that is not here" and "no Mac is here" send a person to
        /// different places.
        case noGuestConnected
        /// A refusal code this build has never seen. Never folded into a
        /// known one: the pane says the host refused and shows its words.
        case unrecognised(code: String)
    }

    let outcome: Outcome
    /// The host's own sentence. Nil exactly when the outcome is
    /// `answered`, because there is no refusal to quote.
    let message: String?

    static let answered = ConnectionAddressing(outcome: .answered,
                                               message: nil)

    /// The single translation point, from the host's refusal to the row.
    init(refusal: AgentIntegrationUnavailable?) {
        guard let refusal else {
            outcome = .answered
            message = nil
            return
        }
        message = refusal.message
        switch refusal.code {
        case "now-guest-not-addressed": outcome = .notAddressed
        case "now-guest-session-ended": outcome = .sessionEnded
        case "now-guest-not-connected": outcome = .notConnected
        case "now-guest-unavailable": outcome = .noGuestConnected
        default: outcome = .unrecognised(code: refusal.code)
        }
    }

    init(outcome: Outcome, message: String?) {
        self.outcome = outcome
        self.message = message
    }
}

/// A session that has ended, remembered only so the pane can be honest
/// about the one outcome that has no row of its own.
///
/// `sessionEnded` is the answer to a stale SESSION id, and a session id
/// exists nowhere durable — the registry remembers machines, not
/// connections, deliberately. Without this the pane could show three of
/// the four outcomes and would silently imply the fourth does not happen.
/// It is the view's memory of what the view watched leave, bounded and
/// dropped at quit; nothing else reads it, and it never puts a row on
/// screen that the roster and the registry did not already justify.
struct EndedGuestSession: Equatable, Sendable {
    let machineID: String
    let sessionID: String
    let endedAt: Date
}

/// One machine, as this host knows it right now.
///
/// **Three identities, kept apart** — the separation is the point, and a
/// row that collapsed them would mislead exactly where it matters:
///
/// - `machineID` is what a person or an agent TYPES. Stable, host-assigned.
/// - `liveSessionID` is THIS connection. Refused once it has ended, rather
///   than answered by its successor.
/// - `address` pairs the guest IP the host saw with the host port that
///   accepted that machine. It is useful reconnect information, not a
///   durable identity — on loopback it cannot even tell two Macs apart,
///   which is what `idIsAnchored` says out loud.
///
/// `name` is what the machine reported; `displayName` is the host-owned title
/// that defaults from it and may be edited without changing identity.
struct ConnectionRow: Identifiable, Equatable, Sendable {
    /// Where this machine stands with the host.
    enum Presence: Equatable, Sendable {
        /// Connected, and the one the window and the request-shaped API
        /// are pointed at.
        case driving
        /// Connected, and not being driven. Everything it says still
        /// arrives; nothing this host asks goes to it until it is chosen.
        case connected
        /// Remembered from a previous connection, not here now. A product
        /// that can address machines by name has to admit to knowing names
        /// it cannot currently reach.
        case known
    }

    let machineID: String
    let presence: Presence
    /// What the machine calls itself — live for a connected row, and the
    /// last name it used for a remembered one.
    let name: String
    /// Host-owned title used by both this page and agent discovery.
    let displayName: String
    /// Guest IP plus the host listener port this machine used. This is not
    /// the transient remote source port from its TCP socket.
    let address: String
    let liveSessionID: String?
    /// The last session this machine had, when the pane watched it end.
    let lastSessionID: String?
    /// Connected since, for a connected row; last seen, for a known one.
    let since: Date
    let version: String?
    let build: String?
    let extensionVersion: String?
    let extensionBuild: String?
    let operatingSystem: String?
    /// The machine's own `hello` answer about being driven by an agent.
    /// Nil is "this build never said", which is not a yes.
    let agentAccess: AgentIntegrationGuestAccess?
    /// True while the id is the host's own ordinal and nobody has named
    /// this machine. It addresses it; it says nothing about it.
    let idIsAutoAssigned: Bool
    /// False when the host cannot tell two machines apart at this address
    /// — every emulated guest — so the id surviving a reconnection is a
    /// guess and the pane must not draw it as a fact.
    let idIsAnchored: Bool
    /// The session handle the pane needs to drive or rename this machine.
    /// Nil for a remembered row: neither is possible without a connection.
    let key: GuestKey?
    /// Exact durable registry record, only for remembered rows. A machine id
    /// is human-editable and therefore cannot safely identify a deletion.
    let registryKey: GuestRegistry.Record.Key?
    /// What an agent naming this row's MACHINE id would be told.
    let byMachineID: ConnectionAddressing
    /// What an agent holding this row's SESSION id would be told — the live
    /// one when connected, the remembered one when not. Nil when the pane
    /// has no session id to ask about.
    let bySessionID: ConnectionAddressing?

    /// The session when there is one, so two rows can never collide even
    /// if a future registry hands two live sessions one machine id.
    var id: String { liveSessionID ?? "known:\(machineID)" }

    var isConnected: Bool { presence != .known }
    var label: String { displayName }
}

/// Everything the pane draws, derived in one place from state the host
/// already keeps.
///
/// A view, not a model: the roster is the listener's, the book of machines
/// is the registry's, the link state is the listener's, and the addressing
/// answers are the agent adapter's. Nothing here is stored anywhere else
/// except the ended-session ledger, which exists for the reason given at
/// `EndedGuestSession`.
struct ConnectionsSnapshot: Equatable, Sendable {
    /// The link this host is offering, straight off the listener.
    let state: GuestListener.State
    let rows: [ConnectionRow]

    static let empty = ConnectionsSnapshot(state: .idle, rows: [])

    var connected: [ConnectionRow] { rows.filter(\.isConnected) }
    var known: [ConnectionRow] { rows.filter { $0.presence == .known } }
    var driving: ConnectionRow? { rows.first { $0.presence == .driving } }

    /// **The resting state.** No Mac has dialled in — which on this desk is
    /// most of the time, and is not a fault. The pane says so in the words
    /// of what the host is doing (listening, or not), never as an error.
    var isIdle: Bool { connected.isEmpty }

    /// **The page's one line**: whether the link is up, and who is on it.
    ///
    /// It answers both halves because the page is both halves — the link
    /// pane and the roster pane were separate and each drew a status line of
    /// its own, worded differently. This is the surviving one.
    ///
    /// "Mac" is never the noun here. This is the page that lists several
    /// machines, and it is read from a Mac; "no Mac connected" on it could
    /// as easily have meant the machine the app is running on.
    var headline: String {
        switch state {
        case .failed(let reason):
            return reason
        case .idle:
            return "Not listening"
        case .listening(let port):
            guard !connected.isEmpty else {
                return "Listening on \(String(port)) — no "
                    + "\(MachineNaming.commonNoun) connected"
            }
            return Self.connectedLine(connected)
        case .connected:
            guard !connected.isEmpty else {
                // The roster is built from live sessions and the state is
                // published beside it; if they disagree, say the roster's
                // answer rather than inventing a machine.
                return "No \(MachineNaming.commonNoun) connected"
            }
            return Self.connectedLine(connected)
        }
    }

    private static func connectedLine(_ rows: [ConnectionRow]) -> String {
        guard rows.count > 1 else {
            return "1 \(MachineNaming.commonNoun) connected"
        }
        let driving = rows.first { $0.presence == .driving }?.displayName
        guard let driving else {
            return "\(rows.count) \(MachineNaming.commonNounPlural) connected"
        }
        return "\(rows.count) \(MachineNaming.commonNounPlural) connected "
            + "— driving \(driving)"
    }

    /// Builds the whole pane from the facts, and asks the host itself what
    /// each id and each session id would be answered with.
    ///
    /// `resolve` is the host's `addressingRefusal`. It is a parameter and
    /// not a reimplementation, so this cannot drift from the surface it
    /// describes; a test hands it a stub and gets the same shape.
    static func make(state: GuestListener.State,
                     guests: [ConnectedGuest],
                     known: [GuestRegistry.Record],
                     ended: [String: EndedGuestSession],
                     resolve: (String) -> AgentIntegrationUnavailable?)
        -> ConnectionsSnapshot {
        var rows: [ConnectionRow] = []
        /* Driving first, then by how long they have been here. The one
           being driven is the answer to the question the pane exists for,
           so it does not move when a third Mac dials in. */
        let live = guests.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.connectedAt < $1.connectedAt
        }
        for guest in live {
            rows.append(ConnectionRow(
                machineID: guest.id.slug,
                presence: guest.isActive ? .driving : .connected,
                name: guest.name,
                displayName: guest.label,
                address: Self.listenerAddress(guest.address.text,
                    port: guest.listenPort ?? SettingsModel.defaultPort),
                liveSessionID: guest.sessionID,
                lastSessionID: ended[guest.id.slug]?.sessionID,
                since: guest.connectedAt,
                version: guest.version,
                build: guest.build,
                extensionVersion: guest.extensionVersion,
                extensionBuild: guest.extensionBuild,
                operatingSystem: guest.operatingSystem,
                agentAccess: guest.agentAccess,
                idIsAutoAssigned: guest.idIsAutoAssigned,
                idIsAnchored: guest.idIsAnchored,
                key: guest.key,
                registryKey: nil,
                byMachineID: ConnectionAddressing(
                    refusal: resolve(guest.id.slug)),
                bySessionID: ConnectionAddressing(
                    refusal: resolve(guest.sessionID))))
        }
        /* A remembered machine can never shadow one on the wire: the live
           roster is built first and its ids are excluded here. That is the
           same rule the listener keeps, for the same reason. */
        let liveIDs = Set(live.map(\.id.slug))
        for record in known where !liveIDs.contains(record.id.slug) {
            let last = ended[record.id.slug]?.sessionID
            rows.append(ConnectionRow(
                machineID: record.id.slug,
                presence: .known,
                name: record.lastName,
                displayName: record.displayName ?? record.lastName,
                address: Self.listenerAddress(record.address,
                    port: record.listenPort ?? SettingsModel.defaultPort),
                liveSessionID: nil,
                lastSessionID: last,
                since: record.lastSeen,
                version: nil,
                build: nil,
                extensionVersion: nil,
                extensionBuild: nil,
                operatingSystem: nil,
                agentAccess: nil,
                idIsAutoAssigned: record.autoAssigned,
                /* The registry anchors on the address; where the address
                   cannot tell machines apart, neither can the record. */
                idIsAnchored: GuestAddress(text: record.address)
                    .distinguishesMachines,
                key: nil,
                registryKey: record.key,
                byMachineID: ConnectionAddressing(
                    refusal: resolve(record.id.slug)),
                bySessionID: last.map {
                    ConnectionAddressing(refusal: resolve($0))
                }))
        }
        return ConnectionsSnapshot(state: state, rows: rows)
    }

    private static func listenerAddress(_ address: String,
                                        port: UInt16) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return "\(host):\(port)"
    }
}

/// The Connections page's model: which Macs are connected, which one an
/// agent is talking to, and how to tell them apart.
///
/// **Nothing here is a new source of truth.** It subscribes to the
/// listener's roster and state, reads the registry's book of machines, and
/// asks the agent adapter's own addressing function what each id would be
/// answered with. Its only memory is the ended-session ledger, and that is
/// there because a session id survives nowhere else.
///
/// **Whatever an agent can do, a person can initiate.** An agent picks
/// which Mac it means by naming one; a person picks by choosing a row, and
/// the same `selectGuest` seam moves the host either way. Renaming is the
/// person's alone by design: an id is what an agent has to type, and
/// letting a caller rename the handle it addresses is how a name stops
/// meaning a machine.
@MainActor
final class ConnectionsModel: ObservableObject {
    @Published private(set) var snapshot: ConnectionsSnapshot = .empty
    /// What the last rename attempt failed with, in the person's words.
    /// Cleared by the next attempt, so a stale complaint never outlives
    /// the field it is about.
    @Published private(set) var renameProblem: String?
    @Published private(set) var pendingUpdates: Set<UpdateKey> = []
    @Published private(set) var updateNotices: [UpdateKey: String] = [:]

    struct UpdateKey: Hashable {
        let guest: GuestKey
        let component: UpdateProvider.Component
    }

    /// The build this Mac told the guest to install, kept per key from the
    /// moment `installUpdate` sends the command until the guest's own
    /// reconnect proves it is running it — or until the session that
    /// installed it disconnects, at which point a fresh session's ordinary
    /// `.current`/`.replacement` read is the honest answer.
    ///
    /// It exists because `update.result` carries `ok` and `action`
    /// (`relaunch-required`/`restart-required`) but no build — the contract
    /// is explicit that an application install "remains connected" running
    /// the OLD code "until the person quits and relaunches it", so this
    /// side cannot infer completion from the result alone. The only proof
    /// this Mac gets is the SAME session later reporting the new build at a
    /// fresh `hello`, which for an unrelaunched guest never arrives — a
    /// one-shot "Installed." notice would then sit there being read as
    /// current forever, which is exactly the silent-stale-build defect this
    /// tracks against.
    private var pendingRelaunches: [UpdateKey: String] = [:]

    private let listener: GuestListener
    private let resolve: (String) -> AgentIntegrationUnavailable?
    private let select: (GuestKey) -> Bool
    private let disconnect: (GuestKey) -> Bool
    private let forget: (GuestRegistry.Record.Key) -> Bool
    private var ended: [String: EndedGuestSession] = [:]
    private var liveGuests: [GuestKey: ConnectedGuest] = [:]
    private var watch: HostEventSubscription?

    /// Bounded by machines rather than by connections, so a desk that
    /// reconnects all day does not grow a ledger.
    private static let endedLimit = 16

    init(listener: GuestListener,
         resolve: @escaping (String) -> AgentIntegrationUnavailable?,
         select: ((GuestKey) -> Bool)? = nil,
         disconnect: ((GuestKey) -> Bool)? = nil,
         forget: ((GuestRegistry.Record.Key) -> Bool)? = nil) {
        self.listener = listener
        self.resolve = resolve
        self.select = select ?? { [listener] key in listener.selectGuest(key) }
        self.disconnect = disconnect
            ?? { [listener] key in listener.removeGuest(key) }
        self.forget = forget
            ?? { [listener] key in listener.registry.forget(key) }
        /* This used to sink `$guests` and `$state` and hop a turn through
           the main queue, because `@Published` fires in `willSet` and a sink
           reading the listener back synchronously saw the OUTGOING value.
           The bus publishes from `didSet`, so the listener has already
           settled when this runs and the hop is gone with the reason for it
           — which also means the pane is right within the turn rather than
           after one. */
        watch = listener.events.subscribe { [weak self] event in
            switch event {
            case .guestDisconnected(let key, _):
                self?.abandonUpdates(for: key)
                self?.refresh()
            case .rosterChanged, .linkStateChanged, .focusChanged,
                 .guestConnected, .guestRenamed:
                self?.refresh()
            case .updateFinished(let key, let result):
                self?.finishUpdate(key: key, result: result)
            default:
                break
            }
        }
        refresh()
    }

    /// Convenience for the live app: the addressing answers come from the
    /// adapter that actually serves them.
    convenience init(listener: GuestListener,
                     addressing: AgentIntegrationHostAdapter,
                     select: ((GuestKey) -> Bool)? = nil) {
        self.init(listener: listener,
                  resolve: { [addressing] selector in
                      addressing.addressingRefusal(selector)
                  },
                  select: select)
    }

    /// Recomputes the page. Also the seam a test drives directly.
    func refresh() {
        noteDepartures(listener.guests)
        resolvePendingRelaunches()
        snapshot = ConnectionsSnapshot.make(
            state: listener.state,
            guests: listener.guests,
            known: listener.registry.known,
            ended: ended,
            resolve: resolve)
    }

    /// Points the whole window at this row's machine — the person's half of
    /// what an agent does by naming one.
    ///
    /// False when the row cannot be driven: a remembered machine has no
    /// connection to point at, and the one already being driven is not a
    /// change. Refusing rather than pretending, so a control that does
    /// nothing is a control the pane can disable.
    @discardableResult
    func drive(_ row: ConnectionRow) -> Bool {
        guard let key = row.key, row.presence == .connected else {
            return false
        }
        let moved = select(key)
        if moved { refresh() }
        return moved
    }

    /// Removes exactly what the list selection represents. Live rows are
    /// sessions, remembered rows are registry records; keeping those paths
    /// separate prevents a stale row from closing whichever guest happens
    /// to be active.
    @discardableResult
    func remove(_ row: ConnectionRow) -> Bool {
        if let key = row.key {
            return disconnect(key)
        }
        guard let key = row.registryKey else { return false }
        let removed = forget(key)
        if removed { refresh() }
        return removed
    }

    /// Names a machine, which is the one act that makes its id durable —
    /// until a human does this the id is an ordinal that says nothing.
    ///
    /// Connected machines only: the rename has to re-label the live
    /// session's row, and the listener owns that.
    @discardableResult
    func rename(_ row: ConnectionRow, to proposed: String) -> Bool {
        renameProblem = nil
        guard let key = row.key else {
            renameProblem = "\(row.machineID) is not connected."
            return false
        }
        switch listener.renameGuest(key, to: proposed) {
        case .success:
            refresh()
            return true
        case .failure(let why):
            renameProblem = Self.explain(why, proposed: proposed)
            return false
        }
    }

    /// Changes the title people see without touching the stable machine id.
    /// Remembered rows are valid targets because the registry owns the title.
    @discardableResult
    func renameDisplayName(_ row: ConnectionRow, to proposed: String) -> Bool {
        renameProblem = nil
        let outcome: Result<String, GuestRegistry.DisplayNameFailure>
        if let key = row.key {
            outcome = listener.renameGuestDisplayName(key, to: proposed)
        } else if let registryKey = row.registryKey {
            outcome = listener.registry.renameDisplayName(
                registryKey, to: proposed)
        } else {
            outcome = .failure(.notFound)
        }
        switch outcome {
        case .success:
            refresh()
            return true
        case .failure(.notFound):
            renameProblem = "That machine is no longer available."
        case .failure(.empty):
            renameProblem = "Enter a name for this machine."
        case .failure(.tooLong):
            renameProblem = "Machine names may be at most 80 characters."
        }
        return false
    }

    func clearRenameProblem() {
        renameProblem = nil
    }

    func updateAvailability(for row: ConnectionRow,
                            component: UpdateProvider.Component)
        -> UpdateProvider.Availability {
        let installed = component == .application
            ? (row.version, row.build)
            : (row.extensionVersion, row.extensionBuild)
        return listener.updateAvailability(
            component, installedVersion: installed.0,
            installedBuild: installed.1)
    }

    func installUpdate(for row: ConnectionRow,
                       component: UpdateProvider.Component) {
        guard let guest = row.key else { return }
        let key = UpdateKey(guest: guest, component: component)
        pendingUpdates.insert(key)
        updateNotices[key] = "Downloading and installing…"
        /* Recorded before the request leaves, from the offer this row is
           actually showing — the only place the target build is known,
           since `update.result` never carries one. */
        if case .replacement(let offer) = updateAvailability(
            for: row, component: component) {
            pendingRelaunches[key] = offer.build
        }
        let installed = component == .application
            ? (row.version, row.build)
            : (row.extensionVersion, row.extensionBuild)
        listener.installUpdate(
            component, for: guest, installedVersion: installed.0,
            installedBuild: installed.1) { [weak self] result in
                guard let self, !result.ok else { return }
                self.pendingUpdates.remove(key)
                self.pendingRelaunches.removeValue(forKey: key)
                self.updateNotices[key] = result.error?.message
                    ?? "The guest refused the update."
            }
    }

    func updateNotice(for row: ConnectionRow,
                      component: UpdateProvider.Component) -> String? {
        guard let guest = row.key else { return nil }
        return updateNotices[UpdateKey(guest: guest, component: component)]
    }

    func updateIsPending(for row: ConnectionRow,
                         component: UpdateProvider.Component) -> Bool {
        guard let guest = row.key else { return false }
        return pendingUpdates.contains(
            UpdateKey(guest: guest, component: component))
    }

    /// True while this row installed a component and this Mac has not yet
    /// seen the reconnect proof that it is running it. Meant for a
    /// lightweight badge that reads even when nobody has opened the update
    /// section's own notice text.
    func isAwaitingRelaunch(for row: ConnectionRow,
                            component: UpdateProvider.Component) -> Bool {
        guard let guest = row.key else { return false }
        return pendingRelaunches[UpdateKey(guest: guest,
                                           component: component)] != nil
    }

    private func finishUpdate(key guest: GuestKey, result: UpdateResult) {
        guard let component = UpdateProvider.Component(
            rawValue: result.component) else { return }
        let key = UpdateKey(guest: guest, component: component)
        pendingUpdates.remove(key)
        if result.ok {
            updateNotices[key] = relaunchNotice(for: key)
        } else {
            pendingRelaunches.removeValue(forKey: key)
            updateNotices[key] = result.reason ?? result.code
                ?? "The guest could not install the update."
        }
    }

    /// Re-derives every outstanding relaunch notice against this Mac's
    /// current view of the guest, on every refresh — never a value set once
    /// and left to go stale while the guest sits unrelaunched underneath it.
    private func resolvePendingRelaunches() {
        guard !pendingRelaunches.isEmpty else { return }
        for key in pendingRelaunches.keys {
            updateNotices[key] = relaunchNotice(for: key)
        }
    }

    /// The honest sentence for one pending install: confirmed by a matching
    /// build on THIS session's latest report, or plainly not yet — never
    /// silence, and never a claim this Mac cannot back with the guest's own
    /// word. The contract is explicit that installing an application never
    /// relaunches it and installing an extension never restarts the Mac
    /// (`update.result.action` is `relaunch-required`/`restart-required`,
    /// not `relaunch`/`restarted`), so "installed" and "running the new
    /// build" are two different facts and this says which one is true.
    private func relaunchNotice(for key: UpdateKey) -> String {
        guard let targetBuild = pendingRelaunches[key] else {
            return key.component == .application
                ? "Installed. Quit NOW on the guest, then launch it again."
                : "Installed. Restart the guest Mac to activate it."
        }
        if let guest = listener.guests.first(where: { $0.key == key.guest }) {
            let reported = key.component == .application
                ? guest.build : guest.extensionBuild
            if let reported, reported == targetBuild {
                pendingRelaunches.removeValue(forKey: key)
                return key.component == .application
                    ? "Relaunched — this session is now running the "
                        + "installed build."
                    : "Restarted — this Mac now reports the installed "
                        + "NOW Extension."
            }
        }
        switch key.component {
        case .application:
            return "Installed, but NOT relaunched: the guest app on the "
                + "classic Mac is still running the OLD build. Quit it on "
                + "the guest, then launch it again to pick up "
                + "\(targetBuild.prefix(12))."
        case .extensionComponent:
            return "Installed, but NOT active: restart the guest Mac to "
                + "load \(targetBuild.prefix(12)) — the running Extension "
                + "is still the old one."
        }
    }

    private func abandonUpdates(for guest: GuestKey) {
        pendingUpdates = pendingUpdates.filter { $0.guest != guest }
        updateNotices = updateNotices.filter { $0.key.guest != guest }
        /* The session that installed it is gone. A genuine relaunch opens a
           NEW session, whose row reads `.current`/`.replacement` fresh from
           its own reported build — there is nothing left for this key to
           watch, and holding onto it would only let a stale warning outlive
           the row it described. */
        pendingRelaunches = pendingRelaunches.filter { $0.key.guest != guest }
    }

    /// The failure in the words of what to do about it. `taken` names the
    /// other machine, because "that id is in use" without saying by what
    /// leaves a person guessing which Mac to go and rename first.
    static func explain(_ failure: GuestRegistry.RenameFailure,
                        proposed: String) -> String {
        switch failure {
        case .notFound:
            return "That machine is no longer connected."
        case .malformed:
            return "\"\(proposed)\" cannot be a machine id. Use letters, "
                + "numbers and hyphens."
        case .taken(let by):
            /* Not "another Mac": this sentence appears on the page that
               lists several of them, read from a Mac. */
            return "Another \(MachineNaming.commonNoun) (\(by)) already "
                + "holds that id. Rename it first, or choose another."
        }
    }

    /// Files the session ids of machines that have left, so the pane can
    /// still say what a caller holding one would be told.
    private func noteDepartures(_ guests: [ConnectedGuest]) {
        let now = Dictionary(uniqueKeysWithValues:
            guests.map { ($0.key, $0) })
        for (key, gone) in liveGuests where now[key] == nil {
            ended[gone.id.slug] = EndedGuestSession(
                machineID: gone.id.slug,
                sessionID: gone.sessionID,
                endedAt: Date())
        }
        liveGuests = now
        while ended.count > Self.endedLimit,
              let oldest = ended.min(by: { $0.value.endedAt < $1.value.endedAt })
        {
            ended.removeValue(forKey: oldest.key)
        }
    }
}
