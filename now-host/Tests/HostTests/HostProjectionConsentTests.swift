import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **The machine's answer, made to mean something.**
///
/// Three things are gated here, and they fail separately on purpose:
///
/// 1. The tier DERIVES. Every row publishes the hints the derivation reads,
///    and no row publishes two that cannot both be true — so the tier can
///    never become the fifth hand-maintained capability list this arc has
///    had to collapse (plan 006, stop condition 1).
/// 2. The ceiling maps every answer, including the two that are not tiers.
/// 3. The check is AT THE DISPATCH and refuses before the row runs, emits an
///    audit line when it does, and lets silence through.
final class HostProjectionConsentTests: XCTestCase {

    // MARK: - The tier derives

    /// Every registry row publishes both hints, as booleans.
    ///
    /// This is the gate that keeps the derivation honest. A row that
    /// published neither would still get a tier — `fullAccess`, the
    /// restrictive reading — and would get it by accident rather than by
    /// saying anything, which is exactly the silent membership a derived
    /// bucket has to refuse. Asked of the REGISTRY, so row twenty-seven is
    /// covered the day it lands.
    ///
    /// It reads the rendered descriptor rather than the source text, which
    /// matters: seven rows state their annotations through a shared fragment
    /// rather than a literal of their own, and a `grep` sees them as silent.
    func testEveryRowDeclaresBothHintsTheDerivationReads() {
        for projection in HostProjectionRegistry.hostFaces.projections {
            XCTAssertNotNil(
                HostCapabilityTierDerivation.hint(
                    "readOnlyHint", of: projection),
                "\(projection.capability) publishes no readOnlyHint, so its "
                    + "consent tier would be assigned rather than derived.")
            XCTAssertNotNil(
                HostCapabilityTierDerivation.hint(
                    "destructiveHint", of: projection),
                "\(projection.capability) publishes no destructiveHint, so "
                    + "nothing can check its two hints agree.")
        }
    }

    /// No row claims to be read-only AND destructive.
    ///
    /// The two hints cannot both be true of one capability, and this is what
    /// `destructiveHint` is FOR here: with two tiers it cannot move a row,
    /// so its job is to contradict a `readOnlyHint` that is wrong. A row
    /// that put a destructive capability behind Read Only would be caught
    /// here rather than by somebody's machine.
    func testNoRowIsBothReadOnlyAndDestructive() {
        for projection in HostProjectionRegistry.hostFaces.projections {
            let readOnly = HostCapabilityTierDerivation.hint(
                "readOnlyHint", of: projection)
            let destructive = HostCapabilityTierDerivation.hint(
                "destructiveHint", of: projection)
            XCTAssertFalse(
                readOnly == true && destructive == true,
                "\(projection.capability) declares itself read-only and "
                    + "destructive, so Read Only consent would admit a "
                    + "capability that destroys something.")
        }
    }

