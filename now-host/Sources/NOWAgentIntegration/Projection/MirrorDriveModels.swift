import Foundation

/// **Driving the Mirror, headless.**
///
/// The Mirror window and MCP are two clients of one state engine. This is
/// the mutation half of that: a call names an object the SNAPSHOT already
/// published, the host turns it into the same `Interaction` a gesture
/// produces, and it runs through `MirrorActionExecutor` and the mutation
/// broker exactly as a click does.
///
/// It deliberately does NOT reuse the older act rows (`now_window_act`
/// and friends). Those take an opaque `now-element-…` ref minted by
/// `now_observe_elements` and go straight to the guest's command dispatch,
/// settling for nothing — a path no person can take. An agent measuring
/// through that path measures the wrong product
/// (`docs/mirror-mcp-parity.md`).
public enum AgentIntegrationMirrorDriveGesture: String, Codable, Sendable {
    /// Window Manager operations, addressed by window entity.
    case select
    case close
    case zoom
    /// Bring an application forward, addressed by process entity.
    case activate
    /// One menu row, by menu id and 1-based item index.
    case menuItem
    /// Hide, Hide Others, Show All — typed, so they cannot fall back to
    /// commanding the Application menu, the route that reported success
    /// without changing the machine.
    case hide
    case hideOthers
    case showAll
    /// One keystroke, carrying the VIRTUAL KEYCODE. A Mac's `MenuEvent`
    /// matches on the code and not the character, which has cost this
    /// project a day before.
    case key
    /// Text, as the keystrokes it is made of, wherever focus is.
    case type
    /// Ask the Finder for an item BY NAME — the case the object-first
    /// model exists for, because an icon has no control reference.
    case finderOpen
    case finderSelect
    /// Clear the Finder's selection, which is what clicking empty desktop
    /// does. Its own gesture rather than a `finderSelect` with no name,
    /// because "select nothing" and "select the thing called nothing" must
    /// not be the same request.
    case finderDeselect
    /// One live Dialog Manager item, by its 1-based DITL number, through
    /// the addressed dialog's own event path. NOT a Control Manager part,
    /// even when the item owns a `ControlHandle`.
    case dialogItem
    /// One system-owned Apple Menu Items entry, opened through the guest
    /// Finder. CarbonLib does not expose `OpenDeskAcc` to the guest app,
    /// so this is the public, metal-safe route rather than a shortcut.
    case appleMenuItem
    /// Abandon the in-flight act and everything queued behind it. It acts
    /// on the HOST's lane, not the machine, so it needs no entity and no
    /// published scene — the wedged guest it exists for publishes nothing.
    case cancel
}

public struct AgentIntegrationMirrorDriveRequest:
    Codable, Equatable, Sendable {
    public let gesture: AgentIntegrationMirrorDriveGesture
    /// An entity id exactly as `now_mirror_snapshot` published it —
    /// `window:…` or `process:…`. The whole point of addressing this way
    /// is that an agent names what it can see, rather than a second
    /// reference minted somewhere else.
    public let entityID: String?
    public let menuID: Int?
    public let itemIndex: Int?
    public let keyCode: Int?
    public let keyChar: Int?
    public let modifiers: Int?
    public let text: String?
    /// A Finder item's name, and the container to look in — `desktop`, or
    /// a window entity id.
    public let itemName: String?
    public let container: String?

    public init(gesture: AgentIntegrationMirrorDriveGesture,
                entityID: String? = nil, menuID: Int? = nil,
                itemIndex: Int? = nil, keyCode: Int? = nil,
                keyChar: Int? = nil, modifiers: Int? = nil,
                text: String? = nil, itemName: String? = nil,
                container: String? = nil) {
        self.gesture = gesture
        self.entityID = entityID
        self.menuID = menuID
        self.itemIndex = itemIndex
        self.keyCode = keyCode
        self.keyChar = keyChar
        self.modifiers = modifiers
        self.text = text
        self.itemName = itemName
        self.container = container
    }

    public var isWellFormed: Bool {
        switch gesture {
        case .select, .close, .zoom, .activate:
            return entityID?.isEmpty == false
        case .menuItem:
            return menuID != nil && (itemIndex ?? 0) > 0
        case .hide, .hideOthers, .showAll:
            return true
        case .key:
            return keyCode != nil
        case .type:
            return text?.isEmpty == false && (text!.count <= 256)
        case .finderOpen, .finderSelect:
            return itemName?.isEmpty == false
        case .finderDeselect:
            return true
        case .dialogItem:
            return entityID?.isEmpty == false && (itemIndex ?? 0) > 0
        case .appleMenuItem:
            return itemName?.isEmpty == false
        case .cancel:
            return true
        }
    }
}

/// The operation record a gesture produces, unchanged.
///
/// Same fields the Mirror window's own journal carries, because it IS that
/// record. `outcome` is the broker's, not a paraphrase: `queued`,
/// `dispatched`, `refused`, `timedOut`, `confirmed`,
/// `confirmedAfterTimeout`, `confirmedAfterRefusal`, `sessionChanged`,
/// `cancelled`.
///
/// **A dispatch is not an effect.** `dispatched` means the request reached
/// the Mac; only an outcome carrying `confirmed` says a later observation
/// saw the postcondition hold. That rule is older than this surface and
/// survives it — poll with `now_mirror_act` again, or watch the snapshot.
///
/// `id` is the journal's id for anything the broker took. Three values are
/// not ids, and each says which of the host's endings the act reached:
///
/// - `not-dispatched` — refused here; `reason` says why, `settled` is true
///   and nothing is coming.
/// - `direct` — dispatched with no typed postcondition. Seven of the
///   fourteen plans are like this by construction; `awaitsObservation` is
///   false and no settlement can ever arrive.
/// - `held` — it arrived while an observation was in flight, so it is
///   waiting for the cycle to clear and has no record YET. One is coming:
///   `awaitsObservation` is true, and the record appears in the journal
///   under a real id once it enters the lane. Before 2026-08-05 this case
///   was reported as `direct`, which told the caller to stop waiting for a
///   settlement that was on its way.
public struct AgentIntegrationMirrorDriveOperation:
    Codable, Equatable, Sendable {
    public let id: String
    public let outcome: String
    public let reason: String?
    public let settled: Bool
    /// Whether this operation carries a typed postcondition at all. Only
    /// seven of the Mirror's fourteen plans do; the rest dispatch and are
    /// never confirmed by observation, and a caller that did not know
    /// which it had would wait forever for a settlement that cannot come.
    public let awaitsObservation: Bool

    public init(id: String, outcome: String, reason: String?,
                settled: Bool, awaitsObservation: Bool) {
        self.id = id
        self.outcome = outcome
        self.reason = reason
        self.settled = settled
        self.awaitsObservation = awaitsObservation
    }
}

public struct AgentIntegrationMirrorDriveResult:
    Codable, Equatable, Sendable {
    public let available: Bool
    public let operation: AgentIntegrationMirrorDriveOperation?
    public let unavailable: AgentIntegrationUnavailable?

    public init(operation: AgentIntegrationMirrorDriveOperation) {
        available = true
        self.operation = operation
        unavailable = nil
    }

    public init(unavailable: AgentIntegrationUnavailable) {
        available = false
        operation = nil
        self.unavailable = unavailable
    }
}
