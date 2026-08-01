import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **`now_find_elements`**, held to its own properties.
///
/// It shares `ObserveElementsProjection`'s requirement (`elements`) and its
/// `AgentIntegrationClient.observeElements` call — this file's job is the
/// shape only this row has: the filter grammar (title / kind), the "at
/// least one of them" refusal, and that the matches it returns are exactly
/// the references the observation minted, narrowed and never re-derived.
final class FindElementsProjectionTests: XCTestCase {

    // MARK: - Registration

    func testItIsRegisteredWithObserveElementsRequirement() {
        XCTAssertTrue(
            HostProjectionCatalog.projections.contains {
                $0.capability == FindElementsProjection.capability
            })
        XCTAssertEqual(
            FindElementsProjection.requires,
            [AgentIntegrationCapabilityNames.elementsCommand])
        XCTAssertEqual(
            Set(FindElementsProjection.exposes),
            Set(FindElementsProjection.requires))
    }

    func testEveryFaceIsStated() {
        for face in HostCapabilityFace.allCases {
            XCTAssertNotNil(FindElementsProjection.faces[face])
        }
    }

    func testAcceptedArgumentsMatchThePublishedInputSchema() {
        let properties =
            (FindElementsProjection.mcpDescriptor["inputSchema"]
                as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            FindElementsProjection.acceptedArguments, Set(properties.keys))
    }

    func testTheDescriptorIsCompleteAndUnnamed() {
        let descriptor = FindElementsProjection.mcpDescriptor
        for key in ["title", "description", "inputSchema", "outputSchema",
                    "annotations"] {
            XCTAssertNotNil(descriptor[key], "no \(key)")
        }
        XCTAssertNil(descriptor["name"])
        XCTAssertFalse(FindElementsProjection.availabilityNote.isEmpty)
    }

