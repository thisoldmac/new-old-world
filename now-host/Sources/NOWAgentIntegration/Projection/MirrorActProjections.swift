import Foundation

/// **The act plane's rows, as one group — registered 2026-07-31, and served
/// by the PowerPC guest since later the same day.**
///
/// `HostProjectionCatalog` is the published surface: a row in it is a tool an
/// agent can call. These five are in it. Whether one ANSWERS is settled
/// against the connected machine's own `help` table, which is the whole point
/// of the design below.
///
/// ## CORRECTED 2026-07-31 — this file used to say "served by no Macintosh"
///
/// It was written in the morning, when the rows were registered against a
/// contract that declared their commands and a guest that served none of
/// them, and it argued at length that `unavailable` from a machine that said
/// no is a different fact from `unavailable` from a requirement that resolved
/// to nothing. **That argument still stands and is the reason the rows were
/// shaped this way.** What changed is the answer: the PowerPC guest now
/// serves `winact`, `textget`, `textset`, `ctlact` and `menuact`, and — the
/// piece that was actually blocking — the reference layer beneath them, so
/// the references these rows require can be minted at all. The corrections
/// are recorded rather than typed over, because the reasoning is what a later
/// reader needs and the old status is what makes it legible.
///
/// Three specific claims that were true and are not:
///
/// - "Nothing serves the act plane today." The PowerPC guest serves all five
///   commands. NOW-68K serves none, which is a fact its own `help` table
///   states and nothing on this side asks about.
/// - "There is no observation that mints the references." There is:
///   `now_observe_elements`, registered with the observations rather than
///   here — see the group note below.
/// - "A menu row is deliberately absent." The mechanism it was waiting on
///   landed, so `now_menu_act` is here. Its identity check is a coordinate
///   rather than a reference, which is the one place this plane's addressing
///   grammar bends and the reason is stated in full in that row.
///
/// ## What is still true, and still owed
///
/// - **The host owed a lane, and it landed 2026-08-01.** This entry used to
///   read "the host owes a lane… a call today reaches no wire". Five local
///   operations now carry the five acts to the guest's ordinary command
///   dispatch — NOT the transfer lane, which would make a click in a
///   rendered scene refuse itself for the duration of the stream drawing
///   that scene (`AgentIntegrationActControl`). `noActLane` survives as the
///   protocol default, reachable only by the stub clients in the test tree.
/// - **What a row still cannot address is a SCENE's control.** The lane
///   takes an opaque `now-element-…`; `MirrorKit.Scene.Control.ref` is where
///   one would arrive and NOW's producer emits `""`. So the five capabilities
///   answer, and a person clicking a rendered control is told which half is
///   missing rather than shown a positional click
///   (`MirrorActionDriver`).
/// - **The guest revalidates, not the host.** A reference is checked against
///   a live element by the side that owns the heap. A host-side match would
///   be a stale observation wearing the clothes of a live one.
/// - **A dispatch is all any of them may claim.** No `performed: true`
///   meaning "and it worked" — see `AgentIntegrationActDispatch`.
/// - **No ISA check anywhere, and none is owed.** These are commands, so
///   availability is derived from the connected guest's own table exactly as
///   `reveal`, `gestalt` and `tail` are. Nothing here asks which guest
///   answered.
///
/// ## What is still deliberately absent
///
/// - **A general Apple Event verb.** Mirror has one; projecting it would be
///   a transliteration rather than a fitting. NOW already projects the
///   specific events it needs as their own bounded rows — `now_launch_software`,
///   `now_reveal_item`, `now_request_quit`, `now_bring_to_front` — each with
///   a target grammar and a receipt. A row that takes an event class and id
///   is a row whose arguments cannot bound what it does, which is the
///   opposite of the property these rows are built on. It wants its own
///   design pass, not a slot in this list.
/// - **A pane.** Each row's `.appUI` face is `notReached` with its reason,
///   and all five are in `HostFaceParityTests.appUIDivergences`. Rule 3 is
///   owed, not waived: the affordance lands with the scene view that RENDERS
///   what `now_observe_elements` can now fetch, because there is nothing for
///   a person to click until there is something to click ON. Still true on
///   2026-08-01 with the lane built: `MirrorActionDriver` is the seam a pane
///   would call, and the Mirror page passes it no gestures yet, because the
///   renderer has no hit-testing wired into it. A driver with no caller is
///   the half that could be finished without a machine; the pane is the half
///   that wants one.
public enum MirrorActProjections {
    /// The act rows, in the order they are registered: the window, the
    /// control inside it, the menu bar above it, then the read and the write.
    ///
    /// Kept as a group after registration rather than dissolved into the
    /// catalog, because the properties in `MirrorActProjectionTests` are
    /// about the PLANE — one addressing grammar, one dispatch vocabulary,
    /// one refusal of a target-free selector — and a test that had to
    /// re-derive which catalog rows are act rows would be a second spelling
    /// of this list.
    ///
    /// **`now_observe_elements` is deliberately not in it**, though it landed
    /// in the same edit as two of these and every one of them depends on it.
    /// This list is what a suite of act-plane properties runs over, and it
    /// is not an act: it changes nothing, it answers a tree rather than a
    /// dispatch, it sits a consent tier below every row here, and it has no
    /// target at all — a call naming no process is a legal call meaning "the
    /// frontmost". Every one of those is a property this group's tests
    /// assert the opposite of, so including it would either fail them or
    /// force them to carve out the one row they were written about. It is
    /// registered with the observations, where it belongs.
    // The catalog explains the Swift 6.1/6.2 erased-metatype diagnostic
    // transition. One factory keeps both compiler declarations on one list.
#if compiler(>=6.2)
    public nonisolated(unsafe) static let rows = makeRows()
#else
    public static let rows = makeRows()
#endif

    private static func makeRows() -> [any HostProjection.Type] { [
        WindowActProjection.self,
        ControlActProjection.self,
        MenuActProjection.self,
        TextGetProjection.self,
        TextSetProjection.self,
    ] }

    /// The requirements the whole plane rests on, for the test that checks
    /// no row requires anything outside it.
    public static let requirements = AgentIntegrationCapabilityNames.actPlane
}
