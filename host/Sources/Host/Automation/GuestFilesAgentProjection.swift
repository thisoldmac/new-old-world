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
            wireRequestCount: wireRequestCount)
    }
}

private extension GuestFileCommandFailure {
    var agentValue: AgentIntegrationGuestFileFailure {
        .init(code: code, message: message)
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
            modified: modified)
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
