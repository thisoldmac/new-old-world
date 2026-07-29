import Darwin
import Foundation

public struct AgentIntegrationLocalClient: Sendable {
    public let endpoint: AgentIntegrationEndpoint
    /// WHICH machine every request from this client is about. Set once
    /// with `addressing(_:)` rather than threaded through eleven method
    /// signatures, because it is orthogonal to all of them.
    public private(set) var guestSelector: String?
    private let expectedUID: uid_t
    private let readOnlyReceiveTimeout: TimeInterval
    private let launchReceiveTimeout: TimeInterval
    private let transferReceiveTimeout: TimeInterval
    private let capabilitiesReceiveTimeout: TimeInterval

    public init(endpoint: AgentIntegrationEndpoint? = nil,
                expectedUID: uid_t = geteuid()) throws {
        try self.init(
            endpoint: endpoint,
            expectedUID: expectedUID,
            readOnlyReceiveTimeout: 2,
            launchReceiveTimeout: 35,
            transferReceiveTimeout:
                AgentIntegrationArtifactPolicy.maximumTransferResponseWait)
    }

    init(endpoint: AgentIntegrationEndpoint? = nil,
         expectedUID: uid_t = geteuid(),
         readOnlyReceiveTimeout: TimeInterval,
         launchReceiveTimeout: TimeInterval,
         transferReceiveTimeout: TimeInterval =
            AgentIntegrationArtifactPolicy.maximumTransferResponseWait,
         // Read-only, but not quick: this call may wait on the guest-side
         // watchdogs of every family it probes in turn (help, then
         // process.list at 15 s, file.list at 15 s, and with probeCostly
         // software.list at 30 s). The window is their sum plus slack, not
         // the two seconds a single bounded read gets — a capability
         // report that times out locally teaches its caller nothing.
         capabilitiesReceiveTimeout: TimeInterval = 90) throws {
        self.endpoint = try endpoint ?? .currentUser(uid: expectedUID)
        self.expectedUID = expectedUID
        self.readOnlyReceiveTimeout = readOnlyReceiveTimeout
        self.launchReceiveTimeout = launchReceiveTimeout
        self.transferReceiveTimeout = transferReceiveTimeout
        self.capabilitiesReceiveTimeout = capabilitiesReceiveTimeout
    }

