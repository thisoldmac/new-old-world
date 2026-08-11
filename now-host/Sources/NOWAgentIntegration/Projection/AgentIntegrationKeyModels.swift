import Foundation

/// One validated keystroke, addressed to the guest's `key` verb
/// (`now-guest-ppc/src/input/input_cmds.c:now_input_run_key`,
/// `contract/asyncapi.yaml:key`).
///
/// **`mods` is carried and not decorative.** The guest accepts exactly one
/// value for it — 0 — and refuses anything else with `unsupported`: an
/// event's modifiers live on the Event Manager's queue element, and the
/// only call that hands that element back is `PPostEvent`, which CarbonLib
/// does not have (`CALL_NOT_IN_CARBON`). Posting the keystroke and dropping
/// the modifier would type a bare character and answer `ok` — the exact
/// defect upstream's act plane was rewritten to stop making. So this type
/// sends whatever `mods` its caller computed, honestly, and lets the guest's
/// own refusal (surfaced through `AgentIntegrationActControl.key`) be the
/// one place that says no — the same discipline `ActionModel.availability`
/// applies before a call is even built, so the two cannot disagree about
/// the same keystroke.
///
/// One of `name` or (`code`/`char`) must be present — the guest's own rule,
/// checked again here so a malformed request is refused before it reaches
/// the wire rather than answered by a guest that has to decode more of it
/// than a caller sent.
public struct AgentIntegrationKeyRequest: Codable, Equatable, Sendable {
    /// A named key with no character of its own — Return, Tab, the arrows.
    /// The guest's own enum (`contract/asyncapi.yaml:key.args.name`); an
    /// unrecognized string is the guest's to refuse, not this type's.
    public let name: String?
    /// The virtual key code, 0..127 (the message's second byte). The Menu
    /// Manager and Finder shortcut matching read this half, not the
    /// character — sending only a character silently no-ops there
    /// (upstream, `docs/mcp-coverage.md`).
    public let code: Int?
    /// The character code, 0..255 (the message's low byte).
    public let char: Int?
    /// `evtQModifiers` bits: cmd=256, shift=512, opt=2048, ctrl=4096
    /// (`ActionModel.cmdKey`). 0 is the only value the guest accepts.
    public let mods: Int

    public init(name: String? = nil, code: Int? = nil, char: Int? = nil,
                mods: Int = 0) {
        self.name = name
        self.code = code
        self.char = char
        self.mods = mods
    }

    /// At least one of a name, a code or a character — the guest's own
    /// `kNowKeyNoKey` gate, read here so an empty request is refused before
    /// it costs a round trip.
    public var isWellFormed: Bool {
        !(name?.isEmpty ?? true) || code != nil || char != nil
    }
}

/// What one keystroke produced.
///
/// **`posted`, never `typed`.** The keystroke entered the guest's event
/// queue; which application dequeued it and what it did with it is the
/// caller's to read back from a fresh observation — the same rule
/// `AgentIntegrationMenuActReceipt.dispatch` states for a menu command, and
/// `aesend`'s `sent` states for an Apple Event. `code` and `char` are
/// echoed as the guest resolved them, because a caller who sent only a
/// `name` or only a `char` needs to see the half the guest derived to know
/// what it actually posted.
public struct AgentIntegrationKeyReceipt: Codable, Equatable, Sendable {
    public let code: Int
    public let char: Int
    public let posted: Bool
    public let postedAt: Date

    public init(code: Int, char: Int, posted: Bool, postedAt: Date) {
        self.code = code
        self.char = char
        self.posted = posted
        self.postedAt = postedAt
    }
}

public typealias AgentIntegrationKeyResult =
    AgentIntegrationProjectedResult<AgentIntegrationKeyReceipt>
