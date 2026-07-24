import Darwin
import XCTest
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class AgentIntegrationSocketTests: XCTestCase {
    private func temporaryEndpoint() throws
        -> (AgentIntegrationEndpoint, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nat-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        return (AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock")), root)
    }

    func testHostSocketServesTheExistingHealthProjection() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { operation in
                switch operation {
                case .sessionHealth:
                    return .sessionHealth(adapter.sessionHealth())
                case .listProcesses:
                    return .processList(await adapter.processList())
                }
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sessionHealth()

        guard case .available(let health) = result else {
            return XCTFail("running host must return health")
        }
        XCTAssertEqual(health.state, .notListening)
        XCTAssertEqual(listener.state, .idle)
    }

    func testSocketIsPrivateToTheCurrentUser() throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try server.start()
        defer { server.stop() }

        var directory = stat()
        var socket = stat()
        XCTAssertEqual(lstat(endpoint.directoryURL.path, &directory), 0)
        XCTAssertEqual(lstat(endpoint.socketURL.path, &socket), 0)
        XCTAssertEqual(directory.st_uid, geteuid())
        XCTAssertEqual(socket.st_uid, geteuid())
        XCTAssertEqual(directory.st_mode & 0o077, 0)
        XCTAssertEqual(socket.st_mode & 0o077, 0)
    }

    func testSecondHostDoesNotReplaceALiveEndpoint() throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .sessionHealth(.hostUnavailable) })
        let second = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try first.start()
        defer { first.stop() }

        XCTAssertThrowsError(try second.start())
    }

    func testMalformedLocalRequestGetsABoundedError() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .sessionHealth(.hostUnavailable) })
        try server.start()
        defer { server.stop() }

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(Data("{\"operation\":\"oops\"}\n".utf8))

        XCTAssertLessThan(response.count,
                          AgentIntegrationLocalProtocol.maximumMessageBytes)
        let error = try AgentIntegrationLocalCodec.decodeResponse(response)
        XCTAssertEqual(error.error?.code, "invalid-request")
        XCTAssertNil(error.result)
    }

    func testRejectedPeerCannotReachTheHandler() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = InvocationFlag()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            peerAuthorizer: { _, _ in false },
            handler: { _ in
                await invocation.mark()
                return .sessionHealth(.hostUnavailable)
            })
        try server.start()
        defer { server.stop() }

        do {
            _ = try await AgentIntegrationLocalClient(
                endpoint: endpoint).sessionHealth()
            XCTFail("rejected peer must not receive health")
        } catch {
            let handled = await invocation.wasHandled
            XCTAssertFalse(handled)
        }
    }

    func testPeerUIDValidationRejectsAnotherUser() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        XCTAssertTrue(AgentIntegrationLocalServer.sameUserPeer(
            descriptors[0], geteuid()))
        XCTAssertFalse(AgentIntegrationLocalServer.sameUserPeer(
            descriptors[0], geteuid() &+ 1))
    }

    func testConcurrentHealthCallsReceiveIndependentReplies() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { operation in
                switch operation {
                case .sessionHealth:
                    return .sessionHealth(adapter.sessionHealth())
                case .listProcesses:
                    return .processList(await adapter.processList())
                }
            })
        try server.start()
        defer { server.stop() }

        let results = try await withThrowingTaskGroup(
            of: AgentIntegrationSessionHealthResult.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await AgentIntegrationLocalClient(
                        endpoint: endpoint).sessionHealth()
                }
            }
            var values: [AgentIntegrationSessionHealthResult] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy {
            guard case .available(let health) = $0 else { return false }
            return health.state == .notListening
        })
    }

    func testSocketPresenceDoesNotChangePairedModulesOrListenerState()
        throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AgentIntegrationSocket.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "listenAtLaunch")
        let state = HostAppState(registry: .standard, defaults: defaults)
        let modules = ModuleRegistry.standard.modules
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { operation in
                switch operation {
                case .sessionHealth:
                    return .sessionHealth(
                        state.agentIntegration.sessionHealth())
                case .listProcesses:
                    return .processList(
                        await state.agentIntegration.processList())
                }
            })

        try server.start()
        defer { server.stop() }

        XCTAssertEqual(ModuleRegistry.standard.modules, modules)
        XCTAssertEqual(state.listener.state, .idle)
    }

    func testSocketServesTypedProcessUnavailableWithoutCachedRows()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { operation in
                switch operation {
                case .sessionHealth:
                    return .sessionHealth(adapter.sessionHealth())
                case .listProcesses:
                    return .processList(await adapter.processList())
                }
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).listProcesses()

        guard case .unavailable(let unavailable) = result else {
            return XCTFail("disconnected guest must be unavailable")
        }
        XCTAssertEqual(unavailable.code, "now-guest-unavailable")
    }

    func testMaximumProjectedProcessSnapshotFitsTheLocalProtocol()
        throws {
        let processes = (0..<48).map { index in
            AgentIntegrationObservedProcess(
                reference: "now-process-\(UUID().uuidString.lowercased())",
                name: String(repeating: "🙂", count: 32),
                kind: .application,
                code: "APPL",
                creator: "TEST",
                sizeKB: index,
                front: false)
        }
        let response = AgentIntegrationLocalResponse(
            requestID: UUID(),
            processListResult: .available(.init(
                sessionID: UUID(),
                observedAt: Date(timeIntervalSince1970: 1_000),
                processes: processes)))

        let encoded = try AgentIntegrationLocalCodec.encode(response)

        XCTAssertLessThan(encoded.count,
                          AgentIntegrationLocalProtocol.maximumMessageBytes)
    }

    func testSocketRoundTripsAnAvailableProcessSnapshot() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = AgentIntegrationProcessSnapshot(
            sessionID: UUID(),
            observedAt: Date(timeIntervalSince1970: 1_000),
            processes: [.init(
                reference: "now-process-opaque",
                name: "Finder",
                kind: .finder,
                code: "FNDR",
                creator: "MACS",
                sizeKB: 4096,
                front: true)])
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { operation in
                switch operation {
                case .sessionHealth:
                    return .sessionHealth(.hostUnavailable)
                case .listProcesses:
                    return .processList(.available(snapshot))
                }
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).listProcesses()

        XCTAssertEqual(result, .available(snapshot))
    }
}

private actor InvocationFlag {
    private(set) var wasHandled = false

    func mark() {
        wasHandled = true
    }
}
