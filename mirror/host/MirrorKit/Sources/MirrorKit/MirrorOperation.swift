import Foundation

public enum MirrorOperationSource: String, Codable, Equatable, Sendable {
    case human
    case mcp
}

public enum MirrorOperationPostcondition: Equatable, Sendable {
    case windowAbsent(MirrorWindowIdentity)
    case windowFront(MirrorWindowIdentity)
    case windowNamedPresent(owner: MirrorProcessIdentity, title: String)
    case processAbsent(MirrorProcessIdentity)
    case processFront(MirrorProcessIdentity)
    case processNamedPresent(String)
    /// Exact visibility expectations for the processes affected by one
    /// Application-menu command. Dispatch cannot satisfy this condition;
    /// only a later complete guest observation can.
    case processVisibility([MirrorProcessIdentity: Bool])
}

public enum MirrorOperationOutcome: String, Codable, Equatable, Sendable {
    case queued
    case dispatched
    case awaitingEvidenceAfterRefusal
    case refused
    case timedOut
    case confirmed
    case confirmedAfterTimeout
    case confirmedAfterRefusal
    case sessionChanged

    public var isTerminal: Bool {
        switch self {
        case .refused, .confirmed, .confirmedAfterTimeout,
             .confirmedAfterRefusal, .sessionChanged:
            return true
        case .queued, .dispatched, .awaitingEvidenceAfterRefusal, .timedOut:
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
    public var frontWindow: MirrorWindowIdentity?
    public var windowTitles: [MirrorWindowIdentity: String]
    public var processVisibility: [MirrorProcessIdentity: Bool]
    public var processNames: [MirrorProcessIdentity: String]

    public init(session: MirrorGuestSession, sequence: Int,
                coverage: Scene.CoverageClaim,
                receivedAt: Date? = nil,
                presentProcesses: Set<MirrorProcessIdentity> = [],
                presentWindows: Set<MirrorWindowIdentity> = [],
                frontProcess: MirrorProcessIdentity? = nil,
                frontWindow: MirrorWindowIdentity? = nil,
                windowTitles: [MirrorWindowIdentity: String] = [:],
                processVisibility: [MirrorProcessIdentity: Bool] = [:],
                processNames: [MirrorProcessIdentity: String] = [:]) {
        self.session = session
        self.sequence = sequence
        self.coverage = coverage
        self.receivedAt = receivedAt
        self.presentProcesses = presentProcesses
        self.presentWindows = presentWindows
        self.frontProcess = frontProcess
        self.frontWindow = frontWindow
        self.windowTitles = windowTitles
        self.processVisibility = processVisibility
        self.processNames = processNames
    }
}

public enum MirrorOperationEvent: Equatable, Sendable {
    case dispatched(at: Date)
    /// A refusal before any part of the operation could mutate the guest is
    /// terminal. A refusal after dispatch (including a later stage of a
    /// composite operation) is contradictory attempt evidence and remains
    /// eligible for an authoritative postcondition observation.
    case refused(reason: String, at: Date, effectMayHaveLanded: Bool = false)
    case timedOut(at: Date)
    case observation(MirrorSettlementEvidence)
    case sessionChanged(at: Date)
}
