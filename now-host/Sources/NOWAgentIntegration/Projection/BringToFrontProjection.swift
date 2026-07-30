import Foundation

/// Bring one recently observed process forward.
///
/// The sibling of `RequestQuitProjection`, and deliberately shaped like it:
/// the same opaque `now-process-…` reference, the same revalidation against a
/// fresh listing before anything is asked, the same refusal to accept a name.
/// A name is a person's identifier — 31 characters, not unique — and it
/// belongs on the guest's own console, where the contract puts it as the
/// `front` verb.
///
/// **What this row is NOT is the observation.** Which application is
/// frontmost is already answerable: `now_list_processes` returns `front` as a
/// required boolean on every entry. This is the ACTION, and re-exposing the
/// observation here would be two routes to one answer.
///
/// **Success is `unconfirmed` unless a fresh listing says otherwise.** The
/// `process.front` message answers `process.result`, which has no field that
/// could carry "and it landed" — the switch happens when the guest next
/// yields — so the outcome is earned by re-listing and reading the target's
/// `front` flag, the check the guest's own source recommends
/// (`now-guest-68k/src/core/wire68.c :: handle_process_drive`). That is
/// composition over data the guest just supplied, not the host deciding: the
/// confirming fact comes from `process.list`, which is a different subsystem
/// from the one that was asked.
public enum BringToFrontProjection: HostProjection {
    public static let capability = HostCapabilityID("now_bring_to_front")

    /* Three, and each is load-bearing: process.list twice over — once to
       revalidate the reference, once to confirm the switch — and
       process.front to make it. A guest with the `front` COMMAND and not
       the message cannot support the reference model this row stands on,
       and the model is not relaxed to make a tool available. */
    public static let requires = [
        AgentIntegrationCapabilityNames.processList,
        AgentIntegrationCapabilityNames.processFront,
    ]

    /* `process.front` only. Both uses of process.list are internal — the
       caller directs the switch and gets back no listing — and it stays
       covered because `now_list_processes` genuinely exposes it. Exposure is
       a property of a row, not of a capability. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.processFront]

    /* The Processes page's Bring to Front button, on the selected row. It
       predates this row by the whole project: the same GuestListener drive
       verb has always been one click away for the person at the machine,
       which is why rule 3 costs this capability nothing. */
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ProcessesModuleView.swift",
                         symbol: "model.bringToFront(entry)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves process.list and process.front."

    public static var mcpDescriptor: [String: Any] {
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
        let receipt: [String: Any] = [
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
                "outcome": [
                    "type": "string",
                    "enum": AgentIntegrationFrontOutcome.allCases.map(
                        \.rawValue),
                    "description":
                        "fronted means a fresh listing shows it frontmost; unconfirmed means the switch was accepted and had not landed, or nothing could confirm it.",
                ],
                "revalidatedAt": [
                    "type": "string", "format": "date-time",
                ],
                "observedAt": [
                    "type": "string", "format": "date-time",
                ],
            ],
            "required": [
                "reference", "outcome", "revalidatedAt", "observedAt",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Bring a New Old World Guest Process to the Front",
            "description":
                "Brings one recently observed guest process forward. Takes the same opaque process reference as the quit tool, which the running NOW host re-lists and matches by full observed identity before the guest acts on the live process. The answer distinguishes a switch a fresh listing CONFIRMS from one the machine merely accepted — a process switch on this platform happens when the guest next yields, so accepted is not landed.",
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
                    variant("completed", "completed", receipt),
                    variant("refused", "refused", failure),
                    variant("unavailable", "unavailable", [
                        "type": "object",
                        "properties": [
                            "code": ["type": "string"],
                            "message": ["type": "string"],
                        ],
                        "required": ["code", "message"],
                        "additionalProperties": false,
                    ]),
                ],
            ],
            "annotations": [
                "readOnlyHint": false,
                /* Not destructive, and quit is: a front switch loses no
                   work and the person at the machine can undo it by
                   clicking a window. It is still not idempotent — asking
                   twice can answer `unconfirmed` then `fronted`, because
                   the second ask has had the yielded time the first did
                   not. */
                "destructiveHint": false,
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
              Set(arguments.keys) == ["reference"],
              let reference = arguments["reference"] as? String,
              AgentIntegrationQuitPolicy.isValidReference(reference)
        else {
            return .invalidArguments(
                "now_bring_to_front requires one current opaque process reference")
        }
        return .value(.init(
            await client.bringToFront(reference: reference)))
    }
}
