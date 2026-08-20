import Foundation
import NOWAgentIntegration
import XCTest
@testable import Host

@MainActor
final class NOWAPIFileTransferServiceTests: XCTestCase {
    func testRejectsFileAbovePublic32MiBCeilingBeforePrivateStaging() async {
        let driver = FileDriverFixture()
        let service = NOWAPIFileTransferService(driver: driver)
        do {
            _ = try await service.beginUpload(
                guestID: "pb1400c",
                request: upload(bytes: 32 * 1024 * 1024 + 1))
            XCTFail("oversized upload was admitted")
        } catch {
            XCTAssertEqual(error.code, "transfer_too_large")
        }
        XCTAssertEqual(driver.beginCount, 0)
    }

    func testPartialUploadCannotCommitAndDigestMismatchFailsClosed() async throws {
        let driver = FileDriverFixture()
        let service = NOWAPIFileTransferService(driver: driver)
        let partial = try await service.beginUpload(
            guestID: "pb1400c", request: upload(bytes: 4))
        _ = try await service.appendUpload(
            transferID: partial.id, offset: 0, bytes: Data([1, 2]))
        driver.commitFailure = .init(
            code: "now-files-upload-incomplete",
            message: "The staged upload has not received its declared bytes")
        let partialResult = try await service.commitUpload(transferID: partial.id)
        XCTAssertEqual(partialResult.state, .failed)
        XCTAssertEqual(partialResult.failure?.code, "now-files-upload-incomplete")

        driver.commitFailure = .init(
            code: "now-files-integrity-failed",
            message: "The staged upload SHA-256 did not match")
        let digest = try await service.beginUpload(
            guestID: "pb1400c", request: upload(bytes: 1))
        _ = try await service.appendUpload(
            transferID: digest.id, offset: 0, bytes: Data([9]))
        let digestResult = try await service.commitUpload(transferID: digest.id)
        XCTAssertEqual(digestResult.state, .failed)
        XCTAssertEqual(digestResult.failure?.code, "now-files-integrity-failed")
    }

    func testStagedBytesCannotCrossIntoReplacementGuestSession() async throws {
        let driver = FileDriverFixture()
        let service = NOWAPIFileTransferService(driver: driver)
        let transfer = try await service.beginUpload(
            guestID: "pb1400c", request: upload(bytes: 1))
        driver.guest = NOWAPICommandGuest(
            id: "pb1400c", sessionID: "pb1400c-NEW",
            isActive: true, agentAccess: .fullAccess)
        do {
            _ = try await service.appendUpload(
                transferID: transfer.id, offset: 0, bytes: Data([1]))
            XCTFail("stale-session upload was accepted")
        } catch {
            XCTAssertEqual(error.code, "session_changed")
        }
        XCTAssertEqual(driver.appendCount, 0)
    }

    func testExpiredStageIsAbandonedWithoutTouchingDeliveryLane() async throws {
        let clock = FileClock(Date(timeIntervalSince1970: 100))
        let driver = FileDriverFixture()
        driver.expiry = Date(timeIntervalSince1970: 101)
        let service = NOWAPIFileTransferService(driver: driver) { clock.now }
        let transfer = try await service.beginUpload(
            guestID: "pb1400c", request: upload(bytes: 1))
        clock.now = Date(timeIntervalSince1970: 102)
        let expired = await service.transfer(id: transfer.id)
        XCTAssertEqual(expired?.state, .expired)
        XCTAssertEqual(driver.abandoned, [transfer.id])
        XCTAssertEqual(driver.cancelCount, 0)
    }

    func testOnlyOnePublicOperationCanOwnGuestTransferLane() async throws {
        let driver = FileDriverFixture()
        driver.blockCommits = true
        let service = NOWAPIFileTransferService(driver: driver)
        let first = try await service.beginUpload(
            guestID: "pb1400c", request: upload(bytes: 0))
        let second = try await service.beginUpload(
            guestID: "pb1400c", request: upload(bytes: 0))
        let running = Task { try await service.commitUpload(transferID: first.id) }
        while driver.commitContinuation == nil { await Task.yield() }
        driver.progress = (received: 3, expected: 8)
        let observed = await service.transfer(id: first.id)
        XCTAssertEqual(observed?.transferredBytes, 3)
        XCTAssertEqual(observed?.expectedBytes, 8)
        do {
            _ = try await service.commitUpload(transferID: second.id)
            XCTFail("a second transfer entered the lane")
        } catch {
            XCTAssertEqual(error.code, "transfer_lane_busy")
        }
        driver.finishBlockedCommit()
        _ = try await running.value
    }

