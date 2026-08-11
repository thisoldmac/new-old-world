import Foundation

/// The shapes of the **live-stream bracket**, projected.
///
/// A stream is the one capability on this surface that is not a bounded call:
/// `stream.start` opens a bracket, `stream.stopped` closes it, and in between
/// the guest sends frames as ordinary capture transfers (contract,
/// `guestOffersCapture`). Everything here follows from that one sentence —
/// a frame reuses `AgentIntegrationCaptureImage` and its paging verbatim,
/// because a frame *is* a capture, and inventing a second picture type for the
/// same bytes would be two vocabularies for one thing.
///
/// What is NOT here, and is the reason this file exists at all: an owner. The
/// bracket is host-owned by contract — both origins share one path — so who
/// opened it is a fact this side has to carry, and a bracket whose opener has
/// gone is a lane held against somebody's Macintosh for nothing.

/// What one agent-held bracket may cost, stated once where the projection
/// that bounds it and the control that ends it both read it.
public enum AgentIntegrationStreamPolicy {
    /// The frame-rate ceiling this surface sends when the caller names none,
    /// as `minIntervalMs`.
    ///
    /// **Never absent, and that is the whole point of the constant.** The
    /// contract says absent or 0 leaves the pace to the guest, which runs its
    /// own floor of about 15 fps — and an empty frame carries no pixels, so
    /// the wire does not pace one either. That is right for a person watching
    /// a live view and wrong for an agent, which reads one frame per call: a
    /// 1400c would spend fifteen screen grabs a second producing frames
    /// nothing looks at. One a second is the default here, and a caller that
    /// wants a faster stream says so.
    public static let defaultMinIntervalMs = 1_000

    /// The narrowest and widest pace a caller may ask for. The floor is not 0:
    /// this surface has no unbounded setting to hand out, for the reason
    /// above.
    public static let minimumIntervalMs = 100
    public static let maximumIntervalMs = 60_000

    /// How long an agent-opened bracket survives without a call from the
    /// agent that opened it.
    ///
    /// **Shorter than `AgentCompanionActivity.activeWindow` on purpose.** Two
    /// minutes is the right window for "is a companion attached", because an
    /// idle companion costs nothing. An idle *stream* costs a classic Mac a
    /// screen grab a second for as long as it stays open, so the question here
    /// is not "is anything attached" but "is anybody reading this", and the
    /// honest answer after a minute of silence is no.
    public static let lease: TimeInterval = 60

    /// How often the host asks whether an agent-held bracket should still be
    /// open. Cheap — a `kill(pid, 0)` and a clock comparison — and the
    /// interval only bounds how long a dead agent's stream outlives it.
    public static let ownerCheckInterval: TimeInterval = 5

    /// How long the host waits for the frame it asked for before answering
    /// that none arrived. Generous against a 1400c at 1-bit and far short of
    /// anything a caller would read as a hang.
    public static let frameTimeout: TimeInterval = 20

    public static func isValidInterval(_ ms: Int) -> Bool {
        (minimumIntervalMs...maximumIntervalMs).contains(ms)
    }
}

/// **Who opened the bracket that is open.**
///
/// Three origins because the contract has three: a person clicks Start
/// Streaming, a guest asks for one (`stream.request`), and — now — an agent
/// calls for one. The host answers all three the same way and down one path;
/// this records which of them asked, because the two questions that follow
/// from an open bracket both need it. *May this call have the lane?* is
/// answered by whether anyone holds it. *Should this bracket still be open?*
/// can only be answered against whoever opened it.
public enum AgentIntegrationStreamOrigin:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// The person at the host, from the Screenshots page.
    case person
    /// The guest asked, and the host accepted (`stream.request`).
    case guest
    /// An agent, through this surface.
    case agent
}

