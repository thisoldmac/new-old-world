# The scene producer

**Date:** 2026-07-31 · **Status:** built and natively tested; **never run on a
Macintosh** · **Code of record:** `now-guest-ppc/src/scene/`, gates in
`now-guest-ppc/tests/scene_build_test.c`, `scene_json_test.c` and
`scene_walk_test.c`

M5 of [the fold-in plan](plans/2026-07-31-007-feat-now-mirror-integration-plan.md):
NOW's guest producing Mirror's frozen v1 scene IR (`mirror/docs/IR-V1.md`) over
the part of the machine it can honestly walk today. The companion is
[streaming-a-scene.md](streaming-a-scene.md), which argued how a scene should
travel; this note records what was built and what it refuses to claim.

## What it produces, and what it refuses to

| IR v1 field | Here |
|---|---|
| `version`, `seq`, `capturedAt`, `source` | produced |
| `screen.{w,h}` | produced (main device `gdRect`) |
| `apps[].{psn,name,front}` | produced |
| `apps[].error` | produced — this is where the anchor verdicts surface |
| `processes[].{psn,name,front,signature}` | produced (Process Manager) |
| `windows[].{id,app,psn,title,rect,front,z,visible}` | produced (validated anchor walk) |
| `meta.{errors,plane,latencyMs}` | produced; `meta.bytes` absent |
| `menubar.{app,menus[]}`, `menus[].items[]` | **conditional** — the front process only, when its bind and its menu list both succeeded |
| `windows[].controls[]`, `.text`, `.kind` | **conditional** — per window, when that window's walk ran and completed |
| `windows[].ref`, `windows[].controls[].ref` | **conditional** — per element, when the reference layer could name it |
| `menus[].apple`, `controls[].{role,checked}` | **absent** — nothing this walk reads determines them |
| `windows[].display[]`, `.items[]` | **absent** |
| `desktopItems[]` | **absent** |

**Absent, not empty, and the difference is the whole point.** An empty
`controls` array asserts *this window has no controls*; an absent key says
*this producer does not report controls*. Those are different claims about a
real machine, and only one of them is true here. It is this repository's rule
(`AGENTS.md`: record unknowns as absent keys, never guesses) and it is also what
IR v1's additive discipline expects of a partial producer. `scene_json_test.c`
fails if any of those key names appears in an encoded scene at all — a test that
only checked the fields we *do* emit would pass while the encoder quietly
shipped `"controls":[]` and taught every consumer a false fact.

`meta.errors` is the one array emitted even when empty, because it is not an
unreported plane: it is the list of things that went wrong during a walk that
did happen, and zero of them is a real answer.

### Conditional is a third state, and it is the hard one

Two states were easy: a plane is produced, or it is absent. The walk introduced
a third, and it is where a producer most easily starts lying. `controls` on one
window and no `controls` on the next are **both correct** in the same scene, and
which one appears is a fact about what the walk could do, not about which
version of the code is running.

So each row carries a *presence bit* beside its contents, and the three states
are three different documents:

| The row's state | Encoded | Means |
|---|---|---|
| walked, has some | `"controls":[…]` | these are all of them |
| walked, has none | `"controls":[]` | **this window has no controls** |
| not walked | *(no key)* | this producer did not report them here |

`scene_json_test.c`'s `test_conditional_planes` builds all three **in one
scene**, because an encoder that emitted the same thing everywhere would
satisfy any one of them alone.

Two rows never contribute: **our own process**, because NOW is Carbon and its
records are not at these classic offsets (`axprocess.h` says the same about the
walk it belongs to, and `scene_collect.c` skips self explicitly rather than
letting a wrong read fail closed by luck); and any process whose anchor verdict
does not admit data, which `now_scene_open_menubar` refuses *independently* of
the collector the way `now_scene_add_window` already did.

### A truncation that cannot be attributed is retracted, not reported short

`meta.errors` can say *"windows truncated"* because a scene has one `windows`
array for the notice to be about. It cannot say **which window's** controls
stopped early, and a short list with nothing beside it reads as a complete one.

