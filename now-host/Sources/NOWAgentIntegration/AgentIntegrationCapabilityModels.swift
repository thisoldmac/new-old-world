import Foundation

/// What the companion may say about a capability of the connected guest.
///
/// Three states, not two. `unproven` is the honest answer to "can this
/// guest do X" before anyone has asked it, and it is a different fact from
/// "no". Collapsing the two is how a report starts guessing — and the only
/// cheap way to guess is from the guest's identity, which is exactly what
/// this whole ledger exists to avoid. See docs/command-parity.md, "The MCP
/// is a client, not a face".
public enum AgentIntegrationCapabilityState:
    String, Codable, Equatable, Sendable {
    /// The guest answered a request in this capability.
    case available
    /// The guest refused a request in this capability, in typed form.
    case unavailable
    /// Nobody has asked this guest yet. Not a synonym for `unavailable`.
    case unproven
}

/// How a capability's state was established. A reader is entitled to know
/// whether an answer came from the machine or from a policy about probing.
public enum AgentIntegrationCapabilityEvidence:
    String, Codable, Equatable, Sendable {
    /// Named in the guest's own `help` table, which both guests serve.
    case commandTable
    /// Absent from a command table this session successfully read.
    case absentFromCommandTable
    /// A request in this family succeeded during ordinary tool use.
    case observedInUse
    /// A request in this family was refused during ordinary tool use.
    case refusedInUse
    /// This report sent a read-only request to settle the question.
    case probed
    /// Not probed: the smallest request in this family changes the guest.
    case notProbedMutating
    /// Not probed by default: settling it costs the guest real work.
    case notProbedCostly
    /// The guest never answered `help`, so no command table exists.
    case commandTableUnavailable
}

/// One message family's standing with the connected guest.
///
/// Message families are NOT in `help` — the command table cannot see them,
/// which is precisely how `ps` shipped wire-only here and went unnoticed
/// for a day. A family is therefore established by asking, and this record
/// carries the guest's own words when the answer was no.
public struct AgentIntegrationFamilyCapability:
    Codable, Equatable, Sendable {
    /// The contract's request message type, e.g. `process.list`.
    public let family: String
    public let state: AgentIntegrationCapabilityState
    public let evidence: AgentIntegrationCapabilityEvidence
    /// The guest's refusal code, when it refused. Its words, not ours.
    public let refusalCode: String?
    public let refusalMessage: String?
    public let observedAt: Date?

    public init(family: String,
                state: AgentIntegrationCapabilityState,
                evidence: AgentIntegrationCapabilityEvidence,
                refusalCode: String? = nil,
                refusalMessage: String? = nil,
                observedAt: Date? = nil) {
        self.family = family
        self.state = state
        self.evidence = evidence
        self.refusalCode = refusalCode
        self.refusalMessage = refusalMessage
        self.observedAt = observedAt
    }
}

/// One companion tool's standing against the connected guest.
///
/// `requires` is the whole derivation: a tool is exactly as available as
/// the capabilities it projects, and nothing about which guest is on the
/// other end enters into it.
public struct AgentIntegrationToolCapability:
    Codable, Equatable, Sendable {
    public let tool: String
    public let state: AgentIntegrationCapabilityState
    /// Command names and message families this tool cannot work without.
    public let requires: [String]
    /// The requirements that are currently `unavailable` or `unproven`.
    public let missing: [String]
    /// Written for the caller: why this state, in one sentence.
    public let reason: String

    public init(tool: String,
                state: AgentIntegrationCapabilityState,
                requires: [String],
                missing: [String],
                reason: String) {
        self.tool = tool
        self.state = state
        self.requires = requires
        self.missing = missing
        self.reason = reason
    }
}

/// The whole capability picture for one paired session.
public struct AgentIntegrationSessionCapabilities:
    Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let observedAt: Date
    /// The guest's own command names, from `help`. Nil when the guest did
    /// not answer `help` at all — which is itself a capability answer, and
    /// is reported rather than papered over with a default list.
    public let commandTable: [String]?
    public let commandTableEvidence: AgentIntegrationCapabilityEvidence
    public let families: [AgentIntegrationFamilyCapability]
    public let tools: [AgentIntegrationToolCapability]
    /// True when this call sent the costly catalog probe.
    public let probedCostly: Bool

    public init(sessionID: UUID,
                observedAt: Date,
                commandTable: [String]?,
                commandTableEvidence: AgentIntegrationCapabilityEvidence,
                families: [AgentIntegrationFamilyCapability],
                tools: [AgentIntegrationToolCapability],
                probedCostly: Bool) {
        self.sessionID = sessionID
        self.observedAt = observedAt
        self.commandTable = commandTable
        self.commandTableEvidence = commandTableEvidence
        self.families = families
        self.tools = tools
        self.probedCostly = probedCostly
    }
}

