import Foundation

/// Which machine an answer is about — the pairing, wherever a guest is
/// named on this surface.
///
/// Three fields because there are three different questions. `id` is the
/// MACHINE (`pb1400c`): stable, host-assigned, what a caller types to
/// address it, and what survives a redeploy. `sessionID`
/// (`pb1400c-<uuid>`) is THIS CONNECTION: a caller that holds one and
/// presents it after a silent reconnect is told the session ended rather
/// than being retargeted at its successor — the same shape as the process
/// and quit references already on this surface, which are refused when
/// stale rather than reinterpreted. `name` is what the machine calls
/// itself, which is guest-asserted, carries the version, and is therefore
/// a label and never a handle.
///
/// **No address.** The host observes the guest's peer address and uses it
/// internally to anchor the id, and it does not travel to a companion
/// process: this surface has never disclosed where anything is — not the
/// guest's address, not the host's socket path — and being able to name a
/// machine does not require being told where it lives. The pairing the
/// requirement asks for is exposed to the HUMAN, in the app's own roster
/// and log, where the address is already theirs.
public struct AgentIntegrationGuestReference:
    Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let name: String
    /// True while the id is the host's own ordinal and nobody has named
    /// this machine. It addresses the machine; it just says nothing about
    /// it.
    public let idIsAutoAssigned: Bool
    /// False when the host cannot tell two machines apart at this address,
    /// so the id's survival across a reconnection is a guess. A caller
    /// that needs certainty uses `sessionID`.
    public let idIsAnchored: Bool

    public init(id: String, sessionID: String, name: String,
                idIsAutoAssigned: Bool, idIsAnchored: Bool) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.idIsAutoAssigned = idIsAutoAssigned
        self.idIsAnchored = idIsAnchored
    }
}

public struct AgentIntegrationUnavailable: Codable, Equatable, Sendable {
    public static let host = AgentIntegrationUnavailable(
        code: "now-host-unavailable",
        message: "New Old World host is unavailable")
    public static let guest = AgentIntegrationUnavailable(
        code: "now-guest-unavailable",
        message: "No paired New Old World guest is connected")
    /// The caller named a machine that is connected but is not the one
    /// the host's request-shaped API is driving. Refused rather than
    /// served by the other machine — being handed the wrong Mac's process
    /// table is the failure this whole slice exists to prevent.
    public static func notAddressed(asking: String,
                                    driving: String,
                                    connected: [String])
        -> AgentIntegrationUnavailable {
        AgentIntegrationUnavailable(
            code: "now-guest-not-addressed",
            message: "\(asking) is connected, but this host is driving "
                + "\(driving). Connected: \(connected.joined(separator: ", "))")
    }

    /// The caller held a session id for a connection that has ended.
    /// Distinct from `notAddressed` and from `guest`, because "your
    /// session ended" and "nothing is connected" are different facts and
    /// only one of them is fixed by reconnecting.
    public static func sessionEnded(_ sessionID: String)
        -> AgentIntegrationUnavailable {
        AgentIntegrationUnavailable(
            code: "now-guest-session-ended",
            message: "Session \(sessionID) has ended. Address the machine "
                + "by its id to reach whatever is connected to it now.")
    }

    /// The caller named a machine the host has no live connection to.
    public static func notConnected(_ id: String)
        -> AgentIntegrationUnavailable {
        AgentIntegrationUnavailable(
            code: "now-guest-not-connected",
            message: "No New Old World guest \(id) is connected")
    }

    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum AgentIntegrationSessionHealthResult: Equatable, Sendable {
    case available(AgentIntegrationSessionHealth)
    case unavailable(AgentIntegrationUnavailable)

    public static let hostUnavailable = AgentIntegrationSessionHealthResult
        .unavailable(.host)
}

extension AgentIntegrationSessionHealthResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case available
        case health
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .available) {
            self = .available(try container.decode(
                AgentIntegrationSessionHealth.self, forKey: .health))
        } else {
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let health):
            try container.encode(true, forKey: .available)
            try container.encode(health, forKey: .health)
        case .unavailable(let unavailable):
            try container.encode(false, forKey: .available)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

