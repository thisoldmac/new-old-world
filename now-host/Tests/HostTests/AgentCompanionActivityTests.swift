import Darwin
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// What the host knows about the companions that reach its local endpoint.
///
/// The fixtures drive a REAL server over a real socket, so the peer these
/// assertions are about is this test process — which is what makes the
/// kernel-attested identity testable at all: `getpid()` is the answer the
/// server must arrive at without anything having told it.
@MainActor
final class AgentCompanionActivityTests: XCTestCase {
    private func temporaryEndpoint() throws
        -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nac-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The resting state on most Macs, and the one the module's open
    /// question is about: nothing has EVER attached is a different answer
    /// from nothing is attached now, and the type has to be able to say so.
    func testHostNoCompanionEverReachedSaysNeverAttached() throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try server.start()
        defer { server.stop() }

        let activity = server.companionActivity
        XCTAssertEqual(activity.presence(), .neverAttached)
        XCTAssertFalse(activity.hasEverAttached)
        XCTAssertNil(activity.firstSeen)
        XCTAssertNil(activity.lastSeen)
        XCTAssertEqual(activity.totalRequests, 0)
        XCTAssertTrue(activity.companions.isEmpty)
    }

    /// One request leaves a trace of the process that made it, named by the
    /// kernel rather than by anything the peer sent.
    func testServedRequestRecordsTheCallingProcess() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try server.start()
        defer { server.stop() }

        _ = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sessionHealth()
        await waitUntil { server.companionActivity.inFlight == 0 }

        let activity = server.companionActivity
        XCTAssertTrue(activity.hasEverAttached)
        XCTAssertEqual(activity.totalRequests, 1)
        XCTAssertEqual(activity.inFlight, 0)
        XCTAssertEqual(activity.companions.count, 1)
        let companion = try XCTUnwrap(activity.companions.first)
        XCTAssertEqual(companion.processID, getpid(),
                       "the peer is named by LOCAL_PEERPID, not by itself")
        XCTAssertEqual(companion.requests, 1)
        // The connection is already gone; the companion is not.
        guard case .active = activity.presence() else {
            return XCTFail("a request a moment ago must read as active, "
                           + "not as a closed socket: \(activity.presence())")
        }
    }

    /// The count is of COMPANIONS, not of connections. One request per
    /// connection is the contract, so a companion that asks twice would read
    /// as two agents if the ledger counted sockets.
    func testTwoRequestsFromOneProcessAreOneCompanion() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try server.start()
        defer { server.stop() }

        let client = try AgentIntegrationLocalClient(endpoint: endpoint)
        _ = try await client.sessionHealth()
        _ = try await client.sessionHealth()
        await waitUntil {
            server.companionActivity.totalRequests == 2
                && server.companionActivity.inFlight == 0
        }

        let activity = server.companionActivity
        XCTAssertEqual(activity.companions.count, 1,
                       "one process asking twice is one companion")
        XCTAssertEqual(activity.companions.first?.requests, 2)
        XCTAssertEqual(activity.totalRequests, 2)
    }

    /// The uid gate stays the only authority, and stays first: a peer it
    /// turns away is counted as a refusal and enters no companion row, so
    /// presence tracking cannot become a way for an unauthorized process to
    /// appear as an attached agent.
    func testRefusedPeerIsCountedAndNamesNoCompanion() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            peerAuthorizer: { _, _ in false },
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try server.start()
        defer { server.stop() }

        _ = try? await AgentIntegrationLocalClient(
            endpoint: endpoint).sessionHealth()
        await waitUntil { server.companionActivity.refusedPeers == 1 }

        let activity = server.companionActivity
        XCTAssertEqual(activity.refusedPeers, 1)
        XCTAssertNotNil(activity.lastRefusal)
        XCTAssertTrue(activity.companions.isEmpty,
                      "a refused peer must not become a companion")
        XCTAssertEqual(activity.totalRequests, 0)
        XCTAssertFalse(activity.hasEverAttached)
        XCTAssertEqual(activity.presence(), .neverAttached,
                       "being reached by a peer we refused is not an agent "
                       + "having attached")
    }

    /// The observer is how a pane learns; a getter alone would miss every
    /// request, because each one is over in milliseconds.
    func testObserverSeesTheRequestWhileItIsInFlight() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = SnapshotCollector()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            companionObserver: { activity in seen.add(activity) },
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try server.start()
        defer { server.stop() }

        _ = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sessionHealth()
        await waitUntil { seen.snapshots.contains { $0.inFlight == 0
                                                    && $0.totalRequests == 1 } }

        let snapshots = seen.snapshots
        XCTAssertTrue(snapshots.contains { $0.inFlight == 1 },
                      "the pane must be told while a request is running")
        XCTAssertEqual(snapshots.last?.inFlight, 0,
                       "and told again when it finishes")
    }

    /// Bounded retention: the detail ages out, the totals do not.
    func testLedgerForgetsTheStalestCompanionButNotTheCount() {
        let ledger = AgentCompanionLedger()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let extra = 3
        let count = AgentCompanionActivity.rememberedCompanions + extra
        for index in 0..<count {
            let moment = start.addingTimeInterval(Double(index))
            _ = ledger.began(processID: pid_t(500 + index), at: moment)
            _ = ledger.ended(at: moment)
        }

        let activity = ledger.snapshot
        XCTAssertEqual(activity.companions.count,
                       AgentCompanionActivity.rememberedCompanions)
        XCTAssertEqual(activity.totalRequests, count,
                       "the total does not forget what the list drops")
        XCTAssertEqual(activity.companions.first?.processID,
                       pid_t(500 + count - 1),
                       "most recently active first")
        XCTAssertFalse(
            activity.companions.contains { $0.processID == 500 },
            "the stalest companion is the one dropped")
    }

    /// Recency is what a person is told, and it is derived from the clock —
    /// so it changes with nothing happening, which is exactly why the
    /// reading takes the moment as an argument.
    func testPresenceFallsToIdleOutsideTheActiveWindow() {
        let moment = Date(timeIntervalSince1970: 2_000_000)
        let activity = AgentCompanionActivity(
            companions: [.init(processID: 42, firstSeen: moment,
                               lastSeen: moment, requests: 1)],
            totalRequests: 1,
            firstSeen: moment,
            lastSeen: moment)

        XCTAssertEqual(
            activity.presence(asOf: moment.addingTimeInterval(1)),
            .active(since: moment))
        XCTAssertEqual(
            activity.presence(asOf: moment.addingTimeInterval(
                AgentCompanionActivity.activeWindow + 1)),
            .idle(since: moment))
    }

    /// A request in flight outranks the clock: whatever the last one's
    /// timestamp says, something is happening NOW.
    func testWorkingOutranksRecency() {
        let stale = Date(timeIntervalSince1970: 1)
        let activity = AgentCompanionActivity(
            totalRequests: 9, inFlight: 1,
            firstSeen: stale, lastSeen: stale)
        XCTAssertEqual(activity.presence(asOf: Date()), .working)
    }
}

/// Collects observer callbacks, which arrive on the server's own serial
/// queue rather than this actor's.
private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentCompanionActivity] = []

    func add(_ activity: AgentCompanionActivity) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(activity)
    }

    var snapshots: [AgentCompanionActivity] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
