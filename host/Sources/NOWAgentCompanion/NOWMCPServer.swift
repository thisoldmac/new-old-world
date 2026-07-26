import CoreFoundation
import Foundation
import NOWAgentIntegration

protocol AgentIntegrationClient: Sendable {
    func sessionHealth() async -> AgentIntegrationSessionHealthResult
    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult
    func listProcesses() async -> AgentIntegrationProcessListResult
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult
    func requestQuit(reference: String) async -> AgentIntegrationQuitResult
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult
    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult
    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult
    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult
}

extension AgentIntegrationClient {
    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        .hostUnavailable(.host)
    }

    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        .hostUnavailable(.host)
    }

    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        .hostUnavailable(.host)
    }
}

struct SocketAgentIntegrationClient: AgentIntegrationClient {
    private let client: AgentIntegrationLocalClient?
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

actor NOWMCPServer {
    enum ToolName: String {
        case sessionHealth = "now_session_health"
        case sessionCapabilities = "now_session_capabilities"
        case listProcesses = "now_list_processes"
        case launchSoftware = "now_launch_software"
        case requestQuit = "now_request_quit"
        case transferApprovedArtifact =
            "now_transfer_approved_artifact"
        case guestFilesCapabilities =
            "now_guest_files_capabilities"
        case guestFilesList = "now_guest_files_list"
        case guestFilesStat = "now_guest_files_stat"
        case guestFilesUploadBegin = "now_guest_files_upload_begin"
        case guestFilesUploadAppend = "now_guest_files_upload_append"
        case guestFilesUploadCommit = "now_guest_files_upload_commit"
    }

    static let maximumMessageBytes = 64 * 1024
    private static let supportedVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    private let client: AgentIntegrationClient
    private var initializeResponded = false
    private var initialized = false

    init(client: AgentIntegrationClient) {
        self.client = client
    }

    func handle(_ data: Data) async -> Data? {
        guard data.count <= Self.maximumMessageBytes else {
            return errorResponse(id: NSNull(), code: -32700,
                                 message: "MCP message exceeds size limit")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            return errorResponse(id: NSNull(), code: -32700,
                                 message: "Parse error")
        }
        guard let request = value as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return errorResponse(id: validID(requestID(in: value)),
                                 code: -32600,
                                 message: "Invalid Request")
        }

        let id = validID(request["id"])
        let isNotification = request["id"] == nil
        guard isNotification || !(id is NSNull) else {
            return errorResponse(id: NSNull(), code: -32600,
                                 message: "Invalid Request")
        }
        switch method {
        case "initialize":
            guard !isNotification else { return nil }
            return initialize(request, id: id)
        case "notifications/initialized":
            guard isNotification, initializeResponded else { return nil }
            initialized = true
            return nil
        case "ping":
            guard !isNotification else { return nil }
            return successResponse(id: id, result: [:])
        case "tools/list":
            guard !isNotification else { return nil }
            guard initialized else {
                return errorResponse(
                    id: id, code: -32002,
                    message: "Server has not completed initialization")
            }
            return listTools(request, id: id)
        case "tools/call":
            guard !isNotification else { return nil }
            guard initialized else {
                return errorResponse(
                    id: id, code: -32002,
                    message: "Server has not completed initialization")
            }
            return await callTool(request, id: id)
        default:
            guard !isNotification else { return nil }
            return errorResponse(id: id, code: -32601,
                                 message: "Method not found")
        }
    }

    func oversizedMessageResponse() -> Data {
        errorResponse(id: NSNull(), code: -32700,
                      message: "MCP message exceeds size limit")
    }

