import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **`now_wait_for`**, held to its own properties.
///
/// It shares `ListProcessesProjection`'s requirement (`process.list`) and
/// repeats its `client.listProcesses()` call rather than sending anything
/// new — this file's job is the shape only this row has: the three
/// conditions, the timeout arithmetic, and that a fake clock exercises the
/// real poll loop (`WaitForProjection.poll`) without a test spending real
/// wall-clock seconds asleep.
final class WaitForProjectionTests: XCTestCase {

    // MARK: - Registration

    func testItIsRegisteredWithListProcessesRequirement() {
        XCTAssertTrue(
            HostProjectionCatalog.projections.contains {
                $0.capability == WaitForProjection.capability
            })
        XCTAssertEqual(
            WaitForProjection.requires,
            [AgentIntegrationCapabilityNames.processList])
        XCTAssertEqual(
            Set(WaitForProjection.exposes),
            Set(WaitForProjection.requires))
    }

    func testEveryFaceIsStated() {
        for face in HostCapabilityFace.allCases {
            XCTAssertNotNil(WaitForProjection.faces[face])
        }
    }

    func testAcceptedArgumentsMatchThePublishedInputSchema() {
        let properties = (WaitForProjection.mcpDescriptor["inputSchema"]
            as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            WaitForProjection.acceptedArguments, Set(properties.keys))
    }

    func testTheDescriptorIsCompleteAndUnnamed() {
        let descriptor = WaitForProjection.mcpDescriptor
        for key in ["title", "description", "inputSchema", "outputSchema",
                    "annotations"] {
            XCTAssertNotNil(descriptor[key], "no \(key)")
        }
        XCTAssertNil(descriptor["name"])
        XCTAssertFalse(WaitForProjection.availabilityNote.isEmpty)
    }

