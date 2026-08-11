import XCTest
@testable import Host
import NOWAgentIntegration

/// The bring-to-front capability's own coverage, aimed at the one thing that
/// is genuinely its own: **the difference between a switch that is confirmed
/// and one that was merely accepted.**
///
/// `process.result` cannot carry that difference — `ok` and a reason, nothing
/// else — so the projection earns it from a second `process.list`. Every test
/// below is therefore about what the host did with answers a fake guest gave
/// it, and the fake guest is free to disagree with itself between the two
/// listings, which is exactly the case a single listing could not see.
@MainActor
final class AgentIntegrationFrontTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    private func process(
        name: String = "SimpleText",
        front: Bool? = false,
        high: Int = 0,
        low: Int = 42
    ) -> ProcessEntry {
        .init(name: name, kind: "application", code: "APPL",
              creator: "ttxt", sizeKB: 1024, front: front,
              psnHigh: high, psnLow: low)
    }

    /// Answers `process.list` from a closure that is told which listing this
    /// is, so a test can make the confirming listing differ from the
    /// revalidating one.
    private func installResponder(
        on guest: FakeGuest,
        entries: @escaping (Int) -> [ProcessEntry],
        listCount: Counter = Counter(),
        frontCount: Counter = Counter(),
        result: ProcessResult? = nil
    ) {
        guest.onMessage = { message in
            switch message {
            case .processList(let request):
                listCount.value += 1
                try? guest.send(.processListing(.init(
                    id: request.id,
                    processes: entries(listCount.value),
                    more: false,
                    cursor: nil)))
            case .processFront(let request):
                frontCount.value += 1
                let reply = result.map {
                    ProcessResult(id: request.id, ok: $0.ok,
                                  reason: $0.reason)
                } ?? .init(id: request.id, ok: true, reason: nil)
                try? guest.send(.processResult(reply))
            default:
                break
            }
        }
    }

    private func currentReference(
        from adapter: AgentIntegrationHostAdapter
    ) async throws -> String {
        guard case .available(let snapshot) = await adapter.processList(),
              let reference = snapshot.processes.first?.reference else {
            throw UnexpectedTestResult(
                description: "expected a current process reference")
        }
        return reference
    }

    // MARK: - Confirmed versus accepted

    /// A listing that shows the target frontmost is what `fronted` means.
    ///
    /// Three listings, not two: one for the reference the caller holds, one
    /// to revalidate it, one to confirm the switch. The third is the whole
    /// capability — without it the honest answer would be `unconfirmed`
    /// forever.
    func testAFreshListingShowingItFrontmostIsWhatMakesItFronted()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let lists = Counter()
        let fronts = Counter()
        installResponder(
            on: guest,
            entries: { [self] nth in [process(front: nth >= 3)] },
            listCount: lists, frontCount: fronts)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        let result = await adapter.bringToFront(reference: reference)

        guard case .completed(let receipt) = result else {
            return XCTFail("a current exact identity should front: \(result)")
        }
        XCTAssertEqual(receipt.outcome, .fronted)
        XCTAssertEqual(receipt.reference, reference)
        XCTAssertEqual(receipt.name, "SimpleText")
        XCTAssertEqual(lists.value, 3)
        XCTAssertEqual(fronts.value, 1)
        XCTAssertGreaterThanOrEqual(receipt.observedAt, receipt.revalidatedAt)
        let text = String(
            decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(text.contains("psn"))
    }

    /// The guest accepted it and the confirming listing does not agree yet.
    ///
    /// This is the ordinary answer on a cooperative machine, not an error:
    /// the switch happens when the guest next yields. Reporting it as
    /// `fronted` would be the host claiming something only the guest can
    /// know.
    func testAnAcceptedSwitchNoListingConfirmsStaysUnconfirmed()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let fronts = Counter()
        installResponder(on: guest,
                         entries: { [self] _ in [process(front: false)] },
                         frontCount: fronts)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        let result = await adapter.bringToFront(reference: reference)

        guard case .completed(let receipt) = result else {
            return XCTFail("an accepted switch is still a success")
        }
        XCTAssertEqual(receipt.outcome, .unconfirmed)
        XCTAssertEqual(fronts.value, 1)
    }

    /// A listing that carries no `front` flag confirms NOTHING, and absent
    /// must not read as false-but-known. Both answer `unconfirmed`; what
    /// this test pins is that a guest omitting the field cannot be reported
    /// as having denied the switch.
    func testAListingWithNoFrontFlagConfirmsNothing() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest,
                         entries: { [self] _ in [process(front: nil)] })
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        let result = await adapter.bringToFront(reference: reference)

        guard case .completed(let receipt) = result else {
            return XCTFail("a missing flag is not a refusal")
        }
        XCTAssertEqual(receipt.outcome, .unconfirmed)
    }

    /// The process was fronted and had gone by the confirming listing. The
    /// ask still happened, so this is `unconfirmed` and not a refusal —
    /// failing to confirm is never evidence that nothing was asked.
    func testAProcessGoneByTheConfirmingListingIsUnconfirmedNotRefused()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let fronts = Counter()
        installResponder(
            on: guest,
            entries: { [self] nth in nth >= 3 ? [] : [process()] },
            frontCount: fronts)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        let result = await adapter.bringToFront(reference: reference)

        guard case .completed(let receipt) = result else {
            return XCTFail("the switch was asked for; that much is true")
        }
        XCTAssertEqual(receipt.outcome, .unconfirmed)
        XCTAssertEqual(fronts.value, 1)
    }

    // MARK: - Refusals, and the one quit treats differently

    /// **Not running is a refusal here, where quit calls it done.** Quit's
    /// asked-for state already holds when nothing is running; this one's
    /// cannot, and a caller whose next step assumes a window is up must not
    /// read "it is not there" as success.
    func testAVanishedProcessIsRefusedAndNothingIsAsked() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries = [process()]
        let fronts = Counter()
        installResponder(on: guest, entries: { _ in entries },
                         frontCount: fronts)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)
        entries = []

        let result = await adapter.bringToFront(reference: reference)

        guard case .refused(let failure) = result else {
            return XCTFail("nothing to front is not a completed front")
        }
        XCTAssertEqual(failure.code, "now-process-not-found")
        XCTAssertEqual(fronts.value, 0)
    }

    /// A guest refusal stays a refusal, and its reason is the host's own
    /// sentence: the guest's carries a process name and could carry a path.
    func testAGuestRefusalIsBoundedAndClaimsNoSwitch() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(
            on: guest,
            entries: { [self] _ in [process()] },
            result: .init(id: 0, ok: false,
                          reason: "would not front HD:Secret:Thing"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)

        let result = await adapter.bringToFront(reference: reference)

        guard case .refused(let failure) = result else {
            return XCTFail("a guest refusal must remain a refusal")
        }
        XCTAssertEqual(failure.code, "now-front-refused")
        XCTAssertFalse(failure.message.contains("HD:"))
    }

    /// The reference vocabulary is quit's, so its failures are too: a reused
    /// PSN whose identity changed, and an observation past the age bound,
    /// are both refused before anything is asked.
    func testAChangedIdentityAndAnOldObservationAreBothStale() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries = [process()]
        let fronts = Counter()
        installResponder(on: guest, entries: { _ in entries },
                         frontCount: fronts)
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let reference = try await currentReference(from: adapter)
        entries = [process(name: "Another App")]

        guard case .refused(let changed) = await adapter.bringToFront(
            reference: reference) else {
            return XCTFail("a reused PSN with changed identity is stale")
        }
        XCTAssertEqual(changed.code, "now-process-reference-stale")
        XCTAssertEqual(fronts.value, 0)

        entries = [process()]
        guard case .available(let snapshot) = await adapter.processList(
            observedAt: Date(timeIntervalSince1970: 1_000)),
              let old = snapshot.processes.first?.reference else {
            return XCTFail("expected a process observation")
        }
        guard case .refused(let aged) = await adapter.bringToFront(
            reference: old,
            requestedAt: Date(timeIntervalSince1970: 1_031)) else {
            return XCTFail("an observation past the age bound is stale")
        }
        XCTAssertEqual(aged.code, "now-process-reference-stale")
        XCTAssertEqual(fronts.value, 0)
    }

    /// No guest, no answer about a guest. `unavailable` and not a refusal:
    /// the difference between "the machine said no" and "there was no
    /// machine" is the one the shared envelope exists to keep.
    func testADisconnectedGuestIsUnavailableRatherThanRefused() async {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let result = await AgentIntegrationHostAdapter(
            listener: disconnected
        ).bringToFront(
            reference: "now-process-00000000-0000-0000-0000-000000000000")

        guard case .unavailable(let missing) = result else {
            return XCTFail("a disconnected guest cannot refuse anything")
        }
        XCTAssertEqual(missing.code, "now-guest-unavailable")
    }

    // MARK: - The projection's own bound

    /// The reference is the only thing a caller may send, and it must be one
    /// the host issued. A name is refused here rather than resolved: the
    /// name form is the guest console's `front` verb, by contract.
    func testTheProjectionAcceptsOnlyACurrentOpaqueReference() async {
        let expected =
            "now_bring_to_front requires one current opaque process reference"
        let refused: [Any?] = [
            nil,
            [String: Any](),
            ["name": "SimpleText"],
            ["reference": "SimpleText"],
            ["reference": "now-process-not-a-uuid"],
            ["reference": Self.reference, "extra": 1],
        ]
        for raw in refused {
            let outcome = await BringToFrontProjection.invoke(
                .init(raw: raw), through: FrontStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "accepted \(String(describing: raw)) as a reference")
            }
            XCTAssertEqual(message, expected)
        }
    }

    /// A valid reference reaches the host verbatim, and the outcome the host
    /// answered is the outcome the caller reads — the projection renders it
    /// and does not re-decide it.
    func testAValidReferenceIsPassedThroughAndTheOutcomeSurvives() async
        throws {
        let host = FrontStubHost()
        let outcome = await BringToFrontProjection.invoke(
            .init(raw: ["reference": Self.reference]), through: host)

        guard case .value(let value) = outcome else {
            return XCTFail("a valid reference should reach the host")
        }
        let asked = await host.asked
        XCTAssertEqual(asked, [Self.reference])
        let json = String(
            decoding: try value.encoded(using: JSONEncoder()),
            as: UTF8.self)
        XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
        XCTAssertTrue(json.contains("\"unconfirmed\""))
        XCTAssertNil(
            value.attachment,
            "This row answers in JSON; only capture attaches anything.")
    }

    /// The row exposes the ACTION and not the observation. Which application
    /// is frontmost is `now_list_processes`' `front` flag and was never a
    /// gap; a second route to it would be one answer with two spellings.
    func testTheRowExposesTheDriveVerbAndNotTheListing() {
        XCTAssertEqual(
            BringToFrontProjection.exposes,
            [AgentIntegrationCapabilityNames.processFront])
        XCTAssertTrue(
            BringToFrontProjection.requires.contains(
                AgentIntegrationCapabilityNames.processList),
            "The listing is required twice over — to revalidate and to "
                + "confirm — and a row that did not require it would be "
                + "confirming from something it never asked for.")
    }

    private static let reference =
        "now-process-4c7a1f6e-2b3d-4a5f-8c9e-0d1a2b3c4d5e"
}

/// Answers one front result and records the references it was asked about.
/// Everything else says "no host", which is what the protocol's defaults are
/// for.
private actor FrontStubHost: AgentIntegrationClient {
    private(set) var asked: [String] = []

    func bringToFront(reference: String) async
        -> AgentIntegrationFrontResult {
        asked.append(reference)
        return .completed(.init(
            reference: reference,
            name: "SimpleText",
            outcome: .unconfirmed,
            revalidatedAt: Self.moment,
            observedAt: Self.moment))
    }

    /// Fixed so an encode round trip cannot drift on sub-second precision.
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Everything else answers "no host"

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

    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult {
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
