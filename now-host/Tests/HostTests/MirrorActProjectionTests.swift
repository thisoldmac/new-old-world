import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **The act plane's rows, held to the published rows' standard before they
/// are published.**
///
/// `WindowActProjection`, `TextGetProjection` and `TextSetProjection` are not
/// in `HostProjectionCatalog` — NOW's contract declares no act plane, so a
/// registered row would publish a tool whose requirement resolves to nothing
/// (`MirrorActProjections` says why in full). Every registry-wide gate
/// therefore skips them, which would leave three unwatched rows in the tree.
///
/// So this file runs those properties over `MirrorActProjections.pending`
/// itself, and — where it matters most — through the REAL
/// `HostProjectionDispatch` over a registry built from those three rows, so
/// consent, the shared argument gate and the audit line are exercised rather
/// than asserted about.
///
/// Two upstream MEASUREMENTS are what the interesting half of this file
/// checks, and they are properties of the design rather than of the code:
///
/// 1. **Identity is the guard.** A request that merely disarmed after one use
///    rode the user's own press 18/20; one that named its exact target
///    hijacked 0/20. So no act row may accept a target-free selector, and
///    every act must name one.
/// 2. **`performed: true` is not evidence.** So no receipt on this surface
///    may spell a success that means "and it worked".
///
/// **Every gate here was watched failing (2026-07-31), by mutation:**
///
/// | Mutation | Failed |
/// | --- | --- |
/// | `frontmost` added to `WindowActProjection.acceptedArguments` | `…NoActRowAcceptsATargetFreeSelector`, `…AcceptedSetIsExactlyItsPublishedProperties` |
/// | `TextGetProjection` annotations spelled `readOnlyHint: false` | `…TheReadIsReadOnlyAndTheTwoActsAreFullAccess`, `…AReadOnlyMachineRefusesTheActsAndNotTheRead` |
/// | `TextSetProjection.invoke` checks the text before the target | `…TheTargetIsRefusedBeforeTheText` |
/// | a `performed` case added to `AgentIntegrationActDispatch` | `…AnActCanOnlyClaimDispatch` |
/// | `present == expected` relaxed to `isSuperset(of:)` in the window decode | `…AnActionIsRefusedGeometryItDoesNotTake` |
/// | `WindowActProjection` registered in `HostProjectionCatalog` without folding its constant | `…ARowIsRegisteredExactlyWhenItsRequirementIsAKnownName` (and `MCPCoverageTests.testEveryRequirementResolvesToTheContract`, which is the reason these rows are unregistered) |
final class MirrorActProjectionTests: XCTestCase {

    private var rows: [any HostProjection.Type] {
        MirrorActProjections.pending
    }

    private func registry() throws -> HostProjectionRegistry {
        try HostProjectionRegistry(MirrorActProjections.pending)
    }

    private func schema(
        _ projection: any HostProjection.Type, _ key: String
    ) -> [String: Any] {
        (projection.mcpDescriptor[key] as? [String: Any]) ?? [:]
    }

    private func inputProperties(
        _ projection: any HostProjection.Type
    ) -> [String: Any] {
        (schema(projection, "inputSchema")["properties"]
            as? [String: Any]) ?? [:]
    }

    // MARK: - The row properties every registered row is held to

    func testEveryActRowStatesEveryFace() {
        for row in rows {
            for face in HostCapabilityFace.allCases {
                XCTAssertNotNil(
                    row.faces[face],
                    "\(row.capability) says nothing about the \(face.rawValue) "
                        + "face. A face a row omits reads as parity nobody "
                        + "checked.")
            }
        }
    }

    func testEveryActRowExposesOnlyWhatItRequires() {
        for row in rows {
            let extra = Set(row.exposes).subtracting(row.requires)
            XCTAssertTrue(
                extra.isEmpty,
                "\(row.capability) exposes \(extra.sorted()) and does not "
                    + "require it, so it is handing back an answer it never "
                    + "had grounds to ask for.")
        }
    }

    /// The declaration is read off the published schema, never guessed —
    /// the property that stops a surface advertising one spelling and
    /// accepting another.
    func testEveryActRowsAcceptedSetIsExactlyItsPublishedProperties() {
        for row in rows {
            XCTAssertEqual(
                row.acceptedArguments, Set(inputProperties(row).keys),
                "\(row.capability) accepts "
                    + "\(row.acceptedArguments.sorted()) and publishes "
                    + "\(inputProperties(row).keys.sorted()). One of the two "
                    + "is the lie a caller reads.")
        }
    }