So when a window's control chain hits its bound, cycles, or meets a pointer that
fails validation, the whole sub-plane is **dropped for that window** — the key
goes absent — and a `meta.errors` line records that a drop happened. Same for a
menu's items, and for the menu bar itself when its list will not parse. The
retraction always reports; a drop nobody can see would be exactly the partial
walk delivered as a complete one that the whole design refuses.

### Why there are menus now

The menu walk was blocked for a **citation** reason rather than an effort one:
`MenuInfo`'s `menuData` at offset 14 is citable (Universal Interfaces 3.4), but
the structure `LMGetMenuList()` returns — the header plus the entry array —
appears in no header in this toolchain, and writing its stride from memory would
have been a phantom constant in code that dereferences another process's heap.

The port closed it with a measurement rather than a guess: `timbottu/mirror`'s
`axmenu.c` carries a 6-byte header and 6-byte entries, measured against a live
Mac OS 9.1 Finder, with the `14` this project had already confirmed from
published documentation as the independent check on the other two. Those
constants live in `src/axwalk/axmenu.c` beside the code that uses them, and
`axmenu_test.c` pins them by value.

**`now_peek_menu_titles` is no longer a stub** (2026-07-31). It binds through
the same anchor plane the window walk uses and answers in the same five words.
Two things about its contract differ from the window calls and are deliberate:
`kNowPeekReadOk` with **zero** titles is a real answer, because a faceless
process genuinely has no menu bar and there is no `NoMenus` in this vocabulary
to spend on it; and **self returns `kNowPeekReadStub`**, precisely — NOW's own
menu bar exists and wants the Toolbox, so *"a plane whose walk is not built
yet"* is exactly true of it. `now_not_walked` still reaches the wire, now
meaning something narrower than it did.

### The reference plane

*Landed 2026-08-01.* `windows[].ref` and `windows[].controls[].ref` carry a
token minted by the guest's observation registry (`now-window-…` /
`now-element-…`), resolvable by `now_observe_resolve_window` /
`now_observe_resolve_element`. Before it, a rendered scene drew chrome, titles,
menus and controls and **nothing was clickable**: every control's `ref` was
empty, so the host's act model reported `axdo` as `needsObservation` — the
element is addressed by an opaque reference only an observation mints, and the
scene minted none.

**When it mints: during the walk, not afterwards.** This is the only moment the
addresses exist. A control is a `ControlHandle` on a chain inside another
process's heap; nothing downstream of the walk holds one, and a second pass that
re-derived them would be a second thing deciding what an element is — the defect
the reference layer was unified to remove when `act_ref.c` went away. There is
still exactly one minter and one registry: `src/observe/obsmint.c` is a *seam*
onto it, asserted structurally by `one_minter_source_test.py`, which also forbids
anything under `src/scene/` from touching the table.

**What a second fetch does: nothing.** The seam **interns** — an identity byte-
identical to a live registry entry (same process, same fingerprints, same
addresses, same title and occurrence) hands back that entry's token rather than
minting a new one. So re-fetching an unchanged desktop returns the same
references and the registry does not grow. That is not a convenience: the scene
a person is *looking at* when they click is the one from the previous fetch, so a
producer that renamed everything on every walk would make a scene actable only
until it refreshed. Anything that actually changed — a window that moved, a
process that relaunched, a control at a new handle — fails the identity match and
mints fresh, and the old token still **refuses** rather than being repaired.

**The lifetime and the capacity, which is what bounds all of it.**

| | |
|---|---|
| Registry size | `kNowObsRegistryMax` = **96** live references |
| Lifetime | the guest **session**. The seed is drawn once at startup; a reference from a previous run of the guest matches nothing (new seed, empty table) |
| Eviction | round-robin, and an evicted token is `NotFound` — never re-pointed at whatever now occupies the slot |
| A scene's demand | up to 64 windows + 96 controls = **160**, which is larger than the table |

