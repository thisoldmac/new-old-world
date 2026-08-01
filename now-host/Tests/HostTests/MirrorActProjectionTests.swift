import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **The act plane's rows, held to the properties that are about the PLANE
/// rather than about any one row.**
///
/// `WindowActProjection`, `ControlActProjection`, `MenuActProjection`,
/// `TextGetProjection` and `TextSetProjection` are in `HostProjectionCatalog`
/// as of 2026-07-31, so every registry-wide gate now sees them — this file is
/// no longer standing in for those. What it holds is what a registry-wide
/// gate cannot express: one addressing grammar across the plane, one dispatch
/// vocabulary, and one refusal that the rows share and that the other
/// twenty-odd have no opinion about.
///
/// **`now_observe_elements` is deliberately not held to these properties.**
/// It landed the same day and every row here depends on it, but it is an
/// observation: it has no target, answers a tree rather than a dispatch, and
/// sits a consent tier below all of these. Running act-plane properties over
/// it would either fail them or force each one to carve out the row it was
/// written about. The argument is in `MirrorActProjections`; the row is
/// covered by the registry-wide gates and by `MCPCoverageTests`.
///
/// It runs those properties over `MirrorActProjections.rows` and — where it
/// matters most — through the REAL `HostProjectionDispatch` over a registry
/// built from those three rows, so consent, the shared argument gate and the
/// audit line are exercised rather than asserted about.
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
/// | `WindowActProjection` registered in `HostProjectionCatalog` without folding its constant | `…ARowIsRegisteredExactlyWhenItsRequirementIsAKnownName` (and `MCPCoverageTests.testEveryRequirementResolvesToTheContract`, which is the reason these rows were unregistered) |
///
/// **And again at the fold, 2026-07-31, in both directions:**
///
/// | Mutation | Failed |
/// | --- | --- |
/// | `WindowActProjection` removed from `HostProjectionCatalog`, constant left folded | `…ARowIsRegisteredExactlyWhenItsRequirementIsAKnownName` |
/// | `windowActCommand` removed from `AgentIntegrationCapabilityNames.all`, row left registered | the same test, from the other side |
/// | `winact:` removed from the contract's `x-commands` | `MCPCoverageTests.testEveryRequirementResolvesToTheContract` |
/// | the three exempted in `CommandRegistryTests.servedByNoGuestYet` deleted | `…TheThreeHalvesAgreeOnTheCommandSet` |
/// | the act defaults returned to `.hostUnavailable` | `…AnActAgainstALiveHostSaysWhatIsMissing` |
/// | `now_text_set`'s row deleted from `docs/mcp-coverage.md` | `MCPCoverageTests.testTheProjectionTableMatchesTheRegistry` |
/// | `winact` listed in BOTH command-registry exemption maps | `CommandRegistryTests.testTheUnservedDeclarationsAreStillUnserved` |
/// | `reveal` — a verb the PowerPC guest does serve — added to `servedByNoGuestYet` | the same test, which is what keeps that list a debt rather than a drawer |
///
/// The three rows are registered, so the registry-wide gates cover them too:
/// `frontmost` added to `acceptedArguments` now fails
/// `HostProjectionArgumentStrictnessTests` as well as the two here.
final class MirrorActProjectionTests: XCTestCase {

    private var rows: [any HostProjection.Type] {
        MirrorActProjections.rows
    }

