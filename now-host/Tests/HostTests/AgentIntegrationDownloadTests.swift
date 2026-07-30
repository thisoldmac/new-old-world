import XCTest
@testable import Host
import NOWAgentIntegration

/// The download capability's own coverage, aimed at the thing that is
/// genuinely its own: **the policy**, not the transfer.
///
/// The bytes move over the reverse-streaming path, which has its own tests
/// and a bounded metal receipt (docs/reverse-file-streaming.md). What is new
/// here is the authority around it — one path beneath a host-owned root, a
/// ceiling applied to what the guest's own listing reported BEFORE anything
/// crosses, a destination the caller cannot name, and a receipt that says
/// where the file went and whether its checksum was checked. So most tests
/// below assert on what the host refused and on what it never sent.
@MainActor
final class AgentIntegrationDownloadTests: XCTestCase {
    private func makePolicy(root: String = "") -> GuestFileAccessPolicy {
        let suite = "AgentDownload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(root, forKey: GuestFileAccessPolicy.rootKey)
        defaults.set(1, forKey: GuestFileAccessPolicy.versionKey)
        return GuestFileAccessPolicy(defaults: defaults)
    }

    /// A store rooted in the test's own temporary directory, so nothing
    /// touches the real per-launch private root.
    private func makeStore(
        availableBytes: Int64 = 1 << 40
    ) throws -> (AgentDownloadStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-download-test-\(UUID().uuidString)",
                isDirectory: true)
        let store = try AgentDownloadStore(
            rootURL: root, availableBytes: { availableBytes })
        return (store, root)
    }

    private func entry(
        name: String = "today.txt",
        kind: String = "file",
        dataBytes: Int? = 13,
        rsrcBytes: Int? = 0
    ) -> FileEntry {
        FileEntry(
            name: name, kind: kind, fileType: "TEXT", creator: "ttxt",
            dataBytes: dataBytes, rsrcBytes: rsrcBytes,
            modified: 3_500_000_000, identity: "0123456789abcdef")
    }

    /// Serves one bounded listing page containing `entries`, and records
    /// every `file.get` path it is asked for. The pull half is scripted by
    /// the caller, because half these tests are about a pull that must never
    /// happen.
    private final class Script {
        var listedPaths: [String] = []
        var gotPaths: [String] = []
    }

    private func install(
        on guest: FakeGuest,
        script: Script,
        entries: [FileEntry],
        pull: ((Int, FileGet) -> Void)? = nil
    ) {
        guest.onMessage = { message in
            switch message {
            case .fileList(let request):
                script.listedPaths.append(request.path)
                try? guest.send(.fileListing(FileListing(
                    id: request.id, path: request.path, entries: entries,
                    more: false, cursor: nil, root: "Macintosh HD:")))
            case .fileGet(let request):
                script.gotPaths.append(request.path)
                pull?(request.id, request)
            default:
                break
            }
        }
    }

    private func makeCommands(
        listener: GuestListener,
        policy: GuestFileAccessPolicy,
        store: AgentDownloadStore?,
        sessionID: UUID,
        audit: @escaping (String) -> Void = { _ in }
    ) -> GuestFilesCommandService {
        GuestFilesCommandService(
            listener: listener,
            policy: policy,
            currentSessionID: { sessionID },
            audit: { _, line in audit(line) },
            downloadStore: store)
    }

    // MARK: - The whole way through

    /// One file lands in host-owned storage, and the receipt is what names
    /// it.
    ///
    /// The assertions worth reading are the last three: the landed path is
    /// INSIDE the store's root and nowhere a caller chose, the file is
    /// read-only once it is there, and the wire request count is the two
    /// exchanges the policy actually spent — a listing to bound the size and
    /// the pull itself.
    func testAFileLandsInHostOwnedStorageAndTheReceiptNamesIt()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("First\rSecond\r".utf8)
        let script = Script()
        install(on: guest, script: script, entries: [entry()]) { id, _ in
            try? guest.send(.fileBegin(FileBegin(
                id: id, transfer: 7, name: "today.txt", container: "data",
                bytes: payload.count, dataBytes: payload.count,
                rsrcBytes: 0, fileType: "TEXT", creator: "ttxt",
                modified: 3_500_000_000)))
            guest.sendRaw((try? FrameCodec.encode(
                channel: .bulk, flags: [.end], transfer: 7,
                payload: payload)) ?? Data())
            try? guest.send(.fileEnd(FileEnd(
                id: id, transfer: 7, ok: true, sendMs: 12,
                crc32: TransferIdentity.crc32(payload))))
        }
        var audit: [String] = []
        let commands = makeCommands(
            listener: listener, policy: makePolicy(), store: store,
            sessionID: UUID(), audit: { audit.append($0) })

        let response = await commands.download(path: "today.txt")
        let landing = try XCTUnwrap(response.value)

        XCTAssertEqual(response.receipt.operation, .download)
        XCTAssertEqual(response.receipt.outcome, .success)
        XCTAssertEqual(response.receipt.affectedPaths, ["today.txt"])
        XCTAssertEqual(response.receipt.wireRequestCount, 2)
        XCTAssertEqual(script.gotPaths, ["today.txt"])
        XCTAssertEqual(landing.guestPath, "today.txt")
        XCTAssertEqual(landing.bytes, payload.count)
        XCTAssertEqual(landing.container, "data")
        XCTAssertEqual(landing.crc32,
                       Int(TransferIdentity.crc32(payload)))
        XCTAssertNil(landing.resumeToken)

        let url = URL(fileURLWithPath: landing.hostPath)
        XCTAssertEqual(url.deletingLastPathComponent()
            .resolvingSymlinksInPath(),
                       root.resolvingSymlinksInPath(),
                       "a download must land inside host-owned storage")
        XCTAssertEqual(try Data(contentsOf: url), payload)
        let mode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[
                .posixPermissions] as? NSNumber)?.int16Value)
        XCTAssertEqual(mode, 0o400,
                       "a landed download is read-only once it is there")
        XCTAssertTrue(audit.contains { $0.contains("guestFiles.download") })
    }

    /// A guest that computed no checksum leaves the file UNCHECKED, and the
    /// receipt says so by absence rather than by a comforting default.
    func testAGuestThatSentNoChecksumLeavesTheFileReportedUnchecked()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([1, 2, 3])
        let script = Script()
        install(on: guest, script: script,
                entries: [entry(dataBytes: 3)]) { id, _ in
            try? guest.send(.fileBegin(FileBegin(
                id: id, transfer: 8, name: "today.txt",
                container: "macbinary", bytes: payload.count,
                dataBytes: 3, rsrcBytes: 0, fileType: nil, creator: nil,
                modified: nil, offset: nil, resumeToken: "src-42")))
            guest.sendRaw((try? FrameCodec.encode(
                channel: .bulk, flags: [.end], transfer: 8,
                payload: payload)) ?? Data())
            try? guest.send(.fileEnd(FileEnd(
                id: id, transfer: 8, ok: true, sendMs: 3)))
        }
        let commands = makeCommands(
            listener: listener, policy: makePolicy(), store: store,
            sessionID: UUID())

        let response = await commands.download(path: "today.txt")
        let landing = try XCTUnwrap(response.value)

        XCTAssertNil(landing.crc32,
                     "no guest checksum means unchecked, not correct")
        XCTAssertEqual(landing.container, "macbinary")
        XCTAssertEqual(landing.resumeToken, "src-42",
                       "a token the guest offered is reported as offered")
    }

    /// The caller's path is rebased beneath the host's `guestRoot`, both for
    /// the bounding listing and for the pull.
    func testThePathIsRebasedBeneathTheHostOwnedRoot() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Script()
        install(on: guest, script: script, entries: [entry()]) { id, _ in
            try? guest.send(.fileBegin(FileBegin(
                id: id, transfer: 9, name: "today.txt", container: "data",
                bytes: 1, dataBytes: 1, rsrcBytes: 0)))
            guest.sendRaw((try? FrameCodec.encode(
                channel: .bulk, flags: [.end], transfer: 9,
                payload: Data([7]))) ?? Data())
            try? guest.send(.fileEnd(FileEnd(
                id: id, transfer: 9, ok: true, sendMs: 1)))
        }
        let commands = makeCommands(
            listener: listener, policy: makePolicy(root: "Lab"),
            store: store, sessionID: UUID())

        let response = await commands.download(path: "Logs:today.txt")

        XCTAssertEqual(response.receipt.outcome, .success)
        XCTAssertEqual(script.listedPaths, ["Lab:Logs"])
        XCTAssertEqual(script.gotPaths, ["Lab:Logs:today.txt"])
        XCTAssertEqual(response.value?.guestPath, "Logs:today.txt")
    }

    // MARK: - What it refuses, and refuses BEFORE the wire

    /// The ceiling is applied to the size the guest's own listing reported,
    /// and the refusal costs one listing and no transfer.
    ///
    /// This is the assertion the whole policy rests on: `gotPaths` empty
    /// means no byte of a too-large file crossed. Defaulting the ceiling
    /// check away — or moving it after the pull — fails here by name.
    func testAnItemOverTheCeilingIsRefusedBeforeAnyByteMoves()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Script()
        install(on: guest, script: script, entries: [
            entry(dataBytes: AgentDownloadPolicy.maximumBytes,
                  rsrcBytes: 1),
        ])
        let commands = makeCommands(
            listener: listener, policy: makePolicy(), store: store,
            sessionID: UUID())

        let response = await commands.download(path: "today.txt")

        XCTAssertEqual(response.receipt.outcome, .refused)
        XCTAssertEqual(response.failure?.code, "now-download-too-large")
        XCTAssertEqual(response.receipt.wireRequestCount, 1)
        XCTAssertTrue(script.gotPaths.isEmpty,
                      "nothing may be pulled once the ceiling refuses it")
        XCTAssertNil(response.value)
    }

    /// A listing that does not say how big something is cannot be bounded,
    /// so it is refused rather than attempted with the size read as zero.
    func testAnItemWhoseSizeTheGuestDidNotReportIsRefused() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Script()
        install(on: guest, script: script,
                entries: [entry(dataBytes: nil, rsrcBytes: nil)])
        let commands = makeCommands(
            listener: listener, policy: makePolicy(), store: store,
            sessionID: UUID())

        let response = await commands.download(path: "today.txt")

        XCTAssertEqual(response.failure?.code, "now-download-size-unknown")
        XCTAssertTrue(script.gotPaths.isEmpty)
    }

    /// A folder is refused, not walked. A download takes one file.
    func testAFolderIsRefusedRatherThanWalked() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Script()
        install(on: guest, script: script,
                entries: [entry(name: "Logs", kind: "folder",
                                dataBytes: 0, rsrcBytes: 0)])
        let commands = makeCommands(
            listener: listener, policy: makePolicy(), store: store,
            sessionID: UUID())

        let response = await commands.download(path: "Logs")

        XCTAssertEqual(response.failure?.code, "now-download-not-a-file")
        XCTAssertTrue(script.gotPaths.isEmpty)
    }

    /// A Mac with no room refuses before the wire too, and says so as a host
    /// fact rather than as something the guest did.
    func testAHostWithoutRoomRefusesBeforeTheWire() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore(availableBytes: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Script()
        install(on: guest, script: script, entries: [entry()])
        let commands = makeCommands(
            listener: listener, policy: makePolicy(), store: store,
            sessionID: UUID())

        let response = await commands.download(path: "today.txt")

        XCTAssertEqual(response.failure?.code,
                       "now-download-insufficient-host-space")
        XCTAssertTrue(script.gotPaths.isEmpty)
    }

    /// Paths that are not one canonical item beneath the root never reach
    /// the wire at all.
    func testUnrepresentableAndEscapingPathsNeverReachTheGuest()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Script()
        install(on: guest, script: script, entries: [entry()])
        let commands = makeCommands(
            listener: listener, policy: makePolicy(root: "Lab"),
            store: store, sessionID: UUID())

        for path in ["Lab:..:Escape", "/etc/passwd", ":Lab", "Lab::x", ""] {
            let response = await commands.download(path: path)
            XCTAssertEqual(response.receipt.outcome, .refused, path)
            XCTAssertEqual(response.receipt.wireRequestCount, 0, path)
        }
        XCTAssertTrue(script.listedPaths.isEmpty)
        XCTAssertTrue(script.gotPaths.isEmpty)
    }

    /// No guest, no transfer, and a receipt that says which.
    func testADisconnectedHostAnswersUnavailableWithAReceipt() async throws {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { nil },
            audit: { _, _ in },
            downloadStore: store)

        let response = await commands.download(path: "today.txt")

        XCTAssertEqual(response.receipt.operation, .download)
        XCTAssertEqual(response.receipt.outcome, .unavailable)
        XCTAssertEqual(response.failure?.code, "now-guest-unavailable")
    }

    /// Without private storage the command is off host-side, and the
    /// capability report says `download` is deferred rather than letting a
    /// transfer start with nowhere to put it.
    func testWithoutPrivateStorageDownloadIsDeferredNotAttempted()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let script = Script()
        install(on: guest, script: script, entries: [entry()])
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID },
            audit: { _, _ in },
            downloadStore: .some(nil))

        let response = await commands.download(path: "today.txt")
        let capabilities = await commands.capabilities().value

        XCTAssertEqual(response.failure?.code,
                       "now-download-staging-unavailable")
        XCTAssertTrue(script.gotPaths.isEmpty)
        XCTAssertEqual(capabilities?.availableCommands,
                       [.capabilities, .list, .stat, .put])
        XCTAssertTrue(
            capabilities?.deferredCommands.contains(.download) ?? false)
    }

    // MARK: - The store's own rules

    /// Two downloads of one guest name do not overwrite each other. The
    /// pull direction keeps the create-only discipline the push direction
    /// keeps on the guest.
    func testASecondDownloadOfOneNameDoesNotOverwriteTheFirst() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try store.land(try staged(in: root, bytes: 3),
                                   named: "Read Me")
        let second = try store.land(try staged(in: root, bytes: 4),
                                    named: "Read Me")

        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.bytes, 3)
        XCTAssertEqual(second.bytes, 4)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: first.url.path))
    }

    /// A guest name is turned into a host FILENAME, never used as a path.
    /// A classic HFS name may legally hold `/` and control bytes, and one of
    /// those reaching `appendingPathComponent` is traversal written by the
    /// other machine.
    func testAGuestNameBecomesAFilenameAndNeverAPath() throws {
        XCTAssertEqual(
            AgentDownloadStore.hostFilename(for: "a/b:c\\d"), "a_b_c_d")
        XCTAssertEqual(
            AgentDownloadStore.hostFilename(for: "\u{3}\u{2}x"), "__x")
        XCTAssertEqual(AgentDownloadStore.hostFilename(for: ".."),
                       "download")
        XCTAssertEqual(AgentDownloadStore.hostFilename(for: "   "),
                       "download")
    }

    /// A file that arrives over the ceiling lands nowhere.
    ///
    /// The pre-check reads the size the guest reported; this is the case
    /// where that was not the size that came — a source that grew, or a
    /// MacBinary whose header and padding the fork sizes did not include.
    /// The bytes are spent and the refusal is honest about it: no path is
    /// reported and nothing is left in the root.
    func testAnArrivalOverTheCeilingIsDiscardedAndLandsNothing() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let oversize = try staged(
            in: root, bytes: AgentDownloadPolicy.maximumBytes + 1)

        XCTAssertThrowsError(try store.land(oversize, named: "big")) {
            XCTAssertEqual(
                ($0 as? AgentDownloadStore.Failure)?.code,
                "now-download-too-large")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("big").path))
    }

    /// A completed staged file, made the way a real transfer makes one —
    /// through the sink, so nothing here fakes the shape of a delivery.
    private func staged(in directory: URL, bytes: Int) throws
        -> InboundFileSink.StagedFile {
        let sink = try InboundFileSink(
            directory: directory, expectedBytes: bytes)
        try sink.append(Data(repeating: 0x41, count: bytes))
        return try sink.finish(expectedCRC32: nil)
    }

    // MARK: - The face

    /// The projection accepts one path and nothing else — which is how "the
    /// caller does not choose the destination" is enforced rather than
    /// merely documented.
    func testTheProjectionAcceptsOnePathAndNoDestination() async {
        for arguments in [
            ["path": "a.txt", "hostPath": "/tmp/x"] as [String: Any],
            ["path": "a.txt", "container": "data"],
            ["path": ""],
            ["path": 3],
            [:],
        ] {
            let outcome = await GuestFilesDownloadProjection.invoke(
                .init(raw: arguments), through: SilentDownloadClient())
            guard case .invalidArguments(let why) = outcome else {
                return XCTFail("accepted \(arguments)")
            }
            XCTAssertTrue(why.contains("now_guest_files_download"))
        }
    }

    /// The published ceiling is the enforced one. Two numbers for one bound
    /// is the drift this repository has already paid for once.
    func testThePublishedCeilingIsTheEnforcedOne() {
        XCTAssertEqual(AgentDownloadStore.maximumBytes,
                       AgentDownloadPolicy.maximumBytes)
        let schema = GuestFilesDownloadProjection.mcpDescriptor
        let output = schema["outputSchema"] as? [String: Any]
        XCTAssertNotNil(output, "the row must publish an output schema")
    }
}

/// Answers "no host" to everything, so an argument test cannot accidentally
/// depend on a transfer.
private struct SilentDownloadClient: AgentIntegrationClient {
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
