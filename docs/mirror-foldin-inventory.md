# What Mirror actually contains, and what has crossed

## Executable completion inventory, 2026-08-03

This is the strangler map for the final fold. It is derived and checked by
`tools/mirror-gate-tests/test_mirror_parity_inventory.py`; adding an old
service method or a human `InteractionPlan` case without a row fails the
ordinary native gate.

The recovered Cycle 18 file is worktree-local by design. Its live contents
are preserved as `tools/mirror-gate-tests/cycle-18-results.json`: **15 pass,
20 fail, 3 blocked, 2 n/a**, 40 rows, source SHA-256
`a436639e07498b443c71a7fe2f6198c0995ee7bdbf9eb1a65b54df72359f74b7`.
That corrects the later plan summary without relabelling a row. The fixture is
the reproducible before-state; screenshots and narrative remain under
`docs/local/`.

### Recovered scheduling baseline

There is no numeric queue-wait baseline to preserve. The recovered
`NOWMirrorSource` has a `pending` bit for its sequential scene poll, but each
human act starts its own unqueued `Task`; `ActLog` records only end-to-end
elapsed milliseconds. The tree therefore cannot distinguish time waiting for
the shared guest lane from guest execution time, and concurrent acts have no
declared order. The honest U1 baseline is **not observable**, not zero.

U4 must add separate `queuedAt`, `dispatchedAt`, and settlement timestamps and
then characterize the emulator workload. Its invariant is stronger than a
latency target: once an act is queued, no new scene poll or bulk chunk starts
ahead of it. No QEMU-only scheduler or input mechanism may be part of that
implementation; QEMU remains the independent development oracle.

### Legacy runtime capability disposition

This is the retirement ledger for the unified NOW Extension prerequisite. Its
keys are derived by
`tools/mirror-gate-tests/test_mirror_parity_inventory.py` from AXPeek's sample
record, QDPeek's operation constants, Portal's operation and window-operation
constants, the agent dispatch, and the old staging/service paths. Adding a
legacy capability without a row fails the ordinary native gate. The source
column says where the key comes from; it is not evidence that NOW already
provides the outcome.

`goal` means the user outcome is part of the data-driven Mirror. Such a row
cannot close as a refusal, fixture, or blocker: it must have the same capability,
an outcome-equivalent NOW path, or be a prohibited mechanism with no remaining
consumer. The proof owner is the unit in the unified-extension prerequisite,
not the older fold roadmap or Mirror completion plan. Upstream measurements are
only differential-oracle inputs to that owner's proof.

