import CoreFoundation
import Foundation
import NOWAgentIntegration

/// The MCP face. JSON-RPC framing, one MCP-shaped rendering of the host
/// projection registry, and nothing else.
///
/// It knows how many capabilities exist only by asking the registry, which
/// is the point: a capability arrives as one file plus one catalog row, and
/// no dispatch here has to learn its name. What used to be a tool enum, a
/// dozen schema builders and a switch over all of them is now the loop in
/// `Self.tools` and the lookup in `callTool`.
actor NOWMCPServer {
    static let maximumMessageBytes = 64 * 1024
    private static let supportedVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    private let client: AgentIntegrationClient
    private let registry: HostProjectionRegistry
    private var initializeResponded = false
    private var initialized = false

    init(client: AgentIntegrationClient,
         registry: HostProjectionRegistry = .hostFaces) {
        self.client = client
        self.registry = registry
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
        return successResponse(id: id, result: ["tools": tools])
    }

    /// One tool object per registry row, in registry order.
    ///
    /// The name and the `guest` selector are injected here rather than
    /// written into each row. The name because a row that spelled its own
    /// identity twice could disagree with itself; the selector because the
    /// host serves several machines at once and a caller that cannot say
    /// which one it means gets whichever is being driven — fine on a one-Mac
    /// desk and a silent wrong answer anywhere else. So it exists on every
    /// tool rather than on the ones somebody remembered.
    private var tools: [[String: Any]] {
        registry.projections.map { projection in
            var tool = projection.mcpDescriptor
            tool["name"] = projection.capability.rawValue
            guard var schema = tool["inputSchema"] as? [String: Any] else {
                return tool
            }
            var properties =
                (schema["properties"] as? [String: Any]) ?? [:]
            properties["guest"] = [
                "type": "string",
                "description": Self.guestSelectorHelp,
            ]
            schema["properties"] = properties
            tool["inputSchema"] = schema
            return tool
        }
    }

    private static let guestSelectorHelp = """
        Which connected Mac this call is about. A machine id (for example         pb1400c) means whatever is connected to that machine now and         follows a reconnection; a session id (machine id, a hyphen and a         UUID, as reported by now_session_health) means one connection and         fails once it has ended rather than being answered by its         successor. Omit to address the machine the host is currently         driving. Naming a connected machine the host is not driving is         refused, never answered by the other one.
        """

    private func callTool(_ request: [String: Any], id: Any) async -> Data {
        guard var params = request["params"] as? [String: Any],
              let name = params["name"] as? String,
              let projection = registry.projection(named: name) else {
            return errorResponse(id: id, code: -32602,
                                 message: "Unknown tool")
        }
        /* `guest` is lifted off every tool's arguments in ONE place and
           removed before the projection's own validation runs, so a dozen
           argument checks did not each have to learn about it and drift.
           An empty or oversized selector is rejected here rather than
           travelling to the host as a name nothing can match. */
        var selector: String?
        if var object = params["arguments"] as? [String: Any],
           let raw = object.removeValue(forKey: "guest") {
            guard let text = raw as? String, !text.isEmpty,
                  text.count <= 128 else {
                return errorResponse(
                    id: id, code: -32602,
                    message: "guest must be a machine id or session id")
            }
            selector = text
            params["arguments"] = object
        }
        let client = self.client.addressing(selector)
        let outcome = await projection.invoke(
            .init(raw: params["arguments"]), through: client)
        switch outcome {
        case .value(let value):
            return toolResponse(id: id, value: value)
        case .invalidArguments(let message):
            return errorResponse(id: id, code: -32602, message: message)
        }
    }

    private func toolResponse(id: Any, value: HostProjectionValue) -> Data {
        do {
            let structured = try structuredObject(value)
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
        _ value: HostProjectionValue
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try value.encoded(using: encoder)
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
