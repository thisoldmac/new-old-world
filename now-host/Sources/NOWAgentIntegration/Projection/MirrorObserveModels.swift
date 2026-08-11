import Foundation

/// **The reference layer's shapes** — what an observation of this machine's
/// on-screen elements looks like on the host side, and the two acts whose
/// targets it mints.
///
/// It is a separate file from `MirrorActModels.swift` because it describes a
/// different kind of thing. That file holds the act plane's vocabulary: what
/// a row may claim it did, and the refusals that keep an act from addressing
/// anything but a named element. This one holds an OBSERVATION — a walk's
/// answer, carrying no claim about the machine beyond what the walk saw — and
/// the argument grammar of the two acts added beside `winact` on 2026-07-31.
///
/// **One minter, and the host does not invent references.** `observe`,
/// `elements` and `axtree` are three doors onto one guest-side walk, and that
/// walk is the only thing in the product that creates a reference (see the
/// reference-layer preamble in `contract/asyncapi.yaml`). The host validates
/// a reference's SHAPE when a caller sends one back and forwards it; it never
/// resolves one, and it never mints one outside a test. A token carries no
/// identity of its own — it is a lookup key into a bounded guest-side table
/// whose 128 bits are hashed over a per-session secret the caller never sees,
/// so knowing a window's title, bounds or `WindowPtr` does not let anyone
/// compute its reference. That is why there is deliberately no "give me the
/// reference for the window called X" anywhere on this surface.

