import Foundation

public enum AgentIntegrationMirrorReadIntention: String, Codable, Sendable {
    case status
    case snapshot
    case find
    case wait
    /// The act and scene-cycle clocks the Mirror page shows.
    ///
    /// Not a diagnostic extra. The Mirror window and MCP are two clients
    /// of one state engine, differing only in pixels and input method —
    /// so a measurement a person can read off the Mirror page and an
    /// agent cannot is drift, and it is the drift that matters most for
    /// a headless run, because an agent driving without it cannot tell a
    /// queued act from a slow machine.
    case metrics
}

public struct AgentIntegrationMirrorReadRequest:
    Codable, Equatable, Sendable {
    public let intention: AgentIntegrationMirrorReadIntention
    public let query: String?
    public let afterSnapshotID: Int?
    public let timeoutMs: Int?

    public init(intention: AgentIntegrationMirrorReadIntention,
                query: String? = nil, afterSnapshotID: Int? = nil,
                timeoutMs: Int? = nil) {
        self.intention = intention
        self.query = query
        self.afterSnapshotID = afterSnapshotID
        self.timeoutMs = timeoutMs
    }

    public var isWellFormed: Bool {
        switch intention {
        case .status, .snapshot:
            return query == nil && afterSnapshotID == nil && timeoutMs == nil
        case .find:
            return query?.isEmpty == false && query!.count <= 128
                && afterSnapshotID == nil && timeoutMs == nil
        case .wait:
            return query == nil && (afterSnapshotID ?? 0) > 0
                && (1...15_000).contains(timeoutMs ?? 5_000)
        case .metrics:
            return query == nil && afterSnapshotID == nil && timeoutMs == nil
        }
    }
}

public struct AgentIntegrationMirrorSnapshotMetadata:
    Codable, Equatable, Sendable {
    public let guest: String
    public let session: String
    public let snapshotID: Int
    public let sequence: Int
    public let digest: String
    public let baseComplete: Bool
    public let sceneGeneration: Int
    public let contentGeneration: Int

    public init(guest: String, session: String, snapshotID: Int,
                sequence: Int, digest: String, baseComplete: Bool,
                sceneGeneration: Int, contentGeneration: Int) {
        self.guest = guest
        self.session = session
        self.snapshotID = snapshotID
        self.sequence = sequence
        self.digest = digest
        self.baseComplete = baseComplete
        self.sceneGeneration = sceneGeneration
        self.contentGeneration = contentGeneration
    }
}

public struct AgentIntegrationMirrorCoverage:
    Codable, Equatable, Sendable {
    public let scope: String
    public let owner: String?
    public let status: String
    public let reason: String?

    public init(scope: String, owner: String?, status: String,
                reason: String?) {
        self.scope = scope
        self.owner = owner
        self.status = status
        self.reason = reason
    }
}

public struct AgentIntegrationMirrorEntity:
    Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case process, window }

    public let id: String
    public let kind: Kind
    public let ownerID: String?
    public let name: String
    public let title: String?
    public let front: Bool
    /// nil is honest unknown: process visibility is a separate retained
    /// guest observation, not something the structural roster implies.
    public let visible: Bool?
    public let freshness: String
    public let actionable: Bool

    public init(id: String, kind: Kind, ownerID: String?, name: String,
                title: String?, front: Bool, visible: Bool?,
                freshness: String, actionable: Bool) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.name = name
        self.title = title
        self.front = front
        self.visible = visible
        self.freshness = freshness
        self.actionable = actionable
    }
}

public struct AgentIntegrationMirrorMenuItem:
    Codable, Equatable, Sendable {
    public let title: String
    public let index: Int
    public let separator: Bool
    public let enabled: Bool
    public let marked: Bool
    public let command: String

    public init(title: String, index: Int, separator: Bool, enabled: Bool,
                marked: Bool, command: String) {
        self.title = title
        self.index = index
        self.separator = separator
        self.enabled = enabled
        self.marked = marked
        self.command = command
    }
}

public struct AgentIntegrationMirrorMenu:
    Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let apple: Bool
    public let left: Int
    public let items: [AgentIntegrationMirrorMenuItem]

    public init(id: Int, title: String, apple: Bool, left: Int,
                items: [AgentIntegrationMirrorMenuItem]) {
        self.id = id
        self.title = title
        self.apple = apple
        self.left = left
        self.items = items
    }
}

