import Foundation

/// Name **one process's on-screen elements**, and mint the reference that
/// addresses each one.
///
/// This is the row every act row on this surface was waiting for. `winact`,
/// `ctlact`, `textget` and `textset` all take an opaque reference and none of
/// them can be reached without one, deliberately — and until 2026-07-31 there
/// was nothing on any face that produced one, which made the act plane a
/// published surface with no legal argument. This is the door onto the walk
/// that mints them.
///
/// **It is an observation, not an act.** It changes nothing, its
/// `readOnlyHint` puts it in the `readOnly` consent tier beside
/// `now_text_get`, and it is registered with the observations rather than
/// with the drive verbs. That is also why it is NOT in
/// `MirrorActProjections.rows`: the properties that group asserts are about
/// the act plane — one dispatch vocabulary, one target-free refusal, one
/// dispatch-only receipt — and none of them is a claim about a walk.
///
/// **Its answer is a tree, not a row array.** Most guest answers on this
/// surface are rows a person reads; this one is navigated and then addressed,
/// so which control sits in which window of which process is the whole
/// question a caller is asking. Flattening it would destroy the containment
/// that makes a reference mean anything.
///
/// **The default is a default for the WALK and never for an act.** Omitting
/// the process observes the frontmost application, which is safe here for the
/// exact reason a "frontmost" spelling is refused one row over: an
/// observation that looked at the wrong application wastes a call, where an
/// act that addressed the wrong one rides the user's own press. Nothing
/// downstream of this can express "whatever is frontmost", and this row is
/// what makes that refusal affordable.
///
/// **Two limits stated rather than hidden.** NOW's own process binds and
/// walks to nothing — a Carbon application's window records are not where a
/// classic walk reads — and a document window's text handle is not
/// discoverable from a foreign walk, so such a window carries no text
/// reference. Both arrive as facts in the answer (`bind`, and an absent
/// `text`) rather than as silence.
public enum ObserveElementsProjection: HostProjection {
    public static let capability = HostCapabilityID("now_observe_elements")

    /* A command, resolved against the connected guest's own `help` table —
       the same derivation that makes `reveal` and `gestalt` PowerPC-only
       without anything here naming a guest. `elements` and not `observe`:
       this row aims the walk by process, which is what a caller who is about
       to act on something has. */
    public static let requires = [
        AgentIntegrationCapabilityNames.elementsCommand,
    ]

