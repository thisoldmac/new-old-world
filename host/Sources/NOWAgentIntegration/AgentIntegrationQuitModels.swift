import Foundation

public enum AgentIntegrationQuitPolicy {
    public static let maximumReferenceAge: TimeInterval = 30
    public static let maximumNameScalars = 32
    public static let maximumMessageScalars = 160
    public static let maximumFailureCodeScalars = 48
    public static let referencePrefix = "now-process-"
    public static let referencePattern =
        "^now-process-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

    public static func makeReference() -> String {
        referencePrefix + UUID().uuidString.lowercased()
    }

    public static func isValidReference(_ value: String) -> Bool {
        guard value == value.lowercased(),
              value.hasPrefix(referencePrefix),
              value.count == referencePrefix.count + 36 else {
            return false
        }
        return UUID(uuidString: String(value.dropFirst(referencePrefix.count)))
            != nil
    }
}

public struct AgentIntegrationQuitProcess:
    Codable, Equatable, Sendable {
    public let reference: String
    public let name: String
    public let kind: AgentIntegrationObservedProcess.Kind
    public let code: String?
    public let creator: String?

    public init(reference: String, name: String,
                kind: AgentIntegrationObservedProcess.Kind,
                code: String?, creator: String?) {
        self.reference = reference
        self.name = name
        self.kind = kind
        self.code = code
        self.creator = creator
    }
}

public struct AgentIntegrationQuitReceipt:
    Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let snapshotObservedAt: Date
    public let revalidatedAt: Date
    public let acknowledgedAt: Date
    public let process: AgentIntegrationQuitProcess
    public let guestMessage: String

    public init(sessionID: UUID, snapshotObservedAt: Date,
                revalidatedAt: Date, acknowledgedAt: Date,
                process: AgentIntegrationQuitProcess,
                guestMessage: String) {
        self.sessionID = sessionID
        self.snapshotObservedAt = snapshotObservedAt
        self.revalidatedAt = revalidatedAt
        self.acknowledgedAt = acknowledgedAt
        self.process = process
        self.guestMessage = guestMessage
    }
}

public struct AgentIntegrationQuitFailure:
    Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum AgentIntegrationQuitResult: Equatable, Sendable {
    case requestSent(AgentIntegrationQuitReceipt)
    case unavailable(AgentIntegrationUnavailable)
    case stale(AgentIntegrationQuitFailure)
    case notFound(AgentIntegrationQuitFailure)
    case refused(AgentIntegrationQuitFailure)
}

extension AgentIntegrationQuitResult: Codable {
    private enum Outcome: String, Codable {
        case requestSent
        case unavailable
        case stale
        case notFound
        case refused
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case requestSent
        case unavailable
        case stale
        case notFound
        case refused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .requestSent:
            self = .requestSent(try container.decode(
                AgentIntegrationQuitReceipt.self, forKey: .requestSent))
        case .unavailable:
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        case .stale:
            self = .stale(try container.decode(
                AgentIntegrationQuitFailure.self, forKey: .stale))
        case .notFound:
            self = .notFound(try container.decode(
                AgentIntegrationQuitFailure.self, forKey: .notFound))
        case .refused:
            self = .refused(try container.decode(
                AgentIntegrationQuitFailure.self, forKey: .refused))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .requestSent(let receipt):
            try container.encode(Outcome.requestSent, forKey: .outcome)
            try container.encode(receipt, forKey: .requestSent)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        case .stale(let failure):
            try container.encode(Outcome.stale, forKey: .outcome)
            try container.encode(failure, forKey: .stale)
        case .notFound(let failure):
            try container.encode(Outcome.notFound, forKey: .outcome)
            try container.encode(failure, forKey: .notFound)
        case .refused(let failure):
            try container.encode(Outcome.refused, forKey: .outcome)
            try container.encode(failure, forKey: .refused)
        }
    }
}