    func testAnnotationsAreReadOnly() {
        let annotations = FindElementsProjection.mcpDescriptor["annotations"]
            as? [String: Any]
        XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations?["destructiveHint"] as? Bool, false)
    }

    // MARK: - invoke: argument decode

    func testInvokeRefusesAnUnknownArgument() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["title": "OK", "needle": "x"]),
            through: NoHostFindClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
        XCTAssertTrue(message.contains("needle"))
    }

    func testInvokeRefusesWhenNeitherTitleNorKindIsGiven() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: [:]), through: NoHostFindClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesAnEmptyTitle() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["title": ""]), through: NoHostFindClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesAnUnknownKind() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "dialog"]), through: NoHostFindClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesHalfAProcessSerial() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "window", "serialHi": 1]),
            through: NoHostFindClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    // MARK: - invoke: the filter, over a fixed observation

    func testFilterByTitleIsCaseInsensitiveSubstring() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["title": "cancel"]),
            through: FixedObservationClient(.completed(Self.fixture)))
        let matches = try! Self.completedMatches(outcome)
        XCTAssertEqual(matches.map(\.ref), ["now-element-control-cancel"])
    }

    func testFilterByKindWindowReturnsOnlyWindows() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "window"]),
            through: FixedObservationClient(.completed(Self.fixture)))
        let matches = try! Self.completedMatches(outcome)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].kind, .window)
        XCTAssertEqual(matches[0].ref, "now-window-1")
        XCTAssertNil(matches[0].window,
                     "a window match is the element, not something found "
                        + "inside one, so it carries no containing window")
    }

    func testFilterByKindControlIncludesTheContainingWindow() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "control"]),
            through: FixedObservationClient(.completed(Self.fixture)))
        let matches = try! Self.completedMatches(outcome)
        XCTAssertEqual(matches.count, 2)
        for match in matches {
            XCTAssertEqual(match.window?.ref, "now-window-1")
        }
    }

    func testFilterByKindTextNeverMatchesATitleFilter() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["title": "anything", "kind": "text"]),
            through: FixedObservationClient(.completed(Self.fixture)))
        let matches = try! Self.completedMatches(outcome)
        XCTAssertTrue(
            matches.isEmpty,
            "a text element has no title, so a call combining title with "
                + "kind: text is well formed and simply never matches")
    }

    func testFilterByKindTextAloneMatchesTheTextElement() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "text"]),
            through: FixedObservationClient(.completed(Self.fixture)))
        let matches = try! Self.completedMatches(outcome)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].kind, .text)
        XCTAssertEqual(matches[0].ref, "now-element-text-1")
        XCTAssertEqual(matches[0].length, 12)
    }

    func testAnswerCopiesTheObservationsOwnFactsRatherThanRecomputingThem() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "window"]),
            through: FixedObservationClient(.completed(Self.fixture)))
        guard case .value(let value) = outcome else {
            return XCTFail("expected a value, got \(outcome)")
        }
        let data = try! value.encoded(using: .init())
        let result = try! JSONDecoder().decode(
            AgentIntegrationFindResult.self, from: data)
        guard case .completed(let answer) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(answer.scope, Self.fixture.scope)
        XCTAssertEqual(answer.truncated, Self.fixture.truncated)
        XCTAssertEqual(answer.live, Self.fixture.live)
    }

    func testARefusedObservationIsForwardedRatherThanReinterpreted() async {
        let refusal = AgentIntegrationProjectionFailure(
            code: "no-process", message: "no such process")
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "window"]),
            through: FixedObservationClient(.refused(refusal)))
        guard case .value(let value) = outcome else {
            return XCTFail("expected a value, got \(outcome)")
        }
        let data = try! value.encoded(using: .init())
        let object = try! JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        XCTAssertEqual(object?["outcome"] as? String, "refused")
    }

    // MARK: - No-host default

    func testAgainstNoHostTheDefaultIsNoObservationLane() async {
        let outcome = await FindElementsProjection.invoke(
            .init(raw: ["kind": "window"]), through: NoHostFindClient())
        guard case .value(let value) = outcome else {
            return XCTFail("expected a value, got \(outcome)")
        }
        let data = try! value.encoded(using: .init())
        let object = try! JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        XCTAssertEqual(object?["outcome"] as? String, "unavailable")
    }

    // MARK: - Fixture

    private static let fixture = AgentIntegrationElementObservation(
        scope: "frontmost", count: 4, truncated: false, live: 4,
        processes: [
            .init(
                name: "TestApp", signature: "TEST", serialHi: 0, serialLo: 1,
                front: true, bind: "ok", stampTicks: 12345,
                windows: [
                    .init(
                        ref: "now-window-1", title: "Preferences",
                        occurrence: 0, z: 0, visible: true, kind: 0,
                        bounds: .init(left: 0, top: 0, right: 100,
                                     bottom: 100),
                        text: .init(ref: "now-element-text-1", length: 12),
                        controls: [
                            .init(ref: "now-element-control-cancel",
                                 title: "Cancel", occurrence: 0,
                                 visible: true, enabled: true,
                                 bounds: .init(left: 0, top: 0, right: 10,
                                              bottom: 10),
                                 value: 0, min: 0, max: 1),
                            .init(ref: "now-element-control-ok",
                                 title: "OK", occurrence: 0, visible: true,
                                 enabled: true,
                                 bounds: .init(left: 20, top: 0, right: 30,
                                              bottom: 10),
                                 value: 0, min: 0, max: 1),
                        ]),
                ]),
        ])

    private static func completedMatches(
        _ outcome: HostProjectionOutcome
    ) throws -> [AgentIntegrationFindElementMatch] {
        guard case .value(let value) = outcome else {
            XCTFail("expected a value, got \(outcome)")
            return []
        }
        let data = try value.encoded(using: .init())
        let result = try JSONDecoder().decode(
            AgentIntegrationFindResult.self, from: data)
        guard case .completed(let answer) = result else {
            XCTFail("expected completed, got \(result)")
            return []
        }
        return answer.matches
    }
}

/// No host to ask; `elements` answers through the protocol's own default.
private struct NoHostFindClient: AgentIntegrationClient {
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

/// Answers `observeElements` with a fixed result handed to it at
/// construction, so a test can assert the filter over a known tree without a
/// socket or a machine.
private struct FixedObservationClient: AgentIntegrationClient {
    let result: AgentIntegrationElementObservationResult

    init(_ result: AgentIntegrationElementObservationResult) {
        self.result = result
    }

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

    func observeElements(process: AgentIntegrationProcessSerial?) async
        -> AgentIntegrationElementObservationResult {
        result
    }
}