    /* The caller directs the walk and receives its whole answer, references
       included, which is what exposure means. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.elementsCommand,
    ]

    /* Two keys, and they are one argument: both halves of a process serial
       number, or neither. The pair rule is enforced in
       `AgentIntegrationProcessSerial.decode`, because a call sending one
       half meant to name a process and must not be answered about a
       different one. */
    public static let acceptedArguments: Set<String> = [
        "serialHi", "serialLo",
    ]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "No NOW pane shows a guest application's elements yet. "
                + "This row's answer is a tree of opaque references, which "
                + "is exactly the thing a person cannot read and a pane "
                + "would have to render as the windows and controls it "
                + "names — the scene view. Rule 3 is owed and not waived: "
                + "the affordance lands with that view, which is also what "
                + "gives the act rows something for a person to click ON."),
        /* Registered 2026-07-31, in the same edit that folded its
           requirement name and gave it a row in docs/mcp-coverage.md. */
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the elements command."

    public static var operationDescriptor: NOWOperationDescriptor {
        let bounds: [String: Any] = [
            "type": "object",
            "properties": [
                "left": ["type": "integer"],
                "top": ["type": "integer"],
                "right": ["type": "integer"],
                "bottom": ["type": "integer"],
            ],
            "required": ["left", "top", "right", "bottom"],
            "additionalProperties": false,
        ]
        let control: [String: Any] = [
            "type": "object",
            "properties": [
                "ref": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.elementReferencePattern,
                    "description":
                        "The opaque reference this control is addressed by. now_control_act takes it; nothing else can produce one.",
                ],
                "title": ["type": "string"],
                "occurrence": [
                    "type": "integer",
                    "description":
                        "Which of the identically-titled controls in this window this is, counting from the front. Two OK buttons are told apart by nothing else a caller can read.",
                ],
                "visible": ["type": "boolean"],
                "enabled": ["type": "boolean"],
                "bounds": bounds,
                "value": ["type": "integer"],
                "min": ["type": "integer"],
                "max": ["type": "integer"],
            ],
            "required": [
                "ref", "title", "occurrence", "visible", "enabled",
                "bounds", "value", "min", "max",
            ],
            "additionalProperties": false,
        ]
        let text: [String: Any] = [
            "type": "object",
            "properties": [
                "ref": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.elementReferencePattern,
                    "description":
                        "A TEXT element's reference: now_text_get and now_text_set take it, and now_control_act refuses it.",
                ],
                "length": ["type": "integer"],
            ],
            "required": ["ref", "length"],
            "additionalProperties": false,
        ]
        let window: [String: Any] = [
            "type": "object",
            "properties": [
                "ref": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.windowReferencePattern,
                    "description":
                        "The opaque reference this window is addressed by. now_window_act takes it.",
                ],
                "title": ["type": "string"],
                "occurrence": ["type": "integer"],
                "z": [
                    "type": "integer",
                    "description":
                        "Its position in the window list, front first.",
                ],
                "visible": ["type": "boolean"],
                "kind": ["type": "integer"],
                "bounds": bounds,
                "text": text,
                "controls": ["type": "array", "items": control],
            ],
            "required": [
                "ref", "title", "occurrence", "z", "visible", "kind",
                "bounds", "controls",
            ],
            "additionalProperties": false,
        ]
        let process: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "signature": ["type": "string"],
                "serialHi": ["type": "integer"],
                "serialLo": ["type": "integer"],
                "front": ["type": "boolean"],
                "bind": [
                    "type": "string",
                    "description":
                        "Why this process contributed no tree, in one word — so an empty windows array is never mistaken for an application with no windows. ok, no-process, no-plane, no-anchor, ambiguous, mismatch, unreadable. New Old World's own process always answers with no tree: a Carbon application's window records are not where a classic walk reads.",
                ],
                "stampTicks": [
                    "type": "integer",
                    "description":
                        "The TickCount at which this slice of the walk was taken, by the machine that took it.",
                ],
                "windows": ["type": "array", "items": window],
            ],
            "required": [
                "name", "signature", "serialHi", "serialLo", "front",
                "bind", "stampTicks", "windows",
            ],
            "additionalProperties": false,
        ]
        let observation: [String: Any] = [
            "type": "object",
            "properties": [
                "scope": ["type": "string"],
                "count": ["type": "integer"],
                "truncated": [
                    "type": "boolean",
                    "description":
                        "A fact about this REPLY, not about the machine: the walk saw more than it could send. A reader that cannot tell a short tree from a clipped one has been told nothing useful.",
                ],
                "live": [
                    "type": "integer",
                    "description":
                        "How many references are currently resolvable on the machine — the real bound on how much of this walk stays addressable. A reference that has aged out of the bounded table reads exactly like one whose window closed, and both are true.",
                ],
                "processes": ["type": "array", "items": process],
            ],
            "required": [
                "scope", "count", "truncated", "live", "processes",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Observe One New Old World Guest Application's Elements",
            "description":
                "Targeted direct observation. First read now_semantic_ui_snapshot for desktop and application context. Do not call this in parallel with that snapshot: read its coverage and content before deciding whether retained state is incomplete. Call this only after retained state proves incomplete or a direct action requires a fresh opaque reference. Walks one guest application's windows, controls and text fields and MINTS the opaque reference that addresses each one. Nothing else on this surface produces a reference, and every direct act — now_window_act, now_control_act, now_text_get, now_text_set — requires one, so this is the call that makes any of them reachable. Omitting the process observes the frontmost application; that is a default for the WALK and never for an act, and nothing downstream can say \"whatever is frontmost\". The answer is a tree rather than a list, dated by the machine, and says whether it was clipped and how much of it is still resolvable. Nothing is clicked or simulated.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "serialHi": [
                        "type": "integer",
                        "description":
                            "High half of the process serial number to observe, as an earlier observation or now_list_processes reports it. Omit both halves for the frontmost application.",
                    ],
                    "serialLo": [
                        "type": "integer",
                        "description":
                            "Low half of the same process serial number. Sent together with serialHi or not at all — half a serial number names nothing, and a call carrying one half is refused rather than answered about the frontmost.",
                    ],
                ],
                "required": [],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", observation),
                    variant("refused", "refused",
                            HostProjectionSchema.unavailableFailure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            /* The shared read-only fragment, which is also what puts this row
               in the readOnly consent tier — one tier below every act that
               consumes its answer. A machine whose owner agreed to be read
               and not driven can be observed, and every reference the
               observation mints is then refused by the acts above it, which
               is the line these tiers exist to draw. */
            "annotations": HostProjectionSchema.readOnlyAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        switch AgentIntegrationProcessSerial.decode(
            arguments.object ?? [:], tool: capability) {
        case .failure(let refusal):
            return .invalidArguments(refusal.text)
        case .success(let process):
            return .value(.init(
                await client.observeElements(process: process)))
        }
    }
}
