import CryptoKit
import Foundation

/// The live-stream bracket, projected — **one capability with three
/// intentions**, closing the last three unnoticed gaps in
/// docs/mcp-coverage.md.
///
/// ## Why one row and not three
///
/// The gap table has three rows because the contract has three messages, and
/// a first reading says three messages means three capabilities. It does not.
/// `stream.stop` and `stream.refresh` both take the id `stream.start` minted
/// and mean nothing without it, so three rows would be one row and two that
/// are unusable alone — and a caller could reach for the second before the
/// first. That is the argument `now_capture_screen` already made for folding
/// take, page and abandon into one tool, and it is stronger here: those three
/// share a lane, and these three share a *bracket*.
///
/// The three availability rows would also have been identical. The
/// diagnostics trio is three rows precisely because `vprobe`, `shotdiag` and
/// `putstat` are served by different guests; these three arrived together, are
/// served by the same guest, and are absent from the same one.
///
/// ## What a caller gets that `now_capture_screen` does not give it
///
/// A picture that is already being taken. A capture costs the guest a whole
/// screen grab per call — measured at 0.5–0.6 s on the 1400c — while an open
/// bracket has the guest capturing continuously, so a frame is waiting rather
/// than starting. That is the whole reason an agent would open one.
///
/// And the reverse, which is the thing to know before opening one: **while a
/// stream runs, `capture.request` is refused** (contract,
/// `guestOffersCapture` — the stream owns the transfer lane). An agent that
/// opens a bracket has given up single captures until it closes it, so this
/// row is not a cheaper capture, it is a *different mode*, and one that has to
/// be left.
///
/// ## Read-only, and the one thing that annotation does not cover
///
/// `readOnlyHint` is true and it is honest: a stream observes the screen and
/// changes nothing on the machine, exactly as a capture does. That puts this
/// row at the Read Only consent tier, which is the tier derivation reading the
/// annotation rather than a separate declaration
/// (`HostCapabilityTierDerivation`).
///
/// **What the tier cannot express is duration**, and this is the row where
/// that matters: a single capture consenting machine grants one screen grab,
/// and the same consent here grants a bracket that keeps grabbing. The answer
/// is not to lie about `readOnlyHint` in order to buy a stricter tier — that
/// would corrupt the annotation agents actually read, to smuggle in a
/// distinction the two tiers do not have. The answer is that the bracket ends
/// itself when its opener stops watching, and that the person at the host can
/// end it at any moment from the page they watch it on. Both of those are
/// mechanisms rather than promises: `AgentIntegrationStreamControl` carries
/// the first and the Screenshots page carries the second.
public enum StreamScreenProjection: HostProjection {
    public static let capability = HostCapabilityID("now_stream_screen")

    /* All three, as a conjunction, and that is the right shape here for the
       reason it was the wrong one for the diagnostics: a bracket you can
       open and cannot close is not a capability to hand anybody, and a guest
       that serves one of these serves all three. `capture.request` is
       deliberately NOT among them — a frame is a capture transfer on the
       wire, but nothing here sends capture.request and a stream is refused
       exactly where it would. */
    public static let requires = [
        AgentIntegrationCapabilityNames.streamStart,
        AgentIntegrationCapabilityNames.streamStop,
        AgentIntegrationCapabilityNames.streamRefresh,
    ]

    /* All three again, and this is the rarer case where `exposes` equals
       `requires`: a caller directs each of the three messages by naming an
       intention, and none of them is consumed internally to compose an
       answer out of. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.streamStart,
        AgentIntegrationCapabilityNames.streamStop,
        AgentIntegrationCapabilityNames.streamRefresh,
    ]

    /* The Screenshots page's Start/Stop Streaming button. Named rather than
       the Refresh button beside it because it is the one that opens the
       bracket, and a distinctive symbol rather than `model.startStream()`
       for the reason `HostFaceReach.reached` records as the fifth rot mode:
       a symbol its file uses more than once proves less than it looks
       like. `toggleStream()` exists in exactly one place, the button. */
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ScreenshotsModuleView.swift",
                         symbol: "model.toggleStream()"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves stream.start, stream.stop and "
            + "stream.refresh."

