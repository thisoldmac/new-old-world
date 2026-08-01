import Foundation

/// The standard modifier bits `mods` may combine, and the mask that bounds
/// them.
///
/// **CORRECTED 2026-08-01.** This lived as a comment on `mods` claiming "0 is
/// the only value the guest accepts", which was true before tonight's
/// contract change and is not true now: the act plane's own `key` op stamps a
/// nonzero modifier from inside the resident extension's filter when one is
/// present, current and pumping the target's event loop
/// (`contract/asyncapi.yaml:key`, `AgentIntegrationActControl.key`). What
/// stays true either way is the shape of the refusal: a value outside this
/// mask names bits no modifier owns, and the contract calls that bad-request
/// rather than something for the guest to interpret.
public enum AgentIntegrationKeyModifierPolicy {
    public static let cmd = 256
    public static let shift = 512
    public static let alphaLock = 1024
    public static let option = 2048
    public static let control = 4096

    /// Every bit a caller may legally set, ORed together. Not the guest's to
    /// enumerate — a bit outside this mask is not a modifier this contract
    /// has a name for, so it is refused before the request is built rather
    /// than forwarded for the guest to puzzle over.
    public static let mask = cmd | shift | alphaLock | option | control

    public static func isValid(_ mods: Int) -> Bool {
        mods & ~mask == 0
    }
}

/// One validated keystroke, addressed to the guest's `key` verb
/// (`now-guest-ppc/src/input/input_cmds.c:now_input_run_key`,
/// `contract/asyncapi.yaml:key`).
///
/// **`mods` is carried and not decorative.** `mods == 0` posts through the
/// guest's plain event queue as it always has. A nonzero `mods` now routes
/// through the act plane's own key op (`contract/asyncapi.yaml:key`, "THE
/// ROUTE, AS OF 2026-08-01"), served by the NOW Extension's 68K resident
/// filter — the same reach `winact` and `menuact` already use, and reachable
/// from there for the same reason it is not from CarbonLib: an event's
/// modifiers live on the Event Manager's queue element, the only call that
/// hands that element back is `PPostEvent`, and that is `CALL_NOT_IN_CARBON`
/// for this Carbon application's own code. Whether the route is ARMED right
/// now (extension present, current, target pumping) is a fact about the
/// paired guest, not one this type or `ActionModel.availability` can know in
/// advance — so this type sends whatever `mods` its caller computed,
/// honestly, and lets the guest's own reply (surfaced through
/// `AgentIntegrationActControl.key`) say ok or name which of those it was.
/// Posting the keystroke and silently dropping the modifier would type a
/// bare character and answer `ok` — the exact defect this design refuses to
/// make, in either the armed or the unarmed case.
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
    /// `evtQModifiers` bits: cmd=256, shift=512, alphaLock=1024, opt=2048,
    /// ctrl=4096 (`AgentIntegrationKeyModifierPolicy`). 0 (or omitted) never
    /// touches the act plane; a nonzero value inside the mask is carried to
    /// the guest, which answers or refuses `unsupported` depending on
    /// whether the resident route is armed. See the type's own header.
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
    /// it costs a round trip — and `mods` inside the modifier mask, the
    /// contract's own bad-request line (`contract/asyncapi.yaml:key`).
    public var isWellFormed: Bool {
        (!(name?.isEmpty ?? true) || code != nil || char != nil)
            && AgentIntegrationKeyModifierPolicy.isValid(mods)
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
