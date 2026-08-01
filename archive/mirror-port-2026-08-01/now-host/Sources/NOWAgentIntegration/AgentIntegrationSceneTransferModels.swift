import Foundation

/// What one staged scene transfer may cost this surface, stated once where
/// both the host that stages it and the face that fetches it read it.
///
/// A scene is Mirror's IR v1 document — semantic structure, not pixels — but
/// it is still not JSON that fits one 16 KiB local response: NOW's own
/// producer encodes several KB for a handful of windows before menus or
/// controls exist at all (contract/asyncapi.yaml, "THE SCENE FAMILY"). So the
/// bytes cross the local socket in pages, exactly as a capture's PNG does,
/// and the numbers below are the whole bound on that lane.
///
/// **What this surface deliberately does NOT have, unlike capture: an
/// abandon.** The contract states plainly that there is no scene bracket and
/// no `scene.cancel` — a scene transfer is short enough that cancelling it
/// costs more than finishing it. Reusing capture's three-shape design here
/// would invent a lane the guest has no way to honour.
public enum AgentIntegrationScenePolicy {
    /// The most JSON one staged scene may hold. Shared with capture's bound
    /// rather than measured separately: both are headroom for an unusually
    /// busy machine, not a target, and a scene over it is refused rather than
    /// truncated — half a JSON document does not parse, which the contract
    /// itself calls "the worst form of that lie".
    public static let maximumBytes = 4 * 1024 * 1024

    /// One page of the document. The same size the capture and upload lanes
    /// use, for the same reason: it is the largest chunk that leaves room for
    /// the rest of a 16 KiB response once base64 has grown it by a third.
    public static let pageBytes = 8 * 1024

    /// How long a staged scene stays fetchable. It exists only to be paged
    /// out by the call that made it, so this is a leak bound rather than a
    /// feature — the same reasoning capture's stage keeps.
    public static let stageLifetime: TimeInterval = 120

    /// Pages one answer may need, derived rather than typed so it cannot
    /// disagree with the two numbers above.
    public static var maximumPages: Int {
        (maximumBytes + pageBytes - 1) / pageBytes
    }
}

/// One staged scene's own facts — everything about the document except the
/// document.
///
/// Repeated on every page rather than sent once with the first, and for
/// capture's exact reason: it is how the fetching face notices that the
/// stage it started reading is not the one it is finishing.
public struct AgentIntegrationSceneFacts: Codable, Equatable, Sendable {
    /// Opaque, host-minted, and valid only for this connection. It names an
    /// observation, never a file.
    public let sceneID: UUID
    public let sessionID: UUID
    public let observedAt: Date
    /// The IR major this document declares. The same number `NOWSceneCodec`
    /// gates on before decoding — carried here so a caller can see what
    /// version answered, never so this surface can skip the gate.
    public let irVersion: Int
    /// The guest's own monotonic counter for this walk, when it sent one.
    public let seq: Int?
    /// The plane the scene was walked from ("peek" for NOW).
    public let source: String?
    /// How long the guest spent walking, by its own clock.
    public let walkMs: Int?
    /// How long the transfer took, as the host measured it.
    public let transferMs: Int
    /// The document's length in UTF-8 bytes. The face knows when it has all
    /// of it from this, rather than from a page that claims to be last.
    public let bytes: Int
    public let sha256: String
    public let mimeType: String

    public init(sceneID: UUID,
                sessionID: UUID,
                observedAt: Date,
                irVersion: Int,
                seq: Int? = nil,
                source: String? = nil,
                walkMs: Int? = nil,
                transferMs: Int,
                bytes: Int,
                sha256: String,
                mimeType: String = "application/json") {
        self.sceneID = sceneID
        self.sessionID = sessionID
        self.observedAt = observedAt
        self.irVersion = irVersion
        self.seq = seq
        self.source = source
        self.walkMs = walkMs
        self.transferMs = transferMs
        self.bytes = bytes
        self.sha256 = sha256
        self.mimeType = mimeType
    }
}

/// One page of a staged scene's document.
public struct AgentIntegrationScenePage: Codable, Equatable, Sendable {
    /// Byte offset into the UTF-8 document. Always a multiple of
    /// `AgentIntegrationScenePolicy.pageBytes`.
    public let offset: Int
    public let base64: String

    public init(offset: Int, base64: String) {
        self.offset = offset
        self.base64 = base64
    }
}

/// A staged scene and one page of it — the shape both the first call and
/// every continuation answer with.
public struct AgentIntegrationSceneChunk: Codable, Equatable, Sendable {
    public let facts: AgentIntegrationSceneFacts
    public let page: AgentIntegrationScenePage

    public init(facts: AgentIntegrationSceneFacts,
                page: AgentIntegrationScenePage) {
        self.facts = facts
        self.page = page
    }
}