public enum AgentIntegrationSessionCapabilitiesResult:
    Equatable, Sendable {
    case available(AgentIntegrationSessionCapabilities)
    case unavailable(AgentIntegrationUnavailable)

    public static let guestUnavailable =
        AgentIntegrationSessionCapabilitiesResult.unavailable(.guest)
}

extension AgentIntegrationSessionCapabilitiesResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case available
        case capabilities
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .available) {
            self = .available(try container.decode(
                AgentIntegrationSessionCapabilities.self,
                forKey: .capabilities))
        } else {
            self = .unavailable(try container.decode(
                AgentIntegrationUnavailable.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let capabilities):
            try container.encode(true, forKey: .available)
            try container.encode(capabilities, forKey: .capabilities)
        case .unavailable(let unavailable):
            try container.encode(false, forKey: .available)
            try container.encode(unavailable, forKey: .unavailable)
        }
    }
}

/// The names this projection uses, in one place so the report, the tool
/// derivation and the tests cannot drift into three spellings.
public enum AgentIntegrationCapabilityNames {
    public static let processList = "process.list"
    public static let processQuit = "process.quit"
    /// The other drive verb of the same family. Named here for the reason
    /// the rest are: `GuestListener` records its observation under this
    /// string and `BringToFrontProjection` requires it, and those used to
    /// be one hand-typed literal and one constant.
    public static let processFront = "process.front"
    public static let softwareList = "software.list"
    public static let fileList = "file.list"
    public static let filePut = "file.put"
    /// The four catalog mutations, named separately because the contract
    /// names them separately — and required TOGETHER by the one row that
    /// projects them: a guest that could trash and not restore would offer a
    /// deletion nothing can undo, which is not the capability.
    public static let fileMove = "file.move"
    public static let fileTrash = "file.trash"
    public static let fileRestore = "file.restore"
    public static let fileMkdir = "file.mkdir"
    /// The screen-capture family. A contract message name, not an alias:
    /// `capture.request` is what the host sends and both guests dispatch.
    public static let captureRequest = "capture.request"
    public static let launchCommand = "launch"

    /// Every name above, as a set.
    ///
    /// It exists so a projection's `requires` can be checked against the
    /// declaration rather than against a second copy of it typed into a
    /// test — which is what `HostProjectionRegistryTests` used to hold, and
    /// what every new capability had to remember to edit.
    ///
    /// Swift cannot enumerate an enum's static lets, so this is written by
    /// hand; the point is that it is written *here*, beside the constant it
    /// lists, and not in a test target. Membership is also not the only
    /// check a requirement faces: `MCPCoverageTests`
    /// `testEveryRequirementResolvesToTheContract` resolves the same strings
    /// against `contract/asyncapi.yaml`, so a name that exists only in this
    /// set still fails somewhere.
    public static let all: Set<String> = [
        processList, processQuit, processFront, softwareList, fileList,
        filePut, fileMove, fileTrash, fileRestore, fileMkdir,
        captureRequest, launchCommand,
    ]

    /// Refusal codes that mean "this guest does not implement that", as
    /// opposed to "that failed". The 68K guest answers `not-implemented`
    /// to an unknown message type (now-guest-68k/src/core/wire68.c) and
    /// `unknown-command` to an unknown command; the contract allows both
    /// on either side. A timeout is deliberately NOT in this set — an
    /// unanswered request proves nothing about what a guest implements,
    /// and treating silence as a "no" is how a wedged MacTCP would get
    /// recorded as a missing feature.
    public static let refusalCodes: Set<String> = [
        "not-implemented", "unknown-command", "unknown-message",
        "unsupported",
    ]

    public static func isRefusal(_ code: String) -> Bool {
        refusalCodes.contains(code.lowercased())
    }
}
