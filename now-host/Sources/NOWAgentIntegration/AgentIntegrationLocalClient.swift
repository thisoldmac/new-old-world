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
    private let captureReceiveTimeout: TimeInterval

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
         capabilitiesReceiveTimeout: TimeInterval = 90,
         // The guest's capture watchdog is 20 s and starts before the
         // transfer does; a deep full screen off a 68030 spends seconds
         // more on the wire after that. This is that sum plus slack, not a
         // read-only window.
         captureReceiveTimeout: TimeInterval = 45) throws {
        self.endpoint = try endpoint ?? .currentUser(uid: expectedUID)
        self.expectedUID = expectedUID
        self.readOnlyReceiveTimeout = readOnlyReceiveTimeout
        self.launchReceiveTimeout = launchReceiveTimeout
        self.transferReceiveTimeout = transferReceiveTimeout
        self.capabilitiesReceiveTimeout = capabilitiesReceiveTimeout
        self.captureReceiveTimeout = captureReceiveTimeout
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

    public func requestCapture(depth: Int) async throws
        -> AgentIntegrationCaptureResult {
        try await captureResult(of: .capture(depth: depth))
    }

    public func fetchCapturePage(captureID: UUID, offset: Int) async throws
        -> AgentIntegrationCaptureResult {
        try await captureResult(
            of: .capturePage(captureID: captureID, offset: offset))
    }

    public func abandonCapture() async throws
        -> AgentIntegrationCaptureResult {
        try await captureResult(of: .captureAbandon())
    }

    private func captureResult(of request: AgentIntegrationLocalRequest)
        async throws -> AgentIntegrationCaptureResult {
        let response = try await send(request)
        guard let result = response.captureResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no capture result")
        }
        return result
    }

    /// Report one completed invocation for the host's log.
    ///
    /// It returns nothing and throws nothing a caller is expected to handle
    /// beyond the transport's own errors: the value of the call is the line
    /// in the person's log, and there is nothing to hand back to the face
    /// that already knows what it did.
    public func recordAudit(_ event: HostProjectionAuditEvent) async throws {
        let response = try await send(.audit(event))
        guard response.recorded == true else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response did not confirm the audit event")
        }
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
        case .audit:
            preconditionFailure("An audit report requires its event")
        case .capture:
            preconditionFailure(
                "A capture request says which of its three shapes it is")
        case .transferCancel:
            return try await send(.transferCancel())
        case .machineFacts:
            return try await send(.machineFacts())
        case .catalogSearch:
            return try await send(.catalogSearch())
        case .census:
            preconditionFailure("A census request names its probe")
        case .softwareInventory:
            preconditionFailure(
                "A software inventory request names its domain")
        case .guestFileDownload:
            preconditionFailure("A download requires a path")
        case .bringToFront:
            preconditionFailure(
                "Bringing a process forward requires its reference")
        case .guestFileMutation:
            preconditionFailure(
                "A file mutation says which of its four it is")
        case .guestLogTail:
            /* The one P1a operation whose every field is optional, so a
               bare operation IS a complete request: absent means the
               verb's own default of 20 lines. */
            return try await send(.guestLogTail())
        case .revealItem:
            preconditionFailure("A reveal requires a target")
        case .diagnostics:
            preconditionFailure("A diagnostics request names its probe")
        case .stream:
            preconditionFailure(
                "A stream request says which of its three intentions it is")
        }
    }

    // MARK: - The live-stream bracket

    public func startStream(depth: Int, minIntervalMs: Int) async throws
        -> AgentIntegrationStreamResult {
        try await streamResult(
            of: .streamStart(depth: depth, minIntervalMs: minIntervalMs))
    }

    public func nextStreamFrame() async throws
        -> AgentIntegrationStreamResult {
        try await streamResult(of: .streamFrame())
    }

    public func fetchStreamFramePage(frameID: UUID, offset: Int) async throws
        -> AgentIntegrationStreamResult {
        try await streamResult(
            of: .streamFramePage(frameID: frameID, offset: offset))
    }

    public func stopStream() async throws -> AgentIntegrationStreamResult {
        try await streamResult(of: .streamStop())
    }

    private func streamResult(of request: AgentIntegrationLocalRequest)
        async throws -> AgentIntegrationStreamResult {
        let response = try await send(request)
        guard let result = response.streamResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no stream result")
        }
        return result
    }

    // MARK: - P1a: the eleven verbs

    /* Typed sends for verbs nothing serves yet, so that when a capability's
       adapter lands, the round trip it needs is already here and tested.
       Each one throws `.notImplemented` today — from `send`, uniformly,
       rather than from eleven `guard let` failures reporting a missing
       result field, which is what a caller would otherwise be told about a
       host that answered perfectly honestly. */

    public func census(probe: String, cursor: Int?) async throws
        -> AgentIntegrationCensusResult {
        let response = try await send(
            .census(probe: probe, cursor: cursor))
        guard let result = response.censusResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no census result")
        }
        return result
    }

    public func softwareInventory(
        domain: AgentIntegrationSoftwareDomain,
        cursor: Int?
    ) async throws -> AgentIntegrationSoftwareInventoryResult {
        let response = try await send(
            .softwareInventory(domain: domain, cursor: cursor))
        guard let result = response.softwareInventoryResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no software inventory result")
        }
        return result
    }

    public func downloadGuestFile(path: String) async throws
        -> AgentIntegrationGuestFileDownloadResult {
        let response = try await send(.guestFileDownload(path: path))
        guard let result = response.guestFileDownloadResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no guest-file download result")
        }
        return result
    }

    public func bringToFront(reference: String) async throws
        -> AgentIntegrationFrontResult {
        let response = try await send(.bringToFront(reference: reference))
        guard let result = response.bringToFrontResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no bring-to-front result")
        }
        return result
    }

    public func moveGuestFile(path: String, toPath: String) async throws
        -> AgentIntegrationGuestFileMutationResult {
        try await mutationResult(
            of: .guestFileMove(path: path, toPath: toPath))
    }

    public func trashGuestFile(path: String) async throws
        -> AgentIntegrationGuestFileMutationResult {
        try await mutationResult(of: .guestFileTrash(path: path))
    }

    public func restoreGuestFile(trashedAs: String, toPath: String)
        async throws -> AgentIntegrationGuestFileMutationResult {
        try await mutationResult(
            of: .guestFileRestore(trashedAs: trashedAs, toPath: toPath))
    }

    public func makeGuestDirectory(path: String) async throws
        -> AgentIntegrationGuestFileMutationResult {
        try await mutationResult(
            of: .guestFileMakeDirectory(path: path))
    }

    private func mutationResult(of request: AgentIntegrationLocalRequest)
        async throws -> AgentIntegrationGuestFileMutationResult {
        let response = try await send(request)
        guard let result = response.guestFileMutationResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no guest-file mutation result")
        }
        return result
    }

    public func cancelTransfer() async throws
        -> AgentIntegrationTransferCancelResult {
        let response = try await send(.transferCancel())
        guard let result = response.transferCancelResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no transfer cancel result")
        }
        return result
    }

    public func tailGuestLog(lines: Int?) async throws
        -> AgentIntegrationGuestRowReportResult {
        let response = try await send(.guestLogTail(lines: lines))
        guard let result = response.guestLogTailResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no guest log result")
        }
        return result
    }

    public func machineFacts() async throws
        -> AgentIntegrationGuestRowReportResult {
        let response = try await send(.machineFacts())
        guard let result = response.machineFactsResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no machine facts result")
        }
        return result
    }

    public func catalogSearch() async throws
        -> AgentIntegrationGuestRowReportResult {
        let response = try await send(.catalogSearch())
        guard let result = response.catalogSearchResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no catalog search result")
        }
        return result
    }

    public func revealItem(target: String) async throws
        -> AgentIntegrationGuestRowReportResult {
        let response = try await send(.revealItem(target: target))
        guard let result = response.revealItemResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no reveal result")
        }
        return result
    }

    public func diagnostics(probe: AgentIntegrationDiagnosticProbe)
        async throws -> AgentIntegrationGuestRowReportResult {
        let response = try await send(.diagnostics(probe: probe))
        guard let result = response.diagnosticsResult else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local response had no diagnostics result")
        }
        return result
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
                 .guestFilesUploadAppend, .audit:
                /* The audit report shares the read-only window: it writes
                   one line on the main actor and reaches no guest, so a
                   longer wait would only mean holding an MCP answer back
                   for a host that has stopped answering at all. */
                timeout = readOnlyReceiveTimeout
            case .sessionCapabilities:
                timeout = capabilitiesReceiveTimeout
            case .launchSoftware, .requestQuit:
                timeout = launchReceiveTimeout
            case .transferApprovedArtifact, .guestFilesUploadCommit:
                timeout = transferReceiveTimeout
            case .capture:
                /* Only TAKING one waits on a machine — the guest's own
                   capture watchdog is 20 s and a deep screen spends real
                   time on the wire after it. A page fetch and an abandon
                   reach no guest at all, so they share the read-only
                   window; giving them the long one would hold an answer
                   back for a host that has stopped answering. */
                timeout = request.captureDepth != nil
                    ? captureReceiveTimeout : readOnlyReceiveTimeout
            case .bringToFront, .guestFileMutation,
                 .transferCancel, .guestLogTail, .machineFacts,
                 .revealItem:
                /* Bounded reads and small mutations. Each reaches the guest
                   and back inside its own watchdog: a `file.result` is one
                   reply, and a front is a couple of seconds of the guest
                   yielding. */
                timeout = readOnlyReceiveTimeout
            case .census:
                /* A census PAGE is bounded at 16 rows and the page is not
                   what costs — the PROBE is. `overview` synthesizes what
                   every other probe read, `selectors` walks the documented
                   Gestalt table, and `scsi` waits on a bus. Sixteen rows of
                   that off a 68030 is a measurement, not a bounded read, and
                   the two-second window would time out locally on a call
                   that was going to succeed. The capture window is the one
                   already sized for "the guest is busy for seconds", and it
                   outlives the host adapter's own 30 s page bound so the
                   caller reads a typed answer rather than a transport
                   error. */
                timeout = captureReceiveTimeout
            case .softwareInventory:
                /* The `apps` domain sweeps the startup volume's catalog on
                   the first page, which is the cost `catsearch` was written
                   to measure — seconds on a real disk, not a bounded read.
                   It shares the capabilities window because that window is
                   already the sum of the guest's own family watchdogs. */
                timeout = capabilitiesReceiveTimeout
            case .guestFileDownload:
                /* A real transfer over the bulk channel. */
                timeout = transferReceiveTimeout
            case .stream:
                /* Only asking for a FRAME waits on a machine, and it waits
                   the way a capture does: the host sends stream.refresh and
                   holds the answer until the guest's next whole frame
                   arrives. Opening and closing the bracket are two writes
                   and a local acknowledgement — but a page fetch cannot be
                   told apart from the frame request it continues by the
                   timeout switch's own vocabulary without reading two
                   fields, so all four share the capture window. The cost of
                   that is a page fetch against a wedged host waiting 45 s
                   rather than 2; the cost of the other way round is a frame
                   request timing out locally on a call that was going to
                   succeed, which is the mistake this switch is written to
                   avoid. */
                timeout = captureReceiveTimeout
            case .catalogSearch, .diagnostics:
                /* Both are MEASUREMENTS that run on the machine and are
                   bounded there rather than here: `catsearch` is ~20 s per
                   pass on a disk that cannot answer faster and runs two,
                   and `vprobe`/`shotdiag` each cost what a full-screen read
                   costs. The capture window is the one already sized for
                   "the guest is busy for seconds"; the read-only two would
                   time out locally on a call that was going to succeed,
                   which teaches its caller nothing. */
                timeout = captureReceiveTimeout
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
            /* Checked beside the addressing refusal and before any typed
               accessor, because it is the same kind of answer: the host
               answered honestly and there is no operation-shaped result to
               hand back. */
            if let pending = decoded.notImplemented {
                throw AgentIntegrationLocalTransportError
                    .notImplemented(pending)
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
