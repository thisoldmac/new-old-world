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

/// **Which faces can reach a capability** — the design-time reach model a
/// row declares and `HostFaceParityTests` checks.
///
/// The guest has two faces (console, wire) and `CommandParityTests` compares
/// them. The host has three, and until now nothing compared anything: a
/// capability could arrive on the MCP face and be unreachable from the app a
/// person actually launches — the host's version of the guest drift that
/// shipped `process.list` on one face only, which nothing noticed for a day
/// (docs/command-parity.md).
///
/// **Not to be confused with `HostInvokingFace`, and the two are different
/// axes rather than two spellings of one.** This enum answers *can this face
/// reach this capability at all*, which is a property of the product and is
/// asserted per row. `HostInvokingFace` answers *who invoked, on this call*,
/// which is a runtime fact and reaches the audit log. That is why this one
/// has an `appUI` case and that one deliberately does not: the app UI reaches
/// every capability it reaches, and reaches none of them *through a
/// projection*. Neither type is a subset of the other and they must not be
/// collapsed — `appIntents` here is a face that does not exist yet, while
/// `HostInvokingFace.appIntent` is a caller that can already be constructed.
///
/// `appIntents` is listed here while it does not exist. That is the point of
/// listing it: a face silently absent from the model is the failure this
/// whole gate is for, so the face that is *coming* (W3) is declared as
/// uniformly not-yet-reached and starts demanding justifications from every
/// row the moment its first source file lands.
public enum HostCapabilityFace: String, CaseIterable, Sendable {
    /// The NOW app a person launches: its sidebar modules and their controls.
    case appUI = "app UI"
    /// The agent companion's MCP tool surface.
    case mcp = "MCP"
    /// AppIntents / Siri. Planned (W3); no source exists yet.
    case appIntents = "AppIntents"
}

/// The owner whose authority a projection spends. Guest consent is not a
/// proxy for access to this Mac's application-owned storage.
public enum HostProjectionAuthorityDomain: Equatable, Sendable {
    case guest
    case hostProjects
    case hostProjectsAndGuest
    /// This Mac's own application state — not project storage, and nothing a
    /// guest has standing over. `now_host_log_tail` reads the host's own log
    /// ring, which exists whether or not any Macintosh is connected and says
    /// nothing about one.
    ///
    /// Its own case rather than borrowing `hostProjects`: they agree on the
    /// consequence (guest consent is not consulted) and disagree on the
    /// fact, and the refusal a caller reads when they name a guest quotes
    /// that fact. Answering "operates on host-owned project storage" for the
    /// host's log would send somebody to the wrong half of the product.
    case hostApplication

    /// Whether a connected guest's `hello.agent` answer has any bearing on
    /// this row.
    ///
    /// Derived from the domain rather than declared a second time. It is
    /// false for the two host-owned domains for one reason: a machine that
    /// declined to be read has declined about ITSELF, and applying that to
    /// this Mac's own storage would be a refusal with nothing behind it that
    /// a caller could act on.
    public var isGuestConsentRelevant: Bool {
        switch self {
        case .guest, .hostProjectsAndGuest: return true
        case .hostProjects, .hostApplication: return false
        }
    }

    /// The half-sentence a face uses when refusing a `guest` selector on a
    /// row that takes none. Beside the enum so the two host-owned domains
    /// cannot drift into one wording that is wrong for one of them.
    public var addressingRefusalSubject: String {
        switch self {
        case .hostProjects, .hostProjectsAndGuest:
            return "operates on host-owned project storage"
        case .hostApplication:
            return "reads this Mac's own application state"
        case .guest:
            return "operates on the connected Macintosh"
        }
    }
}

