import Foundation

/// One host capability's name, spelled once.
///
/// It is the MCP tool name and the identifier the capability report keys
/// on, because those were always the same string and used to be typed
/// twice — once in the companion's tool enum and once in the ledger's
/// per-tool literal. Two spellings of one identity is the shape of drift
/// this registry exists to remove.
public struct HostCapabilityID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The host's faces — the ways a caller reaches a projected capability.
///
/// The guest has two (console, wire) and `CommandParityTests` compares them.
/// The host has three, and until now nothing compared anything: a capability
/// could arrive on the MCP face and be unreachable from the app a person
/// actually launches — the host's version of the guest drift that shipped
/// `process.list` on one face only, which nothing noticed for a day
/// (docs/command-parity.md).
///
/// `appIntents` is listed here while it does not exist. That is the point of
/// listing it: a face silently absent from the model is the failure this
/// whole gate is for, so the face that is *coming* (W3) is declared as
/// uniformly not-yet-reached and starts demanding justifications from every
/// row the moment its first source file lands.
public enum HostFace: String, CaseIterable, Sendable {
    /// The NOW app a person launches: its sidebar modules and their controls.
    case appUI = "app UI"
    /// The agent companion's MCP tool surface.
    case mcp = "MCP"
    /// AppIntents / Siri. Planned (W3); no source exists yet.
    case appIntents = "AppIntents"
}

/// Whether one face reaches one capability, and the evidence or the reason.
///
/// A row does not get to *assert* reach: for the app UI it names the file and
/// the affordance that proves it, and `HostFaceParityTests` reads that file.
/// A declaration nobody checks is prose, and prose goes stale.
public enum HostFaceReach: Sendable {
    /// The face reaches it, proven by `symbol` appearing in `file` (relative
    /// to `now-host/Sources/Host`). Name the CALL SITE a person's click
    /// reaches, not the function it calls — a handler left behind after its
    /// button was deleted proves nothing.
    case reached(file: String, symbol: String)

    /// The face reaches every registered row structurally, because its
    /// renderer loops the registry rather than naming capabilities. No row
    /// can be missing from such a face, and none names its own evidence;
    /// the parity test checks the loop is still there instead.
    case reachedByRegistry

    /// The face does not reach it, and this is the decision behind that.
    /// Adding one should feel like a small act of documentation — it is
    /// reviewed against the ledger in `HostFaceParityTests`, so it cannot be
    /// the quiet way to make a failure go away.
    case notReached(because: String)
}

extension HostFaceReach {
    /// AppIntents, spelled once for all twelve rows rather than twelve
    /// invented variations on one fact. When W3 lands, this constant goes
    /// and each row has to say what its intent is — which is the whole
    /// reason the face is modelled before it exists.
    public static let appIntentsFaceNotBuiltYet = HostFaceReach.notReached(
        because: "The AppIntents face is planned (W3) and no AppIntents "
            + "source exists yet. Declared not-yet rather than omitted so "
            + "that the first intent to land forces every row to say "
            + "whether it has one.")
}

/// What a projection is allowed to be.
///
/// **The host projection layer may address, authorize, bound and render. It
/// may not decide or answer.** Anything the host answers out of its own
/// state is a fact about the host, not about the machine — and a capability
/// that starts being answered here has migrated out of the guest, which is
/// the one failure this seam is shaped to make visible. The guest owns
/// capability behind its two faces (docs/command-parity.md); the host is a
/// remote, and a projection is a client of the wire rather than a third
/// face (docs/agent-integration.md).
///
/// Read against that contract, the four verbs a conforming type may use:
///
/// - **address** — say WHICH machine a call is about. The `guest` selector
///   is lifted off every call in one place before `invoke` runs, so no
///   projection implements it and none can forget to.
/// - **authorize** — refuse what the caller has no standing to ask: an
///   expired receipt, a stale opaque reference, a path outside the
///   host-owned root.
/// - **bound** — cap what one call may cost or return, and reject
///   arguments the guest should never be asked to parse.
/// - **render** — turn one typed host result into one face's shape. The
///   MCP face's shape is `mcpDescriptor`; a later face renders the same
///   projection its own way, and neither may re-decide the answer.
///
/// Composition over data the guest just supplied is permitted and is not
/// deciding: `now_launch_software` lists the catalog, matches exactly one
/// name in it, hands back an opaque reference, revalidates that reference
/// against a fresh listing and only then sends `launch`. Every fact in that
/// chain came from the guest in the same breath. What is forbidden is the
/// version of it that answers from a remembered catalog.
///
/// Adding a capability is one new file conforming to this protocol plus one
/// row in `HostProjectionCatalog`. There is deliberately no shared switch
/// to edit: nine capabilities landing across three faces means nine agents
/// in nine worktrees, and a switch statement is where those nine collide.
public protocol HostProjection {
    /// The one spelling of this capability's name.
    static var capability: HostCapabilityID { get }