    private func registry() throws -> HostProjectionRegistry {
        try HostProjectionRegistry(MirrorActProjections.rows)
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

    /// One well-formed call per row, for the gates that need every row to get
    /// past its own argument decode and reach the client.
    ///
    /// Declared per row rather than filtered out of a shared bag, because
    /// what a legal call looks like is what each row's decode DEFINES: a bag
    /// filtered by `acceptedArguments` would send `now_menu_act` no arguments
    /// at all and read the resulting refusal as evidence about something
    /// else. Fresh references each call — they are minted here and never
    /// resolved, since no host lane carries one to a machine.
    private func wellFormedArguments(
        forCapability capability: String
    ) -> [String: Any] {
        switch capability {
        case WindowActProjection.capability.rawValue:
            return [
                "window": AgentIntegrationActPolicy.makeWindowReference(),
                "action": "zoom",
            ]
        case ControlActProjection.capability.rawValue:
            return [
                "element": AgentIntegrationActPolicy.makeElementReference(),
                "part": 10,
            ]
        case MenuActProjection.capability.rawValue:
            return ["menu": 128, "item": 1, "titleLeft": 8]
        case TextGetProjection.capability.rawValue:
            return [
                "element": AgentIntegrationActPolicy.makeElementReference(),
            ]
        case TextSetProjection.capability.rawValue:
            return [
                "element": AgentIntegrationActPolicy.makeElementReference(),
                "text": "hello",
            ]
        default:
            XCTFail(
                "\(capability) is in the act plane and this file does not "
                    + "know what a legal call to it looks like, so every "
                    + "gate below would read its argument refusal as the "
                    + "answer it was testing for.")
            return [:]
        }
    }

    /// The plane's capability names, built with a plain loop.
    ///
    /// A `rows.map(\.capability.rawValue)` inside an `XCTAssertEqual` is what
    /// it wants to be, and it crashes SILGen: lowering a key-path read off an
    /// existential metatype inside the assertion's autoclosure hits an
    /// unreachable in `Transform::transform` (Swift 6.2, watched 2026-07-31).
    /// Hoisted out and spelled long, which is also the only reason this
    /// helper is worth a name.
    private func planeCapabilityNames() -> Set<String> {
        var names: Set<String> = []
        for row in rows {
            names.insert(row.capability.rawValue)
        }
        return names
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

    /// Every requirement is one of the act commands, and nothing else leaked
    /// in — `elements` above all, which every row here depends on and none of
    /// them may REQUIRE: `requires` is a conjunction, so a row requiring the
    /// observation would switch itself off against a guest that serves the
    /// act, which is the silent-conjunction wall the three diagnostics were
    /// split to avoid.
    func testEveryActRequirementIsOneOfTheActCommands() {
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
    ///
    /// **`now_menu_act` is the one exception and it is checked separately**,
    /// below, rather than waived. A menu press carries no handle to name, so
    /// its identity is the press itself; the property this test states still
    /// holds there in the form that matters — the request must name what it
    /// is about, and cannot be spelled without it — but the thing it names is
    /// a coordinate rather than a reference.
    func testEveryActRowRequiresAnOpaqueReferenceAsItsTarget() {
        let targets: [(any HostProjection.Type, String, String)] = [
            (WindowActProjection.self, "window",
             AgentIntegrationActPolicy.windowReferencePattern),
            (ControlActProjection.self, "element",
             AgentIntegrationActPolicy.elementReferencePattern),
            (TextGetProjection.self, "element",
             AgentIntegrationActPolicy.elementReferencePattern),
            (TextSetProjection.self, "element",
             AgentIntegrationActPolicy.elementReferencePattern),
        ]
        /* Spelled as a loop rather than a map over the tuples: SILGen
           crashes lowering a closure that reads a member off an existential
           metatype inside one (Swift 6.2, 2026-07-31). */
        var addressed: Set<String> = [MenuActProjection.capability.rawValue]
        for (row, _, _) in targets {
            addressed.insert(row.capability.rawValue)
        }
        let plane = planeCapabilityNames()
        XCTAssertEqual(
            addressed, plane,
            "An act row states no target here. Every row in the plane is "
                + "either reference-addressed and listed above, or is the "
                + "menu act whose identity check is asserted below — a row "
                + "that is neither has a target nothing checks.")
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

    /// **The menu act names its target too, and its target is a
    /// coordinate.**
    ///
    /// `titleLeft` is where the press will land, and it is required for the
    /// same reason every other row requires a reference: without it there is
    /// no way to tell this act's press from the one the person at the machine
    /// is making. A host that derived it from `menu` would be guessing where
    /// a title sits, and a wrong guess either misses or matches the user's.
    ///
    /// It is asserted here rather than folded into the reference test because
    /// the two are different mechanisms with the same purpose, and a test
    /// that called a coordinate a reference would make the exception
    /// invisible.
    func testTheMenuActsIdentityCheckIsRequiredAndPublished() {
        let required = Set(
            (schema(MenuActProjection.self, "inputSchema")["required"]
                as? [String]) ?? [])
        XCTAssertEqual(
            required, ["menu", "item", "titleLeft"],
            "now_menu_act's required keys are \(required.sorted()). Its "
                + "identity check is titleLeft; a call that can omit it is a "
                + "call that cannot be told from the user's own press.")
        let property = inputProperties(MenuActProjection.self)["titleLeft"]
            as? [String: Any]
        XCTAssertNotNil(property?["minimum"])
        XCTAssertNotNil(property?["maximum"])
        XCTAssertTrue(
            ((property?["description"] as? String) ?? "")
                .contains("identity"),
            "now_menu_act publishes titleLeft without saying it is the "
                + "identity check, so a caller reads it as a coordinate to "
                + "supply rather than the thing that keeps the act apart "
                + "from a person's press.")
    }

    /// An act with no target is refused, and the refusal is about the
    /// target.
    ///
    /// The expected word is declared per row rather than derived, because
    /// what a row calls its target is exactly what this test exists to pin —
    /// a derivation would agree with whatever the row happened to say.
    func testAnActWithNoTargetIsRefusedNamingTheTarget() async {
        let targetWords: [String: String] = [
            WindowActProjection.capability.rawValue: "window",
            ControlActProjection.capability.rawValue: "element",
            MenuActProjection.capability.rawValue: "titleLeft",
            TextGetProjection.capability.rawValue: "element",
            TextSetProjection.capability.rawValue: "element",
        ]
        let plane = planeCapabilityNames()
        XCTAssertEqual(
            Set(targetWords.keys), plane,
            "An act row names no target word here, so the call below would "
                + "assert nothing about it.")
        let client = NoHostActClient()
        for row in rows {
            let outcome = await row.invoke(.init(raw: [:]), through: client)
            guard case .invalidArguments(let message) = outcome else {
                XCTFail(
                    "\(row.capability) accepted a call with no target: "
                        + "\(outcome)")
                continue
            }
            let key = targetWords[row.capability.rawValue] ?? ""
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

    /// The read sits below the line and every drive verb sits above it. This
    /// is what makes one row per side of the tier boundary worth having.
    ///
    /// The observation that mints these rows' targets sits below the line
    /// too, and is asserted here because that is the pair that makes the
    /// tiers mean something: a machine whose owner consented to being READ
    /// can be observed and its text read, and every act on what the
    /// observation named is refused above it.
    func testTheReadsAreReadOnlyAndEveryDriveIsFullAccess() {
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: TextGetProjection.self), .readOnly)
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: ObserveElementsProjection.self), .readOnly)
        for row in rows where row.capability != TextGetProjection.capability {
            let tier = HostCapabilityTierDerivation.requiredTier(of: row)
            let name = row.capability.rawValue
            XCTAssertEqual(
                tier, .fullAccess,
                "\(name) drives a guest application and does not sit in the "
                    + "fullAccess tier.")
        }
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

        for row in rows where row.capability != TextGetProjection.capability {
            let outcome = await HostProjectionDispatch(
                face: .mcp, registry: registry, audit: ActAuditSpy()
            ).invoke(
                row.capability.rawValue,
                arguments: .init(raw: wellFormedArguments(forCapability: row.capability.rawValue)),
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
        let control = try encoder.encode(
            AgentIntegrationControlActResult.completed(.init(
                element: AgentIntegrationActPolicy.makeElementReference(),
                part: 10,
                dispatch: .dispatched,
                dispatchedAt: Date(timeIntervalSince1970: 0))))
        let menu = try encoder.encode(
            AgentIntegrationMenuActResult.completed(.init(
                menu: 128, item: 1, titleLeft: 8,
                dispatch: .dispatched,
                dispatchedAt: Date(timeIntervalSince1970: 0))))
        for payload in [window, text, control, menu] {
            let json = String(decoding: payload, as: UTF8.self)
            for claim in ["performed", "succeeded", "applied", "moved",
                          "changed"] {
                XCTAssertFalse(
                    json.contains(claim),
                    "An act receipt claims \"\(claim)\": \(json)")
            }
            XCTAssertTrue(json.contains("dispatched"), json)
        }
        /* Every row that publishes a `dispatch` says what it does NOT mean,
           which is the read `now_text_get` alone is exempt from — it
           publishes a reading rather than a dispatch. */
        for row in rows where row.capability != TextGetProjection.capability {
            let rendered = "\(row.mcpDescriptor)"
            let name = row.capability.rawValue
            XCTAssertTrue(
                rendered.contains("NOT a claim"),
                "\(name) publishes a dispatch without saying what it does "
                    + "not mean.")
        }
    }

    /// A well-formed act against a host with no act lane is typed
    /// unavailable — not an empty success, and not a crash.
    func testAWellFormedActAgainstNoActLaneIsTypedUnavailable() async throws {
        for row in rows {
            let outcome = await row.invoke(
                .init(raw: wellFormedArguments(forCapability: row.capability.rawValue)),
                through: NoHostActClient())
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

    /// **A published row against a REACHABLE host says what is actually
    /// missing**, rather than blaming a host that is up.
    ///
    /// This is the one thing registration changed about the act lanes'
    /// behaviour and it is worth a gate of its own. While the rows were
    /// unregistered, the only client that could reach these defaults was a
    /// stub with no host, and `.hostUnavailable` — "New Old World host is
    /// unavailable" — was true. Registering them made the same defaults
    /// reachable from the real local client, where the app is running and a
    /// Macintosh is connected, and the sentence became false about the one
    /// thing a caller could check.
    ///
    /// The outcome is unchanged and must stay so: typed `unavailable`, never
    /// a refusal, never an empty success. Only the reason moved.
    func testAnActAgainstALiveHostSaysWhatIsMissing() async throws {
        for row in rows {
            let outcome = await HostProjectionDispatch(
                face: .mcp, registry: try registry(), audit: ActAuditSpy()
            ).invoke(
                row.capability.rawValue,
                arguments: .init(raw: wellFormedArguments(forCapability: row.capability.rawValue)),
                guest: "pb1400c",
                through: ConsentActClient(access: .fullAccess))
            guard case .value(let value) = outcome else {
                XCTFail(
                    "\(row.capability) did not answer a well-formed call "
                        + "against a consenting machine: "
                        + "\(String(describing: outcome))")
                continue
            }
            let json = String(
                decoding: try value.encoded(using: JSONEncoder()),
                as: UTF8.self)
            XCTAssertTrue(
                json.contains("\"outcome\":\"unavailable\""),
                "\(row.capability) answered something other than typed "
                    + "unavailability: \(json)")
            XCTAssertTrue(
                json.contains("now-act-lane-absent"),
                "\(row.capability) is unavailable for some reason other "
                    + "than the missing act lane: \(json)")
            XCTAssertFalse(
                json.contains(AgentIntegrationUnavailable.host.code),
                "\(row.capability) blamed an unreachable host while the "
                    + "host answered its session health: \(json)")
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
