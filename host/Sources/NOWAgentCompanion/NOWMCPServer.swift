import CoreFoundation
import Foundation
import NOWAgentIntegration

protocol AgentIntegrationClient: Sendable {
    func sessionHealth() async -> AgentIntegrationSessionHealthResult
    func listProcesses() async -> AgentIntegrationProcessListResult
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult
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
    private enum ToolName: String {
        case sessionHealth = "now_session_health"
        case listProcesses = "now_list_processes"
        case launchSoftware = "now_launch_software"
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
                "Projects bounded health, process observation, and exact application launch already owned by a running New Old World host.",
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
                processListTool(),
                launchSoftwareTool(),
            ],
        ])
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
                                "enum": ["observationOnly"],
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

    private func callTool(_ request: [String: Any], id: Any) async -> Data {
        guard let params = request["params"] as? [String: Any],
              let name = params["name"] as? String,
              let tool = ToolName(rawValue: name) else {
            return errorResponse(id: id, code: -32602,
                                 message: "Unknown tool")
        }
        if tool != .launchSoftware,
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
        }
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
