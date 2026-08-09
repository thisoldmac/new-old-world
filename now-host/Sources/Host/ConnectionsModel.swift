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
/// - `address` is where the host saw it. Authoritative for which socket,
///   useless as a name — and on loopback it cannot even tell two Macs
///   apart, which is what `idIsAnchored` says out loud.
///
/// `name` is a fourth thing and deliberately not an identity: it is what
/// the machine calls itself, it carries the deployed binary's version, and
/// it is shown and never compared.
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
    let address: String
    let liveSessionID: String?
    /// The last session this machine had, when the pane watched it end.
    let lastSessionID: String?
    /// Connected since, for a connected row; last seen, for a known one.
    let since: Date
    let version: String?
    let build: String?
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
        let driving = rows.first { $0.presence == .driving }?.machineID
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
                address: guest.address.text,
                liveSessionID: guest.sessionID,
                lastSessionID: ended[guest.id.slug]?.sessionID,
                since: guest.connectedAt,
                version: guest.version,
                build: guest.build,
                operatingSystem: guest.operatingSystem,
                agentAccess: guest.agentAccess,
                idIsAutoAssigned: guest.idIsAutoAssigned,
                idIsAnchored: guest.idIsAnchored,
                key: guest.key,
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
                address: record.address,
                liveSessionID: nil,
                lastSessionID: last,
                since: record.lastSeen,
                version: nil,
                build: nil,
                operatingSystem: nil,
                agentAccess: nil,
                idIsAutoAssigned: record.autoAssigned,
                /* The registry anchors on the address; where the address
                   cannot tell machines apart, neither can the record. */
                idIsAnchored: GuestAddress(text: record.address)
                    .distinguishesMachines,
                key: nil,
                byMachineID: ConnectionAddressing(
                    refusal: resolve(record.id.slug)),
                bySessionID: last.map {
                    ConnectionAddressing(refusal: resolve($0))
                }))
        }
        return ConnectionsSnapshot(state: state, rows: rows)
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

    private let listener: GuestListener
    private let resolve: (String) -> AgentIntegrationUnavailable?
    private let select: (GuestKey) -> Bool
    private var ended: [String: EndedGuestSession] = [:]
    private var liveGuests: [GuestKey: ConnectedGuest] = [:]
    private var watch: HostEventSubscription?

    /// Bounded by machines rather than by connections, so a desk that
    /// reconnects all day does not grow a ledger.
    private static let endedLimit = 16

    init(listener: GuestListener,
         resolve: @escaping (String) -> AgentIntegrationUnavailable?,
         select: ((GuestKey) -> Bool)? = nil) {
        self.listener = listener
        self.resolve = resolve
        self.select = select ?? { [listener] key in listener.selectGuest(key) }
        /* This used to sink `$guests` and `$state` and hop a turn through
           the main queue, because `@Published` fires in `willSet` and a sink
           reading the listener back synchronously saw the OUTGOING value.
           The bus publishes from `didSet`, so the listener has already
           settled when this runs and the hop is gone with the reason for it
           — which also means the pane is right within the turn rather than
           after one. */
        watch = listener.events.subscribe { [weak self] event in
            switch event {
            case .rosterChanged, .linkStateChanged, .focusChanged,
                 .guestConnected, .guestDisconnected, .guestRenamed:
                self?.refresh()
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