public struct AgentIntegrationMirrorSnapshot:
    Codable, Equatable, Sendable {
    public let metadata: AgentIntegrationMirrorSnapshotMetadata
    public let coverage: [AgentIntegrationMirrorCoverage]
    public let entities: [AgentIntegrationMirrorEntity]
    public let menus: [AgentIntegrationMirrorMenu]

    public init(metadata: AgentIntegrationMirrorSnapshotMetadata,
                coverage: [AgentIntegrationMirrorCoverage],
                entities: [AgentIntegrationMirrorEntity],
                menus: [AgentIntegrationMirrorMenu]) {
        self.metadata = metadata
        self.coverage = coverage
        self.entities = entities
        self.menus = menus
    }
}

/// One act's four clocks, as the Mirror page shows them.
///
/// `-1` is never used for "did not happen": an absent settle and a settle
/// of zero are opposite results, so the field is simply absent. The same
/// rule the `NOWBASE` line follows with `-`.
public struct AgentIntegrationMirrorActMetric:
    Codable, Equatable, Sendable {
    public let kind: String
    public let operationID: String
    public let label: String
    public let outcome: String
    public let queueDepthAtEntry: Int
    public let waitedMs: Int?
    public let dispatchMs: Int?
    public let settleMs: Int?
    public let totalMs: Int

    public init(kind: String, operationID: String, label: String,
                outcome: String, queueDepthAtEntry: Int,
                waitedMs: Int?, dispatchMs: Int?, settleMs: Int?,
                totalMs: Int) {
        self.kind = kind
        self.operationID = operationID
        self.label = label
        self.outcome = outcome
        self.queueDepthAtEntry = queueDepthAtEntry
        self.waitedMs = waitedMs
        self.dispatchMs = dispatchMs
        self.settleMs = settleMs
        self.totalMs = totalMs
    }
}

/// One scene cycle. `walk` names which planes were asked for, because a
/// structure-only poll and a full walk are different amounts of work on
/// the classic Mac and must not be averaged together.
public struct AgentIntegrationMirrorCycleMetric:
    Codable, Equatable, Sendable {
    public let walk: String
    public let outcome: String
    public let idleMs: Int?
    public let requestMs: Int?
    public let decodeMs: Int?
    public let totalMs: Int
    public let windows: Int?
    public let elements: Int?

    public init(walk: String, outcome: String, idleMs: Int?,
                requestMs: Int?, decodeMs: Int?, totalMs: Int,
                windows: Int?, elements: Int?) {
        self.walk = walk
        self.outcome = outcome
        self.idleMs = idleMs
        self.requestMs = requestMs
        self.decodeMs = decodeMs
        self.totalMs = totalMs
        self.windows = windows
        self.elements = elements
    }
}

public struct AgentIntegrationMirrorMetrics:
    Codable, Equatable, Sendable {
    /// Acts queued or in flight right now. `0` means the next act reaches
    /// the Mac immediately; above zero, a slow gesture is waiting on the
    /// lane rather than on the machine.
    public let laneDepth: Int
    public let acts: [AgentIntegrationMirrorActMetric]
    public let cycles: [AgentIntegrationMirrorCycleMetric]

    public init(laneDepth: Int,
                acts: [AgentIntegrationMirrorActMetric],
                cycles: [AgentIntegrationMirrorCycleMetric]) {
        self.laneDepth = laneDepth
        self.acts = acts
        self.cycles = cycles
    }
}

public struct AgentIntegrationMirrorReadValue:
    Codable, Equatable, Sendable {
    public let intention: AgentIntegrationMirrorReadIntention
    public let current: AgentIntegrationMirrorSnapshotMetadata?
    public let snapshot: AgentIntegrationMirrorSnapshot?
    public let matches: [AgentIntegrationMirrorEntity]?
    public let metrics: AgentIntegrationMirrorMetrics?
    public let timedOut: Bool

    public init(intention: AgentIntegrationMirrorReadIntention,
                current: AgentIntegrationMirrorSnapshotMetadata?,
                snapshot: AgentIntegrationMirrorSnapshot? = nil,
                matches: [AgentIntegrationMirrorEntity]? = nil,
                metrics: AgentIntegrationMirrorMetrics? = nil,
                timedOut: Bool = false) {
        self.intention = intention
        self.current = current
        self.snapshot = snapshot
        self.matches = matches
        self.metrics = metrics
        self.timedOut = timedOut
    }
}

public struct AgentIntegrationMirrorReadResult:
    Codable, Equatable, Sendable {
    public let available: Bool
    public let value: AgentIntegrationMirrorReadValue?
    public let unavailable: AgentIntegrationUnavailable?

    public init(value: AgentIntegrationMirrorReadValue) {
        available = true
        self.value = value
        unavailable = nil
    }

    public init(unavailable: AgentIntegrationUnavailable) {
        available = false
        value = nil
        self.unavailable = unavailable
    }
}
