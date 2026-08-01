import Foundation

/// One QuickDraw operation captured by QDPeek and drained via `qdtrace fetch` —
/// the content-plane vocabulary (QDPEEK-SPEC.md). A window's `display` is an
/// ordered list of these; the renderer replays them in order (later ops paint
/// over earlier, like the guest framebuffer). Coordinates are port-local
/// (window content space); a `state` op with kind `origin` shifts them.
///
/// This is the host mirror of the guest's ring records — one flat struct over
/// every op family so it rides the Codable scene IR without a per-op type.
public struct DisplayOp: Codable, Equatable, Sendable {
    /// "text" | "line" | "rect" | "rrect" | "oval" | "arc" | "poly" | "rgn" |
    /// "bits" | "state".
    public var op: String
    /// TickCount at capture (ordering within a frame).
    public var ticks: Int

    // text
    public var text: String?
    public var pen: [Int]?        // [h, v]
    public var font: Int?
    public var size: Int?
    public var face: Int?

    // shapes (rect/rrect/oval/arc/poly/rgn)
    public var verb: Int?         // GrafVerb: 0 frame 1 paint 2 erase 3 invert 4 fill
    public var rect: [Int]?       // [l, t, r, b]
    public var ext: [Int]?        // ovalW/H (rrect) or angles (arc)

    // line
    public var from: [Int]?       // [h, v]
    public var to: [Int]?         // [h, v]

    // state
    public var kind: String?      // "origin" | "clip" | "fg" | "bg"
    public var origin: [Int]?     // [h, v]
    public var rgb: [Int]?        // [r, g, b] 0-65535

    // bits (geometry only)
    public var src: [Int]?        // [l, t, r, b]
    public var dst: [Int]?        // [l, t, r, b]

    public init(op: String, ticks: Int) {
        self.op = op
        self.ticks = ticks
    }

    /// Build one op from a `qdtrace fetch` result dict.
    public init?(fetched dict: [String: Any]) {
        guard let op = dict["op"] as? String else { return nil }
        self.op = op
        self.ticks = SceneBuilder.intValue(dict["ticks"]) ?? 0
        func ints(_ k: String) -> [Int]? {
            (dict[k] as? [Any])?.compactMap(SceneBuilder.intValue)
        }
        text = dict["text"] as? String
        pen = ints("pen"); font = SceneBuilder.intValue(dict["font"])
        size = SceneBuilder.intValue(dict["size"])
        face = SceneBuilder.intValue(dict["face"])
        verb = SceneBuilder.intValue(dict["verb"])
        rect = ints("rect"); ext = ints("ext")
        from = ints("from"); to = ints("to")
        kind = dict["kind"] as? String
        origin = ints("origin"); rgb = ints("rgb")
        src = ints("src"); dst = ints("dst")
    }
}
