import XCTest
@testable import Host
import NOWAgentIntegration

@MainActor
final class GuestFilePathTests: XCTestCase {
    func testCanonicalRootRelativePathsUseClassicSegments() throws {
        XCTAssertEqual(try GuestFilePath("").wireValue, "")
        XCTAssertEqual(try GuestFilePath("Lab:Logs:today.txt").components,
                       ["Lab", "Logs", "today.txt"])
        XCTAssertEqual(
            try GuestFilePath("Logs").appending(to: GuestFilePath("Lab")),
            GuestFilePath(unchecked: "Lab:Logs"))
    }

    func testTraversalAbsoluteAndUnrepresentablePathsAreRejected() {
        for path in [
            ":Lab", "Lab:", "Lab::Code", ".", "..", "Lab:..:Code",
            "/etc", "Lab:\0secret", "Lab:🐈",
            String(repeating: "a", count: 32),
        ] {
            XCTAssertThrowsError(try GuestFilePath(path), path)
        }
    }

    func testClassicControlByteNamesRemainExactlyAddressable() throws {
        let path = "\u{3}\u{2}\u{1}Move&Rename"

        XCTAssertEqual(try GuestFilePath(path).wireValue, path)
    }

    func testCompleteWirePathIsBounded() {
        let components = Array(repeating: String(repeating: "a", count: 31),
                               count: 8)
        XCTAssertThrowsError(try GuestFilePath(
            components.joined(separator: ":")))
    }
}

@MainActor
final class GuestFileAccessPolicyTests: XCTestCase {
    func testApprovedDefaultIsPersistedAndAuditedExplicitly() throws {
        let suite = "GuestFilePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [String] = []

        let policy = GuestFileAccessPolicy(
            defaults: defaults,
            audit: { events.append($0) })

        XCTAssertEqual(policy.snapshot.guestRoot, GuestFilePath(unchecked: ""))
        XCTAssertEqual(policy.snapshot.version, 1)
        XCTAssertEqual(defaults.object(
            forKey: GuestFileAccessPolicy.rootKey) as? String, "")
        XCTAssertEqual(defaults.integer(
            forKey: GuestFileAccessPolicy.versionKey), 1)
        XCTAssertTrue(events.contains {
            $0.contains("initialized") && $0.contains("share root")
        })
    }

    func testStoredScopedRootIsValidatedBeforeUse() throws {
        let suite = "GuestFilePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Lab:Deploy", forKey: GuestFileAccessPolicy.rootKey)
        defaults.set(7, forKey: GuestFileAccessPolicy.versionKey)

        let policy = GuestFileAccessPolicy(defaults: defaults)

        XCTAssertEqual(policy.snapshot.guestRoot.wireValue, "Lab:Deploy")
        XCTAssertEqual(policy.snapshot.version, 7)
    }

    func testInvalidStoredRootIsRejectedAndRestoredExplicitly() throws {
        let suite = "GuestFilePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Lab:..:Escape", forKey: GuestFileAccessPolicy.rootKey)
        defaults.set(9, forKey: GuestFileAccessPolicy.versionKey)
        var events: [String] = []

        let policy = GuestFileAccessPolicy(
            defaults: defaults,
            audit: { events.append($0) })

        XCTAssertEqual(policy.snapshot.guestRoot.wireValue, "")
        XCTAssertEqual(policy.snapshot.version, 1)
        XCTAssertEqual(defaults.string(
            forKey: GuestFileAccessPolicy.rootKey), "")
        XCTAssertTrue(events.contains { $0.contains("rejected") })
        XCTAssertTrue(events.contains { $0.contains("initialized") })
    }
}

@MainActor
final class GuestFilesCommandTests: XCTestCase {
    func testDisconnectedListReturnsTypedUnavailableAndAuditReceipt()
        async throws {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let policy = makePolicy()
        var audit: [String] = []
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: policy,
            currentSessionID: { nil },
            audit: { _, line in audit.append(line) })

        let response = await commands.list(path: "")

