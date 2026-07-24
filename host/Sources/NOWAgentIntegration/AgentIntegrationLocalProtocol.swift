import Foundation

public enum AgentIntegrationLocalProtocol {
    /// Version 3 adds redemption of host-minted artifact approvals.
    public static let version = 3
    public static let maximumMessageBytes = 16 * 1024
}

public struct AgentIntegrationLocalRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case sessionHealth = "session_health"
        case listProcesses = "list_processes"
        case launchSoftware = "launch_software"
        case requestQuit = "request_quit"
        case transferApprovedArtifact = "transfer_approved_artifact"
    }

    public let version: Int
    public let requestID: UUID
    public let operation: Operation
    public let launchSelection: AgentIntegrationLaunchSelection?
    public let processReference: String?
    public let approvalReceipt: String?

    private init(requestID: UUID,
                 operation: Operation,
                 launchSelection: AgentIntegrationLaunchSelection?,
                 processReference: String?,
                 approvalReceipt: String?) {
        version = AgentIntegrationLocalProtocol.version
        self.requestID = requestID
        self.operation = operation
        self.launchSelection = launchSelection
        self.processReference = processReference
        self.approvalReceipt = approvalReceipt
    }

    public static func sessionHealth(requestID: UUID = UUID()) -> Self {
        .init(requestID: requestID, operation: .sessionHealth,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil)
    }

    public static func processList(requestID: UUID = UUID()) -> Self {
        .init(requestID: requestID, operation: .listProcesses,
              launchSelection: nil, processReference: nil,
              approvalReceipt: nil)
    }

    public static func launchSoftware(
        _ selection: AgentIntegrationLaunchSelection,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .launchSoftware,
              launchSelection: selection, processReference: nil,
              approvalReceipt: nil)
    }

    public static func requestQuit(
        reference: String,
        requestID: UUID = UUID()
    ) -> Self {
        .init(requestID: requestID, operation: .requestQuit,
              launchSelection: nil, processReference: reference,
              approvalReceipt: nil)
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
            approvalReceipt: receipt)
    }
}

public enum AgentIntegrationLocalResult: Equatable, Sendable {
    case sessionHealth(AgentIntegrationSessionHealthResult)
    case processList(AgentIntegrationProcessListResult)
    case launchSoftware(AgentIntegrationLaunchSoftwareResult)
    case requestQuit(AgentIntegrationQuitResult)
    case transferApprovedArtifact(AgentIntegrationArtifactTransferResult)
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
            "processReference", "approvalReceipt",
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
        case .sessionHealth, .listProcesses:
            expectedKeys = ["version", "requestID", "operation"]
            guard request.launchSelection == nil,
                  request.processReference == nil,
                  request.approvalReceipt == nil else {
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
                  AgentIntegrationArtifactPolicy.isValidReceipt(receipt)
            else {
                throw AgentIntegrationLocalTransportError.invalidMessage(
                    "Artifact transfer receipt does not match the schema")
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
        let hasError = object["error"] != nil
        guard [
            hasResult, hasProcessList, hasLaunch, hasQuit,
            hasArtifactTransfer, hasError,
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