    func testAnnotationsAreReadOnly() {
        let annotations = WaitForProjection.mcpDescriptor["annotations"]
            as? [String: Any]
        XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations?["destructiveHint"] as? Bool, false)
    }

    func testTheSchemaCapsTimeoutAtTheHardMaximum() {
        let properties = (WaitForProjection.mcpDescriptor["inputSchema"]
            as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let timeout = properties["timeoutMs"] as? [String: Any]
        XCTAssertEqual(timeout?["maximum"] as? Int,
                       AgentIntegrationWaitPolicy.maximumTimeoutMs)
        XCTAssertEqual(AgentIntegrationWaitPolicy.maximumTimeoutMs, 10_000,
                       "the hard cap this row states in its own header")
    }

    // MARK: - invoke: argument decode

    func testInvokeRefusesAnUnknownArgument() async {
        let outcome = await WaitForProjection.invoke(
            .init(raw: ["name": "Finder", "until": "front", "poll": 1]),
            through: NoHostWaitClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
        XCTAssertTrue(message.contains("poll"))
    }

    func testInvokeRefusesAnEmptyName() async {
        let outcome = await WaitForProjection.invoke(
            .init(raw: ["name": "", "until": "front"]),
            through: NoHostWaitClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesAMissingName() async {
        let outcome = await WaitForProjection.invoke(
            .init(raw: ["until": "front"]), through: NoHostWaitClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesAnUnknownUntil() async {
        let outcome = await WaitForProjection.invoke(
            .init(raw: ["name": "Finder", "until": "visible"]),
            through: NoHostWaitClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesATimeoutAboveTheHardCap() async {
        let outcome = await WaitForProjection.invoke(
            .init(raw: [
                "name": "Finder", "until": "running", "timeoutMs": 10_001,
            ]),
            through: NoHostWaitClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    func testInvokeRefusesATimeoutBelowTheMinimum() async {
        let outcome = await WaitForProjection.invoke(
            .init(raw: [
                "name": "Finder", "until": "running", "timeoutMs": 0,
            ]),
            through: NoHostWaitClient())
        guard case .invalidArguments = outcome else {
            return XCTFail("expected invalidArguments, got \(outcome)")
        }
    }

    // MARK: - The poll loop, over a fake clock

    func testSatisfiedImmediatelyWhenTheFirstReadAlreadyHolds() async {
        let clock = FakeWaitClock()
        let client = SequencedProcessListClient(
            snapshots: [Self.snapshot(frontmost: "Finder")])
        let outcome = await WaitForProjection.poll(
            name: "Finder", until: .front, timeoutMs: 5_000,
            through: client, clock: clock)
        let result = try! Self.decode(outcome)
        guard case .satisfied(let receipt) = result else {
            return XCTFail("expected satisfied, got \(result)")
        }
        XCTAssertEqual(receipt.name, "Finder")
        XCTAssertEqual(receipt.until, .front)
        XCTAssertEqual(client.callCount, 1,
                       "already-true condition must not poll a second time")
    }

    func testSatisfiedAfterSeveralReadsAdvancesTheFakeClockEachPoll() async {
        let clock = FakeWaitClock()
        let client = SequencedProcessListClient(snapshots: [
            Self.snapshot(frontmost: "Finder"),
            Self.snapshot(frontmost: "Finder"),
            Self.snapshot(frontmost: "TestApp"),
        ])
        let outcome = await WaitForProjection.poll(
            name: "TestApp", until: .front, timeoutMs: 5_000,
            through: client, clock: clock)
        let result = try! Self.decode(outcome)
        guard case .satisfied = result else {
            return XCTFail("expected satisfied, got \(result)")
        }
        XCTAssertEqual(client.callCount, 3)
        XCTAssertEqual(clock.sleepCount, 2,
                       "two false reads sleep between them; the third, "
                           + "satisfying read does not sleep again")
    }

    func testRunningHoldsWhenListedRegardlessOfFront() async {
        let clock = FakeWaitClock()
        let client = SequencedProcessListClient(
            snapshots: [Self.snapshot(frontmost: "Finder",
                                      others: ["TestApp"])])
        let outcome = await WaitForProjection.poll(
            name: "TestApp", until: .running, timeoutMs: 5_000,
            through: client, clock: clock)
        let result = try! Self.decode(outcome)
        guard case .satisfied = result else {
            return XCTFail("expected satisfied, got \(result)")
        }
    }

    func testGoneHoldsWhenTheNameNeverAppears() async {
        let clock = FakeWaitClock()
        let client = SequencedProcessListClient(
            snapshots: [Self.snapshot(frontmost: "Finder")])
        let outcome = await WaitForProjection.poll(
            name: "QuitMe", until: .gone, timeoutMs: 5_000,
            through: client, clock: clock)
        let result = try! Self.decode(outcome)
        guard case .satisfied = result else {
            return XCTFail("expected satisfied, got \(result)")
        }
    }

    func testTimesOutHonestlyWhenTheConditionNeverHolds() async {
        let clock = FakeWaitClock(millisecondsPerSleep: 200)
        let client = SequencedProcessListClient(
            snapshots: Array(
                repeating: Self.snapshot(frontmost: "Finder"), count: 100))
        let outcome = await WaitForProjection.poll(
            name: "NeverThere", until: .running, timeoutMs: 500,
            through: client, clock: clock)
        let result = try! Self.decode(outcome)
        guard case .timedOut(let report) = result else {
            return XCTFail("expected timedOut, got \(result)")
        }
        XCTAssertEqual(report.name, "NeverThere")
        XCTAssertEqual(report.until, .running)
        XCTAssertEqual(report.timeoutMs, 500)
        XCTAssertGreaterThanOrEqual(report.elapsedMs, 500)
        XCTAssertNotNil(report.lastObservedAt,
                        "at least one read completed before the bound ran "
                            + "out, so the last listing's own timestamp is "
                            + "known")
    }

    func testUnavailableIsForwardedRatherThanRetried() async {
        let clock = FakeWaitClock()
        let client = SequencedProcessListClient(
            unavailable: .init(code: "no-guest", message: "no guest"))
        let outcome = await WaitForProjection.poll(
            name: "Finder", until: .front, timeoutMs: 5_000,
            through: client, clock: clock)
        let result = try! Self.decode(outcome)
        guard case .unavailable = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertEqual(client.callCount, 1)
    }

    // MARK: - No-host default

    func testAgainstNoHostTheDefaultIsHostUnavailable() async {
        let outcome = await WaitForProjection.invoke(
            .init(raw: ["name": "Finder", "until": "running"]),
            through: NoHostWaitClient())
        guard case .value(let value) = outcome else {
            return XCTFail("expected a value, got \(outcome)")
        }
        let data = try! value.encoded(using: .init())
        let object = try! JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        XCTAssertEqual(object?["outcome"] as? String, "unavailable")
    }

    // MARK: - Fixtures

    private static func snapshot(
        frontmost: String, others: [String] = []
    ) -> AgentIntegrationProcessSnapshot {
        var processes = [
            AgentIntegrationObservedProcess(
                reference: nil, name: frontmost, kind: .application,
                code: nil, creator: nil, sizeKB: nil, front: true),
        ]
        for name in others {
            processes.append(.init(
                reference: nil, name: name, kind: .application, code: nil,
                creator: nil, sizeKB: nil, front: false))
        }
        return AgentIntegrationProcessSnapshot(
            sessionID: UUID(), observedAt: Date(), processes: processes)
    }

    private static func decode(
        _ outcome: HostProjectionOutcome
    ) throws -> AgentIntegrationWaitResult {
        guard case .value(let value) = outcome else {
            XCTFail("expected a value, got \(outcome)")
            return .hostUnavailable
        }
        let data = try value.encoded(using: .init())
        return try JSONDecoder().decode(
            AgentIntegrationWaitResult.self, from: data)
    }
}

/// Advances by a fixed step on every `sleep`, and never actually suspends —
/// so the loop's own logic runs at full speed while the elapsed-time
/// arithmetic it computes is exercised exactly as it would be for a real
/// poll.
private final class FakeWaitClock: AgentIntegrationWaitClock, @unchecked Sendable {
    private var current: Date
    private let step: Int
    private(set) var sleepCount = 0

    init(millisecondsPerSleep: Int = 200) {
        current = Date(timeIntervalSince1970: 0)
        step = millisecondsPerSleep
    }

    func now() -> Date { current }

    func sleep(milliseconds: Int) async {
        sleepCount += 1
        current = current.addingTimeInterval(Double(step) / 1000)
    }
}

/// Answers `listProcesses()` with one snapshot per call, holding the last
/// one once the sequence is exhausted — or a fixed `unavailable` when
/// constructed that way — so a test can drive the poll loop through a known
/// sequence of reads without a socket or a machine.
private final class SequencedProcessListClient: AgentIntegrationClient, @unchecked Sendable {
    private var snapshots: [AgentIntegrationProcessSnapshot]
    private let unavailableAnswer: AgentIntegrationUnavailable?
    private(set) var callCount = 0

    init(snapshots: [AgentIntegrationProcessSnapshot]) {
        self.snapshots = snapshots
        unavailableAnswer = nil
    }

    init(unavailable: AgentIntegrationUnavailable) {
        snapshots = []
        unavailableAnswer = unavailable
    }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
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

    func listProcesses() async -> AgentIntegrationProcessListResult {
        callCount += 1
        if let unavailableAnswer {
            return .unavailable(unavailableAnswer)
        }
        guard !snapshots.isEmpty else {
            return .unavailable(.host)
        }
        let next = snapshots.count > 1 ? snapshots.removeFirst()
            : snapshots[0]
        return .available(next)
    }
}

/// No host to ask; `process.list` answers through the protocol's own
/// default.
private struct NoHostWaitClient: AgentIntegrationClient {
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