| capability | derived source | goal-facing outcome | relevance | disposition | proof owner |
|---|---|---|---|---|---|
| `AXPeek:appName` | `axshared.h:AXContextSample.appName` | identify the sampled application | goal | outcome-equivalent-through-NOW | prerequisite U2 P1 identity/freshness tests |
| `AXPeek:currentA5` | `axshared.h:AXContextSample.currentA5` | bind a foreign context exactly | goal | same-capability | prerequisite U2 P1 anchor tests |
| `AXPeek:menuList` | `axshared.h:AXContextSample.menuList` | locate the target's system menus | goal | outcome-equivalent-through-NOW | prerequisite U2/U3 anchor and semantics tests |
| `AXPeek:sample-throttle` | `axgne.S` | fresh anchors without an every-event full scan | goal | outcome-equivalent-through-NOW | prerequisite U2 six-tick mutation watch |
| `AXPeek:stackBase` | `axshared.h:AXContextSample.stackBase` | corroborate partition identity | goal | same-capability | prerequisite U2 P1 identity tests |
| `AXPeek:ticks` | `axshared.h:AXContextSample.ticks` | report bounded freshness | goal | same-capability | prerequisite U2 cadence/freshness tests |
| `AXPeek:windowList` | `axshared.h:AXContextSample.windowList` | locate foreign windows | goal | same-capability | prerequisite U2 P1 anchor tests |
| `MirrorApp:--serve` | `MirrorApp/Serve.swift` | old host IPC service lifecycle | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 absence guard after Plan 001 broker boundary is recorded |
| `Portal:control-invoke` | `ptshared.h:PT_OP_CONTROL_INVOKE` | actuate the addressed control in its owner context | goal | outcome-equivalent-through-NOW | prerequisite U5 typed P4 positive/no-hijack proof |
| `Portal:menu-geometry` | `ptshared.h:PT_OP_MENU_GEOMETRY` | resolve non-uniform menu item geometry | goal | outcome-equivalent-through-NOW | prerequisite U3 bounded P2 evidence table and fixtures |
| `Portal:menu-invoke` | `ptshared.h:PT_OP_MENU_INVOKE` | select an addressed menu item through the application | goal | outcome-equivalent-through-NOW | prerequisite U5 typed P4 settlement proof |
| `Portal:selftest` | `ptshared.h:PT_OP_SELFTEST` | prove the resident act ABI before actions | goal | same-capability | prerequisite U5 `actselftest` positive control |
| `Portal:text-get` | `ptshared.h:PT_OP_TEXT_GET` | read addressed TextEdit/dialog text in context | goal | outcome-equivalent-through-NOW | prerequisite U3/U5 semantic and settlement proof |
| `Portal:text-set` | `ptshared.h:PT_OP_TEXT_SET` | change addressed text and prove redraw/effect | goal | outcome-equivalent-through-NOW | prerequisite U5 typed text settlement proof |
| `Portal:window-act` | `ptshared.h:PT_OP_WINDOW_ACT` | route addressed window behavior through its owner | goal | outcome-equivalent-through-NOW | prerequisite U5 window settlement proof |
| `Portal:window-close` | `ptshared.h:PT_WIN_CLOSE` | ask the application to close the addressed window | goal | outcome-equivalent-through-NOW | prerequisite U5 close/postcondition proof |
| `Portal:window-move` | `ptshared.h:PT_WIN_MOVE` | move the addressed window | goal | outcome-equivalent-through-NOW | prerequisite U5 move/postcondition proof |
| `Portal:window-resize` | `ptshared.h:PT_WIN_RESIZE` | resize through the application's window path | goal | outcome-equivalent-through-NOW | prerequisite U5 resize/postcondition proof |
| `Portal:window-zoom` | `ptshared.h:PT_WIN_ZOOM` | zoom through the application's window path | goal | outcome-equivalent-through-NOW | prerequisite U5 zoom/postcondition proof |
| `QDPeek:arc` | `qdshared.h:QD_OP_ARC` | retain bounded structured arc drawing | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 fixture and epoch proof |
| `QDPeek:bits` | `qdshared.h:QD_OP_BITS` | retain bounds/provenance for an unavailable bitmap | goal | outcome-equivalent-through-NOW | prerequisite U4 bounded-placeholder proof; no pixels transported |
| `QDPeek:comment` | `qdshared.h:QD_OP_COMMENT` | old QuickDraw comment record | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 derived absence/consumer audit |
| `QDPeek:line` | `qdshared.h:QD_OP_LINE` | retain bounded structured line drawing | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 fixture and epoch proof |
| `QDPeek:oval` | `qdshared.h:QD_OP_OVAL` | retain bounded structured oval drawing | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 fixture and epoch proof |
| `QDPeek:poly` | `qdshared.h:QD_OP_POLY` | retain bounded structured polygon bounds | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 fixture and epoch proof |
| `QDPeek:rect` | `qdshared.h:QD_OP_RECT` | retain bounded structured rectangle drawing | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 fixture and epoch proof |
| `QDPeek:rgn` | `qdshared.h:QD_OP_RGN` | retain bounded structured region bounds | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 fixture and epoch proof |
| `QDPeek:rrect` | `qdshared.h:QD_OP_RRECT` | retain bounded structured round-rectangle drawing | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 fixture and epoch proof |
| `QDPeek:state` | `qdshared.h:QD_OP_STATE` | place and color structured operations correctly | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 state/epoch proof |
| `QDPeek:text` | `qdshared.h:QD_OP_TEXT` | retain guest-authored drawn text as structure | goal | outcome-equivalent-through-NOW | prerequisite U4 initial-display and fixture proof |
| `mirror-agent:activate` | `mirrorverbs.c:dispatch_verb` | bring the addressed application frontmost | goal | same-capability | prerequisite U5 activation settlement proof |
| `mirror-agent:apple-event` | `mirrorverbs.c:dispatch_verb` | bounded quit/open lifecycle outcomes | goal | outcome-equivalent-through-NOW | prerequisite U5 observed postcondition proof |
| `mirror-agent:axdo` | `mirrorverbs.c:dispatch_verb` | act on an identity-addressed control/text target | goal | outcome-equivalent-through-NOW | prerequisite U5 typed P4 operations |
| `mirror-agent:axsnap` | `mirrorverbs.c:dispatch_verb` | snapshot guest-authored object state | goal | outcome-equivalent-through-NOW | prerequisite U3 scene fixture proof |
| `mirror-agent:axtree` | `mirrorverbs.c:dispatch_verb` | expose guest-authored object structure | goal | outcome-equivalent-through-NOW | prerequisite U3 scene fixture proof |
| `mirror-agent:capture` | `mirrorverbs.c:dispatch_verb` | old guest pixel capture | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 no-pixel-transport consumer audit |
| `mirror-agent:click` | `mirrorverbs.c:dispatch_verb` | a Mirror pointer gesture changes the addressed guest object | goal | outcome-equivalent-through-NOW | prerequisite U5 typed identity action; no synthetic guest click |
| `mirror-agent:close` | `mirrorverbs.c:dispatch_verb` | old bulk-transfer close | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 old-lane absence guard |
| `mirror-agent:ctlinvoke` | `mirrorverbs.c:dispatch_verb` | actuate the addressed control | goal | outcome-equivalent-through-NOW | prerequisite U5 control settlement proof |
| `mirror-agent:fetch` | `mirrorverbs.c:dispatch_verb` | old bulk-transfer page fetch | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 old-lane absence guard |
| `mirror-agent:hello` | `mirrorverbs.c:dispatch_verb` | identify capability and build at session start | goal | outcome-equivalent-through-NOW | prerequisite U2/U6 exact identity handshake proof |
| `mirror-agent:journalprobe` | `mirrorverbs.c:dispatch_verb` | closed event-journal experiment | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 consumer audit |
| `mirror-agent:key` | `mirrorverbs.c:dispatch_verb` | a Mirror keyboard event reaches the intended guest target | goal | outcome-equivalent-through-NOW | prerequisite U5 direct-input keyboard proof |
| `mirror-agent:launch` | `mirrorverbs.c:dispatch_verb` | launch an addressed application | goal | same-capability | prerequisite U5 observed launch settlement |
| `mirror-agent:list` | `mirrorverbs.c:dispatch_verb` | list guest files for Finder representation | goal | same-capability | prerequisite U7 focused Macintosh HD/Finder proof |
| `mirror-agent:menugeom` | `mirrorverbs.c:dispatch_verb` | resolve real menu item geometry | goal | outcome-equivalent-through-NOW | prerequisite U3 semantic evidence and U5 menu proof |
| `mirror-agent:menuinvoke` | `mirrorverbs.c:dispatch_verb` | invoke an addressed menu item | goal | outcome-equivalent-through-NOW | prerequisite U5 menu settlement proof |
| `mirror-agent:mouseloc` | `mirrorverbs.c:dispatch_verb` | old guest cursor-position probe | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 consumer audit |
| `mirror-agent:observe` | `mirrorverbs.c:dispatch_verb` | observe applications, windows, and controls | goal | outcome-equivalent-through-NOW | prerequisite U3 scene and focused-corpus proof |
| `mirror-agent:ping` | `mirrorverbs.c:dispatch_verb` | prove session liveness | goal | same-capability | prerequisite U6 unified handshake/lifecycle proof |
| `mirror-agent:portal` | `mirrorverbs.c:dispatch_verb` | old Portal raw operation wrapper | legacy-only | prohibited-mechanism/no-consumer | prerequisite U5 typed operations plus U7 consumer audit |
| `mirror-agent:portalselftest` | `mirrorverbs.c:dispatch_verb` | prove the resident action ABI | goal | same-capability | prerequisite U5 `actselftest` positive control |
| `mirror-agent:qdtrace` | `mirrorverbs.c:dispatch_verb` | fetch structured retained drawing | goal | outcome-equivalent-through-NOW | prerequisite U4 P3 lifecycle and display proof |
| `mirror-agent:quit` | `mirrorverbs.c:dispatch_verb` | stop the old faceless agent | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 agent-absence proof |
| `mirror-agent:script` | `mirrorverbs.c:dispatch_verb` | arbitrary guest scripting escape hatch | legacy-only | prohibited-mechanism/no-consumer | prerequisite U7 consumer audit |
| `mirror-agent:stat` | `mirrorverbs.c:dispatch_verb` | inspect guest file metadata | goal | same-capability | prerequisite U7 focused Macintosh HD/Finder proof |
| `mirror-agent:textget` | `mirrorverbs.c:dispatch_verb` | read addressed foreign text | goal | outcome-equivalent-through-NOW | prerequisite U3/U5 text proof |
| `mirror-agent:textset` | `mirrorverbs.c:dispatch_verb` | edit addressed foreign text | goal | outcome-equivalent-through-NOW | prerequisite U5 direct-input text settlement proof |
| `mirror-agent:volumes` | `mirrorverbs.c:dispatch_verb` | enumerate guest volumes | goal | same-capability | prerequisite U7 focused Macintosh HD proof |
| `mirror-agent:winact` | `mirrorverbs.c:dispatch_verb` | act on an addressed foreign window | goal | outcome-equivalent-through-NOW | prerequisite U5 window settlement proof |
| `staging:TB-residents` | preserved `mirror/tools/stage-agent.py` | install three old resident files | legacy-only | prohibited-mechanism/no-consumer | U7 extension-only staging mutation watch |
| `staging:mirror-agent` | preserved `mirror/tools/stage-agent.py` | install the old faceless guest service | legacy-only | prohibited-mechanism/no-consumer | U7 extension-only staging mutation watch |
| `transport:mirror.port` | preserved `mirror/tools/stage-agent.py` | configure the old agent's separate port | legacy-only | prohibited-mechanism/no-consumer | U7 staging and stopped-image absence proof |
| `transport:port-1420` | preserved `mirror/tools/stage-agent.py` and `spin-up.sh` | forward the old agent's separate socket | legacy-only | prohibited-mechanism/no-consumer | U7 port-1420 mutation watch |