    /// The derivation is the hints and nothing else — spot-checked at both
    /// ends of the line rather than as a table, because a table of all
    /// twenty-six IS the list this must not become.
    func testTheTierFollowsTheReadOnlyHint() {
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: GuestFilesListProjection.self),
            .readOnly)
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: HardwareCensusProjection.self),
            .readOnly)
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: GuestFilesMutateProjection.self),
            .fullAccess)
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: RequestQuitProjection.self),
            .fullAccess)
        /* Reveal, stated because plan 006 expected it in Read Only and the
           derivation puts it in Full Access. Its own row declares
           `readOnlyHint: false` and argues why — it takes over the screen of
           whoever is sitting at the machine — and moving it would mean
           either lying in a published annotation an agent reads or adding
           the fourth field the plan forbids. So the row wins, and this line
           is here so the divergence is a decision somebody can find rather
           than an accident. */
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: RevealItemProjection.self),
            .fullAccess)
    }

    // MARK: - The ceiling

    func testDisabledPermitsNothing() {
        let ceiling = HostConsentCeiling.ceiling(for: .disabled)
        XCTAssertFalse(ceiling.permits(.readOnly))
        XCTAssertFalse(ceiling.permits(.fullAccess))
    }

    func testReadOnlyPermitsOnlyTheReadOnlyTier() {
        let ceiling = HostConsentCeiling.ceiling(for: .readOnly)
        XCTAssertTrue(ceiling.permits(.readOnly))
        XCTAssertFalse(ceiling.permits(.fullAccess))
    }

    func testFullAccessPermitsBoth() {
        let ceiling = HostConsentCeiling.ceiling(for: .fullAccess)
        XCTAssertTrue(ceiling.permits(.readOnly))
        XCTAssertTrue(ceiling.permits(.fullAccess))
    }

    /// **A tier this build cannot name permits nothing.**
    ///
    /// The alternative — treating it as at least Full Access — would make an
    /// older host the way to escape a newer machine's narrower ceiling, and
    /// a version skew must never open in that direction. Unlike silence, the
    /// machine answered: it stated a limit, and a receiver that cannot
    /// evaluate the limit cannot claim to be inside it.
    func testAnUnrecognizedTierPermitsNothing() {
        let ceiling = HostConsentCeiling.ceiling(for: .unrecognized("below"))
        XCTAssertFalse(ceiling.permits(.readOnly))
        XCTAssertFalse(ceiling.permits(.fullAccess))
    }

    // MARK: - The check, at the dispatch

    /// A machine that says `disabled` refuses even a read-only row, the row
    /// never runs, and the attempt is on the record.
    func testADisabledMachineRefusesAndTheRowNeverRuns() async {
        let spy = AuditSpy()
        let client = ConsentClient(access: .disabled)
        let dispatch = HostProjectionDispatch(face: .mcp, audit: spy)

        let outcome = await dispatch.invoke(
            ListProcessesProjection.capability.rawValue,
            arguments: .init(raw: nil),
            guest: "pb1400c",
            through: client)

        guard case .deniedByConsent(let denial) = outcome else {
            return XCTFail("A disabled machine did not refuse: \(outcome!)")
        }
        XCTAssertEqual(denial.ground, .machineDeclines)
        XCTAssertEqual(denial.machineAnswer, "disabled")
        XCTAssertEqual(denial.requiredTier, .readOnly)
        let asked = await client.recorder.asked
        XCTAssertFalse(
            asked,
            "The projection ran anyway, so the refusal happened after the "
                + "machine had already been driven.")
    }

    /// A read-only machine runs the read-only rows and refuses the rest,
    /// naming the tier it granted.
    func testAReadOnlyMachineRefusesOnlyWhatIsAboveIt() async {
        let readClient = ConsentClient(access: .readOnly)
        let allowed = await HostProjectionDispatch(face: .mcp, audit: AuditSpy())
            .invoke(ListProcessesProjection.capability.rawValue,
                    arguments: .init(raw: nil),
                    guest: nil, through: readClient)
        if case .deniedByConsent(let denial) = allowed {
            return XCTFail("A read-only row was refused: \(denial.reason)")
        }
        let asked = await readClient.recorder.asked
        XCTAssertTrue(asked, "The read-only row did not reach the machine.")

        let outcome = await HostProjectionDispatch(face: .mcp, audit: AuditSpy())
            .invoke(RequestQuitProjection.capability.rawValue,
                    arguments: .init(raw: ["process": "psn:1"]),
                    guest: nil, through: ConsentClient(access: .readOnly))
        guard case .deniedByConsent(let denial) = outcome else {
            return XCTFail("A full-access row ran under read-only consent.")
        }
        XCTAssertEqual(denial.ground, .aboveGrantedTier)
        XCTAssertEqual(denial.machineAnswer, "read-only")
        XCTAssertEqual(denial.requiredTier, .fullAccess)
    }

    /// Full Access runs everything the product can do at all.
    func testAFullAccessMachineIsNotRefused() async {
        let client = ConsentClient(access: .fullAccess)
        let outcome = await HostProjectionDispatch(face: .mcp, audit: AuditSpy())
            .invoke(ListProcessesProjection.capability.rawValue,
                    arguments: .init(raw: nil),
                    guest: nil, through: client)
        if case .deniedByConsent(let denial) = outcome {
            XCTFail("Full Access was refused: \(denial.reason)")
        }
    }

    /// **Silence fails OPEN, and that is a recorded decision.**
    ///
    /// A guest older than the field looks exactly like an installer that
    /// omitted the feature, and every machine in the field today is the
    /// former. Plan 006 makes the call and this asserts it, so the day it
    /// flips it flips against a failing test rather than silently.
    func testAMachineThatSaidNothingIsNotRefused() async {
        let client = ConsentClient(access: nil)
        let outcome = await HostProjectionDispatch(face: .mcp, audit: AuditSpy())
            .invoke(RequestQuitProjection.capability.rawValue,
                    arguments: .init(raw: ["process": "psn:1"]),
                    guest: nil, through: client)
        if case .deniedByConsent(let denial) = outcome {
            XCTFail("Silence was read as a refusal: \(denial.reason)")
        }
    }

    /// An unrecognised token refuses, and the refusal quotes it — the raw
    /// string is the only useful thing anyone has about a tier this build
    /// cannot name.
    func testAnUnrecognizedTokenRefusesAndQuotesItself() async {
        let outcome = await HostProjectionDispatch(face: .mcp, audit: AuditSpy())
            .invoke(ListProcessesProjection.capability.rawValue,
                    arguments: .init(raw: nil),
                    guest: nil,
                    through: ConsentClient(access: .unrecognized("mordor")))
        guard case .deniedByConsent(let denial) = outcome else {
            return XCTFail("An unrecognised tier was read as consent.")
        }
        XCTAssertEqual(denial.ground, .unrecognizedTier)
        XCTAssertTrue(denial.reason.contains("mordor"), denial.reason)
        XCTAssertTrue(denial.message.contains("mordor"), denial.message)
    }

    /// **No host, or no machine connected, is not a consent question.**
    ///
    /// Nothing answered, so nothing declined; the projection's own
    /// `unavailable` is the honest answer. Denying here would tell a caller
    /// their machine refused when no machine was ever reached.
    func testAnUnreachableHostIsNotARefusal() async {
        let outcome = await HostProjectionDispatch(face: .mcp, audit: AuditSpy())
            .invoke(ListProcessesProjection.capability.rawValue,
                    arguments: .init(raw: nil),
                    guest: nil, through: NoHostClient())
        if case .deniedByConsent = outcome {
            XCTFail("An unreachable host was reported as a machine refusing.")
        }
    }

    // MARK: - What the person at the machine reads

    /// A refused invocation still emits — and emits its OWN outcome.
    ///
    /// The transfer-cancel row made this argument and it holds harder here:
    /// a denied attempt is the more interesting event to the person at the
    /// machine, and it is the only outcome class the host would otherwise
    /// never see, because nothing is sent when consent is missing. `denied`
    /// rather than `refused` because they are two different events: one is
    /// an agent asking wrongly, the other is an agent asking for something
    /// this machine had already said no to.
    func testADeniedInvocationEmitsItsOwnAuditOutcome() async {
        let spy = AuditSpy()
        _ = await HostProjectionDispatch(face: .mcp, audit: spy)
            .invoke(GuestFilesMutateProjection.capability.rawValue,
                    arguments: .init(raw: nil),
                    guest: "pb1400c",
                    through: ConsentClient(access: .readOnly))

        let events = await spy.recorded()
        XCTAssertEqual(events.count, 1)
        let event = events.first
        XCTAssertEqual(event?.outcome, .denied)
        XCTAssertEqual(event?.level, .warn)
        XCTAssertEqual(event?.capability,
                       GuestFilesMutateProjection.capability.rawValue)
        XCTAssertEqual(event?.guest, "pb1400c")
        let line = event?.logMessage() ?? ""
        XCTAssertTrue(line.contains("denied:"), line)
        XCTAssertTrue(line.contains("granted read-only"), line)
    }

    /// The audit reason is the SHORT sentence and fits the line's bound
    /// uncut — the long one is written for the agent, not for the person
    /// standing at the Macintosh.
    func testTheAuditReasonFitsTheLineUncut() {
        for ground in [HostProjectionConsentDenial.Ground.machineDeclines,
                       .aboveGrantedTier, .unrecognizedTier] {
            let denial = HostProjectionConsentDenial(
                ground: ground,
                capability: RequestQuitProjection.capability,
                requiredTier: .fullAccess,
                machineAnswer: "read-only")
            XCTAssertLessThanOrEqual(
                denial.reason.unicodeScalars.count,
                HostProjectionAuditEvent.maximumReasonScalars,
                "\(ground) would be truncated mid-sentence in the log.")
        }
    }

    // MARK: - Consent is not incapacity

    /// **A caller tells the two apart without parsing prose.**
    ///
    /// The surface is already fluent in "this guest cannot": `unavailable`,
    /// `unproven`, `not-implemented`. Routed through any of those, a refusal
    /// by consent reaches an agent as a broken capability and sends somebody
    /// to debug a working machine. So it carries its own JSON-RPC code, its
    /// own enumerated `reason`, and a `kind` that says which sort of no it
    /// is — all fields, none of them a sentence.
    func testTheDenialIsTypedRatherThanWorded() {
        let denial = HostProjectionConsentDenial(
            ground: .aboveGrantedTier,
            capability: GuestFilesMutateProjection.capability,
            requiredTier: .fullAccess,
            machineAnswer: "read-only")
        XCTAssertEqual(denial.errorData["kind"] as? String, "consent")
        XCTAssertEqual(denial.errorData["reason"] as? String,
                       "above-granted-tier")
        XCTAssertEqual(denial.errorData["requiredTier"] as? String, "full")
        XCTAssertEqual(denial.errorData["machineAnswer"] as? String,
                       "read-only")
        /* Not -32602: the caller's arguments were fine, and an agent that
           reads invalid-params retries with different ones. */
        XCTAssertNotEqual(HostProjectionConsentDenial.jsonRPCCode, -32602)
        XCTAssertTrue(
            (-32099...(-32000)).contains(
                HostProjectionConsentDenial.jsonRPCCode),
            "The code must be in JSON-RPC's implementation-defined range.")
    }

    /// The words say consent, and say the machine is capable — the two
    /// things a caller gets wrong about this refusal.
    func testTheWordsDoNotDescribeABrokenCapability() {
        for ground in [HostProjectionConsentDenial.Ground.machineDeclines,
                       .aboveGrantedTier, .unrecognizedTier] {
            let message = HostProjectionConsentDenial(
                ground: ground,
                capability: CaptureScreenProjection.capability,
                requiredTier: .readOnly,
                machineAnswer: "disabled").message
            XCTAssertTrue(
                message.contains("consent"),
                "A consent refusal that never says so: \(message)")
            XCTAssertFalse(
                message.lowercased().contains("cannot"),
                "A consent refusal that reads as incapacity: \(message)")
            XCTAssertFalse(
                message.lowercased().contains("unavailable"),
                "A consent refusal wearing the unavailability vocabulary: "
                    + "\(message)")
        }
    }
}

