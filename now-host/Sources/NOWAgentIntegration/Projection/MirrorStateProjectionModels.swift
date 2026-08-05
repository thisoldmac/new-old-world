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
    /// Plane policy and the resident's own bits, plus its build. The Mirror
    /// page shows all of it and a headless client could not see any of it —
    /// and on 2026-08-04 a PowerBook answered from a stale `Now Extension`
    /// beside the new `NowExt`, refusing every act as "the anchor plane is
    /// absent or not armed", while the host knew the resident's build the
    /// whole time and never said it.
    case lifecycle
    /// Every operation the Mirror has recorded this session, whichever face
    /// drove it. The clocks in `metrics` say how long; this says what was
    /// asked, of what, by whom, and how it ended.
    case journal
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
        case .metrics, .lifecycle, .journal:
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

public struct AgentIntegrationMirrorRect: Codable, Equatable, Sendable {
    public let l: Int
    public let t: Int
    public let r: Int
    public let b: Int

    public init(l: Int, t: Int, r: Int, b: Int) {
        self.l = l
        self.t = t
        self.r = r
        self.b = b
    }
}

/// One drawable thing inside a window, as the renderer receives it.
///
/// `kind` is the field that decides how it is DRAWN — a checkbox, a radio,
/// a popup, a push button — and it comes from the IR's semantic evidence
/// rather than from the role. Absent means the producer could not read the
/// control's defProc and so cannot say; that is a different fact from
/// "a plain control", and it is the fact behind a Date & Time panel whose
/// radios rendered as push buttons.
public struct AgentIntegrationMirrorSurfaceItem:
    Codable, Equatable, Sendable {
    /// `control` or `dialogItem` — different actuation paths on the Mac,
    /// so never flattened into one list without saying which.
    public let source: String
    public let ref: String?
    public let role: String?
    public let title: String
    public let rect: AgentIntegrationMirrorRect?
    public let enabled: Bool
    public let visible: Bool
    public let value: Int?
    public let checked: Bool?
    public let kind: String?
    public let state: String?
    /// The semantic VALUE — a field's text, a popup's chosen row. The thing
    /// that was missing from every rendered form in the 2026-08-03 sweep,
    /// and which no entity-level projection could ever have shown.
    public let text: String?
    public let knowledge: String?
    /// Where the control's definition function came from — `system`,
    /// `application` or `indeterminate` — carried only where `kind` is
    /// absent. A strictly weaker claim than `kind`: `system` says a
    /// documented answer exists somewhere, never that this is a push
    /// button, so it can never authorise an act. It is here because
    /// splitting the undetermined population is a measurement an agent
    /// has to be able to take, and the face that takes it is this one.
    public let definition: String?
    /// 1-based DITL number, for a dialog item.
    public let number: Int?

    public init(source: String, ref: String?, role: String?, title: String,
                rect: AgentIntegrationMirrorRect?, enabled: Bool,
                visible: Bool, value: Int?, checked: Bool?, kind: String?,
                state: String?, text: String?, knowledge: String?,
                definition: String? = nil,
                number: Int?) {
        self.source = source
        self.ref = ref
        self.role = role
        self.title = title
        self.rect = rect
        self.enabled = enabled
        self.visible = visible
        self.value = value
        self.checked = checked
        self.kind = kind
        self.state = state
        self.text = text
        self.knowledge = knowledge
        self.definition = definition
        self.number = number
    }
}

/// A window's render-relevant detail, keyed to the entity of the same id.
public struct AgentIntegrationMirrorSurface:
    Codable, Equatable, Sendable {
    public let entityID: String
    public let title: String
    public let rect: AgentIntegrationMirrorRect?
    public let z: Int
    public let front: Bool
    public let visible: Bool
    public let items: [AgentIntegrationMirrorSurfaceItem]
    /// How many items the window actually has. A bounded list that did not
    /// say so would read as a complete window with fewer controls than the
    /// Mac is drawing — the silent-truncation defect this project has
    /// already paid for once in the Finder's item roster.
    public let itemTotal: Int

    public init(entityID: String, title: String,
                rect: AgentIntegrationMirrorRect?, z: Int, front: Bool,
                visible: Bool, items: [AgentIntegrationMirrorSurfaceItem],
                itemTotal: Int) {
        self.entityID = entityID
        self.title = title
        self.rect = rect
        self.z = z
        self.front = front
        self.visible = visible
        self.items = items
        self.itemTotal = itemTotal
    }
}

public struct AgentIntegrationMirrorScreen: Codable, Equatable, Sendable {
    public let w: Int
    public let h: Int

    public init(w: Int, h: Int) {
        self.w = w
        self.h = h
    }
}

