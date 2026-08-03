import Foundation
/* For AgentIntegrationGuestAccess — hello.agent decodes straight into the
   contract's own vocabulary rather than a String this layer hands on for
   somebody else to interpret. One definition, in the module that already
   owns the agent-facing models. */
import NOWAgentIntegration

/// Control-channel messages from contract/asyncapi.yaml. One JSON object per
/// control frame, discriminated by `type`.
enum Contract {
    /// x-contract-revision from contract/asyncapi.yaml. Unequal => refuse.
    static let revision = 1
    static let defaultChunk = 8192
}

enum ControlMessage: Equatable, Sendable {
    case hello(Hello)
    case refuse(Refuse)
    case ping(id: Int)
    case pong(id: Int)
    case bye(Bye)
    case error(ErrorMessage)
    case commandRequest(CommandRequest)
    case commandResult(CommandResult)
    case execRequest(ExecRequest)
    case execOutput(ExecOutput)
    case execResult(ExecResult)
    case execCancel(ExecCancel)
    case execInput(ExecInput)
    case censusRequest(CensusRequest)
    case censusReport(CensusReport)
    case fileList(FileList)
    case fileListing(FileListing)
    case fileGet(FileGet)
    case fileOffer(FileOffer)
    case fileAccept(FileAccept)
    case fileDone(FileDone)
    case fileProgress(FileProgress)
    case fileRefuse(FileRefuse)
    case fileMove(FileMove)
    case fileTrash(FileTrash)
    case fileRestore(FileRestore)
    case fileMkdir(FileMkdir)
    case fileResult(FileResult)
    case fileBegin(FileBegin)
    case fileEnd(FileEnd)
    case fileCancel(FileCancel)
    case streamRequest(StreamRequest)
    case streamStart(StreamStart)
    case streamStop(StreamStop)
    case streamRefresh(StreamRefresh)
    case streamStopped(StreamStopped)
    case captureOffer(CaptureOffer)
    case captureAccept(CaptureAccept)
    case captureRefuse(CaptureRefuse)
    case captureRequest(CaptureRequest)
    case captureCancel(CaptureCancel)
    case captureBegin(CaptureBegin)
    case captureEnd(CaptureEnd)
    case sceneRequest(SceneRequest)
    case sceneBegin(SceneBegin)
    case sceneEnd(SceneEnd)
    case processList(ProcessList)
    case processListing(ProcessListing)
    case softwareList(SoftwareList)
    case softwareListing(SoftwareListing)
    case processFront(ProcessFront)
    case processQuit(ProcessQuit)
    case processShot(ProcessShot)
    case processResult(ProcessResult)
    case agentAccess(AgentAccess)
    case cloudServices(CloudServices)
    case cloudReport(CloudReport)
    case cloudList(CloudList)
    case cloudListing(CloudListing)
    case cloudDetail(CloudDetail)
    case cloudCard(CloudCard)
    case cloudGet(CloudGet)
    case cloudRefuse(CloudRefuse)
}

// MARK: - The cloud family

/* The guest asking about this Mac's iCloud. One direction by
   definition — the subject is the modern machine's cloud — so unlike
   the file family none of these has a "host asks" reading. Strings in
   the answers are converted BEFORE sending (MacRoman-expressible,
   composed): the modern machine is the only side that can spell both
   alphabets. */

struct CloudServices: Codable, Equatable, Sendable {
    var id: Int
}

struct CloudServiceEntry: Codable, Equatable, Sendable, Identifiable {
    var service: String
    var label: String
    /// serving | off | no-access | unavailable — reported even when not
    /// serving, so the guest's dropdown can say WHY a thing is missing.
    var state: String
    var detail: String?

    var id: String { service }
}

struct CloudReport: Codable, Equatable, Sendable {
    var id: Int
    var services: [CloudServiceEntry]
}

struct CloudList: Codable, Equatable, Sendable {
    var id: Int
    var service: String
    var cursor: Int?
}

struct CloudEntry: Codable, Equatable, Sendable, Identifiable {
    /// Opaque responder identity — what detail and get take back. Not a
    /// path, and not promised stable beyond the connection.
    var item: String
    var title: String
    var subtitle: String?
    /// What a cloud.get's offer would carry, so a person can decline a
    /// 40 MB original from an 800 MB disk before the offer exists.
    var bytes: Int?
    /// Classic Mac epoch: seconds since 1904-01-01.
    var modified: Int?

    var id: String { item }
}

struct CloudListing: Codable, Equatable, Sendable {
    var id: Int
    var service: String
    var entries: [CloudEntry]
    var more: Bool
    var cursor: Int?
}

struct CloudDetail: Codable, Equatable, Sendable {
    var id: Int
    var service: String
    var item: String
}

struct CloudCard: Codable, Equatable, Sendable {
    var id: Int
    var service: String
    var item: String
    /// [label, value] pairs in display order — the census row
    /// discipline: the host decides what is worth saying, the guest
    /// only draws it.
    var rows: [[String]]
}

