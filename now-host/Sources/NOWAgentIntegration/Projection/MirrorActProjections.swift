import Foundation

/// **The act plane's rows, written and not yet registered — with the exact
/// reason, and the exact steps that register them.**
///
/// `HostProjectionCatalog` is the published surface: a row in it is a tool an
/// agent can call. These three are not in it, and that is a decision rather
/// than an oversight.
///
/// ## Why they are not registered
///
/// NOW's contract declares no act plane. `contract/asyncapi.yaml` has no
/// `winact` / `textget` / `textset` among its commands, and no guest
/// dispatches them. A registered row would therefore be a published tool
/// whose requirement resolves to nothing in the capability ledger — which
/// fails nowhere at run time and is the specific trap `MCPCoverageTests
/// .testEveryRequirementResolvesToTheContract` was written to catch: the
/// ledger falls through to the command table, misses, and the tool reports
/// itself permanently unavailable against every guest, in a sentence that
/// reads as a fact about the Macintosh.
///
/// Registering them would not make the capability real; it would make the
/// gate that says it is not real go red. So the rows land complete and
/// unregistered, and this list is what keeps them gated in the meantime:
/// `MirrorActProjectionTests` runs the registry's own properties over these
/// three, so they are held to the published rows' standard before they are
/// published.
///
/// ## What the guest must implement
///
/// Nothing here invents a wire message, and the guest work is not started.
/// For any of these three to answer anything but `unavailable`, the guest
/// needs, in this order:
///
/// 1. **Three commands in its `help` table** — `winact`, `textget`,
///    `textset` — because that table is how the capability ledger settles a
///    command, and it is what makes the act plane PowerPC-only by derivation
///    rather than by an ISA check anyone writes.
/// 2. **An identity-addressed element observation that MINTS the
///    references** these rows take (`now-window-…`, `now-element-…`) and can
///    map one back to a live `WindowPtr` / `ControlHandle`. Without it there
///    is no legal argument to send, and there must be no fallback that
///    addresses "the frontmost window" — that fallback is the measured
///    18/20 hijack.
/// 3. **Revalidation at the guest, before dispatch.** The reference is
///    checked against a live element by the side that owns the heap. A
///    host-side match would be a stale observation wearing the clothes of a
///    live one.
/// 4. **A dispatch that answers the application's own `FindWindow` / text
///    path**, so the application does what it would have done. No
///    synthesised mouse motion and no QMP: that is what keeps the plane
///    inside the no-host-side-cheating rule, and it is what upstream
///    measured 20/20 on each of four window ops.
/// 5. **A reply that claims only dispatch.** No `performed: true` meaning
///    "and it worked" — see `AgentIntegrationActDispatch`.
///
/// ## What registering them takes, once the guest serves them
///
/// - Move the three constants out of the extension in `MirrorActModels.swift`
///   into `AgentIntegrationCapabilityNames`, and add them to its `all` set.
/// - Declare the three commands in `contract/asyncapi.yaml` under
///   `x-commands`. They are COMMANDS, so no `familyPolicy` row is owed.
/// - Promote the three client methods from extension methods to protocol
///   requirements on `AgentIntegrationClient`, keeping the present bodies as
///   their defaults — one edit, no conformer broken.
/// - Add the three types to `HostProjectionCatalog.projections`, beside the
///   process drive verbs.
/// - Flip each row's `.mcp` face to `.reachedByRegistry`, and add a row per
///   capability to `docs/mcp-coverage.md`.
/// - The `.appUI` face stays `notReached` with its stated reason until a
///   pane can select an element; rule 3 is owed, not waived.
///
/// ## What is deliberately absent
///
/// - **A menu row.** Upstream's `MENU_INVOKE` is its own defect 0 and was
///   actively being worked on 2026-07-31; the plan's stop condition is
///   explicit that a mechanism in flight must not be folded. Its measured
///   arc (hijack 18/20 → 0/19) is already reflected here in the refusal to
///   offer a target-free form, which is the portable half.
/// - **A general Apple Event verb.** Mirror has one; projecting it would be
///   a transliteration rather than a fitting. NOW already projects the
///   specific events it needs as their own bounded rows — `now_launch_software`,
///   `now_reveal_item`, `now_request_quit`, `now_bring_to_front` — each with
///   a target grammar and a receipt. A row that takes an event class and id
///   is a row whose arguments cannot bound what it does, which is the
///   opposite of the property the other three are built on. It wants its own
///   design pass, not a slot in this list.
public enum MirrorActProjections {
    /// The three rows, in the order they would be registered: the window
    /// act beside the other drive verbs, then the read, then the write.
    public static let pending: [any HostProjection.Type] = [
        WindowActProjection.self,
        TextGetProjection.self,
        TextSetProjection.self,
    ]

    /// The requirements the whole plane rests on, for the test that checks
    /// no row requires anything outside it.
    public static let requirements = AgentIntegrationCapabilityNames.actPlane
}