/// One element's rectangle, in the guest's own screen coordinates.
///
/// Four edges rather than an origin and a size, matching the contract's
/// `x-bounds` and QuickDraw's own `Rect`. A host that re-expressed it as
/// origin-plus-extent would be doing arithmetic on a machine's numbers on the
/// way to a caller, which is the one thing the projection seam exists to keep
/// out of the middle.
public struct AgentIntegrationElementTreeBounds:
    Codable, Equatable, Sendable {
    public let left: Int
    public let top: Int
    public let right: Int
    public let bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// One control the walk read, with the reference that addresses it.
///
/// `value`, `min` and `max` are the Control Manager's own three numbers.
/// They are present for every control because the walk reads them for every
/// control; for a push button they are the degenerate 0/0/1 the Toolbox
/// keeps, which is a fact about that control rather than an absence.
public struct AgentIntegrationElementTreeControl:
    Codable, Equatable, Sendable {
    /// The opaque reference — `now-element-…` — that `ctlact` takes.
    public let ref: String
    public let title: String
    /// Which of the identically-titled controls in this window this is,
    /// counting from the front. Two OK buttons are told apart by nothing
    /// else a caller can read.
    public let occurrence: Int
    public let visible: Bool
    public let enabled: Bool
    public let bounds: AgentIntegrationElementTreeBounds
    public let value: Int
    public let min: Int
    public let max: Int

    public init(ref: String, title: String, occurrence: Int,
                visible: Bool, enabled: Bool,
                bounds: AgentIntegrationElementTreeBounds,
                value: Int, min: Int, max: Int) {
        self.ref = ref
        self.title = title
        self.occurrence = occurrence
        self.visible = visible
        self.enabled = enabled
        self.bounds = bounds
        self.value = value
        self.min = min
        self.max = max
    }
}

/// A window's own text element, when the walk could reach one.
///
/// **Present only for a window whose `TEHandle` a foreign walk can find** —
/// in practice a dialog's. A document window's text record is not
/// discoverable from outside the application, and the contract states that
/// gap rather than papering over it: such a window carries no text reference
/// and gets no row here. A caller that finds this absent has been told
/// something true about the walk, not about whether the window has text.
public struct AgentIntegrationElementTreeText: Codable, Equatable, Sendable {
    /// An element reference. It names a TEXT element, so `textget` and
    /// `textset` take it and `ctlact` refuses it.
    public let ref: String
    public let length: Int

    public init(ref: String, length: Int) {
        self.ref = ref
        self.length = length
    }
}

/// One window the walk saw.
public struct AgentIntegrationElementTreeWindow:
    Codable, Equatable, Sendable {
    /// The opaque reference — `now-window-…` — that `winact` takes.
    public let ref: String
    public let title: String
    /// Which of the identically-titled windows in this process this is.
    public let occurrence: Int
    /// Its position in the window list, front first.
    public let z: Int
    public let visible: Bool
    /// The window's `windowKind`.
    public let kind: Int
    public let bounds: AgentIntegrationElementTreeBounds
    public let text: AgentIntegrationElementTreeText?
    public let controls: [AgentIntegrationElementTreeControl]

    public init(ref: String, title: String, occurrence: Int, z: Int,
                visible: Bool, kind: Int,
                bounds: AgentIntegrationElementTreeBounds,
                text: AgentIntegrationElementTreeText?,
                controls: [AgentIntegrationElementTreeControl]) {
        self.ref = ref
        self.title = title
        self.occurrence = occurrence
        self.z = z
        self.visible = visible
        self.kind = kind
        self.bounds = bounds
        self.text = text
        self.controls = controls
    }
}

/// One process, and whatever of it the walk could read.
///
/// `bind` is the reason a process contributed no tree, in one word, and it is
/// the field that keeps an empty `windows` array from reading as a machine
/// with no windows open. `ok` means the walk ran; the other values name where
/// it stopped. **NOW's own process always answers with no tree** — a Carbon
/// application's window records are not where a classic walk reads — and that
/// is a limit the contract states rather than hides.
public struct AgentIntegrationElementTreeProcess:
    Codable, Equatable, Sendable {
    public let name: String
    public let signature: String
    public let serialHi: Int
    public let serialLo: Int
    public let front: Bool
    public let bind: String
    /// The `TickCount` at which this process's slice of the walk was taken.
    /// An observation is dated by the machine that made it, not by the host
    /// that received it.
    public let stampTicks: Int
    public let windows: [AgentIntegrationElementTreeWindow]

    public init(name: String, signature: String,
                serialHi: Int, serialLo: Int, front: Bool,
                bind: String, stampTicks: Int,
                windows: [AgentIntegrationElementTreeWindow]) {
        self.name = name
        self.signature = signature
        self.serialHi = serialHi
        self.serialLo = serialLo
        self.front = front
        self.bind = bind
        self.stampTicks = stampTicks
        self.windows = windows
    }
}

/// One walk's whole answer — the shape the contract calls `x-axTree`, shared
/// by `observe`, `elements` and `axtree`.
///
/// It is **not a row array**, and that is worth saying because most of this
/// surface's guest answers are. A row array is text a person reads; this is a
/// tree a caller navigates and then addresses, so flattening it would destroy
/// the containment that makes a reference meaningful — which control is in
/// which window of which process is the whole question an act is answering.
///
/// `truncated` is a fact about the REPLY and `live` about the machine, and
/// keeping them apart is the point of having both: a reader that cannot tell
/// a short tree from a clipped one has been told nothing useful, and `live` —
/// how many references are currently resolvable — is the real bound on how
/// much of this walk stays addressable after it arrives.
public struct AgentIntegrationElementObservation:
    Codable, Equatable, Sendable {
    /// What was walked: the frontmost application, or every process.
    public let scope: String
    /// How many elements the walk minted a reference for.
    public let count: Int
    public let truncated: Bool
    public let live: Int
    public let processes: [AgentIntegrationElementTreeProcess]

    public init(scope: String, count: Int, truncated: Bool, live: Int,
                processes: [AgentIntegrationElementTreeProcess]) {
        self.scope = scope
        self.count = count
        self.truncated = truncated
        self.live = live
        self.processes = processes
    }
}

/// Which process to observe, or the frontmost.
///
/// A pair rather than one number because a `ProcessSerialNumber` is two
/// 32-bit halves and always has been; splitting it here is what lets the
/// value cross JSON without a host-side encoding nobody else shares. Both
/// halves are present or neither is: half a PSN names nothing.
public struct AgentIntegrationProcessSerial:
    Codable, Equatable, Sendable {
    public let high: Int
    public let low: Int

    public init(high: Int, low: Int) {
        self.high = high
        self.low = low
    }

    /// Decode the optional pair, or the sentence a caller gets back.
    ///
    /// Nil is a legal answer and means "the frontmost", which is the default
    /// the contract states. A call that sends one half is refused rather than
    /// silently treated as the default: a caller that meant to name a process
    /// and mistyped one key would otherwise get an answer about a different
    /// application and no way to tell.
    public static func decode(
        _ arguments: [String: Any], tool: HostCapabilityID
    ) -> Result<Self?, AgentIntegrationArgumentRefusal> {
        let high = arguments["serialHi"] as? Int
        let low = arguments["serialLo"] as? Int
        switch (high, low) {
        case (nil, nil):
            /* Neither key, or keys carrying something that is not an
               integer. The second case matters: a `serialHi` of "3" is a
               call that meant to name a process, so it must not fall
               through to the frontmost. */
            guard arguments["serialHi"] == nil,
                  arguments["serialLo"] == nil else {
                return .failure(.init(
                    "\(tool.rawValue) requires serialHi and serialLo to be "
                        + "integers — the two halves of a process serial "
                        + "number, as an observation reports them."))
            }
            return .success(nil)
        case (let high?, let low?):
            return .success(.init(high: high, low: low))
        default:
            return .failure(.init(
                "\(tool.rawValue) takes serialHi and serialLo together or "
                    + "neither. Half a process serial number names nothing, "
                    + "and omitting both is how this call says \"the "
                    + "frontmost application\"."))
        }
    }
}

/// One validated control act: an element, and the part code to hand its
/// application.
public struct AgentIntegrationControlActRequest:
    Codable, Equatable, Sendable {
    public let element: String
    public let part: Int

    public init(element: String, part: Int) {
        self.element = element
        self.part = part
    }

    /// The same grammar as `decode`, asked of an already-built value — the
    /// reading the local socket needs now that this type is `Codable`. See
    /// `AgentIntegrationWindowActRequest.isWellFormed` for why a synthesised
    /// decode is not a check.
    public var isWellFormed: Bool {
        AgentIntegrationActPolicy.isValidElementReference(element)
            && AgentIntegrationControlPartPolicy.isBounded(part)
    }

    /// Decode one call's arguments, or the sentence the caller gets back.
    ///
    /// The target is checked first, for the reason
    /// `AgentIntegrationWindowActRequest.decode` gives: an act with no valid
    /// target is the failure this whole design is shaped against.
    public static func decode(
        _ arguments: [String: Any], tool: HostCapabilityID
    ) -> Result<Self, AgentIntegrationArgumentRefusal> {
        guard let element = arguments["element"] as? String,
              AgentIntegrationActPolicy.isValidElementReference(element) else {
            return .failure(.init(
                "\(tool.rawValue) requires element: one opaque "
                    + "\(AgentIntegrationActPolicy.elementReferencePrefix)… "
                    + "reference from a current observation. This surface "
                    + "cannot address a control any other way, and "
                    + "deliberately has no \"frontmost\" or \"default "
                    + "button\" form."))
        }
        guard let part = arguments["part"] as? Int,
              AgentIntegrationControlPartPolicy.isBounded(part) else {
            return .failure(.init(
                "\(tool.rawValue) requires part: a Control Manager part "
                    + "code between "
                    + "\(AgentIntegrationControlPartPolicy.minimumPart) and "
                    + "\(AgentIntegrationControlPartPolicy.maximumPart). The "
                    + "button parts are 10 and 11; a scroll bar's are 20 up, "
                    + "21 down, 22 page-up, 23 page-down, and 129 is the "
                    + "indicator."))
        }
        return .success(.init(element: element, part: part))
    }
}

/// What a part code may be.
///
/// A `ControlPartCode` is a signed 8-bit value in the Toolbox (Inside
/// Macintosh: Macintosh Toolbox Essentials, the Control Manager), and this
/// bounds the argument to that range and nothing narrower. **Deliberately not
/// an enum of the known parts**: a control definition procedure may define
/// its own part codes, and a host that enumerated the standard ones would
/// refuse a legal act against a custom CDEF while claiming to be strict about
/// something it had actually guessed. The guest refuses what it will not do;
/// this only keeps a value off the wire that no `ControlPartCode` could hold.
public enum AgentIntegrationControlPartPolicy {
    public static let minimumPart = 1
    public static let maximumPart = 253

    public static func isBounded(_ value: Int) -> Bool {
        value >= minimumPart && value <= maximumPart
    }
}

/// One validated menu act.
///
/// **`titleLeft` is required and is this act's identity check**, which is the
/// one thing about this request a reader most needs. Every other act on this
/// surface names its target with an opaque reference; a menu press cannot,
/// because there is no handle to name — so the identity checked is the PRESS
/// ITSELF, at the x where this menu's title sits in the menu bar. A press
/// anywhere else belongs to the person at the machine and is passed through
/// untouched. Without it there is no way to tell this act's press from the
/// user's, which is the 18/20 hijack in its menu-shaped form.
public struct AgentIntegrationMenuActRequest:
    Codable, Equatable, Sendable {
    public let menu: Int
    public let item: Int
    public let titleLeft: Int
    public let process: AgentIntegrationProcessSerial?

    public init(menu: Int, item: Int, titleLeft: Int,
                process: AgentIntegrationProcessSerial? = nil) {
        self.menu = menu
        self.item = item
        self.titleLeft = titleLeft
        self.process = process
    }

    /// The same grammar as `decode`, asked of an already-built value — the
    /// reading the local socket needs now that this type is `Codable`. The
    /// identity check is first here too: a value whose `titleLeft` is not a
    /// coordinate a screen could hold cannot be told from the person's own
    /// press, and that is the failure this act is shaped against.
    public var isWellFormed: Bool {
        AgentIntegrationActPolicy.isBoundedCoordinate(titleLeft)
            && item >= 1
    }

    /// Decode one call's arguments, or the sentence the caller gets back.
    ///
    /// The ORDER is the same argument the window act makes, applied to a
    /// target that is three numbers: the identity check is reported first,
    /// because a call missing `titleLeft` is a call that cannot be told apart
    /// from the user's own press, and that is the failure that matters.
    public static func decode(
        _ arguments: [String: Any], tool: HostCapabilityID
    ) -> Result<Self, AgentIntegrationArgumentRefusal> {
        guard let titleLeft = arguments["titleLeft"] as? Int,
              AgentIntegrationActPolicy.isBoundedCoordinate(titleLeft) else {
            return .failure(.init(
                "\(tool.rawValue) requires titleLeft: the x of that menu's "
                    + "title in the menu bar, as an observation reports it. "
                    + "It is this act's identity check rather than a "
                    + "convenience — a menu press carries no handle, so the "
                    + "press itself is the identity, and without it there is "
                    + "no way to tell this act's press from the user's."))
        }
        guard let menu = arguments["menu"] as? Int else {
            return .failure(.init(
                "\(tool.rawValue) requires menu: the menu's id, as an "
                    + "observation reports it."))
        }
        guard let item = arguments["item"] as? Int, item >= 1 else {
            return .failure(.init(
                "\(tool.rawValue) requires item: its 1-based position in "
                    + "that menu. Menu items are counted from 1, so 0 names "
                    + "nothing."))
        }
        switch AgentIntegrationProcessSerial.decode(arguments, tool: tool) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let process):
            return .success(.init(menu: menu, item: item,
                                  titleLeft: titleLeft, process: process))
        }
    }
}