    func testEveryActRowsSchemaIsClosedAndClaimsNoEnvelopeMember() {
        for row in rows {
            XCTAssertEqual(
                schema(row, "inputSchema")["additionalProperties"] as? Bool,
                false,
                "\(row.capability) publishes an open input schema.")
            let envelope = row.acceptedArguments.intersection(
                HostProjectionArguments.envelopeMembers)
            XCTAssertTrue(
                envelope.isEmpty,
                "\(row.capability) claims the envelope member "
                    + "\(envelope.sorted()) as its own argument; addressing "
                    + "is lifted off before a row sees the arguments.")
        }
    }

    func testEveryActRowRendersACompleteDescriptorWithoutItsOwnName() {
        for row in rows {
            let descriptor = row.mcpDescriptor
            for key in ["title", "description", "inputSchema",
                        "outputSchema", "annotations"] {
                XCTAssertNotNil(
                    descriptor[key],
                    "\(row.capability) renders no \(key).")
            }
            XCTAssertNil(
                descriptor["name"],
                "\(row.capability) spells its own name in its descriptor; "
                    + "the renderer injects it so a row cannot misspell its "
                    + "own identity.")
            XCTAssertFalse(
                row.availabilityNote.isEmpty,
                "\(row.capability) states no availability note.")
        }
    }

    /// Every requirement is one of the three act commands, and nothing else
    /// leaked in.
    func testEveryActRequirementIsOneOfTheThreeActCommands() {
        for row in rows {
            for requirement in row.requires {
                XCTAssertTrue(
                    MirrorActProjections.requirements.contains(requirement),
                    "\(row.capability) requires \"\(requirement)\", which is "
                        + "not one of the act plane's commands "
                        + "\(MirrorActProjections.requirements.sorted()).")
            }
            XCTAssertFalse(
                row.requires.isEmpty,
                "\(row.capability) requires nothing, which means it is "
                    + "available whatever the guest implements — and this "
                    + "row cannot work without a guest that serves its "
                    + "command.")
        }
    }

    /// **The half-fold guard.** A row is registered exactly when its
    /// requirement is a name the capability namespace knows: registering
    /// without folding the constant publishes a tool the ledger cannot
    /// resolve, and folding the constant without registering leaves a name
    /// nothing uses.
    func testARowIsRegisteredExactlyWhenItsRequirementIsAKnownName() {
        for row in rows {
            let registered = HostProjectionCatalog.projections.contains {
                $0.capability == row.capability
            }
            let known = row.requires.allSatisfy(
                AgentIntegrationCapabilityNames.all.contains)
            XCTAssertEqual(
                registered, known,
                "\(row.capability) is \(registered ? "" : "not ")registered "
                    + "and its requirements are \(known ? "" : "not ")in "
                    + "AgentIntegrationCapabilityNames.all. Registration, "
                    + "the folded constants and the contract's x-commands "
                    + "entry land in one edit — see MirrorActProjections.")
        }
    }

    // MARK: - Identity is the guard (measured 18/20 → 0/20)

    /// **No act row may accept a target-free selector.**
    ///
    /// The banned spellings are the ways a surface usually says "whatever is
    /// in front", which is the shape that rode the user's own press 18/20.
    /// A row that grew one would have re-introduced the defect under a new
    /// name, and this is the check that notices.
    func testNoActRowAcceptsATargetFreeSelector() {
        let targetFree: Set<String> = [
            "frontmost", "front", "focused", "focus", "active", "current",
            "topmost", "selection", "selected", "title", "windowTitle",
            "name", "any",
        ]
        for row in rows {
            let offending = row.acceptedArguments.intersection(targetFree)
            XCTAssertTrue(
                offending.isEmpty,
                "\(row.capability) accepts \(offending.sorted()), which lets "
                    + "a caller act on whatever the machine happens to be "
                    + "showing. Measured upstream: a request that cannot "
                    + "name its exact target rode the user's own press "
                    + "18/20; one that named it hijacked 0/20.")
        }
    }

