import Foundation

/// **The cheap question the Mirror page asks between scenes.**
///
/// A scene is a transfer on the one bulk lane (`docs/streaming-a-scene.md`);
/// this is a control message that takes no lane at all. The contract picks it
/// out by name — `axsnap` is *"the cheap one … no walk, so no minting — the
/// one call on this surface that is safe to poll"* — which is the whole
/// reason the watch loop can run at half a second without spending a transfer
/// at half a second.
///
/// ## What the token is made of, and what it deliberately leaves out
///
/// The token is the front process's IDENTITY plus whether it has windows and
/// menus at all. Two fields of the reply are excluded, and both exclusions
/// are load-bearing:
///
/// - **`stampTicks`** is the bind sample's own `TickCount` and changes on
///   every call (`now-guest-ppc/src/observe/observe.c`, `emit_process_head`).
///   Folding it in would make every probe report a change, which is a poll
///   wearing a probe's clothes: the same transfer every tick, plus a control
///   round trip for the privilege.
/// - **`references.live/minted/evicted`** count what OTHER callers have
///   observed. An agent taking an observation would move them without
///   anything on the screen having moved, and the page would fetch for
///   somebody else's activity.
///
/// ## What it cannot see, said out loud
///
/// A window dragged inside one application does not change any field here, so
/// the probe answers "nothing moved" when something did. That is a **partial
/// signal by construction**, not a bug to be fixed with more fields — the
/// front-process block is all `axsnap` reports. The watch loop is built
/// around that: its refresh ceiling fetches regardless, so an unseen change
/// costs bounded staleness. A probe treated as complete would be worse than
/// no probe, because the page would sit on a wrong picture calling itself
/// live.
enum MirrorSceneProbe {
    static let command = "axsnap"

    /// What one probe reply came to. Three cases, because "the machine
    /// answered", "the machine cannot answer this" and "nothing came back"
    /// are three different things to do next — and a boolean would fold the
    /// last two together, which is how a momentary silence turns into a
    /// permanently disabled probe.
    enum Reading: Equatable {
        case token(String)
        /// The guest answered, and the answer was that it does not serve
        /// this. The reason is the guest's own words.
        case unsupported(String)
        /// No answer to read: not connected, a dropped link, a timeout.
        case unanswered
    }

    static func read(_ result: CommandResult) -> Reading {
        guard result.ok else {
            guard let error = result.error else {
                return .unsupported("it refused without saying why")
            }
            /* A refusal that is about the WIRE is not a statement about the
               command. Disabling the probe on one of these would let a
               reconnect race permanently downgrade the loop. */
            let transport = ["not-connected", "disconnected", "timeout",
                             "silence"]
            if transport.contains(error.code) { return .unanswered }
            return .unsupported("\(error.message) [\(error.code)]")
        }
        guard case .object(let snap)? = result.outputObjects?[command],
              case .object(let front)? = snap["front"] else {
            /* ok:true with nothing readable under `axsnap`. Not silence and
               not a refusal — a guest answering a shape this side cannot
               use is a guest this probe cannot be run against. */
            return .unsupported("its answer carried no front process")
        }
        return .token(token(front: front))
    }

    /// The identity fields, in a fixed order so two equal machines produce
    /// one string. Missing keys are spelled as the empty field rather than
    /// skipped: a reply that stops carrying `bind` must read as a DIFFERENT
    /// token, not as the same one shorter.
    static func token(front: [String: JSONValue]) -> String {
        ["name", "signature", "serialHi", "serialLo", "front", "bind",
         "hasWindows", "hasMenus"]
            .map { scalar(front[$0]) }
            .joined(separator: "\u{1F}")
    }

    private static func scalar(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            return n == n.rounded() && abs(n) < 9.007199254740992e15
                ? String(Int(n)) : String(n)
        case .null, .none: return ""
        /* Neither shape belongs in the front block. They are spelled
           differently from each other and from every scalar, so a reply
           that changed shape cannot read as an unchanged token. */
        case .array: return "[]"
        case .object: return "{}"
        }
    }
}
