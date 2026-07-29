import Foundation

public enum AgentIntegrationLocalProtocol {
    /// Version 8 makes an agent call VISIBLE to the person at the machine.
    /// The shape changed because the surface gained an operation that asks
    /// the host for nothing: the companion reports what it was asked to do
    /// and what came of it, and the host writes that into its own log. A v7
    /// host answers `invalid-request` to it, which is the honest answer —
    /// that host has no audit line to write — and a v7 companion simply
    /// never sends one, which is what rule 3 of the parity slice exists to
    /// stop being acceptable.
    ///
    /// Version 7 made the surface guest-ADDRESSABLE. The version moves
    /// because the shape changed again: the host serves several machines
    /// at once, so a request may now say WHICH one it means and every
    /// guest-dependent answer names the machine it came from. A v6
    /// companion cannot say which machine it wants and would take
    /// whichever one happened to be active as the answer to a question it
    /// asked about another.
    ///
    /// Version 6 added the read-only session capability report.
    public static let version = 8
    public static let maximumMessageBytes = 16 * 1024
}

public struct AgentIntegrationLocalRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case sessionHealth = "session_health"
        case sessionCapabilities = "session_capabilities"
        case listProcesses = "list_processes"
        case launchSoftware = "launch_software"
        case requestQuit = "request_quit"
        case transferApprovedArtifact = "transfer_approved_artifact"
        case guestFilesCapabilities = "guest_files_capabilities"
        case guestFilesList = "guest_files_list"
        case guestFilesStat = "guest_files_stat"
        case guestFilesUploadBegin = "guest_files_upload_begin"
        case guestFilesUploadAppend = "guest_files_upload_append"
        case guestFilesUploadCommit = "guest_files_upload_commit"
        /// Not a request for anything. The face reports one invocation it
        /// has already performed so the host can write it into the log the
        /// person at the machine reads.
        case audit = "audit"
    }

    public let version: Int
    public let requestID: UUID
    public let operation: Operation
    public let launchSelection: AgentIntegrationLaunchSelection?
    public let processReference: String?
    public let approvalReceipt: String?
    public let guestFilePath: String?
    public let guestFileCursor: Int?
    public let guestFileUpload: AgentIntegrationGuestFileUploadBegin?
    public let guestFileUploadID: UUID?
    public let guestFileUploadOffset: Int?
    public let guestFileUploadChunk: String?
    /// Opt in to the one read-only probe that costs the guest real work.
    public let probeCostly: Bool?
    /// One completed invocation, reported for the log. Present only on the
    /// `audit` operation, and never a request for anything.
    public var auditEvent: HostProjectionAuditEvent? = nil
    /// WHICH machine this request is about, if the caller cares.
    ///
    /// Accepts a machine id (`pb1400c` — "whatever is connected to that
    /// Mac now", which follows a reconnection) or a session id
    /// (`pb1400c-<uuid>` — precise, and fails once that connection ends
    /// rather than being retargeted at its successor). Nil means "the
    /// machine this host is driving", which is what every v6 caller
    /// meant and what a single-Mac desk still means.
    ///
    /// A `var` with a default rather than another parameter on eleven
    /// factory methods: it is orthogonal to every one of them.
    public var guestSelector: String?

    private init(requestID: UUID,
                 operation: Operation,
                 launchSelection: AgentIntegrationLaunchSelection?,
                 processReference: String?,
                 approvalReceipt: String?,
                 guestFilePath: String?,
                 guestFileCursor: Int?,
                 guestFileUpload:
                    AgentIntegrationGuestFileUploadBegin? = nil,
                 guestFileUploadID: UUID? = nil,
                 guestFileUploadOffset: Int? = nil,
                 guestFileUploadChunk: String? = nil,
                 probeCostly: Bool? = nil) {
        version = AgentIntegrationLocalProtocol.version
        self.probeCostly = probeCostly
        self.requestID = requestID
        self.operation = operation
        self.launchSelection = launchSelection
        self.processReference = processReference
        self.approvalReceipt = approvalReceipt
        self.guestFilePath = guestFilePath
        self.guestFileCursor = guestFileCursor
        self.guestFileUpload = guestFileUpload
        self.guestFileUploadID = guestFileUploadID
        self.guestFileUploadOffset = guestFileUploadOffset
        self.guestFileUploadChunk = guestFileUploadChunk
    }

    public static func sessionHealth(requestID: UUID = UUID()) -> Self {
        .init(requestID: requestID, operation: .sessionHealth,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func sessionCapabilities(
        probeCostly: Bool,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .sessionCapabilities,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil, probeCostly: probeCostly)
    }

    public static func processList(requestID: UUID = UUID()) -> Self {
        .init(requestID: requestID, operation: .listProcesses,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func launchSoftware(
        _ selection: AgentIntegrationLaunchSelection,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .launchSoftware,
              launchSelection: selection, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func requestQuit(
        reference: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .requestQuit,
              launchSelection: nil, processReference: reference,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
    }

    public static func transferApprovedArtifact(
        receipt: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .transferApprovedArtifact,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: receipt,
            guestFilePath: nil,
            guestFileCursor: nil)
    }

    public static func guestFilesCapabilities(
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesCapabilities,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil)
    }

    public static func guestFilesList(
        path: String,
        cursor: Int?,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesList,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: path,
            guestFileCursor: cursor)
    }

    public static func guestFilesStat(
        path: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesStat,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: path,
            guestFileCursor: nil)
    }

    public static func guestFilesUploadBegin(
        _ upload: AgentIntegrationGuestFileUploadBegin,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesUploadBegin,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil,
            guestFileUpload: upload)
    }

    public static func guestFilesUploadAppend(
        uploadID: UUID,
        offset: Int,
        base64: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesUploadAppend,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil,
            guestFileUploadID: uploadID,
            guestFileUploadOffset: offset,
            guestFileUploadChunk: base64)
    }

    public static func guestFilesUploadCommit(
        uploadID: UUID,
        requestID: UUID = UUID()
    ) -> Self {
        .init(
            requestID: requestID,
            operation: .guestFilesUploadCommit,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil,
            guestFileUploadID: uploadID)
    }

    /// One completed invocation, on its way to the host's log.
    ///
    /// It carries no selection of any kind: the event names a capability the
    /// host validates against its own registry, a face from a closed set,
    /// one outcome word and a bounded refusal sentence. That bound is what
    /// keeps this from being a way to write arbitrary text into the person's
    /// log — a same-uid process can already cause real agent lines by
    /// making real calls, and this operation must not let it invent lines
    /// about capabilities that do not exist.
    public static func audit(_ event: HostProjectionAuditEvent,
                             requestID: UUID = UUID()) -> Self {
        var request = Self(
            requestID: requestID,
            operation: .audit,
            launchSelection: nil,
            processReference: nil,
            approvalReceipt: nil,
            guestFilePath: nil,
            guestFileCursor: nil)
        request.auditEvent = event
        return request
    }
}

