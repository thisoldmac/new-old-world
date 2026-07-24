import CoreFoundation
import Foundation
import NOWAgentIntegration

protocol AgentIntegrationHealthClient: Sendable {
    func sessionHealth() async -> AgentIntegrationSessionHealthResult
}

struct SocketHealthClient: AgentIntegrationHealthClient {
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
            return unavailable(for: startupError)
        }
        do {
            return try await client.sessionHealth()
        } catch {
            return unavailable(for: error)
        }
    }

    private func unavailable(for error: Error?)
        -> AgentIntegrationSessionHealthResult {
        guard let error else { return .hostUnavailable }
        guard let local = error as? AgentIntegrationLocalTransportError
        else {
            return .unavailable(.init(
                code: "now-host-communication-failed",
                message: "New Old World host communication failed"))
        }
        switch local {
        case .hostUnavailable:
            return .hostUnavailable
        case .unsafeEndpoint:
            return .unavailable(.init(
                code: "now-host-endpoint-invalid",
                message: "New Old World host endpoint is not trustworthy"))
        case .invalidMessage, .messageTooLarge:
            return .unavailable(.init(
                code: "now-host-invalid-response",
                message: "New Old World host returned an invalid response"))
        case .io:
            return .unavailable(.init(
                code: "now-host-communication-failed",
                message: "New Old World host communication failed"))
        }
    }
}

actor NOWMCPServer {
    static let maximumMessageBytes = 64 * 1024
    private static let supportedVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    private let healthClient: AgentIntegrationHealthClient
    private var initializeResponded = false
    private var initialized = false

    init(healthClient: AgentIntegrationHealthClient) {
        self.healthClient = healthClient
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
                "Reports health already owned by a running New Old World host.",
        ])
    }

    private func listTools(_ request: [String: Any], id: Any) -> Data {
        if let params = request["params"] as? [String: Any],
           params["cursor"] != nil {
            return errorResponse(id: id, code: -32602,
                                 message: "Invalid tools/list cursor")
        }
        return successResponse(id: id, result: [
            "tools": [[
                "name": "now_session_health",
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
            ]],
        ])
    }

    private func callTool(_ request: [String: Any], id: Any) async -> Data {
        guard let params = request["params"] as? [String: Any],
              params["name"] as? String == "now_session_health" else {
            return errorResponse(id: id, code: -32602,
                                 message: "Unknown tool")
        }
        if let arguments = params["arguments"] {
            guard let object = arguments as? [String: Any],
                  object.isEmpty else {
                return errorResponse(
                    id: id, code: -32602,
                    message: "now_session_health accepts no arguments")
            }
        }
        let result = await healthClient.sessionHealth()
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

    private func structuredObject(
        _ result: AgentIntegrationSessionHealthResult
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
