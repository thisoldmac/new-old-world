import Foundation
import NOWAgentIntegration

@MainActor
extension GuestFilesCommandService {
    func agentCapabilities()
        async -> AgentIntegrationGuestFileCapabilitiesResult {
        let response = await capabilities()
        return .completed(
            receipt: response.receipt.agentValue,
            value: response.value.map(\.agentValue),
            failure: response.failure.map(\.agentValue))
    }

    func agentList(path: String, cursor: Int?)
        async -> AgentIntegrationGuestFileListResult {
        let response = await list(path: path, cursor: cursor)
        return .completed(
            receipt: response.receipt.agentValue,
            value: response.value.map(\.agentValue),
            failure: response.failure.map(\.agentValue))
    }

    func agentStat(path: String)
        async -> AgentIntegrationGuestFileStatResult {
        let response = await stat(path: path)
        return .completed(
            receipt: response.receipt.agentValue,
            value: response.value.map(\.agentValue),
            failure: response.failure.map(\.agentValue))
    }

    func agentBeginUpload(_ request: AgentIntegrationGuestFileUploadBegin)
        async -> AgentIntegrationGuestFileUploadStageResult {
        let response = await beginUpload(.init(
            destinationPath: request.destinationPath,
            bytes: request.bytes,
            sha256: request.sha256,
            container: request.container,
            fileType: request.fileType,
            creator: request.creator,
            modified: request.modified))
        return .completed(
            receipt: response.receipt.agentValue,
            value: response.value.map(\.agentValue),
            failure: response.failure.map(\.agentValue))
    }

    func agentAppendUpload(uploadID: UUID, offset: Int, bytes: Data)
        async -> AgentIntegrationGuestFileUploadStageResult {
        let response = await appendUpload(
            uploadID: uploadID, offset: offset, bytes: bytes)
        return .completed(
            receipt: response.receipt.agentValue,
            value: response.value.map(\.agentValue),
            failure: response.failure.map(\.agentValue))
    }

    func agentCommitUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        let response = await commitUpload(uploadID: uploadID)
        return .completed(
            receipt: response.receipt.agentValue,
            value: response.value.map(\.agentValue),
            failure: response.failure.map(\.agentValue))
    }
}

private extension GuestFileCommandKind {
    var agentValue: AgentIntegrationGuestFileOperation {
        switch self {
        case .capabilities: .capabilities
        case .list: .list
        case .stat: .stat
        case .download: .download
        case .readText: .readText
        case .tailText: .tailText
        case .put: .put
        case .mkdir: .mkdir
        case .move: .move
        case .delete: .delete
        case .deployTree: .deployTree
        case .prune: .prune
        }
    }
}

private extension GuestFileCommandOutcome {
    var agentValue: AgentIntegrationGuestFileOutcome {
        switch self {
        case .success: .success
        case .unavailable: .unavailable
        case .staleSession: .staleSession
        case .notFound: .notFound
        case .scanLimit: .scanLimit
        case .refused: .refused
        case .expired: .expired
        case .conflict: .conflict
        case .failed: .failed
        }
    }
}

private extension GuestFileCommandReceipt {
    var agentValue: AgentIntegrationGuestFileReceipt {
        .init(
            commandID: commandID,
            sessionID: sessionID,
            policyVersion: policyVersion,
            operation: operation.agentValue,
            startedAt: startedAt,
            completedAt: completedAt,
            outcome: outcome.agentValue,
            wireRequestCount: wireRequestCount,
            affectedPaths: affectedPaths)
    }
}

private extension GuestFileUploadStageStatus {
    var agentValue: AgentIntegrationGuestFileUploadStage {
        .init(
            uploadID: uploadID,
            destinationPath: destinationPath,
            expectedBytes: expectedBytes,
            receivedBytes: receivedBytes,
            maximumChunkBytes: maximumChunkBytes,
            expiresAt: expiresAt,
            hostAvailableBytesAtStart: hostAvailableBytesAtStart,
            hostReservedBytes: hostReservedBytes,
            sealed: sealed)
    }
}

private extension GuestFileUploadTransferReceipt {
    var agentValue: AgentIntegrationGuestFileUploadReceipt {
        .init(
            uploadID: uploadID,
            destinationPath: destinationPath,
            container: container,
            sha256: sha256,
            totalBytes: totalBytes,
            acceptedOffset: acceptedOffset,
            receiverConfirmedBytes: receiverConfirmedBytes,
            elapsedMs: elapsedMs,
            averageBytesPerSecond: averageBytesPerSecond,
            stalledState: stalledState,
            maximumProgressGapMs: maximumProgressGapMs,
            progressEvidence: progressEvidence,
            guestFreeBytesBefore: guestFreeBytesBefore,
            guestReservedBytes: guestReservedBytes,
            guestStaging: guestStaging,
            finalization: finalization,
            destinationAcknowledged: destinationAcknowledged,
            integrity: integrity,
            hostStagingCleanup: hostStagingCleanup,
            guestCleanup: guestCleanup)
    }
}

private extension GuestFileCommandFailure {
    var agentValue: AgentIntegrationGuestFileFailure {
        .init(
            code: code,
            message: message,
            transferEvidence: transferEvidence.map(\.agentValue))
    }
}

private extension GuestFileTransferFailureEvidence {
    var agentValue: AgentIntegrationGuestFileTransferFailureEvidence {
        .init(
            totalBytes: totalBytes,
            acceptedOffset: acceptedOffset,
            receiverConfirmedBytes: receiverConfirmedBytes,
            elapsedMs: elapsedMs,
            stalledState: stalledState,
            maximumProgressGapMs: maximumProgressGapMs,
            progressEvidence: progressEvidence,
            guestFreeBytesBefore: guestFreeBytesBefore,
            guestReservedBytes: guestReservedBytes,
            guestStaging: guestStaging,
            hostStagingCleanup: hostStagingCleanup,
            guestCleanup: guestCleanup)
    }
}

private extension GuestFileCapabilities {
    var agentValue: AgentIntegrationGuestFileCapabilities {
        .init(
            guestRoot: guestRoot,
            rootLabel: rootLabel,
            availableCommands: availableCommands.map(\.agentValue),
            deferredCommands: deferredCommands.map(\.agentValue),
            maximumPageEntries: maximumPageEntries,
            maximumStatPages: maximumStatPages,
            maximumPathBytes: maximumPathBytes,
            maximumSegmentBytes: maximumSegmentBytes,
            transferLaneState: transferLaneState == "busy"
                ? .busy : .unknown,
            observedAt: observedAt)
    }
}

private extension GuestFileObservedEntry {
    var agentValue: AgentIntegrationGuestFileEntry {
        .init(
            path: path,
            name: name,
            isFolder: isFolder,
            fileType: fileType,
            creator: creator,
            dataBytes: dataBytes,
            resourceBytes: resourceBytes,
            modified: modified,
            observationReference: observationReference)
    }
}

private extension GuestFileListingSnapshot {
    var agentValue: AgentIntegrationGuestFileListing {
        .init(
            path: path,
            entries: entries.map(\.agentValue),
            hasMore: hasMore,
            nextCursor: nextCursor,
            rootLabel: rootLabel,
            observedAt: observedAt)
    }
}
