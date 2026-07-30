import Foundation
import NOWAgentIntegration

/// The companion's one way to reach the running host: a bounded local
/// request per call over the per-uid private socket. It launches nothing and
/// keeps no state about the guest between calls.
struct SocketAgentIntegrationClient: AgentIntegrationClient {
    private var client: AgentIntegrationLocalClient?
    private let startupError: Error?

    init(endpoint: AgentIntegrationEndpoint? = nil) {
        do {
            client = try AgentIntegrationLocalClient(endpoint: endpoint)
            startupError = nil
        } catch {
            client = nil
            startupError = error
        }
    }

    func addressing(_ selector: String?) -> AgentIntegrationClient {
        var copy = self
        copy.client = client?.addressing(selector)
        return copy
    }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.sessionHealth()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.sessionCapabilities(
                probeCostly: probeCostly)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.listProcesses()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.launchSoftware(selection)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.requestQuit(reference: reference)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func bringToFront(reference: String) async
        -> AgentIntegrationFrontResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.bringToFront(reference: reference)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.transferApprovedArtifact(receipt: receipt)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.guestFilesCapabilities()
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.listGuestFiles(
                path: path, cursor: cursor)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.statGuestFile(path: path)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.beginGuestFileUpload(upload)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.appendGuestFileUpload(
                uploadID: uploadID, offset: offset, bytes: bytes)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.commitGuestFileUpload(
                uploadID: uploadID)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    /// The one place the four intentions become four local requests.
    ///
    /// The wire shapes differ per intention (P1a's `guestFileMutation`
    /// branch), the projection holds one operation, and this is the seam
    /// between them. The two `preconditionFailure`s cannot fire: only
    /// `AgentIntegrationGuestFileMutationRequest`'s failable initialisers can
    /// build one of these, and they refuse a move with no destination and a
    /// restore with no trashed name. They are stated rather than defaulted
    /// for the reason the local client's own branch states its: a substituted
    /// value here would send a Macintosh a request nobody wrote.
    func mutateGuestFile(
        _ mutation: AgentIntegrationGuestFileMutationRequest
    ) async -> AgentIntegrationGuestFileMutationResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            switch mutation.mutation {
            case .move:
                guard let toPath = mutation.destinationPath else {
                    preconditionFailure("A move names where it is going")
                }
                return try await client.moveGuestFile(
                    path: mutation.path, toPath: toPath)
            case .trash:
                return try await client.trashGuestFile(path: mutation.path)
            case .restore:
                guard let trashedAs = mutation.trashedAs else {
                    preconditionFailure(
                        "A restore names the item's name in the Trash")
                }
                return try await client.restoreGuestFile(
                    trashedAs: trashedAs, toPath: mutation.path)
            case .mkdir:
                return try await client.makeGuestDirectory(
                    path: mutation.path)
            }
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func requestGuestCapture(depth: Int?) async
        -> AgentIntegrationCaptureResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.requestCapture(
                depth: depth ?? AgentIntegrationCapturePolicy.defaultDepth)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func fetchGuestCapturePage(captureID: UUID, offset: Int) async
        -> AgentIntegrationCaptureResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.fetchCapturePage(
                captureID: captureID, offset: offset)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func abandonGuestCapture() async -> AgentIntegrationCaptureResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.abandonCapture()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    private func unavailable(for error: Error?)
        -> AgentIntegrationUnavailable {
        guard let error else { return .host }
        guard let local = error as? AgentIntegrationLocalTransportError
        else {
            return .init(
                code: "now-host-communication-failed",
                message: "New Old World host communication failed")
        }
        switch local {
        // Passed through as itself. "This host is driving another
        // machine" is a fact about ADDRESSING, and flattening it into a
        // communication failure would tell a caller to retry the one
        // thing that cannot work.
        case .notAddressed(let refusal):
            return refusal
        // Passed through for the same reason: "this host carries the verb
        // and nothing serves it yet" is a fact about the HOST's wiring, and
        // a caller told "communication failed" would retry a call that is
        // going to answer the same way every time.
        case .notImplemented(let pending):
            return pending
        case .hostUnavailable:
            return .host
        case .unsafeEndpoint:
            return .init(
                code: "now-host-endpoint-invalid",
                message: "New Old World host endpoint is not trustworthy")
        case .invalidMessage, .messageTooLarge:
            return .init(
                code: "now-host-invalid-response",
                message: "New Old World host returned an invalid response")
        case .io:
            return .init(
                code: "now-host-communication-failed",
                message: "New Old World host communication failed")
        }
    }
}