struct CloudGet: Codable, Equatable, Sendable {
    var id: Int
    var service: String
    var item: String
}

struct CloudRefuse: Codable, Equatable, Sendable {
    var id: Int
    var code: String
    var reason: String?
}

struct Hello: Codable, Equatable, Sendable {
    var contract: Int
    var side: String
    var version: String
    /// Opaque build identity — a string that differs between two builds of
    /// the same `version`. Nil means the sender does not report one, which
    /// says nothing about the build; it is never filled in from `version`,
    /// because a version equal across two builds is the failure this exists
    /// for.
    var build: String? = nil
    /// The sending machine's own answer to whether a companion agent may
    /// drive it. Nil means it never said — a sender that predates the
    /// field — and that is NOT consent, never `.fullAccess` filled in
    /// here. A machine that refuses says `.disabled` out loud, which is
    /// the only thing separating it from one that is simply older.
    var agent: AgentIntegrationGuestAccess? = nil
    var name: String?
    var os: String?
    var chunk: Int?
}

struct Refuse: Codable, Equatable, Sendable {
    var contract: Int
    var reason: String
}

struct Bye: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case normal
        case shuttingDown = "shutting-down"
        case protocolError = "protocol-error"
    }

    var code: Code
    var reason: String?
}

struct ErrorMessage: Codable, Equatable, Sendable {
    var id: Int?
    var code: String
    var message: String
}

/// One command argument, in the shape the WIRE needs it.
///
/// **Every numeric argument this host ever sent arrived as zero.**
/// `args` was `[String: String]`, so `part` went out as `"21"`; the
/// classic guest reads a number with `strtol`, which stops at the
/// opening quote, returns 0 — and its presence check could not tell that
/// from a real zero. Measured on a live scroll bar 2026-08-02: the same
/// request as an integer moved it one line and as a string moved it
/// somewhere else, and BOTH replies said `dispatched`.
///
/// That is `two-halves-never-met-in-a-test` exactly: the contract says
/// `type: integer`, both sides were self-consistent, and nothing on
/// either side had ever watched the other's bytes.
enum CommandArg: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    case text(String)
    case number(Int)

    init(stringLiteral value: String) { self = .text(value) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { self = .number(v); return }
        self = .text(try c.decode(String.self))
    }
}

struct CommandRequest: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    /// The typed form: what a caller that knows the command sends.
    var args: [String: CommandArg]?
    /// The raw form: the text a human typed after the command name, for a
    /// console — which knows no command's grammar and must not, because the
    /// two guests do not serve the same commands. Presence is the signal, and
    /// "" is present. See CommandRequest.line in contract/asyncapi.yaml.
    var line: String?
}

/// Any JSON value, kept whole.
///
/// It exists for exactly one job — see `CommandResult.outputObjects` — and
/// deliberately does not grow past it: this is not an escape hatch for typing
/// a message properly. A family that needs a shape gets a struct.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "not a JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            // Whole numbers re-encode as integers. A cursor that went out as
            // 4096 and came back as 4096.0 is the same number and a
            // different string, and this type sits under a byte-for-byte
            // fixture comparison.
            if v == v.rounded(), abs(v) < 9.007199254740992e15 {
                try c.encode(Int(v))
            } else {
                try c.encode(v)
            }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// The row-array reading of this value, or nil when it is not one.
    /// `[[String]]` is the house shape and most values are one.
    var rows: [[String]]? {
        guard case .array(let outer) = self else { return nil }
        var out: [[String]] = []
        out.reserveCapacity(outer.count)
        for row in outer {
            guard case .array(let cells) = row else { return nil }
            var strings: [String] = []
            strings.reserveCapacity(cells.count)
            for cell in cells {
                guard case .string(let s) = cell else { return nil }
                strings.append(s)
            }
            out.append(strings)
        }
        return out
    }
}

struct CommandResult: Codable, Equatable, Sendable {
    struct CommandError: Codable, Equatable, Sendable {
        var code: String
        var message: String
    }

    var id: Int
    var ok: Bool
    /// Grouped, ordered rows: group name -> [[label, value], ...]. gestalt
    /// returns snapshot/cpu/memory/os/network/hw; the console shows a slice.
    ///
    /// **The row array is the house shape and not the only one.** This
    /// property holds the groups that ARE rows; a group whose value is any
    /// other JSON lands in `outputObjects` instead, and neither is thrown
    /// away. See that property for what this cost before it existed.
    var output: [String: [[String]]]?
    /// The groups whose value is NOT a row array, kept whole.
    ///
    /// **This is a fix for a live defect, not a generality.** The contract
    /// has declared object-shaped outputs since the reference layer landed
    /// (`observe`, `axtree`, `elements`, `handle`, `axsnap` all answer
    /// `output.<name>` as an OBJECT — `x-axTree` in the contract says so),
    /// and this side could not decode one. A host that cannot decode a frame
    /// drops the connection, so asking a guest to `observe` — the verb the
    /// whole act plane is aimed through — would have taken the link down.
    ///
    /// It went unnoticed because those emitters assemble their reply
    /// piecemeal, and `GuestWireConformanceTests` reads whole `snprintf`
    /// templates. `qdtrace` was the first object-shaped reply written as one
    /// template, so the gate saw it and reported it as a qdtrace problem; it
    /// was never qdtrace's. That verb's contract row states why its numbers
    /// are not rows.
    ///
    /// Two properties rather than one heterogeneous dictionary because every
    /// existing reader wants rows and should keep saying so. `rows(_:)`
    /// below is for a reader that does not care which half a group is in.
    var outputObjects: [String: JSONValue]?
    var error: CommandError?

