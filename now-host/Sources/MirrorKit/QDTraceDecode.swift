import Foundation

/// **The translation between the guest's `qdtrace drain` reply and
/// `[DisplayOp]`.**
///
/// The two halves of the content plane were built by different lanes and never
/// met. `now-guest-ppc/src/content/qdtrace_json.c` emits a QuickDraw op stream;
/// `DisplayOp` + `DisplayReplay` consume one; nothing turned the first into the
/// second, and `MirrorSceneAdapter` hard-set every window's `display` to nil.
/// This file is that turn, and it lives on the **host** side on purpose: the
/// wire format is the guest's and is not changed to suit a consumer.
///
/// ## Why a Record and not just a DisplayOp
///
/// Every ring record carries a `port` — a `CGrafPtr`, which
/// `contract/content_table.h` calls *"the window identity key"*. `DisplayOp`
/// has no port and must not grow one: it is in the frozen scene IR
/// (`Scene.Window.CodingKeys` names `display`), and a port is a join key, not
/// a drawing instruction. So a decoded record is the pair, and whoever joins
/// decides what a port means. See `MirrorContentJoin`.
///
/// ## The three places the vocabularies disagree
///
/// 1. **`pen` means two things.** For a `text` record the guest's `pen` is the
///    pen LOCATION (`NowContentTextPayload.pen_h/pen_v`, "pen location at draw
///    time") and `DisplayReplay` draws the glyph run there. For a `line`
///    record the same key is `NowContentLinePayload.pn_h/pn_v` — the pen
///    SIZE. Nothing is mis-drawn today only because the replay's line branch
///    never reads `pen`. This decoder therefore does **not** put a line's
///    `pen` into `DisplayOp.pen`; it carries it as `Record.penSize`. A size
///    parked in a field whose documented meaning is a position is a trap with
///    a fuse in it, and the fuse is however long it takes someone to use it.
/// 2. **`detail: false`.** The guest emits that, and nothing else, for a
///    record whose payload it could not read — *"an op happened and we could
///    not read its detail"*. There is no `DisplayOp` field for it. The record
///    is kept (op, port, ticks are all true) and counted in `detailless`,
///    because a record silently reduced to a header is a drawing operation the
///    host will think it saw in full.
/// 3. **`trunc` / `fullLen`.** A text run longer than the guest's inline
///    maximum arrives short with `trunc: true`. The bytes that arrived are
///    drawn; the count of runs that were cut is reported in `truncatedText`,
///    so a short label on screen is attributable rather than mysterious.
///
/// ## What is counted rather than dropped
///
/// `DisplayReplay` draws `state`(origin/fg), `text`, `line`, and
/// `rect`/`rrect`/`oval` at verbs frame/paint/fill. It skips `arc`, `poly`,
/// `rgn`, `bits`, `comment`, `state`(clip/bg) and the erase/invert verbs.
/// Those ops are decoded and carried anyway — the renderer's coverage is the
/// renderer's business — and `undrawn` names them with counts, so "the window
/// is half empty" has an answer instead of a shrug.
public enum QDTraceDecode {

    /// What one `qdtrace drain` reply came to.
    ///
    /// Every accounting field is carried through, including all four ways a
    /// drain ends short. They are four different words on the wire for a
    /// reason the guest emitter spells out at length, and folding them into
    /// "fewer records than expected" here would undo that in one line.
    public struct Drain: Equatable, Sendable {

        /// One decoded record: the op the renderer speaks, plus the port that
        /// says whose it is.
        public struct Record: Equatable, Sendable {
            /// The `CGrafPtr`, exactly as the guest printed it
            /// (`"0x%08lx"`). Kept as the guest's own string rather than
            /// parsed to an integer: it is an opaque identity to this side,
            /// and two strings compare equal or they do not.
            public var port: String
            public var op: DisplayOp
            /// `line` only — the pen size, which the guest sends under the
            /// key `pen`. Nil for every other family. See the header.
            public var penSize: [Int]?
            /// True when the guest said `detail: false`: the op is real and
            /// its geometry is not.
            public var detailless: Bool

            public init(port: String, op: DisplayOp,
                        penSize: [Int]? = nil, detailless: Bool = false) {
                self.port = port
                self.op = op
                self.penSize = penSize
                self.detailless = detailless
            }
        }

        public var records: [Record] = []

        // The cursor accounting, verbatim from the drain tail.
        public var cursor: Int = 0
        public var nextCursor: Int = 0
        public var writeCursor: Int = 0
        public var pending: Int = 0
        /// The guest's own record count. Compared against `records.count` by
        /// `recordCountAgrees` — a disagreement means this side dropped
        /// something the guest sent, which is a decoder bug and not a fact
        /// about the machine.
        public var reportedRecords: Int = 0
        public var wraps: Int = 0

        // The four ways an answer is short. Never merged.
        public var more: Bool = false
        public var resync: Bool = false
        public var torn: Bool = false
        public var busy: Bool = false

        /// Bytes the writer overwrote before this side read them (`resync`).
        public var lostBytes: Int = 0
        /// The WRITER's own counter of records it could not fit. A different
        /// loss with a different cause; never summed with `lostBytes`.
        public var dropped: Int = 0

        // The honesty census this decoder adds.