    private func initialize(_ request: [String: Any], id: Any) -> Data {
        guard !initializeResponded,
              let params = request["params"] as? [String: Any],
              let requested = params["protocolVersion"] as? String,
              params["capabilities"] is [String: Any],
              params["clientInfo"] is [String: Any] else {
            return errorResponse(id: id, code: -32602,
                                 message: "Invalid initialize parameters")
        }
        initializeResponded = true
        let version = Self.supportedVersions.contains(requested)
            ? requested : Self.supportedVersions[0]
        return successResponse(id: id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": [:]],
            "serverInfo": [
                "name": "now-agent-companion",
                "title": "New Old World Agent Integration",
                "version": "0.1.0",
            ],
            "instructions":
                "Projects bounded health, process observation, exact application launch, revalidated cooperative quit, approved artifact delivery, and root-scoped guest Files observation already owned by a running New Old World host.",
        ])
    }

    private func listTools(_ request: [String: Any], id: Any) -> Data {
        if let params = request["params"] as? [String: Any],
           params["cursor"] != nil {
            return errorResponse(id: id, code: -32602,
                                 message: "Invalid tools/list cursor")
        }
        return successResponse(id: id, result: [
            "tools": [
                [
                    "name": ToolName.sessionHealth.rawValue,
                    "title": "New Old World Session Health",
                    "description":
                        "Reports the running NOW host and paired guest session state without changing either application.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [:],
                        "additionalProperties": false,
                    ],
                    "outputSchema": [
                        "type": "object",
                        "properties": [
                            "available": ["type": "boolean"],
                            "health": ["type": "object"],
                            "unavailable": ["type": "object"],
                        ],
                        "required": ["available"],
                    ],
                    "annotations": [
                        "readOnlyHint": true,
                        "destructiveHint": false,
                        "idempotentHint": true,
                        "openWorldHint": false,
                    ],
                ],
                sessionCapabilitiesTool(),
                processListTool(),
                launchSoftwareTool(),
                requestQuitTool(),
                transferApprovedArtifactTool(),
                guestFilesCapabilitiesTool(),
                guestFilesListTool(),
                guestFilesStatTool(),
                guestFilesUploadBeginTool(),
                guestFilesUploadAppendTool(),
                guestFilesUploadCommitTool(),
            ],
        ])
    }

    /// The tool that makes the other eleven honest against a guest that
    /// implements only part of the contract. It reports what the CONNECTED
    /// guest can do, derived from its own `help` table and from observed
    /// message-family traffic — never from which guest it is.
    private func sessionCapabilitiesTool() -> [String: Any] {
        let capabilityState = [
            "type": "string",
            "enum": ["available", "unavailable", "unproven"],
        ] as [String: Any]
        return [
            "name": ToolName.sessionCapabilities.rawValue,
            "title": "New Old World Session Capabilities",
            "description":
                "Reports what the currently paired NOW guest can actually do, and therefore which of these tools are available against it. NOW has guests of different completeness; a tool listed as unavailable here cannot be made to work by calling it anyway. Command availability comes from the guest's own help table and message-family availability from observed traffic plus bounded read-only probes; nothing is inferred from the guest's identity. State 'unproven' means nobody has asked this guest yet and is not a synonym for 'unavailable'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "probeCostly": [
                        "type": "boolean",
                        "description":
                            "Settle software.list by asking. Its first page is a whole-volume sweep costing about four seconds on a guest that implements it; a guest that does not refuses instantly. Defaults to false, which leaves software.list unproven.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "available": ["type": "boolean"],
                    "capabilities": [
                        "type": "object",
                        "properties": [
                            "sessionID": [
                                "type": "string", "format": "uuid",
                            ],
                            "observedAt": [
                                "type": "string", "format": "date-time",
                            ],
                            "commandTable": [
                                "type": "array",
                                "items": ["type": "string"],
                            ],
                            "commandTableEvidence": ["type": "string"],
                            "probedCostly": ["type": "boolean"],
                            "families": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "family": ["type": "string"],
                                        "state": capabilityState,
                                        "evidence": ["type": "string"],
                                        "refusalCode": ["type": "string"],
                                        "refusalMessage": [
                                            "type": "string",
                                        ],
                                    ],
                                    "required": [
                                        "family", "state", "evidence",
                                    ],
                                ],
                            ],
                            "tools": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "tool": ["type": "string"],
                                        "state": capabilityState,
                                        "requires": [
                                            "type": "array",
                                            "items": ["type": "string"],
                                        ],
                                        "missing": [
                                            "type": "array",
                                            "items": ["type": "string"],
                                        ],
                                        "reason": ["type": "string"],
                                    ],
                                    "required": [
                                        "tool", "state", "requires",
                                        "missing", "reason",
                                    ],
                                ],
                            ],
                        ],
                    ],
                    "unavailable": ["type": "object"],
                ],
                "required": ["available"],
            ],
            // Not idempotent: a probe settles a family, so a second call
            // can legitimately report more than the first. Saying
            // otherwise would invite a client to cache the weaker answer.
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private func processListTool() -> [String: Any] {
        [
            "name": ToolName.listProcesses.rawValue,
            "title": "List New Old World Guest Processes",
            "description":
                "Reads a bounded point-in-time snapshot of processes already observed through the running NOW host's paired guest session. Opaque references identify observations only and grant no control authority.",
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "available": ["type": "boolean"],
                    "snapshot": [
                        "type": "object",
                        "properties": [
                            "sessionID": [
                                "type": "string",
                                "format": "uuid",
                            ],
                            "observedAt": [
                                "type": "string",
                                "format": "date-time",
                            ],
                            "freshness": [
                                "type": "string",
                                "enum": ["pointInTime"],
                            ],
                            "referenceAuthority": [
                                "type": "string",
                                "enum": ["cooperativeQuit"],
                            ],
                            "processes": [
                                "type": "array",
                                "maxItems": 48,
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "reference": [
                                            "type": "string",
                                        ],
                                        "name": [
                                            "type": "string",
                                            "maxLength": 32,
                                        ],
                                        "kind": [
                                            "type": "string",
                                            "enum": [
                                                "application",
                                                "background",
                                                "finder",
                                                "unknown",
                                            ],
                                        ],
                                        "code": [
                                            "type": "string",
                                            "maxLength": 4,
                                        ],
                                        "creator": [
                                            "type": "string",
                                            "maxLength": 4,
                                        ],
                                        "sizeKB": [
                                            "type": "integer",
                                            "minimum": 0,
                                        ],
                                        "front": ["type": "boolean"],
                                    ],
                                    "required": [
                                        "name", "kind", "front",
                                    ],
                                    "additionalProperties": false,
                                ],
                            ],
                        ],
                        "required": [
                            "sessionID", "observedAt", "freshness",
                            "referenceAuthority", "processes",
                        ],
                        "additionalProperties": false,
                    ],
                    "unavailable": [
                        "type": "object",
                        "properties": [
                            "code": ["type": "string"],
                            "message": ["type": "string"],
                        ],
                        "required": ["code", "message"],
                        "additionalProperties": false,
                    ],
                ],
                "required": ["available"],
                "additionalProperties": false,
            ],
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private func launchSoftwareTool() -> [String: Any] {
        let failureSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy
                            .maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumMessageScalars,
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let candidateSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "reference": ["type": "string", "maxLength": 49],
                "name": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumNameScalars,
                ],
                "version": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumVersionScalars,
                ],
                "type": ["type": "string", "maxLength": 4],
                "creator": ["type": "string", "maxLength": 4],
                "running": [
                    "type": "boolean",
                    "description":
                        "State observed in the catalog before any launch",
                ],
            ],
            "required": ["reference", "name", "running"],
            "additionalProperties": false,
        ]
        let receiptSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "sessionID": [
                    "type": "string",
                    "format": "uuid",
                ],
                "catalogObservedAt": [
                    "type": "string",
                    "format": "date-time",
                ],
                "acknowledgedAt": [
                    "type": "string",
                    "format": "date-time",
                ],
                "software": candidateSchema,
                "guestMessage": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumMessageScalars,
                ],
            ],
            "required": [
                "sessionID", "catalogObservedAt", "acknowledgedAt",
                "software", "guestMessage",
            ],
            "additionalProperties": false,
        ]
        let ambiguitySchema: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy
                            .maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumMessageScalars,
                ],
                "matchCount": [
                    "type": "integer",
                    "minimum": 2,
                    "maximum":
                        AgentIntegrationLaunchPolicy.maximumCatalogEntries,
                ],
                "candidates": [
                    "type": "array",
                    "maxItems":
                        AgentIntegrationLaunchPolicy.maximumCandidates,
                    "items": candidateSchema,
                ],
            ],
            "required": [
                "code", "message", "matchCount", "candidates",
            ],
            "additionalProperties": false,
        ]
        func resultVariant(
            _ outcome: String,
            payload: String,
            schema: [String: Any]
        ) -> [String: Any] {
            [
                "type": "object",
                "properties": [
                    "outcome": ["const": outcome],
                    payload: schema,
                ],
                "required": ["outcome", payload],
                "additionalProperties": false,
            ]
        }
        return [
            "name": ToolName.launchSoftware.rawValue,
            "title": "Launch New Old World Guest Application",
            "description":
                "Launches only an exact, current application selected from the running NOW host's paired guest catalog. A name with zero or multiple exact matches does not launch; an opaque candidate reference is revalidated before use. Guest paths are never accepted or returned.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength":
                            AgentIntegrationLaunchPolicy.maximumNameScalars,
                    ],
                    "reference": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationLaunchPolicy.referencePattern,
                    ],
                ],
                "oneOf": [
                    ["required": ["name"], "not": ["required": ["reference"]]],
                    ["required": ["reference"], "not": ["required": ["name"]]],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    resultVariant(
                        "launched", payload: "launched",
                        schema: receiptSchema),
                    resultVariant(
                        "unavailable", payload: "unavailable",
                        schema: failureSchema),
                    resultVariant(
                        "ambiguous", payload: "ambiguous",
                        schema: ambiguitySchema),
                    resultVariant(
                        "notFound", payload: "notFound",
                        schema: failureSchema),
                    resultVariant(
                        "refused", payload: "refused",
                        schema: failureSchema),
                ],
            ],
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private func requestQuitTool() -> [String: Any] {
        let failureSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationQuitPolicy
                            .maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationQuitPolicy.maximumMessageScalars,
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let processSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "reference": [
                    "type": "string",
                    "pattern": AgentIntegrationQuitPolicy.referencePattern,
                ],
                "name": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationQuitPolicy.maximumNameScalars,
                ],
                "kind": [
                    "type": "string",
                    "enum": [
                        "application", "background", "finder", "unknown",
                    ],
                ],
                "code": ["type": "string", "maxLength": 4],
                "creator": ["type": "string", "maxLength": 4],
            ],
            "required": ["reference", "name", "kind"],
            "additionalProperties": false,
        ]
        let receiptSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "sessionID": ["type": "string", "format": "uuid"],
                "snapshotObservedAt": [
                    "type": "string", "format": "date-time",
                ],
                "revalidatedAt": [
                    "type": "string", "format": "date-time",
                ],
                "acknowledgedAt": [
                    "type": "string", "format": "date-time",
                ],
                "process": processSchema,
                "guestMessage": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationQuitPolicy.maximumMessageScalars,
                ],
            ],
            "required": [
                "sessionID", "snapshotObservedAt", "revalidatedAt",
                "acknowledgedAt", "process", "guestMessage",
            ],
            "additionalProperties": false,
        ]
        func resultVariant(
            _ outcome: String,
            payload: String,
            schema: [String: Any]
        ) -> [String: Any] {
            [
                "type": "object",
                "properties": [
                    "outcome": ["const": outcome],
                    payload: schema,
                ],
                "required": ["outcome", payload],
                "additionalProperties": false,
            ]
        }
        return [
            "name": ToolName.requestQuit.rawValue,
            "title": "Request New Old World Guest Application Quit",
            "description":
                "Asks one recently observed guest process to quit cooperatively. The running NOW host freshly re-lists and matches the full observed identity before the guest revalidates the live process reference. Success means only that the quit request was sent, not that the application exited.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "reference": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationQuitPolicy.referencePattern,
                    ],
                ],
                "required": ["reference"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    resultVariant(
                        "requestSent", payload: "requestSent",
                        schema: receiptSchema),
                    resultVariant(
                        "unavailable", payload: "unavailable",
                        schema: failureSchema),
                    resultVariant(
                        "stale", payload: "stale",
                        schema: failureSchema),
                    resultVariant(
                        "notFound", payload: "notFound",
                        schema: failureSchema),
                    resultVariant(
                        "refused", payload: "refused",
                        schema: failureSchema),
                ],
            ],
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private func transferApprovedArtifactTool() -> [String: Any] {
        let failureSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy
                            .maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumMessageScalars,
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let evidenceSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "sha256": [
                    "type": "string",
                    "pattern": "^[0-9a-f]{64}$",
                ],
                "bytes": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum":
                        AgentIntegrationArtifactPolicy.maximumSourceBytes,
                ],
            ],
            "required": ["sha256", "bytes"],
            "additionalProperties": false,
        ]
        let receiptSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "transferID": ["type": "string", "format": "uuid"],
                "sessionID": ["type": "string", "format": "uuid"],
                "approvedAt": ["type": "string", "format": "date-time"],
                "redeemedAt": ["type": "string", "format": "date-time"],
                "acknowledgedAt": [
                    "type": "string", "format": "date-time",
                ],
                "name": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumNameScalars,
                ],
                "source": evidenceSchema,
                "handedToNOW": evidenceSchema,
                "container": [
                    "type": "string",
                    "enum": ["data", "macbinary"],
                ],
                "conversion": [
                    "type": ["string", "null"],
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumMessageScalars,
                ],
                "guestAcknowledgedWrite": ["const": true],
                "destinationBytesVerified": ["const": false],
                "guestMessage": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumMessageScalars,
                ],
            ],
            "required": [
                "transferID", "sessionID", "approvedAt", "redeemedAt",
                "acknowledgedAt", "name", "source", "handedToNOW",
                "container", "guestAcknowledgedWrite",
                "destinationBytesVerified", "guestMessage",
            ],
            "additionalProperties": false,
        ]
        func resultVariant(
            _ outcome: String,
            payload: String,
            schema: [String: Any]
        ) -> [String: Any] {
            [
                "type": "object",
                "properties": [
                    "outcome": ["const": outcome],
                    payload: schema,
                ],
                "required": ["outcome", payload],
                "additionalProperties": false,
            ]
        }
        return [
            "name": ToolName.transferApprovedArtifact.rawValue,
            "title": "Transfer an Approved New Old World Artifact",
            "description":
                "Redeems one unexpired, one-use approval minted by a native New Old World host action. The receipt already fixes one private staged file and guest destination. The tool accepts no path, never overwrites, and reports success only after the paired guest acknowledges writing the file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "approvalReceipt": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationArtifactPolicy.receiptPattern,
                    ],
                ],
                "required": ["approvalReceipt"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    resultVariant(
                        "delivered", payload: "delivered",
                        schema: receiptSchema),
                    resultVariant(
                        "unavailable", payload: "unavailable",
                        schema: failureSchema),
                    resultVariant(
                        "expired", payload: "expired",
                        schema: failureSchema),
                    resultVariant(
                        "refused", payload: "refused",
                        schema: failureSchema),
                    resultVariant(
                        "failed", payload: "failed",
                        schema: failureSchema),
                ],
            ],
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private func callTool(_ request: [String: Any], id: Any) async -> Data {
        guard let params = request["params"] as? [String: Any],
              let name = params["name"] as? String,
              let tool = ToolName(rawValue: name) else {
            return errorResponse(id: id, code: -32602,
                                 message: "Unknown tool")
        }
        if tool == .sessionHealth || tool == .listProcesses
            || tool == .guestFilesCapabilities,
           let arguments = params["arguments"] {
            guard let object = arguments as? [String: Any],
                  object.isEmpty else {
                return errorResponse(
                    id: id, code: -32602,
                    message: "\(name) accepts no arguments")
            }
        }
        switch tool {
        case .sessionHealth:
            let result = await client.sessionHealth()
            return toolResponse(id: id, result: result)
        case .sessionCapabilities:
            let arguments =
                (params["arguments"] as? [String: Any]) ?? [:]
            let probeCostly: Bool
            switch arguments["probeCostly"] {
            case nil:
                probeCostly = false
            case let flag as Bool:
                probeCostly = flag
            default:
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_session_capabilities accepts only an optional boolean probeCostly")
            }
            guard Set(arguments.keys).isSubset(of: ["probeCostly"]) else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_session_capabilities accepts only an optional boolean probeCostly")
            }
            let result = await client.sessionCapabilities(
                probeCostly: probeCostly)
            return toolResponse(id: id, result: result)
        case .listProcesses:
            let result = await client.listProcesses()
            return toolResponse(id: id, result: result)
        case .launchSoftware:
            guard let arguments = params["arguments"] as? [String: Any],
                  let selection = launchSelection(arguments) else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_launch_software requires exactly one bounded name or opaque reference")
            }
            let result = await client.launchSoftware(selection)
            return toolResponse(id: id, result: result)
        case .requestQuit:
            guard let arguments = params["arguments"] as? [String: Any],
                  Set(arguments.keys) == ["reference"],
                  let reference = arguments["reference"] as? String,
                  AgentIntegrationQuitPolicy.isValidReference(reference)
            else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_request_quit requires one current opaque process reference")
            }
            let result = await client.requestQuit(reference: reference)
            return toolResponse(id: id, result: result)
        case .transferApprovedArtifact:
            guard let arguments = params["arguments"] as? [String: Any],
                  Set(arguments.keys) == ["approvalReceipt"],
                  let receipt = arguments["approvalReceipt"] as? String,
                  AgentIntegrationArtifactPolicy.isValidReceipt(receipt)
            else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_transfer_approved_artifact requires one host-minted approval receipt")
            }
            let result = await client.transferApprovedArtifact(
                receipt: receipt)
            return toolResponse(id: id, result: result)
        case .guestFilesCapabilities:
            let result = await client.guestFilesCapabilities()
            return toolResponse(id: id, result: result)
        case .guestFilesList:
            let arguments =
                (params["arguments"] as? [String: Any]) ?? [:]
            guard let selection = guestFileListSelection(arguments)
            else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_guest_files_list accepts one bounded root-relative path and optional positive cursor")
            }
            let result = await client.listGuestFiles(
                path: selection.path, cursor: selection.cursor)
            return toolResponse(id: id, result: result)
        case .guestFilesStat:
            guard let arguments = params["arguments"] as? [String: Any],
                  Set(arguments.keys) == ["path"],
                  let path = arguments["path"] as? String,
                  !path.isEmpty,
                  AgentIntegrationGuestFilePolicy.isBoundedPath(path)
            else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_guest_files_stat requires one bounded root-relative path")
            }
            let result = await client.statGuestFile(path: path)
            return toolResponse(id: id, result: result)
        case .guestFilesUploadBegin:
            guard let arguments = params["arguments"] as? [String: Any],
                  let upload = guestFileUploadBegin(arguments) else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_guest_files_upload_begin requires one canonical destination, declared size, SHA-256, and data or macbinary container")
            }
            return toolResponse(
                id: id,
                result: await client.beginGuestFileUpload(upload))
        case .guestFilesUploadAppend:
            guard let arguments = params["arguments"] as? [String: Any],
                  Set(arguments.keys) == ["uploadID", "offset", "data"],
                  let rawID = arguments["uploadID"] as? String,
                  let uploadID = UUID(uuidString: rawID),
                  let offset = arguments["offset"] as? Int,
                  offset >= 0,
                  let encoded = arguments["data"] as? String,
                  encoded.count
                    <= AgentIntegrationGuestFilePolicy
                        .maximumUploadChunkBase64Scalars,
                  let bytes = Data(base64Encoded: encoded),
                  !bytes.isEmpty,
                  bytes.count
                    <= AgentIntegrationGuestFilePolicy
                        .maximumUploadChunkBytes else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_guest_files_upload_append requires one opaque upload ID, exact offset, and at most 8192 decoded bytes")
            }
            return toolResponse(
                id: id,
                result: await client.appendGuestFileUpload(
                    uploadID: uploadID, offset: offset, bytes: bytes))
        case .guestFilesUploadCommit:
            guard let arguments = params["arguments"] as? [String: Any],
                  Set(arguments.keys) == ["uploadID"],
                  let rawID = arguments["uploadID"] as? String,
                  let uploadID = UUID(uuidString: rawID) else {
                return errorResponse(
                    id: id, code: -32602,
                    message:
                        "now_guest_files_upload_commit requires one opaque upload ID")
            }
            return toolResponse(
                id: id,
                result: await client.commitGuestFileUpload(
                    uploadID: uploadID))
        }
    }

    private func guestFileUploadBegin(
        _ arguments: [String: Any]
    ) -> AgentIntegrationGuestFileUploadBegin? {
        let allowed = Set([
            "destinationPath", "bytes", "sha256", "container",
            "fileType", "creator", "modified",
        ])
        guard Set(arguments.keys).isSubset(of: allowed),
              let destination = arguments["destinationPath"] as? String,
              !destination.isEmpty,
              AgentIntegrationGuestFilePolicy.isBoundedPath(destination),
              let bytes = arguments["bytes"] as? Int,
              bytes >= 0, bytes <= Int(Int32.max),
              let sha256 = arguments["sha256"] as? String,
              AgentIntegrationGuestFilePolicy.isCanonicalSHA256(sha256),
              let container = arguments["container"] as? String,
              container == "data" || container == "macbinary" else {
            return nil
        }
        func optionalString(_ key: String) -> String? {
            arguments[key] as? String
        }
        if arguments["fileType"] != nil
            && optionalString("fileType") == nil { return nil }
        if arguments["creator"] != nil
            && optionalString("creator") == nil { return nil }
        guard AgentIntegrationGuestFilePolicy.isClassicOSType(
                optionalString("fileType")),
              AgentIntegrationGuestFilePolicy.isClassicOSType(
                optionalString("creator")) else {
            return nil
        }
        let modified: Int?
        if let value = arguments["modified"] {
            guard let integer = value as? Int, integer >= 0 else {
                return nil
            }
            modified = integer
        } else {
            modified = nil
        }
        return .init(
            destinationPath: destination,
            bytes: bytes,
            sha256: sha256,
            container: container,
            fileType: optionalString("fileType"),
            creator: optionalString("creator"),
            modified: modified)
    }

    private func guestFileListSelection(
        _ arguments: [String: Any]
    ) -> (path: String, cursor: Int?)? {
        guard Set(arguments.keys).isSubset(of: ["path", "cursor"])
        else { return nil }
        let path: String
        if let value = arguments["path"] {
            guard let bounded = value as? String else { return nil }
            path = bounded
        } else {
            path = ""
        }
        guard AgentIntegrationGuestFilePolicy.isBoundedPath(path)
        else { return nil }
        let cursor: Int?
        if let value = arguments["cursor"] {
            guard let positive = value as? Int, positive >= 1
            else { return nil }
            cursor = positive
        } else {
            cursor = nil
        }
        return (path, cursor)
    }

    private func launchSelection(_ arguments: [String: Any])
        -> AgentIntegrationLaunchSelection? {
        switch Set(arguments.keys) {
        case ["name"]:
            guard let name = arguments["name"] as? String,
                  !name.isEmpty,
                  name.unicodeScalars.count <=
                    AgentIntegrationLaunchPolicy.maximumNameScalars else {
                return nil
            }
            return .name(name)
        case ["reference"]:
            guard let reference = arguments["reference"] as? String,
                  AgentIntegrationLaunchPolicy
                    .isValidReference(reference) else {
                return nil
            }
            return .reference(reference)
        default:
            return nil
        }
    }

    private func toolResponse<Result: Encodable>(
        id: Any,
        result: Result
    ) -> Data {
        do {
            let structured = try structuredObject(result)
            let textData = try JSONSerialization.data(
                withJSONObject: structured, options: [.sortedKeys])
            let text = String(decoding: textData, as: UTF8.self)
            return successResponse(id: id, result: [
                "content": [["type": "text", "text": text]],
                "structuredContent": structured,
                "isError": false,
            ])
        } catch {
            return errorResponse(id: id, code: -32603,
                                 message: "Could not encode tool result")
        }
    }

    private func structuredObject<Result: Encodable>(
        _ result: Result
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        return try JSONSerialization.jsonObject(with: data)
            as? [String: Any] ?? [:]
    }

    private func requestID(in value: Any) -> Any? {
        (value as? [String: Any])?["id"]
    }

    private func validID(_ value: Any?) -> Any {
        if let string = value as? String { return string }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.rounded() == number.doubleValue {
            return number
        }
        return NSNull()
    }

    private func successResponse(id: Any, result: [String: Any]) -> Data {
        jsonData([
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
    }

    private func errorResponse(id: Any, code: Int,
                               message: String) -> Data {
        jsonData([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ])
    }

    private func jsonData(_ object: [String: Any]) -> Data {
        // Every object above is made from constants or JSON-decoded IDs.
        // If this ever fails, an empty object is still one bounded line.
        (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }
}
