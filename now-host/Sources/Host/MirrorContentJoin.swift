import Foundation
import MirrorKit

/// **The join that was never written: the content plane onto the scene.**
///
/// The audit's acceptance row 1 — *"it didn't even draw window content"* — was
/// not a missing plane on either side. `qdtrace` has emitted a QuickDraw op
/// stream from the guest since `commands.c:1376`; `DisplayOp` and
/// `DisplayReplay` have consumed one on the host; `Scene.Window.display` has
/// been `[DisplayOp]?` all along. Nothing connected them, and
/// `MirrorSceneAdapter` hard-set `display: nil` under a comment claiming NOW
/// modelled no display plane. It does. This file is the join.
///
/// ## Transport posture
///
/// One `qdtrace drain` per ask, on the **control** lane — `qdtrace.h` argues
/// at length that a drain is a bounded control answer and not a transfer,
/// precisely so it does not take the one bulk lane a scene needs. There is no
/// timer here and this is never called from the watch loop: content is joined
/// when a person presses the button or when an act's follow-up scene lands.
/// The cursor is held between joins, so a second join reads forward through
/// the ring instead of re-reading it.
///
/// ## The rule for attaching ops to a window, and why it is a rule
///
/// A ring record's `port` is a `CGrafPtr` and `contract/content_table.h` calls
/// it *"the window identity key"*. A `Scene.Window.id` is
/// `"<psn>/<title>#<z>"` (`scene_build.c:197`) and carries **no pointer**.
/// There is no field common to the two planes, and coordinates cannot bridge
/// them either: ops are port-local and carry no global anchor, so a port's
/// records cannot be matched against a window's global rect.
///
/// So this joins under one stated rule, and refuses outside it:
///
/// - **exactly one distinct port** in the drain → its ops attach to the front
///   window. `qdtrace start` arms ONE A5 world, i.e. one application, so one
///   port drawing over the drained interval is one window's worth of ops.
/// - **more than one port** → nothing attaches, `.ambiguous`. Two ports drew
///   and this side cannot say which window either is. Picking one would be a
///   coin flip presented as a mirror.
/// - **no records** → nothing attaches, and the emptiness is *attributed*
///   rather than left blank (see `armGap`).
///
/// The single-port rule is a rule, not a measurement, and it will need
/// re-examining the first time a real drain is watched: an application that
/// draws into its own offscreen `GWorld` produces a second port that is not a
/// window at all.
///
/// ## What this cannot do, refused in writing
///
/// **This host cannot arm the plane.** `qdtrace start` requires `a5` and
/// refuses zero by name (`qdtrace_cmd.c:217`, `no-target`: *"there is no
/// arm-everything"*). The A5 exists in the extension's anchor table
/// (`contract/peek_table.h:447`) and **no NOW command emits it**:
/// `observe`/`axsnap`'s process head sends `name signature serialHi serialLo
/// front bind stampTicks`, and the scene sends a PSN. A PSN is not an A5 and
/// nothing on this side can derive one.
///
/// So the join drains and never starts. On an unarmed machine it will report
/// zero records forever, correctly, and say why. The three ways round it were
/// considered and all rejected: deriving an A5 from a PSN (no relation
/// exists), arming everything (the guest refuses it by name and is right to),
/// and reading the anchor table through a below-the-line peek (NOW's peek
/// surface does not expose it, and reaching under the line to feed an
/// above-the-line join is the wrong door). The fix belongs in the guest —
/// either a verb that reports the front process's A5, or a `front: true`
/// selector on `qdtrace start` that resolves it where it is already known.
///
/// **Nothing in this file has run against a Macintosh.** The plane it reads
/// has run nowhere either — `qdtrace.h` says so in its own header. What is
/// proven is that it compiles and that its decisions are unit-tested.
@MainActor
final class MirrorContentJoin {

    /// What one join came to. Every case carries the sentence a page shows,
    /// because "the content area is empty" has six different causes and a
    /// blank rectangle is the same picture for all of them.
    enum Outcome: Equatable {
        /// Ops attached to the front window.
        case attached(port: String, ops: Int, note: String?)
        /// The drain worked and carried nothing. The sentence attributes it.
        case empty(String)
        /// More than one port drew. Nothing attached, on purpose.
        case ambiguous(ports: [String])
        /// The scene has no front window to attach to.
        case noFrontWindow
        /// The guest was asked and said no, in its own words.
        case refused(String)
        /// Nothing was asked — no wire, or no scene to join onto.
        case unavailable(String)

