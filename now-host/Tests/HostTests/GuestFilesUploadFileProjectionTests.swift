import CryptoKit
import XCTest
@testable import Host
import NOWAgentIntegration

/// The local-file upload row's own coverage, aimed at the two things that
/// are genuinely its own: **that the pinned workspace root contains every
/// path it will read** — `..` and symlink escapes refused, no root meaning
/// no reads at all — and **that the internal stage-and-commit lane is
/// driven whole and in order**, offsets exact and the declared SHA-256
/// computed from the file's real bytes.
///
/// One class on purpose: `HostProjectionLocalRead` is process state, so
/// every test that stages or clears it lives here where XCTest runs them
/// serially, and setUp/tearDown leave it empty for everyone else.
@MainActor
final class GuestFilesUploadFileProjectionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        HostProjectionLocalRead.configure(workspaceRoot: nil)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        HostProjectionLocalRead.configure(workspaceRoot: nil)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - No root, no reads

    func testACompanionWithoutAWorkspaceLaneRefusesEveryPath() async throws {
        let file = root.appendingPathComponent("app.bin")
        try Data("bytes".utf8).write(to: file)
        let client = UploadFileRecordingClient()

        let outcome = await GuestFilesUploadFileProjection.invoke(
            .init(raw: [
                "localPath": "app.bin",
                "destinationPath": "Lab:app.bin",
                "container": "data",
            ]),
            through: client)

        /* A typed unavailability, not an argument refusal: the arguments
           were fine and the lane was missing. */
        guard case .value(let value) = outcome else {
            return XCTFail("no injected root must refuse: \(outcome)")
        }
        let encoded = try value.encoded(using: JSONEncoder())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])
        XCTAssertEqual(object["hostAvailable"] as? Bool, false)
        let unavailable = try XCTUnwrap(
            object["unavailable"] as? [String: Any])
        XCTAssertEqual(unavailable["code"] as? String,
                       "now-files-workspace-unavailable")
        XCTAssertTrue(
            (unavailable["message"] as? String ?? "")
                .contains("launched without a workspace lane"))
        let calls = await client.calls
        XCTAssertEqual(calls, [], "nothing may be staged without a root")
    }

    // MARK: - Containment

    func testADotDotEscapeIsRefusedWithoutTouchingTheLane() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        HostProjectionLocalRead.configure(workspaceRoot: root)
        let client = UploadFileRecordingClient()

        let outcome = await GuestFilesUploadFileProjection.invoke(
            .init(raw: [
                "localPath": "../\(outside.lastPathComponent)",
                "destinationPath": "Lab:steal.txt",
                "container": "data",
            ]),
            through: client)

        guard case .invalidArguments(let reason) = outcome else {
            return XCTFail("a ..-escape must be refused: \(outcome)")
        }
        XCTAssertTrue(
            reason.contains("outside the chat workspace root"), reason)
        let calls = await client.calls
        XCTAssertEqual(calls, [])
    }

    func testASymlinkEscapeIsRefusedWithoutTouchingTheLane() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside)
        HostProjectionLocalRead.configure(workspaceRoot: root)
        let client = UploadFileRecordingClient()

        let outcome = await GuestFilesUploadFileProjection.invoke(
            .init(raw: [
                "localPath": "innocent.txt",
                "destinationPath": "Lab:steal.txt",
                "container": "data",
            ]),
            through: client)

        guard case .invalidArguments(let reason) = outcome else {
            return XCTFail("a symlink escape must be refused: \(outcome)")
        }
        XCTAssertTrue(
            reason.contains("outside the chat workspace root"), reason)
        let calls = await client.calls
        XCTAssertEqual(calls, [])
    }

    func testAnAbsolutePathOutsideTheRootIsRefused() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        HostProjectionLocalRead.configure(workspaceRoot: root)
        let client = UploadFileRecordingClient()

        let outcome = await GuestFilesUploadFileProjection.invoke(
            .init(raw: [
                "localPath": outside.path,
                "destinationPath": "Lab:steal.txt",
                "container": "data",
            ]),
            through: client)

        guard case .invalidArguments = outcome else {
            return XCTFail("an absolute escape must be refused: \(outcome)")
        }
        let calls = await client.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: - Bounds

    func testAFileOverTheCeilingIsRefusedBeforeAnyStaging() async throws {
        let file = root.appendingPathComponent("huge.bin")
        let size = GuestFilesUploadFileProjection.maximumLocalFileBytes + 1
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        HostProjectionLocalRead.configure(workspaceRoot: root)
        let client = UploadFileRecordingClient()

        let outcome = await GuestFilesUploadFileProjection.invoke(
            .init(raw: [
                "localPath": "huge.bin",
                "destinationPath": "Lab:huge.bin",
                "container": "data",
            ]),
            through: client)

        guard case .invalidArguments(let reason) = outcome else {
            return XCTFail("an oversized file must be refused: \(outcome)")
        }
        XCTAssertTrue(reason.contains("32 MiB"), reason)
        let calls = await client.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: - The lane, driven whole

    func testAWorkspaceFileIsStagedInOrderAndCommitted() async throws {
        /* Two full chunks and a remainder, so the offset arithmetic is
           exercised rather than an under-one-chunk special case. */
        let chunk =
            AgentIntegrationGuestFilePolicy.maximumUploadChunkBytes
        let payload = Data((0..<(chunk * 2 + 511)).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("Build")
            .appendingPathComponent("New Old World.bin")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try payload.write(to: file)
        HostProjectionLocalRead.configure(workspaceRoot: root)
        let client = UploadFileRecordingClient()

        let outcome = await GuestFilesUploadFileProjection.invoke(
            .init(raw: [
                "localPath": "Build/New Old World.bin",
                "destinationPath": "Lab:New Old World.bin",
                "container": "macbinary",
                "fileType": "APPL",
                "creator": "NOWo",
            ]),
            through: client)

        guard case .value(let value) = outcome else {
            return XCTFail("a bounded workspace file must upload: \(outcome)")
        }
        let declaredBegin = await client.begin
        let begin = try XCTUnwrap(declaredBegin)
        XCTAssertEqual(begin.destinationPath, "Lab:New Old World.bin")
        XCTAssertEqual(begin.bytes, payload.count)
        XCTAssertEqual(begin.container, "macbinary")
        XCTAssertEqual(begin.fileType, "APPL")
        XCTAssertEqual(begin.creator, "NOWo")
        XCTAssertEqual(begin.sha256, sha256(payload))
        let calls = await client.calls
        XCTAssertEqual(calls, [
            "begin",
            "append@0#\(chunk)",
            "append@\(chunk)#\(chunk)",
            "append@\(chunk * 2)#511",
            "commit",
        ])
        let appended = await client.appendedBytes
        XCTAssertEqual(appended, payload)
        /* The outcome is the commit's own receipt, rendered through the
           projection value: decode it back and check the identity facts
           survived the trip. */
        let encoder = JSONEncoder()
        let encoded = try value.encoded(using: encoder)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])
        XCTAssertEqual(object["hostAvailable"] as? Bool, true)
        let receipt = try XCTUnwrap(object["value"] as? [String: Any])
        XCTAssertEqual(receipt["sha256"] as? String, sha256(payload))
        XCTAssertEqual(receipt["totalBytes"] as? Int, payload.count)
    }

    func testAFailedAppendStopsTheLaneAndSurfacesTheStageAnswer()
        async throws {
        let chunk =
            AgentIntegrationGuestFilePolicy.maximumUploadChunkBytes
        let payload = Data(repeating: 7, count: chunk * 3)
        let file = root.appendingPathComponent("stall.bin")
        try payload.write(to: file)
        HostProjectionLocalRead.configure(workspaceRoot: root)
        let client = UploadFileRecordingClient()
        await client.failAppend(
            at: chunk,
            code: "now-files-upload-expired",
            message: "the private stage expired")

        let outcome = await GuestFilesUploadFileProjection.invoke(
            .init(raw: [
                "localPath": "stall.bin",
                "destinationPath": "Lab:stall.bin",
                "container": "data",
            ]),
            through: client)

        guard case .value(let value) = outcome else {
            return XCTFail("a stage failure is surfaced, not hidden: "
                + "\(outcome)")
        }
        let calls = await client.calls
        XCTAssertEqual(calls, [
            "begin", "append@0#\(chunk)", "append@\(chunk)#\(chunk)",
        ], "the failed append ends the lane; nothing commits")
        let encoded = try value.encoded(using: JSONEncoder())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])
        let failure = try XCTUnwrap(object["failure"] as? [String: Any])
        XCTAssertEqual(
            failure["code"] as? String, "now-files-upload-expired")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