/// One bracket, as a caller sees it.
///
/// It reports the host's own lane rather than anything about the Macintosh,
/// and that is deliberate and is the limit: whether a stream is open is a fact
/// about this host's bracket, and the projection layer may report its own
/// addressing and bounds. Nothing here is an answer about the screen — that
/// only ever arrives as a frame.
public struct AgentIntegrationStreamBracket: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case open
        case closed
    }

    /// The host's own stream id, which every frame's `capture.begin` carries.
    /// Opaque to a caller: it names this bracket and nothing else, and it is
    /// not a handle anything else on this surface accepts.
    public let streamID: Int
    public let sessionID: UUID
    public let state: State
    public let origin: AgentIntegrationStreamOrigin
    public let openedAt: Date
    /// The depth asked for. The guest answers with the depth it actually
    /// produced, and that is on the frame rather than here.
    public let depth: Int
    /// The frame-rate ceiling sent with `stream.start`, in milliseconds
    /// between frame starts. Never nil on this surface — see
    /// `AgentIntegrationStreamPolicy.defaultMinIntervalMs`.
    public let minIntervalMs: Int
    /// When this bracket ends unless the agent that opened it calls again.
    /// Nil for a bracket this surface did not open, which is exactly the
    /// point: a person's stream has no lease and never gets one.
    public let leaseExpiresAt: Date?
    /// Why a closed bracket closed, in whoever's words ended it.
    public let closedReason: String?

    public init(streamID: Int,
                sessionID: UUID,
                state: State,
                origin: AgentIntegrationStreamOrigin,
                openedAt: Date,
                depth: Int,
                minIntervalMs: Int,
                leaseExpiresAt: Date? = nil,
                closedReason: String? = nil) {
        self.streamID = streamID
        self.sessionID = sessionID
        self.state = state
        self.origin = origin
        self.openedAt = openedAt
        self.depth = depth
        self.minIntervalMs = minIntervalMs
        self.leaseExpiresAt = leaseExpiresAt
        self.closedReason = closedReason
    }
}

/// One frame off an open bracket, and the bracket it came from.
///
/// The picture reuses the capture types whole. A frame that arrived on the
/// stream lane has already been composited by the session — deltas patched
/// into the canvas, an interlaced field woven into the rows beneath it — so
/// what reaches here is a complete screen, never a band of one.
public struct AgentIntegrationStreamFrame: Codable, Equatable, Sendable {
    public let bracket: AgentIntegrationStreamBracket
    public let chunk: AgentIntegrationCaptureChunk

    public init(bracket: AgentIntegrationStreamBracket,
                chunk: AgentIntegrationCaptureChunk) {
        self.bracket = bracket
        self.chunk = chunk
    }
}

public enum AgentIntegrationStreamFailure {
    /// Somebody else has the lane. The sentence names WHO, because "busy" on
    /// its own sends an agent to look for a fault in a host that is working —
    /// and because a person streaming their own Mac is not a fault at all.
    public static func busy(_ origin: AgentIntegrationStreamOrigin)
        -> AgentIntegrationProjectionFailure {
        let holder: String
        switch origin {
        case .person:
            holder = "the person at this host is streaming this Mac's screen"
        case .guest:
            holder = "the Mac itself asked for the stream that is running"
        case .agent:
            holder = "an agent already holds the stream"
        }
        return .init(
            code: "now-stream-busy",
            message: "The connection's one transfer lane is taken: \(holder).")
    }

    public static let notOpen = AgentIntegrationProjectionFailure(
        code: "now-stream-not-open",
        message: "No live stream is open on this connection")

    /// Asked for a frame and none arrived inside the bound. It says nothing
    /// about whether the machine is well: a guest whose screen has not changed
    /// still sends frames, so silence here is the absence of an answer rather
    /// than a still picture.
    public static let noFrame = AgentIntegrationProjectionFailure(
        code: "now-stream-no-frame",
        message: "The stream produced no frame before the host stopped "
            + "waiting")

    public static let staleFrame = AgentIntegrationProjectionFailure(
        code: "now-stream-frame-stale",
        message: "No staged frame matches that reference on this stream")

    public static let tooLarge = AgentIntegrationProjectionFailure(
        code: "now-stream-frame-too-large",
        message: "The frame is larger than this surface carries")

    public static let encodeFailed = AgentIntegrationProjectionFailure(
        code: "now-stream-frame-encode-failed",
        message: "The frame could not be encoded as PNG")

    public static func digestMismatch(expected: String, got: String)
        -> AgentIntegrationProjectionFailure {
        .init(code: "now-stream-frame-digest-mismatch",
              message: "The reassembled frame hashes to \(got), not "
                  + "\(expected)")
    }

    public static func intervalOutOfRange(_ ms: Int)
        -> AgentIntegrationProjectionFailure {
        .init(code: "now-stream-interval-invalid",
              message: "\(ms) ms is outside the "
                  + "\(AgentIntegrationStreamPolicy.minimumIntervalMs)–"
                  + "\(AgentIntegrationStreamPolicy.maximumIntervalMs) ms "
                  + "this surface will ask a guest to pace at")
    }

    /// The host asked the guest to stop and the guest never acknowledged.
    /// The bracket is closed here regardless — `GuestListener.stopStream`
    /// self-heals — so this is reported on a CLOSED bracket rather than as a
    /// refusal.
    public static let unacknowledgedStop = "no answer to stop"
}