/// Whether one `HostCapabilityFace` reaches one capability, and the evidence
/// or the reason.
///
/// A row does not get to *assert* reach: for the app UI it names the file and
/// the affordance that proves it, and `HostFaceParityTests` reads that file.
/// A declaration nobody checks is prose, and prose goes stale.
public enum HostFaceReach: Sendable {
    /// The face reaches it, proven by `symbol` appearing in `file` (relative
    /// to `now-host/Sources/Host`). Name the CALL SITE a person's click
    /// reaches, not the function it calls — a handler left behind after its
    /// button was deleted proves nothing.
    ///
    /// **The known limit of that proof, stated where the next author will
    /// read it: it is `file.contains(symbol)` and nothing more.** It catches
    /// the failure it was built for — the affordance deleted or renamed, the
    /// file gone — and it cannot catch an affordance that is still *spelled*
    /// and no longer *reachable*. Concretely, all of these keep this check
    /// green while a person loses the capability:
    ///
    /// - the call site wrapped in `if false`, `#if`, or a feature flag;
    /// - the control left in place but permanently `.disabled(true)`;
    /// - the whole view no longer instantiated, because its module was
    ///   dropped from the sidebar registry — the file and the symbol both
    ///   survive untouched;
    /// - the symbol surviving only inside a comment or a `#Preview`;
    /// - **the symbol appearing SEVERAL TIMES in the file, so deleting the
    ///   affordance the row means changes nothing.** Added 2026-07-31 after
    ///   a gate audit: `now_list_processes` names `model.refresh()` in
    ///   `ProcessesModuleView.swift`, which contains three of them — the
    ///   Refresh button, an `.onAppear`, and a reconnect. Deleting the
    ///   button outright — the one affordance a person clicks, which is
    ///   what this case is defined to name — compiles and passes. A row
    ///   naming a symbol its file uses more than once is proving less than
    ///   it looks like, and picking a distinctive one is free.
    ///
    /// This is the same weakness the MCP face's check has and names: that one
    /// is textual over `NOWMCPServer`'s registry loop, so a `guard … continue`
    /// added inside the loop body would skip a row without changing any
    /// matched string. **The app-UI proof is weaker still, because a loop at
    /// least fails uniformly and a hand-built pane fails one row at a time.**
    ///
    /// It is documented rather than strengthened on purpose. Every cheap fix
    /// available here — stripping comments, rejecting a `.disabled` on the
    /// same line, walking from the module registry to the view — is a partial
    /// parser of Swift that would pass the four cases above in some spelling
    /// while *reading* as a reachability proof. An honest limit a reviewer can
    /// price beats a check that makes a false claim. The real proof of an
    /// app-UI face is a person clicking the control; treat `reached` as "the
    /// affordance was here when someone last looked", which is what a
    /// divergence review is for.
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
/// - **render** — publish neutral schemas and presentation data. MCP and
///   later faces render the same descriptor their own way, and none may
///   re-decide the answer.
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

    /// The guest capabilities a caller can actually **ask about** through this
    /// row — as distinct from those the row merely consumes to do its job.
    ///
    /// `requires` and this are different questions, and reading the first as
    /// an answer to the second is a blind spot with a live instance:
    /// `now_launch_software` requires `software.list` and uses it internally
    /// to match one name, so any check that counts "required by some
    /// projection" as coverage reads the software listing as covered — while
    /// no tool returns a listing at all. An agent can launch an application it
    /// can already name exactly and cannot ask what is installed. That gap
    /// wore a tick until this array existed.
    ///
    /// So the test: could a caller of this tool obtain that capability's own
    /// answer, or direct its effect? `now_launch_software` exposes `launch`
    /// (the caller chooses what is launched) and does **not** expose
    /// `software.list` (the catalog is consumed and discarded).
    /// `now_request_quit` exposes `process.quit` and not the `process.list` it
    /// revalidates a reference against.
    ///
    /// Necessarily a subset of `requires` — a projection cannot expose an
    /// answer it never had grounds to ask for — and `MCPCoverageTests` checks
    /// that. Empty is the honest common case: a row that only reads host state
    /// exposes nothing, and so does one whose guest traffic is entirely
    /// internal to its own composition.
    static var exposes: [String] { get }

    /// **Every argument key this projection accepts, declared once.**
    ///
    /// An unread parameter is indistinguishable from an absent one, and that
    /// is the whole reason this exists. A caller that sends
    /// `destinationPath` where the row's name is `toPath` has not sent a
    /// slightly-wrong request; it has sent a *different* request, and a
    /// surface that ignores the key it did not recognise performs that
    /// different request and reports success. The sibling Mirror project
    /// measured the cost of the fail-open version of this on a real machine
    /// (`mirror` 156b8ce): `modifiers` for `mods` dropped a Command key, so
    /// Command-Q typed a literal `q` into an open document, and the reply
    /// said `performed: true`. A misspelled VALUE was already refused there;
    /// a misspelled KEY was not, which is the worse half.
    ///
    /// **The set is read off this row's neutral operation descriptor, never
    /// guessed.** `HostProjectionArgumentStrictnessTests` asserts it equals
    /// the `inputSchema`'s `properties` keys for every registered row, which
    /// is what stops this declaration from rebuilding the same class of bug
    /// one row over: a hand-written set that has drifted from the schema is
    /// a surface that advertises one spelling and accepts another.
    ///
    /// Empty is a real answer and eight rows give it — they take no
    /// arguments at all, and were the only strict ones before this existed.
    /// There is deliberately no default implementation: a row that has not
    /// thought about its key namespace must fail to compile rather than
    /// inherit somebody else's answer.
    ///
    /// The envelope's own members are not listed here and must not be. The
    /// `guest` selector is lifted off in one place before a projection ever
    /// sees the arguments (`HostProjectionArguments.init`), so no row states
    /// it and none can forget to.
    static var acceptedArguments: Set<String> { get }

