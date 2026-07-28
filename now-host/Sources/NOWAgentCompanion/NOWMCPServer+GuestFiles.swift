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

    func guestFilesUploadBeginTool() -> [String: Any] {
        [
            "name": ToolName.guestFilesUploadBegin.rawValue,
            "title": "Begin a New Old World Guest File Upload",
            "description":
                "Reserves private NOW-owned staging for one declared file beneath guestRoot. It accepts no modern-host path and sends nothing to the guest yet.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "destinationPath": guestFilePathSchema,
                    "bytes": [
                        "type": "integer", "minimum": 0,
                        "maximum": Int(Int32.max),
                    ],
                    "sha256": [
                        "type": "string",
                        "pattern": "^[0-9a-f]{64}$",
                    ],
                    "container": [
                        "type": "string",
                        "enum": ["data", "macbinary"],
                    ],
                    "fileType": [
                        "type": "string", "minLength": 4, "maxLength": 4,
                    ],
                    "creator": [
                        "type": "string", "minLength": 4, "maxLength": 4,
                    ],
                    "modified": ["type": "integer", "minimum": 0],
                ],
                "required": [
                    "destinationPath", "bytes", "sha256", "container",
                ],
                "additionalProperties": false,
            ],
            "outputSchema": guestFileResultSchema(
                value: guestFileUploadStageSchema),
            "annotations": uploadAnnotations,
        ]
    }

    func guestFilesUploadAppendTool() -> [String: Any] {
        [
            "name": ToolName.guestFilesUploadAppend.rawValue,
            "title": "Append a New Old World Guest File Upload",
            "description":
                "Writes one ordered, bounded base64 chunk into an existing private NOW upload stage. It sends nothing to the guest.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "uploadID": ["type": "string", "format": "uuid"],
                    "offset": ["type": "integer", "minimum": 0],
                    "data": [
                        "type": "string",
                        "contentEncoding": "base64",
                        "maxLength": 11_000,
                    ],
                ],
                "required": ["uploadID", "offset", "data"],
                "additionalProperties": false,
            ],
            "outputSchema": guestFileResultSchema(
                value: guestFileUploadStageSchema),
            "annotations": uploadAnnotations,
        ]
    }

    func guestFilesUploadCommitTool() -> [String: Any] {
        [
            "name": ToolName.guestFilesUploadCommit.rawValue,
            "title": "Commit a New Old World Guest File Upload",
            "description":
                "Verifies and consumes one private stage, then asks the running NOW host to create the exact destination through its existing guest transfer lane. It never overwrites.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "uploadID": ["type": "string", "format": "uuid"],
                ],
                "required": ["uploadID"],
                "additionalProperties": false,
            ],
            "outputSchema": guestFileResultSchema(
                value: guestFileUploadReceiptSchema),
            "annotations": uploadAnnotations,
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

    private var uploadAnnotations: [String: Any] {
        [
            "readOnlyHint": false,
            "destructiveHint": false,
            "idempotentHint": false,
            "openWorldHint": false,
        ]
    }

    private var guestFileFailureSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": ["type": "string", "maxLength": 256],
                "transferEvidence": [
                    "oneOf": [
                        guestFileTransferFailureEvidenceSchema,
                        ["type": "null"],
                    ],
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
    }

    private var guestFileTransferFailureEvidenceSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "totalBytes": ["type": "integer", "minimum": 0],
                "acceptedOffset": ["type": "integer", "minimum": 0],
                "receiverConfirmedBytes": [
                    "type": ["integer", "null"], "minimum": 0,
                ],
                "elapsedMs": ["type": "integer", "minimum": 0],
                "stalledState": [
                    "type": "string",
                    "enum": ["observed", "not-observed", "unknown"],
                ],
                "maximumProgressGapMs": [
                    "type": ["integer", "null"], "minimum": 0,
                ],
                "progressEvidence": [
                    "type": "string", "maxLength": 32,
                ],
                "guestFreeBytesBefore": [
                    "type": ["integer", "null"], "minimum": 0,
                ],
                "guestReservedBytes": [
                    "type": ["integer", "null"], "minimum": 0,
                ],
                "guestStaging": [
                    "type": ["string", "null"], "maxLength": 32,
                ],
                "hostStagingCleanup": [
                    "type": "string", "maxLength": 32,
                ],
                "guestCleanup": [
                    "type": "string", "maxLength": 32,
                ],
            ],
            "required": [
                "totalBytes", "acceptedOffset", "elapsedMs",
                "stalledState", "progressEvidence",
                "hostStagingCleanup", "guestCleanup",
            ],
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
                        "notFound", "scanLimit", "refused", "expired",
                        "conflict", "failed",
                    ],
                ],
                "wireRequestCount": ["type": "integer", "minimum": 0],
                "affectedPaths": [
                    "type": "array",
                    "maxItems": 1,
                    "items": guestFilePathSchema,
                ],
            ],
            "required": [
                "commandID", "policyVersion", "operation", "startedAt",
                "completedAt", "outcome", "wireRequestCount",
                "affectedPaths",
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
                "observationReference": [
                    "type": ["string", "null"],
                    "maxLength":
                        AgentIntegrationGuestFilePolicy
                            .maximumObservationReferenceScalars,
                    "description":
                        "Opaque, short-lived handle for this exact observation. It grants no path-only mutation authority.",
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

    private var guestFileUploadStageSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "uploadID": ["type": "string", "format": "uuid"],
                "destinationPath": guestFilePathSchema,
                "expectedBytes": ["type": "integer", "minimum": 0],
                "receivedBytes": ["type": "integer", "minimum": 0],
                "maximumChunkBytes": [
                    "const": AgentIntegrationGuestFilePolicy
                        .maximumUploadChunkBytes,
                ],
                "expiresAt": ["type": "string", "format": "date-time"],
                "hostAvailableBytesAtStart": [
                    "type": "integer", "minimum": 0,
                ],
                "hostReservedBytes": ["type": "integer", "minimum": 0],
                "sealed": ["type": "boolean"],
            ],
            "required": [
                "uploadID", "destinationPath", "expectedBytes",
                "receivedBytes", "maximumChunkBytes", "expiresAt",
                "hostAvailableBytesAtStart", "hostReservedBytes", "sealed",
            ],
            "additionalProperties": false,
        ]
    }

    private var guestFileUploadReceiptSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "uploadID": ["type": "string", "format": "uuid"],
                "destinationPath": guestFilePathSchema,
                "container": [
                    "type": "string", "enum": ["data", "macbinary"],
                ],
                "sha256": [
                    "type": "string", "pattern": "^[0-9a-f]{64}$",
                ],
                "totalBytes": ["type": "integer", "minimum": 0],
                "acceptedOffset": ["type": "integer", "minimum": 0],
                "receiverConfirmedBytes": [
                    "type": "integer", "minimum": 0,
                ],
                "elapsedMs": ["type": "integer", "minimum": 0],
                "averageBytesPerSecond": [
                    "type": "integer", "minimum": 0,
                ],
                "stalledState": [
                    "type": "string",
                    "enum": ["observed", "not-observed", "unknown"],
                ],
                "maximumProgressGapMs": [
                    "type": ["integer", "null"], "minimum": 0,
                ],
                "progressEvidence": ["type": "string", "maxLength": 32],
                "guestFreeBytesBefore": [
                    "type": ["integer", "null"], "minimum": 0,
                ],
                "guestReservedBytes": [
                    "type": ["integer", "null"], "minimum": 0,
                ],
                "guestStaging": [
                    "type": ["string", "null"], "maxLength": 32,
                ],
                "finalization": ["type": "string", "maxLength": 32],
                "destinationAcknowledged": ["const": true],
                "integrity": ["type": "string", "maxLength": 32],
                "hostStagingCleanup": ["type": "string", "maxLength": 32],
                "guestCleanup": ["type": "string", "maxLength": 32],
            ],
            "required": [
                "uploadID", "destinationPath", "container", "sha256",
                "totalBytes", "acceptedOffset", "receiverConfirmedBytes",
                "elapsedMs", "averageBytesPerSecond", "stalledState",
                "progressEvidence", "finalization",
                "destinationAcknowledged", "integrity",
                "hostStagingCleanup", "guestCleanup",
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