        var sentence: String {
            switch self {
            case .attached(let port, let ops, let note):
                let head = "\(ops) drawing operation\(ops == 1 ? "" : "s") "
                    + "from port \(port) drew into the front window."
                return note.map { "\(head) \($0)" } ?? head
            case .empty(let why):
                return why
            case .ambiguous(let ports):
                return "\(ports.count) drawing ports reported operations "
                    + "(\(ports.joined(separator: ", "))) and a scene window "
                    + "carries no port, so \(MachineNaming.thisMac) cannot "
                    + "say which window "
                    + "either belongs to. Nothing was drawn rather than the "
                    + "wrong thing."
            case .noFrontWindow:
                return "This scene has no front window, so there is nothing "
                    + "for the content plane to draw into."
            case .refused(let why):
                return why
            case .unavailable(let why):
                return why
            }
        }
    }

    /// The refusal in 4a, as one sentence a page can show. Kept here rather
    /// than in a comment because a person looking at an empty window is owed
    /// the reason, and a reason that only exists in a source file is a reason
    /// nobody reads.
    static let armGap =
        "Nothing is armed to record drawing, and \(MachineNaming.thisMac) "
        + "cannot arm it: "
        + "qdtrace start needs the A5 world of one process, and no NOW "
        + "command reports an A5 — the scene carries a process serial, which "
        + "is a different thing. Arm it on \(MachineNaming.simpleReference) "
        + "and press again."

    private let listener: GuestListener

    /// The ring cursor, carried between joins so a second one reads forward.
    /// Monotonic bytes, not a position (`qdtrace.h`).
    private(set) var cursor: Int = 0

    init(listener: GuestListener) {
        self.listener = listener
    }

    /// A cursor from another machine is meaningless. Reset when the guest
    /// changes — a stale cursor against a fresh ring reads as a colossal
    /// overrun or as bytes that are not there.
    func guestChanged() {
        cursor = 0
    }

    /// Ask for the front window's content, and hand back the scene with it
    /// attached.
    ///
    /// The scene goes through unchanged in every case but `.attached`; a join
    /// that cannot decide never edits what it was given.
    func join(into scene: MirrorKit.Scene,
              completion: @escaping (MirrorKit.Scene, Outcome) -> Void) {
        guard scene.windows.contains(where: \.front) else {
            completion(scene, .noFrontWindow)
            return
        }
        /* `cursor` is a string because `parse_u32` (qdtrace_cmd.c:84) takes
           one: a monotonic byte count exceeds 2^31 after two gigabytes of
           records, and the guest's `long` is 32 bits. `maxBytes` and
           `maxRecords` are NOT sent — they parse through `now_json_find_int`,
           which is `strtol` on the raw value, and every arg from this host is
           a JSON string, so `"4096"` would read as 0 anyway. Absent means the
           whole ring bounded by the guest's own output frame, which is the
           behaviour wanted here; sending an argument that silently reads as
           its default would be worse than sending none. */
        listener.runCommand("qdtrace",
                            args: ["op": "drain", "cursor": String(cursor)]) {
            [weak self] result in
            guard let self else { return }
            let (scene, outcome) = self.apply(result, to: scene)
            /* An empty drain with no reason of its own is the ONE case worth
               a second round trip: `apply` leaves its sentence blank exactly
               there, and `status` is the only thing that can fill it in. */
            if case .empty(let why) = outcome, why.isEmpty {
                self.attribute(scene, completion: completion)
                return
            }
            completion(scene, outcome)
        }
    }

    // MARK: - the decision, which is pure and therefore tested