    static var authorityDomain: HostProjectionAuthorityDomain { get }

    /// Whether this capability can be addressed to one connected Macintosh.
    /// Host-owned project storage is deliberately outside that namespace.
    static var acceptsGuestAddressing: Bool { get }

    /// Which of the host's three faces reach this capability.
    ///
    /// Every face in `HostCapabilityFace.allCases` is stated, including the
    /// one that does not exist yet: a row that simply omits a face reads as
    /// parity nobody checked. Reach is evidence or a reason, never an
    /// assertion — see `HostFaceReach`.
    static var faces: [HostCapabilityFace: HostFaceReach] { get }

    /// One sentence for the caller, used when every requirement is met.
    /// The unavailable and unproven wordings are derived, so a row states
    /// only the fact it alone knows.
    static var availabilityNote: String { get }

    /// Transport-neutral title, summary, request/result schemas, stability,
    /// and typed effect hints. Protocol-specific names, addressing envelopes,
    /// and annotations are injected by their renderers.
    static var operationDescriptor: NOWOperationDescriptor { get }

    /// Validate, bound, and delegate. Everything a caller may ask is
    /// checked here; nothing about the machine is answered here.
    static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome
}

extension HostProjection {
    public static var authorityDomain: HostProjectionAuthorityDomain { .guest }
    public static var acceptsGuestAddressing: Bool { true }
}

/// The arguments of one call, after the `guest` selector has been lifted.
///
/// It carries `Any?` rather than a dictionary because absent and empty are
/// different facts on this surface: three projections accept no arguments
/// at all and must reject a non-empty object while still accepting a call
/// that omits the member entirely.
/// Safe to transfer because the initializer receives the request's private
/// JSON graph after the face has finished removing envelope members, and this
/// value exposes that graph read-only. JSONSerialization cannot express that
/// guarantee in `Any`, so the compiler cannot derive Sendable for it.
public struct HostProjectionArguments: @unchecked Sendable {
    /// Exactly what arrived as `params.arguments`, less `guest`.
    public let raw: Any?
    /// Immutable authority attached by the invoking server session. It is
    /// envelope context, never a caller-controlled tool argument.
    public let workspaceGrant: HostWorkspaceGrant?

    /// **The envelope's own members: addressing, not arguments.**
    ///
    /// `guest` says WHICH machine a call is about. It is a property of the
    /// call rather than of the capability, so no row lists it in
    /// `acceptedArguments` and every row would otherwise refuse it the
    /// moment argument keys became strict.
    ///
    /// The MCP face already removes it before constructing these arguments,
    /// and this lift is deliberately kept anyway: the face that removes it is
    /// one of three, and an exemption that only exists inside one caller is
    /// an exemption the next face has to rediscover. Stated once, here, where
    /// the strictness is.
    public static let envelopeMembers: Set<String> = ["guest"]

    public init(raw: Any?, workspaceGrant: HostWorkspaceGrant? = nil) {
        self.workspaceGrant = workspaceGrant
        guard let object = raw as? [String: Any],
              object.keys.contains(where: Self.envelopeMembers.contains)
        else {
            self.raw = raw
            return
        }
        self.raw = object.filter { !Self.envelopeMembers.contains($0.key) }
    }

    /// The arguments as an object, or nil when the caller sent something
    /// else — a projection that requires arguments refuses that.
    public var object: [String: Any]? { raw as? [String: Any] }

    /// The arguments as an object, treating absent as empty. For the
    /// projections whose every member is optional.
    public var objectOrEmpty: [String: Any] { object ?? [:] }

    /// The shared bound for a projection that takes nothing: absent or an
    /// empty object pass, anything else is refused with one wording.
    ///
    /// Kept beside `refusalForUnknownMembers` rather than folded into it
    /// because it refuses one thing that one cannot: arguments that are not
    /// an object at all. An unknown *key* is only a question you can ask of
    /// something with keys, and a row that wants a member out of a JSON array
    /// has a different complaint to make.
    public func refusalIfAnyPresent(
        tool: HostCapabilityID
    ) -> String? {
        guard let raw else { return nil }
        guard let object = raw as? [String: Any], object.isEmpty else {
            return "\(tool.rawValue) accepts no arguments"
        }
        return nil
    }