### Old Mirror method disposition

The current-human and current-MCP columns are characterization, not promises.
The disposition is the required NOW end-state before the old method can go.

| old method | current human primitive | current MCP projection | disposition |
|---|---|---|---|
| `mirror.attach` | none | none | compatibility adapter |
| `mirror.detach` | none | none | compatibility adapter |
| `mirror.status` | `status` | `now_session_health` | canonical broker primitive |
| `mirror.scene` | `LiveMirrorView` | `now_observe_elements` | canonical broker primitive |
| `mirror.find` | `ObjectResolver` | `now_observe_elements` | canonical broker primitive |
| `mirror.shot` | `LiveMirrorView` | none | retirement blocker |
| `mirror.wait` | none | none | retirement blocker |
| `mirror.act.control` | `controlPart` | `now_control_act` | canonical broker primitive |
| `mirror.act.menu` | `menuCommand` | `now_menu_act` | canonical broker primitive |
| `mirror.act.type` | `typeText` | `now_text_set` | canonical broker primitive |
| `mirror.act.key` | `keystroke` | none | retirement blocker |
| `mirror.act.open` | `finderOpen` | none | canonical broker primitive |
| `mirror.act.window` | `windowAct` | `now_window_act` | canonical broker primitive |
| `mirror.act.scroll` | `controlPart` | `now_control_act` | canonical broker primitive |
| `mirror.app` | `activateApp` | `now_bring_to_front` | canonical broker primitive |

