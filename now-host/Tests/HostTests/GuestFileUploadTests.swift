import CryptoKit
import Darwin
import XCTest
@testable import Host

@MainActor
final class GuestUploadStagingStoreTests: XCTestCase {
    func testDiskPolicyRefusesAReservationBeyondUsableCapacity()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000,
                    policyHeadroomBytes: 100)
            })

        let result = await store.begin(
            expectedBytes: 901,
            expectedSHA256: sha256(Data(repeating: 0, count: 901)))

        guard case .failure(let failure) = result else {
            return XCTFail("reservation must be refused")
        }
        XCTAssertEqual(
            failure.code, "now-files-insufficient-host-space")
    }

    func testOrderedChunksSealToAReadOnlyFileBackedSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<20_000).map { UInt8($0 % 251) })
        let store = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 10_000_000,
                    policyHeadroomBytes: 100_000)
            })
        let begin = try value(await store.begin(
            expectedBytes: payload.count,
            expectedSHA256: sha256(payload)))

        let first = payload.prefix(8_192)
        _ = try value(await store.append(
            uploadID: begin.uploadID,
            offset: 0,
            bytes: Data(first)))
        guard case .failure(let conflict) = await store.append(
            uploadID: begin.uploadID,
            offset: 0,
            bytes: Data(first)) else {
            return XCTFail("repeated offset must conflict")
        }
        XCTAssertEqual(
            conflict.code, "now-files-upload-offset-conflict")
        _ = try value(await store.append(
            uploadID: begin.uploadID,
            offset: first.count,
            bytes: Data(payload.dropFirst(first.count).prefix(8_192))))
        _ = try value(await store.append(
            uploadID: begin.uploadID,
            offset: 16_384,
            bytes: Data(payload.dropFirst(16_384))))

        let sealed = try value(
            await store.seal(uploadID: begin.uploadID))
        let reader = try sealed.source.openReader()
        var reconstructed = Data()
        var offset = 0
        while offset < payload.count {
            let count = min(8_192, payload.count - offset)
            reconstructed.append(
                try reader.read(offset: offset, count: count))
            offset += count
        }
        XCTAssertEqual(reconstructed, payload)
        XCTAssertEqual(sealed.source.sha256, sha256(payload))
        XCTAssertEqual(
            sealed.source.crc32, TransferIdentity.crc32(payload))
    }

    func testDigestMismatchDiscardsStageAndCannotBeReplayed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("wrong".utf8)
        let store = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        let begin = try value(await store.begin(
            expectedBytes: payload.count,
            expectedSHA256: sha256(Data("right".utf8))))
        _ = try value(await store.append(
            uploadID: begin.uploadID, offset: 0, bytes: payload))

        guard case .failure(let failure) =
                await store.seal(uploadID: begin.uploadID) else {
            return XCTFail("mismatched digest must fail")
        }
        XCTAssertEqual(failure.code, "now-files-integrity-failed")
        guard case .failure(let missing) =
                await store.seal(uploadID: begin.uploadID) else {
            return XCTFail("discarded stage must stay unavailable")
        }
        XCTAssertEqual(missing.code, "now-files-upload-expired")
    }

    func testCleanupFailureStaysTrackedAndIsReportedHonestly()
        async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("retain until cleanup can recover".utf8)
        let store = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            },
            removeItem: { _ in
                throw CocoaError(.fileWriteUnknown)
            })
        let begin = try value(await store.begin(
            expectedBytes: payload.count,
            expectedSHA256: sha256(payload)))
        _ = try value(await store.append(
            uploadID: begin.uploadID, offset: 0, bytes: payload))

        let cleanup = await store.finish(uploadID: begin.uploadID)

        XCTAssertEqual(cleanup, .cleanupNeeded)
        guard case .success = await store.seal(
                uploadID: begin.uploadID) else {
            return XCTFail("failed cleanup must remain recoverable")
        }
    }

    func testRecoveryRemovesOnlyPrivateDeadProcessStages() throws {
        let parent = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let orphan = parent.appendingPathComponent(
            "uploads-\(Int32.max)-\(UUID().uuidString.lowercased())",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: orphan, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let stage = orphan.appendingPathComponent("stale.upload")
        FileManager.default.createFile(
            atPath: stage.path,
            contents: Data("partial".utf8),
            attributes: [.posixPermissions: 0o600])

        let removed =
            GuestUploadStagingStore.removeOrphanedUploadDirectories(
                in: parent, uid: geteuid())

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "now-upload-test-\(UUID().uuidString)",
            isDirectory: true)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func value<T>(
        _ result: Result<T, GuestUploadStagingStore.StoreFailure>
    ) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let failure):
            XCTFail("\(failure.code): \(failure.message)")
            throw failure
        }
    }
}