    /// **Refuse a key the projection does not know, naming both halves.**
    ///
    /// The wording is the point, not just the refusal. "Unknown parameter"
    /// leaves a caller guessing which of `toPath` and `destinationPath` is
    /// the real one, and guessing is the failure being fixed — so the
    /// sentence carries what arrived AND what the row would have taken, and
    /// the caller's next attempt is informed rather than another coin flip.
    ///
    /// Sorted, so one call's refusal reads the same as the next one's and a
    /// test can assert the whole sentence rather than a substring.
    ///
    /// Returns nil when the arguments are not an object: `refusalIfAnyPresent`
    /// and each row's own decoding own that case.
    public func refusalForUnknownMembers(
        tool: HostCapabilityID,
        accepting accepted: Set<String>
    ) -> String? {
        guard let object = raw as? [String: Any] else { return nil }
        let unknown = Set(object.keys).subtracting(accepted)
        guard !unknown.isEmpty else { return nil }
        guard !accepted.isEmpty else {
            /* One wording for the rows that take nothing, and it is the
               wording they already had: "does not accept x; it accepts
               nothing" is a worse sentence than the one this surface has
               been answering with since the first empty row. */
            return "\(tool.rawValue) accepts no arguments"
        }
        return "\(tool.rawValue) does not accept "
            + unknown.sorted().joined(separator: ", ")
            + "; it accepts "
            + accepted.sorted().joined(separator: ", ")
    }
}

/// What a projection hands back: one typed result to render, or the reason
/// the call was not well formed. A projection never renders the transport's
/// error itself — that is the face's job.
public enum HostProjectionOutcome: Sendable {
    case value(HostProjectionValue)
    /// The caller's arguments were refused. The text is written for that
    /// caller and says what the projection would have accepted.
    case invalidArguments(String)
    /// **The machine declined**, so the projection never ran.
    ///
    /// A separate case rather than a `value` carrying an `unavailable`, and
    /// that is the whole point of the type: `unavailable` means the machine
    /// or the host cannot, and this means it can and its owner said no. A
    /// caller that cannot tell those apart reports a broken capability, and
    /// somebody spends an afternoon on a machine that is working.
    ///
    /// Only `HostProjectionDispatch` produces it — a projection cannot,
    /// because the check runs before `invoke` and nothing reaches the row.
    case deniedByConsent(HostProjectionConsentDenial)
}

/// One projection result, kept encodable without the face having to know
/// which of a dozen result types it is holding.
///
/// **Twelve capabilities answered in JSON; the thirteenth answers with an
/// image**, and that is why this type gained a second half. A capture's
/// bytes cannot go in the encodable part: the MCP face renders a result
/// twice — once as `structuredContent` and once as the text block beside it —
/// so a 300 KB screen in a JSON field arrives as 600 KB of base64 in
/// somebody's context window. So the picture travels as an ATTACHMENT,
/// exactly once, and each face renders it in its own idiom (the MCP face as
/// an `image` content block).
///
/// It is deliberately not a general blob: an attachment is a rendering of
/// the same answer the encodable part describes, never a second answer. A
/// row whose metadata says one thing and whose attachment shows another
/// would be two facts about one machine.
public struct HostProjectionValue: Sendable {
    /// The semantic result proved while the producer's result is still
    /// strongly typed. Transport adapters copy this value; they never infer
    /// it by inspecting encoded JSON.
    public enum Disposition: String, Equatable, Sendable {
        case completed, refused, unavailable, failed
    }

    /// A non-JSON rendering of this result, for faces that can carry one.
    public enum Attachment: Sendable {
        /// Image bytes and their media type — `image/png` for a capture.
        case image(bytes: Data, mimeType: String)
    }

    private let encodeValue: @Sendable (JSONEncoder) throws -> Data
    public let disposition: Disposition
    public let attachment: Attachment?

    public init<Value: Encodable & Sendable>(
        _ value: Value,
        disposition: Disposition,
        attachment: Attachment? = nil
    ) {
        encodeValue = { try $0.encode(value) }
        self.disposition = disposition
        self.attachment = attachment
    }

    public func encoded(using encoder: JSONEncoder) throws -> Data {
        try encodeValue(encoder)
    }
}

