import XCTest
@testable import Host
import NOWAgentIntegration

@MainActor
final class AgentIntegrationProcessTests: XCTestCase {
    private struct WaitTimeout: Error {
        let what: String
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connectedListener()
        async throws -> (GuestListener, FakeGuest) {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listener ready") {
            if case .listening = listener.state { return true }
            return false
        }

        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision,
            side: "guest",
            version: "0.1.0",
            name: "PowerBook 1400",
            os: "9.1",
            chunk: 8192)))
        try await waitUntil("connected guest") {
            if case .connected = listener.state { return true }
            return false
        }
        return (listener, guest)
    }

    private func installResponder(
        on guest: FakeGuest,
        entries: @escaping () -> [ProcessEntry]
    ) {
        guest.onMessage = { message in
            guard case .processList(let request) = message else { return }
            try? guest.send(.processListing(.init(
                id: request.id,
                processes: entries(),
                more: false,
                cursor: nil)))
        }
    }

    private func finder(front: Bool = true) -> ProcessEntry {
        .init(name: "Finder", kind: "finder", code: "FNDR",
              creator: "MACS", sizeKB: 4096, front: front,
              psnHigh: 0, psnLow: 2)
    }

    func testUnavailableGuestReturnsNoCachedProcesses() async {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = await adapter.processList()

        guard case .unavailable(let unavailable) = result else {
            return XCTFail("a disconnected guest must be unavailable")
        }
        XCTAssertEqual(unavailable.code, "now-guest-unavailable")
    }

    func testPopulatedAndEmptySnapshotsAreCompletePointInTimeReads()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var entries = [finder()]
        installResponder(on: guest) { entries }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let observedAt = Date(timeIntervalSince1970: 1_000)

        guard case .available(let populated) =
                await adapter.processList(observedAt: observedAt) else {
            return XCTFail("expected a populated snapshot")
        }
        XCTAssertEqual(populated.observedAt, observedAt)
        XCTAssertEqual(populated.freshness, .pointInTime)
        XCTAssertEqual(populated.referenceAuthority, .observationOnly)
        XCTAssertEqual(populated.processes.map(\.name), ["Finder"])
        XCTAssertNotNil(populated.processes.first?.reference)
        XCTAssertEqual(populated.processes.first?.kind, .finder)

        entries = []
        guard case .available(let empty) =
                await adapter.processList(observedAt: observedAt) else {
            return XCTFail("expected an empty snapshot")
        }
        XCTAssertTrue(empty.processes.isEmpty)
    }

    func testProcessReferenceIsOpaqueAndStableAcrossRefreshes()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] in [finder()] }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .available(let first) = await adapter.processList(),
              case .available(let second) = await adapter.processList(),
              let firstReference = first.processes.first?.reference else {
            return XCTFail("expected two process snapshots")
        }

        XCTAssertEqual(second.processes.first?.reference, firstReference)
        XCTAssertFalse(firstReference.contains("Finder"))
        XCTAssertFalse(firstReference.contains("0:2"))
        XCTAssertEqual(first.sessionID, second.sessionID)
    }

    func testDisconnectClearsThePriorSnapshotAndReferenceScope()
        async throws {
        let (listener, guest) = try await connectedListener()
        installResponder(on: guest) { [self] in [finder()] }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .available = await adapter.processList() else {
            return XCTFail("expected initial snapshot")
        }

        guest.connection.cancel()
        try await waitUntil("guest disconnect") {
            if case .listening = listener.state { return true }
            return false
        }
        defer { listener.stop() }

        guard case .unavailable(let unavailable) =
                await adapter.processList() else {
            return XCTFail("stale rows must not survive disconnect")
        }
        XCTAssertEqual(unavailable.code, "now-guest-unavailable")
    }

    func testConcurrentProcessReadsAllReturnStableReferences()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        installResponder(on: guest) { [self] in [finder()] }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let tasks = (0..<8).map { _ in
            Task { @MainActor in await adapter.processList() }
        }
        var references: [String] = []
        for task in tasks {
            guard case .available(let snapshot) = await task.value,
                  let reference = snapshot.processes.first?.reference else {
                return XCTFail("every read must complete")
            }
            references.append(reference)
        }

        XCTAssertEqual(references.count, tasks.count)
        XCTAssertEqual(Set(references).count, 1)
    }

    func testLegacyIdentityAndLongFieldsFailClosedAndStayBounded()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let longName = String(repeating: "🙂", count: 100)
        installResponder(on: guest) {
            [.init(name: longName, kind: "unexpected",
                   code: "TOO-LONG", creator: "ALSO-LONG",
                   sizeKB: -1, front: nil,
                   psnHigh: nil, psnLow: nil)]
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .available(let snapshot) =
                await adapter.processList(),
              let process = snapshot.processes.first else {
            return XCTFail("expected bounded legacy observation")
        }

        XCTAssertEqual(process.name.unicodeScalars.count, 32)
        XCTAssertEqual(process.kind, .unknown)
        XCTAssertEqual(process.code, "TOO-")
        XCTAssertEqual(process.creator, "ALSO")
        XCTAssertNil(process.sizeKB)
        XCTAssertNil(process.reference,
                     "no PSN means no claim of stable identity")
    }
}