    /// Turn one `qdtrace drain` reply into a scene and an outcome.
    ///
    /// Split out from `join` with no wire in it so the port rule and the four
    /// shortness reasons are unit-testable without a socket.
    func apply(_ result: CommandResult,
               to scene: MirrorKit.Scene) -> (MirrorKit.Scene, Outcome) {
        guard result.ok else {
            let error = result.error
            /* A wire refusal is not a statement about the content plane, and
               a guest refusal is. Both are forwarded in the guest's own
               words; neither is rewritten into a cheerier one. */
            return (scene, .refused(error.map { "\($0.message) [\($0.code)]" }
                ?? MachineNaming.startingSentence(
                    MachineNaming.simpleReference)
                    + " refused the drain without saying why."))
        }
        guard case .object(let object)? = result.outputObjects?["qdtrace"],
              let drain = QDTraceDecode.drain(Self.plain(object)) else {
            return (scene, .refused(
                MachineNaming.startingSentence(
                    MachineNaming.simpleReference)
                + " answered the drain with something \(MachineNaming.thisMac) "
                + "cannot read as one."))
        }

        /* The cursor advances on any answered drain, including a short one:
           `nextCursor` is where the guest says to resume, and a torn or busy
           drain reports the cursor it did not move past. Advancing on
           anything else would re-read the ring; not advancing at all would
           re-read it forever. */
        cursor = drain.nextCursor

        /* A torn or busy drain delivers NOTHING — the guest retracts whatever
           its sink printed before the tear. Checked here rather than trusted:
           if a record ever arrives beside one of those flags, it is a record
           about a read that was discarded, and drawing it would put a
           half-read frame inside a window. */
        if drain.torn || drain.busy || drain.records.isEmpty {
            /* An empty result with none of the four reasons gets a blank
               sentence on purpose — `join` fills it in from a `status`, which
               is the only thing that can tell "nothing is armed" from
               "nothing drew". */
            return (scene, .empty(Self.shortness(drain) ?? ""))
        }
        let ports = drain.ports
        guard ports.count == 1, let port = ports.first else {
            return (scene, .ambiguous(ports: ports))
        }

        var attached = scene
        guard let index = attached.windows.firstIndex(where: \.front) else {
            return (scene, .noFrontWindow)
        }
        let ops = drain.ops(port: port)
        attached.windows[index].display = ops
        return (attached, .attached(port: port, ops: ops.count,
                                    note: Self.note(drain)))
    }

    /// The four ways a drain ends short, kept apart the way the guest emitter
    /// keeps them apart. Nil when none of them applies — which, with no
    /// records, is the only case that means what it looks like: a machine
    /// that is not drawing.
    static func shortness(_ drain: QDTraceDecode.Drain) -> String? {
        if drain.torn {
            return "A program drew into the ring while "
                + "\(MachineNaming.thisMac) was reading "
                + "it and overtook the read, so the answer was discarded "
                + "rather than shipped half-right. Press again."
        }
        if drain.busy {
            return "A drawing operation was being committed at the moment of "
                + "the read. Nothing was lost; press again."
        }
        if drain.resync {
            return "Drawing outran \(MachineNaming.thisMac) by "
                + "\(drain.lostBytes) bytes, "
                + "which no longer exist in the ring. The read restarted at "
                + "the live end; press again for what is being drawn now."
        }
        return nil
    }