    /// Every act row's target argument is an opaque reference, is required,
    /// and is published with the pattern that bounds it.
    func testEveryActRowRequiresAnOpaqueReferenceAsItsTarget() {
        let targets: [(any HostProjection.Type, String, String)] = [
            (WindowActProjection.self, "window",
             AgentIntegrationActPolicy.windowReferencePattern),
            (TextGetProjection.self, "element",
             AgentIntegrationActPolicy.elementReferencePattern),
            (TextSetProjection.self, "element",
             AgentIntegrationActPolicy.elementReferencePattern),
        ]
        for (row, key, pattern) in targets {
            let required = Set(
                (schema(row, "inputSchema")["required"] as? [String]) ?? [])
            XCTAssertTrue(
                required.contains(key),
                "\(row.capability) does not require \(key), so a call with "
                    + "no target is a well-formed call.")
            let property = inputProperties(row)[key] as? [String: Any]
            XCTAssertEqual(
                property?["pattern"] as? String, pattern,
                "\(row.capability)'s \(key) is published without the opaque "
                    + "reference pattern, so any string reads as a target.")
        }
    }

    /// An act with no target is refused, and the refusal is about the
    /// target.
    func testAnActWithNoTargetIsRefusedNamingTheTarget() async {
        let client = NoHostActClient()
        for row in rows {
            let outcome = await row.invoke(.init(raw: [:]), through: client)
            guard case .invalidArguments(let message) = outcome else {
                XCTFail(
                    "\(row.capability) accepted a call with no target: "
                        + "\(outcome)")
                continue
            }
            let key = row.capability == WindowActProjection.capability
                ? "window" : "element"
            XCTAssertTrue(
                message.contains(key),
                "\(row.capability) refused a target-free call without "
                    + "naming the target it needed: \(message)")
        }
    }

    /// A plausible-but-wrong target spelling is refused naming both halves,
    /// rather than performing a different act and reporting success.
    func testAPlausibleWrongTargetSpellingIsRefusedNamingBothHalves() async {
        let dispatch = try? registry()
        XCTAssertNotNil(dispatch)
        let outcome = await HostProjectionDispatch(
            face: .mcp, registry: try! registry(), audit: ActAuditSpy()
        ).invoke(
            WindowActProjection.capability.rawValue,
            arguments: .init(raw: [
                "windowTitle": "Untitled",
                "action": "close",
            ]),
            guest: nil,
            through: NoHostActClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail(
                "now_window_act accepted windowTitle: \(String(describing: outcome))")
        }
        XCTAssertTrue(
            message.contains("windowTitle"),
            "The refusal does not say what arrived: \(message)")
        XCTAssertTrue(
            message.contains("window"),
            "The refusal does not say what the row would have taken: "
                + "\(message)")
    }

    // MARK: - Ordered refusals

    /// **The target is checked before the payload**, so a caller that sent
    /// neither is told about the thing that matters. Ordered rather than
    /// early: the call carries a bad target AND an over-long text, and only
    /// one of the two sentences is the right one.
    func testTheTargetIsRefusedBeforeTheText() async {
        let outcome = await TextSetProjection.invoke(
            .init(raw: [
                "element": "the front field",
                "text": String(
                    repeating: "x",
                    count: AgentIntegrationActPolicy.maximumTextScalars + 1),
            ]),
            through: NoHostActClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("A bad element was accepted: \(outcome)")
        }
        XCTAssertTrue(
            message.contains("element"),
            "The first thing a caller is told about is not the target: "
                + "\(message)")
        XCTAssertFalse(
            message.contains("characters"),
            "The text bound was reported ahead of the invalid target: "
                + "\(message)")
    }

    /// The shared key gate runs before the row decodes anything, so an
    /// unknown key is refused even though the target is also invalid.
    func testAnUnknownKeyIsRefusedBeforeTheTargetIsDecoded() async {
        let outcome = await WindowActProjection.invoke(
            .init(raw: [
                "window": "not-a-reference",
                "action": "zoom",
                "nowNoActRowAcceptsThisParameter": true,
            ]),
            through: NoHostActClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("An unknown key was accepted: \(outcome)")
        }
        XCTAssertTrue(
            message.contains("nowNoActRowAcceptsThisParameter"),
            "The unknown key was not the complaint: \(message)")
    }

    // MARK: - Per-action geometry

