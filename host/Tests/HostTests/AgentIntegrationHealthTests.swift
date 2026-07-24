import XCTest
@testable import Host

@MainActor
final class AgentIntegrationHealthTests: XCTestCase {
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

        return (listener, try await connectGuest(to: listener))
    }

    private func connectGuest(to listener: GuestListener) async throws
        -> FakeGuest {
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision,
            side: "guest",
            version: "0.1.0",
            name: "PowerBook 1400",
            os: "9.1",
            chunk: 8192)))
        try await waitUntil("session health") {
            listener.health != nil
        }
        return guest
    }

    func testIdleHostReturnsAnAvailableNotListeningSnapshot() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let observedAt = Date(timeIntervalSince1970: 1_000)

        guard case .available(let snapshot) =
                adapter.sessionHealth(observedAt: observedAt) else {
            return XCTFail("a running host must be available")
        }

        XCTAssertEqual(snapshot.state, .notListening)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertNil(snapshot.listeningPort)
        XCTAssertNil(snapshot.sessionID)
        XCTAssertNil(snapshot.guest)
        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(listener.state, .idle)
    }

    func testConnectedSnapshotReportsOnlyExistingHostOwnedHealth()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let health = try XCTUnwrap(listener.health)
        let observedAt = health.lastTraffic.addingTimeInterval(2)

        guard case .available(let snapshot) =
                adapter.sessionHealth(observedAt: observedAt) else {
            return XCTFail("a running host must be available")
        }

        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.listeningPort, listener.boundPort)
        XCTAssertNotNil(snapshot.sessionID)
        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(snapshot.guest?.name, health.guestName)
        XCTAssertEqual(snapshot.guest?.version, health.guestVersion)
        XCTAssertEqual(snapshot.guest?.operatingSystem, health.guestOS)
        XCTAssertEqual(snapshot.guest?.connectedAt, health.connectedAt)
        XCTAssertEqual(snapshot.guest?.lastTraffic, health.lastTraffic)
        XCTAssertEqual(try XCTUnwrap(snapshot.guest?.quietFor), 2,
                       accuracy: 0.001)
        XCTAssertEqual(snapshot.guest?.pingsAnswered, health.pingsAnswered)
        XCTAssertEqual(snapshot.guest?.framesReceived, health.framesReceived)
    }

    func testDuplicateConcurrentReadsShareOneSessionIdentity() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let observedAt = try XCTUnwrap(listener.health).lastTraffic
        let tasks = (0..<8).map { _ in
            Task { @MainActor in
                adapter.sessionHealth(observedAt: observedAt)
            }
        }

        var results: [AgentIntegrationSessionHealthResult] = []
        for task in tasks {
            results.append(await task.value)
        }
        let sessionIDs = results.compactMap { result -> UUID? in
            guard case .available(let snapshot) = result else { return nil }
            return snapshot.sessionID
        }

        XCTAssertEqual(sessionIDs.count, tasks.count)
        XCTAssertEqual(Set(sessionIDs).count, 1)
        XCTAssertEqual(listener.state,
                       .connected(guestName: "PowerBook 1400"))
    }

    func testReconnectMintsANewSessionIdentityEvenWithoutAnInterimRead()
        async throws {
        let (listener, firstGuest) = try await connectedListener()
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        guard case .available(let first) = adapter.sessionHealth() else {
            return XCTFail("a running host must be available")
        }
        let firstID = try XCTUnwrap(first.sessionID)

        firstGuest.connection.cancel()
        try await waitUntil("listener ready after disconnect") {
            if case .listening = listener.state { return true }
            return false
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let secondGuest = try await connectGuest(to: listener)
        defer {
            secondGuest.connection.cancel()
            listener.stop()
        }

        guard case .available(let second) = adapter.sessionHealth() else {
            return XCTFail("a running host must be available")
        }
        XCTAssertNotEqual(second.sessionID, firstID)
    }

    func testTypedHostUnavailableResultCarriesNoHealth() {
        let result = AgentIntegrationSessionHealthResult.hostUnavailable

        guard case .unavailable(let unavailable) = result else {
            return XCTFail("expected typed unavailable")
        }
        XCTAssertEqual(unavailable.code, "now-host-unavailable")
        XCTAssertEqual(unavailable.message, "New Old World host is unavailable")
    }

    func testHostFacadeDoesNotChangePairedModuleInventoryOrListenerState() {
        let suite = "AgentIntegrationHealth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "listenAtLaunch")
        let before = ModuleRegistry.standard.modules

        let state = HostAppState(registry: .standard, defaults: defaults)
        _ = state.agentIntegration

        XCTAssertEqual(ModuleRegistry.standard.modules, before)
        XCTAssertEqual(state.listener.state, .idle)
    }
}
