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