    private enum Argument {
        static let intention = "intention"
        static let depth = "depth"
        static let minIntervalMs = "minIntervalMs"
        static let all: Set<String> = [intention, depth, minIntervalMs]
    }

    /// This row's key namespace, declared once and read by the dispatch.
    ///
    /// This capability and the argument gate were built on branches that
    /// never saw each other, and git merged them without a word — the gate
    /// touched no file this row lives in. What caught it is that
    /// `acceptedArguments` has **no default implementation**: a row that has
    /// not stated its namespace does not compile. A defaulted requirement
    /// would have merged green and shipped the one row on the surface whose
    /// unknown keys nobody refused.
    public static let acceptedArguments = Argument.all

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Stream the New Old World Guest's Screen",
            "description":
                "Opens, reads and closes a live view of the screen of the classic Mac paired with the running NOW host. Start opens the bracket and the machine begins capturing continuously; frame asks for the next whole frame and returns it as a PNG image; stop closes it. Read-only: it observes the screen and changes nothing on the machine. Two things to know before opening one. While a stream runs the single-capture tool is refused — the stream owns the machine's one transfer lane — so this is a different mode rather than a cheaper capture, and it has to be left. And the host ends a stream you opened if you stop calling for about a minute, because a stream nobody is reading still costs the Macintosh a screen grab a second.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.intention: [
                        "type": "string",
                        "enum": AgentIntegrationStreamIntention.allCases
                            .map(\.rawValue),
                        "description":
                            "start opens the bracket, frame returns the next whole frame off an open one, stop closes it. Only start takes the other two arguments.",
                    ],
                    Argument.depth: [
                        "type": "integer",
                        "enum": AgentIntegrationCapturePolicy.depths,
                        "description":
                            "Bits per pixel to stream at; omitted means \(AgentIntegrationCapturePolicy.defaultDepth). Lower is dramatically cheaper on classic hardware and matters far more here than for one capture, because the cost is paid per frame.",
                    ],
                    Argument.minIntervalMs: [
                        "type": "integer",
                        "minimum":
                            AgentIntegrationStreamPolicy.minimumIntervalMs,
                        "maximum":
                            AgentIntegrationStreamPolicy.maximumIntervalMs,
                        "description":
                            "Fewest milliseconds between frames the guest may produce; omitted means \(AgentIntegrationStreamPolicy.defaultMinIntervalMs). This is a ceiling on the machine's work, not on how often you may ask: you read one frame per call whatever it is set to, and a fast stream you read slowly is a Macintosh grabbing screens nobody looks at.",
                    ],
                ],
                "required": [Argument.intention],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "outcome": [
                        "type": "string",
                        "enum": AgentIntegrationStreamAnswer.Outcome
                            .allOutcomes,
                    ],
                    "stream": bracketSchema,
                    "frame": frameSchema,
                    "refused": failureSchema,
                    "unavailable": failureSchema,
                ],
                "required": ["outcome"],
                "additionalProperties": false,
            ],
            /* Read-only about the machine and NOT idempotent, for capture's
               reason and one more: two frames a second apart are two
               moments, and `start` called twice is an open bracket and then
               a refusal. */
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private static var bracketSchema: [String: Any] {
        [
            "type": "object",
            "description":
                "The host's own bracket. Everything here is a fact about this host's lane rather than about the Macintosh — whether a stream is open, who opened it, and when it lapses if nobody calls.",
            "properties": [
                "streamID": ["type": "integer"],
                "sessionID": ["type": "string", "format": "uuid"],
                "state": ["type": "string", "enum": ["open", "closed"]],
                "origin": [
                    "type": "string",
                    "enum": AgentIntegrationStreamOrigin.allCases.map(
                        \.rawValue),
                    "description":
                        "Who opened it: person is somebody at the host's own screen, guest is the Macintosh asking, agent is a caller of this tool.",
                ],
                "openedAt": ["type": "string", "format": "date-time"],
                "depth": [
                    "type": "integer",
                    "enum": AgentIntegrationCapturePolicy.depths,
                ],
                "minIntervalMs": ["type": "integer"],
                "leaseExpiresAt": [
                    "type": "string",
                    "format": "date-time",
                    "description":
                        "When the host ends this bracket unless you call again. Present only on a stream this surface opened; a person's live view has no lease and never gets one.",
                ],
                "closedReason": ["type": "string"],
            ],
            "required": [
                "streamID", "sessionID", "state", "origin", "openedAt",
                "depth", "minIntervalMs",
            ],
            "additionalProperties": false,
        ]
    }

    private static var frameSchema: [String: Any] {
        [
            "type": "object",
            "description":
                "The frame's own facts. The image bytes are the result's image content block rather than a field here, so they are carried once instead of twice. It is a whole screen: the host composites the guest's deltas and interlaced fields before anything reaches here.",
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
        guard let object = arguments.object else {
            return .invalidArguments(
                "\(capability.rawValue) takes an object naming one of "
                    + AgentIntegrationStreamIntention.allCases
                        .map(\.rawValue).joined(separator: ", "))
        }
        let unknown = Set(object.keys).subtracting(Argument.all)
        guard unknown.isEmpty else {
            return .invalidArguments(
                "\(capability.rawValue) does not take "
                    + unknown.sorted().joined(separator: ", "))
        }
        guard let raw = object[Argument.intention] as? String,
              let intention = AgentIntegrationStreamIntention(rawValue: raw)
        else {
            return .invalidArguments(
                "\(Argument.intention) must be one of "
                    + AgentIntegrationStreamIntention.allCases
                        .map(\.rawValue).joined(separator: ", "))
        }

        switch intention {
        case .start:
            return await open(object, through: client)
        case .frame, .stop:
            /* Refused rather than ignored, for the reason `abandon` refuses
               a depth beside it: a caller that sent tuning with a stop
               believes it is tuning something, and serving the stop
               silently would confirm a belief that is wrong. */
            let extra = Set(object.keys).subtracting([Argument.intention])
            let opening = AgentIntegrationStreamIntention.start.rawValue
            guard extra.isEmpty else {
                return .invalidArguments(
                    "\(raw) takes no "
                        + extra.sorted().joined(separator: ", ")
                        + " — only \(opening) opens a bracket, so only it "
                        + "is tuned")
            }
            if intention == .stop {
                return .value(.init(answer(for: await client.stopGuestStream(),
                                           closing: true)))
            }
            return await readFrame(through: client)
        }
    }

    private static func open(
        _ object: [String: Any],
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        var depth = AgentIntegrationCapturePolicy.defaultDepth
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
        /* The default is applied HERE rather than left absent on the wire.
           The contract lets `minIntervalMs` be omitted and reads that as
           "the guest paces itself" — about 15 fps, backing off to 4 while
           frames stay empty — which is right for a person watching a live
           view and wrong for a caller that reads one frame per call. A
           surface with no unbounded setting cannot hand one out by
           accident. */
        var interval = AgentIntegrationStreamPolicy.defaultMinIntervalMs
        if let raw = object[Argument.minIntervalMs] {
            guard let value = raw as? Int,
                  AgentIntegrationStreamPolicy.isValidInterval(value) else {
                return .invalidArguments(
                    "\(Argument.minIntervalMs) must be between "
                        + "\(AgentIntegrationStreamPolicy.minimumIntervalMs)"
                        + " and "
                        + "\(AgentIntegrationStreamPolicy.maximumIntervalMs)")
            }
            interval = value
        }
        return .value(.init(answer(
            for: await client.startGuestStream(
                depth: depth, minIntervalMs: interval),
            closing: false)))
    }

    // MARK: - One call, N+1 local round trips

    /// The same paging `CaptureScreenProjection` does, for the same reason and
    /// with the same costs: one tool call is N+1 local round trips, a caller
    /// cannot resume a partial fetch, and a fetch that fails halfway is
    /// reported as a failed frame rather than as a retryable read. Hidden
    /// here for the same reason too — an agent asking to see a screen has no
    /// use for a pagination protocol.
    private static func readFrame(
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        let first = await client.nextGuestStreamFrame()
        guard case .frame(let opening) = first else {
            return .value(.init(answer(for: first, closing: false)))
        }
        let image = opening.chunk.image
        guard image.bytes <= AgentIntegrationCapturePolicy.maximumBytes else {
            return .value(.init(AgentIntegrationStreamAnswer.refused(
                AgentIntegrationStreamFailure.tooLarge)))
        }

        var png = Data()
        var page: AgentIntegrationCapturePage? = opening.chunk.page
        var pages = 0
        var bracket = opening.bracket
        while let current = page {
            guard pages <= AgentIntegrationCapturePolicy.maximumPages else {
                return .value(.init(AgentIntegrationStreamAnswer.refused(
                    AgentIntegrationStreamFailure.tooLarge)))
            }
            guard current.offset == png.count,
                  let bytes = Data(base64Encoded: current.base64),
                  !bytes.isEmpty else {
                return .value(.init(AgentIntegrationStreamAnswer.refused(
                    AgentIntegrationStreamFailure.staleFrame)))
            }
            png.append(bytes)
            pages += 1
            guard png.count < image.bytes else { break }

            let next = await client.fetchGuestStreamFramePage(
                frameID: image.captureID, offset: png.count)
            guard case .frame(let continued) = next else {
                return .value(.init(answer(for: next, closing: false)))
            }
            /* The frame re-identifies itself on every page, so a frame
               re-staged underneath this loop — which on a live stream is a
               second away rather than hypothetical — is caught rather than
               stitched into a picture of a moment that never existed. */
            guard continued.chunk.image == image else {
                return .value(.init(AgentIntegrationStreamAnswer.refused(
                    AgentIntegrationStreamFailure.staleFrame)))
            }
            /* The BRACKET is taken from the last page rather than the
               first: a stream that closed while its frame was being read
               out is exactly the fact a caller needs, and reporting the
               opening state would tell it the stream is still running. */
            bracket = continued.bracket
            page = continued.chunk.page
        }

        guard png.count == image.bytes else {
            return .value(.init(AgentIntegrationStreamAnswer.refused(
                AgentIntegrationStreamFailure.staleFrame)))
        }
        let digest = SHA256.hash(data: png)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == image.sha256 else {
            return .value(.init(AgentIntegrationStreamAnswer.refused(
                AgentIntegrationStreamFailure.digestMismatch(
                    expected: image.sha256, got: digest))))
        }
        return .value(.init(
            AgentIntegrationStreamAnswer.frame(bracket, image),
            attachment: .image(bytes: png, mimeType: image.mimeType)))
    }

    /// The host's typed result, rendered for a caller. Nothing is re-decided:
    /// a refusal keeps the host's own code and sentence.
    ///
    /// `closing` is what tells an opened bracket from a closed one, and it
    /// comes from the intention rather than from the bracket's `state`: a
    /// `start` that raced a stop would report a closed bracket, and the
    /// caller still needs to know which call it made.
    private static func answer(for result: AgentIntegrationStreamResult,
                               closing: Bool)
        -> AgentIntegrationStreamAnswer {
        switch result {
        case .bracket(let bracket):
            return closing ? .closed(bracket) : .opened(bracket)
        case .frame(let frame):
            /* Reached only when a page arrived where a bracket was
               expected — the frame path above handles `frame` itself.
               Reported as stale rather than as a picture, because one page
               is not one. */
            _ = frame
            return .refused(AgentIntegrationStreamFailure.staleFrame)
        case .refused(let failure):
            return .refused(failure)
        case .unavailable(let unavailable):
            return .unavailable(unavailable)
        }
    }
}

extension AgentIntegrationStreamAnswer.Outcome {
    /// The published enum, derived rather than typed a second time into the
    /// schema — the same collapse this arc has made four times already.
    static var allOutcomes: [String] {
        [opened, closed, frame, refused, unavailable].map(\.rawValue)
    }
}