    /// One group's rows, from whichever half holds it.
    func rows(_ group: String) -> [[String]]? {
        output?[group] ?? outputObjects?[group]?.rows
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, output, error
    }

    init(id: Int, ok: Bool, output: [String: [[String]]]? = nil,
         outputObjects: [String: JSONValue]? = nil,
         error: CommandError? = nil) {
        self.id = id
        self.ok = ok
        self.output = output
        self.outputObjects = outputObjects
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(CommandError.self, forKey: .error)

        guard let raw = try c.decodeIfPresent(
            [String: JSONValue].self, forKey: .output) else {
            output = nil
            outputObjects = nil
            return
        }
        var rows: [String: [[String]]] = [:]
        var objects: [String: JSONValue] = [:]
        for (key, value) in raw {
            if let r = value.rows { rows[key] = r } else { objects[key] = value }
        }
        // An `output` that was present and empty stays present and empty:
        // "the machine answered with no groups" is not "the machine sent no
        // output", and gestalt's `notice` row exists because that difference
        // has mattered before.
        output = objects.isEmpty ? rows : (rows.isEmpty ? nil : rows)
        outputObjects = objects.isEmpty ? nil : objects
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(error, forKey: .error)

        if output == nil && outputObjects == nil { return }
        var merged: [String: JSONValue] = [:]
        for (key, rows) in output ?? [:] {
            merged[key] = .array(rows.map { .array($0.map { .string($0) }) })
        }
        for (key, value) in outputObjects ?? [:] { merged[key] = value }
        try c.encode(merged, forKey: .output)
    }
}

/// The exec plane: a line this side does not read, and text it does not
/// parse. See the "Exec" section of the contract preamble for why this is a
/// second plane rather than a loosening of CommandRequest above.
///
/// The whole of the host's involvement in running a command is in these four
/// types, and what matters is what is ABSENT: no command name, no arg
/// dictionary, no per-command output schema. A verb this host has never
/// heard of travels through here unchanged — which is the property the plane
/// exists for, and the reason nothing in this file needs editing when a
/// guest grows one.
struct ExecRequest: Codable, Equatable, Sendable {
    var id: Int
    /// The whole line, verb included, exactly as typed. Nothing on this side
    /// looks inside it — not even to find where the verb ends, because that
    /// is a grammar, and a grammar belongs to the machine that serves the
    /// verb. Contrast CommandRequest.line, which is what is left AFTER this
    /// host has already split a name off the front.
    var line: String
}

struct ExecOutput: Codable, Equatable, Sendable {
    var id: Int
    /// 0-based and contiguous per exec. A gap means a frame was lost, and
    /// the console says so rather than quietly showing a hole.
    var seq: Int
    /// Free text, as the guest would have drawn it. A CHUNK, not a line: a
    /// guest splits where its buffer ends, so a reader reassembles before it
    /// goes looking for line breaks.
    var text: String
}

struct ExecResult: Codable, Equatable, Sendable {
    var id: Int
    var ok: Bool
    var code: String?
    var message: String?
}

struct ExecCancel: Codable, Equatable, Sendable {
    var id: Int
}

/// One line answering a prompt the guest sent as exec.output.
///
/// Unsolicited input is DROPPED by the guest, not buffered — a line typed at
/// a prompt that has already gone would otherwise be answered into the next
/// one, which is how a console runs something nobody meant.
struct ExecInput: Codable, Equatable, Sendable {
    var id: Int
    var text: String
}

/// The hardware census. Symmetric by contract: whoever receives the
/// request answers for its own machine. A report paginates like a file
/// listing; the guest is the side with hardware worth asking about, and
/// the host answers `refused` until it grows its own census.
struct CensusRequest: Codable, Equatable, Sendable {
    var id: Int
    var probe: String
    var cursor: Int?
}

struct CensusReport: Codable, Equatable, Sendable {
    var id: Int
    var probe: String
    /// present | absent | partial | refused | failed | not-attempted.
    /// `absent` (the machine said no) is never conflated with `refused`
    /// (the responder declined to look).
    var outcome: String
    /// One page of [name, raw, meaning] triples; the raw value always
    /// survives beside the decoded meaning.
    var rows: [[String]]
    var more: Bool
    var cursor: Int?
    var total: Int?
    var note: String?
}

struct CaptureRequest: Codable, Equatable, Sendable {
    var id: Int
    var depth: Int
    var chunkKb: Int?
    var paceMs: Int?
    var pack: Bool?
}