Two consequences follow and both are handled rather than hoped about. A walk is
bracketed by a **registry epoch**, so eviction cannot take a reference *this
scene* already handed out; past the table the mint refuses, and the element's
`ref` is simply absent. And a reference is minted only for an element a
resolution could actually **reach** — resolution walks at most
`kNowAxResolveMaxWindows` (16) windows and `kNowAxResolveMaxControls` (32)
controls before answering `NotFound`, so an element past either bound gets no
reference, because one would be decoration rather than an address.

**Absence is still load-bearing here, and sharply.** An absent `ref` means *not
minted*. The empty string is never emitted: the host's own adapter reads a
present-but-empty `ref` as *"this producer has no reference layer"* and reports
the element unactionable, which is a different — and false — claim about an
element the walk merely could not reach. An over-long token is dropped rather
than clipped for the same family of reason: a shortened reference passes every
shape check on both sides of the wire and resolves to nothing, so it would
present as *"that element went away"* rather than as a producer bug.

**Contract standing.** `windows[].controls[].ref` is not an extension at all —
IR v1 promotes `windows[].controls[].*`, so this is a declared field the
producer had been leaving out. `windows[].ref` **is** an addition to IR v1's
window field set, taken deliberately under the accretive rule (additive fields
do not move `irVersion`) and written down in `contract/asyncapi.yaml` under
`guestServesScene`. A window is the other thing an act can name, so a scene that
named only controls would leave half the act plane unaddressable.

**Mutation report for the reference plane**, each watched failing 2026-08-01.
The first two are the ones that matter: a `ref` that is well formed and resolves
to nothing is *worse* than an absent one, because the renderer draws a
clickable-looking button and every press is refused.

| Mutation | Result |
|---|---|
| the mint's node fingerprint stops naming the addresses | 6 red — every minted reference resolves `Stale` |
| a control's reference filed against index 0 instead of its own row | 3 red — Cancel would act for OK, and both rows still look complete |
| the walk names the chain head instead of the window it is holding | 6 red — including the refusals for an address that is not on the chain |
| `identity_same` forced true (everything interns) | 4 red — a moved button inheriting the reference of the one that was there |
| the epoch's eviction guard disabled | 2 red — a walk eating the front of its own scene |
| `put_ref` emits the empty string instead of omitting the key | 3 red — the absent/empty split, in the plane where empty means something else |
| `copy_ref` truncates instead of refusing | 1 red — a clipped token that resolves to nothing |

### What the walked planes still do not assert

- **A control's role.** The walk reads a `ControlRecord`, not its `contrlDefProc`,
  so it cannot say whether a control is a button, a checkbox or a scroll bar.
  `role` is absent, and `checked` with it — it is meaningless without knowing
  which. A role inferred from a min/max range would be a guess wearing a fact's
  clothes. (`ref` used to be on this list and came off it on 2026-08-01; see
  *The reference plane* below.)
- **Which menu is the Apple menu.** IR v1 carries `menus[].apple`; nothing this
  walk reads determines it, so the key is absent rather than plausible.
- **Text on a non-dialog window.** A `DialogRecord`'s `TEHandle` is at 160,
  *past* the end of a 156-byte `WindowRecord`, so the text read is gated on
  `kind == 2` (`dialogKind`). Without that gate an ordinary window's read would
  interpret whatever follows its record as a TextEdit handle, and the reader's
  coherence checks only catch that most of the time. This is the one place where
  emitting `kind` earns its keep twice: it is IR v1's dialog discriminator *and*
  the guard in front of the text read.

## How the oracle's five verdicts survive

`peek_oracle.h` answers with a **verdict**, not a pointer, because three of its
five answers are cases where returning a pointer would be a lie. A scene that
flattened them would say "this process has no windows" about a process whose
anchor was refused — the single most misleading sentence this producer could
emit. So each verdict reaches the wire as a per-app token, in upstream's own
`ax_oracle_*` vocabulary wherever one exists:

