import Foundation

/// **The shapes `now_find_elements` answers in.**
///
/// This row mints no reference of its own and sends the guest no message
/// `now_observe_elements` does not already send — it is a HOST-SIDE narrowing
/// of that walk's tree, by title and/or kind, so a caller who already knows
/// roughly what they are looking for does not have to walk the whole tree
/// themselves to find one button. See `FindElementsProjection`'s header for
/// why that composition is permitted and not a second decision about the
/// machine.

/// Which of the three element kinds a match is. A window IS the element the
/// walk found; a control or text element is found INSIDE one, which is why
/// only those two carry `window` in the answer below.
public enum AgentIntegrationFindElementKind: String, Codable, Sendable {
    case window
    case control
    case text
}

/// The process a match was found in, carried alongside every match rather
/// than once per answer: a caller filtering across every process (no
/// `serialHi`/`serialLo`) needs to know which one each hit belongs to, and a
/// flattened match list is the whole point of this row.
public struct AgentIntegrationFindElementProcess:
    Codable, Equatable, Sendable {
    public let name: String
    public let signature: String
    public let serialHi: Int
    public let serialLo: Int
    public let front: Bool

    public init(name: String, signature: String, serialHi: Int, serialLo: Int,
                front: Bool) {
        self.name = name
        self.signature = signature
        self.serialHi = serialHi
        self.serialLo = serialLo
        self.front = front
    }
}

/// The containing window's own identity, carried on a control or text match
/// so a caller can tell which window it is inside without a second call.
/// Absent on a window match — the window IS the match, not its container.
public struct AgentIntegrationFindElementWindow:
    Codable, Equatable, Sendable {
    public let ref: String
    public let title: String
    public let occurrence: Int

    public init(ref: String, title: String, occurrence: Int) {
        self.ref = ref
        self.title = title
        self.occurrence = occurrence
    }
}

/// One element the walk's own tree contained and this row's filter kept.
///
/// Every field a text element cannot supply — `title`, `occurrence`,
/// `bounds`, `visible`, `enabled` — is optional and absent rather than
/// defaulted, the same rule `AgentIntegrationElementTreeText` follows for the
/// tree this is filtered from: an absent field is a fact about what KIND of
/// element this is, never a placeholder.
public struct AgentIntegrationFindElementMatch: Codable, Equatable, Sendable {
    public let kind: AgentIntegrationFindElementKind
    /// The opaque reference: `now_window_act`, `now_control_act`,
    /// `now_text_get` or `now_text_set` takes it depending on `kind`. Minted
    /// by the walk this row filters, never by this row.
    public let ref: String
    public let title: String?
    public let occurrence: Int?
    public let process: AgentIntegrationFindElementProcess
    public let window: AgentIntegrationFindElementWindow?
    public let bounds: AgentIntegrationElementTreeBounds?
    public let visible: Bool?
    public let enabled: Bool?
    /// Present only for `kind == .text`.
    public let length: Int?

    public init(kind: AgentIntegrationFindElementKind, ref: String,
                title: String?, occurrence: Int?,
                process: AgentIntegrationFindElementProcess,
                window: AgentIntegrationFindElementWindow?,
                bounds: AgentIntegrationElementTreeBounds?,
                visible: Bool?, enabled: Bool?, length: Int?) {
        self.kind = kind
        self.ref = ref
        self.title = title
        self.occurrence = occurrence
        self.process = process
        self.window = window
        self.bounds = bounds
        self.visible = visible
        self.enabled = enabled
        self.length = length
    }
}

/// The whole answer: the walk's own facts about itself, carried through
/// unchanged, beside the matches this row's filter kept.
///
/// `scope`, `truncated` and `live` are the observation's own — copied rather
/// than recomputed, because this row does not re-derive a fact the guest
/// already stated about its own walk. `count` is deliberately NOT copied: the
/// observation's `count` is how many elements the WALK minted a reference
/// for, and this answer's `matches.count` is how many of those the FILTER
/// kept, which is a different number and the one this row's caller asked.
public struct AgentIntegrationFindAnswer: Codable, Equatable, Sendable {
    public let scope: String
    public let truncated: Bool
    public let live: Int
    public let matches: [AgentIntegrationFindElementMatch]

    public init(scope: String, truncated: Bool, live: Int,
                matches: [AgentIntegrationFindElementMatch]) {
        self.scope = scope
        self.truncated = truncated
        self.live = live
        self.matches = matches
    }
}

public typealias AgentIntegrationFindResult =
    AgentIntegrationProjectedResult<AgentIntegrationFindAnswer>
