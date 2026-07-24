import Foundation
import NOWAgentIntegration

extension NOWMCPServer {
    func guestFilesCapabilitiesTool() -> [String: Any] {
        [
            "name": ToolName.guestFilesCapabilities.rawValue,
            "title": "New Old World Guest Files Capabilities",
            "description":
                "Reports the running NOW host's active guestRoot policy, current guest share label, bounded limits, and implemented versus deferred guest Files commands. It changes nothing.",
            "inputSchema": emptyInputSchema,
            "outputSchema": guestFileResultSchema(
                value: guestFileCapabilitiesSchema),
            "annotations": readOnlyGuestFilesAnnotations,
        ]
    }

    func guestFilesListTool() -> [String: Any] {
        [
            "name": ToolName.guestFilesList.rawValue,
            "title": "List New Old World Guest Files",
            "description":
                "Lists one bounded page beneath the running NOW host's configured guestRoot. Paths are canonical root-relative HFS paths; the agent cannot choose or escape guestRoot.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": guestFilePathSchema,
                    "cursor": [
                        "type": "integer",
                        "minimum": 1,
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": guestFileResultSchema(
                value: guestFileListingSchema),
            "annotations": readOnlyGuestFilesAnnotations,
        ]
    }

    func guestFilesStatTool() -> [String: Any] {
        var path = guestFilePathSchema
        path["minLength"] = 1
        return [
            "name": ToolName.guestFilesStat.rawValue,
            "title": "Inspect a New Old World Guest File",
            "description":
                "Reads bounded metadata for one exact item beneath the running NOW host's configured guestRoot. A bounded parent scan returns explicit not-found or scan-limit outcomes instead of guessing.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": path],
                "required": ["path"],
                "additionalProperties": false,
            ],
            "outputSchema": guestFileResultSchema(
                value: guestFileEntrySchema),
            "annotations": readOnlyGuestFilesAnnotations,
        ]
    }

    private var emptyInputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ]
    }

    private var guestFilePathSchema: [String: Any] {
        [
            "type": "string",
            "maxLength":
                AgentIntegrationGuestFilePolicy.maximumPathScalars,
            "description":
                "Canonical HFS path relative to the host-owned guestRoot; empty means guestRoot.",
        ]
    }

    private var readOnlyGuestFilesAnnotations: [String: Any] {
        [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        ]
    }

    private var guestFileFailureSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": ["type": "string", "maxLength": 256],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
    }

    private var guestFileReceiptSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "commandID": ["type": "string", "format": "uuid"],
                "sessionID": [
                    "type": ["string", "null"],
                    "format": "uuid",
                ],
                "policyVersion": ["type": "integer", "minimum": 1],
                "operation": [
                    "type": "string",
                    "enum": [
                        "capabilities", "list", "stat", "download",
                        "readText", "tailText", "put", "mkdir", "move",
                        "delete", "deployTree", "prune",
                    ],
                ],
                "startedAt": ["type": "string", "format": "date-time"],
                "completedAt": [
                    "type": "string",
                    "format": "date-time",
                ],
                "outcome": [
                    "type": "string",
                    "enum": [
                        "success", "unavailable", "staleSession",
                        "notFound", "scanLimit", "refused",
                    ],
                ],
                "wireRequestCount": ["type": "integer", "minimum": 0],
            ],
            "required": [
                "commandID", "policyVersion", "operation", "startedAt",
                "completedAt", "outcome", "wireRequestCount",
            ],
            "additionalProperties": false,
        ]
    }

    private var guestFileEntrySchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": guestFilePathSchema,
                "name": ["type": "string", "maxLength": 31],
                "isFolder": ["type": "boolean"],
                "fileType": [
                    "type": ["string", "null"],
                    "maxLength": 4,
                ],
                "creator": [
                    "type": ["string", "null"],
                    "maxLength": 4,
                ],
                "dataBytes": [
                    "type": ["integer", "null"],
                    "minimum": 0,
                ],
                "resourceBytes": [
                    "type": ["integer", "null"],
                    "minimum": 0,
                ],
                "modified": [
                    "type": ["integer", "null"],
                    "minimum": 0,
                    "maximum": Int(UInt32.max),
                    "description":
                        "Classic Mac seconds since 1904 when observed.",
                ],
            ],
            "required": ["path", "name", "isFolder"],
            "additionalProperties": false,
        ]
    }

    private var guestFileListingSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": guestFilePathSchema,
                "entries": [
                    "type": "array",
                    "maxItems": 16,
                    "items": guestFileEntrySchema,
                ],
                "hasMore": ["type": "boolean"],
                "nextCursor": [
                    "type": ["integer", "null"],
                    "minimum": 1,
                ],
                "rootLabel": [
                    "type": ["string", "null"],
                    "maxLength": 128,
                ],
                "observedAt": [
                    "type": "string",
                    "format": "date-time",
                ],
            ],
            "required": ["path", "entries", "hasMore", "observedAt"],
            "additionalProperties": false,
        ]
    }

    private var guestFileCapabilitiesSchema: [String: Any] {
        let operations = [
            "capabilities", "list", "stat", "download", "readText",
            "tailText", "put", "mkdir", "move", "delete", "deployTree",
            "prune",
        ]
        return [
            "type": "object",
            "properties": [
                "guestRoot": guestFilePathSchema,
                "rootLabel": [
                    "type": ["string", "null"],
                    "maxLength": 128,
                ],
                "availableCommands": [
                    "type": "array",
                    "items": ["type": "string", "enum": operations],
                ],
                "deferredCommands": [
                    "type": "array",
                    "items": ["type": "string", "enum": operations],
                ],
                "maximumPageEntries": ["const": 16],
                "maximumStatPages": ["type": "integer", "minimum": 1],
                "maximumPathBytes": ["const": 223],
                "maximumSegmentBytes": ["const": 31],
                "transferLaneState": [
                    "type": "string",
                    "enum": ["busy", "unknown"],
                ],
                "observedAt": [
                    "type": "string",
                    "format": "date-time",
                ],
            ],
            "required": [
                "guestRoot", "availableCommands", "deferredCommands",
                "maximumPageEntries", "maximumStatPages",
                "maximumPathBytes", "maximumSegmentBytes",
                "transferLaneState", "observedAt",
            ],
            "additionalProperties": false,
        ]
    }

    private func guestFileResultSchema(
        value: [String: Any]
    ) -> [String: Any] {
        [
            "oneOf": [
                [
                    "type": "object",
                    "properties": [
                        "hostAvailable": ["const": false],
                        "unavailable": guestFileFailureSchema,
                    ],
                    "required": ["hostAvailable", "unavailable"],
                    "additionalProperties": false,
                ],
                [
                    "type": "object",
                    "properties": [
                        "hostAvailable": ["const": true],
                        "receipt": guestFileReceiptSchema,
                        "value": value,
                        "failure": guestFileFailureSchema,
                    ],
                    "required": ["hostAvailable", "receipt"],
                    "oneOf": [
                        ["required": ["value"]],
                        ["required": ["failure"]],
                    ],
                    "additionalProperties": false,
                ],
            ],
        ]
    }
}