/// What one control act produced.
///
/// It carries no control value. A receipt reporting where the scroll bar
/// "now sits" would be this host answering for the machine out of the
/// arguments it was just handed — where the control sits is a question for
/// another observation. The guest's own reply may quote a re-read position
/// for a control with a live range, and that is the machine speaking; when a
/// host lane exists to carry it, it arrives as its own dated reading rather
/// than as a field on this dispatch.
public struct AgentIntegrationControlActReceipt:
    Codable, Equatable, Sendable, AgentIntegrationSettledActReceipt {
    public let element: String
    public let part: Int
    public let dispatch: AgentIntegrationActDispatch
    public let dispatchedAt: Date
    public let correlation: String?
    public let settlement: String

    public init(element: String, part: Int,
                dispatch: AgentIntegrationActDispatch,
                dispatchedAt: Date, correlation: String? = nil,
                settlement: String = "unknown") {
        self.element = element
        self.part = part
        self.dispatch = dispatch
        self.dispatchedAt = dispatchedAt
        self.correlation = correlation
        self.settlement = settlement
    }
}

/// What one menu act produced.
///
/// `dispatched` here means the application's own `MenuSelect` returned this
/// item. What its command handler then did is the caller's to verify against
/// the machine's own state — a menu command may open a window, put up a
/// dialog, or do nothing at all, and none of that is visible from the
/// dispatch.
public struct AgentIntegrationMenuActReceipt:
    Codable, Equatable, Sendable, AgentIntegrationSettledActReceipt {
    public let menu: Int
    public let item: Int
    /// Echoed back because it is the identity that was checked, not a
    /// parameter of the act: a caller reading the receipt can see which
    /// press this was, which is the whole basis on which the guest agreed to
    /// treat it as the agent's rather than the person's.
    public let titleLeft: Int
    /// **Whether that identity was checked against the machine, or only
    /// trusted.** The guest asks the target application's own menu bar
    /// where the named menu's title sits; where it can read one, a
    /// disagreement is refused before anything is armed, and where it
    /// cannot there is no second opinion to have and the press is armed
    /// where the caller said.
    ///
    /// Two different safety claims, so they are two different words, and
    /// nil is a third: a guest that answered without the row. Reporting
    /// any of the three as the others is how a caller comes to believe a
    /// trusted press was a verified one.
    public let identity: String?
    public let dispatch: AgentIntegrationActDispatch
    public let dispatchedAt: Date
    public let correlation: String?
    public let settlement: String

    public init(menu: Int, item: Int, titleLeft: Int,
                identity: String? = nil,
                dispatch: AgentIntegrationActDispatch,
                dispatchedAt: Date, correlation: String? = nil,
                settlement: String = "unknown") {
        self.menu = menu
        self.item = item
        self.titleLeft = titleLeft
        self.identity = identity
        self.dispatch = dispatch
        self.dispatchedAt = dispatchedAt
        self.correlation = correlation
        self.settlement = settlement
    }
}