    public func sessionCapabilities(probeCostly: Bool) async throws
        -> AgentIntegrationSessionCapabilitiesResult {
        let response = try await send(
            .sessionCapabilities(probeCostly: probeCostly))
        guard let result = response.sessionCapabilitiesResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no session-capabilities result")
        }
        return result
    }

    public func sessionHealth() async throws
        -> AgentIntegrationSessionHealthResult {
        let response = try await send(operation: .sessionHealth)
        guard let result = response.result else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no session-health result")
        }
        return result
    }

    public func listProcesses() async throws
        -> AgentIntegrationProcessListResult {
        let response = try await send(operation: .listProcesses)
        guard let result = response.processListResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no process-list result")
        }
        return result
    }

    public func launchSoftware(_ selection: AgentIntegrationLaunchSelection)
        async throws -> AgentIntegrationLaunchSoftwareResult {
        let response = try await send(
            .launchSoftware(selection))
        guard let result = response.launchResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no software-launch result")
        }
        return result
    }

    public func requestQuit(reference: String) async throws
        -> AgentIntegrationQuitResult {
        let response = try await send(.requestQuit(reference: reference))
        guard let result = response.quitResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no cooperative-quit result")
        }
        return result
    }

    public func transferApprovedArtifact(receipt: String) async throws
        -> AgentIntegrationArtifactTransferResult {
        let response = try await send(
            .transferApprovedArtifact(receipt: receipt))
        guard let result = response.artifactTransferResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no artifact-transfer result")
        }
        return result
    }

    public func guestFilesCapabilities() async throws
        -> AgentIntegrationGuestFileCapabilitiesResult {
        let response = try await send(operation: .guestFilesCapabilities)
        guard let result = response.guestFilesCapabilitiesResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no guest-files capabilities result")
        }
        return result
    }

    public func listGuestFiles(path: String, cursor: Int?) async throws
        -> AgentIntegrationGuestFileListResult {
        let response = try await send(
            .guestFilesList(path: path, cursor: cursor))
        guard let result = response.guestFilesListResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no guest-files list result")
        }
        return result
    }

    public func statGuestFile(path: String) async throws
        -> AgentIntegrationGuestFileStatResult {
        let response = try await send(.guestFilesStat(path: path))
        guard let result = response.guestFilesStatResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no guest-files stat result")
        }
        return result
    }

    public func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async throws -> AgentIntegrationGuestFileUploadStageResult {
        let response = try await send(.guestFilesUploadBegin(upload))
        guard let result = response.guestFilesUploadStageResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no upload-stage result")
        }
        return result
    }

    public func appendGuestFileUpload(
        uploadID: UUID,
        offset: Int,
        bytes: Data
    ) async throws -> AgentIntegrationGuestFileUploadStageResult {
        let response = try await send(.guestFilesUploadAppend(
            uploadID: uploadID,
            offset: offset,
            base64: bytes.base64EncodedString()))
        guard let result = response.guestFilesUploadStageResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no upload-stage result")
        }
        return result
    }

    public func commitGuestFileUpload(uploadID: UUID) async throws
        -> AgentIntegrationGuestFileUploadCommitResult {
        let response = try await send(
            .guestFilesUploadCommit(uploadID: uploadID))
        guard let result = response.guestFilesUploadCommitResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no upload-commit result")
        }
        return result
    }

    func sendRaw(_ request: Data) async throws -> Data {
        try await Task.detached {
            try sendRaw(
                request, receiveTimeoutSeconds: readOnlyReceiveTimeout)
        }.value
    }

    private func send(operation: AgentIntegrationLocalRequest.Operation)
        async throws -> AgentIntegrationLocalResponse {
        switch operation {
        case .sessionHealth:
            return try await send(.sessionHealth())
        case .listProcesses:
            return try await send(.processList())
        case .guestFilesCapabilities:
            return try await send(.guestFilesCapabilities())
        case .sessionCapabilities:
            preconditionFailure(
                "Session capabilities requires an explicit probe choice")
        case .launchSoftware:
            preconditionFailure("Launch requests require a selection")
        case .requestQuit:
            preconditionFailure("Quit requests require a process reference")
        case .transferApprovedArtifact:
            preconditionFailure(
                "Artifact transfers require an approval receipt")
        case .guestFilesList:
            preconditionFailure("Guest Files list requires a path")
        case .guestFilesStat:
            preconditionFailure("Guest Files stat requires a path")
        case .guestFilesUploadBegin, .guestFilesUploadAppend,
             .guestFilesUploadCommit:
            preconditionFailure("Guest Files upload requires typed input")
        }
    }

    /// A copy of this client that says which machine it is asking about.
    ///
    /// A machine id (`pb1400c`) means "whatever is connected to that Mac
    /// now" and follows a reconnection; a session id (`pb1400c-<uuid>`)
    /// means this connection and nothing else, and stops being valid the
    /// moment it ends — the same contract the process and quit references
    /// on this surface already keep.
    public func addressing(_ selector: String?)
        -> AgentIntegrationLocalClient {
        var copy = self
        copy.guestSelector = selector
        return copy
    }

    private func send(_ request: AgentIntegrationLocalRequest) async throws
        -> AgentIntegrationLocalResponse {
        var request = request
        request.guestSelector = guestSelector
        return try await Task.detached {
            let timeout: TimeInterval
            switch request.operation {
            case .sessionHealth, .listProcesses,
                 .guestFilesCapabilities, .guestFilesList,
                 .guestFilesStat, .guestFilesUploadBegin,
                 .guestFilesUploadAppend:
                timeout = readOnlyReceiveTimeout
            case .sessionCapabilities:
                timeout = capabilitiesReceiveTimeout
            case .launchSoftware, .requestQuit:
                timeout = launchReceiveTimeout
            case .transferApprovedArtifact, .guestFilesUploadCommit:
                timeout = transferReceiveTimeout
            }
            let response = try sendRaw(
                AgentIntegrationLocalCodec.encode(request),
                receiveTimeoutSeconds: timeout)
            let decoded = try AgentIntegrationLocalCodec.decodeResponse(
                response)
            guard decoded.requestID == request.requestID else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Local response request ID did not match")
            }
            if let refusal = decoded.notAddressed {
                throw AgentIntegrationLocalTransportError
                    .notAddressed(refusal)
            }
            if let error = decoded.error {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "\(error.code): \(error.message)")
            }
            return decoded
        }.value
    }

    private func sendRaw(_ request: Data,
                         receiveTimeoutSeconds: TimeInterval) throws -> Data {
        try AgentIntegrationUnixSocket.validateDirectory(
            endpoint.directoryURL, uid: expectedUID)
        try AgentIntegrationUnixSocket.validateSocket(
            endpoint.socketURL, uid: expectedUID)
        let descriptor = try AgentIntegrationUnixSocket.makeSocket()
        defer { close(descriptor) }
        AgentIntegrationUnixSocket.setTimeouts(
            descriptor, seconds: receiveTimeoutSeconds)
        try AgentIntegrationUnixSocket.withAddress(
            path: endpoint.socketURL.path) { address, length in
            if connect(descriptor, address, length) != 0 {
                if errno == ENOENT || errno == ECONNREFUSED {
                    throw AgentIntegrationLocalTransportError
                        .hostUnavailable
                }
                throw AgentIntegrationUnixSocket.ioError("connect")
            }
        }
        try AgentIntegrationUnixSocket.writeLine(request, to: descriptor)
        _ = shutdown(descriptor, SHUT_WR)
        return try AgentIntegrationUnixSocket.readLine(from: descriptor)
    }
}
