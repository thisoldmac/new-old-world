import Foundation

/// What one screen capture may cost this surface, stated once where both the
/// host that stages a capture and the face that fetches it read it.
///
/// A capture is the first thing on this surface whose answer is **not JSON**.
/// Everything else here is a bounded record or a small chunk a caller
/// supplied; a screen is tens to hundreds of kilobytes of PNG, and the local
/// request/response cap is 16 KiB
/// (`AgentIntegrationLocalProtocol.maximumMessageBytes`). So the bytes cross
/// the local socket in pages, and the numbers below are the whole bound on
/// that lane.
public enum AgentIntegrationCapturePolicy {
    /// The most PNG one staged capture may hold. A 640×480 screen is a few
    /// tens of KB at 1-bit and a few hundred at 16-bit; this is headroom for
    /// a large deep screen, not a target, and a capture over it is refused
    /// rather than truncated — half a picture is worse than none.
    public static let maximumBytes = 4 * 1024 * 1024

    /// One page of PNG. The same 8 KiB the upload lane uses, for the same
    /// reason: it is the largest chunk that leaves room for the rest of a
    /// 16 KiB response once base64 has grown it by a third.
    public static let pageBytes = 8 * 1024

    /// base64 of `pageBytes`, exactly: ceil(8192 / 3) * 4.
    public static let pageBase64Scalars = 10_924

    /// How long a staged capture stays fetchable. It exists only to be
    /// paged out by the call that made it, so this is a leak bound rather
    /// than a feature: a caller that walked away must not leave a screen of
    /// somebody's Mac in host memory.
    public static let stageLifetime: TimeInterval = 120

    /// The depths the guest's capture path implements (contract,
    /// `capture.request`). A closed set, checked before the request leaves,
    /// because "9-bit" reaches the guest as a Toolbox failure that reads
    /// like a broken machine.
    public static let depths = [1, 2, 4, 8, 16, 32]

    /// The depth a caller who did not choose one gets. Deliberately a
    /// constant rather than the human's current panel selection: the panel
    /// is host state, and reading it would make one caller's answer depend
    /// on what somebody else had clicked.
    public static let defaultDepth = 8

    /// Pages one answer may need, derived rather than typed so it cannot
    /// disagree with the two numbers above.
    public static var maximumPages: Int {
        (maximumBytes + pageBytes - 1) / pageBytes
    }

    public static func isValidDepth(_ depth: Int) -> Bool {
        depths.contains(depth)
    }
}

/// One staged capture's own facts — everything about the picture except the
/// picture.
///
/// It is repeated on every page rather than sent once with the first, and
/// that is not redundancy: it is how the fetching face notices that the
/// stage it started reading is not the one it is finishing. A capture id
/// that changed mid-fetch means another call re-staged underneath, and
/// silently stitching two screens together would produce an image of a
/// moment that never existed.
public struct AgentIntegrationCaptureImage: Codable, Equatable, Sendable {
    /// Opaque, host-minted, and valid only for this connection. It names an
    /// observation, never a file: nothing on this surface can be turned back
    /// into a path.
    public let captureID: UUID
    public let sessionID: UUID
    public let capturedAt: Date
    public let width: Int
    public let height: Int
    /// Bits per pixel as the guest produced it, which may not be the depth
    /// asked for — the guest answers with what its screen actually is.
    public let depth: Int
    /// How long the transfer took, as the host measured it.
    public let transferMs: Int
    /// What the picture cost on the wire, before the host re-encoded it.
    /// Kept beside `bytes` because the ratio is the interesting number and
    /// deriving it needs both.
    public let wireBytes: Int
    /// The PNG's length. The face knows when it has all of it from this,
    /// rather than from a page that claims to be last.
    public let bytes: Int
    public let sha256: String
    public let mimeType: String

    public init(captureID: UUID,
                sessionID: UUID,
                capturedAt: Date,
                width: Int,
                height: Int,
                depth: Int,
                transferMs: Int,
                wireBytes: Int,
                bytes: Int,
                sha256: String,
                mimeType: String = "image/png") {
        self.captureID = captureID
        self.sessionID = sessionID
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.depth = depth
        self.transferMs = transferMs
        self.wireBytes = wireBytes
        self.bytes = bytes
        self.sha256 = sha256
        self.mimeType = mimeType
    }
}

/// One page of a staged capture's PNG.
public struct AgentIntegrationCapturePage: Codable, Equatable, Sendable {
    /// Byte offset into the PNG. Always a multiple of
    /// `AgentIntegrationCapturePolicy.pageBytes`.
    public let offset: Int
    public let base64: String

    public init(offset: Int, base64: String) {
        self.offset = offset
        self.base64 = base64
    }
}

/// A staged capture and one page of it — the shape both the first call and
/// every continuation answer with.
public struct AgentIntegrationCaptureChunk: Codable, Equatable, Sendable {
    public let image: AgentIntegrationCaptureImage
    public let page: AgentIntegrationCapturePage

    public init(image: AgentIntegrationCaptureImage,
                page: AgentIntegrationCapturePage) {
        self.image = image
        self.page = page
    }
}