| Verdict / reader state | `apps[].error` | Windows admitted? |
|---|---|---|
| `Ok` | *(absent)* | yes |
| `Stale` | `ax_oracle_stale` | **yes** — reported, never refused |
| `NotFound` | `ax_oracle_not_found` | no |
| `Ambiguous` | `ax_oracle_ambiguous` | no |
| `Mismatch` | `ax_oracle_mismatch` | no |
| reader `Unreadable` | `ax_read` | no |
| reader `NoWindows` | *(absent)* — not an error | trivially |
| reader `NoPlane` | `now_no_plane` | no |
| reader `Stub` | `now_not_walked` | no |

Two of those rows carry the design.

**Stale is derived here, because it cannot arrive from below.** `peek_read.c`
deliberately runs with **no age gate** — window state is only ever as fresh as
the target's last event-loop pass, so an old-but-clean anchor arrives as `Ok`
with an old stamp. The scene takes the stamp the reader reports beside the
window list, compares it against the caller's `TickCount` frame, and marks the
row stale *beside its data*. That is the oracle's own rule for the verdict
(REPORTED, NOT REFUSED) restated one layer up, and it is the only place in NOW
where the fifth verdict is visible at all.

**A refused verdict admits no window, and assembly enforces that itself.** The
collector asks before walking, but `now_scene_add_window` refuses independently:
a window read under an `Ambiguous` anchor would be exactly the coin-flip walk
the validation layer exists to decline, delivered as fact one layer above the
code that declined to guess. Two `now_*` tokens are prefixed differently on
purpose — the anchor plane being absent and a walk not being built are NOW's
states, not the IR's, and a consumer should be able to see at a glance whose
word it is reading.

Nothing in `src/scene/` holds a foreign pointer. Every window read goes through
`now_peek_windows_for_psn`, which validates each pointer inside the process's
partition or the system heap before dereferencing it
([resident-components.md](resident-components.md)). The scene layer cannot
weaken that even by accident, because it never has a pointer to weaken.

## What the scene does not assert

- **Cross-process stacking.** `z` is the index within a process's own window
  chain, which *is* that process's stacking order. Across processes only the
  front app's position is knowable from here, so windows are emitted front
  process first and nothing else about the global order is claimed. Upstream's
  own builder is in the same position and resolves it the same way.
- **`visible`.** Emitted `true`: the reader walks the Window Manager's window
  list, so its members are windows the machine has, but the visible flag itself
  is not read through the validated path yet. Stated rather than dressed up.
- **The clock.** `capturedAt` is the guest's own `GetDateTime` converted to Unix
  epoch. Whether it is *right* is a property of the machine — a PowerBook with a
  dead PRAM battery boots in 1904 and this scene will say so, because silently
  correcting it would hide a real fact behind a plausible number.
