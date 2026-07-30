import Foundation

public enum AgentIntegrationGuestFilePolicy {
    public static let maximumPathScalars = 223
    public static let maximumObservationReferenceScalars = 45
    public static let maximumUploadChunkBytes = 8 * 1024
    public static let maximumUploadChunkBase64Scalars =
        ((maximumUploadChunkBytes + 2) / 3) * 4

    public static func isBoundedPath(_ value: String) -> Bool {
        value.unicodeScalars.count <= maximumPathScalars
    }

    public static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    public static func isClassicOSType(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.unicodeScalars.count == 4
            && value.data(
                using: .macOSRoman, allowLossyConversion: false) != nil
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
    /// To the Trash and back out of it. Distinct from `delete`, and the
    /// distinction is the whole point of the pair: a trashed item is still
    /// there, named by where it landed, and `restore` is the only thing
    /// that name is good for.
    case trash
    case restore
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
    case expired
    case conflict
    case failed
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
    public let affectedPaths: [String]

    public init(
        commandID: UUID,
        sessionID: UUID?,
        policyVersion: Int,
        operation: AgentIntegrationGuestFileOperation,
        startedAt: Date,
        completedAt: Date,
        outcome: AgentIntegrationGuestFileOutcome,
        wireRequestCount: Int,
        affectedPaths: [String] = []
    ) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.policyVersion = policyVersion
        self.operation = operation
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.wireRequestCount = wireRequestCount
        self.affectedPaths = affectedPaths
    }
}

public struct AgentIntegrationGuestFileFailure:
    Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let transferEvidence:
        AgentIntegrationGuestFileTransferFailureEvidence?

    public init(
        code: String,
        message: String,
        transferEvidence:
            AgentIntegrationGuestFileTransferFailureEvidence? = nil
    ) {
        self.code = code
        self.message = message
        self.transferEvidence = transferEvidence
    }
}

