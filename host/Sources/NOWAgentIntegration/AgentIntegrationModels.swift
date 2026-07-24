import Foundation

public struct AgentIntegrationUnavailable: Codable, Equatable, Sendable {
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
        .unavailable(.init(
            code: "now-host-unavailable",
            message: "New Old World host is unavailable"))
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
