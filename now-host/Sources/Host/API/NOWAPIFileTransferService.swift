import Foundation
import NOWAgentIntegration

/// Public file operations composed over NOW's existing root-scoped command
/// service and its one guest transfer lane. This layer owns only HTTP
/// resource identity and lifecycle; path authority, guest consent, wire
/// commands, receipts, integrity checks, and private staging stay with their
/// existing owners.
@MainActor
final class NOWAPIFileTransferService {
    nonisolated static let maximumFileBytes =
        GuestFilesUploadFileProjection.maximumLocalFileBytes
    nonisolated static let maximumChunkBytes =
        AgentIntegrationGuestFilePolicy.maximumUploadChunkBytes
    nonisolated static let maximumTransfers = 256

    struct Transfer: Codable, Equatable, Sendable {
        enum Direction: String, Codable, Sendable { case upload, download }
        enum State: String, Codable, Sendable {
            case staging, running, completed, failed, cancelled, expired
        }

        let id: UUID
        let guestID: String
        let guestSessionID: String
        let direction: Direction
        let guestPath: String
        var state: State
        var expectedBytes: Int?
        var transferredBytes: Int
        var expiresAt: Date?
        var failure: AgentIntegrationGuestFileFailure?
        var contentAvailable: Bool
        var contentType: String?
        var createdAt: Date
        var updatedAt: Date
        fileprivate var contentURL: URL?

        enum CodingKeys: String, CodingKey {
            case id, guestID, guestSessionID, direction, guestPath, state
            case expectedBytes, transferredBytes, expiresAt, failure
            case contentAvailable, contentType, createdAt, updatedAt
        }
    }

    struct Problem: Error, Equatable, Sendable {
        let status: Int
        let code: String
        let message: String
        let reach: String
    }

    private let driver: any NOWAPIFileDriving
    private let clock: @Sendable () -> Date
    private var transfers: [UUID: Transfer] = [:]
    /// The public operation holding the real guest bulk lane. Upload stages
    /// do not claim it; commit does. One ID across both directions mirrors
    /// the listener's actual one-lane contract.
    private var wireTransferID: UUID?

    init(driver: any NOWAPIFileDriving,
         clock: @escaping @Sendable () -> Date = Date.init) {
        self.driver = driver
        self.clock = clock
    }

    func listFiles(guestID: String, path: String, cursor: Int?) async
        throws(Problem) -> AgentIntegrationGuestFileListResult {
        _ = try addressedGuest(guestID)
        return await driver.apiListFiles(path: path, cursor: cursor)
    }

    func statFile(guestID: String, path: String) async throws(Problem)
        -> AgentIntegrationGuestFileStatResult {
        _ = try addressedGuest(guestID)
        return await driver.apiStatFile(path: path)
    }

    func mutateFile(
        guestID: String, expectedSessionID: String? = nil,
        request: AgentIntegrationGuestFileMutationRequest
    ) async throws(Problem) -> AgentIntegrationGuestFileMutationResult {
        _ = try addressedGuest(guestID, expectedSessionID: expectedSessionID)
        return await driver.apiMutateFile(request)
    }

    func beginUpload(
        guestID: String, expectedSessionID: String? = nil,
        request: AgentIntegrationGuestFileUploadBegin
    ) async throws(Problem) -> Transfer {
        let guest = try addressedGuest(
            guestID, expectedSessionID: expectedSessionID)
        guard request.bytes >= 0,
              request.bytes <= Self.maximumFileBytes else {
            throw Problem(
                status: 413, code: "transfer_too_large",
                message: "API v1 accepts one file up to 32 MiB.",
                reach: "request")
        }
        try reserveTransferSlot()
        let result = await driver.apiBeginUpload(request)
        guard case .completed(let receipt, let stage?, nil) = result,
              receipt.outcome == .success else {
            throw problem(result, fallback: "upload_not_admitted")
        }
        let now = clock()
        let transfer = Transfer(
            id: stage.uploadID, guestID: guest.id,
            guestSessionID: guest.sessionID, direction: .upload,
            guestPath: stage.destinationPath, state: .staging,
            expectedBytes: stage.expectedBytes,
            transferredBytes: stage.receivedBytes,
            expiresAt: stage.expiresAt, failure: nil,
            contentAvailable: false, contentType: nil,
            createdAt: now, updatedAt: now, contentURL: nil)
        transfers[transfer.id] = transfer
        return transfer
    }

