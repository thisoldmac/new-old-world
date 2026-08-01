import CryptoKit
import Foundation

/// One Mirror IR walk of the connected Mac's screen, now — semantic
/// structure (windows, controls, menus, the desktop), not pixels.
///
/// The guest has served this since M4/M5 of the mirror integration plan —
/// `scene.request` on the wire, decoded and version-gated on the host side by
/// `NOWSceneCodec` — and no host face could ask for it until this row
/// (docs/mcp-coverage.md, the `scene.request` gap). The app has had the
/// affordance from the beginning: the Mirror page's own Start Mirror button,
/// which asks for a scene immediately and then keeps asking. This row is the
/// same capability arriving on the agent face.
///
/// ## Who absorbs the paging, and who does not decode
///
/// Shaped after `CaptureScreenProjection`, which absorbed the same two
/// things a first non-JSON — or here, non-fitting-JSON — answer needs: the
/// guest's own bulk transfer, and the 16 KiB cap between the companion and
/// the running host. **Both are absorbed below this row.** What is
/// deliberately NOT absorbed here is a structural decode: this side gates
/// only the IR **major** — the same "refuse before decode" order
/// `NOWSceneCodec.decode` states — and pages the guest's raw JSON through
/// untouched. A caller that wants structure parses it; re-deciding what the
/// guest's absent keys mean by decoding into a stricter Swift model here
/// would risk the exact crash class a real captured scene once produced
/// against MirrorKit's Codable types before that model learned the right
/// defaults.
///
/// ## Two shapes, not capture's three
///
/// There is no abandon. The contract states plainly that a scene transfer is
/// short enough that cancelling it costs more than finishing it — there is
/// no `scene.cancel` on the wire to fall back on, so this row does not invent
/// a local-only "stop waiting" the guest has no way to honour.
///
/// ## What it does not do
///
/// It does not choose the guest's transfer tuning (chunk size, pace) — those
/// are the same fixed defaults every caller gets, exactly as capture's depth
/// default is a policy constant rather than a caller's dial into guest
/// internals. It does not join the content plane or the folder-items walk
/// the app's own page composes after a scene lands: those are separate,
/// fetch-on-ask round trips with their own refusal shapes, and folding them
/// in here would make one row answer for three different questions.
public enum SceneProjection: HostProjection {
    public static let capability = HostCapabilityID("now_scene")

    public static let requires =
        [AgentIntegrationCapabilityNames.sceneRequest]
    public static let exposes =
        [AgentIntegrationCapabilityNames.sceneRequest]

    public static let acceptedArguments: Set<String> = Argument.all

    /// **The app-UI call site FOLLOWED its affordance, 2026-08-01.** This
    /// row shipped naming `model.fetchScene` — the Mirror page's Fetch
    /// button — and 27de200 reduced that page's controls to Start / Stop
    /// plus a config area, per the maintainer's decision. The capability did
    /// not leave the app: `startSession()` arms content and asks for a scene
    /// on the press, before the loop's first tick. What left was the spelling
    /// the row was pointing at, and the row went on claiming a symbol its
    /// file no longer contained until `HostFaceParityTests` said so.
    ///
    /// So this names Start Mirror's own call site, per `HostFaceReach`:
    /// the thing a person's click reaches, not the function it calls.
    /// `model.startSession` appears once in that file — the button — so
    /// deleting the button fails this, which is the whole point of the row.
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "MirrorModuleView.swift",
                         symbol: "model.startSession"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves scene.request."

