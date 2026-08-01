import Foundation

/// **The act plane's rows, as one group — registered 2026-07-31, and served
/// by no Macintosh.**
///
/// `HostProjectionCatalog` is the published surface: a row in it is a tool an
/// agent can call. These three are in it now. What they answer, on every
/// machine that exists, is `unavailable`.
///
/// ## Why that is the honest state and not the trap it resembles
///
/// These rows landed built and UNREGISTERED, deliberately, and the reason was
/// exact: NOW's contract declared no act plane, so a registered row would
/// have published a tool whose requirement resolved to nothing. That failure
/// is invisible at run time — the capability ledger looks the name up among
/// the message families, misses, falls through to the guest's command table,
/// misses again, and reports the tool permanently unavailable in a sentence
/// that reads as a fact about the Macintosh. `MCPCoverageTests
/// .testEveryRequirementResolvesToTheContract` exists to catch exactly that,
/// and it did.
///
/// The fold closed it from the other end. `winact`, `textget` and `textset`
/// are now declared in `contract/asyncapi.yaml` under `x-commands` — legal by
/// that file's own rule, which makes adding a command additive and has a peer
/// that does not serve one answer `unknown-command` cleanly. So the three
/// names resolve as COMMANDS, and a command's availability is settled against
/// the connected guest's own `help` table. The row is unavailable **because
/// the machine said so**. Same words to a caller, entirely different fact,
/// and it is the fact that makes the plane PowerPC-only later by derivation —
/// exactly as `reveal`, `gestalt` and `tail` are today, with nothing on this
/// side asking which guest answered. **There is no ISA check anywhere in this
/// slice and none is owed.**
///
/// ## What the guest must implement
///
/// Nothing here invents a wire message, and the guest work is not started.
/// For any of these three to answer anything but `unavailable`, the guest
/// needs, in this order:
///
/// 1. **Three commands in its `help` table** — `winact`, `textget`,
///    `textset` — because that table is how the capability ledger settles a
///    command. Until then, `CommandRegistryTests.servedByNoGuestYet` carries
///    the debt with its reason, and fails the day one of the three is served
///    and the exemption is not removed.
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
/// The HOST also still owes a lane: the three client methods are protocol
/// requirements whose defaults answer `AgentIntegrationUnavailable.noActLane`
/// because no local operation carries an act. That is the second half, and it
/// is worth building only after the first.
///
/// ## What is still deliberately absent
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
/// - **A pane.** Each row's `.appUI` face is `notReached` with its reason,
///   and the three are in `HostFaceParityTests.appUIDivergences`. Rule 3 is
///   owed, not waived: the affordance lands with the scene view that mints
///   the references these rows take, because there is nothing for a person
///   to click until there is something to click ON.
public enum MirrorActProjections {
    /// The three rows, in the order they are registered: the window act
    /// beside the other drive verbs, then the read, then the write.
    ///
    /// Kept as a group after registration rather than dissolved into the
    /// catalog, because the properties in `MirrorActProjectionTests` are
    /// about the PLANE — one addressing grammar, one dispatch vocabulary,
    /// one refusal of a target-free selector — and a test that had to
    /// re-derive which catalog rows are act rows would be a second spelling
    /// of this list.
    public static let rows: [any HostProjection.Type] = [
        WindowActProjection.self,
        TextGetProjection.self,
        TextSetProjection.self,
    ]

    /// The requirements the whole plane rests on, for the test that checks
    /// no row requires anything outside it.
    public static let requirements = AgentIntegrationCapabilityNames.actPlane
}
