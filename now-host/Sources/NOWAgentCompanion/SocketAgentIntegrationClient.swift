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