public struct AgentIntegrationGuestFileTransferFailureEvidence:
    Codable, Equatable, Sendable {
    public let totalBytes: Int
    public let acceptedOffset: Int
    public let receiverConfirmedBytes: Int?
    public let elapsedMs: Int
    public let stalledState: String
    public let maximumProgressGapMs: Int?
    public let progressEvidence: String
    public let guestFreeBytesBefore: Int?
    public let guestReservedBytes: Int?
    public let guestStaging: String?
    public let hostStagingCleanup: String
    public let guestCleanup: String

    public init(
        totalBytes: Int,
        acceptedOffset: Int,
        receiverConfirmedBytes: Int?,
        elapsedMs: Int,
        stalledState: String,
        maximumProgressGapMs: Int?,
        progressEvidence: String,
        guestFreeBytesBefore: Int?,
        guestReservedBytes: Int?,
        guestStaging: String?,
        hostStagingCleanup: String,
        guestCleanup: String
    ) {
        self.totalBytes = totalBytes
        self.acceptedOffset = acceptedOffset
        self.receiverConfirmedBytes = receiverConfirmedBytes
        self.elapsedMs = elapsedMs
        self.stalledState = stalledState
        self.maximumProgressGapMs = maximumProgressGapMs
        self.progressEvidence = progressEvidence
        self.guestFreeBytesBefore = guestFreeBytesBefore
        self.guestReservedBytes = guestReservedBytes
        self.guestStaging = guestStaging
        self.hostStagingCleanup = hostStagingCleanup
        self.guestCleanup = guestCleanup
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
    public let observationReference: String?

    public init(
        path: String,
        name: String,
        isFolder: Bool,
        fileType: String?,
        creator: String?,
        dataBytes: Int?,
        resourceBytes: Int?,
        modified: Int?,
        observationReference: String? = nil
    ) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.fileType = fileType
        self.creator = creator
        self.dataBytes = dataBytes
        self.resourceBytes = resourceBytes
        self.modified = modified
        self.observationReference = observationReference
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

public struct AgentIntegrationGuestFileUploadBegin:
    Codable, Equatable, Sendable {
    public let destinationPath: String
    public let bytes: Int
    public let sha256: String
    public let container: String
    public let fileType: String?
    public let creator: String?
    public let modified: Int?

    public init(
        destinationPath: String,
        bytes: Int,
        sha256: String,
        container: String,
        fileType: String? = nil,
        creator: String? = nil,
        modified: Int? = nil
    ) {
        self.destinationPath = destinationPath
        self.bytes = bytes
        self.sha256 = sha256
        self.container = container
        self.fileType = fileType
        self.creator = creator
        self.modified = modified
    }
}

public struct AgentIntegrationGuestFileUploadStage:
    Codable, Equatable, Sendable {
    public let uploadID: UUID
    public let destinationPath: String
    public let expectedBytes: Int
    public let receivedBytes: Int
    public let maximumChunkBytes: Int
    public let expiresAt: Date
    public let hostAvailableBytesAtStart: Int64
    public let hostReservedBytes: Int
    public let sealed: Bool

    public init(
        uploadID: UUID,
        destinationPath: String,
        expectedBytes: Int,
        receivedBytes: Int,
        maximumChunkBytes: Int,
        expiresAt: Date,
        hostAvailableBytesAtStart: Int64,
        hostReservedBytes: Int,
        sealed: Bool
    ) {
        self.uploadID = uploadID
        self.destinationPath = destinationPath
        self.expectedBytes = expectedBytes
        self.receivedBytes = receivedBytes
        self.maximumChunkBytes = maximumChunkBytes
        self.expiresAt = expiresAt
        self.hostAvailableBytesAtStart = hostAvailableBytesAtStart
        self.hostReservedBytes = hostReservedBytes
        self.sealed = sealed
    }
}

public struct AgentIntegrationGuestFileUploadReceipt:
    Codable, Equatable, Sendable {
    public let uploadID: UUID
    public let destinationPath: String
    public let container: String
    public let sha256: String
    public let totalBytes: Int
    public let acceptedOffset: Int
    public let receiverConfirmedBytes: Int
    public let elapsedMs: Int
    public let averageBytesPerSecond: Int
    public let stalledState: String
    public let maximumProgressGapMs: Int?
    public let progressEvidence: String
    public let guestFreeBytesBefore: Int?
    public let guestReservedBytes: Int?
    public let guestStaging: String?
    public let finalization: String
    public let destinationAcknowledged: Bool
    public let integrity: String
    public let hostStagingCleanup: String
    public let guestCleanup: String

    public init(
        uploadID: UUID,
        destinationPath: String,
        container: String,
        sha256: String,
        totalBytes: Int,
        acceptedOffset: Int,
        receiverConfirmedBytes: Int,
        elapsedMs: Int,
        averageBytesPerSecond: Int,
        stalledState: String,
        maximumProgressGapMs: Int?,
        progressEvidence: String,
        guestFreeBytesBefore: Int?,
        guestReservedBytes: Int?,
        guestStaging: String?,
        finalization: String,
        destinationAcknowledged: Bool,
        integrity: String,
        hostStagingCleanup: String,
        guestCleanup: String
    ) {
        self.uploadID = uploadID
        self.destinationPath = destinationPath
        self.container = container
        self.sha256 = sha256
        self.totalBytes = totalBytes
        self.acceptedOffset = acceptedOffset
        self.receiverConfirmedBytes = receiverConfirmedBytes
        self.elapsedMs = elapsedMs
        self.averageBytesPerSecond = averageBytesPerSecond
        self.stalledState = stalledState
        self.maximumProgressGapMs = maximumProgressGapMs
        self.progressEvidence = progressEvidence
        self.guestFreeBytesBefore = guestFreeBytesBefore
        self.guestReservedBytes = guestReservedBytes
        self.guestStaging = guestStaging
        self.finalization = finalization
        self.destinationAcknowledged = destinationAcknowledged
        self.integrity = integrity
        self.hostStagingCleanup = hostStagingCleanup
        self.guestCleanup = guestCleanup
    }
}

public typealias AgentIntegrationGuestFileUploadStageResult =
    AgentIntegrationGuestFileResult<AgentIntegrationGuestFileUploadStage>
public typealias AgentIntegrationGuestFileUploadCommitResult =
    AgentIntegrationGuestFileResult<AgentIntegrationGuestFileUploadReceipt>