public struct AgentIntegrationMirrorSnapshot:
    Codable, Equatable, Sendable {
    public let metadata: AgentIntegrationMirrorSnapshotMetadata
    public let coverage: [AgentIntegrationMirrorCoverage]
    public let entities: [AgentIntegrationMirrorEntity]
    public let menus: [AgentIntegrationMirrorMenu]
    /// The guest's own screen, so a headless caller can reason about
    /// geometry at all.
    public let screen: AgentIntegrationMirrorScreen?
    /// What the renderer draws inside each window. Absent from this
    /// projection until 2026-08-05, which made the render workflow —
    /// read the state, confirm it is there, then implement the drawing —
    /// impossible for anything but windows and menus.
    public let surfaces: [AgentIntegrationMirrorSurface]

    public init(metadata: AgentIntegrationMirrorSnapshotMetadata,
                coverage: [AgentIntegrationMirrorCoverage],
                entities: [AgentIntegrationMirrorEntity],
                menus: [AgentIntegrationMirrorMenu],
                screen: AgentIntegrationMirrorScreen? = nil,
                surfaces: [AgentIntegrationMirrorSurface] = []) {
        self.metadata = metadata
        self.coverage = coverage
        self.entities = entities
        self.menus = menus
        self.screen = screen
        self.surfaces = surfaces
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
    /// Whether the Mirror is running — polling the Mac and publishing
    /// scenes.
    ///
    /// Found by calling this row for the first time against a live host on
    /// 2026-08-05: it answered `laneDepth 0` with two empty lists, which is
    /// honest and unreadable. "The Mirror is open and the machine has been
    /// quiet" and "the Mirror was never opened, so nothing could have been
    /// measured" are the same reply without this field, and they call for
    /// opposite next steps — wait, versus open the Mirror.
    public let running: Bool
    /// Acts queued or in flight right now. `0` means the next act reaches
    /// the Mac immediately; above zero, a slow gesture is waiting on the
    /// lane rather than on the machine.
    public let laneDepth: Int
    public let acts: [AgentIntegrationMirrorActMetric]
    public let cycles: [AgentIntegrationMirrorCycleMetric]

    public init(running: Bool, laneDepth: Int,
                acts: [AgentIntegrationMirrorActMetric],
                cycles: [AgentIntegrationMirrorCycleMetric]) {
        self.running = running
        self.laneDepth = laneDepth
        self.acts = acts
        self.cycles = cycles
    }
}

public struct AgentIntegrationMirrorPlane: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let purpose: String
    public let format: Int
    public let generation: Int
    /// Host policy: whether this face is asking for the plane at all.
    public let requestedByHost: Bool

    public init(id: String, title: String, purpose: String, format: Int,
                generation: Int, requestedByHost: Bool) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.format = format
        self.generation = generation
        self.requestedByHost = requestedByHost
    }
}

public struct AgentIntegrationMirrorLifecycle:
    Codable, Equatable, Sendable {
    public let lifecycle: String
    public let residentBuild: String?
    public let residentMajor: Int?
    public let residentMinor: Int?
    /// The three plane bitmasks the resident reports. `capabilities` is what
    /// it CAN do, `requested` what the host asked for, `active` what it is
    /// actually doing — and the gap between the last two is the difference
    /// between "not armed" and "cannot arm", which reads identically in a
    /// refusal and calls for opposite repairs.
    public let capabilities: Int?
    public let requested: Int?
    public let active: Int?
    public let reason: String?
    public let planes: [AgentIntegrationMirrorPlane]

    public init(lifecycle: String, residentBuild: String?,
                residentMajor: Int?, residentMinor: Int?,
                capabilities: Int?, requested: Int?, active: Int?,
                reason: String?,
                planes: [AgentIntegrationMirrorPlane]) {
        self.lifecycle = lifecycle
        self.residentBuild = residentBuild
        self.residentMajor = residentMajor
        self.residentMinor = residentMinor
        self.capabilities = capabilities
        self.requested = requested
        self.active = active
        self.reason = reason
        self.planes = planes
    }
}

/// One operation, as the journal holds it.
///
/// `source` is the face that drove it — `human` or `mcp`. It was hardcoded
/// to `human` until 2026-08-05, so every agent-driven act was recorded as a
/// person's; telling the two apart afterwards is most of what this row is
/// for.
public struct AgentIntegrationMirrorOperationRecord:
    Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let outcome: String
    public let reason: String?
    public let target: String
    public let postcondition: String
    public let displayedSnapshotID: Int
    public let settledSequence: Int?

    public init(id: String, source: String, outcome: String,
                reason: String?, target: String, postcondition: String,
                displayedSnapshotID: Int, settledSequence: Int?) {
        self.id = id
        self.source = source
        self.outcome = outcome
        self.reason = reason
        self.target = target
        self.postcondition = postcondition
        self.displayedSnapshotID = displayedSnapshotID
        self.settledSequence = settledSequence
    }
}

public struct AgentIntegrationMirrorReadValue:
    Codable, Equatable, Sendable {
    public let intention: AgentIntegrationMirrorReadIntention
    public let current: AgentIntegrationMirrorSnapshotMetadata?
    public let snapshot: AgentIntegrationMirrorSnapshot?
    public let matches: [AgentIntegrationMirrorEntity]?
    public let metrics: AgentIntegrationMirrorMetrics?
    public let lifecycle: AgentIntegrationMirrorLifecycle?
    public let journal: [AgentIntegrationMirrorOperationRecord]?
    public let timedOut: Bool

    public init(intention: AgentIntegrationMirrorReadIntention,
                current: AgentIntegrationMirrorSnapshotMetadata?,
                snapshot: AgentIntegrationMirrorSnapshot? = nil,
                matches: [AgentIntegrationMirrorEntity]? = nil,
                metrics: AgentIntegrationMirrorMetrics? = nil,
                lifecycle: AgentIntegrationMirrorLifecycle? = nil,
                journal: [AgentIntegrationMirrorOperationRecord]? = nil,
                timedOut: Bool = false) {
        self.intention = intention
        self.current = current
        self.snapshot = snapshot
        self.matches = matches
        self.metrics = metrics
        self.lifecycle = lifecycle
        self.journal = journal
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
