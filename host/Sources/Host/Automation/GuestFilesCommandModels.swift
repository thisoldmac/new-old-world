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
}

struct GuestFileCommandFailure: Equatable, Sendable {
    let code: String
    let message: String
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
}

struct GuestFileListingSnapshot: Equatable, Sendable {
    let path: String
    let entries: [GuestFileObservedEntry]
    let hasMore: Bool
    let nextCursor: Int?
    let rootLabel: String?
    let observedAt: Date
}