    func appendUpload(
        transferID: UUID, offset: Int, bytes: Data
    ) async throws(Problem) -> Transfer {
        var transfer = try await uploadStage(transferID)
        try requireSameSession(transfer)
        guard !bytes.isEmpty, bytes.count <= Self.maximumChunkBytes else {
            throw Problem(
                status: 413, code: "upload_chunk_invalid",
                message: "Each upload chunk must contain 1 through \(Self.maximumChunkBytes) bytes.",
                reach: "request")
        }
        let result = await driver.apiAppendUpload(
            uploadID: transferID, offset: offset, bytes: bytes)
        guard case .completed(let receipt, let stage?, nil) = result,
              receipt.outcome == .success else {
            throw problem(result, fallback: "upload_chunk_refused")
        }
        transfer.transferredBytes = stage.receivedBytes
        transfer.expiresAt = stage.expiresAt
        transfer.updatedAt = clock()
        transfers[transferID] = transfer
        return transfer
    }

    func commitUpload(transferID: UUID) async throws(Problem) -> Transfer {
        var transfer = try await uploadStage(transferID)
        try requireSameSession(transfer)
        try claimLane(transferID)
        transfer.state = .running
        transfer.expiresAt = nil
        transfer.updatedAt = clock()
        transfers[transferID] = transfer
        let result = await driver.apiCommitUpload(uploadID: transferID)
        releaseLane(transferID)
        guard transfers[transferID]?.state != .cancelled else {
            return transfers[transferID]!
        }
        transfer.updatedAt = clock()
        switch result {
        case .completed(let receipt, let value?, nil)
            where receipt.outcome == .success:
            transfer.state = .completed
            transfer.transferredBytes = value.receiverConfirmedBytes
        case .completed(_, _, let failure):
            transfer.state = .failed
            transfer.failure = failure ?? .init(
                code: "upload_failed",
                message: "The upload did not return a complete receipt.")
        case .hostUnavailable(let unavailable):
            transfer.state = .failed
            transfer.failure = .init(
                code: unavailable.code, message: unavailable.message)
        }
        transfers[transferID] = transfer
        return transfer
    }

    func download(guestID: String, expectedSessionID: String? = nil,
                  path: String) async throws(Problem) -> Transfer {
        let guest = try addressedGuest(
            guestID, expectedSessionID: expectedSessionID)
        try reserveTransferSlot()
        let id = UUID()
        try claimLane(id)
        let now = clock()
        transfers[id] = Transfer(
            id: id, guestID: guest.id, guestSessionID: guest.sessionID,
            direction: .download, guestPath: path, state: .running,
            expectedBytes: nil, transferredBytes: 0, expiresAt: nil,
            failure: nil, contentAvailable: false, contentType: nil,
            createdAt: now, updatedAt: now, contentURL: nil)
        let result = await driver.apiDownloadFile(path: path)
        releaseLane(id)
        guard transfers[id]?.state != .cancelled else { return transfers[id]! }
        var transfer = transfers[id]!
        transfer.updatedAt = clock()
        switch result {
        case .completed(let receipt, let value?, nil)
            where receipt.outcome == .success:
            transfer.state = .completed
            transfer.expectedBytes = value.bytes
            transfer.transferredBytes = value.bytes
            transfer.contentAvailable = true
            transfer.contentType = value.container == "macbinary"
                ? "application/macbinary" : "application/octet-stream"
            guard let hostPath = value.hostPath else {
                transfer.state = .failed
                transfer.failure = .init(
                    code: "download_landing_missing",
                    message: "The completed download named no host landing.")
                transfers[id] = transfer
                return transfer
            }
            transfer.contentURL = URL(fileURLWithPath: hostPath)
        case .completed(_, _, let failure):
            transfer.state = .failed
            transfer.failure = failure ?? .init(
                code: "download_failed",
                message: "The download did not return a complete receipt.")
        case .hostUnavailable(let unavailable):
            transfer.state = .failed
            transfer.failure = .init(
                code: unavailable.code, message: unavailable.message)
        }
        transfers[id] = transfer
        return transfer
    }

    func listTransfers() async -> [Transfer] {
        await expireStages()
        refreshWireProgress()
        return transfers.values.sorted { $0.createdAt > $1.createdAt }
    }

    func transfer(id: UUID) async -> Transfer? {
        await expireStages()
        refreshWireProgress()
        return transfers[id]
    }