/// The guest's file share. Paths are relative to the guest's chosen
/// share root ("" is the root, segments joined with ":"), so nothing
/// outside the share is expressible.
struct FileList: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var cursor: Int?
}

struct FileEntry: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var kind: String
    var fileType: String?
    var creator: String?
    var dataBytes: Int?
    var rsrcBytes: Int?
    /// Classic Mac epoch: seconds since 1904-01-01.
    var modified: Int?
    /// Opaque responder-owned catalog identity for mutation preconditions.
    var identity: String? = nil

    var id: String { name }
    var isFolder: Bool { kind == "folder" }
}

struct FileListing: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var entries: [FileEntry]
    var more: Bool
    var cursor: Int?
    /// What the other machine is sharing, in its own spelling. Display
    /// only; every path on the wire is relative to it.
    var root: String?
}

struct FileGet: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var container: String?
}

/// Ask the other machine for its running processes. Read-only and
/// symmetric with the file family: whoever receives it answers from its
/// OWN process list (the guest from the Process Manager, the host from
/// its own).
struct ProcessList: Codable, Equatable, Sendable {
    var id: Int
    var cursor: Int?
}

struct ProcessEntry: Codable, Equatable, Sendable, Identifiable {
    var name: String
    /// application / background / finder, as the responder classifies it.
    var kind: String
    /// The process "type" four-character code, e.g. "APPL".
    var code: String?
    var creator: String?
    var sizeKB: Int?
    var front: Bool?
    /// The two halves of the process serial number, which name this
    /// process to the drive verbs. Absent if the responder predates them.
    var psnHigh: Int?
    var psnLow: Int?
    /// True on the ONE row that is the responder itself — the process on
    /// the other end of this connection. It is the only trustworthy
    /// answer to "which of these is the guest I am talking to": a name
    /// built from the version in `hello` agrees with the deployed file
    /// name only by convention, and when that convention lapsed a
    /// handoff asked a guest to quit a process that did not exist.
    /// Absent from a responder that predates the field.
    var isSelf: Bool?

    var id: String { "\(name)#\(code ?? "")#\(creator ?? "")" }
    var isBackground: Bool { kind == "background" }

    /// A process can only be driven if it named itself with a PSN.
    var isDrivable: Bool { psnHigh != nil && psnLow != nil }

    /// The responder will refuse process.quit here — quitting itself
    /// would sever the reply mid-send. Known before asking, so a UI can
    /// say so rather than discover it.
    var isQuittable: Bool { isDrivable && !(isSelf ?? false) }
}

struct ProcessListing: Codable, Equatable, Sendable {
    var id: Int
    var processes: [ProcessEntry]
    var more: Bool
    var cursor: Int?
}

/// Ask the other machine for its installed software, one domain a page.
/// Symmetric in meaning, one direction in implementation — the
/// process.list precedent: the host asks, the guest serves, and the
/// host ignores a software.list rather than serving one.
/// The guest revising the consent answer it gave at `hello`.
///
/// Guest-to-host only, unsolicited, and never acknowledged. `hello.agent`
/// states this once per connection; before this message existed, a person
/// who set Read Only mid-session went on being driven at the tier they had
/// just withdrawn until the link was rebuilt.
///
/// `agent` is non-optional here and optional in `Hello` on purpose: in a
/// hello, absence means "this sender predates the field" and must never be
/// read as consent, whereas a message whose only purpose is to carry the
/// answer has no reading in which the answer is missing. A malformed one
/// fails to decode and is dropped by the same path as any other unreadable
/// control frame, which is the right outcome — better no revision than an
/// invented tier.
struct AgentAccess: Codable, Equatable, Sendable {
    var agent: AgentIntegrationGuestAccess
}

struct SoftwareList: Codable, Equatable, Sendable {
    var id: Int
    var domain: String
    /// 1-based; 1 (or absent) rebuilds the responder's inventory — for
    /// "apps" that is a whole-volume sweep, ~4 s on real hardware.
    var cursor: Int?
}

struct SoftwareEntry: Codable, Equatable, Sendable, Identifiable {
    var name: String
    /// Full HFS path — the launch key. Empty means the responder could
    /// not name the parent chain honestly; listed, but not launchable
    /// from afar.
    var path: String
    var type: String?
    var creator: String?
    /// Data + resource forks; -1 when unreadable.
    var sizeK: Int?
    /// In an Extensions Manager disabled folder.
    var off: Bool?
    /// Joined against the responder's process list.
    var running: Bool?
    /// The 'vers' short version string, read per served entry (a bounded
    /// page's worth of fork opens); nil when the file has no 'vers'.
    var version: String?

    var id: String { path.isEmpty ? "\(name)#\(type ?? "")" : path }
    var isLaunchable: Bool { !path.isEmpty }
    /// Revealable whenever the responder could name the path — any item,
    /// not only an application, since reveal opens nothing.
    var isRevealable: Bool { !path.isEmpty }
}