    /// What is worth saying beside a successful attach: loss, truncation, and
    /// operations the renderer carries but does not draw. Nil when there is
    /// nothing to add — a note that always fires is a note nobody reads.
    static func note(_ drain: QDTraceDecode.Drain) -> String? {
        var parts: [String] = []
        /* Overrun can arrive WITH records — the resync lands on the live end
           and the drain reads forward from there. The loss is still loss and
           is said beside the ops that survived, never instead of them. */
        if drain.resync {
            parts.append("\(drain.lostBytes) bytes of earlier drawing were "
                         + "overwritten before \(MachineNaming.thisMac) "
                         + "read them")
        }
        if drain.more {
            parts.append("more operations are waiting (\(drain.pending) "
                         + "bytes); press again to continue")
        }
        if drain.dropped > 0 {
            parts.append("\(MachineNaming.simpleReference) could not fit "
                         + "\(drain.dropped) "
                         + "operation\(drain.dropped == 1 ? "" : "s") into "
                         + "the ring")
        }
        if drain.detailless > 0 {
            parts.append("\(drain.detailless) arrived without geometry and "
                         + "could not be drawn")
        }
        if drain.truncatedText > 0 {
            parts.append("\(drain.truncatedText) text run"
                         + "\(drain.truncatedText == 1 ? " was" : "s were") "
                         + "cut short by \(MachineNaming.simpleReference)")
        }
        if !drain.undrawn.isEmpty {
            let named = drain.undrawn.sorted { $0.key < $1.key }
                .map { "\($0.value)×\($0.key)" }.joined(separator: ", ")
            parts.append("this renderer does not draw \(named)")
        }
        if !drain.recordCountAgrees {
            /* A disagreement here is a defect in QDTraceDecode, not a report
               about the Mac, and it is said as one. */
            parts.append("\(drain.reportedRecords) operations were reported "
                         + "and \(drain.records.count) were read, which is a "
                         + "fault in \(MachineNaming.thisMac) and not in "
                         + "\(MachineNaming.simpleReference)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + "."
    }

    // MARK: - attributing an empty drain

    /// A drain that answered and carried nothing has two very different
    /// causes: nothing is armed, or something is armed and nothing drew. Only
    /// `status` can tell them apart, and it is the one subcommand that
    /// neither writes nor moves a record — so it is asked exactly here, when
    /// there is an emptiness to explain, and never on a schedule.
    private func attribute(_ scene: MirrorKit.Scene,
                           completion: @escaping (MirrorKit.Scene,
                                                  Outcome) -> Void) {
        listener.runCommand("qdtrace", args: ["op": "status"]) { result in
            completion(scene, .empty(Self.attribution(result)))
        }
    }

    /// Read `active.a5` and `active.mode` out of a status reply and say what
    /// the emptiness means.
    static func attribution(_ result: CommandResult) -> String {
        guard result.ok,
              case .object(let object)? = result.outputObjects?["qdtrace"],
              case .object(let active)? = object["active"] else {
            /* The status did not answer. Say the least: the drain was empty,
               and this side could not find out why. */
            return "Nothing has been drawn since \(MachineNaming.thisMac) "
                + "last looked, and \(MachineNaming.simpleReference) did "
                + "not answer the follow-up question about "
                + "whether anything is armed to record drawing."
        }
        let a5: String
        if case .string(let s)? = active["a5"] { a5 = s } else { a5 = "" }
        /* `active.a5` is `"0x%08lx"` (qdtrace_json.c:207) and zero is the
           extension's own word for "nothing armed". A value this side cannot
           parse is treated as UNARMED rather than as armed: the two errors
           are not symmetric — reading a malformed A5 as armed would report
           "the plane is armed and nothing drew" about a machine that never
           said so, and hide the one gap this join actually has. */
        guard a5.hasPrefix("0x"), let value = UInt32(a5.dropFirst(2),
                                                     radix: 16),
              value != 0 else {
            return armGap
        }
        var mode = ""
        if case .string(let s)? = active["mode"] { mode = s }
        if mode == "count" {
            /* The cheap mode counts and records nothing, by design. An empty
               drain under it is correct behaviour and not a fault. */
            return "Drawing is being counted but not recorded (mode "
                + "\"count\"), so there are no operations to draw. Arm the "
                + "plane in \"record\" mode on "
                + "\(MachineNaming.simpleReference)."
        }
        return "The plane is armed on A5 \(a5) and nothing has drawn since "
            + "\(MachineNaming.thisMac) last looked."
    }

    // MARK: -

    /// `JSONValue` → the plain Foundation values `QDTraceDecode` reads.
    ///
    /// The decoder lives in MirrorKit and takes `[String: Any]` on purpose:
    /// it is testable from a JSON literal without any of this host's wire
    /// types. This is the one place the two meet.
    static func plain(_ object: [String: JSONValue]) -> [String: Any] {
        object.mapValues(plain(_:))
    }

    private static func plain(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let n):
            /* Whole numbers become integers. A cursor that arrived as 4096
               must not become 4096.0 — `NSNumber.intValue` would cope, but a
               reader comparing the two would not. */
            if n == n.rounded(), abs(n) < 9.007199254740992e15 {
                return NSNumber(value: Int(n))
            }
            return NSNumber(value: n)
        case .string(let s): return s
        case .array(let a): return a.map(plain(_:))
        case .object(let o): return o.mapValues(plain(_:))
        }
    }
}