    func content(id: UUID) async throws(Problem) -> (URL, Int, String) {
        await expireStages()
        guard let transfer = transfers[id] else {
            throw Problem(status: 404, code: "transfer_not_found",
                          message: "No transfer has that ID.", reach: "transfer")
        }
        guard transfer.state == .completed,
              transfer.contentAvailable,
              let url = transfer.contentURL,
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let byteCount = values.fileSize else {
            throw Problem(status: 409, code: "transfer_content_unavailable",
                          message: "That transfer has no completed content.",
                          reach: "transfer")
        }
        return (url, byteCount,
                transfer.contentType ?? "application/octet-stream")
    }

    func cancel(id: UUID) async throws(Problem) -> Transfer {
        await expireStages()
        guard var transfer = transfers[id] else {
            throw Problem(status: 404, code: "transfer_not_found",
                          message: "No transfer has that ID.", reach: "transfer")
        }
        switch transfer.state {
        case .staging:
            guard await driver.apiAbandonUpload(uploadID: id) else {
                throw Problem(status: 409, code: "transfer_not_cancellable",
                              message: "The upload has already entered delivery.",
                              reach: "transfer")
            }
        case .running:
            _ = driver.apiCancelTransfer()
        case .completed, .failed, .cancelled, .expired:
            return transfer
        }
        /* Mark first. The in-flight call may settle successfully after the
           guest acknowledges cancellation; commit/download must not then
           resurrect this resource as completed. */
        transfer.state = .cancelled
        transfer.updatedAt = clock()
        transfers[id] = transfer
        return transfer
    }

    private func uploadStage(_ id: UUID) async throws(Problem) -> Transfer {
        await expireStages()
        guard let transfer = transfers[id] else {
            throw Problem(status: 404, code: "transfer_not_found",
                          message: "No transfer has that ID.", reach: "transfer")
        }
        guard transfer.direction == .upload, transfer.state == .staging else {
            throw Problem(status: 409, code: "upload_not_staging",
                          message: "That transfer is not accepting upload bytes.",
                          reach: "transfer")
        }
        return transfer
    }

    private func addressedGuest(_ id: String) throws(Problem) -> NOWAPICommandGuest {
        guard let guest = driver.apiFileGuest(id: id) else {
            throw Problem(status: 404, code: "guest_not_connected",
                          message: "That guest is not connected.", reach: "guest")
        }
        guard guest.isActive else {
            throw Problem(status: 409, code: "guest_not_addressed",
                          message: "That guest is connected but is not the guest the host is driving.",
                          reach: "guest")
        }
        if let access = guest.agentAccess,
           !HostConsentCeiling.ceiling(for: access).permits(.fullAccess) {
            throw Problem(status: 403, code: "guest_access_refused",
                          message: "The guest has not granted full control access.",
                          reach: "guest")
        }
        return guest
    }

    private func addressedGuest(
        _ id: String, expectedSessionID: String?
    ) throws(Problem) -> NOWAPICommandGuest {
        let guest = try addressedGuest(id)
        guard expectedSessionID == nil || guest.sessionID == expectedSessionID else {
            throw Problem(status: 409, code: "session_changed",
                          message: "The addressed guest session changed before dispatch.",
                          reach: "session")
        }
        return guest
    }

    private func requireSameSession(_ transfer: Transfer) throws(Problem) {
        let guest = try addressedGuest(transfer.guestID)
        guard guest.sessionID == transfer.guestSessionID else {
            throw Problem(status: 409, code: "session_changed",
                          message: "The addressed guest session changed.",
                          reach: "session")
        }
    }

    private func claimLane(_ id: UUID) throws(Problem) {
        guard wireTransferID == nil else {
            throw Problem(status: 409, code: "transfer_lane_busy",
                          message: "The guest transfer lane is already in use.",
                          reach: "transfer")
        }
        wireTransferID = id
    }

    private func releaseLane(_ id: UUID) {
        if wireTransferID == id { wireTransferID = nil }
    }

    private func reserveTransferSlot() throws(Problem) {
        if transfers.count >= Self.maximumTransfers {
            let settled = transfers.values.filter {
                $0.state == .completed || $0.state == .failed
                    || $0.state == .cancelled || $0.state == .expired
            }.sorted { $0.updatedAt < $1.updatedAt }
            for transfer in settled.prefix(
                transfers.count - Self.maximumTransfers + 1) {
                transfers.removeValue(forKey: transfer.id)
            }
        }
        guard transfers.count < Self.maximumTransfers else {
            throw Problem(
                status: 429, code: "transfer_registry_full",
                message: "Too many nonterminal transfers are retained.",
                reach: "host")
        }
    }