// MARK: - Typed public result families

extension HostProjectionValue {
    public init(_ value: AgentIntegrationChatResult) {
        self.init(value, disposition: value.ok ? .completed : .unavailable)
    }

    public init(_ value: AgentIntegrationProjectResult) {
        self.init(value, disposition: value.ok ? .completed : .unavailable)
    }

    public init(_ value: AgentIntegrationArtifactTransferResult) {
        let disposition: Disposition
        switch value {
        case .delivered: disposition = .completed
        case .unavailable: disposition = .unavailable
        case .expired, .refused: disposition = .refused
        case .failed: disposition = .failed
        }
        self.init(value, disposition: disposition)
    }

    public init<Value: Codable & Equatable & Sendable>(
        _ value: AgentIntegrationProjectedResult<Value>,
        attachment: Attachment? = nil
    ) {
        let disposition: Disposition
        switch value {
        case .completed: disposition = .completed
        case .refused: disposition = .refused
        case .unavailable: disposition = .unavailable
        }
        self.init(value, disposition: disposition, attachment: attachment)
    }

    public init<Value: Codable & Equatable & Sendable>(
        _ value: AgentIntegrationGuestFileResult<Value>,
        attachment: Attachment? = nil
    ) {
        let disposition: Disposition
        switch value {
        case .hostUnavailable:
            disposition = .unavailable
        case .completed(let receipt, _, _):
            switch receipt.outcome {
            case .success: disposition = .completed
            case .unavailable: disposition = .unavailable
            case .failed: disposition = .failed
            case .staleSession, .notFound, .scanLimit, .refused, .expired,
                 .conflict:
                disposition = .refused
            }
        }
        self.init(value, disposition: disposition, attachment: attachment)
    }

    public init(_ value: AgentIntegrationSessionHealthResult) {
        let disposition: Disposition
        switch value {
        case .available: disposition = .completed
        case .unavailable: disposition = .unavailable
        }
        self.init(value, disposition: disposition)
    }

    public init(_ value: AgentIntegrationSessionCapabilitiesResult) {
        let disposition: Disposition
        switch value {
        case .available: disposition = .completed
        case .unavailable: disposition = .unavailable
        }
        self.init(value, disposition: disposition)
    }

    public init(_ value: AgentIntegrationProcessListResult) {
        let disposition: Disposition
        switch value {
        case .available: disposition = .completed
        case .unavailable: disposition = .unavailable
        }
        self.init(value, disposition: disposition)
    }

    public init(_ value: AgentIntegrationLaunchSoftwareResult) {
        let disposition: Disposition
        switch value {
        case .launched: disposition = .completed
        case .unavailable: disposition = .unavailable
        case .ambiguous, .notFound, .refused: disposition = .refused
        }
        self.init(value, disposition: disposition)
    }

    public init(_ value: AgentIntegrationQuitResult) {
        let disposition: Disposition
        switch value {
        case .requestSent: disposition = .completed
        case .unavailable: disposition = .unavailable
        case .stale, .notFound, .refused: disposition = .refused
        }
        self.init(value, disposition: disposition)
    }

    public init(_ value: AgentIntegrationCaptureAnswer,
                attachment: Attachment? = nil) {
        let disposition: Disposition
        switch value.outcome {
        case .captured, .abandoned: disposition = .completed
        case .refused: disposition = .refused
        case .unavailable: disposition = .unavailable
        }
        self.init(value, disposition: disposition, attachment: attachment)
    }

    public init(_ value: AgentIntegrationStreamAnswer,
                attachment: Attachment? = nil) {
        let disposition: Disposition
        switch value.outcome {
        case .opened, .closed, .frame: disposition = .completed
        case .refused: disposition = .refused
        case .unavailable: disposition = .unavailable
        }
        self.init(value, disposition: disposition, attachment: attachment)
    }

    public init(_ value: AgentIntegrationMirrorReadResult) {
        self.init(value, disposition: value.available ? .completed : .unavailable)
    }

    public init(_ value: AgentIntegrationMirrorDriveResult) {
        let disposition: Disposition
        if !value.available {
            disposition = .unavailable
        } else if value.operation?.outcome == "not-dispatched" {
            disposition = .refused
        } else {
            disposition = .completed
        }
        self.init(value, disposition: disposition)
    }

    public init(_ value: AgentIntegrationMirrorOpenResult) {
        self.init(value, disposition: value.showing ? .completed : .unavailable)
    }
}