/// What one stream call comes to.
///
/// Four cases, and the split between the first two is what a caller acts on:
/// a bracket is the lane's own state and a frame is a picture. Neither is
/// derivable from the other, and folding them into one "it worked" would make
/// a caller parse an optional image to find out whether it got one.
public enum AgentIntegrationStreamResult: Equatable, Sendable {
    case bracket(AgentIntegrationStreamBracket)
    case frame(AgentIntegrationStreamFrame)
    case refused(AgentIntegrationProjectionFailure)
    case unavailable(AgentIntegrationUnavailable)

    public static let hostUnavailable =
        AgentIntegrationStreamResult.unavailable(.host)
    public static let guestUnavailable =
        AgentIntegrationStreamResult.unavailable(.guest)
}

extension AgentIntegrationStreamResult: Codable {
    private enum Outcome: String, Codable {
        case bracket
        case frame
        case refused
        case unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case bracket
        case frame
        case refused
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .bracket:
            self = .bracket(try container.decode(
                AgentIntegrationStreamBracket.self, forKey: .bracket))
        case .frame:
            self = .frame(try container.decode(
                AgentIntegrationStreamFrame.self, forKey: .frame))
        case .refused:
            self = .refused(try container.decode(
                AgentIntegrationProjectionFailure.self, forKey: .refused))
        case .unavailable:
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bracket(let bracket):
            try container.encode(Outcome.bracket, forKey: .outcome)
            try container.encode(bracket, forKey: .bracket)
        case .frame(let frame):
            try container.encode(Outcome.frame, forKey: .outcome)
            try container.encode(frame, forKey: .frame)
        case .refused(let failure):
            try container.encode(Outcome.refused, forKey: .outcome)
            try container.encode(failure, forKey: .refused)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

/// Which of the bracket's three intentions one call carries.
///
/// One operation and three intentions, for capture's reason rather than as a
/// convenience: `stop` and `frame` are meaningless except against the `start`
/// that opened the bracket, and splitting them into three operations would let
/// a caller ask for a frame of a stream nothing opened.
public enum AgentIntegrationStreamIntention:
    String, Codable, Equatable, Sendable, CaseIterable {
    /// `stream.start` — open the bracket.
    case start
    /// `stream.refresh`, then the frame it produces.
    case frame
    /// `stream.stop` — close it.
    case stop
}

/// What the MCP face hands its caller.
///
/// The picture is deliberately absent, exactly as it is from
/// `AgentIntegrationCaptureAnswer` and for the same reason: the MCP face
/// renders a result twice, so a frame in a structured field would arrive as
/// base64 in an agent's context window as well as as an image. The bytes
/// travel once, as the result's attachment.
public struct AgentIntegrationStreamAnswer: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        /// A bracket this call opened.
        case opened
        /// A bracket this call closed.
        case closed
        /// One frame off an open bracket.
        case frame
        case refused
        case unavailable
    }

    public let outcome: Outcome
    public let stream: AgentIntegrationStreamBracket?
    /// The frame's own facts — the same record a capture answers with.
    public let frame: AgentIntegrationCaptureImage?
    public let refused: AgentIntegrationProjectionFailure?
    public let unavailable: AgentIntegrationUnavailable?

    public init(outcome: Outcome,
                stream: AgentIntegrationStreamBracket? = nil,
                frame: AgentIntegrationCaptureImage? = nil,
                refused: AgentIntegrationProjectionFailure? = nil,
                unavailable: AgentIntegrationUnavailable? = nil) {
        self.outcome = outcome
        self.stream = stream
        self.frame = frame
        self.refused = refused
        self.unavailable = unavailable
    }

    public static func opened(_ bracket: AgentIntegrationStreamBracket)
        -> Self {
        .init(outcome: .opened, stream: bracket)
    }

    public static func closed(_ bracket: AgentIntegrationStreamBracket)
        -> Self {
        .init(outcome: .closed, stream: bracket)
    }

    public static func frame(_ bracket: AgentIntegrationStreamBracket,
                             _ image: AgentIntegrationCaptureImage) -> Self {
        .init(outcome: .frame, stream: bracket, frame: image)
    }

    public static func refused(_ failure: AgentIntegrationProjectionFailure)
        -> Self {
        .init(outcome: .refused, refused: failure)
    }

    public static func unavailable(_ value: AgentIntegrationUnavailable)
        -> Self {
        .init(outcome: .unavailable, unavailable: value)
    }
}
