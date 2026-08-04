import Foundation

public enum MirrorOperationSource: String, Codable, Equatable, Sendable {
    case human
    case mcp
}

public enum MirrorOperationPostcondition: Equatable, Sendable {
    case windowAbsent(MirrorWindowIdentity)
    case processAbsent(MirrorProcessIdentity)
    case processFront(MirrorProcessIdentity)
}

public enum MirrorOperationOutcome: String, Codable, Equatable, Sendable {
    case queued
    case dispatched
    case refused
    case timedOut
    case confirmed
    case confirmedAfterTimeout
    case sessionChanged

    public var isTerminal: Bool {
        switch self {
        case .refused, .confirmed, .confirmedAfterTimeout, .sessionChanged:
            return true
        case .queued, .dispatched, .timedOut:
            return false
        }
    }
}

public struct MirrorOperation: Equatable, Sendable {
    public var id: String
    public var source: MirrorOperationSource
    public var displayedSnapshotID: Int
    public var displayedSequence: Int
    public var target: MirrorEntityIdentity
    public var postcondition: MirrorOperationPostcondition
    public var enqueuedAt: Date
    public var dispatchedAt: Date?
    public var settledAt: Date?
    public var settledSequence: Int?
    public var outcome: MirrorOperationOutcome
    public var reason: String?

    public init(id: String, source: MirrorOperationSource,
                displayedSnapshotID: Int, displayedSequence: Int,
                target: MirrorEntityIdentity,
                postcondition: MirrorOperationPostcondition,
                enqueuedAt: Date) {
        self.id = id
        self.source = source
        self.displayedSnapshotID = displayedSnapshotID
        self.displayedSequence = displayedSequence
        self.target = target
        self.postcondition = postcondition
        self.enqueuedAt = enqueuedAt
        self.outcome = .queued
    }

    public var session: MirrorGuestSession {
        switch target {
        case .process(let identity): return identity.session
        case .window(let identity): return identity.process.session
        }
    }
}

public struct MirrorSettlementEvidence: Equatable, Sendable {
    public var session: MirrorGuestSession
    public var sequence: Int
    public var coverage: Scene.CoverageClaim
    public var receivedAt: Date?
    public var presentProcesses: Set<MirrorProcessIdentity>
    public var presentWindows: Set<MirrorWindowIdentity>
    public var frontProcess: MirrorProcessIdentity?

    public init(session: MirrorGuestSession, sequence: Int,
                coverage: Scene.CoverageClaim,
                receivedAt: Date? = nil,
                presentProcesses: Set<MirrorProcessIdentity> = [],
                presentWindows: Set<MirrorWindowIdentity> = [],
                frontProcess: MirrorProcessIdentity? = nil) {
        self.session = session
        self.sequence = sequence
        self.coverage = coverage
        self.receivedAt = receivedAt
        self.presentProcesses = presentProcesses
        self.presentWindows = presentWindows
        self.frontProcess = frontProcess
    }
}

public enum MirrorOperationEvent: Equatable, Sendable {
    case dispatched(at: Date)
    case refused(reason: String, at: Date)
    case timedOut(at: Date)
    case observation(MirrorSettlementEvidence)
    case sessionChanged(at: Date)
}
