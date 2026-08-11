import Foundation

/// **The act plane's vocabulary** — the shapes the three act rows share, and
/// the two properties the sibling Mirror project MEASURED that decide them.
///
/// The parked sibling Mirror project
/// drives a classic Mac application's own `FindWindow` / text / menu paths
/// from inside that application, rather than from outside it. Two of its
/// results are load-bearing here and neither is a preference:
///
/// 1. **Identity is the guard, not self-disarming.** A request that merely
///    disarms after one use rode the user's own press **18/20**; the variant
///    that additionally required the request to name its exact target
///    hijacked **0/20**. A bound on time or count is not a bound on scope.
///    So every act row in this file addresses ONE named element and none of
///    them can express "whatever is frontmost" — an act whose arguments
///    cannot name a target is that 18/20 defect restated in our idiom.
/// 2. **`performed: true` means an event was DISPATCHED**, not that anything
///    happened. Upstream verified its acts against the guest filesystem
///    rather than against the service's own report. So the receipts here say
///    `dispatched` and stop there; see `AgentIntegrationActDispatch`.
///
/// **QMP is out of the act plane, and that is the sentence a reader of this
/// file most needs.** Nothing here simulates mouse motion or synthesises a
/// click: the application answers its own `FindWindow` call and does what it
/// would have done. These rows therefore inherit **no emulator dependency**
/// and sit inside this project's no-host-side-cheating rule rather than
/// against it. A week ago that was not true, which is why it is written down
/// here instead of assumed.
///
/// ## What the guest must implement before any of this answers
///
/// Nothing in NOW serves the act plane today, and this file invents no wire
/// message for it. What it declares is a REQUIREMENT — three console
/// commands, resolved off the guest's own `help` table exactly as `reveal`,
/// `gestalt` and `tail` are — so the rows report typed unavailability until
/// a guest answers them, with nothing on this side asking which guest is
/// connected. The full list is in `MirrorActProjections`.
public enum AgentIntegrationActPolicy {
    /// **Opaque element references, and why they are not handles.**
    ///
    /// A `WindowPtr` or a `ControlHandle` is a pointer in another process's
    /// heap: it is meaningful only while that element lives, it is trivially
    /// forgeable, and a caller holding one could name an element it never
    /// observed. So the host takes the same shape it already takes for
    /// processes (`AgentIntegrationQuitPolicy.referencePattern`): an opaque,
    /// short-lived string minted BY the observation that saw the element,
    /// which the guest maps back to a live element and revalidates before it
    /// acts.
    ///
    /// The host validates the shape and forwards it. It deliberately does
    /// not resolve one: a host-side match would be a stale observation
    /// wearing the clothes of a live one, which is the argument
    /// `GuestFilesMutateProjection` already makes about path identity.
    public static let windowReferencePrefix = "now-window-"
    public static let elementReferencePrefix = "now-element-"

    public static let windowReferencePattern =
        "^now-window-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}"
            + "-[0-9a-f]{12}$"
    public static let elementReferencePattern =
        "^now-element-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}"
            + "-[0-9a-f]{12}$"

    public static func makeWindowReference() -> String {
        windowReferencePrefix + UUID().uuidString.lowercased()
    }

    public static func makeElementReference() -> String {
        elementReferencePrefix + UUID().uuidString.lowercased()
    }

    public static func isValidWindowReference(_ value: String) -> Bool {
        isValidReference(value, prefix: windowReferencePrefix)
    }

    public static func isValidElementReference(_ value: String) -> Bool {
        isValidReference(value, prefix: elementReferencePrefix)
    }

    private static func isValidReference(
        _ value: String, prefix: String
    ) -> Bool {
        guard value == value.lowercased(),
              value.hasPrefix(prefix),
              value.count == prefix.count + 36 else {
            return false
        }
        return UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }

    /// The coordinate range a classic `Rect` can hold: QuickDraw's `Rect`
    /// members are signed 16-bit, so a destination outside this is not a
    /// window the machine could ever have. Documented (Inside Macintosh:
    /// Imaging With QuickDraw, the `Rect` structure), not measured, and it
    /// bounds an argument rather than describing a machine.
    public static let minimumCoordinate = -32_768
    public static let maximumCoordinate = 32_767

    /// A window's smallest expressible edge. One point, not a measurement of
    /// any real window manager's floor — the guest refuses what it will not
    /// do, and this only keeps a zero or a negative off the wire.
    public static let minimumExtent = 1