        XCTAssertEqual(response.receipt.operation, .list)
        XCTAssertEqual(response.receipt.outcome, .unavailable)
        XCTAssertEqual(response.failure?.code, "now-guest-unavailable")
        XCTAssertNil(response.value)
        XCTAssertEqual(audit.count, 2)
        XCTAssertTrue(audit[0].contains("started"))
        XCTAssertTrue(audit[1].contains("unavailable"))
        XCTAssertEqual(listener.state, .idle)
    }

    func testCapabilitiesObserveTheActiveRootAndOnlyCompletedCommands()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            XCTAssertEqual(request.path, "")
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: "",
                entries: [],
                more: false,
                cursor: 1,
                root: "Macintosh HD:")))
        }

        let response = await commands.capabilities()
        let capabilities = try XCTUnwrap(response.value)

        XCTAssertEqual(response.receipt.outcome, .success)
        XCTAssertEqual(response.receipt.sessionID, sessionID)
        XCTAssertEqual(capabilities.guestRoot, "")
        XCTAssertEqual(capabilities.rootLabel, "Macintosh HD:")
        XCTAssertEqual(capabilities.availableCommands,
                       [.capabilities, .list, .stat, .put])
        XCTAssertEqual(capabilities.deferredCommands,
                       [.download, .readText, .tailText, .mkdir,
                        .move, .delete, .deployTree, .prune])
        XCTAssertEqual(capabilities.maximumPageEntries, 16)
        XCTAssertEqual(capabilities.maximumPathBytes, 223)
    }

    func testListRebasesCallerPathUnderPolicyAndPreservesMetadata()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(root: "Lab"),
            currentSessionID: { UUID(uuidString:
                "00000000-0000-0000-0000-000000000001")! })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            XCTAssertEqual(request.path, "Lab:Logs")
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: request.path,
                entries: [
                    FileEntry(
                        name: "today.txt", kind: "file",
                        fileType: "TEXT", creator: "ttxt",
                        dataBytes: 42, rsrcBytes: 3,
                        modified: 3_500_000_000,
                        identity: "0123456789abcdef"),
                ],
                more: true,
                cursor: 2)))
        }

        let response = await commands.list(path: "Logs")
        let listing = try XCTUnwrap(response.value)

        XCTAssertEqual(listing.path, "Logs")
        XCTAssertEqual(listing.entries.map(\.path), ["Logs:today.txt"])
        XCTAssertEqual(listing.entries.first?.fileType, "TEXT")
        XCTAssertEqual(listing.entries.first?.creator, "ttxt")
        XCTAssertEqual(listing.entries.first?.dataBytes, 42)
        XCTAssertEqual(listing.entries.first?.resourceBytes, 3)
        XCTAssertNotNil(listing.entries.first?.observationReference)
        XCTAssertEqual(listing.nextCursor, 2)
        XCTAssertTrue(listing.hasMore)
    }

    func testListAcceptsClassicControlByteNamesWithoutInjectingAudit()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let name = "\u{3}\u{2}\u{1}Move&Rename"
        let sessionID = UUID()
        var audit: [String] = []
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID },
            audit: { _, line in audit.append(line) })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: request.path,
                entries: [
                    FileEntry(
                        name: name, kind: "folder",
                        fileType: nil, creator: nil,
                        dataBytes: nil, rsrcBytes: nil, modified: 0),
                ],
                more: false,
                cursor: 2)))
        }

        let response = await commands.list(path: "")
        let listing = try XCTUnwrap(response.value)

        XCTAssertEqual(listing.entries.first?.name, name)
        XCTAssertEqual(listing.entries.first?.path, name)
        XCTAssertFalse(audit.joined(separator: "\n").contains(name))
    }

    func testStatPagesToAnExactEntryWithoutReturningSiblingPaths()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            let entries: [FileEntry]
            let more: Bool
            let cursor: Int?
            if request.cursor == nil {
                entries = [
                    FileEntry(name: "Other", kind: "file",
                              fileType: nil, creator: nil,
                              dataBytes: 1, rsrcBytes: 0, modified: nil),
                ]
                more = true
                cursor = 2
            } else {
                entries = [
                    FileEntry(name: "Target", kind: "file",
                              fileType: "APPL", creator: "ttxt",
                              dataBytes: 99, rsrcBytes: 12,
                              modified: 3_500_000_000),
                ]
                more = false
                cursor = 3
            }
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: request.path,
                entries: entries,
                more: more,
                cursor: cursor)))
        }

        let response = await commands.stat(path: "Folder:Target")
        let item = try XCTUnwrap(response.value)

        XCTAssertEqual(response.receipt.outcome, .success)
        XCTAssertEqual(item.path, "Folder:Target")
        XCTAssertEqual(item.name, "Target")
        XCTAssertEqual(item.fileType, "APPL")
        XCTAssertEqual(item.resourceBytes, 12)
        XCTAssertFalse(item.isFolder)
    }

    func testStatReportsScanLimitInsteadOfGuessingPastItsBound()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID },
            maximumStatPages: 2)
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: request.path,
                entries: [
                    FileEntry(name: "Not It", kind: "file",
                              fileType: nil, creator: nil,
                              dataBytes: 1, rsrcBytes: 0, modified: nil),
                ],
                more: true,
                cursor: (request.cursor ?? 1) + 1)))
        }

        let response = await commands.stat(path: "Folder:Target")

        XCTAssertEqual(response.receipt.outcome, .scanLimit)
        XCTAssertEqual(response.failure?.code, "now-files-scan-limit")
        XCTAssertNil(response.value)
    }

    func testSessionChangeDuringAListingReturnsStaleNotRows()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            sessionID = UUID()
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: request.path,
                entries: [
                    FileEntry(name: "Stale", kind: "file",
                              fileType: nil, creator: nil,
                              dataBytes: 1, rsrcBytes: 0, modified: nil),
                ],
                more: false,
                cursor: 2)))
        }

        let response = await commands.list(path: "")

        XCTAssertEqual(response.receipt.outcome, .staleSession)
        XCTAssertEqual(response.failure?.code, "now-session-stale")
        XCTAssertNil(response.value)
    }

    func testInvalidPathAndCursorAreRefusedBeforeWireUse() async {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(root: "Lab"),
            currentSessionID: { UUID() })

        let escaped = await commands.list(path: "..")
        let invalidCursor = await commands.list(path: "", cursor: 0)

        XCTAssertEqual(escaped.receipt.outcome, .refused)
        XCTAssertEqual(escaped.failure?.code, "now-files-path-invalid")
        XCTAssertEqual(escaped.receipt.wireRequestCount, 0)
        XCTAssertEqual(invalidCursor.receipt.outcome, .refused)
        XCTAssertEqual(
            invalidCursor.failure?.code, "now-files-cursor-invalid")
        XCTAssertEqual(invalidCursor.receipt.wireRequestCount, 0)
        XCTAssertEqual(listener.state, .idle)
    }

    func testRepeatedConcurrentListingsRemainIndependentAndBounded()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: request.path,
                entries: [],
                more: false,
                cursor: 1,
                root: "Macintosh HD:")))
        }

        let tasks = (0..<6).map { _ in
            Task { @MainActor in
                await commands.list(path: "")
            }
        }
        var responses: [GuestFileCommandResponse<
            GuestFileListingSnapshot
        >] = []
        for task in tasks {
            responses.append(await task.value)
        }

        XCTAssertEqual(responses.count, 6)
        XCTAssertEqual(
            Set(responses.map(\.receipt.commandID)).count, 6)
        XCTAssertTrue(responses.allSatisfy {
            $0.receipt.outcome == .success
                && $0.receipt.wireRequestCount == 1
                && $0.value?.entries.isEmpty == true
        })
    }

    func testMalformedGuestListingIsRefusedInsteadOfProjected()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: "a different folder",
                entries: [
                    FileEntry(
                        name: "..", kind: "unknown",
                        fileType: nil, creator: nil,
                        dataBytes: -1, rsrcBytes: 0, modified: -1),
                ],
                more: true,
                cursor: nil)))
        }

        let response = await commands.list(path: "")

        XCTAssertEqual(response.receipt.outcome, .refused)
        XCTAssertEqual(
            response.failure?.code, "now-files-listing-invalid")
        XCTAssertEqual(response.receipt.wireRequestCount, 1)
        XCTAssertNil(response.value)
    }

    func testGuestRefusalIsBoundedBeforeItReachesAProjection()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            try? guest.send(.fileRefuse(FileRefuse(
                id: request.id,
                code: String(repeating: "c", count: 200),
                reason: String(repeating: "m", count: 1_000))))
        }

        let response = await commands.list(path: "")

        XCTAssertEqual(response.receipt.outcome, .refused)
        XCTAssertLessThanOrEqual(
            response.failure?.code.unicodeScalars.count ?? .max, 64)
        XCTAssertLessThanOrEqual(
            response.failure?.message.unicodeScalars.count ?? .max, 256)
        XCTAssertNil(response.value)
    }

    func testHostCommandRegistrationDoesNotAddUIOrStartTheListener()
        throws {
        let suite = "GuestFilesHostState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let modules = ModuleRegistry.standard.modules

        let state = HostAppState(
            registry: .standard, defaults: defaults)

        XCTAssertEqual(ModuleRegistry.standard.modules, modules)
        XCTAssertEqual(state.listener.state, .idle)
        XCTAssertEqual(defaults.string(
            forKey: GuestFileAccessPolicy.rootKey), "")
        XCTAssertEqual(defaults.integer(
            forKey: GuestFileAccessPolicy.versionKey), 1)
    }

    func testAgentProjectionPreservesReceiptScopeAndForkMetadata()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(root: "Lab"),
            currentSessionID: { sessionID })
        guest.onMessage = { message in
            guard case .fileList(let request) = message else { return }
            try? guest.send(.fileListing(FileListing(
                id: request.id,
                path: request.path,
                entries: [
                    FileEntry(
                        name: "Resource", kind: "file",
                        fileType: "APPL", creator: "TEST",
                        dataBytes: 12, rsrcBytes: 34,
                        modified: 3_500_000_000),
                ],
                more: false,
                cursor: 1)))
        }

        let result = await commands.agentList(path: "", cursor: nil)

        guard case .completed(let receipt, let value, let failure) = result
        else {
            return XCTFail("host command result must cross the projection")
        }
        XCTAssertEqual(receipt.sessionID, sessionID)
        XCTAssertEqual(receipt.operation, .list)
        XCTAssertEqual(receipt.outcome, .success)
        XCTAssertEqual(receipt.policyVersion, 1)
        XCTAssertNil(failure)
        XCTAssertEqual(value?.entries.first?.path, "Resource")
        XCTAssertEqual(value?.entries.first?.resourceBytes, 34)
    }

    private func makePolicy(root: String = "") -> GuestFileAccessPolicy {
        let suite = "GuestFilesCommand.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(root, forKey: GuestFileAccessPolicy.rootKey)
        defaults.set(1, forKey: GuestFileAccessPolicy.versionKey)
        return GuestFileAccessPolicy(defaults: defaults)
    }
}