- **A partial walk is never delivered as a complete scene.** Truncation (more
  processes or windows than a scene carries, or a window chain longer than the
  reader's cap) sets a flag that becomes a `meta.errors` line. And the encoder
  **fails closed**: an overflowing scene leaves nothing behind rather than a
  prefix, because half a JSON object does not even parse and a consumer that got
  one would be reading a machine state that never existed.

## The version, stamped once

`NOW_SCENE_IR_VERSION` is the body's `version` **and** the number any serving
layer must copy into the result's `irVersion` key. One constant, so the envelope
key and the body stamp cannot diverge without editing that line — upstream's own
arrangement (IR-V1.md, *"One number, two places"*) and the same accretive rule
`contract/peek_table.h` already applies to the in-memory seam: an additive field
does not move the number; removing or renaming one does. The consumer duty —
read `irVersion`, refuse an unknown major, *then* decode — belongs to whoever
decodes, which is the host; this side's obligation is to make the two numbers
one number, and it does.

## How it is served: not yet, and deliberately

A scene is a **transfer, not a control message**, and the number is now ours
rather than borrowed. `scene_json_test.c` sizes what the encoder actually
produces:

| Scene | Encoded |
|---|---|
| 4 processes, 3 windows | **1193 B** |
| 24 processes, 32 windows, unwalked | **9214 B** |
| the same desktop **walked** — 64 controls, 6 menus of 8 items | **21541 B** |
| every pool full **and every row named** — this producer's **ceiling** | **54178 B** |

The control-frame cap is 4096 bytes. An idle desktop fits; an ordinary working
one does not — and the walked planes cost 2.3× the same desktop without them,
which is roughly the gap between our unwalked scene and upstream's 13980 B
one-window trace, from the other side. The open question
[streaming-a-scene.md](streaming-a-scene.md) listed as the one that would
dissolve the whole problem ("do realistic scenes fit in a control frame") is
answered **no** in our own bytes, and can be treated as closed.

**No new wire family was minted here, and the reason is a gate rather than a
preference.** `now-host/Tests/HostTests/GuestWireConformanceTests.swift` reads
every `{"type":"..."}` literal out of the guest sources and fails when the host
cannot decode one — *"an unknown type is a failure"*. A `scene.begin` emitted
from `wire.c` would therefore turn the host suite red until the contract
declares the schema and the host grows a decoder, and both of those are M4/M6
files owned elsewhere. Contract first is the house rule and this is what it
looks like from the guest side. What exists instead is the payload producer:
`now_scene_collect` fills a scene, `now_scene_encode` renders it, and
`now_scene_encoded_size` answers "does this fit" *before* a caller commits to a
frame — which is precisely the decision a serving layer has to make.

So `src/scene/` is compiled into the guest and has no caller yet. That is a
stated, one-commit-wide gap, not a forgotten one.

**Closed 2026-07-31.** The gap was exactly one commit wide, and it closed the
way the paragraph above said it would have to: the contract, the guest's
`scene.request` handler and the host's decoder landed together, because the
conformance gate makes any other order red. `serve_scene` in `wire.c` is the
caller — it walks, sizes, encodes, and answers on the bulk lane with
`scene.begin` / frames / `scene.end`, borrowing capture's transfer machinery
whole rather than inventing a second one. The transport learned a single new
fact: which terminal message closes a transfer (`xfer_end_type`). See
[streaming-a-scene.md](streaming-a-scene.md) for why a one-shot transfer and
not a bracket, and `now-host/Tests/HostTests/SceneWireTests.swift` for the
host half — including the assertion that the version gate runs *before* the
parser, which is the only one that can tell a compliant decoder from a
plausible one.

What is still open is the **projection**: no MCP row asks for a scene yet.
That is M6, and it is declared as a planned gap in
[mcp-coverage.md](mcp-coverage.md) rather than left to be discovered.

## Gates, and what was watched failing

`scripts/test-native`: **40 passed, 0 failed** (38 before this work). Every
assertion below was watched failing under a deliberate mutation, then reverted.

| Mutation | Result |
|---|---|
| `now_scene_anchor_admits_windows` returns 1 for everything | **build failed** — the verdict goes unread and `-Werror` rejects it. A mutation that will not compile proves nothing, so it was rewritten (below). The same trap `peek_oracle_test.c` records |
| ...rewritten to admit everything except `NoPlane` (verdict still read) | 2 red — both scene tests |
| encoder emits `"controls":[]` beside `visible` | 1 red — the absence gate, which is the only thing that could have caught it |
| `NotFound` and `Ambiguous` tokens swapped | 2 red, in both directions |
| overflow branch removed (return what fits) | 1 red — **as a segfault**, which is its own finding: failing closed is also the bounds check |
| `front` becomes `z == 0` regardless of the process | 1 red |
| stale gate `>` becomes `>=` | 1 red — the boundary case only, which is why it is there |
| window truncation stops setting its flag | 2 red |
| `kNowSceneAnchorAmbiguous`/`Mismatch` reordered in `scene_anchor.h` | **guest build failed** on the compile-time pin in `scene_collect.c` — the gate that exists because a silently reordered verdict would turn "this anchor is ambiguous" into "this process has no windows" and nothing would say so |

`scripts/build-guests`: all three targets green.

### Wiring the walk in, 2026-07-31 (Phase 1.3)

`scripts/test-native`: **49 passed, 0 failed** (48 before). One new file,
`scene_walk_test.c`, covering `src/scene/scene_walk.c` — the bridge between the
ported walk and these rules. It is Toolbox-free for the same reason
`scene_build.c` is: it takes a **bound `NowAxMemory` seam as an argument**, so
the layer that turns a parser result into a *claim* runs on the host against the
axwalk fixture's synthetic big-endian arena. The impure half is one
`now_ax_bind_process` call in `scene_collect.c`, and that call is the only part
of this plane a Macintosh is needed to exercise.

**The two readers are matched by address, not by position.** `peek_read.c`
produces the window rows (its rect is the *structure* region — the frame a
person sees) and now reports each row's `WindowRecord`; the walk returns to that
exact record for the controls, the kind and the text. Counting along both chains
would have misfiled every control after the first window `peek_read.c` skipped
for insane bounds — a quiet, plausible, permanently-wrong scene.

| Mutation | Result |
|---|---|
| encoder emits `"controls":[]` on every window (presence guard removed) | 1 red — the conditional-plane gate. The old absence gate could not have caught this: `controls` is now allowed to appear |
| `now_scene_open_menubar` ignores the anchor verdict | 2 red — assembly's independent refusal, and the bridge's |
| the misfile invariant (`block_is_tail`) always true | 1 red — two windows interleaving controls, and the second silently taking the first's |
| the dialog-text read loses its `kind == 2` gate | 1 red — an ordinary window reporting text parsed from the bytes *after* its record |
| a retracted control plane stops setting its flag | 2 red — a drop nobody can see |
| `w->text` left at `memset`'s 0 instead of −1 | 3 red — every window claiming text row 0 |
| the hyphen separator rule removed | 1 red |
| `cmdChar` marker bytes (< 0x20) reported as command keys | 1 red — a hierarchical-menu marker offered to a person as a keyboard shortcut |
| a refused control link leaves the short list standing instead of retracting | 1 red — the retraction rule, stated as a mutation |
| an unparsable menu list reads as an empty menu bar | 1 red — "this app has no menus" where "we could not read them" is true |

**Nothing here has been run by a Macintosh.** No emulator, no metal, no
`NOW_METAL`. Everything above is *built* and *tested*; nothing is verified. In
particular the collector — the whole Toolbox half — has never executed, so the
first live scene is as likely to teach us something as to confirm anything.

## What M6 needs that does not exist yet

1. **A wire family and its contract schemas.** One-shot request, answered by a
   bulk transfer (the shape `capture.request` already has), plus a host decoder.
   Until all three land together the conformance gate is right to refuse.
2. **`irVersion` in the result envelope**, copied from `NOW_SCENE_IR_VERSION`,
   with the consumer duty in upstream's order on the decoding side.
3. **A relaxation in MirrorKit's own decoder.** `Scene.Window.controls` is a
   **non-optional** `[Control]`, so a scene that omits the key *fails to decode*.
   IR v1 froze the field set, but the Swift type makes "I do not report
   controls" inexpressible — a partial producer can only say the false thing.
   This is the one place where upstream's contract and this repository's
   absent-key rule genuinely collide, and it is upstream's side that has to give
   (decode-if-present with an empty default) or NOW's guest cannot be a source
   for MirrorKit at all. Same question for `apps`, `windows` and `meta.errors`,
   which we do emit, so only `controls` bites today.

   **Sharper since the walk landed, not softer.** The guest now emits `controls`
   on some windows and omits it on others *in the same scene*, so a decoder that
   cannot express absence does not merely reject an edge case — it rejects a
   scene of an ordinary desktop. NOW's own host decoder
   (`AgentIntegrationSceneModels.swift`) already models `menubar`, `menus`,
   `controls` and `text` as optional, so this side needed no change; the
   collision is entirely upstream's, and Phase 2.2 owns it.
4. **A number from a real machine.** What the walk costs on a 1400c is what
   decides whether a scene ever wants the streaming bracket
   ([streaming-a-scene.md](streaming-a-scene.md)); `meta.latencyMs` is emitted
   for exactly that measurement and has never been read off hardware.