    /// The argument name, spelled once so the schema and the validation
    /// cannot drift into two vocabularies.
    private enum Argument {
        static let staleAfterMs = "staleAfterMs"
        static let all: Set<String> = [staleAfterMs]
    }

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Read the New Old World Guest's Scene",
            "description":
                "Asks the classic Mac paired with the running NOW host to walk its own screen and describe it structurally — windows, their controls, the menu bar, the desktop — as Mirror's IR v1 JSON document. Read-only: it observes the machine and changes nothing on it. The document crosses the wire and the local surface in pages; both are handled here, so one call returns the whole thing as a JSON string for the caller to parse. An unknown IR major is refused rather than guessed at.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.staleAfterMs: [
                        "type": "integer",
                        "minimum": 0,
                        "description":
                            "How old an anchor sample may be, in milliseconds, and still be reported clean; an older one is reported stale on the affected process rather than dropped or refused. Omitted or 0 disables the age gate, which is the guest's own default.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "outcome": [
                        "type": "string",
                        "enum": ["captured", "refused", "unavailable"],
                    ],
                    "scene": sceneSchema,
                    "document": [
                        "type": "string",
                        "description":
                            "The guest's own JSON document, UTF-8 text, undecoded by this surface beyond the IR major gate.",
                    ],
                    "refused": failureSchema,
                    "unavailable": failureSchema,
                ],
                "required": ["outcome"],
                "additionalProperties": false,
            ],
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                /* Not idempotent, for capture's exact reason: two calls a
                   moment apart are two different moments on the machine. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private static var sceneSchema: [String: Any] {
        [
            "type": "object",
            "description":
                "The scene's own facts. The document is carried once, in the result's own document field, rather than twice.",
            "properties": [
                "sceneID": ["type": "string", "format": "uuid"],
                "sessionID": ["type": "string", "format": "uuid"],
                "observedAt": ["type": "string", "format": "date-time"],
                "irVersion": ["type": "integer", "minimum": 1],
                "seq": ["type": "integer"],
                "source": ["type": "string"],
                "walkMs": ["type": "integer", "minimum": 0],
                "transferMs": ["type": "integer", "minimum": 0],
                "bytes": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum": AgentIntegrationScenePolicy.maximumBytes,
                ],
                "sha256": ["type": "string"],
                "mimeType": ["type": "string", "enum": ["application/json"]],
            ],
            "required": [
                "sceneID", "sessionID", "observedAt", "irVersion",
                "transferMs", "bytes", "sha256", "mimeType",
            ],
            "additionalProperties": false,
        ]
    }

    private static var failureSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "code": ["type": "string"],
                "message": ["type": "string"],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let object = arguments.object ?? emptyIfAbsent(arguments)
        else {
            return .invalidArguments(
                "\(capability.rawValue) takes an object with optional "
                    + "\(Argument.staleAfterMs)")
        }
        let unknown = Set(object.keys).subtracting(Argument.all)
        guard unknown.isEmpty else {
            return .invalidArguments(
                "\(capability.rawValue) does not take "
                    + unknown.sorted().joined(separator: ", "))
        }

        var staleAfterMs: Int?
        if let raw = object[Argument.staleAfterMs] {
            guard let value = raw as? Int, value >= 0 else {
                return .invalidArguments(
                    "\(Argument.staleAfterMs) must be a non-negative "
                        + "integer of milliseconds")
            }
            staleAfterMs = value
        }
        return await scene(staleAfterMs: staleAfterMs, through: client)
    }

    /// Absent arguments are an empty object; anything that is not an object
    /// at all is a refusal. The same distinction every row here keeps.
    private static func emptyIfAbsent(
        _ arguments: HostProjectionArguments
    ) -> [String: Any]? {
        arguments.raw == nil ? [:] : nil
    }

    // MARK: - One call, N+1 local round trips

    private static func scene(
        staleAfterMs: Int?,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        let first = await client.requestGuestScene(
            staleAfterMs: staleAfterMs)
        guard case .captured(let chunk) = first else {
            return .value(.init(answer(for: first)))
        }
        let facts = chunk.facts
        guard facts.bytes <= AgentIntegrationScenePolicy.maximumBytes else {
            return .value(.init(
                AgentIntegrationSceneAnswer.refused(.tooLarge)))
        }

        var document = Data()
        var page: AgentIntegrationScenePage? = chunk.page
        var pages = 0
        while let current = page {
            guard pages <= AgentIntegrationScenePolicy.maximumPages else {
                return .value(.init(
                    AgentIntegrationSceneAnswer.refused(.tooLarge)))
            }
            /* Offsets are checked here as well as at the host end, for the
               reason capture's own loop states: this side is assembling a
               document from several answers, and an out-of-order page would
               produce a plausible-looking result of nothing. */
            guard current.offset == document.count,
                  let bytes = Data(base64Encoded: current.base64),
                  !bytes.isEmpty else {
                return .value(.init(
                    AgentIntegrationSceneAnswer.refused(.stale)))
            }
            document.append(bytes)
            pages += 1
            guard document.count < facts.bytes else { break }

            let next = await client.fetchGuestScenePage(
                sceneID: facts.sceneID, offset: document.count)
            guard case .captured(let continued) = next else {
                return .value(.init(answer(for: next)))
            }
            /* The stage re-identifies itself on every page, so a scene
               re-staged underneath this loop is caught rather than stitched
               into a document of a moment that never existed. */
            guard continued.facts == facts else {
                return .value(.init(
                    AgentIntegrationSceneAnswer.refused(.stale)))
            }
            page = continued.page
        }

        guard document.count == facts.bytes else {
            return .value(.init(
                AgentIntegrationSceneAnswer.refused(.stale)))
        }
        let digest = SHA256.hash(data: document)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == facts.sha256 else {
            return .value(.init(AgentIntegrationSceneAnswer.refused(
                .digestMismatch(expected: facts.sha256, got: digest))))
        }
        return .value(.init(AgentIntegrationSceneAnswer.captured(
            facts: facts, document: String(decoding: document, as: UTF8.self))))
    }

    /// The host's typed result, rendered for a caller. Nothing is
    /// re-decided: a refusal keeps the host's own code and sentence.
    private static func answer(for result: AgentIntegrationSceneResult)
        -> AgentIntegrationSceneAnswer {
        switch result {
        case .captured:
            /* Reached only when a page arrived where an outcome was
               expected — the two callers above both handle `captured`
               themselves. Reported as stale rather than as a document,
               because one page is not one. */
            return .refused(.stale)
        case .refused(let failure):
            return .refused(failure)
        case .unavailable(let unavailable):
            return .unavailable(.init(code: unavailable.code,
                                      message: unavailable.message))
        }
    }
}