public struct AgentIntegrationSessionHealth: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case notListening
        case listening
        case connected
        case failed
    }

    public struct Guest: Codable, Equatable, Sendable {
        /// Who this is — id, session id and label together. Optional only
        /// so a decoder built against v6 keeps working.
        public let reference: AgentIntegrationGuestReference?
        public let name: String
        public let version: String?
        /// Build identity from the guest's `hello`, when it reports one.
        ///
        /// `version` is hand-edited in the guest's source, so two builds
        /// routinely share it — a stale guest on the PowerBook 1400c reported
        /// the same "0.1.0" as the current one and an hour of diagnosis went
        /// to the wrong half of the system (2026-07-30). This differs whenever
        /// the build does. Nil means the guest reports none, which is a fact
        /// about that guest and NOT a claim about its build; a caller must not
        /// fall back to `version` to fill it in.
        public let build: String?
        public let operatingSystem: String?
        public let connectedAt: Date?
        public let lastTraffic: Date?
        public let quietFor: TimeInterval?
        public let pingsAnswered: Int?
        public let framesReceived: Int?

        public init(reference: AgentIntegrationGuestReference? = nil,
                    name: String, version: String?, build: String? = nil,
                    operatingSystem: String?, connectedAt: Date?,
                    lastTraffic: Date?, quietFor: TimeInterval?,
                    pingsAnswered: Int?, framesReceived: Int?) {
            self.reference = reference
            self.name = name
            self.version = version
            self.build = build
            self.operatingSystem = operatingSystem
            self.connectedAt = connectedAt
            self.lastTraffic = lastTraffic
            self.quietFor = quietFor
            self.pingsAnswered = pingsAnswered
            self.framesReceived = framesReceived
        }
    }

    public let state: State
    public let observedAt: Date
    public let listeningPort: UInt16?
    public let sessionID: UUID?
    public let guest: Guest?
    /// EVERY machine currently connected, not just the one being driven.
    /// The host serves several at once, so a caller that could only see
    /// the active one had no way to discover the id it needs to address
    /// another — and no way to know the others were there at all.
    public let roster: [AgentIntegrationGuestReference]
    public let failure: String?

    public init(state: State, observedAt: Date, listeningPort: UInt16?,
                sessionID: UUID?, guest: Guest?,
                roster: [AgentIntegrationGuestReference] = [],
                failure: String?) {
        self.roster = roster
        self.state = state
        self.observedAt = observedAt
        self.listeningPort = listeningPort
        self.sessionID = sessionID
        self.guest = guest
        self.failure = failure
    }
}

public enum AgentIntegrationProcessListResult: Equatable, Sendable {
    case available(AgentIntegrationProcessSnapshot)
    case unavailable(AgentIntegrationUnavailable)

    public static let guestUnavailable = AgentIntegrationProcessListResult
        .unavailable(.guest)
}

extension AgentIntegrationProcessListResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case available
        case snapshot
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .available) {
            self = .available(try container.decode(
                AgentIntegrationProcessSnapshot.self, forKey: .snapshot))
        } else {
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let snapshot):
            try container.encode(true, forKey: .available)
            try container.encode(snapshot, forKey: .snapshot)
        case .unavailable(let unavailable):
            try container.encode(false, forKey: .available)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

public struct AgentIntegrationProcessSnapshot:
    Codable, Equatable, Sendable {
    public enum Freshness: String, Codable, Equatable, Sendable {
        /// A complete read that was current only at `observedAt`.
        case pointInTime
    }

    public enum ReferenceAuthority:
        String, Codable, Equatable, Sendable {
        /// References remain snapshots but may be offered to the cooperative
        /// quit tool, which revalidates identity before acting.
        case cooperativeQuit
    }

    public let sessionID: UUID
    /// WHICH machine these rows came from. A process table that does not
    /// say whose it is was the concrete complaint: an agent calling
    /// process.list got whatever guest happened to be active with nothing
    /// in the answer naming it.
    public let guest: AgentIntegrationGuestReference?
    public let observedAt: Date
    public let freshness: Freshness
    public let referenceAuthority: ReferenceAuthority
    public let processes: [AgentIntegrationObservedProcess]

    public init(sessionID: UUID, guest: AgentIntegrationGuestReference? = nil,
                observedAt: Date,
                freshness: Freshness = .pointInTime,
                referenceAuthority: ReferenceAuthority = .cooperativeQuit,
                processes: [AgentIntegrationObservedProcess]) {
        self.guest = guest
        self.sessionID = sessionID
        self.observedAt = observedAt
        self.freshness = freshness
        self.referenceAuthority = referenceAuthority
        self.processes = processes
    }
}

public struct AgentIntegrationObservedProcess:
    Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case application
        case background
        case finder
        case unknown
    }

    /// Present only when the paired guest supplied a live Process Serial
    /// Number. The token discloses none of that identity and grants only the
    /// right to request a separately revalidated cooperative quit.
    public let reference: String?
    public let name: String
    public let kind: Kind
    public let code: String?
    public let creator: String?
    public let sizeKB: Int?
    public let front: Bool

    public init(reference: String?, name: String, kind: Kind,
                code: String?, creator: String?, sizeKB: Int?,
                front: Bool) {
        self.reference = reference
        self.name = name
        self.kind = kind
        self.code = code
        self.creator = creator
        self.sizeKB = sizeKB
        self.front = front
    }
}