struct SoftwareListing: Codable, Equatable, Sendable {
    var id: Int
    var domain: String
    var entries: [SoftwareEntry]
    var more: Bool
    var cursor: Int?
    /// The honest edges: unknown domain, or a truncated inventory.
    var note: String?
}

/// A drive verb: bring a process to the front, or ask it to quit. Both
/// name their target by the PSN echoed from a process.listing entry.
struct ProcessFront: Codable, Equatable, Sendable {
    var id: Int
    var psnHigh: Int
    var psnLow: Int
}

struct ProcessQuit: Codable, Equatable, Sendable {
    var id: Int
    var psnHigh: Int
    var psnLow: Int
}

/// Front a process, then capture just its front window. The answer is a
/// capture transfer (reusing the capture transport), not a process.result.
struct ProcessShot: Codable, Equatable, Sendable {
    var id: Int
    var psnHigh: Int
    var psnLow: Int
    var depth: Int?
}

/// The one reply to either drive verb.
struct ProcessResult: Codable, Equatable, Sendable {
    var id: Int
    var ok: Bool
    var reason: String?
}

/// A push into the guest's share. The share bounds what the guest may
/// reach unbidden, never what a human deliberately sends — so the
/// source is any file, and only `path` must lie inside the share.
struct FileOffer: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var path: String
    var container: String
    var bytes: Int
    var fileType: String?
    var creator: String?
    var modified: Int?
    var createParents: Bool? = nil
    var overwrite: Bool?
    /// Stable identity of the SOURCE file. The receiver never interprets
    /// it — it stores the token beside a partial and compares it later,
    /// so resuming can never land the tail of one file onto the head of
    /// another. Must change whenever the bytes would.
    var resumeToken: String?
}

struct FileAccept: Codable, Equatable, Sendable {
    var id: Int
    /// Bytes of THIS file the receiver already holds from an interrupted
    /// attempt, and so the offset to begin at. Only ever non-zero when
    /// the offer carried a resumeToken the receiver recognises.
    var have: Int?
    var freeBytes: Int? = nil
    var reservedBytes: Int? = nil
    var staging: String? = nil
}

struct FileDone: Codable, Equatable, Sendable {
    var id: Int
    var ok: Bool
    var code: String?
    var reason: String?
    var received: Int? = nil
    var crc32: UInt32? = nil
    var finalization: String? = nil
    var cleanup: String? = nil
}

/// What the guest has actually taken off the wire during a put. Advisory:
/// the guest drops these rather than delaying the messages that carry
/// meaning, so treat it as a floor that may skip, and its absence as an
/// older guest rather than a stalled one.
struct FileProgress: Codable, Equatable, Sendable {
    var id: Int
    var received: Int
}

/// Changing the share. A rename and a move are the same operation —
/// `toPath` carries the whole destination including the new name — and
/// missing parents are not invented, because a typo in a folder name
/// should fail rather than quietly create one.
struct FileMove: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var toPath: String
    var overwrite: Bool?
}

/// Delete means the Trash, not unlink: it is what a human expects on
/// this machine, and it is the only honest basis for an undo.
struct FileTrash: Codable, Equatable, Sendable {
    var id: Int
    var path: String
}

/// Puts a trashed item back. Both halves are names — what it is called
/// in the Trash, and where in the share it belongs — so an undo survives
/// a restart of either side. The Trash is a real folder; a name in it is
/// as durable a way to say "that item" as a path anywhere else.
struct FileRestore: Codable, Equatable, Sendable {
    var id: Int
    var trashedAs: String
    var toPath: String
}

struct FileMkdir: Codable, Equatable, Sendable {
    var id: Int
    var path: String
}

struct FileResult: Codable, Equatable, Sendable {
    var id: Int
    var ok: Bool
    var path: String?
    /// Answering file.trash: the name it landed under in the Trash,
    /// which is not always the name it had — the Trash may already hold
    /// one, and the second delete must not fail.
    var trashedAs: String?
    var code: String?
    var reason: String?
}

struct FileRefuse: Codable, Equatable, Sendable {
    var id: Int
    var code: String
    var reason: String?
}

struct FileBegin: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var name: String
    var container: String
    var bytes: Int
    var dataBytes: Int?
    var rsrcBytes: Int?
    var fileType: String?
    var creator: String?
    var modified: Int?
    /// First byte of the file this stream carries; absent or 0 is whole.
    /// `bytes` stays the size of the WHOLE file either way, so progress
    /// means the same thing on a resumed transfer as on a fresh one.
    var offset: Int?
    var resumeToken: String?
}

struct FileEnd: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var ok: Bool
    var sendMs: Int?
    /// CRC-32 of the WHOLE file, not of this stream — so a file stitched
    /// from two attempts is checked as the thing it is meant to be.
    /// Absent means the sender computed none, which a receiver must read
    /// as "unchecked", never as "correct".
    var crc32: UInt32?
}

struct FileCancel: Codable, Equatable, Sendable {
    var transfer: Int
}

