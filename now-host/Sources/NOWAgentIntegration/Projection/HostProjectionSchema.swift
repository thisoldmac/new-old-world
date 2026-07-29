import Foundation

/// Schema fragments more than one projection renders.
///
/// A fragment belongs here when two rows would otherwise state one shape
/// twice; anything one capability alone knows stays in that capability's
/// file, where a reviewer reading the row can see all of it.
public enum HostProjectionSchema {
    public static let emptyInput: [String: Any] = [
        "type": "object",
        "properties": [:],
        "additionalProperties": false,
    ]

    public static let readOnlyAnnotations: [String: Any] = [
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
    ]

    /// One discriminated `outcome` variant, the shape the launch, quit and
    /// artifact projections all render their results as.
    public static func resultVariant(
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
}

/// The guest Files family's shared shapes. Six projections render these,
/// which is why they are one declaration rather than six.
enum GuestFilesSchema {
    static var path: [String: Any] {
        [
            "type": "string",
            "maxLength":
                AgentIntegrationGuestFilePolicy.maximumPathScalars,
            "description":
                "Canonical HFS path relative to the host-owned guestRoot; empty means guestRoot.",
        ]
    }

    static var readOnlyAnnotations: [String: Any] {
        HostProjectionSchema.readOnlyAnnotations
    }

    static var uploadAnnotations: [String: Any] {
        [
            "readOnlyHint": false,
            "destructiveHint": false,
            "idempotentHint": false,
            "openWorldHint": false,
        ]
    }

    static var failure: [String: Any] {
        [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": ["type": "string", "maxLength": 256],
                "transferEvidence": [
                    "oneOf": [
                        transferFailureEvidence,
                        ["type": "null"],
                    ],
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
    }

    static var transferFailureEvidence: [String: Any] {
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

    static var receipt: [String: Any] {
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
                    "enum": operations,
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
                    "items": path,
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

    static var entry: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": path,
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

    static var listing: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": path,
                "entries": [
                    "type": "array",
                    "maxItems": 16,
                    "items": entry,
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

    static let operations = [
        "capabilities", "list", "stat", "download", "readText",
        "tailText", "put", "mkdir", "move", "delete", "deployTree",
        "prune",
    ]

    static var capabilities: [String: Any] {
        [
            "type": "object",
            "properties": [
                "guestRoot": path,
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

    static var uploadStage: [String: Any] {
        [
            "type": "object",
            "properties": [
                "uploadID": ["type": "string", "format": "uuid"],
                "destinationPath": path,
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

    static var uploadReceipt: [String: Any] {
        [
            "type": "object",
            "properties": [
                "uploadID": ["type": "string", "format": "uuid"],
                "destinationPath": path,
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

    static func result(value: [String: Any]) -> [String: Any] {
        [
            "oneOf": [
                [
                    "type": "object",
                    "properties": [
                        "hostAvailable": ["const": false],
                        "unavailable": failure,
                    ],
                    "required": ["hostAvailable", "unavailable"],
                    "additionalProperties": false,
                ],
                [
                    "type": "object",
                    "properties": [
                        "hostAvailable": ["const": true],
                        "receipt": receipt,
                        "value": value,
                        "failure": failure,
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