    func testAnActionIsRefusedGeometryItDoesNotTake() async {
        let outcome = await WindowActProjection.invoke(
            .init(raw: [
                "window": AgentIntegrationActPolicy.makeWindowReference(),
                "action": "close",
                "width": 400,
            ]),
            through: NoHostActClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("A close carrying a width was accepted: \(outcome)")
        }
        XCTAssertTrue(
            message.contains("close") && message.contains("width"),
            "The refusal names neither the action nor what it was sent: "
                + "\(message)")
    }

    func testAnActionIsRefusedIncompleteGeometry() async {
        let outcome = await WindowActProjection.invoke(
            .init(raw: [
                "window": AgentIntegrationActPolicy.makeWindowReference(),
                "action": "move",
                "left": 40,
            ]),
            through: NoHostActClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("A move with no top was accepted: \(outcome)")
        }
    }

    func testGeometryOutsideAQuickDrawRectIsRefused() async {
        let outcome = await WindowActProjection.invoke(
            .init(raw: [
                "window": AgentIntegrationActPolicy.makeWindowReference(),
                "action": "resize",
                "width": AgentIntegrationActPolicy.maximumCoordinate + 1,
                "height": 200,
            ]),
            through: NoHostActClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("An impossible width was accepted: \(outcome)")
        }
        XCTAssertTrue(message.contains("width"), message)
    }

    func testAZeroExtentIsRefused() async {
        let outcome = await WindowActProjection.invoke(
            .init(raw: [
                "window": AgentIntegrationActPolicy.makeWindowReference(),
                "action": "resize",
                "width": 0,
                "height": 200,
            ]),
            through: NoHostActClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("A zero width was accepted: \(outcome)")
        }
    }

    // MARK: - Consent tiers, through the real dispatch

    func testEveryActRowDeclaresBothHintsAndIsCoherent() {
        for row in rows {
            let readOnly = HostCapabilityTierDerivation.hint(
                "readOnlyHint", of: row)
            let destructive = HostCapabilityTierDerivation.hint(
                "destructiveHint", of: row)
            XCTAssertNotNil(
                readOnly,
                "\(row.capability) declares no readOnlyHint, which is what "
                    + "the consent tier is derived from.")
            XCTAssertNotNil(
                destructive,
                "\(row.capability) declares no destructiveHint.")
            XCTAssertFalse(
                readOnly == true && destructive == true,
                "\(row.capability) claims to be read-only and destructive at "
                    + "once; both cannot be true.")
        }
    }

