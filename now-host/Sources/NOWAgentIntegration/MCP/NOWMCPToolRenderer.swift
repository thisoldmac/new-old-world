import Foundation

/// The sole MCP rendering seam for neutral NOW operation descriptors.
public enum NOWMCPToolRenderer {
    public static func baseTool(
        for projection: any HostProjection.Type
    ) -> [String: Any] {
        baseTool(descriptor: projection.operationDescriptor)
    }

    public static func baseTool(
        descriptor: NOWOperationDescriptor
    ) -> [String: Any] {
        var tool: [String: Any] = [
            "title": descriptor.title,
            "description": descriptor.summary,
            "inputSchema": descriptor.inputSchema,
            "annotations": [
                "readOnlyHint": descriptor.effectHints.readOnly,
                "destructiveHint": descriptor.effectHints.destructive,
                "idempotentHint": descriptor.effectHints.idempotent,
                "openWorldHint": descriptor.effectHints.openWorld,
            ],
        ]
        if let output = descriptor.outputSchema {
            tool["outputSchema"] = output
        }
        if let stability = descriptor.stability {
            tool["x-now-stability"] = stability
        }
        return tool
    }

    /// Renders the exact tools/list payload, including MCP's object-root and
    /// guest-selector requirements. No projection owns either concern.
    public static func tools(
        for registry: HostProjectionRegistry
    ) -> [[String: Any]] {
        registry.projections.map { projection in
            var tool = baseTool(for: projection)
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
            var properties = (schema["properties"] as? [String: Any]) ?? [:]
            if projection.acceptsGuestAddressing {
                properties["guest"] = [
                    "type": "string",
                    "description": guestSelectorHelp,
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
}