    private func refreshWireProgress() {
        guard let id = wireTransferID,
              var transfer = transfers[id],
              transfer.state == .running,
              let progress = driver.apiTransferProgress() else { return }
        guard transfer.transferredBytes != progress.received
                || transfer.expectedBytes != progress.expected else { return }
        transfer.transferredBytes = progress.received
        transfer.expectedBytes = progress.expected
        transfer.updatedAt = clock()
        transfers[id] = transfer
    }

    private func expireStages() async {
        let now = clock()
        let expired = transfers.values.filter {
            $0.state == .staging && ($0.expiresAt ?? .distantFuture) < now
        }.map(\.id)
        for id in expired {
            guard await driver.apiAbandonUpload(uploadID: id) else {
                continue
            }
            var transfer = transfers[id]!
            transfer.state = .expired
            transfer.updatedAt = now
            transfers[id] = transfer
        }
    }

    private func problem<Value>(
        _ result: AgentIntegrationGuestFileResult<Value>, fallback: String
    ) -> Problem {
        switch result {
        case .hostUnavailable(let unavailable):
            return .init(status: 503, code: unavailable.code,
                         message: unavailable.message, reach: "guest")
        case .completed(_, _, let failure):
            return .init(status: 409, code: failure?.code ?? fallback,
                         message: failure?.message ?? "The operation was refused.",
                         reach: "transfer")
        }
    }
}

@MainActor
protocol NOWAPIFileDriving: AnyObject {
    func apiFileGuest(id: String) -> NOWAPICommandGuest?
    func apiListFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult
    func apiStatFile(path: String) async -> AgentIntegrationGuestFileStatResult
    func apiMutateFile(_ request: AgentIntegrationGuestFileMutationRequest)
        async -> AgentIntegrationGuestFileMutationResult
    func apiDownloadFile(path: String) async
        -> AgentIntegrationGuestFileDownloadResult
    func apiBeginUpload(_ request: AgentIntegrationGuestFileUploadBegin) async
        -> AgentIntegrationGuestFileUploadStageResult
    func apiAppendUpload(uploadID: UUID, offset: Int, bytes: Data) async
        -> AgentIntegrationGuestFileUploadStageResult
    func apiCommitUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult
    func apiAbandonUpload(uploadID: UUID) async -> Bool
    func apiCancelTransfer() -> AgentIntegrationTransferCancelResult
    func apiTransferProgress() -> (received: Int, expected: Int)?
}

@MainActor
final class NOWAPIHostFileDriver: NOWAPIFileDriving {
    private let listener: GuestListener
    private let files: GuestFilesCommandService
    private let adapter: AgentIntegrationHostAdapter

    init(listener: GuestListener, files: GuestFilesCommandService,
         adapter: AgentIntegrationHostAdapter) {
        self.listener = listener
        self.files = files
        self.adapter = adapter
    }

    func apiFileGuest(id: String) -> NOWAPICommandGuest? {
        listener.apiCommandGuest(id: id)
    }
    func apiListFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        await files.agentList(path: path, cursor: cursor)
    }
    func apiStatFile(path: String) async -> AgentIntegrationGuestFileStatResult {
        await files.agentStat(path: path)
    }
    func apiMutateFile(_ request: AgentIntegrationGuestFileMutationRequest)
        async -> AgentIntegrationGuestFileMutationResult {
        await files.agentMutate(request)
    }
    func apiDownloadFile(path: String) async
        -> AgentIntegrationGuestFileDownloadResult {
        await files.agentDownload(path: path)
    }
    func apiBeginUpload(_ request: AgentIntegrationGuestFileUploadBegin) async
        -> AgentIntegrationGuestFileUploadStageResult {
        await files.agentBeginUpload(request)
    }
    func apiAppendUpload(uploadID: UUID, offset: Int, bytes: Data) async
        -> AgentIntegrationGuestFileUploadStageResult {
        await files.agentAppendUpload(uploadID: uploadID, offset: offset,
                                      bytes: bytes)
    }
    func apiCommitUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        await files.agentCommitUpload(uploadID: uploadID)
    }
    func apiAbandonUpload(uploadID: UUID) async -> Bool {
        await files.abandonUpload(uploadID: uploadID)
    }
    func apiCancelTransfer() -> AgentIntegrationTransferCancelResult {
        adapter.cancelTransfer()
    }
    func apiTransferProgress() -> (received: Int, expected: Int)? {
        listener.captureProgress.map { ($0.received, $0.expected) }
    }
}