    /// **The host's own cap on text crossing this surface**, in Unicode
    /// scalars, and it is OURS rather than a fact about a Macintosh.
    ///
    /// It is chosen to sit far inside the local surface's 16 KiB
    /// request/response cap with room for the JSON envelope and any escaping,
    /// so a legal call cannot be the thing that overflows a frame. No
    /// measurement backs the exact number and none is claimed; a guest that
    /// holds less says so in its own refusal, and a text longer than this is
    /// refused HERE with a sentence that names the bound rather than
    /// truncated into a silent half-write.
    public static let maximumTextScalars = 4_096

    public static func isBoundedText(_ value: String) -> Bool {
        value.unicodeScalars.count <= maximumTextScalars
    }

    public static func isBoundedCoordinate(_ value: Int) -> Bool {
        value >= minimumCoordinate && value <= maximumCoordinate
    }

    public static func isBoundedExtent(_ value: Int) -> Bool {
        value >= minimumExtent && value <= maximumCoordinate
    }
}

/* The act plane's three requirement names USED to live here, as an
   extension on `AgentIntegrationCapabilityNames`, because the rows were
   built and deliberately unregistered. They were folded into that namespace
   proper on 2026-07-31 when the rows were registered, and the argument for
   why they are COMMANDS rather than message families moved with them —
   `AgentIntegrationCapabilityNames.actPlane` is where it is now. */

/// **What an act row is allowed to claim it did.**
///
/// One case, and the single case is the point rather than an oversight. The
/// act plane dispatches an event into an application's own event path; the
/// reply says the event went, and nothing in it can say the application
/// obeyed. Mirror measured that distinction the expensive way — it verified
/// its acts against the guest filesystem instead of trusting
/// `performed: true` — so this surface refuses to spell a success that would
/// mean the same unverified thing.
///
/// A second case is EARNED, not added: `confirmed` becomes writable the day
/// something re-reads the element and finds the new state, which is how
/// `AgentIntegrationFrontOutcome` came to have two. Until then, a one-case
/// enum is an honest vocabulary and a `Bool` named `performed` would not be.
public enum AgentIntegrationActDispatch:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// The event was handed to the addressed element's own application. It
    /// is NOT a claim that the window moved, or that the text changed.
    case dispatched
}

/// One refused call's sentence, carried as a typed failure.
///
/// It exists because `Result`'s failure must be an `Error` and the thing a
/// refused caller gets is a sentence — the wording is the product here (see
/// `HostProjectionArguments.refusalForUnknownMembers`), so it is carried
/// rather than mapped to a code and back.
public struct AgentIntegrationArgumentRefusal: Error, Equatable, Sendable {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }
}

/// The four things this surface can ask of one window.
///
/// Mirror runs all four through one path — the application's own
/// `FindWindow` answer — and measured 20/20 on each, so they are one row
/// here for the reason the four guest-file mutations are one row: one
/// mechanism, one addressing grammar, one authorization.
public enum AgentIntegrationWindowAction:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// Select this exact window within its owning application.
    case select
    /// Move the window's content origin to `left`/`top`.
    case move
    /// Resize the window's content to `width`/`height`.
    case resize
    /// The zoom box: toggle between the user and standard states. Takes no
    /// geometry — the standard state is the application's to compute, and a
    /// host that supplied one would be deciding what a window is FOR.
    case zoom
    /// The close box. Destructive: an application may lose unsaved work, or
    /// may put up a save dialog nothing here can answer.
    case close
}