public struct AgentIntegrationSceneFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// The guest could not produce a scene, or this side's own lane guard
    /// declined to ask. The guest's own sentence, which is written for a
    /// human because it also lands on the Mirror page.
    public static func guestFailed(_ message: String) -> Self {
        .init(code: "now-scene-failed", message: message)
    }

    public static let tooLarge = AgentIntegrationSceneFailure(
        code: "now-scene-too-large",
        message: "The scene document is larger than this surface carries")

    public static let stale = AgentIntegrationSceneFailure(
        code: "now-scene-stale",
        message: "No staged scene matches that reference on this session")

    /// The envelope named an IR major this host does not understand. The
    /// body is never parsed — the same "refuse before decode" order
    /// `NOWSceneCodec.decode` states for the reason this repeats it: a
    /// breaking change is by definition a document whose fields no longer
    /// mean what this code believes.
    public static func unsupportedMajor(_ major: Int) -> Self {
        .init(code: "now-scene-unsupported-major",
              message: "The guest's scene document is IR major \(major), "
                  + "which this host does not understand and will not "
                  + "decode")
    }

    public static func digestMismatch(expected: String,
                                      got: String) -> Self {
        .init(code: "now-scene-digest-mismatch",
              message: "The reassembled scene hashes to \(got), not "
                  + "\(expected)")
    }
}

/// What a scene call comes to.
///
/// Two outcomes rather than capture's three: there is no `abandoned`, and
/// deliberately so — see `AgentIntegrationScenePolicy`'s header.
public enum AgentIntegrationSceneResult: Equatable, Sendable {
    case captured(AgentIntegrationSceneChunk)
    case refused(AgentIntegrationSceneFailure)
    case unavailable(AgentIntegrationUnavailable)

    public static let hostUnavailable =
        AgentIntegrationSceneResult.unavailable(.host)
    public static let guestUnavailable =
        AgentIntegrationSceneResult.unavailable(.guest)
}

extension AgentIntegrationSceneResult: Codable {
    private enum Outcome: String, Codable {
        case captured
        case refused
        case unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case captured
        case refused
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .captured:
            self = .captured(try container.decode(
                AgentIntegrationSceneChunk.self, forKey: .captured))
        case .refused:
            self = .refused(try container.decode(
                AgentIntegrationSceneFailure.self, forKey: .refused))
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
        case .refused(let failure):
            try container.encode(Outcome.refused, forKey: .outcome)
            try container.encode(failure, forKey: .refused)
        case .unavailable(let unavailable):
            try container.encode(Outcome.unavailable, forKey: .outcome)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

/// What the MCP face hands its caller: the scene's facts, and the document
/// itself.
///
/// **Unlike a capture's bytes, the document travels IN the encodable part
/// rather than as an attachment.** A capture's PNG is opaque payload an
/// attachment renders per-face; a scene's JSON is the actual answer a caller
/// asked a structured question about, and `HostProjectionValue.Attachment`
/// has no raw-text case to carry it losslessly through every face regardless.
/// The cost is the one capture's own header warns about — the MCP face
/// serialises `structuredContent` into a text block as well, so a large scene
/// is carried twice — and it is accepted here rather than hidden, because the
/// alternative (an attachment type built for exactly one caller) is not yet
/// justified by a second one needing it.
public struct AgentIntegrationSceneAnswer: Codable, Equatable, Sendable {
    public let outcome: Outcome
    public let scene: AgentIntegrationSceneFacts?
    /// The reassembled document, as UTF-8 text — the guest's own JSON,
    /// undecoded by this surface beyond the major-version gate. A caller
    /// that wants structure parses it; this side does not re-decide what the
    /// guest's absent keys mean by parsing it first.
    public let document: String?
    public let refused: AgentIntegrationSceneFailure?
    public let unavailable: AgentIntegrationUnavailable?

    public enum Outcome: String, Codable, Equatable, Sendable {
        case captured
        case refused
        case unavailable
    }

    public init(outcome: Outcome,
                scene: AgentIntegrationSceneFacts? = nil,
                document: String? = nil,
                refused: AgentIntegrationSceneFailure? = nil,
                unavailable: AgentIntegrationUnavailable? = nil) {
        self.outcome = outcome
        self.scene = scene
        self.document = document
        self.refused = refused
        self.unavailable = unavailable
    }

    public static func captured(facts: AgentIntegrationSceneFacts,
                                document: String) -> Self {
        .init(outcome: .captured, scene: facts, document: document)
    }

    public static func refused(_ failure: AgentIntegrationSceneFailure)
        -> Self {
        .init(outcome: .refused, refused: failure)
    }

    public static func unavailable(_ value: AgentIntegrationUnavailable)
        -> Self {
        .init(outcome: .unavailable, unavailable: value)
    }
}