/// What a face reported, in order.
private actor AuditSpy: HostProjectionAuditSink {
    private var events: [HostProjectionAuditEvent] = []

    func record(_ event: HostProjectionAuditEvent) async {
        events.append(event)
    }

    func recorded() -> [HostProjectionAuditEvent] { events }
}

/// Records whether any lane BUT session health was reached, which is how
/// "the row never ran" is asserted rather than assumed.
private actor CallRecorder {
    private(set) var asked = false

    func note() { asked = true }
}

/// A host that is reachable, with one machine connected that answered
/// `hello.agent` with `access`.
private struct ConsentClient: AgentIntegrationClient {
    let access: AgentIntegrationGuestAccess?
    let recorder = CallRecorder()

    init(access: AgentIntegrationGuestAccess?) {
        self.access = access
    }

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
        await recorder.note()
        return .unavailable(.guest)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        await recorder.note()
        return .unavailable(.guest)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        await recorder.note()
        return .unavailable(.guest)
    }

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        await recorder.note()
        return .unavailable(.guest)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        await recorder.note()
        return .unavailable(.guest)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        await recorder.note()
        return .hostUnavailable(.guest)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        await recorder.note()
        return .hostUnavailable(.guest)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        await recorder.note()
        return .hostUnavailable(.guest)
    }
}

/// No host to ask, so no machine has answered anything.
private struct NoHostClient: AgentIntegrationClient {
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