### Human action catalog

These are the cases in `InteractionPlan`, the typed result of keyboard/mouse
hit testing. `nothing` and `unsupported` are deliberate non-dispatch outcomes;
they stay catalogued because silently dropping either would make an affordance
look dead.

| interaction plan | disposition |
|---|---|
| `controlPart` | canonical broker primitive |
| `dialogItem` | canonical broker primitive |
| `windowAct` | canonical broker primitive |
| `menuCommand` | canonical broker primitive |
| `keystroke` | canonical broker primitive |
| `typeText` | canonical broker primitive |
| `setText` | canonical broker primitive |
| `activateApp` | canonical broker primitive |
| `applicationVisibility` | canonical broker primitive |
| `finderSelect` | canonical broker primitive |
| `finderOpen` | canonical broker primitive |
| `finderDeselect` | canonical broker primitive |
| `nothing` | explicit refusal |
| `unsupported` | explicit refusal |

### Historical recount

**Date:** 2026-07-31, **recounted 2026-08-01** · **Status:** audit,
current as of `main` today

Written after Michelle said *"make sure you're not cutting corners — there was a
lot of work done in mirror and its new home is gonna be New Old World."* She was
right to push twice. This is the honest accounting, done by enumerating both
repositories rather than by recalling what felt done.

> ## Recount, 2026-08-01
>
> **"Roughly a fifth" is badly stale and was stale within a day.** Recounted
> against the tree rather than against this page:
>
> | | 2026-07-31 | 2026-08-01 |
> |---|---|---|
> | Verbs NOW's PPC guest serves | 22 | **33 dispatch arms** (32 contract verbs + `help`) |
> | Of Mirror's 21 uncrossed verbs | 21 open | **0 open — 16 crossed, 5 refused in writing** |
> | Planes crossed | the walk | the walk, the **act plane** (five ops), the **content plane**, the **reference layer** |
> | Host | — | **MirrorKit + MirrorKitUI**, both test targets, the golden fixtures |
> | Probe harnesses | 0 | **9**, plus five support modules and their own tests |
> | Recorded knowledge | 0 | **9 documents + 9 rendered PNGs + 6 upstream fixtures** |
>
> The original sentence was right about the thing it was measuring — the
> verb layer — and wrong the moment the waves it sequenced actually ran.
> **The unstated part of the recount is the useful part:** what remains
> uncrossed is now almost entirely *tooling and judgement*, not capability.
> The rest of this page is kept as written, with the sections it superseded
> marked, because the *sequencing argument* it makes is what made the recount
> possible.
>
> **What is NOT better than it was:** none of it has run on a Macintosh.
> Crossing is not verification, and the fold-in traded an "is it here"
> problem for an "is it true" one. See
> [emu-readiness.md](emu-readiness.md).