/// Live-stream bracket: between stream.start and the guest's
/// stream.stopped, frames arrive as ordinary capture transfers whose
/// begin id is the stream id. stream.stopped is always the last word —
/// it acks the host's stop and reports guest-side aborts.
struct StreamRequest: Codable, Equatable, Sendable {
    var depth: Int
}

struct StreamStart: Codable, Equatable, Sendable {
    var id: Int
    var depth: Int
    var minIntervalMs: Int?
    var chunkKb: Int?
    var paceMs: Int?
    var pack: Bool?
    var predictive: Bool?
    var interlace: Bool?
}

struct StreamStop: Codable, Equatable, Sendable {
    var id: Int
}

struct StreamRefresh: Codable, Equatable, Sendable {
    var id: Int
}

struct StreamStopped: Codable, Equatable, Sendable {
    var id: Int
    var reason: String?
}

/// Guest-initiated push: the guest has already captured and encoded, so the
/// byte counts are exact; the host answers accept or refuse.
struct CaptureOffer: Codable, Equatable, Sendable {
    var id: Int
    var width: Int
    var height: Int
    var depth: Int
    var rowBytes: Int
    var bytes: Int
    var paletteBytes: Int?
    var encoding: String?
    var captureMs: Int?
    var encodeMs: Int?
}

struct CaptureAccept: Codable, Equatable, Sendable {
    var id: Int
}

struct CaptureRefuse: Codable, Equatable, Sendable {
    var id: Int
    var reason: String?
}

struct CaptureCancel: Codable, Equatable, Sendable {
    var transfer: Int
}

struct CaptureBegin: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var width: Int
    var height: Int
    var depth: Int
    var rowBytes: Int
    var bytes: Int
    var paletteBytes: Int?
    var encoding: String?
    /// Stream frames only: "key", "delta", or "empty" (absent = one-shot).
    var frame: String?
    /// Delta frames: [row, nRows, colByteOffset, colBytes] per dirty rect.
    var rects: [[Int]]?
    var captureMs: Int?
    var encodeMs: Int?
}

struct CaptureEnd: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var ok: Bool
    var sendMs: Int?
}

/// Ask for one scene. The answer is a TRANSFER — scene.begin, bulk
/// frames, scene.end — never a control message, because NOW's own
/// producer encodes 9214 bytes for 24 processes and 32 windows against a
/// 4096-byte control cap. There is no scene bracket and no scene.cancel:
/// the transfer is tens of milliseconds, and abandoning it costs more
/// than finishing it (docs/streaming-a-scene.md).
struct SceneRequest: Codable, Equatable, Sendable {
    var id: Int
    var chunkKb: Int?
    var paceMs: Int?
    /// How old an anchor sample may be and still be reported clean. An
    /// older-but-otherwise-valid anchor is *reported* stale in
    /// `apps[].error`, never silently dropped and never a refusal.
    var staleAfterMs: Int?
}

struct SceneBegin: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    /// Bulk bytes of UTF-8 JSON to expect, terminator excluded.
    var bytes: Int
    /// The IR major, repeated HERE — the same number the document's own
    /// `version` carries — so a consumer can refuse an unknown major
    /// **before** spending a decode on the body. That order is IR-V1.md's
    /// stated consumer duty, and only an envelope makes obeying it
    /// possible; `NOWSceneCodec.decode` is the half that obeys it.
    var irVersion: Int
    var seq: Int?
    var capturedAt: Double?
    var source: String?
    var walkMs: Int?
}

struct SceneEnd: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var ok: Bool
    /// Why a scene could not be served, on ok:false. Prose for a human;
    /// nothing branches on it. A failed or oversized walk ends here with
    /// NO bulk — a partial walk is never delivered as a complete scene.
    var reason: String?
    var sendMs: Int?
}

enum ControlMessageError: Error, Equatable {
    case notAnObject
    case missingType
    case unknownType(String)
}

enum ControlMessageCodec {
    private struct TypeProbe: Codable {
        var type: String
    }

    private struct IdOnly: Codable {
        var type: String
        var id: Int
    }