public enum AgentIntegrationLocalResult: Equatable, Sendable {
    case sessionHealth(AgentIntegrationSessionHealthResult)
    case sessionCapabilities(AgentIntegrationSessionCapabilitiesResult)
    case processList(AgentIntegrationProcessListResult)
    case launchSoftware(AgentIntegrationLaunchSoftwareResult)
    case requestQuit(AgentIntegrationQuitResult)
    case transferApprovedArtifact(AgentIntegrationArtifactTransferResult)
    case guestFilesCapabilities(
        AgentIntegrationGuestFileCapabilitiesResult)
    case guestFilesList(AgentIntegrationGuestFileListResult)
    case guestFilesStat(AgentIntegrationGuestFileStatResult)
    case guestFilesUploadStage(
        AgentIntegrationGuestFileUploadStageResult)
    case guestFilesUploadCommit(
        AgentIntegrationGuestFileUploadCommitResult)
    /// The request named a machine, and this host cannot answer for it.
    ///
    /// One case rather than a variant of each of the eleven results,
    /// because the reason is the same for all of them and belongs to the
    /// ADDRESSING, not to the operation: nothing about the guest was
    /// asked, so no operation-shaped answer would be honest.
    case notAddressed(AgentIntegrationUnavailable)
    /// The reported invocation reached the host's log. It says only that,
    /// because that is all the caller can be told: the line is written where
    /// the person reads it, not returned to whoever reported it.
    case recorded
}

