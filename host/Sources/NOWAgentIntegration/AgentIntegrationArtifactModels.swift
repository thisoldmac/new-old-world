import Foundation

public enum AgentIntegrationArtifactPolicy {
    public static let maximumSourceBytes = 4 * 1024 * 1024
    public static let maximumReceiptAge: TimeInterval = 10 * 60
    public static let maximumTransferResponseWait: TimeInterval = 60 * 60
    public static let maximumNameScalars = 63
    public static let maximumMessageScalars = 160
    public static let maximumFailureCodeScalars = 48
    public static let receiptPrefix = "now-artifact-"
    public static let receiptPattern =
        "^now-artifact-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

    public static func makeReceipt() -> String {
        receiptPrefix + UUID().uuidString.lowercased()
    }

    public static func isValidReceipt(_ value: String) -> Bool {
        guard value == value.lowercased(),
              value.hasPrefix(receiptPrefix),
              value.count == receiptPrefix.count + 36 else {
            return false
        }
        return UUID(uuidString: String(value.dropFirst(receiptPrefix.count)))
            != nil
    }
}

public struct AgentIntegrationArtifactEvidence:
    Codable, Equatable, Sendable {
    public let sha256: String
    public let bytes: Int

    public init(sha256: String, bytes: Int) {
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public struct AgentIntegrationArtifactDeliveryReceipt:
    Codable, Equatable, Sendable {
    public let transferID: UUID
    public let sessionID: UUID
    public let approvedAt: Date
    public let redeemedAt: Date
    public let acknowledgedAt: Date
    public let name: String
    public let source: AgentIntegrationArtifactEvidence
    public let handedToNOW: AgentIntegrationArtifactEvidence
    public let container: String
    public let conversion: String?
    public let guestAcknowledgedWrite: Bool
    public let destinationBytesVerified: Bool
    public let guestMessage: String

    public init(
        transferID: UUID,
        sessionID: UUID,
        approvedAt: Date,
        redeemedAt: Date,
        acknowledgedAt: Date,
        name: String,
        source: AgentIntegrationArtifactEvidence,
        handedToNOW: AgentIntegrationArtifactEvidence,
        container: String,
        conversion: String?,
        guestAcknowledgedWrite: Bool,
        destinationBytesVerified: Bool,
        guestMessage: String
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.approvedAt = approvedAt
        self.redeemedAt = redeemedAt
        self.acknowledgedAt = acknowledgedAt
        self.name = name
        self.source = source
        self.handedToNOW = handedToNOW
        self.container = container
        self.conversion = conversion
        self.guestAcknowledgedWrite = guestAcknowledgedWrite
        self.destinationBytesVerified = destinationBytesVerified
        self.guestMessage = guestMessage
    }
}

public struct AgentIntegrationArtifactFailure:
    Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum AgentIntegrationArtifactTransferResult: Equatable, Sendable {
    case delivered(AgentIntegrationArtifactDeliveryReceipt)
    case unavailable(AgentIntegrationUnavailable)
    case expired(AgentIntegrationArtifactFailure)
    case refused(AgentIntegrationArtifactFailure)
    case failed(AgentIntegrationArtifactFailure)
}

extension AgentIntegrationArtifactTransferResult: Codable {
    private enum Outcome: String, Codable {
        case delivered
        case unavailable
        case expired
        case refused
        case failed
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case delivered
        case unavailable
        case expired
        case refused
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .delivered:
            self = .delivered(try container.decode(
                AgentIntegrationArtifactDeliveryReceipt.self,
                forKey: .delivered))
        case .unavailable:
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        case .expired:
            self = .expired(try container.decode(
                AgentIntegrationArtifactFailure.self, forKey: .expired))
        case .refused:
            self = .refused(try container.decode(
                AgentIntegrationArtifactFailure.self, forKey: .refused))
        case .failed:
            self = .failed(try container.decode(
                AgentIntegrationArtifactFailure.self, forKey: .failed))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delivered(let receipt):
            try container.encode(Outcome.delivered, forKey: .outcome)
            try container.encode(receipt, forKey: .delivered)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        case .expired(let failure):
            try container.encode(Outcome.expired, forKey: .outcome)
            try container.encode(failure, forKey: .expired)
        case .refused(let failure):
            try container.encode(Outcome.refused, forKey: .outcome)
            try container.encode(failure, forKey: .refused)
        case .failed(let failure):
            try container.encode(Outcome.failed, forKey: .outcome)
            try container.encode(failure, forKey: .failed)
        }
    }
}