    /// The read sits below the line and the two acts sit above it. This is
    /// what makes one row per side of the tier boundary worth having.
    func testTheReadIsReadOnlyAndTheTwoActsAreFullAccess() {
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: TextGetProjection.self), .readOnly)
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: TextSetProjection.self), .fullAccess)
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: WindowActProjection.self), .fullAccess)
    }

    /// **A machine that consented to being read serves the read and refuses
    /// both acts**, and the refusal is the typed consent denial rather than
    /// an unavailable.
    ///
    /// Run through the real dispatch, so the check that would gate these
    /// rows in production is the one under test. There is no spy on the act
    /// lane and there cannot be one: no client implements it, so every call
    /// reaches the "no host" default — the outcome CASE is the evidence that
    /// the row ran or did not.
    func testAReadOnlyMachineRefusesTheActsAndNotTheRead() async throws {
        let registry = try registry()
        let read = await HostProjectionDispatch(
            face: .mcp, registry: registry, audit: ActAuditSpy()
        ).invoke(
            TextGetProjection.capability.rawValue,
            arguments: .init(raw: [
                "element": AgentIntegrationActPolicy.makeElementReference(),
            ]),
            guest: "pb1400c",
            through: ConsentActClient(access: .readOnly))
        if case .deniedByConsent(let denial) = read {
            XCTFail("A read-only row was refused: \(denial.reason)")
        }

        for row in [WindowActProjection.self as any HostProjection.Type,
                    TextSetProjection.self] {
            let outcome = await HostProjectionDispatch(
                face: .mcp, registry: registry, audit: ActAuditSpy()
            ).invoke(
                row.capability.rawValue,
                arguments: .init(raw: [
                    "element":
                        AgentIntegrationActPolicy.makeElementReference(),
                    "text": "hello",
                    "window":
                        AgentIntegrationActPolicy.makeWindowReference(),
                    "action": "zoom",
                ].filter { row.acceptedArguments.contains($0.key) }),
                guest: "pb1400c",
                through: ConsentActClient(access: .readOnly))
            guard case .deniedByConsent(let denial) = outcome else {
                XCTFail(
                    "\(row.capability) ran under read-only consent: "
                        + "\(String(describing: outcome))")
                continue
            }
            XCTAssertEqual(denial.ground, .aboveGrantedTier)
            XCTAssertEqual(denial.requiredTier, .fullAccess)
        }
    }

    func testADisabledMachineRefusesEvenTheRead() async throws {
        let outcome = await HostProjectionDispatch(
            face: .mcp, registry: try registry(), audit: ActAuditSpy()
        ).invoke(
            TextGetProjection.capability.rawValue,
            arguments: .init(raw: [
                "element": AgentIntegrationActPolicy.makeElementReference(),
            ]),
            guest: "pb1400c",
            through: ConsentActClient(access: .disabled))
        guard case .deniedByConsent(let denial) = outcome else {
            return XCTFail(
                "A machine that declines was read as consent: "
                    + "\(String(describing: outcome))")
        }
        XCTAssertEqual(denial.ground, .machineDeclines)
    }

    // MARK: - The audit line

    /// Every act names itself in the audit line, whatever it came to.
    func testEveryActEmitsOneAuditEventNamingItself() async throws {
        let registry = try registry()
        for row in rows {
            let spy = ActAuditSpy()
            _ = await HostProjectionDispatch(
                face: .mcp, registry: registry, audit: spy
            ).invoke(
                row.capability.rawValue,
                arguments: .init(raw: [:]),
                guest: "pb1400c",
                through: NoHostActClient())
            let events = await spy.recorded()
            XCTAssertEqual(events.count, 1, "\(row.capability)")
            XCTAssertEqual(events.first?.capability,
                           row.capability.rawValue)
            XCTAssertEqual(events.first?.outcome, .refused)
            let line = events.first?.logMessage() ?? ""
            XCTAssertTrue(
                line.contains(row.capability.rawValue)
                    && line.contains("pb1400c"),
                "The line names neither the capability nor the machine: "
                    + line)
        }
    }

    /// A consent denial is its own audit outcome, not a shade of refused.
    func testADeniedActIsAuditedAsDenied() async throws {
        let spy = ActAuditSpy()
        _ = await HostProjectionDispatch(
            face: .mcp, registry: try registry(), audit: spy
        ).invoke(
            TextSetProjection.capability.rawValue,
            arguments: .init(raw: [
                "element": AgentIntegrationActPolicy.makeElementReference(),
                "text": "hello",
            ]),
            guest: "pb1400c",
            through: ConsentActClient(access: .readOnly))
        let events = await spy.recorded()
        XCTAssertEqual(events.first?.outcome, .denied)
    }

    // MARK: - Dispatched is all an act may claim

    /// **One case, and adding a second is a decision.** A `confirmed` is
    /// earned by re-reading the element, which nothing does yet; upstream
    /// measured what trusting a service's own `performed: true` is worth.
    func testAnActCanOnlyClaimDispatch() {
        XCTAssertEqual(
            AgentIntegrationActDispatch.allCases.map(\.rawValue),
            ["dispatched"],
            "The act vocabulary grew a second success. If something now "
                + "re-reads the element and confirms it, this test changes "
                + "with the receipt that carries the evidence — not before.")
    }

    /// No receipt on this surface spells a word that would mean "and it
    /// worked", and the published schemas do not either.
    func testNoActReceiptClaimsMoreThanDispatch() throws {
        let encoder = JSONEncoder()
        let window = try encoder.encode(
            AgentIntegrationWindowActResult.completed(.init(
                window: AgentIntegrationActPolicy.makeWindowReference(),
                action: .close,
                dispatch: .dispatched,
                dispatchedAt: Date(timeIntervalSince1970: 0))))
        let text = try encoder.encode(
            AgentIntegrationTextSetResult.completed(.init(
                element: AgentIntegrationActPolicy.makeElementReference(),
                requestedScalars: 5,
                dispatch: .dispatched,
                dispatchedAt: Date(timeIntervalSince1970: 0))))
        for payload in [window, text] {
            let json = String(decoding: payload, as: UTF8.self)
            for claim in ["performed", "succeeded", "applied", "moved",
                          "changed"] {
                XCTAssertFalse(
                    json.contains(claim),
                    "An act receipt claims \"\(claim)\": \(json)")
            }
            XCTAssertTrue(json.contains("dispatched"), json)
        }
        for row in [WindowActProjection.self as any HostProjection.Type,
                    TextSetProjection.self] {
            let rendered = "\(row.mcpDescriptor)"
            XCTAssertTrue(
                rendered.contains("NOT a claim"),
                "\(row.capability) publishes a dispatch without saying what "
                    + "it does not mean.")
        }
    }

    /// A well-formed act against a host with no act lane is typed
    /// unavailable — not an empty success, and not a crash.
    func testAWellFormedActAgainstNoActLaneIsTypedUnavailable() async throws {
        let calls: [(any HostProjection.Type, [String: Any])] = [
            (WindowActProjection.self, [
                "window": AgentIntegrationActPolicy.makeWindowReference(),
                "action": "zoom",
            ]),
            (TextGetProjection.self, [
                "element": AgentIntegrationActPolicy.makeElementReference(),
            ]),
            (TextSetProjection.self, [
                "element": AgentIntegrationActPolicy.makeElementReference(),
                "text": "",
            ]),
        ]
        for (row, arguments) in calls {
            let outcome = await row.invoke(
                .init(raw: arguments), through: NoHostActClient())
            guard case .value(let value) = outcome else {
                XCTFail(
                    "\(row.capability) refused a well-formed call: "
                        + "\(outcome)")
                continue
            }
            let json = String(
                decoding: try value.encoded(using: JSONEncoder()),
                as: UTF8.self)
            XCTAssertTrue(
                json.contains("\"outcome\":\"unavailable\""),
                "\(row.capability) answered something other than typed "
                    + "unavailability with no lane to ask: \(json)")
        }
    }

    // MARK: - References

    func testAReferenceIsOnlyValidWithItsOwnPrefix() {
        let window = AgentIntegrationActPolicy.makeWindowReference()
        let element = AgentIntegrationActPolicy.makeElementReference()
        XCTAssertTrue(
            AgentIntegrationActPolicy.isValidWindowReference(window))
        XCTAssertTrue(
            AgentIntegrationActPolicy.isValidElementReference(element))
        XCTAssertFalse(
            AgentIntegrationActPolicy.isValidWindowReference(element),
            "An element reference passed as a window: the two name "
                + "different kinds of thing and must not substitute.")
        XCTAssertFalse(
            AgentIntegrationActPolicy.isValidElementReference(window))
        XCTAssertFalse(
            AgentIntegrationActPolicy.isValidWindowReference(
                window.uppercased()))
        XCTAssertFalse(
            AgentIntegrationActPolicy.isValidWindowReference(
                window + "0"))
        XCTAssertFalse(
            AgentIntegrationActPolicy.isValidWindowReference("now-window-1"))
    }
}