public typealias AgentIntegrationElementObservationResult =
    AgentIntegrationProjectedResult<AgentIntegrationElementObservation>
public typealias AgentIntegrationControlActResult =
    AgentIntegrationProjectedResult<AgentIntegrationControlActReceipt>
public typealias AgentIntegrationMenuActResult =
    AgentIntegrationProjectedResult<AgentIntegrationMenuActReceipt>

extension AgentIntegrationUnavailable {
    /// **No host lane carries an observation of this kind yet**, said as a
    /// fact about this host rather than about the Macintosh.
    ///
    /// The sibling of `noActLane` and a separate code on purpose. The act
    /// lane's absence and the reference layer's absence are two different
    /// missing halves — the acts want a way to send a dispatch, this wants a
    /// way to carry a tree back — and a caller told "no act lane" about a
    /// call that acts on nothing has been given a sentence it cannot use.
    /// The day the local protocol grows one it will very likely grow the
    /// other separately, and the codes are what let a caller tell which
    /// landed.
    public static func noObservationLane(_ command: String)
        -> AgentIntegrationUnavailable {
        AgentIntegrationUnavailable(
            code: "now-observation-lane-absent",
            message: "This host carries no observation lane for \(command) "
                + "yet, so nothing was asked of any machine. The capability "
                + "is published and the connected Macintosh may well serve "
                + "it; what is missing is on this side.")
    }
}
