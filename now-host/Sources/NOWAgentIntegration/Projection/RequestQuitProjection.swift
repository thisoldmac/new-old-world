import Foundation

/// Cooperative quit of one recently observed process.
///
/// Quit needs the `process.quit` FAMILY, not the `quit` command. A guest
/// with a `quit` verb and no `process.quit` cannot support the
/// opaque-reference/PSN-revalidation model this projection is built on, and
/// the fix is never to relax the model to fit.
///
/// Success means the request was sent. It never means the application
/// exited — that takes a later listing, and saying otherwise would be the
/// host answering for the machine.
public enum RequestQuitProjection: HostProjection {
    public static let capability = HostCapabilityID("now_request_quit")

    public static let requires = [
        AgentIntegrationCapabilityNames.processList,
        AgentIntegrationCapabilityNames.processQuit,
    ]

    /* `process.quit` only. The caller directs the quit, and the process.list
       this row also requires is consumed internally to revalidate the opaque
       reference against a current PSN — no listing comes back. process.list
       stays covered because `now_list_processes` genuinely exposes it, which
       is the point: exposure is a property of a row, and the capability is
       covered if any row exposes it. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.processQuit]

    /* The Processes page's Ask to Quit button, on the selected row. It is
       disabled for the row the guest reports as itself rather than being
       offered and refused, which is a rendering decision about the same
       capability. */
    public static let acceptedArguments: Set<String> = ["reference"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ProcessesModuleView.swift",
                         symbol: "model.askToQuit(entry)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves process.list and process.quit."

    public static var operationDescriptor: NOWOperationDescriptor {
        let failure: [String: Any] = [
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
        let process: [String: Any] = [
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
        let receipt: [String: Any] = [
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
                "process": process,
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
        let variant = HostProjectionSchema.resultVariant
        return [
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
                    variant("requestSent", "requestSent", receipt),
                    variant("unavailable", "unavailable", failure),
                    variant("stale", "stale", failure),
                    variant("notFound", "notFound", failure),
                    variant("refused", "refused", failure),
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

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              Set(arguments.keys) == acceptedArguments,
              let reference = arguments["reference"] as? String,
              AgentIntegrationQuitPolicy.isValidReference(reference)
        else {
            return .invalidArguments(
                "now_request_quit requires one current opaque process reference")
        }
        return .value(.init(
            await client.requestQuit(reference: reference)))
    }
}