    static func decode(_ data: Data) throws -> ControlMessage {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
            else { throw ControlMessageError.notAnObject }
            throw ControlMessageError.missingType
        }
        switch probe.type {
        case "hello":
            return .hello(try decoder.decode(Hello.self, from: data))
        case "refuse":
            return .refuse(try decoder.decode(Refuse.self, from: data))
        case "ping":
            return .ping(id: try decoder.decode(IdOnly.self, from: data).id)
        case "pong":
            return .pong(id: try decoder.decode(IdOnly.self, from: data).id)
        case "bye":
            return .bye(try decoder.decode(Bye.self, from: data))
        case "error":
            return .error(try decoder.decode(ErrorMessage.self, from: data))
        case "command.request":
            return .commandRequest(
                try decoder.decode(CommandRequest.self, from: data))
        case "command.result":
            return .commandResult(
                try decoder.decode(CommandResult.self, from: data))
        case "exec.request":
            return .execRequest(
                try decoder.decode(ExecRequest.self, from: data))
        case "exec.output":
            return .execOutput(
                try decoder.decode(ExecOutput.self, from: data))
        case "exec.result":
            return .execResult(
                try decoder.decode(ExecResult.self, from: data))
        case "exec.cancel":
            return .execCancel(
                try decoder.decode(ExecCancel.self, from: data))
        case "exec.input":
            return .execInput(
                try decoder.decode(ExecInput.self, from: data))
        case "census.request":
            return .censusRequest(
                try decoder.decode(CensusRequest.self, from: data))
        case "census.report":
            return .censusReport(
                try decoder.decode(CensusReport.self, from: data))
        case "capture.request":
            return .captureRequest(
                try decoder.decode(CaptureRequest.self, from: data))
        case "file.list":
            return .fileList(try decoder.decode(FileList.self, from: data))
        case "file.listing":
            return .fileListing(
                try decoder.decode(FileListing.self, from: data))
        case "file.get":
            return .fileGet(try decoder.decode(FileGet.self, from: data))
        case "file.offer":
            return .fileOffer(try decoder.decode(FileOffer.self, from: data))
        case "file.accept":
            return .fileAccept(
                try decoder.decode(FileAccept.self, from: data))
        case "file.done":
            return .fileDone(try decoder.decode(FileDone.self, from: data))
        case "file.progress":
            return .fileProgress(
                try decoder.decode(FileProgress.self, from: data))
        case "file.move":
            return .fileMove(try decoder.decode(FileMove.self, from: data))
        case "file.trash":
            return .fileTrash(try decoder.decode(FileTrash.self, from: data))
        case "file.restore":
            return .fileRestore(
                try decoder.decode(FileRestore.self, from: data))
        case "file.mkdir":
            return .fileMkdir(try decoder.decode(FileMkdir.self, from: data))
        case "file.result":
            return .fileResult(
                try decoder.decode(FileResult.self, from: data))
        case "file.refuse":
            return .fileRefuse(
                try decoder.decode(FileRefuse.self, from: data))
        case "file.begin":
            return .fileBegin(try decoder.decode(FileBegin.self, from: data))
        case "file.end":
            return .fileEnd(try decoder.decode(FileEnd.self, from: data))
        case "file.cancel":
            return .fileCancel(
                try decoder.decode(FileCancel.self, from: data))
        case "cloud.services":
            return .cloudServices(
                try decoder.decode(CloudServices.self, from: data))
        case "cloud.report":
            return .cloudReport(
                try decoder.decode(CloudReport.self, from: data))
        case "cloud.list":
            return .cloudList(try decoder.decode(CloudList.self, from: data))
        case "cloud.listing":
            return .cloudListing(
                try decoder.decode(CloudListing.self, from: data))
        case "cloud.detail":
            return .cloudDetail(
                try decoder.decode(CloudDetail.self, from: data))
        case "cloud.card":
            return .cloudCard(try decoder.decode(CloudCard.self, from: data))
        case "cloud.get":
            return .cloudGet(try decoder.decode(CloudGet.self, from: data))
        case "cloud.refuse":
            return .cloudRefuse(
                try decoder.decode(CloudRefuse.self, from: data))
        case "stream.request":
            return .streamRequest(
                try decoder.decode(StreamRequest.self, from: data))
        case "stream.start":
            return .streamStart(
                try decoder.decode(StreamStart.self, from: data))
        case "stream.stop":
            return .streamStop(try decoder.decode(StreamStop.self, from: data))
        case "stream.refresh":
            return .streamRefresh(
                try decoder.decode(StreamRefresh.self, from: data))
        case "stream.stopped":
            return .streamStopped(
                try decoder.decode(StreamStopped.self, from: data))
        case "capture.offer":
            return .captureOffer(
                try decoder.decode(CaptureOffer.self, from: data))
        case "capture.accept":
            return .captureAccept(
                try decoder.decode(CaptureAccept.self, from: data))
        case "capture.refuse":
            return .captureRefuse(
                try decoder.decode(CaptureRefuse.self, from: data))
        case "capture.cancel":
            return .captureCancel(
                try decoder.decode(CaptureCancel.self, from: data))
        case "capture.begin":
            return .captureBegin(
                try decoder.decode(CaptureBegin.self, from: data))
        case "capture.end":
            return .captureEnd(try decoder.decode(CaptureEnd.self, from: data))
        case "scene.request":
            return .sceneRequest(
                try decoder.decode(SceneRequest.self, from: data))
        case "scene.begin":
            return .sceneBegin(
                try decoder.decode(SceneBegin.self, from: data))
        case "scene.end":
            return .sceneEnd(try decoder.decode(SceneEnd.self, from: data))
        case "process.list":
            return .processList(
                try decoder.decode(ProcessList.self, from: data))
        case "process.listing":
            return .processListing(
                try decoder.decode(ProcessListing.self, from: data))
        case "process.front":
            return .processFront(
                try decoder.decode(ProcessFront.self, from: data))
        case "process.quit":
            return .processQuit(
                try decoder.decode(ProcessQuit.self, from: data))
        case "process.shot":
            return .processShot(
                try decoder.decode(ProcessShot.self, from: data))
        case "process.result":
            return .processResult(
                try decoder.decode(ProcessResult.self, from: data))
        case "software.list":
            return .softwareList(
                try decoder.decode(SoftwareList.self, from: data))
        case "software.listing":
            return .softwareListing(
                try decoder.decode(SoftwareListing.self, from: data))
        case "agent.access":
            return .agentAccess(try decoder.decode(AgentAccess.self, from: data))
        default:
            throw ControlMessageError.unknownType(probe.type)
        }
    }

    static func encode(_ message: ControlMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func tagged<T: Encodable>(_ type: String, _ value: T) throws -> Data {
            var object = try JSONSerialization.jsonObject(
                with: encoder.encode(value)) as? [String: Any] ?? [:]
            object["type"] = type
            return try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
        }
        switch message {
        case .hello(let hello): return try tagged("hello", hello)
        case .refuse(let refuse): return try tagged("refuse", refuse)
        case .ping(let id): return try tagged("ping", ["id": id])
        case .pong(let id): return try tagged("pong", ["id": id])
        case .bye(let bye): return try tagged("bye", bye)
        case .error(let error): return try tagged("error", error)
        case .commandRequest(let m): return try tagged("command.request", m)
        case .commandResult(let m): return try tagged("command.result", m)
        case .execRequest(let m): return try tagged("exec.request", m)
        case .execOutput(let m): return try tagged("exec.output", m)
        case .execResult(let m): return try tagged("exec.result", m)
        case .execCancel(let m): return try tagged("exec.cancel", m)
        case .execInput(let m): return try tagged("exec.input", m)
        case .censusRequest(let m): return try tagged("census.request", m)
        case .censusReport(let m): return try tagged("census.report", m)
        case .captureRequest(let m): return try tagged("capture.request", m)
        case .fileList(let m): return try tagged("file.list", m)
        case .fileListing(let m): return try tagged("file.listing", m)
        case .fileGet(let m): return try tagged("file.get", m)
        case .fileOffer(let m): return try tagged("file.offer", m)
        case .fileAccept(let m): return try tagged("file.accept", m)
        case .fileDone(let m): return try tagged("file.done", m)
        case .fileProgress(let m): return try tagged("file.progress", m)
        case .fileRefuse(let m): return try tagged("file.refuse", m)
        case .fileMove(let m): return try tagged("file.move", m)
        case .fileTrash(let m): return try tagged("file.trash", m)
        case .fileRestore(let m): return try tagged("file.restore", m)
        case .fileMkdir(let m): return try tagged("file.mkdir", m)
        case .fileResult(let m): return try tagged("file.result", m)
        case .fileBegin(let m): return try tagged("file.begin", m)
        case .fileEnd(let m): return try tagged("file.end", m)
        case .fileCancel(let m): return try tagged("file.cancel", m)
        case .cloudServices(let m): return try tagged("cloud.services", m)
        case .cloudReport(let m): return try tagged("cloud.report", m)
        case .cloudList(let m): return try tagged("cloud.list", m)
        case .cloudListing(let m): return try tagged("cloud.listing", m)
        case .cloudDetail(let m): return try tagged("cloud.detail", m)
        case .cloudCard(let m): return try tagged("cloud.card", m)
        case .cloudGet(let m): return try tagged("cloud.get", m)
        case .cloudRefuse(let m): return try tagged("cloud.refuse", m)
        case .streamRequest(let m): return try tagged("stream.request", m)
        case .streamStart(let m): return try tagged("stream.start", m)
        case .streamStop(let m): return try tagged("stream.stop", m)
        case .streamRefresh(let m): return try tagged("stream.refresh", m)
        case .streamStopped(let m): return try tagged("stream.stopped", m)
        case .captureOffer(let m): return try tagged("capture.offer", m)
        case .captureAccept(let m): return try tagged("capture.accept", m)
        case .captureRefuse(let m): return try tagged("capture.refuse", m)
        case .captureCancel(let m): return try tagged("capture.cancel", m)
        case .captureBegin(let m): return try tagged("capture.begin", m)
        case .captureEnd(let m): return try tagged("capture.end", m)
        case .sceneRequest(let m): return try tagged("scene.request", m)
        case .sceneBegin(let m): return try tagged("scene.begin", m)
        case .sceneEnd(let m): return try tagged("scene.end", m)
        case .processList(let m): return try tagged("process.list", m)
        case .processListing(let m): return try tagged("process.listing", m)
        case .softwareList(let m): return try tagged("software.list", m)
        case .softwareListing(let m): return try tagged("software.listing", m)
        case .processFront(let m): return try tagged("process.front", m)
        case .processQuit(let m): return try tagged("process.quit", m)
        case .processShot(let m): return try tagged("process.shot", m)
        case .processResult(let m): return try tagged("process.result", m)
        case .agentAccess(let m): return try tagged("agent.access", m)
        }
    }
}
