import Foundation

public enum AgentIntegrationLocalProtocol {
    /// Version 4 adds root-scoped guest Files observation.
    public static let version = 4
    public static let maximumMessageBytes = 16 * 1024
}

public struct AgentIntegrationLocalRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case sessionHealth = "session_health"
        case listProcesses = "list_processes"
        case launchSoftware = "launch_software"
        case requestQuit = "request_quit"
        case transferApprovedArtifact = "transfer_approved_artifact"
        case guestFilesCapabilities = "guest_files_capabilities"
        case guestFilesList = "guest_files_list"
        case guestFilesStat = "guest_files_stat"
    }

    public let version: Int
    public let requestID: UUID
    public let operation: Operation
    public let launchSelection: AgentIntegrationLaunchSelection?
    public let processReference: String?
    public let approvalReceipt: String?
    public let guestFilePath: String?
    public let guestFileCursor: Int?

    private init(requestID: UUID,
                 operation: Operation,
                 launchSelection: AgentIntegrationLaunchSelection?,
                 processReference: String?,
                 approvalReceipt: String?,
                 guestFilePath: String?,
                 guestFileCursor: Int?) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.operation = operation
        self.launchSelection = launchSelection
        self.processReference = processReference
        self.approvalReceipt = approvalReceipt
        self.guestFilePath = guestFilePath
        self.guestFileCursor = guestFileCursor
    }

    public static func sessionHealth(requestID: UUID = UUID()) -> Self {
        .init(requestID: requestID, operation: .sessionHealth,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil, guestFilePath: nil,
              guestFileCursor: nil)
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
}

public enum AgentIntegrationLocalResult: Equatable, Sendable {
    case sessionHealth(AgentIntegrationSessionHealthResult)
    case processList(AgentIntegrationProcessListResult)
    case launchSoftware(AgentIntegrationLaunchSoftwareResult)
    case requestQuit(AgentIntegrationQuitResult)
    case transferApprovedArtifact(AgentIntegrationArtifactTransferResult)
    case guestFilesCapabilities(
        AgentIntegrationGuestFileCapabilitiesResult)
    case guestFilesList(AgentIntegrationGuestFileListResult)
    case guestFilesStat(AgentIntegrationGuestFileStatResult)
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
    public let processListResult: AgentIntegrationProcessListResult?
    public let launchResult: AgentIntegrationLaunchSoftwareResult?
    public let quitResult: AgentIntegrationQuitResult?
    public let artifactTransferResult: AgentIntegrationArtifactTransferResult?
    public let guestFilesCapabilitiesResult:
        AgentIntegrationGuestFileCapabilitiesResult?
    public let guestFilesListResult: AgentIntegrationGuestFileListResult?
    public let guestFilesStatResult: AgentIntegrationGuestFileStatResult?
    public let error: AgentIntegrationLocalError?

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
            "guestFileCursor",
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
                  request.guestFileCursor == nil else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Read-only request contains an action selection")
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
                "processListResult", "launchResult", "quitResult",
                "artifactTransferResult",
                "guestFilesCapabilitiesResult", "guestFilesListResult",
                "guestFilesStatResult",
            ])
        guard object["version"] as? Int ==
                AgentIntegrationLocalProtocol.version else {
            throw AgentIntegrationLocalTransportError.invalidMessage(
                "Unsupported local protocol version")
        }
        let hasResult = object["result"] != nil
        let hasProcessList = object["processListResult"] != nil
        let hasLaunch = object["launchResult"] != nil
        let hasQuit = object["quitResult"] != nil
        let hasArtifactTransfer = object["artifactTransferResult"] != nil
        let hasGuestFilesCapabilities =
            object["guestFilesCapabilitiesResult"] != nil
        let hasGuestFilesList = object["guestFilesListResult"] != nil
        let hasGuestFilesStat = object["guestFilesStatResult"] != nil
        let hasError = object["error"] != nil
        guard [
            hasResult, hasProcessList, hasLaunch, hasQuit,
            hasArtifactTransfer, hasGuestFilesCapabilities,
            hasGuestFilesList, hasGuestFilesStat, hasError,
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
    case hostUnavailable
    case unsafeEndpoint(String)
    case invalidMessage(String)
    case messageTooLarge
    case io(String)
}