**Roughly a fifth of Mirror has crossed.** *(Superseded 2026-08-01 — see the
recount above.)* The parts that crossed are real and
tested; the parts that have not are most of the product.

## The number that reframes it

`guest/app/src/mirrorverbs.c` is **5,386 lines serving 31 verbs.** The guest walk
port took the *parsers that file calls* — `axwalk`, `axmenu`, `axtext`, `axref`,
`axresolve`, `axbinding`, about 35 KB — and left the verb layer behind. That was
described at the time as "porting the archaeology", which was true and
incomplete: the archaeology is what the verbs *use*, not what they *are*.

## Verb surfaces, side by side

| | |
|---|---|
| **NOW's guest serves (22)** | `catsearch` `census` `clear` `front` `gestalt` `help` `launch` `ls` `mkdir` `mv` `ps` `put` `putstat` `quit` `reveal` `screenshot` `sw` `tail` `trash` `untrash` `vers` `vprobe` |
| **Mirror's guest serves (31)** | `activate` `apple_event` `axdo` `axsnap` `axtree` `capture` `click` `close` `ctlinvoke` `fetch` `handle` `hello` `journalprobe` `key` `launch` `list` `menugeom` `menuinvoke` `mouseloc` `observe` `ping` `portal` `portalselftest` `qdtrace` `quit` `script` `stat` `textget` `textset` `volumes` `winact` |
| **Literally shared today** | `launch`, `quit` |

They are two different products. NOW is remote control, files and census; Mirror
is a semantic mirror you can act through. So this is not "NOW is missing 21
verbs it should have had" — it is **the Mirror capability costs about 21 verbs
and two of them exist.**

## What has crossed

| Piece | Where it landed | State |
|---|---|---|
| `axwalk` / `axmenu` / `axtext` / `axref` / `axresolve` / `axbinding` | `now-guest-ppc/src/axwalk/` | ported, natively tested (first coverage this archaeology ever had) |
| `MirrorKit` + `MirrorKitUI` | `now-host/Sources/` | ported whole with both test targets and the golden fixtures |
| The IR contract | `contract/`, guest encoder, host decoder, adapter | NOW's own, IR v1-conformant |
| Oracle *answers* (five verdicts) | `peek_oracle.c` | reimplemented, then V3 added `CurApName` from upstream's |

~~**In flight as of this writing:** `portal` → the act plane (all five ops);
`qdpeek` → the content plane; the `GuestListener` scene caller.~~
**All three landed 2026-07-31.**

## The verb recount, 2026-08-01

Mirror's 31-verb surface, resolved one at a time against
`now-guest-ppc/src/commands/commands.c`. **Every one of the 21 the section
below called uncrossed now has a disposition.**

### Crossed — 16

| Mirror | In NOW | Shape |
|---|---|---|
| `axtree`, `axsnap`, `observe`, `handle` | same names, plus `elements` | the reference layer — the keystone wave 2A named |
| `portal` | the **act plane** (P4) | not a verb: five ops in `ext/`, addressed by `winact` / `ctlact` / `menuact` / `textget` / `textset` |
| `portalselftest` | `actselftest` | **reshaped and renamed** — the plane had served the op since it landed and nothing could call it |
| `ctlinvoke` | `ctlact` | |
| `menuinvoke` | `menuact` | takes an integer menu id **as the scene reports it**, not a reference |
| `winact`, `textget`, `textset`, `mouseloc`, `qdtrace`, `script` | same names | |
| `axdo` | **split** into `ctlact` and `textset` | one upstream verb, two NOW verbs, because actuating and writing are different reaches |
| `apple_event` | `aesend` | **narrowed** to a closed four-event vocabulary that refuses anything outside it |
| `activate` | `activate` | reshaped: the host already sent this name and no guest answered it |
| `key` | `key` | crossed and **refuses `mods`** — CarbonLib has no `PPostEvent` |

### Refused in writing — 5, plus `click`

`volumes`, `fetch`, `close`, `menugeom`, `journalprobe`
([mirror-wave3-verdicts.md](mirror-wave3-verdicts.md)), and `click`
([input-plane-decisions.md](input-plane-decisions.md)).