public struct AgentIntegrationCaptureFailure:
    Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// The guest could not produce or the host could not decode a capture.
    /// The guest's own sentence, which is written for a human because it
    /// also lands in the Screenshots panel.
    public static func guestFailed(_ message: String) -> Self {
        .init(code: "now-capture-failed", message: message)
    }

    public static let tooLarge = AgentIntegrationCaptureFailure(
        code: "now-capture-too-large",
        message: "The capture is larger than this surface carries")

    public static let stale = AgentIntegrationCaptureFailure(
        code: "now-capture-stale",
        message: "No staged capture matches that reference on this session")

    public static let cancelled = AgentIntegrationCaptureFailure(
        code: "now-capture-abandoned",
        message: "The capture in flight was abandoned")

    public static let nothingInFlight = AgentIntegrationCaptureFailure(
        code: "now-capture-nothing-in-flight",
        message: "No capture was in flight to abandon")

    public static let busy = AgentIntegrationCaptureFailure(
        code: "now-capture-busy",
        message:
            "The connection's one transfer lane is already carrying a capture, "
            + "stream or file")

    public static func digestMismatch(expected: String,
                                      got: String) -> Self {
        .init(code: "now-capture-digest-mismatch",
              message: "The reassembled capture hashes to \(got), not "
                  + "\(expected)")
    }
}

/// What a capture call comes to.
///
/// `abandoned` is a first-class outcome rather than a failure: abandoning a
/// capture in flight is a thing a caller asks for on purpose, and reporting
/// it as an error would make the honest answer look like a fault.
public enum AgentIntegrationCaptureResult: Equatable, Sendable {
    case captured(AgentIntegrationCaptureChunk)
    case abandoned(AgentIntegrationCaptureFailure)
    case refused(AgentIntegrationCaptureFailure)
    case unavailable(AgentIntegrationUnavailable)

    public static let hostUnavailable =
        AgentIntegrationCaptureResult.unavailable(.host)
    public static let guestUnavailable =
        AgentIntegrationCaptureResult.unavailable(.guest)
}

extension AgentIntegrationCaptureResult: Codable {
    private enum Outcome: String, Codable {
        case captured
        case abandoned
        case refused
        case unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case captured
        case abandoned
        case refused
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .captured:
            self = .captured(try container.decode(
                AgentIntegrationCaptureChunk.self, forKey: .captured))
        case .abandoned:
            self = .abandoned(try container.decode(
                AgentIntegrationCaptureFailure.self, forKey: .abandoned))
        case .refused:
            self = .refused(try container.decode(
                AgentIntegrationCaptureFailure.self, forKey: .refused))
        case .unavailable:
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .captured(let chunk):
            try container.encode(Outcome.captured, forKey: .outcome)
            try container.encode(chunk, forKey: .captured)
        case .abandoned(let failure):
            try container.encode(Outcome.abandoned, forKey: .outcome)
            try container.encode(failure, forKey: .abandoned)
        case .refused(let failure):
            try container.encode(Outcome.refused, forKey: .outcome)
            try container.encode(failure, forKey: .refused)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

/// What the MCP face hands its caller: the capture's facts, and nothing of
/// the paging that produced them.
///
/// **The bytes are deliberately not in here.** They travel once, as the
/// result's image attachment, because a structured field would be rendered
/// twice — the MCP face serialises `structuredContent` into a text block as
/// well — and a 300 KB screen would arrive as 600 KB of base64 in an agent's
/// context. The digest and the length are here so a caller can check what it
/// received against what the host says it sent.
public struct AgentIntegrationCaptureAnswer: Codable, Equatable, Sendable {
    public let outcome: Outcome
    public let capture: AgentIntegrationCaptureImage?
    public let abandoned: AgentIntegrationCaptureFailure?
    public let refused: AgentIntegrationCaptureFailure?
    public let unavailable: AgentIntegrationUnavailable?

    public enum Outcome: String, Codable, Equatable, Sendable {
        case captured
        case abandoned
        case refused
        case unavailable
    }

    public init(outcome: Outcome,
                capture: AgentIntegrationCaptureImage? = nil,
                abandoned: AgentIntegrationCaptureFailure? = nil,
                refused: AgentIntegrationCaptureFailure? = nil,
                unavailable: AgentIntegrationUnavailable? = nil) {
        self.outcome = outcome
        self.capture = capture
        self.abandoned = abandoned
        self.refused = refused
        self.unavailable = unavailable
    }

    public static func captured(_ image: AgentIntegrationCaptureImage)
        -> Self {
        .init(outcome: .captured, capture: image)
    }

    public static func abandoned(_ failure: AgentIntegrationCaptureFailure)
        -> Self {
        .init(outcome: .abandoned, abandoned: failure)
    }

    public static func refused(_ failure: AgentIntegrationCaptureFailure)
        -> Self {
        .init(outcome: .refused, refused: failure)
    }

    public static func unavailable(_ value: AgentIntegrationUnavailable)
        -> Self {
        .init(outcome: .unavailable, unavailable: value)
    }
}
