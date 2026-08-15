import CoreFoundation
import Foundation

/// The MCP face. JSON-RPC framing, one MCP-shaped rendering of the host
/// projection registry, and nothing else.
///
/// It knows how many capabilities exist only by asking the registry, which
/// is the point: a capability arrives as one file plus one catalog row, and
/// no dispatch here has to learn its name. What used to be a tool enum, a
/// dozen schema builders and a switch over all of them is now the loop in
/// `Self.tools` and the lookup in `callTool`.
public actor NOWMCPServer {
    public static let maximumMessageBytes = 64 * 1024
    public static let firstContactResourceURI = "now://agent/first-contact"
    public static let firstContactPromptName = "start-with-now"
    private static let supportedVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    private let client: AgentIntegrationClient
    private let registry: HostProjectionRegistry
    /// Every capability this face reaches goes through here, and every one
    /// that does leaves a line in the person's log. The sink is a required
    /// argument rather than a default, so a face cannot be assembled without
    /// saying where its audit events go.
    private let dispatch: HostProjectionDispatch
    private var initializeResponded = false
    private var initialized = false

    public init(client: AgentIntegrationClient,
                registry: HostProjectionRegistry = .hostFaces,
                audit: any HostProjectionAuditSink) {
        self.client = client
        self.registry = registry
        dispatch = HostProjectionDispatch(
            face: .mcp, registry: registry, audit: audit)
    }

    public func handle(_ data: Data) async -> Data? {
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
        case "resources/list":
            guard !isNotification else { return nil }
            guard initialized else { return notInitialized(id: id) }
            return listResources(request, id: id)
        case "resources/read":
            guard !isNotification else { return nil }
            guard initialized else { return notInitialized(id: id) }
            return readResource(request, id: id)
        case "prompts/list":
            guard !isNotification else { return nil }
            guard initialized else { return notInitialized(id: id) }
            return listPrompts(request, id: id)
        case "prompts/get":
            guard !isNotification else { return nil }
            guard initialized else { return notInitialized(id: id) }
            return getPrompt(request, id: id)
        default:
            guard !isNotification else { return nil }
            return errorResponse(id: id, code: -32601,
                                 message: "Method not found")
        }
    }

    public func oversizedMessageResponse() -> Data {
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
            "capabilities": [
                "tools": [:],
                "resources": ["subscribe": false, "listChanged": false],
                "prompts": ["listChanged": false],
            ],
            "serverInfo": [
                "name": "new-old-world",
                "title": "New Old World Agent Integration",
                "version": "0.1.0",
            ],
            "instructions": Self.firstContactGuide,
        ])
    }

    private static let firstContactGuide = """
        NOW controls one or more classic Macintosh guests through an already-running New Old World host. This agent surface is experimental and its names may change.

        Start with now_list_machines to discover the roster and the machine the host is already driving. A guest argument asserts that machine's stable id or exact session id; it does not switch the host to another connected machine. The person using NOW controls that selection.

        Prefer evidence in this order: structured product state (processes, software, files); retained now_semantic_ui_* state for desktop and application context; typed semantic actions followed by a wait or fresh read; a targeted direct element probe only when retained state is incomplete; pixels only for a genuinely visual fact or after semantic evidence fails. Do not infer success from an accepted action.

        Artifact delivery has two separate authority lanes. now_transfer_approved_artifact redeems a receipt minted when a person approves a host-selected file in NOW. now_guest_files_upload_begin, now_guest_files_upload_append, and now_guest_files_upload_commit transfer bytes the caller already possesses under the guest's full-access policy; they neither mint nor redeem an approval receipt.
        """

    private func notInitialized(id: Any) -> Data {
        errorResponse(id: id, code: -32002,
                      message: "Server has not completed initialization")
    }

    private func listResources(_ request: [String: Any], id: Any) -> Data {
        if let params = request["params"] as? [String: Any],
           params["cursor"] != nil {
            return errorResponse(id: id, code: -32602,
                                 message: "Invalid resources/list cursor")
        }
        return successResponse(id: id, result: ["resources": [[
            "uri": Self.firstContactResourceURI,
            "name": "now-first-contact",
            "title": "NOW agent first contact",
            "description":
                "Machine selection, semantic evidence order, verification, and approval boundaries for NOW.",
            "mimeType": "text/markdown",
        ]]])
    }

    private func readResource(_ request: [String: Any], id: Any) -> Data {
        guard let params = request["params"] as? [String: Any],
              params["uri"] as? String == Self.firstContactResourceURI,
              Set(params.keys).isSubset(of: ["uri", "_meta"]),
              params["_meta"] == nil
                || params["_meta"] is [String: Any] else {
            return errorResponse(id: id, code: -32602,
                                 message: "Unknown NOW resource")
        }
        return successResponse(id: id, result: ["contents": [[
            "uri": Self.firstContactResourceURI,
            "mimeType": "text/markdown",
            "text": Self.firstContactGuide,
        ]]])
    }

    private func listPrompts(_ request: [String: Any], id: Any) -> Data {
        if let params = request["params"] as? [String: Any],
           params["cursor"] != nil {
            return errorResponse(id: id, code: -32602,
                                 message: "Invalid prompts/list cursor")
        }
        return successResponse(id: id, result: ["prompts": [[
            "name": Self.firstContactPromptName,
            "title": "Start with NOW",
            "description":
                "Ground on the connected Macintosh and use the semantic evidence ladder before acting.",
            "arguments": [],
        ]]])
    }

    private func getPrompt(_ request: [String: Any], id: Any) -> Data {
        guard let params = request["params"] as? [String: Any],
              params["name"] as? String == Self.firstContactPromptName,
              Set(params.keys).isSubset(of: ["name", "arguments"]),
              params["arguments"] == nil
                || params["arguments"] is [String: Any] else {
            return errorResponse(id: id, code: -32602,
                                 message: "Unknown NOW prompt")
        }
        return successResponse(id: id, result: [
            "description": "Begin a bounded NOW session",
            "messages": [[
                "role": "user",
                "content": [
                    "type": "text",
                    "text": Self.firstContactGuide,
                ],
            ]],
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
    ///
    /// The **root `type` of each schema** is injected for the same reason,
    /// and it is the third thing here that is a property of the MCP envelope
    /// rather than of any capability. The spec restricts both `inputSchema`
    /// and `outputSchema` to `type: "object"` at the root — arguments arrive
    /// as an object and `structuredContent` is returned as one — so the root
    /// type is the one fact every row would otherwise have to remember to
    /// repeat identically, 46 times, forever.
    ///
    /// 29 rows did not repeat it, and the cost was total: a row that renders
    /// a discriminated outcome writes a bare root-level `oneOf`, which
    /// declares no type, and a conforming client validates `tools/list` as a
    /// whole and rejects the WHOLE list. Not 29 rows of 46 — zero of 46.
    /// Every gate in this tree was green throughout and the host's own MCP
    /// page read "Running", because nothing here had ever validated the
    /// payload it published (`NOWMCPServerTests.testEveryRenderedTool-
    /// SchemaSatisfiesTheMCPRootTypeRequirement`).
    ///
    /// The chat face had already learned this and nobody carried it across:
    /// `ChatToolRendering.apiSafeSchema` supplies the same missing root type
    /// — one line, same defaulting — because the Anthropic API rejected these
    /// schemas on metal in August. Two faces render the same descriptors to
    /// two validators, one was taught and the other was not, and the row
    /// authors could not have known because the lesson lived in the other
    /// face's file. Whatever a third face needs, it needs it HERE-shaped:
    /// at its own rendering seam, not in 46 rows.
    ///
    /// Injected rather than required of each row on purpose: a row states
    /// what VARIES about its shape, and the envelope states the invariant.
    /// It is not a repair of a wrong answer, and it must not become one —
    /// a row that declares a root type that is *not* `object` is stating
    /// something false about its own result rather than omitting something
    /// uniform, so it is left exactly as written here and failed by the gate.
    private var tools: [[String: Any]] {
        registry.projections.map { projection in
            var tool = projection.mcpDescriptor
            tool["name"] = projection.capability.rawValue
            for key in ["inputSchema", "outputSchema"] {
                guard var schema = tool[key] as? [String: Any],
                      schema["type"] == nil else { continue }
                schema["type"] = "object"
                tool[key] = schema
            }
            guard var schema = tool["inputSchema"] as? [String: Any] else {
                return tool
            }
            var properties =
                (schema["properties"] as? [String: Any]) ?? [:]
            if projection.acceptsGuestAddressing {
                properties["guest"] = [
                    "type": "string",
                    "description": Self.guestSelectorHelp,
                ]
            }
            schema["properties"] = properties
            tool["inputSchema"] = schema
            return tool
        }
    }

    private static let guestSelectorHelp = """
        Which connected Mac this call is about. A machine id (for example         pb1400c) means whatever is connected to that machine now and         follows a reconnection; a session id (machine id, a hyphen and a         UUID, as reported by now_list_machines) means one connection and         fails once it has ended rather than being answered by its         successor. Omit to address the machine the host is currently         driving. Naming a connected machine the host is not driving is         refused, never answered by the other one.
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
            guard projection.acceptsGuestAddressing else {
                return errorResponse(
                    id: id, code: -32602,
                    message: "\(name) \(projection.authorityDomain.addressingRefusalSubject) and does not accept guest addressing")
            }
            guard let text = raw as? String, !text.isEmpty,
                  text.count <= 128 else {
                return errorResponse(
                    id: id, code: -32602,
                    message: "guest must be a machine id or session id")
            }
            selector = text
            params["arguments"] = object
        }
        /* Through the dispatch rather than at the projection directly: this
           is the seam that makes the invocation visible to the person at the
           machine, and reaching past it would put a capability on this face
           that leaves no trace. `HostProjectionAuditGateTests` fails when
           anything here calls a projection's `invoke` itself. */
        let client = self.client.addressing(selector)
        let outcome = await dispatch.invoke(
            name,
            arguments: .init(raw: params["arguments"]),
            guest: selector,
            through: client)
        switch outcome {
        case .value(let value):
            return toolResponse(id: id, value: value)
        case .invalidArguments(let message):
            return errorResponse(id: id, code: -32602, message: message)
        case .deniedByConsent(let denial):
            /* Its own code and its own `data`, so a caller tells "the owner
               said no" from "the machine cannot" without reading either
               sentence: incapacity comes back as a successful RESULT whose
               payload says `unavailable`, and this is an ERROR. Not -32602 —
               the caller's arguments were fine. */
            return errorResponse(id: id,
                                 code: HostProjectionConsentDenial.jsonRPCCode,
                                 message: denial.message,
                                 data: denial.errorData)
        case nil:
            // No row claims the name. The guard above says the same thing
            // first; this is the dispatch's own answer, not a second policy.
            return errorResponse(id: id, code: -32602,
                                 message: "Unknown tool")
        }
    }

    private func toolResponse(id: Any, value: HostProjectionValue) -> Data {
        do {
            let structured = try structuredObject(value)
            let textData = try JSONSerialization.data(
                withJSONObject: structured, options: [.sortedKeys])
            let text = String(decoding: textData, as: UTF8.self)
            var content: [[String: Any]] = [["type": "text", "text": text]]
            /* A result may carry one non-JSON rendering of the same answer —
               a capture's PNG. It goes here, as MCP's own image block, and
               NOT in the structured part: this method serialises that into
               the text block as well, so a picture in a JSON field would be
               sent to the caller twice. */
            if case .image(let bytes, let mimeType)? = value.attachment {
                content.append([
                    "type": "image",
                    "data": bytes.base64EncodedString(),
                    "mimeType": mimeType,
                ])
            }
            return successResponse(id: id, result: [
                "content": content,
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

    /// `data` is optional and carries machine-readable fields beside the
    /// sentence, for the one error class a caller is expected to BRANCH on
    /// rather than surface: a consent denial.
    private func errorResponse(id: Any, code: Int, message: String,
                               data: [String: Any]? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": message]
        if let data {
            error["data"] = data
        }
        return jsonData([
            "jsonrpc": "2.0",
            "id": id,
            "error": error,
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