@MainActor
final class GuestFileUploadCommandTests: XCTestCase {
    func testStagedUploadUsesRootPolicyAndReturnsGuestEvidence()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-command-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(root: "Lab"),
            currentSessionID: { sessionID },
            uploadStaging: staging)
        let payload = Data("hello from staged NOW upload".utf8)
        var capturedOffer: FileOffer?
        guest.onMessage = { message in
            switch message {
            case .fileOffer(let offer):
                capturedOffer = offer
                XCTAssertEqual(offer.path, "Lab:Uploads")
                XCTAssertEqual(offer.name, "Hello.txt")
                XCTAssertFalse(offer.overwrite ?? true)
                XCTAssertFalse(offer.createParents ?? true)
                try? guest.send(.fileAccept(FileAccept(
                    id: offer.id,
                    have: nil,
                    freeBytes: 8_000_000,
                    reservedBytes: payload.count,
                    staging: "same-folder-temp")))
            case .fileEnd(let end):
                try? guest.send(.fileDone(FileDone(
                    id: end.id,
                    ok: true,
                    code: nil,
                    reason: nil,
                    received: payload.count,
                    crc32: TransferIdentity.crc32(payload),
                    finalization: "same-folder-rename",
                    cleanup: "temp-renamed")))
            default:
                break
            }
        }

        let begin = await commands.beginUpload(.init(
            destinationPath: "Uploads:Hello.txt",
            bytes: payload.count,
            sha256: sha256(payload),
            container: "data",
            fileType: "TEXT",
            creator: "ttxt",
            modified: Int(UInt32.max)))
        let stage = try XCTUnwrap(begin.value)
        // Modern unsigned classic seconds do not fit the deployed guest's
        // signed parser; transfer must omit rather than saturate the date.
        _ = await commands.appendUpload(
            uploadID: stage.uploadID, offset: 0, bytes: payload)
        let committed = await commands.commitUpload(
            uploadID: stage.uploadID)
        let receipt = try XCTUnwrap(committed.value)

        XCTAssertNotNil(capturedOffer)
        XCTAssertNil(capturedOffer?.modified)
        XCTAssertEqual(committed.receipt.outcome, .success)
        XCTAssertEqual(receipt.receiverConfirmedBytes, payload.count)
        XCTAssertEqual(receipt.guestReservedBytes, payload.count)
        XCTAssertEqual(receipt.finalization, "same-folder-rename")
        XCTAssertTrue(receipt.destinationAcknowledged)
        XCTAssertEqual(guest.bulkReceived, payload)
        let replay = await commands.commitUpload(
            uploadID: stage.uploadID)
        XCTAssertEqual(replay.receipt.outcome, .conflict)
        XCTAssertEqual(
            replay.failure?.code, "now-files-upload-replayed")
    }

    func testConcurrentCommitIsRefusedBeforeASecondWireOffer()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-command-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { UUID(uuidString:
                "00000000-0000-0000-0000-000000000001")! },
            uploadStaging: staging)
        let payload = Data("one-at-a-time".utf8)
        var endID: Int?
        var offerCount = 0
        guest.onMessage = { message in
            switch message {
            case .fileOffer(let offer):
                offerCount += 1
                try? guest.send(.fileAccept(FileAccept(id: offer.id)))
            case .fileEnd(let end):
                endID = end.id
            default:
                break
            }
        }
        let beginResponse = await commands.beginUpload(.init(
            destinationPath: "Concurrent.txt",
            bytes: payload.count,
            sha256: sha256(payload),
            container: "data",
            fileType: "TEXT",
            creator: "ttxt",
            modified: nil))
        let begin = try XCTUnwrap(beginResponse.value)
        _ = await commands.appendUpload(
            uploadID: begin.uploadID, offset: 0, bytes: payload)

        let first = Task {
            await commands.commitUpload(uploadID: begin.uploadID)
        }
        try await waitUntil("first upload reached file.end") {
            endID != nil
        }
        let concurrent = await commands.commitUpload(
            uploadID: begin.uploadID)
        XCTAssertEqual(concurrent.receipt.outcome, .conflict)
        XCTAssertEqual(
            concurrent.failure?.code, "now-files-upload-conflict")
        XCTAssertEqual(offerCount, 1)

        try guest.send(.fileDone(FileDone(
            id: try XCTUnwrap(endID),
            ok: true,
            received: payload.count,
            crc32: TransferIdentity.crc32(payload),
            finalization: "same-folder-rename",
            cleanup: "temp-renamed")))
        let completed = await first.value
        XCTAssertEqual(completed.receipt.outcome, .success)
    }

    func testCommitRejectsIncompleteGuestCompletionEvidence()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-command-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        let sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID },
            uploadStaging: staging)
        let payload = Data("receipt must prove the bytes".utf8)
        guest.onMessage = { message in
            switch message {
            case .fileOffer(let offer):
                try? guest.send(.fileAccept(FileAccept(id: offer.id)))
            case .fileEnd(let end):
                try? guest.send(.fileDone(FileDone(
                    id: end.id,
                    ok: true,
                    received: payload.count,
                    crc32: nil,
                    finalization: "same-folder-rename",
                    cleanup: "temp-renamed")))
            default:
                break
            }
        }
        let begin = await commands.beginUpload(.init(
            destinationPath: "Receipt.txt",
            bytes: payload.count,
            sha256: sha256(payload),
            container: "data",
            fileType: "TEXT",
            creator: "ttxt",
            modified: nil))
        let stage = try XCTUnwrap(begin.value)
        _ = await commands.appendUpload(
            uploadID: stage.uploadID, offset: 0, bytes: payload)

        let committed = await commands.commitUpload(
            uploadID: stage.uploadID)

        XCTAssertEqual(committed.receipt.outcome, .refused)
        XCTAssertEqual(committed.failure?.code, "now-files-corrupt")
        XCTAssertNil(committed.value)
    }

    func testUnavailableGuestFailsBeforeStaging() async throws {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-command-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { nil },
            uploadStaging: staging)

        let response = await commands.beginUpload(.init(
            destinationPath: "Drops:x",
            bytes: 1,
            sha256: sha256(Data([1])),
            container: "data",
            fileType: nil,
            creator: nil,
            modified: nil))

        XCTAssertEqual(response.receipt.outcome, .unavailable)
        XCTAssertEqual(response.failure?.code, "now-guest-unavailable")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            [])
    }

    func testRootEscapeFailsBeforeStaging() async throws {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-command-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { UUID() },
            uploadStaging: staging)

        let response = await commands.beginUpload(.init(
            destinationPath: "..:escape",
            bytes: 1,
            sha256: sha256(Data([1])),
            container: "data",
            fileType: nil,
            creator: nil,
            modified: nil))

        XCTAssertEqual(response.receipt.outcome, .refused)
        XCTAssertEqual(response.failure?.code, "now-files-path-invalid")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            [])
    }

    func testSessionChangeInvalidatesAndDiscardsStagedAuthority()
        async throws {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-command-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        var sessionID = UUID()
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { sessionID },
            uploadStaging: staging)
        let payload = Data("stale".utf8)
        let begin = await commands.beginUpload(.init(
            destinationPath: "Stale.txt",
            bytes: payload.count,
            sha256: sha256(payload),
            container: "data",
            fileType: "TEXT",
            creator: "ttxt",
            modified: nil))
        let stage = try XCTUnwrap(begin.value)
        sessionID = UUID()

        let append = await commands.appendUpload(
            uploadID: stage.uploadID, offset: 0, bytes: payload)
        let replay = await commands.commitUpload(
            uploadID: stage.uploadID)

        XCTAssertEqual(append.receipt.outcome, .staleSession)
        XCTAssertEqual(append.failure?.code, "now-session-stale")
        XCTAssertEqual(replay.receipt.outcome, .expired)
    }

    func testMalformedMacBinaryIsRefusedBeforeWireUse() async throws {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-upload-command-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try GuestUploadStagingStore(
            rootURL: root,
            capacity: {
                .init(
                    availableBytes: 1_000_000,
                    policyHeadroomBytes: 10_000)
            })
        let commands = GuestFilesCommandService(
            listener: listener,
            policy: makePolicy(),
            currentSessionID: { UUID(uuidString:
                "00000000-0000-0000-0000-000000000001")! },
            uploadStaging: staging)
        let payload = Data("not a MacBinary header".utf8)
        let begin = await commands.beginUpload(.init(
            destinationPath: "Broken",
            bytes: payload.count,
            sha256: sha256(payload),
            container: "macbinary",
            fileType: nil,
            creator: nil,
            modified: nil))
        let stage = try XCTUnwrap(begin.value)
        _ = await commands.appendUpload(
            uploadID: stage.uploadID, offset: 0, bytes: payload)

        let committed = await commands.commitUpload(
            uploadID: stage.uploadID)

        XCTAssertEqual(committed.receipt.wireRequestCount, 0)
        XCTAssertEqual(
            committed.failure?.code, "now-files-container-invalid")
    }

    private func makePolicy(root: String = "") -> GuestFileAccessPolicy {
        let suite = "GuestFileUpload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(root, forKey: GuestFileAccessPolicy.rootKey)
        defaults.set(1, forKey: GuestFileAccessPolicy.versionKey)
        return GuestFileAccessPolicy(defaults: defaults)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
