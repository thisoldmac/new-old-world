import Darwin
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// The private local socket, end to end.
///
/// Every fixture here stands up a real `AgentIntegrationLocalServer` to
/// answer ONE operation, and its handler must still be a total function
/// over the operation enum. The cases it does not care about answer
/// `Self.filler` through a `default:` rather than being spelled out: an
/// exhaustive tail meant every operation added to the protocol was an edit
/// to every fixture in this file, on the one file a whole phase's agents
/// share. Nothing is lost by it — a fixture that reached an operation it
/// had not handled would decode the wrong response and fail.
@MainActor
final class AgentIntegrationSocketTests: XCTestCase {
    /// The answer a fixture gives an operation it is not about. Shaped for
    /// `sessionHealth`, so it decodes as a response only where that is what
    /// was asked; anywhere else it is a deliberate mismatch that fails.
    private static let filler =
        AgentIntegrationLocalResult.sessionHealth(.hostUnavailable)

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
            identity: .init(version: "0.1-test", name: "Test Host"),
            updateProvider: UpdateProvider(snapshot: .empty))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(adapter.sessionHealth())
                case .sessionCapabilities:
                    return .sessionCapabilities(
                        await adapter.sessionCapabilities(
                            probeCostly: request.probeCostly ?? false))
                case .listProcesses:
                    return .processList(await adapter.processList())
                default:
                    return Self.filler   /* see the class note */
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

    func testDevelopmentAttemptReplaysAfterResponseAndHostRestart() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempt = "01234567-89ab-cdef-0123-456789abcdef"
        let request = AgentIntegrationDevelopmentRequest(
            operation: .buildCancel, attemptID: attempt)
        let receipt = AgentIntegrationGuestRowReportResult.completed(.init(
            verb: "development-build",
            groups: [.init(name: "development-build", rows: [
                .init(label: "State", value: "cancelled"),
            ])], observedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        var firstInvocations = 0
        let first = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { local in
                guard local.operation == .development else { return Self.filler }
                firstInvocations += 1
                return .development(receipt)
            })
        try first.start()
        let client = try AgentIntegrationLocalClient(endpoint: endpoint)
        let firstResult = try await client.development(request)
        let replayResult = try await client.development(request)
        XCTAssertEqual(firstResult, receipt)
        XCTAssertEqual(replayResult, receipt)
        XCTAssertEqual(firstInvocations, 1)
        first.stop()

        var restartedInvocations = 0
        let restarted = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                restartedInvocations += 1
                return .development(.unavailable(.host))
            })
        try restarted.start()
        defer { restarted.stop() }
        let restartResult = try await client.development(request)
        XCTAssertEqual(restartResult, receipt)
        XCTAssertEqual(restartedInvocations, 0,
                       "the durable terminal receipt must settle the retry")
    }

    func testProjectMutationAttemptReplaysAfterHostRestart() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempt = "11234567-89ab-cdef-0123-456789abcdef"
        let request = AgentIntegrationProjectRequest(
            operation: .workspaceDiscard,
            workspaceID: "workspace-0123456789abcdef",
            attemptID: attempt)
        let receipt = AgentIntegrationProjectResult(projects: [])
        var firstInvocations = 0
        let first = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { local in
                guard local.operation == .projects else { return Self.filler }
                firstInvocations += 1
                return .projects(receipt)
            })
        try first.start()
        let client = try AgentIntegrationLocalClient(endpoint: endpoint)
        let firstResult = try await client.projects(request)
        let replayResult = try await client.projects(request)
        XCTAssertEqual(firstResult, receipt)
        XCTAssertEqual(replayResult, receipt)
        XCTAssertEqual(firstInvocations, 1)
        first.stop()

        var restartedInvocations = 0
        let restarted = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                restartedInvocations += 1
                return .projects(.init(failure: .init(
                    code: "unexpected-dispatch", message: "unexpected")))
            })
        try restarted.start()
        defer { restarted.stop() }
        let restartResult = try await client.projects(request)
        XCTAssertEqual(restartResult, receipt)
        XCTAssertEqual(restartedInvocations, 0,
                       "the project mutation receipt must survive restart")
    }

    func testAttemptCollisionKeepsTheCurrentRequestIdentity() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempt = "21234567-89ab-cdef-0123-456789abcdef"
        let project = AgentIntegrationProjectRequest(
            operation: .workspaceDiscard,
            workspaceID: "workspace-0123456789abcdef",
            attemptID: attempt)
        let development = AgentIntegrationDevelopmentRequest(
            operation: .buildCancel, attemptID: attempt)
        var invocations = 0
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { local in
                invocations += 1
                guard local.operation == .projects else {
                    return Self.filler
                }
                return .projects(.init(projects: []))
            })
        try server.start()
        defer { server.stop() }
        let client = try AgentIntegrationLocalClient(endpoint: endpoint)

        _ = try await client.projects(project)
        do {
            _ = try await client.development(development)
            XCTFail("a reused attempt ID for different bytes was accepted")
        } catch let error as AgentIntegrationLocalTransportError {
            XCTAssertEqual(error, .attemptRefused(
                code: "attempt-collision",
                message: "This attempt ID is already bound to a different request."))
        }
        XCTAssertEqual(invocations, 1,
                       "a colliding request must never reach the handler")
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
        if ProcessInfo.processInfo.environment[
            "NOW_DEFER_CONCURRENT_SOCKET_TEST"] == "1" {
            throw XCTSkip(
                "scripts/test-host runs this MainActor stress case alone")
        }
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            updateProvider: UpdateProvider(snapshot: .empty))
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(adapter.sessionHealth())
                case .sessionCapabilities:
                    return .sessionCapabilities(
                        await adapter.sessionCapabilities(
                            probeCostly: request.probeCostly ?? false))
                case .listProcesses:
                    return .processList(await adapter.processList())
                default:
                    return Self.filler   /* see the class note */
                }
            })
        try server.start()
        defer { server.stop() }

        /* Swift 6.1 can keep a task-group body inherited from this test
           class on MainActor while it awaits the clients, starving the
           server handlers that must run on that same actor. Orchestrate
           the clients off-actor; awaiting the detached task releases the
           actor for the shipping handler and keeps the real two-second
           receive budget under test. */
        let results = try await Task.detached { [endpoint] in
            let client = try AgentIntegrationLocalClient(endpoint: endpoint)
            return try await withThrowingTaskGroup(
                of: AgentIntegrationSessionHealthResult.self
            ) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await client.sessionHealth()
                    }
                }
                var values: [AgentIntegrationSessionHealthResult] = []
                for try await value in group { values.append(value) }
                return values
            }
        }.value

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
            handler: { request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(
                        state.agentIntegration.sessionHealth())
                case .sessionCapabilities:
                    return .sessionCapabilities(
                        await state.agentIntegration.sessionCapabilities(
                            probeCostly: request.probeCostly ?? false))
                case .listProcesses:
                    return .processList(
                        await state.agentIntegration.processList())
                default:
                    return Self.filler   /* see the class note */
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
            handler: { request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(adapter.sessionHealth())
                case .sessionCapabilities:
                    return .sessionCapabilities(
                        await adapter.sessionCapabilities(
                            probeCostly: request.probeCostly ?? false))
                case .listProcesses:
                    return .processList(await adapter.processList())
                default:
                    return Self.filler   /* see the class note */
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

    func testMaximumGuestFilePageFitsTheLocalProtocol() throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let entries = (0..<16).map { index in
            AgentIntegrationGuestFileEntry(
                path: String(repeating: "p", count: 223),
                name: String(repeating: "n", count: 31),
                isFolder: false,
                fileType: "APPL",
                creator: "TEST",
                dataBytes: index,
                resourceBytes: index,
                modified: Int(UInt32.max))
        }
        let result = AgentIntegrationGuestFileListResult.completed(
            receipt: .init(
                commandID: UUID(),
                sessionID: UUID(),
                policyVersion: 1,
                operation: .list,
                startedAt: observedAt,
                completedAt: observedAt,
                outcome: .success,
                wireRequestCount: 1),
            value: .init(
                path: String(repeating: "p", count: 223),
                entries: entries,
                hasMore: true,
                nextCursor: Int.max,
                rootLabel: String(repeating: "r", count: 128),
                observedAt: observedAt),
            failure: nil)
        let response = AgentIntegrationLocalResponse(
            requestID: UUID(),
            guestFilesListResult: result)

        let encoded = try AgentIntegrationLocalCodec.encode(response)

        XCTAssertLessThan(
            encoded.count,
            AgentIntegrationLocalProtocol.maximumMessageBytes)
    }

    func testGuestFileResultMustMatchItsReceiptOutcome() {
        let now = Date(timeIntervalSince1970: 1_000)
        let receipt = AgentIntegrationGuestFileReceipt(
            commandID: UUID(),
            sessionID: UUID(),
            policyVersion: 1,
            operation: .list,
            startedAt: now,
            completedAt: now,
            outcome: .success,
            wireRequestCount: 1)
        let invalid = AgentIntegrationGuestFileListResult.completed(
            receipt: receipt,
            value: nil,
            failure: .init(code: "wrong", message: "wrong"))
        let response = AgentIntegrationLocalResponse(
            requestID: UUID(),
            guestFilesListResult: invalid)

        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.encode(response))
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
            handler: { request in
                switch request.operation {
                case .sessionHealth:
                    return .sessionHealth(.hostUnavailable)
                case .sessionCapabilities:
                    return .sessionCapabilities(.guestUnavailable)
                case .listProcesses:
                    return .processList(.available(snapshot))
                default:
                    return Self.filler   /* see the class note */
                }
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).listProcesses()

        XCTAssertEqual(result, .available(snapshot))
    }

    func testSocketRoundTripsRootScopedGuestFileListing() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let receipt = AgentIntegrationGuestFileReceipt(
            commandID: UUID(),
            sessionID: UUID(),
            policyVersion: 3,
            operation: .list,
            startedAt: observedAt,
            completedAt: observedAt,
            outcome: .success,
            wireRequestCount: 1)
        let expected = AgentIntegrationGuestFileListResult.completed(
            receipt: receipt,
            value: .init(
                path: "Logs",
                entries: [.init(
                    path: "Logs:today.txt",
                    name: "today.txt",
                    isFolder: false,
                    fileType: "TEXT",
                    creator: "ttxt",
                    dataBytes: 42,
                    resourceBytes: 3,
                    modified: 3_500_000_000)],
                hasMore: false,
                nextCursor: nil,
                rootLabel: "Macintosh HD:",
                observedAt: observedAt),
            failure: nil)
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                switch request.operation {
                case .guestFilesList:
                    XCTAssertEqual(request.guestFilePath, "Logs")
                    XCTAssertEqual(request.guestFileCursor, 2)
                    return .guestFilesList(expected)
                default:
                    return Self.filler   /* see the class note */
                }
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).listGuestFiles(path: "Logs", cursor: 2)

        XCTAssertEqual(result, expected)
    }

    func testLocalSchemaRejectsInvalidGuestFileSelectionsBeforeHandler()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = InvocationFlag()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                await invocation.mark()
                return .guestFilesList(.hostUnavailable(.guest))
            })
        try server.start()
        defer { server.stop() }
        let requestID = UUID().uuidString
        let invalid = Data(
            """
            {"version":5,"requestID":"\(requestID)","operation":"guest_files_list","guestFilePath":"","guestFileCursor":0}
            """.utf8)

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(invalid)
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(response)

        XCTAssertEqual(decoded.error?.code, "invalid-request")
        let handled = await invocation.wasHandled
        XCTAssertFalse(handled)
    }

    func testLocalSchemaRejectsMalformedUploadChunkBeforeHandler()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = InvocationFlag()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                await invocation.mark()
                return .guestFilesUploadStage(.hostUnavailable(.guest))
            })
        try server.start()
        defer { server.stop() }
        let requestID = UUID().uuidString
        let uploadID = UUID().uuidString
        let invalid = Data(
            """
            {"version":5,"requestID":"\(requestID)","operation":"guest_files_upload_append","guestFileUploadID":"\(uploadID)","guestFileUploadOffset":0,"guestFileUploadChunk":"not base64!"}
            """.utf8)

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(invalid)
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(response)

        XCTAssertEqual(decoded.error?.code, "invalid-request")
        let handled = await invocation.wasHandled
        XCTAssertFalse(handled)
    }

    func testLocalSchemaRejectsUploadMetadataOutsidePublicBounds()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = InvocationFlag()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                await invocation.mark()
                return .guestFilesUploadStage(.hostUnavailable(.guest))
            })
        try server.start()
        defer { server.stop() }
        let requestID = UUID().uuidString
        let invalid = Data(
            """
            {"version":5,"requestID":"\(requestID)","operation":"guest_files_upload_begin","guestFileUpload":{"destinationPath":"Drops:x","bytes":1,"sha256":"\(String(repeating: "١", count: 64))","container":"data","fileType":"TOO-LONG","modified":-1}}
            """.utf8)

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(invalid)
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(response)

        XCTAssertEqual(decoded.error?.code, "invalid-request")
        let handled = await invocation.wasHandled
        XCTAssertFalse(handled)
    }

    func testUploadRequestsRoundTripThroughThePrivateSocket()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = UploadOperationRecorder()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                await recorder.record(request.operation)
                switch request.operation {
                case .guestFilesUploadBegin, .guestFilesUploadAppend:
                    return .guestFilesUploadStage(.hostUnavailable(.guest))
                case .guestFilesUploadCommit:
                    return .guestFilesUploadCommit(.hostUnavailable(.guest))
                default:
                    return Self.filler   /* see the class note */
                }
            })
        try server.start()
        defer { server.stop() }
        let client = try AgentIntegrationLocalClient(endpoint: endpoint)
        let uploadID = UUID()
        let begin = try await client.beginGuestFileUpload(.init(
            destinationPath: "Drops:x",
            bytes: 3,
            sha256: String(repeating: "a", count: 64),
            container: "data",
            fileType: "TEXT",
            creator: "ttxt",
            modified: 1))
        let append = try await client.appendGuestFileUpload(
            uploadID: uploadID, offset: 0, bytes: Data("abc".utf8))
        let commit = try await client.commitGuestFileUpload(
            uploadID: uploadID)

        guard case .hostUnavailable = begin,
              case .hostUnavailable = append,
              case .hostUnavailable = commit else {
            return XCTFail("all three typed socket responses must decode")
        }
        let operations = await recorder.operations
        XCTAssertEqual(
            operations,
            [.guestFilesUploadBegin, .guestFilesUploadAppend,
             .guestFilesUploadCommit])
    }

    func testSocketRoundTripsOnlyAnOpaqueLaunchSelection() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let expected = AgentIntegrationLaunchSoftwareResult.launched(.init(
            sessionID: sessionID,
            catalogObservedAt: Date(timeIntervalSince1970: 1_000),
            acknowledgedAt: Date(timeIntervalSince1970: 1_001),
            software: .init(
                reference: "now-software-opaque",
                name: "SimpleText",
                version: "1.4",
                type: "APPL",
                creator: "ttxt",
                running: false),
            guestMessage: "launched SimpleText"))
        var captured: AgentIntegrationLaunchSelection?
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                if case .launchSoftware = request.operation {
                    captured = request.launchSelection
                    return .launchSoftware(expected)
                }
                return .sessionHealth(.hostUnavailable)
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).launchSoftware(.name("SimpleText"))

        XCTAssertEqual(result, expected)
        XCTAssertEqual(captured, .name("SimpleText"))
        let encoded = try AgentIntegrationLocalCodec.encode(
            .launchSoftware(.reference(
                "now-software-00000000-0000-0000-0000-000000000000")))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("\"path\""))
    }

    func testMalformedLocalLaunchSelectionNeverReachesHandler()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = InvocationFlag()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                await invocation.mark()
                return .launchSoftware(.unavailable(.guest))
            })
        try server.start()
        defer { server.stop() }
        let requestID = UUID()
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": requestID.uuidString,
            "operation": "launch_software",
            "launchSelection": [
                "name": "SimpleText",
                "path": "HD:Apps:SimpleText",
            ],
        ])

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(raw)
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(response)
        let wasHandled = await invocation.wasHandled

        XCTAssertEqual(decoded.error?.code, "invalid-request")
        XCTAssertFalse(wasHandled)
    }

    func testLaunchSocketWaitsPastTheReadOnlyTimeoutForCatalogWork()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = AgentIntegrationLaunchSoftwareResult.notFound(.init(
            code: "now-software-not-found",
            message: "No exact application name is current"))
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                guard request.operation == .launchSoftware else {
                    return .sessionHealth(.hostUnavailable)
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
                return .launchSoftware(expected)
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint,
            readOnlyReceiveTimeout: 0.05,
            launchReceiveTimeout: 0.5
        ).launchSoftware(.name("Missing"))

        XCTAssertEqual(result, expected)
    }

    func testSocketRoundTripsOnlyAnOpaqueQuitReference() async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let reference =
            "now-process-00000000-0000-0000-0000-000000000000"
        let expected = AgentIntegrationQuitResult.notFound(.init(
            code: "now-process-not-found",
            message: "The selected process is no longer running"))
        var captured: String?
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                guard case .requestQuit = request.operation else {
                    return .sessionHealth(.hostUnavailable)
                }
                captured = request.processReference
                return .requestQuit(expected)
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).requestQuit(reference: reference)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(captured, reference)
        let encoded = try AgentIntegrationLocalCodec.encode(
            .requestQuit(reference: reference))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("psn"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("path"))
    }

    func testMalformedLocalQuitReferenceNeverReachesHandler()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = InvocationFlag()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                await invocation.mark()
                return .requestQuit(.unavailable(.guest))
            })
        try server.start()
        defer { server.stop() }
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "request_quit",
            "processReference": "42",
        ])

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(raw)
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(response)
        let wasHandled = await invocation.wasHandled

        XCTAssertEqual(decoded.error?.code, "invalid-request")
        XCTAssertFalse(wasHandled)
    }

    func testPriorSchemaRequestIsRejectedAfterGuestFilesCapabilityChange()
        throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": 3,
            "requestID": UUID().uuidString,
            "operation": "list_processes",
        ])

        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(raw)
        ) { error in
            XCTAssertEqual(
                error as? AgentIntegrationLocalTransportError,
                .invalidMessage("Unsupported local protocol version"))
        }
    }

    func testVersionTenMachineNameSemanticsAreRejected() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": 10,
            "requestID": UUID().uuidString,
            "operation": "session_health",
        ])

        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(raw)
        ) { error in
            XCTAssertEqual(
                error as? AgentIntegrationLocalTransportError,
                .invalidMessage("Unsupported local protocol version"))
        }
    }

    func testOlderHostResponseIsTypedAsCompatibilityNotInvalidData() throws {
        let older = AgentIntegrationLocalProtocol.version - 1
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": older,
            "requestID": UUID().uuidString,
            "error": ["code": "invalid-request",
                      "message": "Unsupported local protocol version"],
        ])

        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeResponse(raw)
        ) { error in
            XCTAssertEqual(
                error as? AgentIntegrationLocalTransportError,
                .incompatibleProtocol(
                    expected: AgentIntegrationLocalProtocol.version,
                    actual: older))
        }
    }

    func testSocketRoundTripsOnlyAnArtifactApprovalReceipt()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt =
            "now-artifact-00000000-0000-0000-0000-000000000000"
        let expected = AgentIntegrationArtifactTransferResult.expired(.init(
            code: "now-artifact-approval-expired",
            message: "The artifact approval receipt has expired"))
        var captured: String?
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { request in
                guard request.operation == .transferApprovedArtifact else {
                    return .sessionHealth(.hostUnavailable)
                }
                captured = request.approvalReceipt
                return .transferApprovedArtifact(expected)
            })
        try server.start()
        defer { server.stop() }

        let result = try await AgentIntegrationLocalClient(
            endpoint: endpoint).transferApprovedArtifact(receipt: receipt)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(captured, receipt)
        let encoded = try AgentIntegrationLocalCodec.encode(
            .transferApprovedArtifact(receipt: receipt))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("\"path\""))
        XCTAssertFalse(text.contains("\"destination\""))
    }

    func testMalformedArtifactReceiptNeverReachesLocalHandler()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = InvocationFlag()
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in
                await invocation.mark()
                return .transferApprovedArtifact(.unavailable(.guest))
            })
        try server.start()
        defer { server.stop() }
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "transfer_approved_artifact",
            "approvalReceipt": "/tmp/project/file",
        ])

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(raw)
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(response)
        let wasHandled = await invocation.wasHandled
        XCTAssertEqual(decoded.error?.code, "invalid-request")
        XCTAssertFalse(wasHandled)
    }

    // MARK: - a reply that does not fit is still a reply

    /// **The silent close, named.**
    ///
    /// `finish` encoded the response with `try?` and returned on failure,
    /// and its `defer` closed the socket — so an answer past the 64 KB
    /// ceiling reached the caller as a hang-up with no error frame, no
    /// code and no reason. Found on 2026-08-07 as
    /// `mirror_read --intention snapshot` closing the connection while
    /// `status`, `metrics` and `find` answered normally on the same path,
    /// which reads as a broken host rather than an oversized payload.
    ///
    /// It is deliberately posed here at the TRANSPORT rather than at
    /// `mirror_read`: the encode is the one exit every served operation
    /// leaves by, so every operation had this failure and only one of them
    /// had been seen to.
    func testAnOversizedReplyIsRefusedWithAReasonRatherThanAClosedSocket()
        async throws {
        let (endpoint, root) = try temporaryEndpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { _ in .mirrorRead(.init(unavailable: .init(
                code: "oversized-on-purpose",
                message: String(repeating: "M", count: 80 * 1024)))) })
        try server.start()
        defer { server.stop() }
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "mirror_read",
            "mirrorReadRequest": ["intention": "snapshot"],
        ])

        let response = try await AgentIntegrationLocalClient(
            endpoint: endpoint).sendRaw(raw)

        /* The refusal itself has to fit, or the cure is the disease. */
        XCTAssertLessThanOrEqual(
            response.count, AgentIntegrationLocalProtocol.maximumMessageBytes)
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(response)
        XCTAssertEqual(decoded.error?.code, "response-too-large")

        /* Specific enough to act on: which operation, how big it actually
           was, and what the ceiling is. "Not supported" would not be a
           reason — a caller cannot tell from it whether to narrow the
           request or to file a defect. */
        let message = try XCTUnwrap(decoded.error?.message)
        XCTAssertTrue(message.contains("mirror_read"), message)
        XCTAssertTrue(message.contains(
            "\(AgentIntegrationLocalProtocol.maximumMessageBytes)"), message)
        XCTAssertTrue(message.contains("bytes"), message)
    }

    /// The same guarantee, asked of every operation rather than of the one
    /// that was caught. `notImplemented` carries a free-form
    /// `AgentIntegrationUnavailable`, so it can be made oversized for ANY
    /// operation — which is what makes this a class check and not a second
    /// copy of the row above.
    func testNoOperationCanCloseTheSocketWithoutReplying() async throws {
        for operation in ["session_health", "list_processes", "mirror_read",
                          "machine_facts", "catalog_search",
                          "transfer_cancel"] {
            let (endpoint, root) = try temporaryEndpoint()
            defer { try? FileManager.default.removeItem(at: root) }
            let server = try AgentIntegrationLocalServer(
                endpoint: endpoint,
                handler: { _ in .notImplemented(.init(
                    code: "oversized-on-purpose",
                    message: String(repeating: "N", count: 80 * 1024))) })
            try server.start()
            defer { server.stop() }
            var request: [String: Any] = [
                "version": AgentIntegrationLocalProtocol.version,
                "requestID": UUID().uuidString,
                "operation": operation,
            ]
            if operation == "mirror_read" {
                request["mirrorReadRequest"] = ["intention": "status"]
            }
            let raw = try JSONSerialization.data(withJSONObject: request)

            let response = try await AgentIntegrationLocalClient(
                endpoint: endpoint).sendRaw(raw)
            let decoded = try AgentIntegrationLocalCodec.decodeResponse(
                response)
            XCTAssertEqual(decoded.error?.code, "response-too-large",
                           "\(operation) closed without replying")
            XCTAssertTrue(
                decoded.error?.message.contains(operation) ?? false,
                "\(operation) refusal must name the operation it refused")
        }
    }
}

private actor InvocationFlag {
    private(set) var wasHandled = false

    func mark() {
        wasHandled = true
    }
}

private actor UploadOperationRecorder {
    private(set) var operations: [AgentIntegrationLocalRequest.Operation] = []

    func record(_ operation: AgentIntegrationLocalRequest.Operation) {
        operations.append(operation)
    }
}
