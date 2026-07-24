import Foundation

public enum AgentIntegrationGuestFilePolicy {
    public static let maximumPathScalars = 223

    public static func isBoundedPath(_ value: String) -> Bool {
        value.unicodeScalars.count <= maximumPathScalars
    }
}

public enum AgentIntegrationGuestFileOperation:
    String, Codable, Equatable, Sendable {
    case capabilities
    case list
    case stat
    case download
    case readText
    case tailText
    case put
    case mkdir
    case move
    case delete
    case deployTree
    case prune
}

public enum AgentIntegrationGuestFileOutcome:
    String, Codable, Equatable, Sendable {
    case success
    case unavailable
    case staleSession
    case notFound
    case scanLimit
    case refused
}

public struct AgentIntegrationGuestFileReceipt:
    Codable, Equatable, Sendable {
    public let commandID: UUID
    public let sessionID: UUID?
    public let policyVersion: Int
    public let operation: AgentIntegrationGuestFileOperation
    public let startedAt: Date
    public let completedAt: Date
    public let outcome: AgentIntegrationGuestFileOutcome
    public let wireRequestCount: Int

    public init(
        commandID: UUID,
        sessionID: UUID?,
        policyVersion: Int,
        operation: AgentIntegrationGuestFileOperation,
        startedAt: Date,
        completedAt: Date,
        outcome: AgentIntegrationGuestFileOutcome,
        wireRequestCount: Int
    ) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.policyVersion = policyVersion
        self.operation = operation
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.wireRequestCount = wireRequestCount
    }
}

public struct AgentIntegrationGuestFileFailure:
    Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum AgentIntegrationGuestFileTransferLaneState:
    String, Codable, Equatable, Sendable {
    case busy
    case unknown
}

public struct AgentIntegrationGuestFileCapabilities:
    Codable, Equatable, Sendable {
    public let guestRoot: String
    public let rootLabel: String?
    public let availableCommands: [AgentIntegrationGuestFileOperation]
    public let deferredCommands: [AgentIntegrationGuestFileOperation]
    public let maximumPageEntries: Int
    public let maximumStatPages: Int
    public let maximumPathBytes: Int
    public let maximumSegmentBytes: Int
    public let transferLaneState:
        AgentIntegrationGuestFileTransferLaneState
    public let observedAt: Date

    public init(
        guestRoot: String,
        rootLabel: String?,
        availableCommands: [AgentIntegrationGuestFileOperation],
        deferredCommands: [AgentIntegrationGuestFileOperation],
        maximumPageEntries: Int,
        maximumStatPages: Int,
        maximumPathBytes: Int,
        maximumSegmentBytes: Int,
        transferLaneState: AgentIntegrationGuestFileTransferLaneState,
        observedAt: Date
    ) {
        self.guestRoot = guestRoot
        self.rootLabel = rootLabel
        self.availableCommands = availableCommands
        self.deferredCommands = deferredCommands
        self.maximumPageEntries = maximumPageEntries
        self.maximumStatPages = maximumStatPages
        self.maximumPathBytes = maximumPathBytes
        self.maximumSegmentBytes = maximumSegmentBytes
        self.transferLaneState = transferLaneState
        self.observedAt = observedAt
    }
}

public struct AgentIntegrationGuestFileEntry:
    Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isFolder: Bool
    public let fileType: String?
    public let creator: String?
    public let dataBytes: Int?
    public let resourceBytes: Int?
    public let modified: Int?

    public init(
        path: String,
        name: String,
        isFolder: Bool,
        fileType: String?,
        creator: String?,
        dataBytes: Int?,
        resourceBytes: Int?,
        modified: Int?
    ) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.fileType = fileType
        self.creator = creator
        self.dataBytes = dataBytes
        self.resourceBytes = resourceBytes
        self.modified = modified
    }
}

public struct AgentIntegrationGuestFileListing:
    Codable, Equatable, Sendable {
    public let path: String
    public let entries: [AgentIntegrationGuestFileEntry]
    public let hasMore: Bool
    public let nextCursor: Int?
    public let rootLabel: String?
    public let observedAt: Date

    public init(
        path: String,
        entries: [AgentIntegrationGuestFileEntry],
        hasMore: Bool,
        nextCursor: Int?,
        rootLabel: String?,
        observedAt: Date
    ) {
        self.path = path
        self.entries = entries
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.rootLabel = rootLabel
        self.observedAt = observedAt
    }
}

public enum AgentIntegrationGuestFileResult<
    Value: Codable & Equatable & Sendable
>: Equatable, Sendable {
    case hostUnavailable(AgentIntegrationUnavailable)
    case completed(
        receipt: AgentIntegrationGuestFileReceipt,
        value: Value?,
        failure: AgentIntegrationGuestFileFailure?)
}

extension AgentIntegrationGuestFileResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case hostAvailable
        case receipt
        case value
        case failure
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .hostAvailable) {
            let receipt = try container.decode(
                AgentIntegrationGuestFileReceipt.self,
                forKey: .receipt)
            let value = try container.decodeIfPresent(
                Value.self, forKey: .value)
            let failure = try container.decodeIfPresent(
                AgentIntegrationGuestFileFailure.self,
                forKey: .failure)
            guard (receipt.outcome == .success && value != nil
                    && failure == nil)
                    || (receipt.outcome != .success && value == nil
                        && failure != nil)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .receipt,
                    in: container,
                    debugDescription:
                        "Guest Files result does not match its receipt")
            }
            self = .completed(
                receipt: receipt, value: value, failure: failure)
        } else {
            self = .hostUnavailable(try container.decode(
                AgentIntegrationUnavailable.self,
                forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostUnavailable(let unavailable):
            try container.encode(false, forKey: .hostAvailable)
            try container.encode(unavailable, forKey: .unavailable)
        case .completed(let receipt, let value, let failure):
            guard (receipt.outcome == .success && value != nil
                    && failure == nil)
                    || (receipt.outcome != .success && value == nil
                        && failure != nil)
            else {
                throw EncodingError.invalidValue(
                    self,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription:
                            "Guest Files result does not match its receipt"))
            }
            try container.encode(true, forKey: .hostAvailable)
            try container.encode(receipt, forKey: .receipt)
            try container.encodeIfPresent(value, forKey: .value)
            try container.encodeIfPresent(failure, forKey: .failure)
        }
    }
}

public typealias AgentIntegrationGuestFileCapabilitiesResult =
    AgentIntegrationGuestFileResult<AgentIntegrationGuestFileCapabilities>
public typealias AgentIntegrationGuestFileListResult =
    AgentIntegrationGuestFileResult<AgentIntegrationGuestFileListing>
public typealias AgentIntegrationGuestFileStatResult =
    AgentIntegrationGuestFileResult<AgentIntegrationGuestFileEntry>