public struct AgentIntegrationLocalError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AgentIntegrationLocalResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID?
    public let result: AgentIntegrationSessionHealthResult?
    public var sessionCapabilitiesResult:
        AgentIntegrationSessionCapabilitiesResult? = nil
    public let processListResult: AgentIntegrationProcessListResult?
    public let launchResult: AgentIntegrationLaunchSoftwareResult?
    public let quitResult: AgentIntegrationQuitResult?
    public let artifactTransferResult: AgentIntegrationArtifactTransferResult?
    public let guestFilesCapabilitiesResult:
        AgentIntegrationGuestFileCapabilitiesResult?
    public let guestFilesListResult: AgentIntegrationGuestFileListResult?
    public let guestFilesStatResult: AgentIntegrationGuestFileStatResult?
    public var guestFilesUploadStageResult:
        AgentIntegrationGuestFileUploadStageResult? = nil
    public var guestFilesUploadCommitResult:
        AgentIntegrationGuestFileUploadCommitResult? = nil
    /// The request named a machine this host cannot answer for. Set
    /// INSTEAD of any operation result: nothing was asked of any guest.
    public var notAddressed: AgentIntegrationUnavailable? = nil
    /// The reported invocation was written to the host's log. Set INSTEAD of
    /// any operation result; nothing was asked of any guest.
    public var recorded: Bool? = nil
    public let error: AgentIntegrationLocalError?

    public init(requestID: UUID,
                notAddressed: AgentIntegrationUnavailable) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.notAddressed = notAddressed
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID, recorded: Bool) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.recorded = recorded
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                result: AgentIntegrationSessionHealthResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.result = result
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        sessionCapabilitiesResult:
            AgentIntegrationSessionCapabilitiesResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        self.sessionCapabilitiesResult = sessionCapabilitiesResult
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                processListResult: AgentIntegrationProcessListResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        self.processListResult = processListResult
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                launchResult: AgentIntegrationLaunchSoftwareResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        self.launchResult = launchResult
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(requestID: UUID,
                quitResult: AgentIntegrationQuitResult) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        self.quitResult = quitResult
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        artifactTransferResult: AgentIntegrationArtifactTransferResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        self.artifactTransferResult = artifactTransferResult
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesCapabilitiesResult:
            AgentIntegrationGuestFileCapabilitiesResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        self.guestFilesCapabilitiesResult =
            guestFilesCapabilitiesResult
        guestFilesListResult = nil
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesListResult: AgentIntegrationGuestFileListResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        self.guestFilesListResult = guestFilesListResult
        guestFilesStatResult = nil
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesStatResult: AgentIntegrationGuestFileStatResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        self.guestFilesStatResult = guestFilesStatResult
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesUploadStageResult:
            AgentIntegrationGuestFileUploadStageResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        self.guestFilesUploadStageResult =
            guestFilesUploadStageResult
        error = nil
    }

    public init(
        requestID: UUID,
        guestFilesUploadCommitResult:
            AgentIntegrationGuestFileUploadCommitResult
    ) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        self.guestFilesUploadCommitResult =
            guestFilesUploadCommitResult
        error = nil
    }

    public init(requestID: UUID? = nil,
                error: AgentIntegrationLocalError) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        result = nil
        processListResult = nil
        launchResult = nil
        quitResult = nil
        artifactTransferResult = nil
        guestFilesCapabilitiesResult = nil
        guestFilesListResult = nil
        guestFilesStatResult = nil
        self.error = error
    }
}