        /// Records that arrived as a header with `detail: false`.
        public var detailless: Int = 0
        /// Text runs the guest had to cut (`trunc: true`).
        public var truncatedText: Int = 0
        /// Ops `DisplayReplay` will not draw, by name, with counts. Present
        /// so an empty-looking window is explained rather than shrugged at.
        public var undrawn: [String: Int] = [:]

        public init() {}

        /// The distinct ports seen, in first-appearance order. The join key
        /// the scene does not carry — see `MirrorContentJoin` for what is
        /// done about that.
        public var ports: [String] {
            var seen = Set<String>()
            var out: [String] = []
            for record in records where !seen.contains(record.port) {
                seen.insert(record.port)
                out.append(record.port)
            }
            return out
        }

        /// The ops for one port, in wire order.
        public func ops(port: String) -> [DisplayOp] {
            records.filter { $0.port == port }.map(\.op)
        }

        /// Whether this side decoded as many records as the guest says it
        /// sent. False is a defect in this file, not a report about the Mac.
        public var recordCountAgrees: Bool {
            /* A torn or busy drain delivers no records BY DESIGN — the guest
               retracts anything its sink printed — and its tail still carries
               whatever `records` the walk reached before the tear. Holding
               those two to equality would report a decoder bug every time a
               writer committed mid-read. */
            if torn || busy { return records.isEmpty }
            return records.count == reportedRecords
        }
    }

    /// Decode the object the guest publishes at `output.qdtrace`.
    ///
    /// Returns nil when the object is not a drain: a `status`/`start`/`stop`
    /// reply, or something with no `cmd` at all. It does **not** return an
    /// empty drain for those — "the guest answered a different question" and
    /// "the guest drained nothing" are different answers, and only the second
    /// is a fact about what is on the screen.
    public static func drain(_ qdtrace: [String: Any]) -> Drain? {
        guard let cmd = qdtrace["cmd"] as? String, cmd == "drain" else {
            return nil
        }
        var out = Drain()
        func int(_ key: String) -> Int { SceneBuilder.intValue(qdtrace[key]) ?? 0 }
        func bool(_ key: String) -> Bool { (qdtrace[key] as? NSNumber)?.boolValue ?? false }

        out.cursor = int("cursor")
        out.nextCursor = int("nextCursor")
        out.writeCursor = int("writeCursor")
        out.pending = int("pending")
        out.reportedRecords = int("records")
        out.wraps = int("wraps")
        out.more = bool("more")
        out.resync = bool("resync")
        out.torn = bool("torn")
        out.busy = bool("busy")
        out.lostBytes = int("lostBytes")
        out.dropped = int("dropped")

        for raw in (qdtrace["ops"] as? [Any]) ?? [] {
            guard let dict = raw as? [String: Any],
                  let record = record(from: dict) else { continue }
            out.records.append(record)
            if record.detailless { out.detailless += 1 }
            if (dict["trunc"] as? NSNumber)?.boolValue == true {
                out.truncatedText += 1
            }
            if let name = undrawnName(record) {
                out.undrawn[name, default: 0] += 1
            }
        }
        return out
    }

    /// One record. Nil only when the object has no `op` or no `port` — a
    /// record that cannot say what happened or where is not a record, and
    /// counting it would be counting the decoder's own confusion.
    static func record(from dict: [String: Any]) -> Drain.Record? {
        guard let port = dict["port"] as? String,
              var op = DisplayOp(fetched: dict) else { return nil }

        /* `detail: false` is the guest's word for "the payload was
           unreadable". The key is only ever emitted with that value, so its
           presence is the signal; it is read as a bool anyway rather than
           assumed, because a future emitter that writes `detail: true`
           should not read as a blind record. */
        let detailless = (dict["detail"] as? NSNumber).map { !$0.boolValue }
            ?? false

        /* THE `pen` COLLISION. For a line, the guest's `pen` is a pen SIZE,
           and `DisplayOp.pen` is documented and used as a position. Move it
           out rather than leaving a size where a coordinate is expected. */
        var penSize: [Int]?
        if op.op == "line" {
            penSize = op.pen
            op.pen = nil
        }
        return Drain.Record(port: port, op: op, penSize: penSize,
                            detailless: detailless)
    }

    /// The name under which an op is counted as undrawn, or nil when
    /// `DisplayReplay` draws it.
    ///
    /// This mirrors `MirrorKitUI.DisplayReplay`'s switch deliberately and by
    /// hand — MirrorKit does not depend on MirrorKitUI, and a census that
    /// guessed at the renderer's coverage would be a second claim to
    /// disagree with. When the renderer learns an op, this list loses it, and
    /// `QDTraceDecodeTests` is where the two are checked against each other
    /// by a reader.
    static func undrawnName(_ record: Drain.Record) -> String? {
        if record.detailless { return "\(record.op.op) (no detail)" }
        switch record.op.op {
        case "text", "line":
            return nil
        case "rect", "rrect", "oval":
            switch record.op.verb ?? 0 {
            case 0, 1, 4: return nil
            case 2: return "\(record.op.op) (erase)"
            case 3: return "\(record.op.op) (invert)"
            default: return "\(record.op.op) (verb \(record.op.verb ?? 0))"
            }
        case "state":
            switch record.op.kind {
            case "origin", "fg": return nil
            case let kind?: return "state/\(kind)"
            case nil: return "state"
            }
        default:
            return record.op.op
        }
    }
}