    /// The guest commands and message families this projection cannot work
    /// without — the whole derivation behind its availability. A projection
    /// whose safety model cannot stand up against the connected guest is
    /// unavailable against it in typed form, never a weaker version of
    /// itself with the unsafe part skipped.
    ///
    /// Empty means the projection sends the guest no message and is
    /// therefore available whatever the guest implements. It does not mean
    /// "requirements not worked out yet".
    static var requires: [String] { get }

    /// Which of the host's three faces reach this capability.
    ///
    /// Every face in `HostFace.allCases` is stated, including the one that
    /// does not exist yet: a row that simply omits a face reads as parity
    /// nobody checked. Reach is evidence or a reason, never an assertion —
    /// see `HostFaceReach`.
    static var faces: [HostFace: HostFaceReach] { get }

    /// One sentence for the caller, used when every requirement is met.
    /// The unavailable and unproven wordings are derived, so a row states
    /// only the fact it alone knows.
    static var availabilityNote: String { get }

    /// The MCP face's rendering: title, description, input and output
    /// schema, annotations. The tool's `name` and the `guest` selector are
    /// injected by the renderer, so a row cannot misspell its own identity
    /// or omit addressing.
    static var mcpDescriptor: [String: Any] { get }

    /// Validate, bound, and delegate. Everything a caller may ask is
    /// checked here; nothing about the machine is answered here.
    static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome
}

/// The arguments of one call, after the `guest` selector has been lifted.
///
/// It carries `Any?` rather than a dictionary because absent and empty are
/// different facts on this surface: three projections accept no arguments
/// at all and must reject a non-empty object while still accepting a call
/// that omits the member entirely.
public struct HostProjectionArguments {
    /// Exactly what arrived as `params.arguments`, less `guest`.
    public let raw: Any?

    public init(raw: Any?) {
        self.raw = raw
    }

    /// The arguments as an object, or nil when the caller sent something
    /// else — a projection that requires arguments refuses that.
    public var object: [String: Any]? { raw as? [String: Any] }

    /// The arguments as an object, treating absent as empty. For the
    /// projections whose every member is optional.
    public var objectOrEmpty: [String: Any] { object ?? [:] }

    /// The shared bound for a projection that takes nothing: absent or an
    /// empty object pass, anything else is refused with one wording.
    public func refusalIfAnyPresent(
        tool: HostCapabilityID
    ) -> String? {
        guard let raw else { return nil }
        guard let object = raw as? [String: Any], object.isEmpty else {
            return "\(tool.rawValue) accepts no arguments"
        }
        return nil
    }
}

/// What a projection hands back: one typed result to render, or the reason
/// the call was not well formed. A projection never renders the transport's
/// error itself — that is the face's job.
public enum HostProjectionOutcome {
    case value(HostProjectionValue)
    /// The caller's arguments were refused. The text is written for that
    /// caller and says what the projection would have accepted.
    case invalidArguments(String)
}

/// One projection result, kept encodable without the face having to know
/// which of a dozen result types it is holding.
public struct HostProjectionValue {
    private let encodeValue: (JSONEncoder) throws -> Data

    public init<Value: Encodable>(_ value: Value) {
        encodeValue = { try $0.encode(value) }
    }

    public func encoded(using encoder: JSONEncoder) throws -> Data {
        try encodeValue(encoder)
    }
}