public enum AgentIntegrationLocalCodec {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ request: AgentIntegrationLocalRequest)
        throws -> Data {
        try bounded(makeEncoder().encode(request))
    }

    public static func encode(_ response: AgentIntegrationLocalResponse)
        throws -> Data {
        try bounded(makeEncoder().encode(response))
    }

    public static func decodeRequest(_ data: Data) throws
        -> AgentIntegrationLocalRequest {
        let object = try strictObject(data, allowedKeys: [
            "version", "requestID", "operation", "launchSelection",
            "processReference", "approvalReceipt", "guestFilePath",
            "guestFileCursor", "guestFileUpload", "guestFileUploadID",
            "guestFileUploadOffset", "guestFileUploadChunk", "probeCostly",
            "auditEvent",
        ])
        guard object["version"] as? Int ==
                AgentIntegrationLocalProtocol.version else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Unsupported local protocol version")
        }
        let request = try makeDecoder().decode(
            AgentIntegrationLocalRequest.self, from: bounded(data))
        let expectedKeys: Set<String>
        switch request.operation {
        case .sessionHealth, .listProcesses, .guestFilesCapabilities:
            expectedKeys = ["version", "requestID", "operation"]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.probeCostly == nil,
                  request.guestFileCursor == nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Read-only request contains an action selection")
            }
        case .sessionCapabilities:
            // The one flag is REQUIRED rather than defaulted, because it
            // decides whether this call spends four seconds of a
            // PowerBook's volume sweep. A caller says so on purpose.
            expectedKeys = [
                "version", "requestID", "operation", "probeCostly",
            ]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.probeCostly != nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Session capabilities request does not match the schema")
            }
        case .launchSoftware:
            expectedKeys = [
                "version", "requestID", "operation", "launchSelection",
            ]
            guard request.launchSelection != nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  let rawSelection =
                    object["launchSelection"] as? [String: Any],
                  Set(rawSelection.keys) == ["name"]
                    || Set(rawSelection.keys) == ["reference"] else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Launch request selection does not match the schema")
            }
        case .requestQuit:
            expectedKeys = [
                "version", "requestID", "operation", "processReference",
            ]
            guard request.launchSelection == nil,
                  let reference = request.processReference,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  AgentIntegrationQuitPolicy.isValidReference(reference)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Quit request reference does not match the schema")
            }
        case .transferApprovedArtifact:
            expectedKeys = [
                "version", "requestID", "operation", "approvalReceipt",
            ]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  let receipt = request.approvalReceipt,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  AgentIntegrationArtifactPolicy.isValidReceipt(receipt)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Artifact transfer receipt does not match the schema")
            }
        case .guestFilesList:
            var listKeys: Set<String> = [
                "version", "requestID", "operation", "guestFilePath",
            ]
            if request.guestFileCursor != nil {
                listKeys.insert("guestFileCursor")
            }
            expectedKeys = listKeys
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  let path = request.guestFilePath,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(path),
                  request.guestFileCursor.map({ $0 >= 1 }) ?? true
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files list request does not match the schema")
            }
        case .guestFilesStat:
            expectedKeys = [
                "version", "requestID", "operation", "guestFilePath",
            ]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFileCursor == nil,
                  let path = request.guestFilePath,
                  !path.isEmpty,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(path)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files stat request does not match the schema")
            }
        case .guestFilesUploadBegin:
            expectedKeys = [
                "version", "requestID", "operation", "guestFileUpload",
            ]
            guard let upload = request.guestFileUpload,
                  request.guestFileUploadID == nil,
                  request.guestFileUploadOffset == nil,
                  request.guestFileUploadChunk == nil,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(
                    upload.destinationPath),
                  !upload.destinationPath.isEmpty,
                  upload.bytes >= 0,
                  upload.bytes <= Int(Int32.max),
                  AgentIntegrationGuestFilePolicy.isCanonicalSHA256(
                    upload.sha256),
                  AgentIntegrationGuestFilePolicy.isClassicOSType(
                    upload.fileType),
                  AgentIntegrationGuestFilePolicy.isClassicOSType(
                    upload.creator),
                  upload.modified.map({ $0 >= 0 }) ?? true,
                  upload.container == "data"
                    || upload.container == "macbinary",
                  let raw = object["guestFileUpload"] as? [String: Any],
                  Set(raw.keys).isSuperset(of: [
                    "destinationPath", "bytes", "sha256", "container",
                  ]),
                  Set(raw.keys).isSubset(of: [
                    "destinationPath", "bytes", "sha256", "container",
                    "fileType", "creator", "modified",
                  ]) else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files upload begin does not match the schema")
            }
        case .guestFilesUploadAppend:
            expectedKeys = [
                "version", "requestID", "operation", "guestFileUploadID",
                "guestFileUploadOffset", "guestFileUploadChunk",
            ]
            guard request.guestFileUpload == nil,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.guestFileUploadID != nil,
                  let offset = request.guestFileUploadOffset,
                  offset >= 0,
                  let chunk = request.guestFileUploadChunk,
                  chunk.count
                    <= AgentIntegrationGuestFilePolicy
                        .maximumUploadChunkBase64Scalars,
                  let bytes = Data(base64Encoded: chunk),
                  !bytes.isEmpty,
                  bytes.count
                    <= AgentIntegrationGuestFilePolicy
                        .maximumUploadChunkBytes else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files upload chunk does not match the schema")
            }
        case .guestFilesUploadCommit:
            expectedKeys = [
                "version", "requestID", "operation", "guestFileUploadID",
            ]
            guard request.guestFileUpload == nil,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.guestFileUploadID != nil,
                  request.guestFileUploadOffset == nil,
                  request.guestFileUploadChunk == nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Guest Files upload commit does not match the schema")
            }
        case .audit:
            /* An audit event names a capability, so the capability has to
               exist: the host writes this into the log a person reads, and
               a line about a tool no row claims would be a line about
               nothing. Everything else in the event is a closed enum or a
               bounded sentence, which together are the whole bound on what
               this operation can put in that file. Note there is no guest
               SELECTOR here — the machine the call concerned travels inside
               the event, because nothing is being asked of any guest. */
            expectedKeys = [
                "version", "requestID", "operation", "auditEvent",
            ]
            guard let event = request.auditEvent,
                  request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil,
                  request.guestFilePath == nil,
                  request.guestFileCursor == nil,
                  request.probeCostly == nil,
                  HostProjectionRegistry.hostFaces.projection(
                      named: event.capability) != nil,
                  (event.reason?.unicodeScalars.count ?? 0)
                      <= HostProjectionAuditEvent.maximumReasonScalars else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Audit event does not match the schema")
            }
        }
        guard Set(object.keys) == expectedKeys else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local request fields do not match the operation schema")
        }
        return request
    }

    public static func decodeResponse(_ data: Data) throws
        -> AgentIntegrationLocalResponse {
        let object = try strictObject(
            data,
            allowedKeys: [
                "version", "requestID", "result", "error",
                "sessionCapabilitiesResult",
                "processListResult", "launchResult", "quitResult",
                "artifactTransferResult",
                "guestFilesCapabilitiesResult", "guestFilesListResult",
                "guestFilesStatResult", "guestFilesUploadStageResult",
                "guestFilesUploadCommitResult", "recorded",
            ])
        guard object["version"] as? Int ==
                AgentIntegrationLocalProtocol.version else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Unsupported local protocol version")
        }
        let hasResult = object["result"] != nil
        let hasSessionCapabilities =
            object["sessionCapabilitiesResult"] != nil
        let hasProcessList = object["processListResult"] != nil
        let hasLaunch = object["launchResult"] != nil
        let hasQuit = object["quitResult"] != nil
        let hasArtifactTransfer = object["artifactTransferResult"] != nil
        let hasGuestFilesCapabilities =
            object["guestFilesCapabilitiesResult"] != nil
        let hasGuestFilesList = object["guestFilesListResult"] != nil
        let hasGuestFilesStat = object["guestFilesStatResult"] != nil
        let hasGuestFilesUploadStage =
            object["guestFilesUploadStageResult"] != nil
        let hasGuestFilesUploadCommit =
            object["guestFilesUploadCommitResult"] != nil
        let hasRecorded = object["recorded"] != nil
        let hasError = object["error"] != nil
        guard [
            hasResult, hasSessionCapabilities,
            hasProcessList, hasLaunch, hasQuit,
            hasArtifactTransfer, hasGuestFilesCapabilities,
            hasGuestFilesList, hasGuestFilesStat,
            hasGuestFilesUploadStage, hasGuestFilesUploadCommit,
            hasRecorded, hasError,
        ]
                .filter({ $0 }).count == 1 else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Response must contain exactly one result or error")
        }
        return try makeDecoder().decode(
            AgentIntegrationLocalResponse.self, from: bounded(data))
    }

    private static func strictObject(_ data: Data, keys: Set<String>)
        throws -> [String: Any] {
        let object = try strictObject(data, allowedKeys: keys)
        guard Set(object.keys) == keys else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local request fields do not match the schema")
        }
        return object
    }

    private static func strictObject(_ data: Data,
                                     allowedKeys: Set<String>)
        throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: bounded(data), options: [])
        } catch {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local message is not valid JSON")
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: allowedKeys) else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Local message does not match the schema")
        }
        return dictionary
    }

    private static func bounded(_ data: Data) throws -> Data {
        guard data.count <= AgentIntegrationLocalProtocol.maximumMessageBytes
        else {
            throw AgentIntegrationLocalTransportError.messageTooLarge
        }
        return data
    }
}

public enum AgentIntegrationLocalTransportError: Error, Equatable {
    /// The host would not answer for the machine this request named.
    /// Carried out of the transport as itself, so the caller can report
    /// which machine and which one is being driven rather than "invalid
    /// response".
    case notAddressed(AgentIntegrationUnavailable)
    case hostUnavailable
    case unsafeEndpoint(String)
    case invalidMessage(String)
    case messageTooLarge
    case io(String)
}
