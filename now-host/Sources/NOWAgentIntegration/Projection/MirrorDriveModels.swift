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
public enum AgentIntegrationMirrorDriveGesture:
    String, Codable, Sendable, CaseIterable {
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

    /// The argument grammar published to MCP and enforced before a request
    /// reaches the host. One source owns both so adding a gesture cannot make
    /// the Swift enum and the agent-facing schema disagree.
    public var argumentContract: AgentIntegrationMirrorDriveArgumentContract {
        switch self {
        case .select, .close, .zoom:
            return .init(
                required: ["entityID"], optional: ["modifiers"],
                guidance: "Use the exact window entityID from a fresh retained snapshot. modifiers is optional.")
        case .activate:
            return .init(
                required: ["entityID"],
                guidance: "Use the exact process entityID from a fresh retained snapshot.")
        case .menuItem:
            return .init(
                required: ["menuID", "itemIndex"],
                guidance: "Use one menu id and its 1-based item index from the retained snapshot's menu bar.")
        case .hide, .hideOthers, .showAll:
            return .init(
                guidance: "Acts on the application-menu state published for the front process; takes no target argument.")
        case .key:
            return .init(
                required: ["keyCode"],
                optional: ["keyChar", "modifiers"],
                guidance: "keyCode is the classic Mac virtual keycode. keyChar and modifiers are optional integers.")
        case .type:
            return .init(
                required: ["text"],
                guidance: "Types 1 through 256 Unicode scalars into the current focus.")
        case .finderOpen, .finderSelect:
            return .init(
                required: ["itemName"], optional: ["container"],
                guidance: "Name one Finder item. container is desktop or a Finder window entityID from the retained snapshot.")
        case .finderDeselect:
            return .init(
                guidance: "Clears the Finder selection and takes no target argument.")
        case .dialogItem:
            return .init(
                required: ["entityID", "itemIndex"],
                guidance: "Use the containing window's entityID and the dialog item's 1-based number from the same fresh retained snapshot. Do not pass a now-element reference or a Control Manager part code.")
        case .appleMenuItem:
            return .init(
                required: ["itemName"],
                guidance: "Use one exact Apple menu item title from the retained snapshot.")
        case .cancel:
            return .init(
                guidance: "Cancels the host action lane. It takes no entity and remains available when the guest is wedged.")
        }
    }
}

public struct AgentIntegrationMirrorDriveArgumentContract: Sendable {
    public let required: [String]
    public let optional: [String]
    public let guidance: String

    public init(required: [String] = [], optional: [String] = [],
                guidance: String) {
        self.required = required
        self.optional = optional
        self.guidance = guidance
    }

    public var accepted: Set<String> {
        Set(required + optional)
    }
}

public struct AgentIntegrationMirrorDriveRequest:
    Codable, Equatable, Sendable {
    public let gesture: AgentIntegrationMirrorDriveGesture
    /// An entity id exactly as `now_semantic_ui_snapshot` published it —
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

    /// Decode the MCP argument object against the same per-gesture contract
    /// its schema publishes. The local socket still transports the typed
    /// request; this boundary prevents a model's guessed combination from
    /// reaching it and turning into a less useful host-side refusal.
    public static func decode(
        _ arguments: [String: Any], tool: HostCapabilityID
    ) -> Result<Self, AgentIntegrationArgumentRefusal> {
        guard let raw = arguments["gesture"] as? String,
              let gesture = AgentIntegrationMirrorDriveGesture(rawValue: raw)
        else {
            let names = AgentIntegrationMirrorDriveGesture.allCases
                .map(\.rawValue).joined(separator: ", ")
            return .failure(.init(
                "\(tool.rawValue) requires gesture: one of \(names). "
                    + "Do not invent a gesture name."))
        }

        let contract = gesture.argumentContract
        let present = Set(arguments.keys).subtracting(["gesture"])
        let missing = Set(contract.required).subtracting(present)
        if !missing.isEmpty {
            return .failure(.init(
                "\(tool.rawValue) gesture \(raw) requires "
                    + "\(missing.sorted().joined(separator: ", ")). "
                    + contract.guidance))
        }
        let unexpected = present.subtracting(contract.accepted)
        if !unexpected.isEmpty {
            let accepted = contract.accepted.sorted()
            return .failure(.init(
                "\(tool.rawValue) gesture \(raw) does not take "
                    + "\(unexpected.sorted().joined(separator: ", ")). "
                    + (accepted.isEmpty
                       ? "It takes no arguments besides gesture. "
                       : "It accepts \(accepted.joined(separator: ", ")). ")
                    + contract.guidance))
        }

        func text(_ key: String) -> String? {
            arguments[key] as? String
        }
        func number(_ key: String) -> Int? {
            if let value = arguments[key] as? Int { return value }
            if let value = arguments[key] as? Double { return Int(value) }
            return nil
        }
        let request = Self(
            gesture: gesture,
            entityID: text("entityID"),
            menuID: number("menuID"),
            itemIndex: number("itemIndex"),
            keyCode: number("keyCode"),
            keyChar: number("keyChar"),
            modifiers: number("modifiers"),
            text: text("text"),
            itemName: text("itemName"),
            container: text("container"))
        guard request.isWellFormed else {
            return .failure(.init(
                "\(tool.rawValue) gesture \(raw) has an invalid argument "
                    + "value. \(contract.guidance)"))
        }
        return .success(request)
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
/// survives it — read `now_semantic_ui_journal`, or watch the snapshot.
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
