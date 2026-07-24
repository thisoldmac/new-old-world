import Foundation

enum GuestFileCommandKind: String, Equatable, Sendable {
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

enum GuestFileCommandOutcome: String, Equatable, Sendable {
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

struct GuestFileCommandReceipt: Equatable, Sendable {
    let commandID: UUID
    let sessionID: UUID?
    let policyVersion: Int
    let operation: GuestFileCommandKind
    let startedAt: Date
    let completedAt: Date
    let outcome: GuestFileCommandOutcome
    let wireRequestCount: Int
    let affectedPaths: [String]

    init(
        commandID: UUID,
        sessionID: UUID?,
        policyVersion: Int,
        operation: GuestFileCommandKind,
        startedAt: Date,
        completedAt: Date,
        outcome: GuestFileCommandOutcome,
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

struct GuestFileCommandFailure: Equatable, Sendable {
    let code: String
    let message: String
    let transferEvidence: GuestFileTransferFailureEvidence?

    init(
        code: String,
        message: String,
        transferEvidence: GuestFileTransferFailureEvidence? = nil
    ) {
        self.code = code
        self.message = message
        self.transferEvidence = transferEvidence
    }
}

struct GuestFileTransferFailureEvidence: Equatable, Sendable {
    let totalBytes: Int
    let acceptedOffset: Int
    let receiverConfirmedBytes: Int?
    let elapsedMs: Int
    let stalledState: String
    let maximumProgressGapMs: Int?
    let progressEvidence: String
    let guestFreeBytesBefore: Int?
    let guestReservedBytes: Int?
    let guestStaging: String?
    let hostStagingCleanup: String
    let guestCleanup: String
}

struct GuestFileCommandResponse<Value> {
    let receipt: GuestFileCommandReceipt
    let value: Value?
    let failure: GuestFileCommandFailure?
}

struct GuestFileCapabilities: Equatable, Sendable {
    let guestRoot: String
    let rootLabel: String?
    let availableCommands: [GuestFileCommandKind]
    let deferredCommands: [GuestFileCommandKind]
    let maximumPageEntries: Int
    let maximumStatPages: Int
    let maximumPathBytes: Int
    let maximumSegmentBytes: Int
    let transferLaneState: String
    let observedAt: Date
}

struct GuestFileObservedEntry: Equatable, Sendable {
    let path: String
    let name: String
    let isFolder: Bool
    let fileType: String?
    let creator: String?
    let dataBytes: Int?
    let resourceBytes: Int?
    let modified: Int?
    /// Host-minted handle for this exact guest observation. The guest's
    /// catalog token stays private to the command layer.
    let observationReference: String?
}

struct GuestFileMutationPrecondition: Equatable, Sendable {
    let sessionID: UUID
    let policyVersion: Int
    let path: String
    let guestIdentity: String
}

struct GuestFileListingSnapshot: Equatable, Sendable {
    let path: String
    let entries: [GuestFileObservedEntry]
    let hasMore: Bool
    let nextCursor: Int?
    let rootLabel: String?
    let observedAt: Date
}

struct GuestFileUploadBeginRequest: Equatable, Sendable {
    let destinationPath: String
    let bytes: Int
    let sha256: String
    let container: String
    let fileType: String?
    let creator: String?
    let modified: Int?
}

struct GuestFileUploadStageStatus: Equatable, Sendable {
    let uploadID: UUID
    let destinationPath: String
    let expectedBytes: Int
    let receivedBytes: Int
    let maximumChunkBytes: Int
    let expiresAt: Date
    let hostAvailableBytesAtStart: Int64
    let hostReservedBytes: Int
    let sealed: Bool
}

struct GuestFileUploadTransferReceipt: Equatable, Sendable {
    let uploadID: UUID
    let destinationPath: String
    let container: String
    let sha256: String
    let totalBytes: Int
    let acceptedOffset: Int
    let receiverConfirmedBytes: Int
    let elapsedMs: Int
    let averageBytesPerSecond: Int
    let stalledState: String
    let maximumProgressGapMs: Int?
    let progressEvidence: String
    let guestFreeBytesBefore: Int?
    let guestReservedBytes: Int?
    let guestStaging: String?
    let finalization: String
    let destinationAcknowledged: Bool
    let integrity: String
    let hostStagingCleanup: String
    let guestCleanup: String
}