/// One validated window act: a target, an action, and exactly the geometry
/// that action takes.
///
/// The decode lives beside the vocabulary rather than in the row because it
/// is where the argument grammar is DEFINED — `WindowActProjection` bounds
/// and delegates, and a per-action key rule is not a second job for it.
public struct AgentIntegrationWindowActRequest:
    Codable, Equatable, Sendable {
    public let window: String
    public let action: AgentIntegrationWindowAction
    /// Present exactly for `move`.
    public let left: Int?
    public let top: Int?
    /// Present exactly for `resize`.
    public let width: Int?
    public let height: Int?

    public init(window: String,
                action: AgentIntegrationWindowAction,
                left: Int? = nil, top: Int? = nil,
                width: Int? = nil, height: Int? = nil) {
        self.window = window
        self.action = action
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    /// The geometry keys each action takes — and, read the other way, the
    /// keys it REFUSES. `zoom` and `close` take none, so a call carrying a
    /// `width` alongside a close is not a slightly-wrong close; it is a
    /// different request, and this surface refuses it rather than performing
    /// the close and discarding the rest.
    public static func geometryKeys(
        for action: AgentIntegrationWindowAction
    ) -> Set<String> {
        switch action {
        case .move: return ["left", "top"]
        case .resize: return ["width", "height"]
        case .select, .zoom, .close: return []
        }
    }

    /// **The same grammar as `decode`, asked of an already-built value.**
    ///
    /// It exists because `decode` is not the only door any more. The request
    /// became `Codable` when the act lane landed, so a value can now arrive
    /// off the local socket without passing the argument grammar — and the
    /// socket is a trust boundary (any process of this uid can write it),
    /// not a convenience. Synthesised decoding would happily produce a
    /// `close` carrying a width, or a window reference that is a bare
    /// string, and this is what refuses both.
    ///
    /// It is deliberately a re-derivation of the same three rules rather
    /// than a second list: the geometry set comes from `geometryKeys`, the
    /// reference check from `AgentIntegrationActPolicy`, and the bounds from
    /// the same two predicates `decode` uses.
    public var isWellFormed: Bool {
        guard AgentIntegrationActPolicy.isValidWindowReference(window) else {
            return false
        }
        let expected = Self.geometryKeys(for: action)
        var present: Set<String> = []
        if let left { present.insert("left")
            guard AgentIntegrationActPolicy.isBoundedCoordinate(left) else {
                return false
            }
        }
        if let top { present.insert("top")
            guard AgentIntegrationActPolicy.isBoundedCoordinate(top) else {
                return false
            }
        }
        if let width { present.insert("width")
            guard AgentIntegrationActPolicy.isBoundedExtent(width) else {
                return false
            }
        }
        if let height { present.insert("height")
            guard AgentIntegrationActPolicy.isBoundedExtent(height) else {
                return false
            }
        }
        return present == expected
    }

    /// Decode one call's arguments, or the sentence the caller gets back.
    ///
    /// Every refusal names the bound it broke. The ORDER is deliberate:
    /// the target is checked first, because an act with no valid target is
    /// the failure this whole design is shaped against, and a caller that
    /// gets "left must be…" back for a call with no window has been told the
    /// second-most-important thing.
    public static func decode(
        _ arguments: [String: Any], tool: HostCapabilityID
    ) -> Result<Self, AgentIntegrationArgumentRefusal> {
        guard let window = arguments["window"] as? String,
              AgentIntegrationActPolicy.isValidWindowReference(window) else {
            return .failure(.init(
                "\(tool.rawValue) requires window: one opaque "
                    + "\(AgentIntegrationActPolicy.windowReferencePrefix)… "
                    + "reference from a current observation. This surface "
                    + "cannot address a window any other way, and "
                    + "deliberately has no \"frontmost\" form."))
        }
        guard let actionName = arguments["action"] as? String,
              let action = AgentIntegrationWindowAction(
                rawValue: actionName) else {
            return .failure(.init(
                "\(tool.rawValue) requires action: one of "
                    + AgentIntegrationWindowAction.allCases
                        .map(\.rawValue).sorted().joined(separator: ", ")))
        }

        let expected = geometryKeys(for: action)
        let present = Set(arguments.keys)
            .subtracting(["window", "action"])
        guard present == expected else {
            return .failure(.init(
                "\(tool.rawValue) with action \(action.rawValue) takes "
                    + (expected.isEmpty
                        ? "no geometry"
                        : expected.sorted().joined(separator: ", "))
                    + "; this call sent "
                    + (present.isEmpty
                        ? "none"
                        : present.sorted().joined(separator: ", "))))
        }

        var decoded: [String: Int] = [:]
        for key in expected.sorted() {
            guard let value = arguments[key] as? Int else {
                return .failure(.init(
                    "\(tool.rawValue) requires \(key) to be an integer "
                        + "number of points"))
            }
            let bounded = (key == "left" || key == "top")
                ? AgentIntegrationActPolicy.isBoundedCoordinate(value)
                : AgentIntegrationActPolicy.isBoundedExtent(value)
            guard bounded else {
                return .failure(.init(
                    "\(tool.rawValue) requires \(key) within "
                        + "\(AgentIntegrationActPolicy.minimumCoordinate)…"
                        + "\(AgentIntegrationActPolicy.maximumCoordinate) "
                        + "points, the range a QuickDraw Rect can hold"))
            }
            decoded[key] = value
        }

        return .success(.init(
            window: window,
            action: action,
            left: decoded["left"],
            top: decoded["top"],
            width: decoded["width"],
            height: decoded["height"]))
    }
}

/// What one window act produced. A dispatch, the target it named, and when.
///
/// It carries no rectangle. A receipt reporting where the window "now is"
/// would be this host answering for the machine out of the arguments it was
/// just handed — the one failure the projection seam exists to make visible.
/// Where the window is, is a question for an observation.
public struct AgentIntegrationWindowActReceipt:
    Codable, Equatable, Sendable, AgentIntegrationSettledActReceipt {
    public let window: String
    public let action: AgentIntegrationWindowAction
    public let dispatch: AgentIntegrationActDispatch
    /// When the guest reported the event handed off.
    public let dispatchedAt: Date
    public let correlation: String?
    public let settlement: String

    public init(window: String,
                action: AgentIntegrationWindowAction,
                dispatch: AgentIntegrationActDispatch,
                dispatchedAt: Date, correlation: String? = nil,
                settlement: String = "unknown") {
        self.window = window
        self.action = action
        self.dispatch = dispatch
        self.dispatchedAt = dispatchedAt
        self.correlation = correlation
        self.settlement = settlement
    }
}

/// One text element's contents as the guest read them.
///
/// `truncated` is a fact about the READING, not about the element: the guest
/// says whether more text existed than the bound allowed it to send. An
/// absent flag would leave a caller unable to tell a short field from a
/// clipped one, which is the kind of silence this surface keeps refusing.
public struct AgentIntegrationTextReading: Codable, Equatable, Sendable {
    public let element: String
    public let text: String
    public let truncated: Bool
    public let observedAt: Date

    public init(element: String, text: String,
                truncated: Bool, observedAt: Date) {
        self.element = element
        self.text = text
        self.truncated = truncated
        self.observedAt = observedAt
    }
}

/// What one text replacement produced.
///
/// `requestedScalars` is what the HOST sent, and is named that way on
/// purpose: it is not "what the element now holds", which only a reading
/// could say.
public struct AgentIntegrationTextSetReceipt:
    Codable, Equatable, Sendable, AgentIntegrationSettledActReceipt {
    public let element: String
    public let requestedScalars: Int
    public let dispatch: AgentIntegrationActDispatch
    public let dispatchedAt: Date
    public let correlation: String?
    public let settlement: String

    public init(element: String, requestedScalars: Int,
                dispatch: AgentIntegrationActDispatch,
                dispatchedAt: Date, correlation: String? = nil,
                settlement: String = "unknown") {
        self.element = element
        self.requestedScalars = requestedScalars
        self.dispatch = dispatch
        self.dispatchedAt = dispatchedAt
        self.correlation = correlation
        self.settlement = settlement
    }
}

public typealias AgentIntegrationWindowActResult =
    AgentIntegrationProjectedResult<AgentIntegrationWindowActReceipt>
public typealias AgentIntegrationTextReadingResult =
    AgentIntegrationProjectedResult<AgentIntegrationTextReading>
public typealias AgentIntegrationTextSetResult =
    AgentIntegrationProjectedResult<AgentIntegrationTextSetReceipt>

extension AgentIntegrationUnavailable {
    /// **No host lane carries an act yet**, said as a fact about this host
    /// rather than about the Macintosh or about the socket.
    ///
    /// The three act lanes' protocol defaults answered `.host` — "New Old
    /// World host is unavailable" — while the rows were unregistered, and
    /// that was true of the only clients that could reach them: stubs with
    /// no host at all. Registration made the defaults reachable from the
    /// real local client, where a running app and a connected Macintosh are
    /// the ordinary case, and the sentence stopped being true. So the fold
    /// that published the rows also replaced their reason: same typed
    /// `unavailable` outcome, a reason that names the missing half.
    ///
    /// Distinct from `.guest`, which says nothing is connected, and from
    /// `notWired`, which is about an operation this host's local protocol
    /// DOES carry. Neither describes a capability whose host lane has never
    /// been built.
    public static func noActLane(_ command: String)
        -> AgentIntegrationUnavailable {
        AgentIntegrationUnavailable(
            code: "now-act-lane-absent",
            message: "This host carries no act lane for \(command) yet, so "
                + "nothing was asked of any machine. The capability is "
                + "published and its guest half is unbuilt.")
    }
}
