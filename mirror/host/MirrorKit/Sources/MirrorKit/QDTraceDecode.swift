import Foundation

/// Converts the guest's bounded `qdtrace drain` object into display-list
/// operations while retaining the window-port identity and every reason a
/// drain may be incomplete. The guest wire and the scene IR remain separate;
/// NOW joins them by the reported WindowRecord address.
public enum QDTraceDecode {
    public struct Drain: Equatable, Sendable {
        public struct Record: Equatable, Sendable {
            public var port: String
            public var a5: String
            public var psn: String
            public var displayEpoch: Int
            public var generation: Int
            public var op: DisplayOp
            /// `line` records use the wire's `pen` field for pen size, while
            /// text records use it for pen position. Keep the line value out
            /// of DisplayOp.pen so a future renderer cannot confuse them.
            public var penSize: [Int]?
            public var detailless: Bool
            /// `blitsrc` records only: the offscreen port whose accumulated
            /// ops the following `bits` record reveals. Kept off DisplayOp —
            /// the join is the content plane's job, and a record the
            /// renderer never draws has no business in the render IR.
            public var srcPort: UInt32?

            public init(port: String, a5: String, psn: String,
                        displayEpoch: Int, generation: Int, op: DisplayOp,
                        penSize: [Int]? = nil, detailless: Bool = false,
                        srcPort: UInt32? = nil) {
                self.port = port
                self.a5 = a5
                self.psn = psn
                self.displayEpoch = displayEpoch
                self.generation = generation
                self.op = op
                self.penSize = penSize
                self.detailless = detailless
                self.srcPort = srcPort
            }

            /// The WindowRecord/GrafPort pointer as a numeric join key.
            public var portAddress: UInt32? {
                guard port.hasPrefix("0x") else { return nil }
                return UInt32(port.dropFirst(2), radix: 16)
            }
        }

        public var records: [Record] = []
        public var cursor = 0
        public var nextCursor = 0
        public var writeCursor = 0
        public var pending = 0
        public var reportedRecords = 0
        public var wraps = 0
        public var more = false
        public var resync = false
        public var torn = false
        public var busy = false
        public var lostBytes = 0
        public var dropped = 0
        public var detailless = 0
        public var truncatedText = 0
        public var undrawn: [String: Int] = [:]

        public init() {}

        public var recordCountAgrees: Bool {
            if torn || busy { return records.isEmpty }
            return records.count == reportedRecords
        }
    }

    /// Nil means the object answered a different qdtrace subcommand, not an
    /// empty drain. Those are different claims about the machine.
    public static func drain(_ object: [String: Any]) -> Drain? {
        guard object["cmd"] as? String == "drain" else { return nil }
        var out = Drain()
        func int(_ key: String) -> Int {
            SceneBuilder.intValue(object[key]) ?? 0
        }
        func bool(_ key: String) -> Bool {
            (object[key] as? NSNumber)?.boolValue ?? false
        }

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

        for raw in (object["ops"] as? [Any]) ?? [] {
            guard let dictionary = raw as? [String: Any],
                  let record = record(from: dictionary) else { continue }
            out.records.append(record)
            if record.detailless { out.detailless += 1 }
            if (dictionary["trunc"] as? NSNumber)?.boolValue == true {
                out.truncatedText += 1
            }
            if let name = undrawnName(record) {
                out.undrawn[name, default: 0] += 1
            }
        }
        return out
    }

    static func record(from dictionary: [String: Any]) -> Drain.Record? {
        guard let port = dictionary["port"] as? String,
              let a5 = dictionary["a5"] as? String,
              let psn = dictionary["psn"] as? String,
              let displayEpoch = SceneBuilder.intValue(dictionary["displayEpoch"]),
              let generation = SceneBuilder.intValue(dictionary["generation"]),
              displayEpoch > 0, generation > 0,
              var op = DisplayOp(fetched: dictionary) else { return nil }
        let detailless = (dictionary["detail"] as? NSNumber)
            .map { !$0.boolValue } ?? false
        var penSize: [Int]?
        if op.op == "line" {
            penSize = op.pen
            op.pen = nil
        }
        var srcPort: UInt32?
        if op.op == "blitsrc", let raw = dictionary["srcPort"] as? String,
           raw.hasPrefix("0x") {
            srcPort = UInt32(raw.dropFirst(2), radix: 16)
        }
        return .init(port: port, a5: a5, psn: psn,
                     displayEpoch: displayEpoch, generation: generation,
                     op: op, penSize: penSize,
                     detailless: detailless, srcPort: srcPort)
    }

    /// Mirrors DisplayReplay's supported vocabulary without making the core
    /// MirrorKit module depend on MirrorKitUI.
    static func undrawnName(_ record: Drain.Record) -> String? {
        if record.detailless { return "\(record.op.op) (no detail)" }
        switch record.op.op {
        case "text", "line", "bits":
            return nil
        case "blitsrc":
            // Not a drawing op: the content plane consumes it as the join
            // key for the bits record that follows, and it never reaches
            // the renderer at all.
            return nil
        case "rect", "rrect", "oval":
            switch record.op.verb ?? 0 {
            case 0, 1, 2, 4: return nil
            case 3: return "\(record.op.op) (invert)"
            default: return "\(record.op.op) (verb \(record.op.verb ?? 0))"
            }
        case "rgn":
            switch record.op.verb ?? 0 {
            case 0, 1, 2, 4: return "rgn (bounds only)"
            case 3: return "rgn (invert)"
            default: return "rgn (verb \(record.op.verb ?? 0))"
            }
        case "state":
            switch record.op.kind {
            case "origin", "clip", "fg", "bg": return nil
            case let kind?: return "state/\(kind)"
            case nil: return "state"
            }
        default:
            return record.op.op
        }
    }
}
