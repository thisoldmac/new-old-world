import Foundation

public enum AgentIntegrationLaunchSelection: Equatable, Sendable {
    case name(String)
    case reference(String)
}

extension AgentIntegrationLaunchSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case reference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let reference = try container.decodeIfPresent(
            String.self, forKey: .reference)
        switch (name, reference) {
        case (.some(let value), .none):
            self = .name(value)
        case (.none, .some(let value)):
            self = .reference(value)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription:
                    "Launch selection requires exactly one name or reference"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .name(let name):
            try container.encode(name, forKey: .name)
        case .reference(let reference):
            try container.encode(reference, forKey: .reference)
        }
    }
}

public struct AgentIntegrationSoftwareCandidate:
    Codable, Equatable, Sendable {
    public let reference: String
    public let name: String
    public let version: String?
    public let type: String?
    public let creator: String?
    public let running: Bool

    public init(reference: String, name: String, version: String?,
                type: String?, creator: String?, running: Bool) {
        self.reference = reference
        self.name = name
        self.version = version
        self.type = type
        self.creator = creator
        self.running = running
    }
}

public struct AgentIntegrationLaunchReceipt:
    Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let catalogObservedAt: Date
    public let acknowledgedAt: Date
    public let software: AgentIntegrationSoftwareCandidate
    public let guestMessage: String

    public init(sessionID: UUID, catalogObservedAt: Date,
                acknowledgedAt: Date,
                software: AgentIntegrationSoftwareCandidate,
                guestMessage: String) {
        self.sessionID = sessionID
        self.catalogObservedAt = catalogObservedAt
        self.acknowledgedAt = acknowledgedAt
        self.software = software
        self.guestMessage = guestMessage
    }
}

public struct AgentIntegrationLaunchAmbiguity:
    Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let matchCount: Int
    public let candidates: [AgentIntegrationSoftwareCandidate]

    public init(code: String, message: String, matchCount: Int,
                candidates: [AgentIntegrationSoftwareCandidate]) {
        self.code = code
        self.message = message
        self.matchCount = matchCount
        self.candidates = candidates
    }
}

public struct AgentIntegrationLaunchFailure:
    Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum AgentIntegrationLaunchSoftwareResult: Equatable, Sendable {
    case launched(AgentIntegrationLaunchReceipt)
    case unavailable(AgentIntegrationUnavailable)
    case ambiguous(AgentIntegrationLaunchAmbiguity)
    case notFound(AgentIntegrationLaunchFailure)
    case refused(AgentIntegrationLaunchFailure)
}

extension AgentIntegrationLaunchSoftwareResult: Codable {
    private enum Outcome: String, Codable {
        case launched
        case unavailable
        case ambiguous
        case notFound
        case refused
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case launched
        case unavailable
        case ambiguous
        case notFound
        case refused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .launched:
            self = .launched(try container.decode(
                AgentIntegrationLaunchReceipt.self, forKey: .launched))
        case .unavailable:
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        case .ambiguous:
            self = .ambiguous(try container.decode(
                AgentIntegrationLaunchAmbiguity.self, forKey: .ambiguous))
        case .notFound:
            self = .notFound(try container.decode(
                AgentIntegrationLaunchFailure.self, forKey: .notFound))
        case .refused:
            self = .refused(try container.decode(
                AgentIntegrationLaunchFailure.self, forKey: .refused))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .launched(let receipt):
            try container.encode(Outcome.launched, forKey: .outcome)
            try container.encode(receipt, forKey: .launched)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        case .ambiguous(let ambiguity):
            try container.encode(Outcome.ambiguous, forKey: .outcome)
            try container.encode(ambiguity, forKey: .ambiguous)
        case .notFound(let failure):
            try container.encode(Outcome.notFound, forKey: .outcome)
            try container.encode(failure, forKey: .notFound)
        case .refused(let failure):
            try container.encode(Outcome.refused, forKey: .outcome)
            try container.encode(failure, forKey: .refused)
        }
    }
}
