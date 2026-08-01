import CryptoKit
import Foundation

/// One picture of the connected Mac's screen, taken now.
///
/// The guest has served this throughout — `capture.request` on both ISAs,
/// spelled `screenshot` on the console — and no host face could ask for it
/// (docs/mcp-coverage.md, W1 #1). The app has had the affordance from the
/// beginning: the Screenshots page's **Capture** button and the menu bar's
/// **Screenshot Guest**. This row is the same capability arriving on the
/// agent face, and nothing about the picture is decided here.
///
/// ## Who absorbs the paging
///
/// This is the first capability on this surface whose answer is not JSON, and
/// there are two places bytes could be paged: the guest's chunked capture
/// transfer, and the 16 KiB local request/response cap between the companion
/// and the running host. **Both are absorbed below this row, and a caller
/// sees neither.** The guest's chunking is `GuestListener`'s job and always
/// was; the local cap is paged out inside `invoke` — one `requestGuestCapture`
/// and then as many `fetchGuestCapturePage` calls as the PNG needs, hashed at
/// the end against the digest the host declared with the first page.
///
/// That is deliberate, and it is the same call the sibling TBT project made
/// for its `screenshot` + `shotdata` pair: an agent asking for a screenshot
/// has no use for a pagination protocol, and one that has to reassemble
/// eleven base64 fragments will get it wrong once. The costs of hiding it,
/// stated rather than discovered: one tool call is now N+1 local round trips
/// (a 200 KB screen is 26), a caller cannot resume a partial fetch, and a
/// capture that fails halfway is reported as a failed capture rather than as
/// a fetch that can be retried.
///
/// ## What it does not do
///
/// It does not choose the depth from the human's panel selection, does not
/// keep the picture, and does not write it anywhere. The app's history, its
/// auto-save folder and its clipboard belong to the person at the machine;
/// a projection that filed into them would be putting an agent's call into
/// somebody's photo library.
public enum CaptureScreenProjection: HostProjection {
    public static let capability = HostCapabilityID("now_capture_screen")

    /* Only the request family. `capture.cancel` is used by the abandon mode
       and is deliberately NOT required: the 68K guest serves capture.request
       and not capture.cancel, and requiring it would make a capability both
       guests serve read as PowerPC-only — rule 4, degrade the ANSWER, not the
       message. The host settles an abandoned wait locally whether or not the
       guest implements the message (GuestListener.cancelCapture), so nothing
       here depends on the guest honouring it. */
    public static let requires =
        [AgentIntegrationCapabilityNames.captureRequest]

    /* The picture IS the answer handed back, so a caller reaches
       capture.request through this row. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.captureRequest]

    /* Two app-UI affordances, and the row names the panel's rather than the
       menu bar's because that is the one a person finds without knowing the
       feature exists. The menu item is QuickCapture.swift's `run()`. */
    /* Argument.all, not a second literal: the row already spells its two keys
       once for its own reads, and a set typed twice is a set that drifts. */
    public static let acceptedArguments: Set<String> = Argument.all

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ScreenshotsModuleView.swift",
                         symbol: "model.capture()"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves capture.request."

