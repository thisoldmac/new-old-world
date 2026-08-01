import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **`now_key_act`, held to its own properties rather than
/// `MirrorActProjectionTests`'.**
///
/// It is registered in `HostProjectionCatalog` beside the act plane and is
/// deliberately left out of `MirrorActProjections.rows` — see the header of
/// `KeyActProjection` and the note in `MirrorActProjections` on why
/// `now_observe_elements` sits outside that group too. So the registry-wide
/// gates (`HostProjectionRegistryTests`, `HostProjectionConsentTests`,
/// `HostProjectionArgumentStrictnessTests`, `MCPCoverageTests`) already cover
/// it; what is left for this file is the shape only this row has: no target
/// reference, a `posted` receipt rather than a `Dispatch` claim, and the
/// modifier mask that decode enforces before anything is sent.
final class KeyActProjectionTests: XCTestCase {

    // MARK: - Registration

    func testItIsRegisteredAndFoldsAKnownRequirement() {
        XCTAssertTrue(
            HostProjectionCatalog.projections.contains {
                $0.capability == KeyActProjection.capability
            })
        XCTAssertEqual(
            KeyActProjection.requires,
            [AgentIntegrationCapabilityNames.keyCommand])
        XCTAssertTrue(
            AgentIntegrationCapabilityNames.all.contains(
                AgentIntegrationCapabilityNames.keyCommand))
    }

    func testItIsNotOneOfTheFourDispatchActs() {
        XCTAssertFalse(
            MirrorActProjections.rows.contains {
                $0.capability == KeyActProjection.capability
            },
            "now_key_act shares no state with the four-op dispatch — no "
                + "reference, no Dispatch row — so it must not join the "
                + "group MirrorActProjectionTests holds to those "
                + "properties.")
    }

    func testExposesIsASubsetOfRequires() {
        XCTAssertEqual(
            Set(KeyActProjection.exposes),
            Set(KeyActProjection.requires))
    }

    func testEveryFaceIsStated() {
        for face in HostCapabilityFace.allCases {
            XCTAssertNotNil(KeyActProjection.faces[face])
        }
    }

    // MARK: - The published schema matches what invoke actually accepts

    func testAcceptedArgumentsMatchThePublishedInputSchema() {
        let properties = (KeyActProjection.mcpDescriptor["inputSchema"]
            as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            KeyActProjection.acceptedArguments, Set(properties.keys))
    }

    func testTheDescriptorIsCompleteAndUnnamed() {
        let descriptor = KeyActProjection.mcpDescriptor
        for key in ["title", "description", "inputSchema", "outputSchema",
                    "annotations"] {
            XCTAssertNotNil(descriptor[key], "no \(key)")
        }
        XCTAssertNil(descriptor["name"])
        XCTAssertFalse(KeyActProjection.availabilityNote.isEmpty)
    }

    func testAnnotationsAreCoherentFullAccess() {
        let annotations = KeyActProjection.mcpDescriptor["annotations"]
            as? [String: Any]
        XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations?["destructiveHint"] as? Bool, true)
    }

    // MARK: - The modifier mask

    func testEveryNamedModifierBitIsValidAlone() {
        for bit in [
            AgentIntegrationKeyModifierPolicy.cmd,
            AgentIntegrationKeyModifierPolicy.shift,
            AgentIntegrationKeyModifierPolicy.alphaLock,
            AgentIntegrationKeyModifierPolicy.option,
            AgentIntegrationKeyModifierPolicy.control,
        ] {
            XCTAssertTrue(AgentIntegrationKeyModifierPolicy.isValid(bit))
        }
    }

    func testEveryCombinationOfNamedBitsIsValid() {
        XCTAssertTrue(AgentIntegrationKeyModifierPolicy.isValid(
            AgentIntegrationKeyModifierPolicy.mask))
        XCTAssertTrue(AgentIntegrationKeyModifierPolicy.isValid(0))
    }

    func testABitOutsideTheMaskIsInvalid() {
        // 1 (the low bit) is not any named modifier.
        XCTAssertFalse(AgentIntegrationKeyModifierPolicy.isValid(1))
        // One bit above the highest named modifier (control = 4096).
        XCTAssertFalse(AgentIntegrationKeyModifierPolicy.isValid(8192))
    }

    // MARK: - invoke: argument decode

    func testInvokeRefusesAnUnknownArgument() async {
        let outcome = await KeyActProjection.invoke(
            .init(raw: ["name": "return", "modifier": 1]),
            through: NoHostKeyClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
        XCTAssertTrue(message.contains("modifier"))
    }

    func testInvokeRefusesAKeyNamingNeitherNameNorCodeNorChar() async {
        let outcome = await KeyActProjection.invoke(
            .init(raw: ["mods": 0]), through: NoHostKeyClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesACodeOutOfRange() async {
        let outcome = await KeyActProjection.invoke(
            .init(raw: ["code": 128]), through: NoHostKeyClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesACharOutOfRange() async {
        let outcome = await KeyActProjection.invoke(
            .init(raw: ["char": 256]), through: NoHostKeyClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesAModsValueOutsideTheMask() async {
        let outcome = await KeyActProjection.invoke(
            .init(raw: ["name": "return", "mods": 1]),
            through: NoHostKeyClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
        XCTAssertTrue(message.contains("mods"))
    }

    func testInvokeAcceptsAMaskedNonzeroModsAndForwardsIt() async {
        let client = RecordingKeyClient()
        let outcome = await KeyActProjection.invoke(
            .init(raw: [
                "name": "return",
                "mods": AgentIntegrationKeyModifierPolicy.cmd,
            ]),
            through: client)
        guard case .value = outcome else {
            return XCTFail("expected a value, got \(outcome)")
        }
        XCTAssertEqual(
            client.lastRequest?.mods, AgentIntegrationKeyModifierPolicy.cmd,
            "A masked nonzero mods is carried to the client rather than "
                + "pre-refused — the guest is the one that decides whether "
                + "its resident route is armed.")
    }

    func testInvokeReachesTheClientWithAWellFormedRequest() async {
        let client = RecordingKeyClient()
        _ = await KeyActProjection.invoke(
            .init(raw: ["char": 65]), through: client)
        XCTAssertEqual(client.lastRequest?.char, 65)
    }

    // MARK: - No-host default

    func testAgainstNoHostTheDefaultIsNoActLane() async {
        let outcome = await KeyActProjection.invoke(
            .init(raw: ["name": "return"]), through: NoHostKeyClient())
        guard case .value(let value) = outcome else {
            return XCTFail("expected a value, got \(outcome)")
        }
        let data = try! value.encoded(using: .init())
        let object = try! JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        XCTAssertEqual(object?["outcome"] as? String, "unavailable")
    }
}

/// No host to ask; `key` answers through the protocol's own default.
private struct NoHostKeyClient: AgentIntegrationClient {
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

/// Records the request it was handed and answers a fixed completion, so a
/// test can assert what `invoke` built without a socket or a machine.
private final class RecordingKeyClient: AgentIntegrationClient, @unchecked Sendable {
    private(set) var lastRequest: AgentIntegrationKeyRequest?

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

    func key(_ request: AgentIntegrationKeyRequest) async
        -> AgentIntegrationKeyResult {
        lastRequest = request
        return .completed(.init(
            code: request.code ?? 0, char: request.char ?? 0,
            posted: true, postedAt: Date(timeIntervalSince1970: 0)))
    }
}