**Four of the six are refused because NOW already answers the question
under another name** — `census volumes` is the same `PBHGetVInfo` walk,
`fetch` would be a second bytes-puller on a lane one transfer wide,
`close` is not a window closer, and `journalprobe` belongs to a closed
investigation. `menugeom` is *"not now"* rather than *no*: its consumer
reappeared (`ActionModel`'s `menuRowHeight`, a known-wrong constant) and
the op is resident, so it is a real piece of work rather than a
transcription.

**A refusal with an argument is the deliverable this section was for.**
The one corner-cut the original document forbade was deciding a verb was
unnecessary before its dependencies were in; all six were decided after.

### Already NOW's own, under NOW's spelling — the rest

`capture` → `screenshot`, `list` → `ls`, `stat` → the file family,
`hello` / `ping` → NOW's own handshake, `launch` / `quit` → shared
outright. These were never gaps.

## What has NOT crossed

*(Written 2026-07-31. Sections 1 and 2 are superseded; 3, 4 and 5 are
partly closed — see the inline notes.)*

### ~~1. The verb layer — the largest single gap~~ — CLOSED 2026-08-01

~21 verbs. `axtree` `axsnap` `axdo` `observe` `fetch` `handle` `ctlinvoke`
`menuinvoke` `menugeom` `mouseloc` `portal` `portalselftest` `qdtrace` `textget`
`textset` `winact` `volumes` `activate` `close` `apple_event` `journalprobe`.

The three the host's act rows require (`winact`, `textget`, `textset`) are in
flight. **The other eighteen are not scheduled.** `observe` and `handle` matter
disproportionately: they mint and resolve the element references every act verb
addresses, so nothing can be driven by identity without them.

### 2. The test harnesses — and these ARE Phase 3 — **mostly crossed 2026-08-01**

**Nine harnesses are in `scripts/probes/`**: `g1-probe.py`,
`nohijack-probe.py` (45 KB), `winact-probe.py`, `ctlinvoke-probe.py`,
`textops-probe.py`, `textops-explore.py`, `apple-event-probe.py`,
`drive-sequence.py`, `h2-items-probe.py`. With them came five support
modules — `nowwire.py` (the transport plus the verb and scene gates),
`scene.py`, `tally.py`, `oracles.py`, `qmp.py` — their own tests under
`scripts/probes/tests/`, and **six upstream result fixtures** with a
`PROVENANCE.md` beside them, which is what makes upstream's numbers
comparable rather than merely quoted.

**This document's headline prediction held.** Porting the harnesses was
cheaper than authoring an emulator pass, and it paid twice over in a way
that was not predicted: the ported harnesses **audited the guest**. Six of
them read as blocked on `observe` and were blocked on nothing, one
declared `winact` "served by no guest" when `commands.c` dispatched it,
and one sent `menuinvoke`/`menuID` where the contract says
`menuact`/`menu`. A harness that refuses is a claim about the guest, and
claims can be stale.

**Two did not cross:** `mirror-service-e2e.py` and `agent-session.py`.
Both are service-lifecycle drivers against upstream's own deploy path,
which NOW does not have — the same judgement as the tooling below.

### ~~2. The test harnesses — as written 2026-07-31~~

`mirror/tests/` holds ~25 probe scripts against a live guest. `nohijack-probe.py`
is **50 KB** and is the harness that produced 18/20 → 0/19. Also
`textops-probe.py`, `ctlinvoke-probe.py`, `apple-event-probe.py`, `g1-probe.py`,
the `h2-*` folder-item set with its recorded trial results, `mirror-service-e2e.py`,
`drive-sequence.py`, `agent-session.py`.

**This is the most under-valued item in the list.** The roadmap's Phase 3 says
"validate against an emulator" as though the harness needs writing. It does not —
it exists, it has run, and its results are recorded. Porting these is
cheaper than authoring an emulator pass and gives directly comparable numbers.

### 3. Tooling — **still open, and now the largest remaining item**

`tools/spin-up.sh`, `stage-agent.py`, `stage-mirror.py`, `stop-mirror.sh`, and
`extract-assets/`. NOW has its own deploy path, so these need judgement rather
than transcription — but `extract-assets` produced the Platinum assets
`MirrorKitUI` renders with, and `assets/` itself has not been examined.

**2026-08-01:** the *assets* half is closed —
[mirror-assets.md](mirror-assets.md) records the extraction, and
`MirrorKitUI/Resources` plus `assets/icons/` carry what the renderer draws
with.

**2026-08-01, later: the deploy half is closed too.** `tools/stage-ext.py`,
`tools/askguest.py`, and `scripts/spin-up-ppc` are the port, and they ran:
boot a session-private mac99 clone, stage `NowExt.bin` into
`System Folder:Extensions` and the app beside it, wait for the volume flush,
hard QMP `quit` and relaunch (an INIT loads at boot only), re-verify the
files survived, launch NOW, and let the *guest* answer. See
[staging-path.md](staging-path.md) for what it said.

What was judgement rather than transcription: NOW's wire runs guest → host,
the opposite direction from the mirror agent's, so the mirror's socket
verifier could not be ported at all — `askguest.py` is a listener, and it is
`fakeguest.py`'s mirror image. The staging half *is* close to transcription
and honours all four of the mirror's hardened rules verbatim.

### 4. Documents that are findings, not prose — **crossed 2026-08-01**

`CONTROL-SURFACE.md` (18 KB), `FOLDER-ITEMS.md`, `JOURNALING.md` (16 KB),
`QUICKDRAW-CONTENT-PLANE.md`, `TIMBUKTU-QD-FINDINGS.md`, `TIMBUKTU-TEARDOWN.md`,
`ASSET-EXTRACTION.md`, `PROTOTYPE-NOTES.md`, `HANDOFF.md`, and `STATUS.md` at
**55 KB**. These carry measurements NOW will otherwise re-derive — which has
already happened twice today.

They landed as nine documents, **refactored by subject rather than
transcribed by file**: [mirror-act-plane.md](mirror-act-plane.md),
[mirror-content-plane.md](mirror-content-plane.md),
[mirror-perceive-plane.md](mirror-perceive-plane.md),
[mirror-knowledge.md](mirror-knowledge.md),
[mirror-journaling.md](mirror-journaling.md),
[mirror-renders.md](mirror-renders.md),
[mirror-assets.md](mirror-assets.md),
[mirror-measurement-method.md](mirror-measurement-method.md),
[mirror-wave3-verdicts.md](mirror-wave3-verdicts.md).

**Every one carries a provenance line saying the measurements are
`timbottu/mirror`'s and not NOW's**, taken on that project's own guest —
which is the rule that keeps this fold-in from quietly inheriting evidence
it did not earn. Upstream states plainly that the act plane never touched
metal. Those numbers are evidence about a *mechanism*; they are not
statements about a PowerBook.

### 5. The rendered evidence — **crossed 2026-08-01**

Nine PNGs are in `docs/renders/`, dated in their filenames (2026-07-29 to
2026-07-31), catalogued by [mirror-renders.md](mirror-renders.md).

### 5 (original wording)

Nine PNGs of actual rendered scenes — GraphCalc, desktop icons, a pixel island, a
menu hover, the app switcher, folder items, volumes. They are the only record of
what "working" looks like, and the UX review has nothing to compare against
without them.

## The pattern this audit exists to stop

Twice today NOW re-derived something Mirror had already answered:

- **The menu-list layout.** M5 was declared blocked because `LMGetMenuList()`'s
  structure is in no header we have. `axmenu.c` had carried `6` / `6` / `14` all
  along.
- **The QuickDraw bottleneck question.** A from-scratch INIT (`qdprobe`) plus a
  reader were built to ask whether a 68K bottleneck can be called by PowerPC
  QuickDraw. `QDPEEK-SPEC.md` records **M0–M3 done, M4 emulator gate passed**, and
  answers it in the opposite direction from what the spike braced for: *Mixed Mode
  works with `NewQDxxxUPP` alone, no RoutineDescriptors.*

Both cost real effort and produced nothing upstream did not have. **The rule
going forward: check Mirror before deriving anything.** Its new home is this
repository, and everything in it was paid for once already.

## Completing the fold-in

Sequenced by what blocks what, not by size. Wave 1 is in flight; waves 2 and 3
are dispatched against this document.

**All three waves ran, 2026-07-31 to 2026-08-01.** The plan is kept
verbatim below because the *sequencing* is the reusable part: wave 2A was
correctly identified as the keystone, and wave 3's rule — do not decide a
verb is unnecessary before its dependencies exist — is what made five
refusals arguable instead of assumed.

**What remains after all three:**

| | |
|---|---|
| Upstream tooling (the deploy half of §3) | open, by judgement |
| `menugeom` | "not now" — its consumer came back and the op is resident |
| Two service-lifecycle harnesses | open, same judgement as the tooling |
| **The pane** | the act path is built end to end and nothing joins a click to it — [open-issues.md](open-issues.md), "The last functional gap" |
| **Any of it running on a Macintosh** | nothing has. [emu-readiness.md](emu-readiness.md) |

The last row is the one that matters. A fold-in that is complete on paper
and has met no machine has moved the risk, not retired it.

### Wave 1 — ~~in flight~~ **done 2026-07-31**

| | |
|---|---|
| `portal` → the act plane | all five ops: `CONTROL_INVOKE`, `MENU_INVOKE`, `TEXT_GET`, `TEXT_SET`, `WINDOW_ACT` |
| `qdpeek` → the content plane | P3, charter-designated, M0–M3 done upstream with the M4 emulator gate passed |
| the `GuestListener` scene caller | the one missing piece of an otherwise complete scene path |

### Wave 2 — the keystone, and the thing that makes Phase 3 cheap

**2A — the reference layer: `observe`, `handle`, `axtree`, `axsnap`.**
Every act verb addresses an **opaque, observation-minted reference**, and
identity-not-position is upstream's hardest-won finding — 18/20 versus 0/20.
Without `observe` to mint references and `handle` to resolve one back to a live
`WindowPtr`/`ControlHandle`, the act plane has nothing to address and the scene
has no way to say *this* window. **This blocks the value of Wave 1**, which is
why it is first here rather than filed with the other verbs.

**2B — the probe harnesses.** `mirror/tests/`, ~25 scripts that drive a live
guest. This is Phase 3 of the roadmap, already written and already run. Porting
them is cheaper than authoring an emulator pass and yields numbers directly
comparable to upstream's. `nohijack-probe.py` alone is the 50 KB harness behind
18/20 → 0/19.

**2C — the recorded knowledge.** Ten documents and nine rendered PNGs. Cheap,
and it is the direct fix for the failure this audit exists to stop: NOW has twice
re-derived an answer Mirror already had. The renders are also the only thing a UX
review can compare against.

### Wave 3 — the rest of the verb surface

`volumes` `activate` `close` `menugeom` `mouseloc` `apple_event` `ctlinvoke`
`menuinvoke` `qdtrace` `portal` `portalselftest` `journalprobe` `fetch`, and
NOW-equivalent decisions for `capture` / `list` / `stat` / `script` / `key` /
`click` / `ping` / `hello` where NOW already has its own spelling.

Deliberately last: each is bounded, none blocks another, and several may not want
to cross at all once the act plane and the reference layer exist. **That is a
judgement to make with the ported code in front of us, not now** — the one
corner-cut this document forbids is deciding a verb is unnecessary before its
dependencies are in.

**Three of them were judged on 2026-07-31, with the act plane and the
reference layer in front of us** — which is the condition this section set.
The arguments are in [input-plane-decisions.md](input-plane-decisions.md);
the verdicts:

| Verb | Verdict |
|---|---|
| `key` | **crossed**, as `key` — and it **refuses `mods`** rather than dropping it. CarbonLib has no `PPostEvent`, so this guest cannot stamp modifiers on the queue element |
| `click` | **does not cross.** The h2 folder-item probes already have a click on the emulator (QMP) and want an *identity*, not a coordinate — the Finder's own item names through `script`. A guest-side click is the one mechanism that would let a no-hijack probe forge its own evidence |
| `menugeom` | **does not cross.** Its only consumer is a release point for a menu drag `ActionModel` no longer emits; `menuact` computes no geometry. Calling a foreign MDEF — the riskiest call in upstream's file — to make a dead computation accurate buys nothing |

**The remaining seven were judged the same day**
([mirror-wave3-verdicts.md](mirror-wave3-verdicts.md)): `portalselftest`
and `activate` crossed reshaped; `volumes`, `fetch`, `close` and
`journalprobe` do not cross; `menugeom` was re-opened as *not now*.

**`menugeom`'s verdict changed within a day, and the reversal is the
lesson.** The row above says its consumer is dead. It is not:
`ActionModel.menuRowHeight = 16` assumes uniform menu rows, which is the
assumption upstream *measured* as a **~30 px accumulated error** once a
menu contains separators. A constant is a consumer — it consumes the fact
silently, which is why the audit missed it. **"Nothing consumes X" needs
checking against constants, not only against call sites.** Recorded in
[open-issues.md](open-issues.md).

### The standing rule

**Check Mirror before deriving anything.** Its new home is this repository. If a
piece of work here begins with "we need to find out whether…", the first place to
look is upstream, and the second is upstream's docs.

## Corpus impact

`corpus_impact: none` — an audit of two checkouts, no new measurement. Every
number here is a file count or a line count taken today and reproducible by
running the same commands.

**Unchanged by the 2026-08-01 recount, for the same reason.** The recount
is verb counts and dispatch-table reads taken against this tree; nothing
was measured on a machine, so no `evidence_level` moved. The **moment**
that changes is the first emulator run — every act verb, the reference
layer and the scene plane each owe a finding as soon as one of them
produces a number.