    func testCancelRemainsCancelledWhenWireOperationSettlesSuccess() async throws {
        let driver = FileDriverFixture()
        driver.blockCommits = true
        let service = NOWAPIFileTransferService(driver: driver)
        let transfer = try await service.beginUpload(
            guestID: "pb1400c", request: upload(bytes: 0))
        let running = Task { try await service.commitUpload(transferID: transfer.id) }
        while driver.commitContinuation == nil { await Task.yield() }
        let cancelled = try await service.cancel(id: transfer.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        driver.finishBlockedCommit()
        let settled = try await running.value
        XCTAssertEqual(settled.state, .cancelled)
        XCTAssertEqual(driver.cancelCount, 1)
    }

    private func upload(bytes: Int) -> AgentIntegrationGuestFileUploadBegin {
        .init(destinationPath: "Drop Box:test.bin", bytes: bytes,
              sha256: String(repeating: "0", count: 64), container: "data")
    }
}

private final class FileClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private final class FileDriverFixture: NOWAPIFileDriving {
    var guest = NOWAPICommandGuest(
        id: "pb1400c", sessionID: "pb1400c-SESSION",
        isActive: true, agentAccess: .fullAccess)
    var expiry = Date().addingTimeInterval(600)
    var beginCount = 0
    var appendCount = 0
    var cancelCount = 0
    var progress: (received: Int, expected: Int)?
    var abandoned: [UUID] = []
    var commitFailure: AgentIntegrationGuestFileFailure?
    var blockCommits = false
    var commitContinuation:
        CheckedContinuation<AgentIntegrationGuestFileUploadCommitResult, Never>?
    var blockedCommitID: UUID?
    private var stages: [UUID: (path: String, expected: Int, received: Int)] = [:]

    func apiFileGuest(id: String) -> NOWAPICommandGuest? {
        guest.id == id ? guest : nil
    }
    func apiListFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult { .hostUnavailable(.host) }
    func apiStatFile(path: String) async
        -> AgentIntegrationGuestFileStatResult { .hostUnavailable(.host) }
    func apiMutateFile(_ request: AgentIntegrationGuestFileMutationRequest)
        async -> AgentIntegrationGuestFileMutationResult { .hostUnavailable(.host) }
    func apiDownloadFile(path: String) async
        -> AgentIntegrationGuestFileDownloadResult { .hostUnavailable(.host) }

    func apiBeginUpload(_ request: AgentIntegrationGuestFileUploadBegin) async
        -> AgentIntegrationGuestFileUploadStageResult {
        beginCount += 1
        let id = UUID()
        stages[id] = (request.destinationPath, request.bytes, 0)
        return .completed(receipt: receipt(.success), value: stage(id), failure: nil)
    }
    func apiAppendUpload(uploadID: UUID, offset: Int, bytes: Data) async
        -> AgentIntegrationGuestFileUploadStageResult {
        appendCount += 1
        guard var value = stages[uploadID], value.received == offset else {
            return failedStage("now-files-upload-offset-conflict")
        }
        value.received += bytes.count
        stages[uploadID] = value
        return .completed(receipt: receipt(.success), value: stage(uploadID),
                          failure: nil)
    }
    func apiCommitUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        if blockCommits && commitContinuation == nil {
            blockedCommitID = uploadID
            return await withCheckedContinuation { commitContinuation = $0 }
        }
        return commitResult(uploadID)
    }
    func apiAbandonUpload(uploadID: UUID) async -> Bool {
        abandoned.append(uploadID)
        return stages.removeValue(forKey: uploadID) != nil
    }
    func apiCancelTransfer() -> AgentIntegrationTransferCancelResult {
        cancelCount += 1
        return .hostUnavailable
    }
    func apiTransferProgress() -> (received: Int, expected: Int)? { progress }
    func finishBlockedCommit() {
        guard let continuation = commitContinuation,
              let id = blockedCommitID else { return }
        commitContinuation = nil
        blockedCommitID = nil
        continuation.resume(returning: commitResult(id))
    }

    private func stage(_ id: UUID) -> AgentIntegrationGuestFileUploadStage {
        let value = stages[id]!
        return .init(uploadID: id, destinationPath: value.path,
                     expectedBytes: value.expected,
                     receivedBytes: value.received,
                     maximumChunkBytes: 8192, expiresAt: expiry,
                     hostAvailableBytesAtStart: 1_000_000,
                     hostReservedBytes: value.expected, sealed: false)
    }
    private func receipt(_ outcome: AgentIntegrationGuestFileOutcome)
        -> AgentIntegrationGuestFileReceipt {
        .init(commandID: UUID(), sessionID: UUID(), policyVersion: 1,
              operation: .put, startedAt: Date(), completedAt: Date(),
              outcome: outcome, wireRequestCount: 0)
    }
    private func failedStage(_ code: String)
        -> AgentIntegrationGuestFileUploadStageResult {
        .completed(receipt: receipt(.refused), value: nil,
                   failure: .init(code: code, message: code))
    }
    private func commitResult(_ id: UUID)
        -> AgentIntegrationGuestFileUploadCommitResult {
        if let commitFailure {
            return .completed(receipt: receipt(.refused), value: nil,
                              failure: commitFailure)
        }
        let value = stages[id]!
        return .completed(
            receipt: receipt(.success),
            value: .init(
                uploadID: id, destinationPath: value.path, container: "data",
                sha256: String(repeating: "0", count: 64),
                totalBytes: value.expected,
                acceptedOffset: value.expected,
                receiverConfirmedBytes: value.expected, elapsedMs: 1,
                averageBytesPerSecond: value.expected,
                stalledState: "not-observed", maximumProgressGapMs: nil,
                progressEvidence: "completed", guestFreeBytesBefore: nil,
                guestReservedBytes: nil, guestStaging: nil,
                finalization: "complete", destinationAcknowledged: true,
                integrity: "verified", hostStagingCleanup: "removed-after-attempt",
                guestCleanup: "complete"),
            failure: nil)
    }
}