/// Answers the upload trio in order, records every call, and everything
/// else answers "no host" through the protocol's own defaults.
private actor UploadFileRecordingClient: AgentIntegrationClient {
    private(set) var calls: [String] = []
    private(set) var begin: AgentIntegrationGuestFileUploadBegin?
    private(set) var appendedBytes = Data()
    private let uploadID = UUID()
    private var failAppendAtOffset: Int?
    private var appendFailure: AgentIntegrationGuestFileFailure?

    func failAppend(at offset: Int, code: String, message: String) {
        failAppendAtOffset = offset
        appendFailure = .init(code: code, message: message)
    }

    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        calls.append("begin")
        begin = upload
        return .completed(
            receipt: receipt(operation: .put),
            value: stage(expected: upload.bytes, received: 0),
            failure: nil)
    }

    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        calls.append("append@\(offset)#\(bytes.count)")
        XCTAssertEqual(uploadID, self.uploadID,
                       "appends must reuse the begin's upload ID")
        if offset == failAppendAtOffset, let appendFailure {
            return .completed(
                receipt: receipt(operation: .put, outcome: .expired),
                value: nil,
                failure: appendFailure)
        }
        XCTAssertEqual(offset, appendedBytes.count,
                       "offsets must be exact and in order")
        appendedBytes.append(bytes)
        return .completed(
            receipt: receipt(operation: .put),
            value: stage(
                expected: begin?.bytes ?? 0,
                received: appendedBytes.count),
            failure: nil)
    }

    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        calls.append("commit")
        XCTAssertEqual(uploadID, self.uploadID)
        let begin = begin
        return .completed(
            receipt: receipt(operation: .put),
            value: .init(
                uploadID: uploadID,
                destinationPath: begin?.destinationPath ?? "",
                container: begin?.container ?? "data",
                sha256: begin?.sha256 ?? "",
                totalBytes: begin?.bytes ?? 0,
                acceptedOffset: begin?.bytes ?? 0,
                receiverConfirmedBytes: begin?.bytes ?? 0,
                elapsedMs: 12,
                averageBytesPerSecond: 1_000,
                stalledState: "not-observed",
                maximumProgressGapMs: nil,
                progressEvidence: "receiver-progress",
                guestFreeBytesBefore: nil,
                guestReservedBytes: nil,
                guestStaging: nil,
                finalization: "same-folder-rename",
                destinationAcknowledged: true,
                integrity: "sha256-verified",
                hostStagingCleanup: "removed",
                guestCleanup: "temp-renamed"),
            failure: nil)
    }

    private func stage(expected: Int, received: Int)
        -> AgentIntegrationGuestFileUploadStage {
        .init(
            uploadID: uploadID,
            destinationPath: begin?.destinationPath ?? "",
            expectedBytes: expected,
            receivedBytes: received,
            maximumChunkBytes:
                AgentIntegrationGuestFilePolicy.maximumUploadChunkBytes,
            expiresAt: Date().addingTimeInterval(300),
            hostAvailableBytesAtStart: 1_000_000_000,
            hostReservedBytes: expected,
            sealed: false)
    }

    private func receipt(
        operation: AgentIntegrationGuestFileOperation,
        outcome: AgentIntegrationGuestFileOutcome = .success
    ) -> AgentIntegrationGuestFileReceipt {
        .init(
            commandID: UUID(),
            sessionID: UUID(),
            policyVersion: 1,
            operation: operation,
            startedAt: Date(),
            completedAt: Date(),
            outcome: outcome,
            wireRequestCount: 0)
    }

    // MARK: - The protocol's non-defaulted rows, all "no host"

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
