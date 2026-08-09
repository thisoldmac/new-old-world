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
    /// The host-initiated pull — `file.get` → `file.begin` → bulk →
    /// `file.end`. Named here beside its sibling because it is the one
    /// requirement of `now_guest_files_download` that decides whether the
    /// bounded-download model has anything to stand on.
    public static let fileGet = "file.get"
    public static let filePut = "file.put"
    /// Ending the transfer in flight, in whichever direction it is going.
    ///
    /// The message name, and it is required on **both** guests rather than
    /// forked by ISA: the 68K guest's `cancel` verb is that machine's CONSOLE face
    /// on the same body (`wire68.c :: cancel_in_flight`, reached from both
    /// `handle_file_cancel` and `now68k_wire_cancel_transfer`), not a second
    /// mechanism a host would have to choose between. One capability, two
    /// guest answers, and the host sends the message either way.
    public static let fileCancel = "file.cancel"
    /// The four catalog mutations, named separately because the contract
    /// names them separately — and required TOGETHER by the one row that
    /// projects them: a guest that could trash and not restore would offer a
    /// deletion nothing can undo, which is not the capability.
    public static let fileMove = "file.move"
    public static let fileTrash = "file.trash"
    public static let fileRestore = "file.restore"
    public static let fileMkdir = "file.mkdir"
    /// The hardware-census family. The request half names it, as the
    /// contract does, and one row covers all fourteen probes: a probe is an
    /// ARGUMENT of `census.request`, never a capability the ledger could
    /// resolve — neither the family table nor the guest's `help` command
    /// table can hold a probe name, so requiring one would switch its
    /// projection off against every guest.
    public static let censusRequest = "census.request"
    /// The screen-capture family. A contract message name, not an alias:
    /// `capture.request` is what the host sends and both guests dispatch.
    public static let captureRequest = "capture.request"
    /* The live-stream bracket, named as THREE message families rather than
       one, and the reason is the opposite of the census's.

       A probe is an argument of `census.request` and could never be a
       requirement. These three are each a message the contract declares and a
       guest dispatches by name, so each resolves in the ledger on its own —
       and the row that projects the bracket requires all three, because a
       bracket you can open and cannot close is not a capability anyone should
       be handed. The conjunction is right here where it was wrong for the
       diagnostics: those three differ per guest, and these three arrived
       together, are served together, and are absent together. */

    /// Opens the bracket. Every frame's `capture.begin` carries the id this
    /// message names, which is what routes a frame to the live view instead of
    /// to the disk.
    public static let streamStart = "stream.start"
    /// Closes it. Always answered — `stream.stopped` is the stream's last
    /// word — which is why the projection can report a closed bracket rather
    /// than a hope.
    public static let streamStop = "stream.stop"
    /// Asks for a keyframe: the guest's next frame is sent whole. The
    /// contract calls this belt-and-suspenders against compositing drift, and
    /// on this surface it is load-bearing for a second reason — it is what
    /// makes "the frame after you asked" a thing a caller can be promised.
    public static let streamRefresh = "stream.refresh"
    public static let launchCommand = "launch"
    /// `launch`'s read-only twin: show one item in the guest's own Finder.
    /// A COMMAND rather than a message family — the ledger resolves it
    /// against the guest's `help` table, which is what makes the row
    /// PowerPC-only without anything here naming a guest.
    public static let revealCommand = "reveal"
    /// The whole-volume application sweep, measured on the machine. A
    /// COMMAND and not a message family, which is the whole reason
    /// `CatalogSearchProjection` needs no `familyPolicy` row: a command's
    /// availability comes off `help`, free, so nothing has to decide
    /// whether settling it is worth what it costs.
    public static let catsearchCommand = "catsearch"
    /// The machine's own account of itself — five domain groups and a
    /// snapshot, in one call. A COMMAND, so the ledger resolves it against
    /// the guest's `help` table exactly as it does `reveal`, `catsearch` and
    /// `tail`: that is what makes `now_machine_facts` PowerPC-only by
    /// derivation, with nothing on this side asking which guest answered.
    ///
    /// Note what it is NOT. There is no `gestalt.*` message family and this
    /// name must not grow one: the census family already carries the paged,
    /// per-probe reading of adjacent hardware facts, and a second family for
    /// the same machine would be two mechanisms for one question.
    public static let gestaltCommand = "gestalt"
    /// The PPC guest's qualified, path-free development environment.
    /// A COMMAND so availability follows from `help`; NOW-68K simply does
    /// not advertise it.
    public static let developmentCommand = "development"
    /// The guest's own log for this launch. A COMMAND, like `reveal` and for
    /// the same mechanical reason: the ledger resolves it against the
    /// guest's `help` table, which is what makes the row PowerPC-only
    /// without anything on this side naming a guest — the 68K guest's
    /// command table has no `tail` row, so it resolves `unavailable` there
    /// by derivation rather than by a fork in the code.
    ///
    /// Note what it is NOT: there is no `log.*` message family, and this
    /// name must not grow one by accident. The verb reads the application's
    /// own in-memory ring, and a family would be a second mechanism for one
    /// capability.
    public static let tailCommand = "tail"
    /// What this Mac can say about MIRROR — three resident extensions, an
    /// agent, and the port the file beside it names. A COMMAND, resolved
    /// against the guest's `help` like `gestalt` and `tail`, which is what
    /// makes it PowerPC-only by derivation rather than by a fork here.
    ///
    /// It exists because THIS SIDE CANNOT ANSWER IT. The host's Mirror page
    /// reads the Extensions FOLDER over the file plane and learns that a
    /// file exists; residency is a Gestalt answer, published at boot by the
    /// extension itself, and only the guest can ask. The two are not the
    /// same fact, and the difference — installed but not loaded — is the
    /// whole question somebody opens that page to settle.
    ///
    /// Note what it is NOT. There is no `mirror.*` message family and this
    /// name must not grow one: NOW installs none of Mirror, patches none of
    /// it, and speaks none of its wire. A family here would imply a
    /// relationship the product does not have.
    public static let mirrorCommand = "mirror"

    /* The three diagnostics, and they are named SEPARATELY on purpose —
       this is the whole crux of the capability that projects them.

       All three are COMMANDS, so the ledger resolves each against the
       guest's own `help` table, one at a time. That matters because their
       availability genuinely differs: `vprobe` is served by both guests,
       `shotdiag` by the 68K guest only, `putstat` by the Carbon guest only. A row's
       `requires` is a CONJUNCTION, so one row requiring all three would
       resolve `unavailable` against every guest that exists, for the life of
       every connection, in a sentence that reads as a fact about the
       Macintosh — the same wall `put` reported from the other side (see
       docs/mcp-coverage.md). Three names, required one per row, is what lets
       each be exactly as available as the machine makes it, with nothing on
       this side asking which guest answered. */

    /// What reading this machine's framebuffer costs, by access method.
    /// Both guests serve it, so its row is available on both — the only one
    /// of the trio that is.
    public static let vprobeCommand = "vprobe"
    /// Where a staged capture read from — the verb that found the 180c's
    /// 24-bit addressing defect. The 68K guest only, by derivation from `help`.
    ///
    /// Note what it is NOT: it is not a capture, and it must never be
    /// required by the capture row. It stages one down the real path, records
    /// where the walk read, and discards the file; nothing crosses the bulk
    /// channel. Its answer is about that walk and says nothing about whether
    /// `capture.request` works.
    public static let shotdiagCommand = "shotdiag"
    /// Where the last file the guest RECEIVED spent its time. The Carbon
    /// guest only, by derivation from `help`.
    public static let putstatCommand = "putstat"

    /* The act plane's three, folded here from `MirrorActModels.swift` when
       the rows were registered (2026-07-31).

       All three are COMMANDS, not message families, and the choice is the
       whole reason the act rows need no ISA check. A command's availability
       is resolved against the connected guest's own `help` table, so a guest
       whose table has no `winact` row reports the row unavailable BY
       DERIVATION — exactly how `reveal`, `catsearch`, `gestalt` and `tail`
       are PowerPC-only today with nothing on this side naming a guest.
       Mirror's act plane is PowerPC-only upstream; NOW expresses that as a
       fact the machine answers rather than as a branch we write.

       CORRECTED 2026-07-31: the paragraph that stood here said "NO GUEST
       SERVES THEM YET", and it was true for most of a day. The PowerPC guest
       now answers all five act commands and the reference layer beneath
       them, so `CommandRegistryTests.servedByNoGuestYet` is empty and these
       rows are available or not exactly as the connected machine's `help`
       table decides. The derivation did not change — only the answer. */

    /// Move, resize, zoom or close one addressed window, by answering the
    /// owning application's own `FindWindow`.
    public static let windowActCommand = "winact"
    /// Read the text of one addressed text element.
    public static let textGetCommand = "textget"
    /// Replace the text of one addressed text element.
    public static let textSetCommand = "textset"
    /// Act on one addressed control, by answering the owning application's
    /// own `TrackControl` with a part code.
    public static let controlActCommand = "ctlact"
    /// Perform one menu command, by answering the owning application's own
    /// `MenuSelect`. No menu is drawn and no tracking loop runs.
    public static let menuActCommand = "menuact"

    /// The five above, as a set — the act plane's whole requirement surface,
    /// for the tests that check no act row requires anything else.
    ///
    /// `elements` is deliberately NOT here. It mints the references the acts
    /// take, which makes it the act plane's precondition rather than one of
    /// its members: it changes nothing on the machine, it sits a consent tier
    /// below every row in this set, and a gate that asserts act-plane
    /// properties over it would be asserting them about an observation.
    public static let actPlane: Set<String> = [
        windowActCommand, textGetCommand, textSetCommand,
        controlActCommand, menuActCommand,
    ]

    /* The reference layer, declared and served 2026-07-31. `observe`,
       `handle`, `axtree` and `axsnap` are its other four doors and no host
       row projects them yet — they carry gap rows in docs/mcp-coverage.md
       rather than constants here, because a name in this namespace that no
       row requires is a name nothing checks. */

    /// Name one process's on-screen elements and MINT a reference for each.
    /// The same walk as `observe`, aimed by a process instead of a scope.
    public static let elementsCommand = "elements"

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
        fileGet, filePut, fileCancel, fileMove, fileTrash, fileRestore,
        fileMkdir, censusRequest, captureRequest, streamStart, streamStop,
        streamRefresh, launchCommand, revealCommand, catsearchCommand,
        gestaltCommand, developmentCommand, tailCommand, vprobeCommand,
        shotdiagCommand,
        putstatCommand, windowActCommand, textGetCommand, textSetCommand,
        controlActCommand, menuActCommand, elementsCommand, mirrorCommand,
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