/// What the dispatch reported, in order.
private actor ActAuditSpy: HostProjectionAuditSink {
    private var events: [HostProjectionAuditEvent] = []

    func record(_ event: HostProjectionAuditEvent) async {
        events.append(event)
    }

    func recorded() -> [HostProjectionAuditEvent] { events }
}

/// No host to ask, so consent never denies and the argument gate is what a
/// call meets. The act lanes answer through their own "no host" defaults.
private struct NoHostActClient: AgentIntegrationClient {
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.host)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.host)
    }

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.host)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.host)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.host)
    }
}

/// A reachable host with one machine connected that answered `hello.agent`
/// with `access`.
private struct ConsentActClient: AgentIntegrationClient {
    let access: AgentIntegrationGuestAccess?

    func addressing(_ selector: String?) -> AgentIntegrationClient { self }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .available(.init(
            state: .connected,
            observedAt: Date(timeIntervalSince1970: 0),
            listeningPort: 1400,
            sessionID: nil,
            guest: .init(name: "pb1400c", version: "0.1.0",
                         agentAccess: access,
                         operatingSystem: "Mac OS 9.1",
                         connectedAt: nil, lastTraffic: nil, quietFor: nil,
                         pingsAnswered: nil, framesReceived: nil),
            failure: nil))
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.guest)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.guest)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.guest)
    }

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        .unavailable(.guest)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.guest)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.guest)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.guest)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.guest)
    }
}
