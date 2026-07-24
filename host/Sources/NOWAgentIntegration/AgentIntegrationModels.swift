import Foundation

public struct AgentIntegrationUnavailable: Codable, Equatable, Sendable {
    public static let host = AgentIntegrationUnavailable(
        code: "now-host-unavailable",
        message: "New Old World host is unavailable")
    public static let guest = AgentIntegrationUnavailable(
        code: "now-guest-unavailable",
        message: "No paired New Old World guest is connected")

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
        public let name: String
        public let version: String?
        public let operatingSystem: String?
        public let connectedAt: Date?
        public let lastTraffic: Date?
        public let quietFor: TimeInterval?
        public let pingsAnswered: Int?
        public let framesReceived: Int?

        public init(name: String, version: String?,
                    operatingSystem: String?, connectedAt: Date?,
                    lastTraffic: Date?, quietFor: TimeInterval?,
                    pingsAnswered: Int?, framesReceived: Int?) {
            self.name = name
            self.version = version
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
    public let failure: String?

    public init(state: State, observedAt: Date, listeningPort: UInt16?,
                sessionID: UUID?, guest: Guest?, failure: String?) {
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
    public let observedAt: Date
    public let freshness: Freshness
    public let referenceAuthority: ReferenceAuthority
    public let processes: [AgentIntegrationObservedProcess]

    public init(sessionID: UUID, observedAt: Date,
                freshness: Freshness = .pointInTime,
                referenceAuthority: ReferenceAuthority = .cooperativeQuit,
                processes: [AgentIntegrationObservedProcess]) {
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