    /// The argument names, spelled once so the schema and the validation
    /// cannot drift into two vocabularies.
    private enum Argument {
        static let depth = "depth"
        static let abandon = "abandon"
        static let all: Set<String> = [depth, abandon]
    }

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Capture the New Old World Guest's Screen",
            "description":
                "Asks the classic Mac paired with the running NOW host for a picture of its screen now, and returns it as a PNG image with the measurements behind it. Read-only: it observes the screen and changes nothing on the machine. The capture crosses the wire in chunks and the local surface in pages; both are handled here, so one call returns one whole image. Pass abandon to release the connection's single transfer lane from a capture already in flight instead of starting one.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.depth: [
                        "type": "integer",
                        "enum": AgentIntegrationCapturePolicy.depths,
                        "description":
                            "Bits per pixel to ask the guest for; omitted means \(AgentIntegrationCapturePolicy.defaultDepth). Lower is dramatically cheaper on classic hardware — 1 is a legible monochrome screen in a few tens of kilobytes. The guest answers with the depth it actually produced.",
                    ],
                    Argument.abandon: [
                        "type": "boolean",
                        "description":
                            "Abandon the host's wait for a capture already in flight rather than starting one. Nothing else may be passed with it.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "outcome": [
                        "type": "string",
                        "enum": [
                            "captured", "abandoned", "refused", "unavailable",
                        ],
                    ],
                    "capture": captureSchema,
                    "abandoned": failureSchema,
                    "refused": failureSchema,
                    "unavailable": failureSchema,
                ],
                "required": ["outcome"],
                "additionalProperties": false,
            ],
            /* Read-only about the machine, and NOT idempotent: two calls a
               second apart are two different moments, which is the whole
               point of a screenshot. */
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private static var captureSchema: [String: Any] {
        [
            "type": "object",
            "description":
                "The picture's own facts. The image bytes are the result's image content block rather than a field here, so they are carried once instead of twice.",
            "properties": [
                "captureID": ["type": "string", "format": "uuid"],
                "sessionID": ["type": "string", "format": "uuid"],
                "capturedAt": ["type": "string", "format": "date-time"],
                "width": ["type": "integer", "minimum": 1],
                "height": ["type": "integer", "minimum": 1],
                "depth": [
                    "type": "integer",
                    "enum": AgentIntegrationCapturePolicy.depths,
                ],
                "transferMs": ["type": "integer", "minimum": 0],
                "wireBytes": ["type": "integer", "minimum": 0],
                "bytes": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum": AgentIntegrationCapturePolicy.maximumBytes,
                ],
                "sha256": ["type": "string"],
                "mimeType": ["type": "string", "enum": ["image/png"]],
            ],
            "required": [
                "captureID", "sessionID", "capturedAt", "width", "height",
                "depth", "transferMs", "wireBytes", "bytes", "sha256",
                "mimeType",
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
                    + "\(Argument.depth) and \(Argument.abandon)")
        }
        let unknown = Set(object.keys).subtracting(Argument.all)
        guard unknown.isEmpty else {
            return .invalidArguments(
                "\(capability.rawValue) does not take "
                    + unknown.sorted().joined(separator: ", "))
        }

        if let raw = object[Argument.abandon] {
            guard let abandon = raw as? Bool else {
                return .invalidArguments(
                    "\(Argument.abandon) must be a boolean")
            }
            guard abandon else {
                return .invalidArguments(
                    "\(Argument.abandon) is only meaningful as true; omit it "
                        + "to take a capture")
            }
            /* Refused rather than quietly ignored: "abandon this and also
               take one" is two intentions, and guessing which was meant is
               how a caller loses a screen it thought it asked for. */
            guard object[Argument.depth] == nil else {
                return .invalidArguments(
                    "\(Argument.abandon) cannot be combined with "
                        + Argument.depth)
            }
            return .value(.init(
                answer(for: await client.abandonGuestCapture())))
        }

        var depth: Int?
        if let raw = object[Argument.depth] {
            guard let value = raw as? Int,
                  AgentIntegrationCapturePolicy.isValidDepth(value) else {
                return .invalidArguments(
                    "\(Argument.depth) must be one of "
                        + AgentIntegrationCapturePolicy.depths
                            .map(String.init).joined(separator: ", "))
            }
            depth = value
        }
        return await capture(depth: depth, through: client)
    }

    /// Absent arguments are an empty object; anything that is not an object
    /// at all is a refusal. The same distinction every row here keeps.
    private static func emptyIfAbsent(
        _ arguments: HostProjectionArguments
    ) -> [String: Any]? {
        arguments.raw == nil ? [:] : nil
    }

    // MARK: - One call, N+1 local round trips

    private static func capture(
        depth: Int?,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        let first = await client.requestGuestCapture(
            depth: depth ?? AgentIntegrationCapturePolicy.defaultDepth)
        guard case .captured(let chunk) = first else {
            return .value(.init(answer(for: first)))
        }
        let image = chunk.image
        guard image.bytes <= AgentIntegrationCapturePolicy.maximumBytes else {
            return .value(.init(
                AgentIntegrationCaptureAnswer.refused(.tooLarge)))
        }

        var png = Data()
        var page: AgentIntegrationCapturePage? = chunk.page
        var pages = 0
        while let current = page {
            guard pages <= AgentIntegrationCapturePolicy.maximumPages else {
                return .value(.init(
                    AgentIntegrationCaptureAnswer.refused(.tooLarge)))
            }
            /* Offsets are checked here as well as at the host end. This side
               is assembling a picture from several answers, and an
               out-of-order page would produce a plausible-looking image of
               nothing — the one failure mode that does not announce itself. */
            guard current.offset == png.count,
                  let bytes = Data(base64Encoded: current.base64),
                  !bytes.isEmpty else {
                return .value(.init(
                    AgentIntegrationCaptureAnswer.refused(.stale)))
            }
            png.append(bytes)
            pages += 1
            guard png.count < image.bytes else { break }

            let next = await client.fetchGuestCapturePage(
                captureID: image.captureID, offset: png.count)
            guard case .captured(let continued) = next else {
                return .value(.init(answer(for: next)))
            }
            /* The stage re-identifies itself on every page, so a capture
               re-staged underneath this loop is caught rather than stitched
               into a picture of a moment that never existed. */
            guard continued.image == image else {
                return .value(.init(
                    AgentIntegrationCaptureAnswer.refused(.stale)))
            }
            page = continued.page
        }

        guard png.count == image.bytes else {
            return .value(.init(
                AgentIntegrationCaptureAnswer.refused(.stale)))
        }
        let digest = SHA256.hash(data: png)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == image.sha256 else {
            return .value(.init(AgentIntegrationCaptureAnswer.refused(
                .digestMismatch(expected: image.sha256, got: digest))))
        }
        return .value(.init(
            AgentIntegrationCaptureAnswer.captured(image),
            attachment: .image(bytes: png, mimeType: image.mimeType)))
    }

    /// The host's typed result, rendered for a caller. Nothing is re-decided:
    /// a refusal keeps the host's own code and sentence.
    private static func answer(for result: AgentIntegrationCaptureResult)
        -> AgentIntegrationCaptureAnswer {
        switch result {
        case .captured:
            /* Reached only when a page arrived where an outcome was
               expected — the two callers above both handle `captured`
               themselves. Reported as stale rather than as a picture,
               because one page is not one. */
            return .refused(.stale)
        case .abandoned(let failure):
            return .abandoned(failure)
        case .refused(let failure):
            return .refused(failure)
        case .unavailable(let unavailable):
            return .unavailable(.init(code: unavailable.code,
                                      message: unavailable.message))
        }
    }
}
