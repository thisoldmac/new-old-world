# Open issues

Things known to be wrong, unfinished, or unverified, with enough detail
to pick any one of them up cold. Nothing here is being worked on right
now; each is parked deliberately.

The distinction that matters in this list is **broken** (it does the
wrong thing) versus **unverified** (it may well be right, but no one has
watched it work on the PowerBook). Unverified is not a lesser problem —
several of tonight's bugs lived in code that looked obviously correct.

**Nothing on this page is corrected by editing it.** A claim that has
stopped being true gets a dated line saying so, under the entry that made
it. The history is the point: several entries here are worth more for the
shape of the mistake than for the fix.

## ANSWERED: the theme file has no chrome in it, and the pack now comes off the disk image (2026-08-06)

Two questions closed, one deliberately left open.

**The theme file was opened rather than assumed.**
`System Folder:Appearance:Theme Files:Apple platinum` is an 876 KB
resource fork holding 21 accent `clut`s, 15 preview `PICT`s (fourteen
177×125 thumbnails plus a banner), 14 `scen` settings blobs, and its own
Finder icon. **No window frames, no title bars, no scroll arrows, no
buttons.** mirror-assets.md's inherited claim that Platinum chrome is
drawn procedurally survives contact with the file; the evidence table is
in [asset-extraction-offline.md](asset-extraction-offline.md). The one
liftable thing in it is *specification, not art* — the 21 eight-entry
accent ramps — and **that is not extracted yet**.

**The pack is now built offline**, by `tools/extract-assets-offline`: no
VM, no wire, no guest. 914 per-application icons (was 186), the System
file's full icon set at both sizes, 40 cursors, 8 patterns, 42 carried
PICTs. The two routes were cross-checked — the generic icons come out
byte-identical to the ones the wire route committed.

**Still open, and untouched by any of this: WHICH icon belongs to which
Finder item.** Icons arrive as identity-less bits. A bigger pack does
not help; the route is `PlotIconSuite`/`IconServicesLib` interception
(plan 015 G4), and the entry below on identity-less blits still stands
unchanged. The renderer's generic-by-kind fallback is pinned by a test
so the day identity lands, it shows.

**Unverified:** the menu-bar slot's process-signature join. `apps` and
`processes` share a PSN and a `ProcessRef` reports its creator, so that
one icon can be real identity — but **no fixture carries an
apps/processes block**, so no render exercises it. It is covered by a
unit test against the pack only.

## ANSWERED: the join works end to end on the control — and A2.1's pointer compare was wrong (2026-08-06, plan 013 slices A–C)

The host can now place a hooked GWorld's ops inside the window its blit
names, with no pixels on the wire. The chain, all emulator-verified on
mac99/OS 9.1 in one afternoon: the resident emits a `blitsrc` record
(probe mode only) immediately before each `bits` record whose source
resolves to a hooked offscreen port; the drain carries it
(`srcPort`/`srcPixmap`, 0x-hex); and `NOWMirrorContentPlane` holds
offscreen-keyed ops bounded, then replaces the joined blit's bits op
with the held ops re-homed — origin-shifted by `dst - src`, clipped to
`dst`, window state restored after. Against the loop control: 1000
`blitsrc` records, every one naming the port the applet reported for
itself, and the captured drain is now a committed host fixture whose
test places all six `'offscreen row'` texts
(`testControlCaptureJoinsSixOffscreenRowsIntoTheWindow`).

**The correction worth the entry**: plan 013 A2.1 prescribed comparing
each row's same-instant handle deref against the `src_bits` pointer.
Measured false — the bottleneck receives a **copy** of the source
PixMap (odd address 0x1eb6aaae), so identity never fires. The working
resolve falls back to shape via `now_content_probe_pixmap_match`, the
same route the chase itself was forced onto. The plan carries the
correction inline.

Two rig facts from the same runs: the loop control blits faster than
the 64 KiB ring holds, so a one-shot drain from the arm-time cursor
resyncs and answers EMPTY against 915 recorded ops (`gwprobe
--drain-seconds` is the cure; ring pressure itself is still deferred
item 4 of plan 013); and a Retro68 applet without `canBackground` stops
dead — and stops writing its report — the moment anything else comes
front, which reads exactly like a crash.

## ANSWERED: a real Finder interior composes host-side, without one pixel on the wire (2026-08-06, plan 013 slice D)

The arc's payoff, emulator-verified the same day the join landed: a
drain captured live off the CFM Finder carries 186 ops recorded under
its hooked offscreen world plus the `blitsrc`+`bits` pair that reveals
them, and the host join places **all ten real labels at their true
pens** — `'10 items, 3.21 GB available'` [135,14], `'Documents'`
[280,67], `'TimBotTu'` [282,131], `'TBT'` [40,195] — the same values
plan 013 quotes from the original measurement, re-captured through the
entire new pipeline. `NOW_RENDER_OUT` on the payoff test rasterizes the
composed scene offscreen (Mirror's render-screenshot rule);
`testFinderCaptureComposesTheRealInteriorHostSide` is the committed
fixture gate. Icons are placed bits geometry, per deferred item 1.

**The stimulus that worked, because two acts did not.** `winact` resize
refuses on a fresh boot (`the anchor plane is absent or not armed` —
the standing anchor-bind entry below), and `menuact` View-toggles
answered `dispatched` while the view never changed and the ring wrote
nothing — a second dispatched-but-nothing case worth its own look.
What forces a full composite rebuild with no act plane at all: front
NOW's own window over the armed one, then re-front the Finder. The
uncover repaint is total, and typing (`key`) gives only direct window
drawing — selection redraw worlds are too transient for the chase
(sighted, chased, gone: measured `misses`).

## ANSWERED: the Appearance path was load-bearing, and the panels' values cross (2026-08-06, plan 015 G3)

Michelle's hypothesis, and it was right in the way that matters:
**a control panel's field VALUES are drawn into offscreen worlds
AppearanceLib creates on its behalf.** Date & Time imports no
`NewGWorld` at all — read from its own PEF — yet with the trap patch
armed it reports **286 worlds born, 286 died, 0 missed**, because the
patch is on the TRAP and does not care who the caller is.

Everything a window-port hook could never see now crosses: the date and
time digits themselves, every control label (`Clock Options…`, `Date
Formats…`, `Set Time Zone…`, `Use a Network Time Server`, `Time server:
Apple Americas/…`), and the group titles it already had. Gated by
`testDateAndTimeValuesCrossFromTheThemesOwnWorlds`.

**Compared against the machine**, which is the step that was skipped
when the plated render was called an improvement: a QMP screendump from
the same run reads `3:17:38 PM` where the render reads `3:17:44 PM` —
six seconds of a ticking clock — with the same fields, groups and
buttons in the same places. Guarded by `--expect-build`; the guest that
answered was `1bff0bd2ca39`, this checkout's own.

The consequence is bigger than one panel: **any application themed by
Appearance is now reachable**, which is most of Mac OS 9's own
interface. The renderer's control-plate placeholder stays as the honest
answer for the blits that remain, but it is no longer what a panel
mostly shows.

## FIXED by comparison, and the gap that remains: Sherlock's grid and popup (2026-08-06, plan 015 G2 partial)

Rendering Sherlock 2 beside a QMP screendump of the same run — the
comparison that should have been happening all along — found a real
defect and left two honest gaps.

**Fixed: the destination's ORIGIN belongs in the join's translation.**
Sherlock blits every composed element to a CONSTANT `dst` under a
shifted port origin (the same SetOrigin idiom its channel grid uses), so
a join computing only `dst - src` collapsed them onto one corner: the
volume row rendered at the window's top-left instead of inside the list.
Live state is now tracked per DESTINATION port, and the prologue origin
is `src - dst + destination origin`. The row now lands under its column
headers, as on the machine.

**Still missing, both visible in the comparison and neither yet
explained:**

- **The channel grid does not render at all.** Its geometry is fully
  derivable (measured: 8x2, 51x46 cells, 55/50 pitch, selection readable
  from the sprite source rect) but nothing draws it — the top ~110 px of
  the render is empty where the guest shows sixteen buttons. Deriving it
  is a P2 opportunity, per docs/render-composition.md; leaving it in the
  replay would be drift.
- **The `Custom…` popup and the magnifier button are absent**, and no
  measurement yet says whether their drawing is missing or merely
  unplaced.

So Sherlock's TEXT is complete and its LAYOUT is now right for
everything that draws; what is absent is absent, and the render no
longer claims otherwise.

## MEASURED: the ring is the limit, and one cycle now drains a whole one (2026-08-06, plan 015 G1)

~12 KB/s into a 64 KiB ring under active repaint is about five seconds
of headroom, while the structural cycle that carried the only drain
runs every ~2.2 s and took ONE page of it. That is how Sherlock lost
114018 bytes in a settle and its interior text with them. A cycle now
chases the cursor while the guest reports `more`, bounded to 12 pages —
a whole ring's worth — so an awake reader cannot be lapped, while the
scene cycle stays the cadence owner (the sibling perf thread's
territory; this is additive by construction). The ring stays 64 KiB:
growing it costs system-heap bytes on 68K machines, and the measured
rate says pacing suffices. If an application beats the paced drain, the
ring decision reopens with numbers.

## VOID, and the rule that would have caught it: two late findings came from someone else's machine (2026-08-06)

Two results recorded near the end of the plan-014 arc are **void** and
must not be built on:

- a Date & Time re-capture in record mode, and
- a `qdext` check reporting `installed 0x00000000` with `active mode
  off`, read as a regression in the record-mode graduation.

`scripts/spin-up-ppc` had refused to boot — *"requested anchor port 1720
is in use (another session?)"* — so no VM of mine existed, and the wire
listener on 5340 was answered by **another session's guest running
another branch's build**. The tells were all present and I read past
every one: an identical build stamp across two supposedly fresh boots, a
`psn` belonging to a process from a previous run, and finally an empty
`/private/tmp/nowvm-kg01` with no `qemu.pid` in it.

AGENTS.md states the cure exactly — *"a metal gate must check WHICH
guest answered ... assert a capability only the build under test has
before believing anything it says"* — and it was written after
`Metal68KSendTests` was fooled the same way. The rule exists; nothing
made following it automatic for an ad-hoc harness, which is the real
gap. **`tools/gwprobe.py` and the scratch drivers assert nothing about
who answered**, and until they do, any result from them is a claim about
an unidentified machine.

What is NOT void: E0 (static, no machine), and the E1/E2/E3 runs, whose
boots each produced a distinct build stamp and whose counters moved
consistently with the code under test. The record-mode graduation
compiles and its gates pass, but it has **not** been watched working on
a machine, and the entry below should be read with that scope.

## ANSWERED: worlds hooked at BIRTH, and Sherlock's interior crosses (2026-08-06, plan 014 complete)

Plan 014 ran end to end the same day it was written, and every slice
answered:

- **E0** (static): Sherlock 2 and Appearance both resolve `NewGWorld`
  against **InterfaceLib**, read from their own PEF import tables
  (`tools/pef.py --imports`, extended to map symbols to libraries). Only
  NOW's own binary links CarbonLib, so the CarbonLib hole never stood
  between the resident and a target.
- **E1** (one boot): a resident-installed 68K patch on `$AB1D` fired for
  the CFM Finder — `qdext {installed 0x0058e61c, calls 6509, newGWorld
  2, foreign 0}`. **A native PowerPC caller reaches a 68K trap patch**
  through InterfaceLib's glue, exactly as the documentation says.
- **E2/E3**: the shim gained a tail wrap for selector 0 and a head
  action for selector 4, so each world is hooked at creation and
  released at disposal. Against Sherlock 2 — which the chase hooked 0
  of 8 times — **77 born, 77 died, 0 missed**, and its interior
  crossed: the radio labels, the column headers, and the volume row
  with its real index date.

**The host join had to learn to nest.** Sherlock composites two levels
deep — the list is its own world, blitted into the world holding the
interior, which is blitted into the window. Pending claims are now
keyed by destination port, and a `blitsrc` on an offscreen port is a
real join rather than noise. Gated by
`testSherlockInteriorComposesFromWorldsHookedAtBirth`.

**THE RING IS NOW THE LIMIT, and it is measured**: a hooked Sherlock
overran 64 KiB inside one settle (`lostBytes 114018`), and the first
run's interior text was lost to the overrun rather than to the
mechanism. Draining continuously *during* the stimulus recovered it
(3030 records, all nine strings) but still reported `lostBytes 343204`
across the run. So deferred item 4 of plan 013 is no longer
theoretical: continuous composition needs a drain cadence, a shorter
arm, or a bigger ring, and the decision now has numbers behind it.

**Also measured, and it corrects the applet's scope claim**: `foreign`
counts dispatches the patch saw outside the armed context, and it is
NOT zero under load (139–327). The trap table reaches further than one
process; the note function declines those, so the plane's behaviour is
unchanged, but "an application's trap patch is process-local" was the
applet's own failure and is not a general fact.

## MEASURED: Sherlock's channel grid is fully derivable without pixels (2026-08-06)

The two-row picker of channel buttons looks like the least tractable
thing on that window - sixteen cells of pure BMP art. It is not. Read
out of the drain:

- Sherlock draws each cell by **moving the port origin** and blitting
  to a constant `(0,0,51,46)`. So the grid is in the `state/origin`
  ops: **8 columns x 2 rows**, cells 51x46, pitch 55 horizontal and 50
  vertical, at x = 27 + 55k and y = 21, 71. Sixteen distinct
  (origin, source) pairs, exactly the sixteen cells on screen.
- **Selection is readable from geometry alone.** The selected cell's
  well art comes from sprite source rect `(142,149,193,195)`; all
  fifteen unselected cells come from `(209,231,260,277)`. Which channel
  is active is therefore a fact the mirror can state, with no pixels
  and no guessing.
- Every cell's **hit rect** is the same arithmetic - origin plus 51x46 -
  which is precisely what an act-plane click needs.
- Each channel ICON is its own offscreen world (a 32x32 blit from
  `(0,0,32,32)` of a per-icon world), so with worlds hooked at birth
  each icon has a stable per-session port identity via `blitsrc`.

What is still NOT derivable is the channel's NAME. The icon pixels come
from resources by a path the bottlenecks do not show, which is the
standing icon-identity item; Sherlock imports IconServicesLib (16
symbols, from its PEF), so the route exists if it is ever worth taking.

This is a semantic-layer opportunity rather than a replay one: the
renderer draws those blits as hatches today, and drawing them as
Platinum wells with the measured selection state would be honest,
cheap, and is not yet done.

## The coverage spread, and the one application that beat the chase (2026-08-06, later)

Deferred item 3's thin spread is thin no longer. Live captures, each a
committed fixture behind `NOWMirrorContentCoverageTests`: Finder
**icon, list and button views** all composite and all join (list view
crosses with its column headers and every row's real modification
date); **Date & Time** and **Memory** are non-compositing exactly as
the static table said, so the plain window hook reads their interiors
whole; and **NOW's own window** composes its Workshop, with a retarget
test pinning that a captured window stays composed as expected-stale
when the plane moves on — the hatch behind the Finder is gone.

**SUPERSEDED by plan 014 — see the entry above; the mechanism that
closes this now exists and Sherlock is proven through it. Appearance
itself has not been re-run.** The original finding:

**BROKEN in exactly the predicted way: Appearance.** It builds a
transient offscreen world per widget blit, and the sight→chase→hook
cycle loses every one (measured: 10 misses, 34 busy drops, 136
small-blit refusals, no text crossing). Its window-port geometry
records fine; its themed text never appears. This is not a new defect —
it is the world-replacement fact at its sharpest, and the D0 resident
`NewGWorld` patch (port handed over at creation) is the mechanism that
would close it. Until D0 is re-run from the resident, Appearance-style
per-widget compositors are out of reach and should be stated so.
**Sherlock 2 joined it the same evening**, at full-window scale: its
entire interior is one transient 490×448 composite (7 sights, 7 misses,
0 hooks), so the channel picker, list rows and radio labels are all
behind the same wall — only its window stream's own drawing crosses
(the Edit… well, the search caret), and the coverage suite gates
exactly that plus the honest hatch. D0's resident NewGWorld patch is
now the single mechanism between the mirror and both applications'
interiors, which makes it the next slice by a wide margin.

Two rig facts from the same sweep: `menuact` works on a FRESH boot (the
View-menu marks move; the earlier no-op was the stale kd01 boot — the
scene-walk staleness trap again, now with an act-plane face), and the
render fix for scrollbars was chrome, not capture: a ranged scrollbar
is window furniture and draws over display-owned content.

## ANSWERED: a 68K trap patch DOES see the CFM Finder's NewGWorld (2026-08-06, plan 014 E1)

The question that voided the applet experiment, asked properly - from
the resident, installed on the armed pass in the armed process's own
context - and answered on the first boot:

    qdext: {installed: 0x0058e61c, calls: 6509, newGWorld: 2,
            lastSelector: 0x00080006, foreign: 0}

`installed` names the incumbent, so the patch demonstrably went in;
`calls` counts dispatches seen INSIDE the armed Finder; **`newGWorld: 2`
is two selector-0 dispatches from a native PowerPC application**. That
is the whole precondition of plan 014: a native caller executes no
A-trap itself, but its InterfaceLib glue reads the trap dispatch table
at call time, and the Finder resolves NewGWorld against InterfaceLib
(E0, read from its own PEF import table). `foreign: 0` says the patch
did not fire outside the armed context, which is the scoping property
the plane promises.

So creation-time notification EXISTS, and the transient worlds that beat
the sight-then-chase route (Sherlock 2, Appearance) are reachable. The
escalations named as fallbacks - CFM TVector redirection, pixel islands
for composite-locked windows - are not needed and should not be built.

## NO VERDICT on D0: an applet cannot ask the trap-patch question (2026-08-06)

Plan 013 slice D0 asks whether a `NewGWorld` trap patch fires for a CFM
caller. `tools/guest-gworld/src/trapwatch.c` plants a counting
tail-patch on the QDOffscreen dispatch (`$AB1D`), with a dedicated
selector-0 (NewGWorld) counter after the raw count proved to be ~0.6/s
of ambient selector-7 traffic. The **control failed**: a freshly
launched 68K loop applet's startup `NewGWorld` — and its
LockPixels-per-blit storm — never crossed the patch. An application's
trap patch is process-local under the Process Manager; this is the act
plane's own paid lesson (`act-plane-click-never-taken`: installed once,
in NOW's context only) resurfacing in a rig applet. So the applet
experiment is structurally unable to answer D0, and **neither**
"mechanism exists" **nor** "fall back to the scan" is proven. The
rerun must install from the resident at the armed pass, in the target's
own context — exactly the act plane's `install_patch` pattern; the
applet and its protocol are committed for that rerun to reuse.

## ANSWERED: a foreign process's offscreen GWorld is hookable, and its labels are readable (2026-08-06)

`qdtrace start mode=probe` exists and is emulator-run: it sights a blit
into the armed window, then sweeps the application and system zones for
the CGrafPort that owns those pixels and hooks it as an offscreen row.
[The brief](gworld-probe-brief.md) is what it answers; scratch log in
docs/local/gworld-probe-run-notes.md.

**Working**: the recorder (SimpleText, the positive control, gives 22
text ops at their true pens). **Re-confirmed**: the Finder's icon view
emits one content-sized blit, `src == dst`, zero text, zero per-icon
ops — an independent reproduction of
`finder-window-icons-are-offscreen-blits` on a new binary.

**SOUND — the mechanism**, and this is the premise everything else
rested on. `tools/guest-gworld`, a 68K applet that allocates its own
GWorld and hooks it in its own context, fires every family on all three
allocation flavours: `text 1, line 1, rect 2, rgn 1, bits 1`. Offscreen
drawing DOES consult `grafProcs`, so **outcome 3 is off the table as a
mechanism claim** — any null from the foreign probe is a DISCOVERY
failure. `PlotIconSuite` emitted a blit into the offscreen port, which
answers outcome 2 favourably for the family most likely to have failed.
Every geographic assumption the chase makes also holds: port in the
APPLICATION zone, `portRect == bounds`, `grafProcs` NULL at allocation,
`RecoverHandle` agreeing; `useTempMem` moves only the pixels.

**THE CHASE WORKS**, proven on a purpose-built control
(`tools/guest-gworld/src/loop.c`, one GWorld held for the process's
life) whose port address the probe matched exactly. Then on the Finder:
holding the hook across a reflowing resize, its offscreen port gave 8
text + 24 rect + 11 rgn + 8 bits while the window port gave 4 opaque
blits — and the text carries real filenames at true pens ('Documents'
[280,67], 'TimBotTu' [282,131], 'TBT' [40,195], header '10 items, 3.21
GB available' [135,14]). **Window icon-view labels are recoverable as
semantic text**, composable host-side with no pixels on the wire.
Corpus finding: `gworld-offscreen-ports-are-hookable`.

THREE DEFECTS had to be cleared, and each hid the next: small blits
stealing the chase slot (fixed by largest-wins); a dereferenced pixmap
pointer carried across the draw-time/event-loop gap, when LockPixels
relocates the RECORD out of the app zone (fixed by matching on SHAPE);
and — the one that masked both fixes — a read guard bounded to
`[0x1000, MemTop]`, where MemTop is ~14.8 MB and application heaps sit
~512 MB above it, so it rejected every candidate it ever examined.

**STILL OPEN.** Icons arrive as identity-less `bits` while labels
arrive as text, so full host-side composition still needs
`PlotIconSuite`/`IconRef` interception. The broad spread (list view, a
control panel, a double-buffered app) is unrun: after a long session
the scene walk stops returning Finder windows with addresses, so phases
lose their target — a fresh VM per phase is needed. Ring pressure is
real: a composite-heavy app overran the 64 KiB ring inside one settle
(lostBytes 835410).

**Paid for on the way**: the scan crashed the Finder. It dereferenced a
`portPixMap` read out of arbitrary heap bytes with only a NULL/odd
check, and a wild pointer into unmapped space is a bus error taken
inside the application the resident is a guest in. Now range-checked to
physical RAM on both hops — the general rule being that resident code
walking a heap for a shape dereferences pointers it did not compute.

Two instrument lessons worth more than the probe: the counters encoded
that crash a full run before anyone read the screen (a scan that
increments its entry counter and none of its exit counters never
returned), and nothing on the wire reports a guest-side alert at all —
every counter read green while a crash dialog sat on screen.

## BROKEN: no verb reached through the PowerPC console's fallback can be given an ARGUMENT (2026-08-06)

Found while fixing the renderer half of the same seam (see
[command-parity.md](command-parity.md), "Present on both faces is not the
same as working on both"). `console_model.c` handles 27 verbs with a
`strcmp` of their own and falls through for the other eighteen —
`activate`, `actselftest`, `aesend`, `axsnap`, `axtree`, `ctlact`,
`ditemact`, `elements`, `handle`, `menuact`, `mouseloc`, `observe`,
`putstat`, `qdtrace`, `script`, `textget`, `textset`, `winact`. The
fall-through is:

    now_command_run(name, NULL, 0, result, sizeof result);

`NULL` is the whole request, so the verb sees no arguments at all. Twelve
of the eighteen therefore answer a validation refusal and nothing else,
no matter what a person types after the verb. Measured on the emulator,
build `fea48baffe8f`, wire 5510, through the exec plane:

    > winact          winact requires action: one of select, close, move, resize, zoom
    > menuact         menuact requires menu (the menu's id) and item (its 1-based position…)
    > script          script requires source: one AppleScript, as a string
    > aesend          aesend requires event: one of quit, oapp, odoc, pdoc
    > activate        activate needs a whole process serial number: serialHi and serialLo…

Typing the arguments changes nothing, because the console never passes
them. The refusals are correct and useful sentences — they are just the
only sentences those verbs can produce at that keyboard.

Six of the eighteen take no arguments and now work: `putstat` and
`mouseloc` render real tables, and `axsnap`, `axtree`, `elements`,
`observe` and `qdtrace` answer objects of references, which the console
says it cannot show as a table rather than claiming a failure.

**What it would take.** A grammar, not a renderer: something that turns
the rest of a typed line into the `args` object the wire sends, with
types (`now_json_find_int` vs `now_json_find_string` — a quoted 3 is not
a 3). `now-guest-ppc/src/commands/cmd_line.c` already reads the OTHER
direction and is the obvious place to put its inverse. `script` and
`aesend` and the act verbs are the ones a person would most want, and
`docs/command-parity.md`'s `consoleDebt` map is the list. The three verbs
whose arguments are opaque `now-element-` references are a different
problem and probably stay untypeable.

**Why it is parked.** The reported defect was a renderer printing
"command failed" for commands that had succeeded; that is fixed and
verified at both faces. A console argument grammar is a design decision
about what a person can type at a classic Mac, and folding it into the
same change would have made both harder to review.

## BROKEN, and it is the WORST shape: a ten-second gap in scene polling blinds the whole walk, and the Mirror keeps drawing what it can no longer see (2026-08-06)

Michelle, side by side with the guest: Date & Time's **Set Time Zone**
modal open on the machine, and in the Mirror "System Folder, Control
Panels and Date & Time" and no modal at all — with the status line
reading `5 windows · walk 0ms · transfer 36ms · **same** · content: 13
new draw ops`. `same` is the guest saying *nothing changed* while a modal
was visibly open, which is the stale-mirror-that-believes-it-is-current
failure this project fears most.

It is neither of the two things it looked like. Both were tested on a
private clone (VM `/private/tmp/nowvm-modal`, wire 5490, guest build
`c5c39f61dbbf`), asking for WHOLE documents so no answer could be a delta
artefact.

**The walk is not the defect.** With the modal up the guest publishes it,
within ~600 ms of the quit and for as long as it is there:

    seq=91  windows=[Date & Time; New Old World]                 digest 2c7784cf
    seq=92  windows=[Set Time Zone; Date & Time; New Old World]  digest 95b9a08b

`kind:2`, visible, front, 9 dialog items with a `ref` on each, 10
controls, coverage `complete` for that owner, no error against it.

**The delta plane is not the defect either.** The digest MOVES when the
window appears, and `scene.same` is decided against the digest of the
scene *just walked*, not a remembered one (`wire.c :: serve_scene`), so a
guest cannot answer `same` while the modal is in its own document. The
host's half keeps it too: `MirrorQuitModalTests` runs that captured
document through this side's decoder, the replica reducer and the
projection, and the window survives all three.

**What IS the defect: the anchor plane is held by a ten-second lease that
only a `scene.request` renews.** `peek.c :: kNowPeekOwnerLeaseTicks` is
600 ticks. Stop asking for scenes for longer and the next walk is blind —
measured on the wire, with the modal up the whole time:

    gap  3s → Set Time Zone, Date & Time, New Old World   (95b9a08b)
    gap  8s → Set Time Zone, Date & Time, New Old World   (95b9a08b)
    gap 12s → New Old World only                          (ae3f00e1)
    gap 20s → New Old World only                          (ae3f00e1)

In a blind scene EVERY foreign process reports `now_no_plane` and
`coverage: unavailable/not-observed`, and the document contains not one
foreign window. The scene straight after each blind one is right again,
because the blind walk is the one that RE-claimed: `serve_scene` claims
the plane and walks immediately, while the extension only arms on its
next `jGNE` pass. **Re-claiming therefore costs exactly one scene.**

**Why that produced Michelle's frame.** A second agent measured her guest
at that moment: `requested=8 active=8` — content armed, structure,
semantics and interaction all inactive — and her Cancel click refused
five times with `element-not-found: the anchor plane is absent or not
armed`, at 6.7-8.8 s each. Thirty to forty seconds of acts with no scene
between them is four leases' worth. Then it is self-sustaining:

- the planes lapse, so the walk goes blind;
- the blind document is honest but EMPTY of foreign windows, so the host
  retains its last-known ones as `expectedStale` (`MirrorReplicaReducer`
  deletes only under `complete` coverage) — which is the Finder folders
  and the Date & Time panel Michelle could still see;
- the blind document is STABLE, so every later poll answers `same`;
- the modal, raised after the planes went down, is in no scene ever;
- and every act refuses, because the plane it needs is the one that
  lapsed, which spends more seconds not polling.

The split Michelle reported falls straight out of it: a modal she opens
by clicking arrives while the planes are up and renders; the one Date &
Time raises during its own quit arrives after a stall.

**This is not tonight's work.** The lease is from 2026-08-03/04
(`4ebd575c`, `7e5b0c8f`). Tonight's deltas made it VISIBLE by putting the
word `same` on screen, and are otherwise innocent — which is the one good
thing here.

**What is not yet decided, and needs a person.** Three candidate fixes,
and they are not equivalent:

1. **Do not serve a blind scene.** `serve_scene` already claims the plane
   before walking; it could pump until `arm_active` includes anchors
   before it walks, bounded. The other agent measured the arm handshake at
   ~15 ms tonight, so the bound is cheap. This removes the one-scene lag.
2. **Do not let the lease lapse under a live consumer.** A connected host
   that is doing anything at all is not a host that has gone away, so the
   renewal could ride the wire rather than the scene verb. Against: the
   lease exists so a plane is not armed on a machine nobody is watching.
3. **Say it.** The status line reads `5 windows · same` while several of
   those windows are retentions of a machine the guest could not observe.
   The reducer already knows — `freshness == .expectedStale`,
   `actionable == false`, `baseComplete == false` — and
   `NOWMirrorSource.swift` already has the vocabulary for exactly this
   (`" · Apple menu expected-stale"`). Windows have no equivalent. **Do
   this one regardless of which of the other two wins**, because a mirror
   that cannot see the machine must say so rather than keep drawing.

The fixtures for all of it are in the tree:
`now-host/Tests/HostTests/Fixtures/scene-quit-modal.json` (the modal, as
the guest sent it), and `scene-plane-held.json` /
`scene-plane-lapsed.json` (the same machine, one poll apart, either side
of the lapse). `MirrorQuitModalTests` pins what this side does with them;
its staleness assertion has been watched to fail.

**How to open a control panel over the wire, since it costs an hour to
find.** `launch` refuses one — `not an application (type APPC)`. The
route that works is the `script` verb:

    tell application "Finder" to open file "Date & Time" of folder \
      "Control Panels" of folder "System Folder" of startup disk

(`{"source": "...", "timeoutMs": 25000}` — the argument is `source`, not
`text`.) On a clone whose time zone has never been set, that alone raises
the Set Time Zone modal, so the case needs no quit to reproduce.

**FIXED and measured, 2026-08-06** (`4b972ade`). Candidates 1, 2 and 3
all landed, because 1 and 2 cover different halves of Michelle's
sequence and only together cover it. Same instrument either side —
`tools/local-plane-lapse.py`, whole documents, a control panel open
throughout, and it refuses a guest whose build is not the one asked for:

| gap of total wire silence | before (`c5c39f61dbbf`) | after (`53cbc0fc5dcb`) |
|---|---|---|
| first scene of the connection | NOW's window only | the machine |
| 3 s, 8 s | the machine | the machine |
| 12 s, 20 s, 25 s | **NOW's window only** | the machine |

And the reported frame end to end: twenty seconds of silence, then
`tell application "Date & Time" to quit`, and the FIRST walk after it
carries `Set Time Zone`. Before, that walk was the blind one.

- **Renewal rides host traffic, not the event loop** (`wire.c ::
  renew_scene_planes`). A host sending acts wants the planes; the event
  loop runs whether or not anyone is watching, and an armed plane is
  work charged to every process on the machine. Two gates keep it
  honest: only after a scene has been asked for on THIS link, and never
  on `pong`, which is the reply to our own heartbeat and would make
  "connected" mean "armed forever".
- **A scene waits for the arm echo** (`peek.c :: now_peek_settle`),
  bounded at half a second and returning the moment it lands. It never
  asserts an arm it did not observe — no resident, no writer, or a
  passed deadline all fall through to a walk that reports not-observed.
  This is also why the FIRST scene of a connection is no longer blind;
  the warming ritual `tools/local-arm-latency.py` documents is now
  unnecessary (its docstring is stale, and is left as the record of why
  it existed).
- **The status line distinguishes seen from retained**: `5 windows, 3
  expected-stale · walk … · same`. `MirrorQuitModalTests` pins it
  against the two lapse fixtures, watched to fail.

What is NOT closed by this. A host that goes entirely silent for longer
than the lease still lets the planes lapse — deliberately, that is the
lease doing its job — and the recovery now costs latency (one settle)
rather than a scene. And the arm handshake itself is unchanged: nothing
here makes a plane arm faster, only stops asking before it has.
## FIXED in the host, UNVERIFIED by any drive: Apple menu items did nothing, and the act was never the missing part (2026-08-06)

Michelle, driving: "apple menu items dont work (apple menu -> control
panels, sherlock, system profiler etc)". The menu drew correctly and
selecting a row did nothing on the machine.

The act was sent, reached the guest, and was dispatched. `acts.log`
carries all three attempts, each planning
`menuCommand(menuID: -16383, itemIndex: 3/6/14, titleLeft: 10)` and
answering in **18–50 ms with settlement `unknown`** — the self branch of
`menuact`, which queues the choice for NOW's own main loop and returns
without settlement rows. Compare the Finder's File > Quit on the same
drive: **~800 ms, `dispatched-but-unconfirmed`**, the foreign act plane.
Two mechanisms, and the fast one ends at `main.c :: handle_menu_choice`,
which serves menus 129, 140 and the rest of NOW's own bar and has **no
Apple-menu case at all**. The choice fell off the end of the switch.

Fixed by routing every row below the Apple menu's first separator to
`openAppleMenuItem`, which asks the guest Finder to open the file by
name — the mechanism that already existed and was wired to Key Caps
alone. `ObjectResolver.isAppleMenuItemsEntry` makes the decision where
the sibling rows are visible, and `MirrorDriveService` calls the same
function so the agent face cannot drift.

**No drive has watched an Apple menu row open.** Verified only by
mutation: restoring the Key-Caps-only rule reproduces the three logged
plans byte-for-byte.

### Two things it does not fix

- **A folder alias will time out having worked.** `openAppleMenuItem`
  predicts `processNamedPresent(name)`, which is right for Sherlock 2
  and Apple System Profiler and wrong for Control Panels — an alias to a
  FOLDER, which opens a Finder *window*. That burns the full 15 s
  settlement holding the one mutation lane, the same shape
  `MirrorActionExecutor.finderOpen` documents and fixed for itself by
  classifying the item. Here the item cannot be classified: every Apple
  Menu Items entry is an alias, and an alias reports its own kind and
  never its target's. It needs either a postcondition meaning "a process
  OR a Finder window by this name", or a guest probe that resolves an
  alias. Functionally the open works; only the reporting lies.
- **At the machine, the same click still does nothing.** This is a
  host-side route. A person sitting at the guest with NOW frontmost who
  chooses Apple > Sherlock 2 gets the same silence, because
  `handle_menu_choice` still has no Apple case and `OpenDeskAcc` is not
  in CarbonLib. Whether the guest should serve its own Apple menu — and
  through what, since the obvious call is absent — is open, and it is a
  command-parity question, not a Mirror one.

## BROKEN, and it is NOT the host's click translation: a modal's Cancel is refused because the planes went inactive (2026-08-06)

Michelle, same drive: in Date & Time's Set Time Zone modal — which
renders — "Cancel doesn't work", while an earlier session's `ditemact`
sent straight over the wire had dismissed that same button.

That pairing reads like a host translation defect and is not one. The
host resolved the click correctly and sent the right act:
`plan=dialogItem(ref: "now-element-5f5c3825-…", item: 2)`, the same verb
and the same item number the wire test used. **The guest refused it**:

    element-not-found: the anchor plane is absent or not armed

after 6.7–8.8 s, five times over. The `actmeta` line at that moment says
why: `requested=8 active=8`, with
`structure=inactive semantics=inactive interaction=inactive` and only
`content` active. The planes the act needs had gone down; `requested`
had dropped from 15 to 8.

So the open question is **what takes the structure/semantics/interaction
planes inactive while the content plane stays up**, and whether a modal
being frontmost is what does it — which would tie this to the existing
"one modal wedges the whole Mirror" entry below. Until that is answered,
do not attribute a dead-looking Mirror click to hit-testing without
reading `actmeta` at the same timestamp first: the refusal was recorded
plainly and was still nearly diagnosed as the wrong half.

## MEASURED, and the answer is DON'T BUILD ON IT: how long the content plane takes to arm (2026-08-06)

Plan 013 § A proposes turning the resident into a NOTIFIER — told at
mutation time instead of asked on a timer. **The content plane's arm
handshake is that idea already shipping**, so it is the one place the
proposal can be costed instead of argued: the application writes a
request, and it is honoured only when the TARGET process next runs the
resident's jGNE pass and agrees it is the one named
(`ext/src/now_content.c :: now_content_gne`). The host's status line says
`content: requested X's trace; waiting for its event loop to arm`, and
nobody knew whether that sentence covered 40 ms or 4 s.

**The conditions.** One session-private clone off `os91-runner.qcow2`,
build `9a1d885fcac0`, wire 5450, anchor 1702, `tools/local-arm-latency.py`.
Time from the `qdtrace start` reply to the first `qdtrace status`
reporting that generation **and** that A5 live.

| condition | arm | wire floor, SAME condition | n |
|---|---|---|---|
| NOW's own window, NOW front | **22 ms** (20–31) | 102 ms | 10 |
| Finder's window, Finder front | **116 ms** (102–117) | 101 ms | 10 |
| Finder's window, NOW front | **never**, 25–45 s | 57 ms | 9 |
| …then brought forward mid-wait | **40 ms** after the front change | 56 ms | 6 |
| front application holding a modal | **30.1 s** | 30.0 s for ONE status call | 1 |
| an A5 no process has (control) | never | — | 8 |

**Read the floor column first, because it is the whole finding.** A bare
`qdtrace status` round trip costs ~101 ms when NOW is in the background —
that is NOW's own event-loop period, not the network. So the 116 ms
against a 101 ms floor means **the frontmost Finder pumps within about
15 ms of the request**, and the 22 ms self case is complete before the
first status poll can be asked and is not measurable from here at all.
The arm handshake is fast. The sentence a person reads is mostly the
host's poll cadence.

The first version of this measurement reported the 116 ms as the arm
cost, against a floor taken once at startup in a different front
condition. It is the same mistake plan 013 records against its own first
finding — two variables moved and the differential was read as one — and
it was caught only because the floor was re-measured per condition.

**The two large numbers are not handshake problems**, which is why
nothing here justifies a mechanism:

- **A background application never arms at all.** Not slowly — not at
  all, over 45 s. The unguarded refusal counter says why, and it is the
  useful half: `wrongContext` climbed ~1,770 in 25 s, so processes WERE
  pumping and reading the request the whole time and none of them was the
  Finder (measurement rule 6 — "never entered" and "entered and declined"
  are opposite repairs). The deferred run settles it with one variable
  moved and the same arm: bring the Finder forward without re-requesting
  and it arms in 40 ms, 6/6. A resident notifier cannot fix this. Nothing
  can make a process pump that the Process Manager is not running.
- **Under a modal the wait is the modal.** `tools/guest-wedge modal 30`
  and the arm landed 30.133 s later — the wedge's own duration. The first
  `qdtrace status` after the launch took 30.023 s, so the host could not
  even ASK for 30 s. That is plan 012's liveness territory, already owned,
  and it is not about arming.

**DECISION: do not build the § A notifier on this evidence.** The host
arms only the front window's process (`NOWMirrorContentPlane.join` takes
`scene.windows.first(where: \.front)`) and re-arms on target change or
after `renewAfter` = 9 minutes against a 10-minute TTL. So the measured
cost is ~15 ms of real handshake, paid on a focus change and roughly
never otherwise, on a machine whose whole scene walk is now 3–8 ms. There
is no mechanism that pays for itself here. Per plan 013's own tiering
this would have been tier 2, and the plan prefers re-arguing to
executing — so it is re-argued and dropped.

**What this does NOT settle.**

- **Every number is from mac99.** The dominant term is a Process Manager
  round, so it should scale with process-switch cost rather than with how
  much interface exists — but that is reasoning, not a reading, and a
  1400c has never been asked.
- **"Just launched" was never measured.** `launch` refuses a control
  panel (`launch-refused: not an application (type APPC)`), which is the
  case the observation actually named, and an arm needs an exact window
  address out of the scene — so a just-launched application cannot be
  armed until it has already pumped enough to open a window. The product
  can never request an arm earlier than that.
- **The modal row is n=1**, and it is the wedge's GetNextEvent loop, not
  a real application's modal.
- **The plane measured is the one on `claude/mirror-thread-content`.** The
  GWorld work on `claude/gworld-probe-grounding-3dcbd4` adds ~600 lines to
  `ext/src/now_content.c`, four hunks of them inside `now_content_gne`
  itself. `now_content_arm_verdict` is untouched, so the mechanism
  survives, but the per-pass constant does not necessarily. Re-measure
  after that lands.
## SHIPPED on an emulator, UNVERIFIED on metal: a scene can now answer "the same", or send only what moved (2026-08-06)

Plan 013 § 5. The wire had become the dominant cost — a 3–8.5 ms walk
against a 111–710 ms transfer of a 26–28 KB document, several times a
second, for a Macintosh that mostly had not changed. `scene.request` now
takes a `since` (the body digest the host already holds) and gets one of
three answers: `scene.same` (a control frame, no transfer at all), a
delta carrying only the entities that moved, or a whole document.
Design: [scene-deltas.md](scene-deltas.md). Numbers:
[scene-delta-measurements.md](scene-delta-measurements.md).

**What is proven.** Tested, on a session-private mac99 clone, guest
`df570d8014de`: an idle machine's wire cost drops to **10.3–10.4% over
ten polls**, and after the first scene each poll costs one control frame.
Walk time did not move (0 ms idle, 16 ms driven, both conditions). The
byte-exact reconstruction and the digest check are pinned natively on
both sides, including a two-halves test whose fixtures the GUEST'S
encoder emitted.

**What is not.**

- **No metal pass.** And the emulator understates this one rather than
  overstating it, which is the reverse of plan 013's usual warning: its
  network is host loopback, so the byte term this change removes is
  nearly free here and expensive on a 1400c. The idle saving should be
  worth *more* on the hardware, not less. That is a prediction.
- **The driven case saves ~5%**, because changing the frontmost
  application rewrites every app row, every window's front/z and the
  whole menu bar. That is honest worst-case behaviour and the guest
  correctly still picked the smaller of the two, but nobody has measured
  the realistic middle — one window moving on an otherwise still
  machine — on real hardware or with a real person driving.
- **NOW-68K serves none of it**, because it serves no scene at all. The
  asymmetry is declared in
  [contract-coverage.md](contract-coverage.md); the delta design is
  sized for that machine (a few kilobytes of state, a 32-bit hash), so
  what it lacks is the walk, not the room.
- **The host applies a delta and then throws the result at the unchanged
  reducer.** That is deliberate — one deletion rule, in one place — but
  it means a rebuild is a whole document's worth of decode every time.
  Nothing measures whether that decode is now the expensive half.

### An observation the measurement produced, and it is not about deltas

Revealing two different Finder folders alternately, once per poll,
produced **nine `scene.same` answers out of ten**: the walked scene was
byte-identical each time. Either the Finder did not reorder its windows,
or the walk does not see that it did. `scene.same` is a rather good
change detector and it has just detected something. Worth a second look;
not chased here.
## FIXED on an emulator, NEVER ON METAL: both things the control sweep got wrong, from one change — the guest stopped hunting for controls it had made itself (2026-08-06)

Plan 013 § 2. The entry below names two costs, a 1.9-second focus change
and a background sweep that reported zero controls, and treats them as
one performance item and one correctness item. **They are one defect**,
and its root is a single sentence in Inside Macintosh: `FindControl`
refuses an INACTIVE window. Refusing means answering nothing, so with
anything else in front the sweep walked all 3,724 points, found nothing,
cached nothing, and re-swept on the NEXT poll forever — and the cache was
therefore EMPTY at the exact moment a person clicked into NOW, which is
when a probe costs ~240 µs instead of ~2.7 µs.

**The fix is that the application already knew the answer.** Every
control here goes through `now_control_new` (`workshop/control_kind.c`),
which existed so the scene could report a `role`. That table is now the
scene's LIST of a window's controls, and the lifecycle is closed around
it: `now_control_adopt` for the DataBrowsers (a constructor that takes no
procID, so it cannot go through the wrapper), `now_control_dispose`,
`now_control_dispose_window` and `now_control_dispose_dialog` — because
`DisposeWindow` destroys a window's controls and tells nobody.
`control_kind_source_test.py` gates all five calls, and both of its
refusals were watched by mutation.

Only EXISTENCE is remembered. Title, bounds, value, enabled and visible
are read live every pass, and invisible controls are skipped exactly as
the sweep skipped them — so a Workshop page switch needs no invalidation
at all, which also settles the question the § 1 measurement left open
about whether one bumped the generation. **Nothing is cached, so nothing
can be stale**, which is the opposite of the risk plan 013 warns about
and is worth saying plainly: the projection is rebuilt from the Toolbox
on every scene.

Same clone, same session, one variable — which binary is staged. Guest
builds `2c5dc9cb7d54` (after) and the merge base (before), wire 5430,
`tools/local-scene-bench.py` reading `meta.phases`, µs:

| condition | before, `controls` | after, `controls` | controls reported |
|---|---|---|---|
| NOW front, steady state | 3,217 – 4,890 | **713 – 989** | 9 → 9 |
| the scene NOW becomes front on | **886,398** | **713** | 9 → 9 |
| NOW backgrounded | 7,206 – 7,588 | **477 – 1,324** | **0 → 9** |

The focus-change scene measured 886 ms here against the 1,891,174 µs in
the entry below; a parallel instrumented run the same night saw
1.21–1.43 s. It is a wide range, and every value in it is the same
defect. The focus cycle was repeated three times on the build under test
and the `controls` phase stayed between 727 and 922 µs with no spike.

**The correctness half, which was the worse one.** Backgrounded, the
scene now carries NOW's nine real controls instead of an empty window —
an absence nobody had observed, which the coverage rules forbid. Where
the registry cannot answer (a Dialog Manager window this application did
not build, seen while inactive) the control plane is RETRACTED rather
than swept: the key is absent and `meta.errors` carries the notice,
because "nobody could look" and "there is nothing there" are different
facts. **That retraction path is built and NOT observed** — it needs an
inactive DITL dialog and nothing in this session opened one.

Page switching was checked as a positive control rather than assumed,
over the wire with `menuact` on the View menu: Preferences 5 controls,
Processes 6, Screenshots 9, each correct for its page, each fresh.
Processes shows six because its DataBrowser is now adopted and therefore
mirrored — it carries `role: dataBrowser`, where before it fell through
to the emitter's range guess.

**What is not done.** Nobody has watched any of this on the PowerBook
1400c; every number is QEMU. The sweep still exists for windows this
application did not build, and on that path everything the entry below
says still holds.

## OPEN, and now MEASURED rather than argued: where a scene's time goes, and the two things the control sweep still gets wrong (2026-08-06)

Plan 013 § 1. Every scene now carries `meta.phases` — microseconds per
phase, named for what the guest was doing — so the entry below, which was
written from a THROWAWAY breakdown, no longer needs one. The breakdown
is permanent, additive on the wire, and publishes its own cost. This
entry is what the first measurement with it says.

**The conditions**, one clone off `now-mirror-stage.qcow2.bak-20260806`,
build `9ed6e7d18c19`, wire 5410, control-sweep fix merged. Median of the
STEADY-STATE scenes in each condition, microseconds:

| phase | Finder front | NOW front |
|---|---|---|
| enumerate | 952 | 1045 |
| bind | 182 | 214 |
| windows | 696 | 970 |
| controls | **290** | **5090** |
| menubar | 107 | 1359 |
| semantics | 20 | 17 |
| refs | 153 | 225 |
| encode | 589 | 596 |
| **whole walk** | **~3.0 ms** | **~8.5 ms** |

Against the 116 ms / 1116 ms this plan opened with. The sweep fix holds,
and it holds in both conditions.

**Two costs the fix does not remove, both visible only now.**

1. **A focus change costs one 1.9-second scene.** Measured: the scene in
   which NOW became frontmost reported `controls = 1,891,174 µs`. The
   cache is invalidated by the activation and the whole 3,724-point grid
   is re-swept, in the foreground, at ~240 µs a point. Every subsequent
   front scene is ~5 ms. So the cost did not go away — it moved from
   every poll to every focus change, which is a very large improvement
   and still the single most expensive thing on this machine.
2. **The background sweep is pure waste, and it is also a HOLE IN THE
   MIRROR.** `FindControl` answers an inactive window immediately — which
   is why the sweep is cheap in the background — but "immediately" means
   it answers NOTHING. Measured: with the Finder in front, NOW's own
   window walk spends 5–10 ms sweeping 3,724 points and returns **zero
   controls**. The scene therefore shows NOW's own window as empty
   whenever NOW is not frontmost. That is not a performance issue with a
   performance fix; the mirror is reporting an absence it did not
   observe.

**Both of those are FIXED (2026-08-06, emulator only) — and they were one
defect, not two.** See the entry above. What is left standing here is the
diagnosis, which is worth keeping for its shape: the two were filed as a
performance item and a correctness item because that is how they present,
and they share a root (`FindControl` refuses an inactive window) and a
cure (do not discover what you already know you made).

**The wide answer plan 013 asked for: yes, the shape is everywhere.**
Every remaining phase is a full re-derivation, per poll, of something
that rarely changes — the process list (`enumerate`, ~1 ms and identical
in both conditions), the window chains (`windows`), NOW's own menu bar
(`menubar`, 1.36 ms), and the document itself (`encode`). Nothing in the
steady state is proportional to what CHANGED. The control sweep was not
the only one; it was the loudest. **But the absolute numbers are now
single-digit milliseconds on an emulated G4**, so the case for plan 013's
slices 3–5 no longer rests on comfort here — it rests entirely on the
vintage-hardware multiplier, and that argument should be made with a
number from a 1400c rather than assumed.

**What the breakdown costs, stated because it must be.** 130–330 µs per
scene on this machine, from 26–66 `Microseconds` calls at a calibrated
~4.9 µs each — the emulator's trap cost, and it will be lower on real
PowerPC. That is 0.02% of the 1.9 s scene and up to 8% of a 3 ms one; it
is bounded by PROCESSES and WINDOWS, never by controls or menu items, so
it does not grow with the size of the interface. It is left on because a
breakdown that is off by default is a breakdown nobody has when they
need it, and every scene publishes `phases.clockUs` so a reader can
subtract rather than wonder. **If a metal pass shows `Microseconds`
costing what it costs here, the seam count is what to reduce** — the
per-process bind/windows/menubar trio is 6 of every 8 clock reads.
## FIXED: the PowerPC guest never reads the host's contract revision (2026-08-06)

**Fixed and watched on an emulated Power Mac G4 the same night**, guest
build `48a2af200ab7 2026-08-06T06:54:16Z`, on a session-private clone
(wire 5421). A host answering `contract: 1` is refused with
`{"type":"refuse","contract":2,"reason":"contract revision 1 != 2"}` and
the guest closes; a host answering no `contract` at all is refused with
"host hello states no contract revision; this guest speaks 2"; a host
answering 2 is served, and between all three the guest redialled on its
own backoff without being asked. The permanent check is
`WireLimitsAgreementTests
.testBothGuestsGateTheContractRevisionInTheirHelloHandler`, which reads
both guests' hello handlers and was watched failing with the old
`on_hello` pasted back in.

**The open question this entry ended on — whether a guest should SEND a
refuse — is now settled in the contract**, not in one guest's habits.
`contract/asyncapi.yaml`'s connection rules say the gate binds whoever
RECEIVES a hello (both halves of it), that an ABSENT `contract` is a
mismatch rather than a tolerance, and that the refusal is sent and names
both numbers: a silent hang-up is indistinguishable from a dropped
network at the far end, which is the one thing gating at the door exists
to tell apart. Two implementations moved to meet it — NOW-68K, which
refused silently with a `bye` and a status reading "contract mismatch",
now sends `refuse` naming both numbers; and the host, which dropped an
inbound `refuse` into a `default:` arm, now logs it and finishes, since
"never swallowed" is that schema's own word.

The original entry, unedited:

## FIXED on an emulator, NEVER ON METAL: NOW's own window cost ~1 s of every scene, and the suspect was the wrong one (2026-08-06)

**The symptom.** With NOW frontmost — which is what a person does the
moment they click its window — every scene poll took roughly a second.
With anything else in front the same machine answered in 16 ms while
reporting MORE (8 menus / 82 items against 7 / 48). The self path did
less work for ten times the cost.

**The suspect, and why it was wrong.** The only step that runs
exclusively when NOW is frontmost is `collect_self_menubar`
(`scene_self.c`) — the menu bar collected through the Toolbox, where a
foreign machine's bar is read through the validated memory reader. It
looked expensive too: `root_items_for()` rescans the root menu once PER
MENU, so ~7 full rescans a scene, and the Apple menu's 16 items are
backed by a folder on disk. That is an inference from two conditions and
it survived only until somebody timed the function.

Timed directly (a temporary `meta.dbgUs` breakdown, `Microseconds`, one
fresh clone, six scenes each):

| step | NOW frontmost | Finder frontmost |
|---|---|---|
| `collect_self_menubar`, whole | 1.0 – 2.5 **ms** | not run |
| `root_items_for`, all 7 menus | 0.30 – 0.43 ms | — |
| `add_one_menu`, all 48 items | 0.63 – 1.2 ms | — |
| `find_controls_by_probe` | **875 – 925 ms** | 10 – 22 ms |
| `latencyMs` | 866 – 1133 | 16 |

The menu bar is 0.1% of it, on this machine, with no sign of the disk
cost the Apple menu could have carried. **The cost is the FindControl
sweep over NOW's own window**, and it hides from the obvious A/B for a
documented reason: `FindControl` answers an INACTIVE window immediately.
The identical 3,724-point sweep costs ~2.7 µs a point in the background
and ~240 µs a point in the foreground.

**The fix** (`scene_self.c`, `control_kind.c`): cache the sweep's
DISCOVERY — which controls this window has and the point each was found
at — and re-prove it every pass at one `FindControl` per control. The
rows themselves are still rebuilt from the live Toolbox every scene, so
nothing a person changes goes stale. A control that went away, moved or
was hidden fails its point and the sweep runs again; a control that
ARRIVED disturbs nothing cached, so `now_control_generation()` catches it
instead — every control this application makes goes through
`now_control_new`, and `control_kind_source_test.py` enforces that. A
cached `ControlRef` is only ever compared, never dereferenced, until
`FindControl` has answered with it.

Same clone, same build discipline, guest's own `latencyMs`:

| condition | before | after |
|---|---|---|
| NOW frontmost, steady state (10 scenes) | median 916 ms | **median 0 ms** (9 of 10 at 0) |
| Finder frontmost (8 scenes) | median 16 ms | median 0 ms |
| first scene after a Workshop page switch | ~900 ms | 250 – 1550 ms, then 0 |

Scene contents are unchanged (7 menus / 48 items either way), and the
cache was verified by driving `View` across three pages over the wire:
identical within a page, different across one, correct on each.

**What is NOT done, and what would change the answer.**

- **Nobody has watched this on the PowerBook 1400c.** Every number here
  is QEMU. The direction should hold — the fix removes ~3,700 Toolbox
  calls per scene and adds ~7 — but the size will not.
- **The first scene after any control change still pays the full
  sweep**, 250 ms to 1.5 s depending on how many controls the page has.
  That was paid on EVERY poll before; it is now paid once per UI change.
  Reducing it means reducing the sweep itself, and the honest options are
  a coarser grid (which would miss the 12pt disclosure triangle) or
  giving these windows a root control (which reshapes the interface being
  described — rejected once already, see `scene_self.c`).
- **The menu-bar optimisations were deliberately NOT taken.** Resolving
  the root menu once per scene and change-detecting the MenuList are both
  correct and both worth ~1 ms here. They are not free: NOW's menu bar
  rendered EMPTY after a Hide on 2026-08-05, so menu freshness is a live
  defect surface, and spending it for 0.1% is a bad trade on the evidence
  we have. If a metal run shows the Apple menu's folder-backed items cost
  real time there, that is a different finding ("this cost is
  disk-shaped") and points at not re-reading unchanged items at all.
## BROKEN, contract violation: the PowerPC guest never reads the host's contract revision (2026-08-06)

`contract/asyncapi.yaml`, connection rules: "`contract` is a single
integer revision. **Unequal revisions => refuse.**" Three of the four
implementations do that. One does not.

| side | on an unequal revision in the peer's hello |
| --- | --- |
| host (`Session.swift:1511`) | refuses, reason names both numbers |
| NOW-68K (`wire68.c :: handle_host_hello`) | logs it, `set_status_str("Protocol error: contract mismatch")`, `teardown_and_retry(NULL, "protocol-error")` |
| `scripts/probes/nowwire.py :: _gate` | refuses |
| **NOW-PPC (`wire.c :: on_hello`)** | **never looks at the field.** It reads `name` and `version`, sets `kConnConnected`, and serves the session |

`on_hello` is twenty lines and `contract` is not among them; the
handshake dispatch above it (`handle_frame`, `g.phase ==
kConnHandshaking`) routes `hello` straight there without checking
either. So the PowerPC guest will hold a full session with a host
speaking any revision at all, including one that predates every message
it is about to be sent.

**How it surfaced.** Five Python harnesses declared the revision by hand
and two of them still said 1 (fixed on `claude/wire-revision-drift`,
`contract/wire_limits.py` plus three gates in
`WireLimitsAgreementTests`). Those two had been talking to NOW-PPC
guests perfectly happily — which is exactly the problem: the guest's
missing check is what made a year-stale harness look fine. Against
NOW-68K the same harnesses could never have held a link, and that
difference is the whole diagnosis.

**Why it is worth more than the tools fix.** The check exists to make a
version skew fail loudly at the door instead of quietly in the middle of
a message nobody can decode. A guest that skips it converts "refused,
here is why" into a session that misbehaves later with no handshake to
blame, and that is the `two-halves-never-met-in-a-test` shape.

**The fix**, not taken here because this branch is the tools half and a
guest behaviour change wants a metal pass: read `contract` in
`on_hello`, and on a mismatch set a status naming both numbers and tear
the connection down the way `handle_frame` already does for `refuse`
(return 0). NOW-68K's `handle_host_hello` is the model — including its
treatment of an ABSENT `contract` as a mismatch, since the field is
required.

**What is not known.** Whether the guest should also SEND a `refuse`
before closing. The contract words the refusal as the host's move ("the
host answers `hello` (accept) or `refuse` and closes") and never says
what a guest does with a bad host hello, so NOW-68K's silent teardown
and a hypothetical guest-sent `refuse` are both defensible readings.
AGENTS.md says the file family is symmetric; if that governs here, the
contract's prose should say so explicitly rather than leaving two
implementations to guess. Settle the prose before writing the code.

## UNSETTLED: the host app reported as always-on-top; no window level exists to cause it (2026-08-06)

Michelle: the macOS app window floats above other applications. What was
measured, without driving anything:

- **No window level is set anywhere.** `NSWindow.level`, a floating
  panel, `orderFrontRegardless`, `collectionBehavior`, `LSUIElement`: none
  of them appear in `now-host/`, in the vendored `mirror/` package, in the
  Xcode target's generated Info.plist, or anywhere in this repository's
  history on any branch.
- **The running windows are at level 0.** `CGWindowLayer` read from the
  window server for every window of both copies running on the desk — the
  human's (pid 27820) and a freshly built one — was `0`
  (`NSNormalWindowLevel`). A level-0 window cannot stay above another
  application's windows once that application activates, so "floats" is
  not what the window server is being told to do.
- **The one lever that does steal the front** is
  `NSApp.activate(ignoringOtherApps: true)` at `App.swift:401`, which runs
  on EVERY route into `openMainWindow()`: launch,
  `applicationShouldHandleReopen` (a Dock click, or any `open` of the
  bundle), the status item's "Open New Old World", ⌘, for Settings, and
  every module item in the Windows menu. `ignoringOtherApps: true` puts
  NOW in front of whatever application the person was typing in, rather
  than waiting to be switched to.

**Fixed by narrowing the routes, not by dropping the call.** Simply
asking politely would not do: from a background app
`activate(ignoringOtherApps: false)` does nothing at all, and a status
item's menu does not activate its own application — so "Open New Old
World" would open the window behind everything, which is the shape of the
two regressions this file already carries comments about. So the forceful
activation stays, and moves to `openMainWindowFromOutsideTheApp()`, called
by exactly the two routes where a person asked for this window from
outside the app: the status item, and `applicationShouldHandleReopen`.

Launch and the in-app menu routes (⌘, for Settings, every module item)
now open the window without activating — the menu routes are already
active, so they lost nothing, and a launch the person performed is
activated by macOS itself while one they did not perform stays put.

**What should change:** the app no longer pulls itself in front when it is
launched or relaunched in the background, and no longer re-takes the front
from another application on its own. **What should NOT change:** clicking
the Dock icon still raises the main window, "Open New Old World" in the
status menu still brings the app forward from whatever you were in, and
Open Mirror still leaves the mirror window in front (`NOWMirrorWindow.show`
still does not activate, precisely because activating trips reopen, which
raises the main window over it). Michelle is the verification step here —
this was not driven, by her direction.

## FIXED: hiding NOW leaves it frontmost, and Windows > Workshop then times out having worked (2026-08-06)

Reported by Michelle from a Mirror drive; measured on a session-private
emulator clone the same night, guest builds `bf4987c6eca1` (before) and
`a14d111103f8` (after).

**What hiding NOW actually does.** `hide "New Old World"` — and the
Application menu's own Hide, which is the same Process Manager call —
hides the window and **does not move the front process**. Measured, three
scenes over six seconds and a QMP screendump of the same moment:

- `apps[].front` stays `New Old World`;
- `axsnap` agrees: `front: New Old World, front: true`;
- the machine still draws NOW's menu bar (Apple, File, Edit, View,
  Windows, Help, and the New Old World application menu), over a desktop
  with no NOW window on it;
- the scene's window row for it is `visible:false, front:false`, so the
  scene has **no front window at all** and the content plane says
  `content: no front window`.

**Why Windows > Workshop then timed out.** The menu item is still
reachable in that state, and `menuact 140/1` still dispatches through the
application's own main-loop queue — but `workshop_open` only called
`SelectWindow`, and selecting a hidden application's window shows
nothing. Watched: four scenes over twelve seconds, the window
`visible:false, front:false` throughout. The host had planned
`windowFront(New Old World)` from `MirrorActionExecutor.presentOrCreated`,
which that state can never satisfy, so the act burned its whole 15 s
timeout **having been dispatched correctly** — and the mutation FIFO is
one lane, so everything behind it waited too. Same shape as the
Finder-open entry below, different cause.

**The fix** is `now_proc_show_self()` in `workshop_open`: show this
application before selecting the window. Every route that promises a
Workshop page comes through there. Watched pass: hidden, then the same
`menuact 140/1`, and the window was visible and front **5.6 s** later,
with the Workshop drawn on the machine's own screen.

**What was NOT settled: the menu bar reported empty after the first
Hide.** In the same report Michelle saw NOW's menu bar render EMPTY in
the Mirror after the first hide, restored by cycling to the Finder and
back. That could not be reproduced from the wire. In every hidden-and-
front state produced here the guest reported `menubar.app: New Old
World` with all seven menus and `coverage menubar/…/complete`, the
machine drew them, and feeding those exact IR documents through the
host's own `MirrorScene.decode` + `MirrorReplicaReducer` kept the menu
bar with `actionable: true`. So neither the guest's report nor the host's
retention is dropping it in that state.

**The plane-bind hypothesis is DISPROVEN** (2026-08-06, second pass). It
was worth testing because `axsnap` does report `bind: no-plane,
hasMenus: false` with NOW freshly front and `bind: ok, hasMenus: true`
a few seconds later — so there IS an unarmed window, and "empty until you
cycle away and back" is what one would look like. It reads `axsnap` and a
scene at the SAME moment, 28 paired samples across the four phases the
report names — fresh connection, the first hide, away to the Finder, back
to NOW:

| phase | axsnap bind | scene menubar |
|---|---|---|
| fresh, first pass | `no-plane`, `hasMenus: false` | **New Old World, 7 menus, coverage complete** |
| fresh, passes 2-8 | `ok` | New Old World, 7 menus |
| the first hide, 10 passes over 32 s | `ok` | New Old World, 7 menus |
| the Finder, 4 passes | `ok` | Finder, 8 menus |
| back to NOW, 6 passes | `ok` | New Old World, 7 menus |

The unarmed pass is real and it lasts about three seconds — and **the
scene taken in that exact moment still carries the whole menu bar**. That
is the shape of the thing: `scene_self.c` reads the live `MenuList`
through the Toolbox from inside our own process, and the anchor bind is
the FOREIGN memory reader. They are not the same source and the self path
does not wait for the plane.

**And the RENDERER is cleared too, offscreen** (third pass). `RenderShot`
rasterises the same `SceneRenderer` the Mirror's window uses, with no
screen involved, so the last stretch could be tested after all. The two
live documents are now fixtures —
`now-host/Tests/HostTests/Fixtures/now-scene-self-hidden-but-front.json`
and `…-front-visible.json`, captured three seconds either side of a hide
on guest build `bf4987c6eca1` — and `MirrorMenubarRenderTests` renders
them and counts the ink in the menu-title band:

| document | ink in the title band |
|---|---|
| hidden-but-front (her exact state) | **705** |
| front and visible | **705** |
| the same document with `menubar` stripped, as the negative control | **77** |

So the renderer draws all seven titles for the document she was looking
at. The 77 is worth knowing on its own: it is the Apple glyph
`shouldSynthesizeAppleMenu` falls back to when a scene carries no menus
at all — **a Mirror bar showing an apple and nothing else is exactly what
"the menu is empty" looks like**, which says the scene the window was
drawing had no menubar even though the one that arrived did.

**What is left, and what would tell them apart.** Every static stage is
now cleared by a test, so the remaining candidates are all live state in
the running app, and none of them is worth guessing between:

- **The window was drawing an older projection than the document that had
  just arrived.** `NOWMirrorSource.scene` is
  `shadowEngine?.snapshot?.scene ?? decoded`, so a projection that had not
  taken the new observation would be drawn instead of it.
- **A plane toggle.** `planePolicyDidChange` republishes from the engine's
  snapshot; a scene projected under a different plane policy is a
  different scene.
- **Nothing retained yet.** `reduceMenubar` retains a previous record when
  no menubar claim is complete — retention can only KEEP a bar, never
  empty one, unless the first scene of that Mirror session had none.

The instrument that separates them already existed and **said nothing**:
`MirrorEngineDiagnostics` compares the visible scene against the engine's
projection on every cycle and names the disagreeing field — including
`menubar` — into a 64-entry ring that was never logged, never shown in
the Diagnostics pane and never exported, so its answer died with the
process. It now writes each difference to `HostLog` (`mirror` area, warn
level), which means the NEXT reproduction leaves a line in
`~/Library/Logs/` saying whether the projection and the arriving document
disagreed about the menu bar at that second — the first candidate
confirmed or eliminated without anyone watching. If that line is absent
while the bar is empty, the projection matched and the third candidate is
the one to chase.

Her two details both point the same way and are worth carrying: it is the
FIRST hide after launch and it self-heals on an application cycle, so it
is transitional rather than steady — and a cycle is exactly what forces a
fresh projection.

## Set Time Zone: the acts reach the modal and apply; the LIST is what is missing (2026-08-06)

Michelle: "controls in some of these modals still dont work". Measured
against Date & Time's Set Time Zone modal on the same clone, replies read
rather than fired and forgotten:

1. **The act reaches the guest and applies.** `ditemact` on the modal's
   Cancel — `{element: now-element-…, item: 2}` — answered `Dispatch:
   dispatched, Mechanism: the application's Dialog Manager path`, and the
   next scene and screendump showed the modal *and* Date & Time gone. A
   `ModalDialog` loop is therefore not the obstacle, and modal-vs-ordinary
   is not the discriminator.
   The refusal worth knowing: `ditemact` needs **both** `element` and
   `item`. With `element` alone it answers `bad-request: ditemact requires
   item: a 1-based DITL number from 1 through 96`, and a caller that does
   not read the reply sees a control that "does nothing". The host sends
   both (`NOWMirrorSource.swift`, `.dialogItem`).
2. **The list is not addressable at all.** The scene carries the modal's
   9 DITL items and 10 controls, including the list's scroll bar with
   `max: 193` — 193 cities — and **no `listCells` and no
   `listTotalCount` anywhere**. There is no row to name, so no click on
   that hatched rectangle can hit one. This is row 1 of
   docs/mirror-element-coverage.md, now confirmed live rather than
   inferred.
3. **The greyed Done is TRUTH; the default ring on it is not.** With the
   modal front the guest reports item 1 `Done enabled:false` and item 2
   `Cancel enabled:true`, and the machine's own screen agrees — Done is
   greyed until a city is chosen, and the default ring is around
   **Cancel**. So the grey is a correct report and the ring is a renderer
   fidelity defect.
   (With the modal's application in the BACKGROUND every item reports
   `enabled:false`, which is also true of the machine.)
4. **The truncated explanatory text is the renderer, not the content.**
   The guest reports item 7's title complete: "The time zone must be set
   to determine the correct time. Select the closest city in your current
   time zone:" — 110 characters, in a rect three lines tall.
   `SceneRenderer`'s `case "staticText"` draws it with one `appText` call
   at one baseline and no wrapping, so it is clipped mid-sentence. A wrap
   there is verifiable offscreen with the `RenderShot` harness the
   MirrorKitUI tests already use; it has not been done.

## CLOSED: the resident channel dials, speaks, and holds the session through a 108-second starvation (2026-08-06)

Plan 012 § 4, and the whole plane it completes. A real Macintosh now
opens a SECOND connection from its optional resident component and keeps
it alive while every application on the machine is starved.

**What was watched, on a fresh cold-booted OS 9 clone (mac99, guest
build `4fe6d946e1a0`).** Two connections arrived from the same address a
second apart:

```
[session]  {"type":"hello","contract":2,"side":"guest",...,
            "name":"Power Mac G4","os":"9"}
[resident] {"type":"hello","contract":2,"side":"guest",
            "role":"resident","version":"0.1",
            "name":"Power Mac G4","os":"9"}
```

The `name` and `os` are **identical**, and that is the load-bearing part
rather than a nicety: the host associates a resident channel with its
application by fingerprinting exactly those two fields plus the address,
so a resident that invented its own name would be a channel vouching for
nobody. `capabilities: 127` — both P6 bits, the vehicle and the channel.

Then `tools/guest-wedge spin 110`, with `tools/liveness-channel.py`
timestamping both connections:

| what | measured |
|---|---|
| the application, starved | **108.8 s** with no answer, past the host's 75 s window and past the 90 s Finder incident that started this |
| the resident, meanwhile | **three pings**, at 86.6 s / 121.6 s / 156.6 s, every one answered |
| either connection dropped | **no** |

So the premise the plane rests on is no longer an argument from the
scheduling model at either end. Something answering below the
application kept ANSWERING ON THE WIRE while applications could not.

**Then the same thing against the REAL host**, which is what § 4 was for
and the first time either half of § 1 had met a real guest. An
application starved 110 s kept its session — the same two sockets before
and after, `55223` and `55224`.

**And the mutation was watched to fail.** A build whose application never
publishes the endpoint, cold-booted the same way, opened ONE connection
instead of two; the identical 110-second wedge replaced its session
(`56005` → `56063`). So the survival above is the resident doing it, and
not the host having quietly stopped timing anybody out. This also fixes
the honest limit of the guest-side fix below: it stops the guest tearing
its own link down, and it does not keep a session that nothing is
answering for.

**How it is built, and the one decision worth arguing with.** MacTCP's
`.IPP` driver through the Device Manager — `PBOpen` and `PBControl` are
traps, so a flat 68K code resource needs no library, which is what
killed Open Transport at the linker. **No completion routines.** The
plan expected register-based callbacks each needing `now_liveness_tm.S`'s
shim treatment; they buy nothing here. This component already has a
periodic interrupt-time context, the channel's entire job is one frame
every thirty seconds, `ioResult` is the same fact the callback would
carry read from memory instead — and the ABI is genuinely ambiguous for
these callbacks in a way Timer.h's was not (`MacTCP.h` declares a
STACK-based completion; the Device Manager documents A0/D0). Guessing
wrong there costs a five-second corruption of somebody else's memory,
which is exactly what disarmed the vehicle for a day. The full argument
is in `ext/src/now_liveness_net.c`'s header.

**What this does NOT close.** The channel has been watched on an emulated
G4 only. MacTCP on a real PowerBook under OS 9 is not OT's MacTCP
compatibility on an emulator, and nothing has run on 68K/System 7.1 at
all, where the extension is the same INIT but the stack is real MacTCP.
Metal is attended and Michelle's call.

## FIXED, and found only by driving the real host: the GUEST killed the very session the resident was holding open (2026-08-06)

The entry above nearly read the other way. The first end-to-end run
against the real host — resident channel up, host correctly holding the
session — **still lost the session**, and both connections were replaced
within 150 s of the wedge.

`now-guest-ppc/src/core/wire.c :: service_heartbeat` compared
`last_rx_tick` against a 65-second dead-link window. When the event loop
next ran after the 110-second starvation it saw a 110-second gap and
declared the link dead: *"Reconnecting (no answer)"*. **Nothing had been
silent.** The application was not running to listen, and then blamed the
far side for it.

It is the same defect as the host's, from the other end, and the guest's
version is the plainer one: the host at least observed real silence and
had to be told a machine might be alive behind it.

The cure is the same shape. A gap between two consecutive passes of our
own event loop longer than ten seconds is PROOF of starvation rather
than evidence of it, so the interval is forgiven — the dead-link clock
advances past it instead of counting it, which keeps a genuinely dead
link noticed one window later rather than never. A healthy pass is
milliseconds, and the pump runs from every nested Toolbox loop
(`pump.h`), so nothing legitimate lands between one second and ten.

**It deliberately needs no extension.** `liveness_ticks` says the same
thing more precisely and an application that has one could read it, but
"keeps its session through a modal" must not be a thing only some
machines do — the product degrades honestly without a resident component
(docs/resident-components.md).

### The instrument was feeding the clock it was measuring

Worth more than the fix. The **same** 108-second starvation measured
through `tools/liveness-channel.py` did **not** drop the link, twice, and
that is why this survived a whole afternoon of green runs.

That instrument polls the session with `mirror` every five seconds. The
requests piled up in the socket while the guest was starved; when it came
back it read all twenty-two of them before `service_heartbeat` ran, and
`last_rx_tick` was refreshed on the way past. **The probe supplied the
traffic whose absence was the thing under test.**

Same class as `probe-oracles-were-blind` and the `hello`-probe trap in
`tools/wedge-experiment.py`, and the general form is worth stating: an
instrument that talks to the subject on the channel it is measuring is
not a passive observer of that channel. The real host, which pings
nothing by contract, was the only observer quiet enough to see it.

## The folding sidebar, both halves (2026-08-05)

The rail folds to icons on the guest and the sidebar does the same on the
host, both with tooltips on the folded icons, and the host gained the
guest's other two choices (density, rearrange).

**Guest: emulator-verified.** Folds and unfolds, the icons and the
Connection lamp draw, the hand-drawn help tag appears over a Data
Browser and the Browser repaints clean when it goes. A true fresh
install - prefs file deleted - starts expanded with rich rows, which is
the default that matters.

One note on reading a shared VM, because it cost a paragraph of wrong
suspicion: a first launch appeared to open COLLAPSED, and the cause was
the human clicking the collapse button in the seconds between the launch
and the screendump. The evidence was all there and pointed the right way
once anyone thought to ask - nothing writes that prefs file at launch,
only a quit or a toggle does, and its created and modified stamps were
seconds apart and dated that day rather than inherited from the base
image. **When a VM has a display, a person may be using it**, and a
screendump is a sample of a machine somebody else is also touching, not
a readout of what the code did.

**Host: confirmed working by the human at the desk**, not by me: screen
access was declined, so I have never seen it. `swift test` and the Xcode
target in both configurations are all I can speak to directly.

Open, and worth knowing:

- **Carbon help tags do not display under Mac OS 9.** This toolchain's
  MacHelp.h carries only the help-tag API (`HMSetControlHelpContent`,
  `HMDisplayTag`) - classic `HMShowBalloon` is not in these headers at
  all - and help tags are a Mac OS X facility. The guest's tooltip is
  therefore drawn by hand. Anyone reaching for the Help Manager on this
  target should expect a feature that compiles, links, and shows nothing.
- **The guest's tag is armed from idle**, which runs unslept during a
  transfer. It is one `GetMouse` and two comparisons per pass and draws
  only on a change, but it has not been watched during a large transfer,
  which is the condition that has caught every other idle-path mistake
  in this window.

## The rearrangeable sidebar: emulator-verified, never on metal (2026-08-04)

The rail gained four things in one arc — a scroll bar that appears only
on overflow, Option-drag reordering, a compact density, and a
Preferences page. **Emulator-verified** the same day (OS 9.1 under
QEMU, a private `--instance 7` clone off the runner-ready snapshot, the
build pushed over the harness's own `put` channel):

- the page renders and the pinned group draws with its new sliders icon;
- **compact** fits all eleven nav rows plus the pinned three at the
  standard window size, keeps the icons, and correctly gives the
  Connection row its STATE rather than its title as its single line;
- **Option-drag** arms, draws its XOR insertion line, tracks the
  pointer, erases the line cleanly on drop, and moved Chat from the
  foot of the list to just below MCP;
- the **scroll bar** appears when the window is dragged down toward the
  minimum in rich density, spans exactly the nav rows, stops above the
  divider, narrows the rows to make room, and scrolls by one on its
  arrow;
- all of it **survives a quit and relaunch** — saved order, density and
  window rectangle — and **Reset Order** puts the enum order back.

That is the level below metal and it settles the drawing. What it does
NOT settle, and what to watch for on the PowerBook:

- **The drag against a real hand.** The emulator was driven with
  synthesised relative motion in 3-pixel steps. A fast human drag is
  the case where XOR feedback smears, and no synthetic mouse will show
  that.
- **Compact baselines under a different system font.** 18-pixel rows
  with a hard-coded baseline of 13 — arithmetic, not a metrics query.
  The emulator runs the same fonts the PowerBook does, so this is
  likely fine and is listed because "likely" is not "watched".
- **The prefs v19 migration from a file written by an OLDER build.**
  What was exercised was v19 writing and reading its own record. The
  remap that matters (Connection 13 -> 14, Logs 12 -> 13) needs a prefs
  file from before this arc, which the throwaway VM did not have. This
  is the fifth time that remap has been written and the ordering trap —
  remap Connection first — has been the bug at least once.

**A control created at an empty rectangle may never render (2026-08-05).**
Worth knowing beyond this file. The rail's bar is created once and
Show/Hidden, and the layout reports an EMPTY nav_scroll while everything
fits — an honest description of "no bar", and a fine creation rect for
`scrollBarProc`, which drew correctly after a later `SizeControl`.
`kControlScrollBarLiveProc` does not: born 0x0, it stayed invisible no
matter how it was resized. The tell was that the bar appeared when the
app opened INTO a small window and not when the same window was dragged
down to the same size — two paths to identical geometry, one working.
Create controls at a real rectangle and let Show/Hide carry visibility.

Two things are known limitations rather than suspicions:

- **The drag does not scroll the list under itself.** Rearranging a row
  past the visible edge of a scrolled rail means dropping, scrolling,
  and dragging again. It only bites at rich density in a minimum-size
  window, which is also the only configuration that scrolls at all.
- **The Edit menu holds Preferences and nothing else.** Cut/Copy/Paste
  are absent rather than greyed, because this window has no keyboard
  focus machinery and the TextEdit fields on Chat and Console each own
  their own `TEHandle` — there is no "the focused field" for an Edit
  command to act on. Wiring them needs a new module op handing the
  Workshop the page's current `TEHandle`. That is the same missing seam
  as the dead `GetKeyboardFocus` gates noted below.

## The chat.* family: metal-proven end to end; edges still open (2026-08-02)

Four rounds on the real desk moved most of the 2026-08-02 unknowns to
answered. **Metal-verified**: the Anthropic subscription sign-in
(paste-back OAuth, the Claude-Code-shaped request gate), oMLX serving
(after the no-blank-line SSE finding), the guest Chat page drawing,
streaming and tool use against a real guest — a model paged this
PowerBook's software and tried to launch a game over the wire.
**Emulator-verified** (2026-08-02, restricted VM): the TextEdit prompt
types, edits and refuses correctly; the page renders with both popups.
Still open:

- **The redraw pass is emulator-still-frame verified only.** Per-row
  transcript damage and TE's incremental drawing are built exactly to
  kill the flicker metal showed, but flicker is a motion claim: a human
  watching a streamed answer on the real screen is the proof.
- **Ollama and LM Studio probes have still never seen a live runtime**
  (oMLX has; the other two remain scripted-transport claims).
- **OpenAI (the hosted service) has never been reached** — key entry,
  models list and a streamed turn are all unproven.
- **The turn ceiling raise (12 -> 40) and the launch guidance are
  untested against the errand that hit them** — re-run the
  find-and-launch-a-game prompt.
- **`chat hi` from the host console** (exec plane -> guest `chat` verb)
  still has not run against a booted guest.
- **Keyboard focus is dead application-wide** (no root control, on
  purpose): the three Data Browser pages gate arrows on
  `GetKeyboardFocus` and so have never taken a key. Spun off as its own
  task; docs/guest-ui-start-here.md carries the rule.
## CLOSED: the liveness vehicle runs, and it runs while applications do not (2026-08-05, later)

The entry below is **fixed**, and it is left standing because the wrong
diagnosis in it is the more useful half.

**The cause was the callback ABI, not A5.** `TimerProcPtr` is declared
`CALLBACK_API_REGISTER68K`, which on classic 68K collapses to a function
of *no arguments* — the header says so in its own words — and Timer.h's
procinfo (`0x0000B802`) spells out a register-based call taking four
bytes in **A1**. `now_liveness.c` wrote the tick as
`pascal void tick(TMTaskPtr)`, so the compiled function read a stack
argument belonging to whatever it had interrupted. Nothing rescued it in
between: on classic 68K `NewRoutineDescriptor` is a no-op macro returning
its ProcPtr, so `NewTimerProc` handed the Time Manager that C entry point
bare. The fix is `ext/src/now_liveness_tm.S` — the shim `now_ext_gne.S`
already was, for the same reason and in the same shape.

**One defect explained both symptoms, which is why it is the answer.** A
task whose record pointer is garbage re-primes a garbage queue element,
so it fires once and stops — the first build exactly. Move the counter
into the record and that same garbage pointer becomes a five-second write
into somebody else's memory during boot — the second build exactly. A
two-defect story was not needed.

**The A5 lesson recorded below is WRONG for this component**, and that is
worth more than the fix. Retro68 does not address this extension's
globals through A5: `_start` calls `RETRO68_RELOCATE` and never frees
them, so the flat blob's statics sit at fixed system-heap addresses. The
tree already proved it before anyone theorised otherwise — `now_ext_gne.S`
reaches `gNowExtOldGNEFilter` with an **absolute** load from inside every
application's context, and the anchor plane's `gLastA5` fast path works
across processes. Both would be luck if the A5 story held. The wrong
answer is left in the source comment because it was a plausible one and
the next person will reach for it too.

**Measured on a fresh cold-booted clone**, three results:

- **The guest boots normally.** `capabilities: 63` — bit 5 (32) is the
  vehicle — with Finder, anchor worker and NOW all up.
- **The counter keeps the stated cadence.** Two reads 232.5 s apart by
  the guest's own tick count: `livenessTicks` +46, and 46 × 5 s is 230 s.
- **It keeps climbing through a starvation that stops applications.**
  Under `tools/guest-wedge spin 25`, `tbt-worker` — a background-only
  application on its own TCP port with no code in common with NOW — could
  not be reached for 25 consecutive seconds, and `livenessTicks` gained 5
  over 26 s, the undisturbed rate.

So **012 § 3's deliverable is met**: the premise the whole liveness plane
rests on is no longer an argument from the cooperative scheduling model.
The instrument is `tools/liveness-experiment.py`, and its INCONCLUSIVE
verdict — the failure that most looks like success — was watched to fire
by forcing the probe to report the worker always alive.

**Two of § 5's recorded measurements did NOT reproduce here, and are
flagged rather than resolved.** § 5 records that a spin wedge left `hello`
answering while `stat` died, and that `modal` starved nothing over 71 s.
On this clone, under a spin wedge **`hello` went silent too**, and
**`modal` starved the full 25 s**. The second has a reading available from
the source — `ModalUntil` pumps with `GetNextEvent`, not `WaitNextEvent`,
and background processes get time from the latter — but that is a
hypothesis, not a finding, and the two runs differ in more than one way.
Nothing here depends on either: this result is *stronger* if the worker
was silent at every level, because the resident ticked through it anyway.
Whoever needs § 5's table should re-measure it before quoting it.

**2026-08-05, independently reproduced.** A second session reached the
same ABI diagnosis from the procinfo word alone and measured the same
result on its own clone: 17 ticks over an 83 s window containing a 25 s
spin starvation — the undisturbed rate; a vehicle frozen through the
wedge would have shown ~12. Two rig lessons from that run, neither
recorded elsewhere: `launch` of a **Desktop Folder** path resets the
worker's connection on this rig and the app never starts (stage into the
`now-dev` folder instead); and a starved guest shows as a **long gap
between successful probe replies, not as refusals** — QEMU's user-net
proxy accepts and buffers, so an untimestamped probe timeline reads
"alive" straight through a starvation.

## BROKEN and DISARMED: the liveness vehicle hangs the guest at boot (2026-08-05) — FIXED, see above

012 § 3's Time Manager task — the extension's first interrupt-time
context — **is in the tree and does not install.** The `return` that
disarms it is deliberate and is explained where it sits.

**Two defects, one behind the other, and only running it found either.**

1. **The first build's tick fired once and stopped.** `livenessTicks`
   read `1` on a guest that had been up for minutes. A Time Manager task
   is entered with an ARBITRARY A5 and Retro68 addresses globals through
   A5, so from interrupt time this component's statics are somebody
   else's memory — reading them is luck, writing them is corruption.
   Fixed by carrying everything the task needs inside the task record,
   which the Time Manager hands back, so no global is touched at all.
2. **With that fixed, the guest never finished booting.** The Finder drew
   an empty menu bar and stopped; the anchor worker never came up; the
   machine was still unreachable five minutes later, and a screendump
   shows a bare desktop. So the first defect had been *masking* the
   second: a task that fires once does not hang a machine, and one that
   fires every five seconds does.

**The cause is not established**, and this entry should not be read as
though it were. Two candidates, both testable and neither tested: the
task may need the same globals-world shim the jGNE filter has in
assembly (`now_ext_gne.S`), or re-arming with `PrimeTime` from inside a
standard Time Manager completion may be wrong here.

**Why it ships disarmed rather than reverted.** An extension that hangs a
Macintosh at startup is the worst thing this component can be — it is
recoverable only by pulling the file from a machine that will not boot.
But the A5 lesson is worth more than the file, and whoever picks this up
should start from a diagnosis rather than a blank page.

**What this costs 012:** § 3's deliverable was *prove the vehicle runs
while applications are starved*, and that is now unproven in the
strongest sense — the vehicle cannot be left running at all. The
`liveness_ticks` counter and its `livenessTicks` report are built and
correct; nothing has yet made them climb.

## UNBLOCKED at the first gate: MacTCP's `.ipp` driver DOES open from the extension (2026-08-05, later)

The entry below stands — Open Transport is still ruled out, and for the
structural reason it gives. What has changed is that its named successor
has been asked, in the same cheap way, and **answered yes**.

On a fresh cold boot the resident opened MacTCP's `.IPP` driver with a
plain `PBOpenSync` and reported `transportProbe: 1` (open),
`transportResult: 0` (noErr). The guest booted normally alongside it —
`capabilities: 63`, lifecycle `active`. So the Device-Manager route is
real from a flat 68K code resource on OS 9: no library, no CFM, nothing
for a linker to refuse.

**What this proves is exactly one thing, and the temptation is to read it
as more.** A driver opened. Nothing has been created, dialled, sent or
received. `TCPCreate` and `TCPActiveOpen` are `PBControl` calls this has
not made, their completion routines are register-based callbacks that
will need their own shim — the lesson the vehicle just charged for — and
whether OT's MacTCP compatibility actually serves a connection to a
resident client is untested. **The first gate is clear; that is all.**

**The probe was watched to report the other answer.** A build asking for
a driver that does not exist (`.NOP`), cold-booted the same way, reported
`transportProbe: 2` (refused) and `transportResult: -43` — the Device
Manager's own `fnfErr`. That mutation is not ceremony: a field reading
"open" unconditionally would be indistinguishable from the result above,
which is the class `probe-oracles-were-blind` names.

## BLOCKED, and the answer came from the LINKER: the extension cannot be an Open Transport client (2026-08-05)

Plan 012 § 4 has the resident dial the host itself, so a starved machine
answers for itself. **It cannot, from this component, and the reason is
structural rather than a matter of effort.**

Linking OT's client glue into `ext/` fails at link time on
`__SLM11FuncDispatch`, `__SLM11VTableDispatch`,
`__SLM11ConstructorDispatch`, `__SLM11ExtblDispatch` and
`__gOTClientRecord`. Those are Shared Library Manager dispatch stubs:
**OT's 68K libraries are CFM/SLM fragments, and the NOW Extension is a
flat 68K code resource** (`-Wl,--mac-flat`). The two linkage models do
not meet. Four library combinations were tried, including the
application flavour (`OpenTransportApp`) and the compatibility library;
the best was fifteen unresolved symbols.

**This is 012 § C's metal question answered at link time** — the risk
was named as "OT 1.x on a PowerBook may not behave as OT 2.x on an
emulated G4", and it turns out not to reach a machine at all. Much the
cheapest place to find it.

**The routes left, none of them a small edit:**

- **Reach TCP through the Device Manager instead.** MacTCP's `.ipp`
  driver is driven with `PBControl` and completion routines, which a flat
  68K INIT can do and which is how resident code did networking before
  OT. OS 9's OT still provides it for exactly these callers. This keeps
  the extension an INIT and is the smallest of the three.
- **Ship the resident as a CFM fragment**, which can link OT properly but
  is a different kind of component with a different install story.
- **Ship it as an OT module**, which is what OT's own layering intends
  for something living below applications, and is the largest change.

**What landed anyway, and why it still matters:** the VEHICLE. The
extension now has its first interrupt-time context (a Time Manager task,
`ext/src/now_liveness.c`) which runs whether or not any application is
being scheduled — the thing every existing context in this component is
not. It bumps `liveness_ticks` in the shared table and nothing else does,
so the premise the whole plane rests on is now checkable rather than
argued: under `tools/guest-wedge spin` an application-level probe stops
answering, and this counter must keep climbing.

## BROKEN: the guest's deafness OUTLIVES the host's liveness window, so an ordinary modal kills the session (2026-08-05, second drive)

**This is the one that makes the other deafness entries conditional**, and
it was found by deliberately reproducing the wedge rather than waiting to
be surprised by it again.

A document with a creator no application owns (`Zz!9`) was pushed to the
guest desktop and opened from the Mirror. The Finder raised its *"Could
not find the application program that created the document named 'wedge
doc'"* alert — reproducible on demand, which is what makes this
measurable at all. Then:

- **The alert deafened EVERY process on the guest**, not merely the
  Finder. `tbt-worker` — a background-only application on its own TCP
  port, sharing nothing with NOW but the machine — stopped answering
  `hello` for **more than 90 seconds**, and refused four posted-click
  attempts across the six minutes after that. NOW went silent for the
  same span.
- **The host's idle timeout is 75 s** (`GuestListener.Timing.idleTimeout`,
  and the host never pings by contract). So the wire died of *"Connection
  lost (no traffic)"* while the Macintosh was perfectly healthy and its
  socket perfectly open.

**One ordinary Macintosh event therefore ends the wire session**, and no
amount of host-side patience is the answer: a modal waits for a person,
so the deafness is unbounded. A larger `idleTimeout` moves the cliff and
makes real death slower to notice; it does not remove the cliff.

**What this falsifies.** The entry below (*"a blocked callee deafens NOW
for 15 s per script"*) proposes short poll deadlines as "the cheapest real
fix". That fix is still right and is still worth doing — it stops NOW
spending fifteen seconds per poll on a blocked callee — but it **cannot
reach this**: our own deadline governs how long WE wait, and this is the
guest being unable to answer anybody at all. 011 § C's done-when (*"a
blocked Finder costs the guest its Finder reads and nothing else — the
wire stays live"*) is unreachable by that mechanism alone, because the
blocked Finder costs a **separate background application** its wire too.

**Where the answer has to live.** Liveness is being answered by the
application, and a modal is precisely what takes the application away. So
the signal must come from **below** it. Two layers can speak while every
application is starved, and both are unproven here:

- **The TCP stack.** A wedged guest's kernel still holds the connection;
  a dead machine's does not. Host-side keepalive would be answered by the
  guest's OT stack with no application involvement, which is exactly the
  distinction the idle timer cannot make. Unverified on OS 9's Open
  Transport, and it must be checked on metal before it is believed —
  MacTCP on the 68K side is a second question again.
- **A resident component.** The NOW Extension runs at interrupt time and
  is not subject to cooperative starvation. This is what
  [resident-components.md](resident-components.md) exists for, and it is
  the larger move.

There is also a third answer that does not try to keep the session alive:
**make a redial cost a reconnect rather than a session.** `GuestKey` is
per dial-in, so the same machine returning gets a new key and the Mirror's
pinned engine, journal and act clocks are all invalidated — which is why
the four acts in flight came back *"the Mirror is pinned to guest-1"*.
Re-pinning across a redial of the same MACHINE would make an unbounded
modal survivable without pretending the wire survived it.

Recorded from the drive whose notes are in `docs/local/`, with QMP
screendumps of the alert and of the machine unchanged after the posted
click.

**2026-08-05, later: this has a slice, and reading the code sharpened it
twice.**
[012, Liveness below the application](plans/2026-08-05-012-feat-liveness-below-the-application-plan.md).
Two corrections to the entry above, both from the source rather than from
reasoning:

- **The keepalive already exists**, and it is guest-driven — the contract
  has the guest send `ping` after 30 s of silence. So nothing needs a new
  liveness message; the starvation stops the application sending the one
  that is already there.
- **The resident cannot currently help.** `ext/src/now_ext.c` installs
  its vehicle at `LMSetGNEFilter`, and the act plane's patches fire on
  trap calls, so **every execution context the extension has is
  application-driven**. During this exact starvation the resident does not
  run either. Liveness therefore needs the extension's first
  interrupt-time context, which is what makes 012 a slice rather than a
  patch.

One thing in this entry is over-stated and is corrected there: the
deafness was **>90 s with recovery**, not indefinite. "A modal waits for a
person, so it is unbounded" was an inference, and `ModalDialog` does call
`GetNextEvent` — so a modal merely sitting may starve nothing. The
suspect is the app-enumeration scan behind that particular alert, and it
is a suspicion, not a finding.

## UNVERIFIED: MCP can see the drawing now, but nobody has read one live (2026-08-05)

`now_mirror_snapshot` claims to carry the renderer's whole input and three
times it has not: `window.items` for desktop icons, `window.items` again
for Finder rows, and `window.display` — the per-window QuickDraw ops. The
third is now projected, along with `kind`, `ref` and `text`, which turned
out to be missing for exactly the same reason. Slice 6's render rule (to
render a custom control, replay its ops rather than classify it) is
reachable from MCP for the first time.

**Status is TESTED, not verified.** 1416 host tests pass and six new ones
cover it, but no snapshot has been read off a real guest with ops in it —
the VM stand-up could not complete a cold boot unattended that day. The
shape is proven; the content is not. What would settle it is one headless
`now_mirror_snapshot` against a guest whose front window is being drawn,
checking that `displayTotal` is non-zero and the ops describe what the
Mirror window is showing.

Three things worth keeping regardless of how that goes:

- **The omission CLASS has a guard now**, not just this instance. A test
  walks `Scene.Window`'s stored properties with
  `IRSchema.declaredProperties` and fails on any the projection has not
  disposed of — carried (proven against a real projection) or declined
  with a reason. Adding a field to the IR and forgetting the projection is
  no longer silent. Watched failing by adding a probe field to
  `Scene.Window`: it named `probeField`.
- **The guard has its own guard.** A roster check that asks whether a key
  exists passes for a field that arrives empty, which is coverage the
  roster does not have — the same shape as a test that stays green for the
  wrong reason. So every carried check also runs against a window whose
  fields are all present and all empty and must fail there. Watched
  failing by weakening one check to `!= nil`.
- **The 64 KB ceiling has no headroom left, and this is the number to
  know.** The item projection ALONE encoded **54.6 KB of 64 KB** in its
  worst case, measured rather than estimated. Any independently-bounded
  addition therefore overflowed the message, and overflow is not a
  truncated reply — it is the writer throwing and the connection closing
  with no reply, so `snapshot` stops answering while `status` still does
  (the same failure this file already records from adding Finder items).
  Item and content families now hold separate stated byte shares of one
  ceiling. **Anything further added to this payload must take a share
  rather than assume room; there is none.**
## BROKEN: a blocked callee deafens NOW for 15 s per script (2026-08-05)

**This is the mechanism behind the dropped connection**, and it is not
about modals — a modal is only the commonest way to get a blocked callee.

The guest is a serial Carbon application. `now_input_run_script` calls
`OSADoScript`, and while that call is inside the OSA component **NOW
pumps nothing**: not the wire, not its own event loop. The file says so
in its own refusal text — *"this guest is serial and could not wait
longer"*.

There is a deadline, and it works: `OSASetActiveProc` installs a proc the
component calls while the script runs, which returns `userCanceledErr`
past the deadline. So a script cannot hang forever. But the deadline is
`kNowScriptDefaultMs = 15000`, and **the host never sends `timeoutMs` at
all** — zero occurrences in `NOWMirrorSource`. So every script to a
blocked application makes the guest deaf for a full fifteen seconds.

Stack a few and the arithmetic is the drive that died: acts queued 48–87
seconds, the host's heartbeat unanswered through all of it, six
operations settling `sessionChanged`, and the guest's socket left CLOSED
while the host still believed it had a guest.

**The Finder is the worst possible application for this**, because NOW
reaches it for the icon roster, `finderOpen`, `finderSelect` and the
visibility census — routine scene maintenance, not just user acts. So a
blocked Finder does not degrade one feature; it deafens the whole guest
on a timer.

**The cheapest real fix is not a new mechanism.** Routine scene-
maintenance reads (icons, census) should carry a SHORT `timeoutMs` — they
are polls, and a poll that cannot answer in a second should give the wire
back rather than hold it for fifteen. A user-initiated act can keep the
long deadline, because a person is waiting for that one on purpose. The
argument already exists on the verb; nobody passes it.

**2026-08-05, later: "the cheapest real fix" is still worth doing and is
no longer sufficient.** Measured by reproducing the wedge: the deafness is
not scoped to NOW's own script call. A Finder modal starved a separate
background application (`tbt-worker`, its own port, no code in common)
for over 90 seconds. A short `timeoutMs` bounds how long WE wait for an
answer; it cannot make a starved machine able to answer. See the new
entry at the top of this page for where the liveness signal has to come
from instead.

## The host's dispatch path has no test seam, and it cost three times today (2026-08-05)

Not a defect in the product; a gap in how the product can be checked, and
it has now been paid for often enough to name.

`NOWMirrorSource.serve` turns a plan into a guest command and sends it
through the listener. Nothing can intercept that command in a test, so
every fix to it is verified one level BELOW where it lives — the helper
that builds a string is tested, and the line that decides which string to
build is not. Three fixes on 2026-08-05 landed with exactly that shape:

- the **Hide host switch**: `hideDispatchOutcome` is tested; that
  `.hide` calls the guest verb at all is not;
- the **`transitions` arg key**: the parse is tested against a real
  envelope, and the agent had to DRIVE A MACHINE to prove the wiring;
- the **Finder `activate` rule**: `finderScript` is tested in both
  shapes, and mutating the call site to pass `activate: true`
  unconditionally left **nine tests green**.

That last one is the clean demonstration, because the mutation reinstates
precisely the defect the change exists to fix and nothing notices.

It also explains a pattern in today's live drives: the defects the
machine found — a refusal that was unparseable, a reply that lost its own
records, a verb that could not arm — were all in this same band, between
a tested helper and a tested projection.

**What would close it** is a seam of the kind `NOWMirrorCycleIO` already
gives the scene cycle: one injectable "send this command" function, so a
test can assert WHICH command a plan produces. That is a small refactor
with a large blast radius on confidence, and it is the highest-value
testing work in this arc.

**2026-08-05, later: CLOSED, and by exactly that.** `GuestCommandSend` is
the injectable door, defaulting to `GuestListener.runCommand` and held by
both `NOWMirrorSource`'s `run`/`readingOutput` and
`AgentIntegrationActControl`'s single wire call.
`MirrorServeSeamTests` drives `perform` through it and reads the composed
command. The mutation named above is the proof it works: `activate:
!ownApp` → `activate: true` now fails exactly the control-panel test and
nothing else, where it used to leave nine tests green.

## BROKEN: one modal wedges the whole Mirror, and the lane turns it into 90 seconds (2026-08-05, from Michelle's drive)

**The most complete failure this arc has recorded, and every link is
evidenced.** It is not one defect; it is three, and the one that matters
most is not the one that started it.

**The chain.** Opening `harness.log` — a document whose creator
application is not on the machine — makes the FINDER raise its "could not
find the application program that created the document" modal. A Finder
inside `ModalDialog` does not service Apple Events, and NOW reaches the
Finder for *everything*: the icon roster, `finderOpen`, `finderSelect`,
the visibility census. So one ordinary Macintosh event stops the Mirror's
entire Finder surface, and nothing on either face can dismiss it.

**The amplifier, measured.** From `acts.log`, queue waits behind the
stuck lane: **48 737, 53 146, 53 821, 63 246, 65 653, 70 923 and 87 508
ms.** One act waited **87.5 seconds**. That is WORSE than the 51.8 s that
made the lane a plan item in the first place, and it happened after the
fix that was supposed to remove most of its fuel.

**Then the session died.** Six operations settled `sessionChanged`, four
more logged `disconnected:` with 48–66 s waits already on them, and the
guest's socket was left `CLOSED` on the host's listening port while the
host still believed it had a guest. The Mirror had to be relaunched, then
believed itself connected and dispatched nothing.

**What this falsifies.** The plan deprioritised the lane amplifier (5c
item 2) on the reasoning that fixing the owner prediction "removes most of
its fuel". That reasoning is wrong, and this is the counter-example: ANY
Finder-blocking event refills the lane instantly, and a modal is a normal
thing for a Macintosh to do. The amplifier is not downstream of item 1 —
it is the thing that converts any single stuck act into a dead session.

**Three defects, in the order they should be fixed.**

1. **The lane must be bounded and cancellable.** A single FIFO whose only
   escape is a 15 s timeout cannot survive one act that blocks. Nothing
   can be cancelled: a person watching a 70 s wait has no way to abandon
   it. This is now the highest-value item in the arc.
2. **A modal must reach the operator.** Rung 4, unchanged since it was
   written, and now with a second door into it. Worth noting from the
   same session: a Dialog Manager button IS clickable through the posted
   click the anchor worker sends — the modal was dismissed that way —
   even though a MENU is not. So the act is reachable; the plumbing is
   not.
3. **A document open needs an honest postcondition.** `harness.log` fell
   into the documented gap: unknown kind, so the prediction falls back to
   a Finder window, which never appears. That did not cause the modal, but
   it is why the act sat in the lane for 70 s instead of failing fast.

**And one thing that worked.** The Finder roster read correctly
throughout this session — desktop icons rendered fine, per the operator.
So the intermittency recorded above is real and this session is a case
where it worked.

**2026-08-05, later: item 1 is done, and the re-measurement is much
better — but it did not test the part that matters most.** The lane is now
bounded and cancellable: an act can be cancelled from the Mirror's status
line and from `now_mirror_drive --gesture cancel`; a timed-out act sheds
everything queued behind it with an attributable refusal; and a failed
cycle that finds the pinned session disconnected ends the lane at once
rather than letting each act spend its own deadline. Driving the same
wedge deliberately: **five acts issued across it answered in 2.1 s
total**, no caller blocked, and the wedged act's own ceiling was 30.3 s
(the guest's 15.3 s script deadline, then the broker's 15 s). No 87.5 s
wait recurred.

**That is consistent with the fixes and is not proof of them.** Nothing
reached the lane *behind* the wedge in that run — the four acts issued
after it were `held` at the observation door, upstream of the broker — so
the shed had nothing to shed. The shed, a cancel of a genuinely in-flight
act, and the dead-guest notice ending a non-empty lane are verified by
unit mutation only.

Item 2 is unchanged and got harder: the posted click that dismissed this
modal on 2026-08-05 was refused four times on the second drive, because
the anchor worker is itself starved by the alert (top entry). Item 3 is
untouched.

## BROKEN: the host face can HIDE and cannot SHOW (2026-08-05)

Found on the breadth-first drive, minutes after Hide started working from
that face. Driving `hide` with no target hides the FRONT application —
and when the front application is NOW itself, its window vanishes and
**nothing on the host face can bring it back**. `showAll` has no route
(the Finder refuses `set visible`), and the `.hide` plan only ever hides.

Recovering it needed the guest's own verb over the wire
(`hide --show "New Old World"`), which means stopping the host to free
the port — a person driving the Mirror cannot do that from the Mirror.
Relaunching the application does NOT unhide it; the launch succeeds and
`visible` stays false.

Measured on the machine: `New Old World front=true visible=false`, with
the desktop icons still on screen because the Finder was untouched.

The asymmetry is the defect, not the hiding. What closes it is a `show`
direction on the same verb the host already calls — `hide --show NAME`
exists and works on the guest today — rather than anything new.

## The Finder roster is INTERMITTENT, not absent (2026-08-05)

Sharpening the `desktopItems` entry above, which reads as though the
Finder-item read never works. On one drive it clearly did: the absent-item
refusal fired — *"the Finder shows no item named No Such Item At All on
the desktop"* — and that guard only speaks when the roster is PUBLISHED,
since an unread container claims nothing. Reads minutes later on the same
guest returned nil again.

So it is not a read that never happens; it is a read that sometimes
happens. That is a different investigation from the one the earlier entry
implies, and a more tractable one: something is racing or expiring rather
than missing. The Finder's own Desktop window publishing `itemTotal: 0`
while icons are on screen is the same symptom from the other side.

## FIRST LIVE ANSWERS from the 2026-08-05 drive: display carries, definition says `system`, desktopItems does not read

Driven against a freshly cold-booted emulated Power Mac G4 with the
resident active (`fc6e0946bde92715`, cap 31), with a real control panel
opened so a FOREIGN window with undetermined controls was in view. Three
queued questions, three answers.

**`window.display` carries content — WATCHED.** Date & Time's window
reports `displayTotal: 173`, NOW's own window `205`. The projection that
landed the same day as TESTED is now watched answering off a live guest.

**`definition` answers, and for this panel the answer is unanimous: all
29 undetermined controls report `system`.** Every one is a standard
Toolbox CDEF out of the System file rather than app-owned drawing. That
is the first live data on slice 6's real question, and it points the same
way the transport finding did: the information was recoverable all along.
For this panel the genuinely-custom population is **zero**.

Read it with three limits. It is ONE panel at ONE moment; the extension
on that image PREDATES the batched-classification fix, so this is the
one-cell transport's behaviour and not the fixed one; and 12 of the 41
items were already `known` from the DITL type byte and never needed a
CDEF at all. The corpus recapture is what turns this into a histogram.

**`desktopItems` still does not read, and it is not the stale image.** It
was nil for the whole 2026-08-05 morning drive, and it is nil here on a
clean cold boot with the resident live and a foreign app frontmost.

> **STILL nil on 2026-08-06**, reconfirmed incidentally rather than
> hunted: two live scene captures taken for the content-plane work
> (guest build `1bff0bd2ca39`, with Date & Time and then Sherlock 2
> frontmost) carry no `desktop` key at all, while the guest's own
> screendump from the same run shows desktop icons and a full Control
> Strip. So this survives the anchor-plane lease fixes and everything
> the content plane gained today — it is a Finder-item read failure in
> P2, not a scene-transport or a composition problem, and the host
> render is correctly drawing what it was told (nothing) rather than
> inventing icons. The
matching symptom from the other side: the Finder's own **Desktop window
is published with `itemTotal: 0`** while seventeen icons are on the
screen. So the Finder-item read fails whole rather than partially, and
slice 5c item 1's control-panel half is still unexercised because of it —
the classifier's positive branch cannot fire against a roster that is
never there.

## FIXED, watched on an emulator (not metal): `transitions start` could not arm, by any route (2026-08-05)

**Found by driving, on the first live run of the verb, and fixed and
re-driven the same day.** While it stood, P5's plane could never publish.

`run_start` read its target with `now_json_find_string(json, "name", ...)`
where `json` is the WHOLE request — and every request envelope carries
`"name"` already, as the verb's own name:

```
{"type":"command.request","id":101,"name":"transitions",
 "args":{"op":"start","serialHi":0,"serialLo":34734082}}
```

First match wins, so the target was always the string `transitions`, which
is never a running process. The by-name route is tried BEFORE the
serial/front/a5 selector, so it short-circuited every other route too.
Proven three ways on a live guest, all answering the same by-NAME refusal:

- no target at all → `no-process` (should have fallen to the selector);
- `serialHi`/`serialLo` naming a real running process → `no-process`;
- `name: "New Old World"`, a real running process → `no-process`.

**The contract already forbade this and the rule was not followed.**
`hide` names its argument `target` and says why in the contract, verbatim:
*"`target` and not `name` — see the arg-key rule in the preamble above."*
`transitions` chose `name` and collided with the envelope.

**The fix.** The arg is `target` (contract first, then both faces). The
parse moved out of `transitions_cmd.c` — where it sat in a static
function above `#include <Carbon.h>`, unreachable to any host compiler —
into `transitions_logic.c`, beside the console line's grammar that was
already there for exactly this reason. The console face never went
through JSON at all, which is why `transitions start Finder` typed at the
machine kept working throughout.

**Swept the class.** All 41 verbs' declared args checked against the
envelope keys (`type`, `id`, `name`, `args`, `line`): `transitions` was
the only collision. `resolvedVia: name` deliberately keeps its word — it
names the resolution MECHANISM, and only a request is scanned flat.

**Why no test caught it, and what now does.** The native test exercised
the logic BELOW the parse, with a `NowTransitionsStartReq` a test had
filled by hand, so the suite was green while the verb could not arm.
`transitions_args_test.c` feeds the parse whole request frames — envelope
and all, because with the args object alone the collision is invisible,
which is precisely how it shipped. `contract_arg_key_source_test.py`
holds all 41 verbs to the rule from the contract itself; two verbs have
now broken it (`launch` on metal, `transitions` on an emulator), so it is
executable rather than prose a third time.

**Re-driven on the live emulated Power Mac G4** (build `c39f3e093af3`,
verified in the guest's own hello before believing anything it said):

```
-> {"type":"command.request","id":103,"name":"transitions",
    "args":{"op":"start","target":"New Old World"}}
<- {"cmd":"start","a5":"0x1f21cb60","resolvedVia":"name",
    "process":"New Old World","expiry":116845,"now":113245,
    "requested":true,"armed":false}
```

Then `activity.passes` moved — 1071, then 5572, then 9005 — which is the
resident's own word that it ran INSIDE the armed process and agreed.
**The ring's reader and writer have now met on a machine.**

## FIXED, watched on an emulator (not metal): a `transitions drain` reply lost its own records (2026-08-05)

**Found on this plane's first ever drain**, immediately after the fix
above made a drain possible at all. The reply carried the records AND
threw them away:

```
{"cmd":"drain","records":[ …22 real records, 2853 bytes… ],
 "cursor":0,"nextCursor":22,"records":22,"lost":0,…}
```

`records` twice in one object — the array, then the count in the tail. A
duplicate key is **legal JSON and silently lossy**: every conforming
parser keeps one and drops the other, with no error anywhere. Python kept
the integer. So `transitions drain` looked like it returned a count and
no data, while the records were on the wire the whole time.

It is the arg-key rule in the REPLY direction — a key stated twice is a
key lost. `qdtrace` names its array `ops` and its count `records` and
never met this; this verb named both the same word.

**The fix** renames the tail count to `count`, declared in the contract
beside the array. `transitions_reply_source_test.py` reads every reply in
`transitions_cmd.c` and fails on any key stated twice in one object —
source text because `run_drain` assembles one object across two
`snprintf`s above `<Carbon.h>`, the same reason
`GuestWireConformanceTests` asks for a fixture there.

Re-driven after restaging; a standard parser now reads both:

```
{"cmd":"drain","records":[{"ticks":113305,"seq":1,"kind":4,
 "kindName":"heartbeat","a5":"0x1f21cb60","value":"0x1ecfd8d0",
 "previous":"0x1ecfd8d0"}, …],"cursor":0,"nextCursor":4,"count":4,
 "lost":0,"dropped":0,"pending":74,"writeCursor":74,"more":true}
```

## UNVERIFIED: no non-heartbeat transition has ever been recorded (2026-08-05)

The plane is proven to produce, but everything it has produced is `kind 4
heartbeat` — the resident's one-a-second pulse on a quiet machine. **No
`windowList`, `frontProcess` or `menuList` record has been observed on
any machine**, so the three kinds that are the point of the plane are
still unexercised end to end.

One attempt, recorded because the failure is informative rather than a
defect. With NOW armed, the front process was switched to the Finder and
back over the wire. The drain shows heartbeats either side and **a gap
where the switch was** — seq 125 at tick 141725, seq 126 at tick 141915,
190 ticks (~3 s) apart against a 60-tick cadence. NOW was backgrounded
and got no time, so from the armed process's own event passes the front
process never appeared to change. That is exactly the sampler limitation
`contract/event_tail.h` states — "something raised and dismissed between
two event passes is STILL missed" — observed for the first time.

**What would test it properly:** arm a process that keeps pumping while
another comes and goes — the Finder is the obvious one. That attempt
refused `anchor-plane-absent`: the anchor plane captures an anchor only
when the target pumps while the plane is claimed, and the sequence for
getting a FOREIGN process anchored before arming it is not established
here. Arming NOW itself works because it is the process doing the
arming.

**A rig note worth keeping.** Driving stopped when the human's own host
app took port 5271 (`lsof -nP -iTCP:5271` showed `New Old World` PID
29286 holding the listener with the guest connected to it). Everything
above was measured before that, and every reply quoted carried build
`c39f3e093af3`. This is the collision AGENTS.md warns about, met in
practice.

## FIXED, watched: a `transitions` refusal was unparseable JSON (2026-08-05)

Also found on that first live run, and fixed and re-driven the same
session. `transitions start` refused `no-process`, whose message reads
`nothing by that name is running (see "ps")` — and `error_json`
interpolated it into `"message":"%s"` **unescaped**, so every client got a
JSON parse error at column 124 instead of the reason. The refusal was
correct and unreadable, which is the worse half of the two.

It is on an ERROR path, which is where a missing escape is least likely to
be exercised and most likely to matter — a caller meeting it is already in
trouble. `qdtrace_json.c` does it correctly with `now_json_escape` and
this file simply did not copy it. Swept the siblings: `hide`, `quit` and
`front` carry the same quote-bearing sentence and DO escape it, confirmed
on the same live machine, so this was one emitter and not a class.

Verified by rebuilding, restaging onto the running guest and re-driving:
the refusal now parses.

## MEASURED: the batched classifier is cold-loaded and the numbers have not moved (2026-08-05)

The entry above says the transport rebuild is "fixed in code and none of
the fix has run on a Macintosh", and that **nothing has been cold-loaded
and no panel reclassified**. Half of that is now closed and the other
half is the finding.

**Cold-loaded: yes.** `scripts/spin-up-ppc` staged `NowExt` at 69 716
bytes (against 67 741 for the previous build) and cold-booted; the
resident came up `lifecycle: active`, `cap 31`, build fingerprint
`f172318dda79798d9025a2e37e310cabd75c10d9`.

**Reclassified: no. Date & Time reads exactly as it did before.**

| window | items | `knowledge: known` | kinds determined | `definition` |
|---|---|---|---|---|
| Date & Time (foreign) | 41 | **12** | 12 | `system` × 29 |
| NOW's own Workshop | 53 | **53** | 53 | — |

Identical to the pre-batching reading of the same panel: 29 unknown, 12
known, and all 29 undetermined ones reporting `system`. So the batched
transport is resident and the classification count is unchanged.

**Two things that disagree, informatively.** `definition` says those 29
are standard CDEFs loaded from the System file. `kind` says it cannot
determine what they are. If they really are stock Toolbox controls then
`kControlKindTag` should name them — so either the host never asks for
the batch, or it asks and the resident does not answer. That is the next
question, and it is a narrow one.

**And the inverse pair is worth putting beside it**, because together
they say the two mechanisms fail on opposite populations:

- **kinds**: NOW observing itself 53/53; a foreign panel 12/41.
- **refs**: NOW observing itself 0/53; a foreign panel 41/41.

Whatever is wrong is about the boundary between NOW and a process it does
not own, in both directions at once.

## UNVERIFIED: the classifier's transport was rebuilt; nothing has watched it classify a real panel (2026-08-05)

**The three transport defects below are fixed in code and none of the fix
has run on a Macintosh.** P2 gained a second cell for batched control
classification: one request now types a whole window instead of one
control per scene, each record naming the exact `ControlRef` it
describes. The priorities were inverted — a class fact is the
prerequisite for a list request and now outranks it — and the front-only
gate became a front-first priority, so background panels can be filled in
at all. `contract/peek_table.h`, `ext/src/now_semantic{,_logic}.c`,
`now-guest-shared/src/now_semantic_guard.c`,
`now-guest-ppc/src/peek/semantic_{client,policy}.c`.

What is proven: `scripts/test-all` is green — 111 native tests, all three
cross-builds (PPC guest, 68K guest, **and the 68K flat INIT**), and the
host gate. The extension links the batch resolver: `now_semantic_batch_
apply/resolve/ready/verdict` all appear in `NowExt.map`, and appending a
deliberate error to `ext/src/now_semantic.c` was watched fail the build,
so that gate genuinely covers the resident code.

Five properties were watched fail under mutation — the resolver's
one-walk-per-reply cost argument, the guard's refusal of a reply naming
one control twice, the policy's join-by-named-control, the drained-window
suppression, and the priority ordering. That last one caught a real
error: the first draft had the ordering inverted and the source guard
passed, because the assertion encoded the same mistake as the constants.

What is not proven, and is the whole point of the change:

- **No panel has been classified.** The measurement that motivated this
  (1 of 122 controls determined) has not been retaken. Until the corpus
  is recaptured against a rebuilt extension that has been cold-loaded,
  the claim that this fixes the starvation is a design argument that
  compiles.
- **Nothing has been cold-loaded or run.** A built INIT is not a serving
  INIT; `docs/p2-semantic-evidence.md` records that the previous P2
  checkpoint passed every gate and then produced no live list cells at
  all on the first cold-load sweep.
- How much of the corpus is *genuinely* custom-drawn remains unknown,
  still bounded by the `UnsupportedCustom` branch — which had been
  exercised 1/122 times precisely because nothing else got a turn.

The next step is a cold-load sweep on a machine with an m68k toolchain:
rebuild the extension, recapture the ten panels, and count determined
kinds. The original measurement below is kept as the baseline that
number will be compared against.

## (fixed, pending verification) BROKEN: the control classifier gets one shot per scene, and 121 controls never got one (2026-08-05)

Slice 6's opening measurement was supposed to size how much of the 190
undetermined corpus items are genuinely custom-drawn. It found something
else: **of 122 Control Manager controls in the ten-panel corpus, exactly
one carries a determined kind** — Monitors' resolution list. All 117
other determined items came from the DITL item-type byte and never
involved a CDEF at all.

The classifier is not missing. `ext/src/now_semantic.c :: classify()`
reads the Appearance Manager's public `kControlKindTag` through
`GetControlData`, inside the target process's own context via the
resident's jGNE patch, and resolves fourteen control families; its
`signature != kControlKindSignatureApple` branch is an authoritative
standard-versus-custom verdict. The plane was armed and serving during
the capture (`capabilities: 15, requested: 7, active: 7` in every
`manifest.json`).

It starved on transport. `contract/peek_table.h` carries a **single**
`NowPeekSemanticCell semantic;` — one request per scene, for one
control. In `now-guest-ppc/src/peek/semantic_client.c`, control
classification is the lowest-priority claimant on that cell
(`offer(10, …ControlClass)` against `offer(20, …ListCells)` and
`offer(30, …SystemMenu)`), and only the front process may spend it.
Date & Time's window carries 21 controls and was front for one scene.

**Why it matters beyond the count:** the Date & Time "radios drawn as
push buttons" red has been read as a knowledge gap that slice 6 would
close by replaying draw ops. It is not. The right fix is a batched or
multi-control request op and a priority that reflects what the answer is
worth — a transport change, not a drawing one. How much is *genuinely*
custom is still unknown, bounded by the `UnsupportedCustom` branch, which
has been exercised 1/122 times.

Recorded in full, with the derivation, in
[the gap ledger](mirror-element-coverage.md#splitting-the-190--row-2-opened-up-2026-08-05).
`docs/open-issues.md` already carried the adjacent symptom under "P4's
plane is intact; the reason named for its silence was wrong" — this is
the second, independent measurement of the same shape.

## UNVERIFIED: `semantic.definition` ships, and its histogram has never been taken (2026-08-05)

The walk now reads `contrlDefProc` (offset 24) and reports which heap the
handle came from — `system`, `application` or `indeterminate` — as
`Scene.Semantics.definition`, IR v2 additive. It is a resident-free
answer to the same standard-versus-custom split, with no per-scene
budget: it classifies every control in one walk.

**Nothing has run it against a Macintosh, or against an emulated guest.**
Status is: PPC cross-build green, `scripts/test-native` 110/110 green
(including the new `axdefproc_test`, watched failing under three separate
mutations), `IRFreezeTests` green and watched failing when the addition
is unrecorded. That is *tested*, not *metal-verified*, and the whole
point of the field is a number nobody has yet obtained.

Two things to check on first live contact, in this order:

1. **How large the `indeterminate` column is.** The classic Control
   Manager keeps a variation code per control. If it rides in this
   field's high byte, the raw longword lands in neither zone and lands
   there. A large `indeterminate` column is evidence about the field's
   layout, not a failed read — and nothing is masked on a guess, because
   a 24-bit mask on a 32-bit-clean machine would manufacture a clean
   histogram out of a real question. `axdefproc_test` pins that case.
2. **Whether `system` and the resident's `kControlKindSignatureApple`
   verdict ever disagree.** They answer the same question by independent
   routes; a disagreement names which one is wrong. There is currently
   one control in the corpus where both could be asked.

## THE STALE-REF REFUSAL NO LONGER HOLDS THE LANE (2026-08-05)

**Fixed, tested, and watched on an emulated guest.** During the first human
drive, `winact` refusals against windows the Mirror was still displaying
held the mutation FIFO for its whole 15 s timeout. Measured in
`~/Library/Logs/NewOldWorld/acts.log`: a close refused at 02:03:47.753
held the lane 15 128 ms, and the next click on the same window waited
8 025 ms behind it. The cause was a substring test — a refusal was
treated as "the effect may have landed" unless its wording contained
"was not sent" — so a refusal the guest raised *before* it armed anything
became non-terminal. The same reading produced a false green: a refused
close was recorded `confirmedAfterRefusal` 3 ms later, settled by a scene
that showed the window absent because a PREVIOUS close had closed it.

Two changes, both host-side. A guest act refusal now carries a typed
`AgentIntegrationProjectionFailure.Reach`, read from whether the guest's
error carries a correlation — the guest registers one only after
`now_act_submit`, so its absence is the machine saying nothing was armed.
And the target is re-read against the newest scene at dispatch time
rather than the displayed one, so a click that waited in the queue while
the window closed is refused here instead of on the machine.

Answered along the way, because the arc began by suspecting it: **window
references do not churn on republish.** The guest interns them
(`now_obs_intern` / `identity_same` excludes only `minted_ticks`), and one
token in the same log confirmed an act fifteen seconds and a dozen scene
generations after it was minted.

### The drive that proved it, and how to run one beside somebody else

Driven headlessly on an emulated Power Mac G4 at 03:09 on 2026-08-05 —
three `close`s at one Finder window, 300 ms apart, which is the incident's
own shape. The third one:

    NOT DISPATCHED: the scene moved on — that window is no longer on the
    machine, so the act was not sent. Read it again.
    NOWBASE act ... outcome=refused depth=2 waited_ms=8596
                    dispatch_ms=12 settle_ms=- total_ms=8608

Twelve milliseconds and no guest round trip, against ~89 ms and a 15 s
lane hold before. And `refused`, terminal: the 02:04 equivalent of this
act was recorded `confirmedAfterRefusal` by a scene that another close
had produced.

**The conservative branch earned its keep in the same run.** The FIRST
close was refused `the target served the request and did not arm` — a
refusal the guest raises after `now_act_submit` registered a correlation,
so this side calls it `unknown` and keeps waiting. It held the lane the
full 15 s… and then settled `confirmedAfterTimeout` at 16 503 ms. The
close had landed. Had the rule been "any refusal is terminal", that act
would have been written off as failed while the window was closing.

**Two hosts on one Mac, without touching each other** (this run shared
the desk with another session's verification host, which owned 5250):

- `NOW_PREFS_SUFFIX=<slug>` gives the second host its own settings and
  guest registry — it already existed for exactly this, see
  `ProductIdentity`. Put the port in that domain:
  `defaults write dev.newoldworld.now.settings.<slug> listenPort -int 5262`.
- The guest dials `10.0.2.2:5250` from saved preferences with
  `auto_connect` on, and QEMU refuses a `guestfwd` on `10.0.2.2` because
  it is the gateway. Move the gateway instead, and the address is free to
  forward:

      TBT_EXTRA_HOSTFWD="net=10.0.2.0/24,host=10.0.2.5,dns=10.0.2.6,\
      guestfwd=tcp:10.0.2.2:5250-tcp:127.0.0.1:5262" tools/launch --instance 91

  The guest's own preferences never change, and its dial cannot reach the
  other host. `guestfwd` connects eagerly at launch, so start the host
  first.
- **The agent socket is the one thing that cannot be shared.** It is
  `<darwin-user-temp>/dev.newoldworld.now-agent-<uid>/host.sock`, one per
  user, and `FileManager.temporaryDirectory` ignores `TMPDIR` on macOS
  even though `tools/now-agent` derives its path from `TMPDIR` and says
  so in a docstring. The second host logs `local agent integration
  unavailable` and runs on without an MCP surface. This drive used a
  build-only patch (an env override, reverted before committing) to move
  it. **A supported override belongs in the product**, and the two sides
  should agree on how the path is computed.

**A second false green, found by the test that closed the first.**
Writing the brokered-path test surfaced the same defect entering by
another door: `AgentIntegrationUnavailable` — "there was nobody to ask" —
said nothing about reach, so an act refused because NO GUEST WAS
CONNECTED was held open and then confirmed by a later scene. Nothing had
been sent. That type now carries a reach too, defaulting to `notSent`,
because every one of its statics means the request never left this host;
the single exception is a guest that vanished mid-act, which is built
from a failure and inherits its `unknown`. Both directions are tested,
and the passthrough was watched to fail.

Still open from this:

- **A refusal AFTER the act plane armed nothing still holds the lane
  15 s.** `the target served the request and did not arm` carries a
  correlation, so this side calls it `unknown` — and in the 03:09 drive
  that was right: the act settled `confirmedAfterTimeout` at 16 503 ms,
  it HAD landed. But the guest can sometimes tell the two apart
  (`kNowActNotArmed` means no patch was installed, so no click can be
  delivered), and it says so only in prose. If that distinction is worth
  the 15 s, it belongs in the contract as a field, not in host
  guesswork over the guest's sentences.
- **A guest mis-attribution, noted not fixed.** `now_act_submit` returns
  `kNowActNoExtension` before it registers a correlation, and
  `act_cmds.c:546` answers that with `reply_registered_status`, which
  attaches the PREVIOUS command's correlation. It is conservative for the
  host rule above — a stale correlation reads as "may have landed", which
  only costs a wait — but it is wrong.
## FIXED, TESTED: an agent-driven act was journalled as a person's when it waited (2026-08-05, test landed 2026-08-05)

An act that arrives while an observation is in flight is deferred and
re-enters `NOWMirrorSource.perform` when the cycle clears — and it used
to do that through the **one-argument overload**, whose `source` defaults
to `.human`. So an MCP act unlucky enough to land mid-cycle was recorded
as a hand-driven one, undoing the earlier attribution fix by a path older
than it. The journal is the only thing that can tell the two faces apart
after the fact.

Measured: a `finderOpen` driven entirely over the agent socket settled
`confirmed` and recorded `source: human`. It was the only record in that
host's journal, so there was nothing to confuse it with.

The argument is passed through, and **the owed regression test is now
here**: `MirrorFaceParityTests.testAnMCPActHeldMidObservationIsStill
RecordedAsMCPs`, with a human twin beside it so it cannot pass by making
every act one face. Watched failing by reverting the argument, and again
by reverting the older executor fix — both name the field.

The earlier attempt could not get a harnessed `NOWMirrorSource` to the
broker at all. What it needed was to leave the content join OPEN: that
is the deferred case, and until the join is released the act is held and
has no record. The cycle harness that does it is shared test support
(`MirrorSourceTestSupport.swift`) rather than private to one file.

## RESOLVED — NOT the cause: the MCP drive path holds an engine (2026-08-05)

The suspicion was that `HostAppState.mirrorSource` hands the drive
service a source whose `shadowEngine` is nil, so every MCP act takes the
direct path and can never settle. **It does not, and it cannot.** Two
independent arguments, both cheap to re-check:

- `shadowEngine` and `pinnedGuestKey` are written together in `start()`
  and cleared together in both of `stop()`'s branches — nowhere else. So
  a nil engine implies a nil pin, and `pinnedActionRefusal()` refuses by
  name whenever the pin is nil, **before** the engine is consulted. On
  the MCP path a nil engine produces a refusal with a sentence, never
  `id: "direct"`. (Before the source has ever started there is no
  published scene either, and the drive is refused
  `now-mirror-snapshot-unavailable` without reaching `perform`.)
- The live evidence refutes it directly, and it was already in this
  file. The act that answered `id: "direct"` settled `confirmed` on a
  typed `windowNamedPresent` postcondition — which a nil engine cannot
  mint — and recorded `source: human`, which only the deferred branch
  produces. One act, both facts, and each says the engine was bound.

**The real cause is the deferred branch**, and it is the third instance
of one defect rather than a new one. A held act returns without
enqueuing, so no broker record exists yet, and `MirrorDriveService`
inferred "no new record" == "took the direct path" — answering
`awaitsObservation: false`, which tells the only face that cannot see the
screen to stop waiting, about an act that was on its way to settling.
All three of the arc's drive-service defects are that same
reconstruction: a refusal read as a dispatch, a held act read as a
direct one, and a record found by resemblance rather than by id.

Fixed by not reconstructing it. `perform` answers
`MirrorPerformDisposition` — `refused` / `brokered(id)` / `held` /
`direct` — and the service reports what it is told. Guarded by
`MirrorDriveServiceTests.testAHeldActIsNotReportedAsTheDirectPath` and,
through a real `NOWMirrorSource` mid-observation,
`MirrorFaceParityTests.testAnActHeldMidObservationIsNotReportedToMCPAs
TheDirectPath`. Both watched failing against the pre-fix reading.

**What this means for the measurements already recorded: nothing needs
re-reading.** The worry was that the headless numbers behind slices 3
and 4 described the direct path rather than the shared one. They did
not — the engine was bound throughout. What was wrong was the REPLY to
the caller, not the path the act took: an act reported `id: "direct"`
still went through `MirrorActionExecutor`, the broker and the typed
postcondition. Slice 3's central claim stands, and it now has a gate
(`MirrorFaceParityTests`) instead of a ceremony.

**Still unverified: none of this has been driven live.** No VM was stood
up for the fix — the cold boot cannot run unattended today. The reply an
agent now gets for a held act (`id: "held"`, `outcome: queued`,
`awaitsObservation: true`) has never been seen by a real MCP client.

## Three rig facts that each read as something else (2026-08-05)

None of these is a defect in NOW; all three cost time because they
present as a hang or as a broken change. The second is now fixed and the
third turned out to have a different cause than the one first written
down here.

- **A worktree is too deep to host a VM.** A UNIX socket path is capped
  at 104 bytes and `now/.claude/worktrees/<branch>/run/<pid>/qmp-ui.sock`
  spends 108. QEMU refuses to start and says so only in
  `run/<pid>/qemu.log`; `spin-up-ppc`'s own output ends after "boot a
  fresh, session-private clone" with no error, which reads as a boot that
  hung. This is the DEFAULT path for every agent, because agents work in
  worktrees. `scripts/spin-up-ppc` now checks and names the cure
  (`NOW_SPIN_RUN=/private/tmp/nowvm-$$`).
- **`spin-up-ppc` could not finish its clean shutdown. FIXED, and the
  route is the Shutdown Manager rather than the Finder.** Rule 1 needs
  the guest to shut ITSELF down before the cold boot an INIT requires,
  and the lab's `tools/shutdown-guest` asks the Finder through an agent's
  `script` verb — which the canonical baked worker does not have. Its
  `hello` lists 24 tools (`put`…`click`, `key`, `type`) and `script` is
  not among them, so the run stopped with "the agent refused the script
  verb" and left the VM up with the extension staged and never loaded:
  every plane then reported `unsupported/gen0` and `needs-restart`, which
  reads as a broken build rather than a boot that never happened.

  NOW now stages its own applet, `tools/guest-shutdown`, whose entire
  body is `ShutDwnPower()` — the Shutdown Manager call the Finder itself
  ends up making, which runs the registered shutdown procedures, flushes
  and unmounts the volumes and asks the power manager to cut power.
  `tools/shutdown-guest.py` quits the front application first (Cmd-Q
  through the worker's `key` verb, the one posted-event route measured
  working) and then launches it through the worker's `launch` verb. It is
  68K because the Shutdown Manager is `CALL_NOT_IN_CARBON` and the
  application's own toolchain cannot compile the call at all.

  Measured: launch to QEMU exit, 6 s. Booting the same qcow2 straight
  afterwards reached the anchor in 42 s with no Disk First Aid modal —
  which is the assertion that matters, because the whole reason not to
  use QMP `quit` is the unclean-volume bit.

  What it does NOT do, by construction, is send quit AppleEvents to
  running applications; the Finder does that before it calls the Shutdown
  Manager and this skips it. That is why the front application is quit
  first, and why this is a rig instrument and not a way to stop a machine
  somebody is using.

  **One failure, and it did not reproduce.** Four shutdowns went in 6 s
  each; a fifth did not go at all, and the worker then timed out on
  `observe`, so the machine was wedged rather than slow. That one had
  been driven through roughly fifteen `actselftest` calls first — each
  claiming and withdrawing the act plane, which is the path the entry
  below says is broken — and the run directory was deleted before a
  screendump could be taken, so there is no evidence and no cause. The
  same tool then shut down a comparable machine (extension resident, NOW
  launched and quit) in 6 s. Recorded because a rig that hangs one time
  in five is worth knowing about even when nothing was learned; if it
  recurs, screendump BEFORE cleaning up.
- **Nothing outside this machine can reach its human interface, and the
  reason is not ADB.** The earlier entry blamed an ADB mouse; `info
  qtree` says `has-adb = false` on both `macio-newworld` and `via-pmu`,
  so mac99,via=pmu here has no ADB keyboard, no ADB mouse and no ADB
  power key at all. Every input device is USB: the machine's own
  `usb-kbd` and `usb-mouse` (enumerated, addresses 0.23 and 0.24) plus a
  second `usb-kbd` that `-device usb-kbd` puts behind a hub, which OS 9
  never enumerates — both it and its hub still sit at address 0.0.

  Three separate measurements, none of them a route in:

  * **QMP keyboard input never arrives.** Not "lands in the wrong place"
    — arrives nowhere. With Key Caps open and frontmost, neither
    `send-key` (plain, held, and with modifiers) nor `input-send-event`
    key-down/key-up pairs light a single key or put a character in its
    field. Cmd-N in the Finder makes no folder; Cmd-Shift-3 makes no
    Picture 1.
  * **`abs` pointer events are refused**, and now for a stated reason:
    "Input handler not found for event type abs" is what QEMU says when
    no absolute pointing device exists, and none does. `rel` motion is
    accepted and carries OS 9's pointer acceleration, so counted steps do
    not land where they are aimed (measured earlier the same day: aimed
    at (270,119), ended near (10,63)).
  * **The worker's `click` verb closes a menu without selecting from
    it** — a posted event pair is already up by the time `MenuSelect`'s
    tracking loop reads the real button state.

  So an agent still has **no route to a menu selection on this rig**, and
  that is now a UI-driving limitation rather than a blocker: nothing in
  `spin-up-ppc` needs a menu any more.

  Two things this did NOT establish. Why the key events vanish is a
  hypothesis, not a measurement — the un-enumerated second keyboard is
  suspicious, but nothing here proved QEMU routes to it. And whether
  dropping `-device usb-kbd` from the lab's `tbt_qemu_boot` would restore
  QMP keyboard input was not tried; it is the cheapest next experiment,
  and it would unblock keyboard driving generally. Even if it worked it
  would not give a shutdown: a USB keyboard has no power key here either,
  and Shut Down has no Command-key equivalent in the Finder.

## BROKEN: the anchor plane is active and binds nothing (2026-08-05)

**Found by the first cold boot that ever got this far.** Until the guest
could be made to shut itself down, `scripts/spin-up-ppc` stopped before
the reboot, so nothing had ever interrogated a machine with the unified
NOW Extension resident from a clean start. It does now, and the resident
is plainly alive:

    mirror -> lifecycle "active", capabilities 31, all five planes
              supported, resident fc6e0946bde9271, table 4256 bytes
    qdtrace op=status -> plane {format 2, length 65728, ringCap 65536}

And nothing can be addressed inside it:

    actselftest -> no-such-process        (every attempt, over minutes)
    axsnap      -> front "New Old World", bind "no-plane",
                   hasWindows false, hasMenus false

**The two halves disagree about the same planes.** `actselftest` calls
`now_act_ready`, which claims anchors + act; asked immediately afterwards
in the same connection, `mirror` reports `requested: 5, active: 5` — so
the claim reaches the table and the resident is serving both. Yet
`now_ax_bind_process` still answers `kNowPeekReadNoPlane`, which
`qdtrace_cmd.c` words as "the window-anchor plane is not armed". The
client's plane gate and the resident's own report of the same word do not
agree.

Also note `bind: "no-plane"` and not `not-pumped`: this is not the
settle window [staging-path.md](staging-path.md) records, where a
just-launched application is briefly invisible because it has not pumped.
That one cleared in seconds; this does not clear at all, and it is NOW's
OWN application — the case every earlier entry here treats as the easy
one.

**Not measured, and worth doing first:** whether this predates the
unified extension (2026-08-03) or arrived with it. `staging-path.md`
records `actselftest` answering `abi-agreed` on 2026-08-01, on the plane
model that work replaced, so a bisect has somewhere to start. Read
`now_ax_bind_process` in `now-guest-ppc/src/axwalk/axprocess.c` against
whatever `mirror` reads for `active`, because those are the two words
that disagree.

`spin-up-ppc` runs `actselftest` and prints its answer, but does not gate
on it — a gate permanently red for a defect the rig neither causes nor
can fix is a gate nobody reads. It moves back into the gate when this is
closed.

**2026-08-06, mechanism found and fixed — it was the writer heartbeat,
and "binds nothing" was the flap's worst phase.** The application renewed
`writer.heartbeat_ticks` only inside peek calls, and the lease is 3 s
(`kNowPeekWriterLeaseTicks`), so any wire cadence slower than that let
the resident see a dead writer between requests and de-arm every plane;
the next scene then claimed, renewed, and read `arm_active`
synchronously — before the resident's next jGNE pass could re-echo — so
the first walk after every quiet gap answered `now_no_plane` for every
foreign process. Measured on a clone before the fix: 6/6 scenes at a 4 s
cadence carried no foreign process, while `axsnap` in the same
connection bound the Finder ok (a command pass renews and pumps, which
is why the two halves disagreed). The fix is `now_peek_idle()` — the
event loop renews once per pass, so the heartbeat proves the loop runs,
which is the fact the lease exists to check. Verified on the same clone:
five scene polls with 6 s silent gaps all carried the Finder and its
windows, and its scroll bars arrived classified. Two things this does
NOT close: the FIRST scene of a fresh connection still misses foreign
processes (claim-before-echo, by design — the host's second poll covers
it), and `actselftest`'s `no-such-process` did not change and needs its
own look. The scene should also say WHICH gate refused in its coverage
`reason` (`no-plane` vs `not-observed`) — this defect survived two
sessions because the wording hid the distinction.

## BROKEN: a Finder-open predicts the wrong owner, so panels time out having worked (2026-08-05)

`MirrorActionExecutor` builds `windowNamedPresent(owner: Finder, title:
item)` for every Finder-open. A control panel opens **as its own
application**: a live snapshot taken while Date & Time was up shows that
window owned by a process named `Date & Time`, not by the Finder. The
postcondition is unsatisfiable, so the act burns its full 15 s timeout
having succeeded. It holds only for FOLDERS, whose windows the Finder does
own.

Measured in Michelle's drive: four `open "AppleTalk"` attempts, 15 s each,
and because the mutation FIFO is one lane those timeouts stacked — waits of
15 611, 22 207, 22 106, 37 391, 51 786 and 49 281 ms behind the lane. One
click waited **51.8 seconds**. This one defect is most of the queueing
that drive complained about.

`finderItem.kind` in the snapshot already carries folder-or-file, so a fix
can predict a window for a folder and a PROCESS for an application instead
of guessing one shape for both.

Related, and separate: **an act that legitimately does nothing costs the
same 15 s.** Driving `finderOpen "Date & Time"` against the desktop (where
it does not live) correctly opened nothing, and still burned the timeout
rather than the Finder answering "no such item".

## BROKEN: both Hide routes fail, each in its own way (2026-08-05)

Hiding an application works on a Macintosh; a person does it from the
Application menu. Neither route NOW has reproduces it.

- **AppleScript** — setting `visible` through the Finder's object model is
  refused: `-10000`, `-10006`, and in the 2026-08-05 drive `osaErr -1753`.
  Read-only there.
- **The Application menu, commanded** — the menu is read correctly (`Hide
  Date & Time`, `Hide Others`, `Show All`, present and enabled at menu
  `-16489`), and driving row 1 through `now_mirror_drive --gesture
  menuItem` returns `dispatched` and changes nothing. The paired screendump
  shows the application still frontmost. `InteractionPolicy` already
  records this: visibility is kept typed so it "cannot fall back to
  commanding menu -16489, the route that reported success without changing
  the machine".

**Why the act plane cannot reach it, understood 2026-08-05.** `menuact`
works by arming a trap patch so the target application's own `MenuSelect`
returns the chosen row — which is why it drives the Finder 8/8. The
Application menu is **system-owned**: the Process Manager performs the
hide, and the front application's `MenuSelect` never sees it. So this is
not a flaky route, it is the wrong mechanism for this menu.

**A real positional click is not possible today either**: the guest has no
positional click verb. `mouseloc` is a READ (`input/input_cmds.c`), and the
act plane delivers menu choices by arming a patch rather than by moving a
pointer.

**THE ROUTE THAT EXISTS: `ShowHideProcess`, weak-linked from the Carbon
app.** An earlier version of this entry said the Process Manager's
visibility call was absent from the toolchain under any spelling. **That
was wrong, and the error is worth keeping**: the sweep checked
`toolchain/universal/libppc/libCarbonLib.a` and two `CarbonFrameworkLib`
archives, and never `toolchain/multiversal/libppc/libCarbonLib.a`. There
are TWO CarbonLib archives of different vintages here and only one was
looked at. Verified 2026-08-05:

- present in `Retro68/ImportLibraries/libCarbonLib.a` and
  `toolchain/multiversal/libppc/libCarbonLib.a`, together with
  `IsProcessVisible`;
- absent from `toolchain/universal/libppc/libCarbonLib.a` — and
  `powerpc-apple-macos/lib/libCarbonLib.a` is a SYMLINK to that one, so
  **the linker currently resolves to the archive without the symbol**;
- the split is Universal Interfaces 3.4 (headers, on the include path)
  versus 3.4.1 (the richer archives). `ShowHideProcess` did not exist
  until 3.4.1 — zero occurrences in 3.2, 3.3.2 and 3.4.

`pascal OSErr ShowHideProcess(const ProcessSerialNumber *psn, Boolean
visible)`, `THREEWORDINLINE(0x3F3C, 0x0060, 0xA88F)`, cited from UI 3.4.1
`Processes.h` ll. 542–545 and Apple's *Process Manager Reference*
(2007-12-04, p.19). Availability: **CarbonLib 1.5 and later** — our floor
is 1.6. It is a WEAK import, so the address is tested before it is called.

**And this entry's other worry is settled.** `ProcessInfoRec` carries no
visibility field at all, so `GetProcessInformation` cannot disagree with
the Application menu; the state is the LAYER's `visible` flag, which is
also what Mac OS 8's own `AdjustApplicationMenu` tests when it decides
whether Hide is enabled. One flag, both readers. `IsProcessVisible`
(selector `0x005F`) is the read-back.

**Why `menuact` could never have worked, precisely.** For a system-owned
menu, `MenuSelect` calls `SystemMenu` (trap `$A9B5`) and returns 0 in the
high word to the application; the Process Manager's patch on `_SystemMenu`
performs the hide. Arming a patch on the front application's `MenuSelect`
therefore skips the only code that acts. The wrong trap, not a flaky one.

**Do not reach selector `0x0060` by raw `_OSDispatch`.** Apple's
dispatcher does no bounds check: an unimplemented selector does not return
an error, it reads past the table and `rts`es into whatever that longword
holds — in a resident, in every application's context, an unrecoverable
crash rather than a `paramErr`, with no way to probe first. That route is
last. Plan:
[2026-08-05-010 § C](plans/2026-08-05-010-feat-closing-the-headless-mirror-plan.md).

Until something is watched working, Hide is UNBUILT rather than broken. Its
other half — that it should not hold the shared lane for 15 s rediscovering
a route already known to fail — was fixed on 2026-08-05; that changed the
cost of failing and nothing about whether Hide works.

## P5, THE TRANSITION TAIL: RESIDENT WRITES, NOTHING DELIVERS YET (2026-08-05)

**Built and gated; never executed on a machine.** A ~2.2 s scene cycle
cannot see anything shorter than 2.2 s — measured across 60 cycles: 783 ms
idle, 92 ms request, 315 ms decode. An alert raised and dismissed between
walks leaves the machine as it found it and the Mirror never knew. P5 is a
transition SAMPLER at the guest's own event-loop rate, riding the jGNE pass
that already reads the window list, menu list and current A5 for the anchor
plane.

What exists: the contract (`contract/event_tail.h`), a ring in a system-heap
block behind one appended table word, the resident writer (`ext/src/now_event.c`),
the guest's ring reader, and a fifth `transitions` plane reported end to end.
109 native tests, three cross-builds, full host gate.

**UPDATE 2026-08-05, `claude/p5-transitions-delivery`: the guest half of
that gap is closed and the machine half is not.** The contract declares a
`transitions` verb — `status` (the default, which moves nothing), `start`,
`stop`, `drain` — modelled on `qdtrace` and simpler than it in three
stated ways; the PowerPC guest answers it on BOTH faces off one
implementation; and a native test covers the command layer's own
decisions. So something arms the plane now, and a message carries records.

**What is still not proven is everything that matters.** No guest has
been stood up since the verb landed — the VM cold boot could not run
unattended — so **no record from this ring has ever been observed
crossing the wire, on any machine**. `status` has never answered from a
real block, `start` has never had a resident agree with it, and `drain`
has never returned a record. The reader and the writer have still never
met: the ring's two halves are tested separately, against fixtures, by
the host compiler. Treat every claim below the contract as BUILDS, not
tested and not metal-verified.

Two things a first live run should look at, because they are where the
guest half is most likely to be wrong: `activity.passes` staying at zero
while a request reads live (that is an arm that named the wrong world,
and it is the one diagnostic this design leans on), and whether
`reader_cursor` moving forward on drain actually makes `dropped` behave —
the forward-only rule is native-tested against a fixture and has never
been read by the resident it exists for.

**The host consumes none, and that is deliberate rather than pending:**
the host consumer is a later slice, declared in `docs/mcp-coverage.md`'s
gap table with its reason. Until it lands the plane is reachable only by
a person typing at the guest or by a direct `command.request`.

Before that update, the status was: nothing arms the plane, no contract
message carries records to the host, and the host consumes none. So a
cold boot proved the INIT loads, allocates, publishes `cap` bit 4 and
boots clean — and proved nothing about the tail. That last sentence is
still true.

Two things found while building it, both mine:

- **The plane roster was made breaking in the wrong direction.** Moving the
  contract from exactly-four plane rows to exactly-five meant a newer host
  refused an older guest's honest four-row report — "The Mac's mirror facts
  do not match schema 1". This project's rule is that an older reader
  refuses a NEWER message, never the reverse. The contract now says four
  rows or five and the reader completes a missing trailing row as
  present-and-unsupported.
- **The snapshot outgrew one protocol message.** Adding Finder items pushed
  a scene of several panels plus a desktop past the 64 KB ceiling, past
  which the writer throws and the connection closes with NO reply — so
  `now_mirror_snapshot` stopped answering while `status` and `lifecycle`
  still did, which reads as a broken host rather than an oversized payload.
  Bounded per window AND per snapshot now, both stated in `itemTotal`.

Also unverified: `finderDeselect` and `dialogItem` against an item that
does something have never been driven; the INIT resource is 67 KB against
a conventional 32 KB budget (pre-existing, and this image boots it).

## BROKEN: the Finder cannot set `visible`, so no Hide act can ever land (2026-08-05)

Measured directly against Mac OS 9.1 (mac99, guest build `a4a59d37d100`) by
impersonating a host with `tools/askguest.py` and running the production
scripts verbatim. **All three visibility mutations are refused by the
Finder's object model**, so `Hide`, `Hide Others` and `Show All` have never
been able to work by this route:

- `hideFrontApplicationScript` → `-10000 Finder got an error: Can't
  continue .`
- `showAllApplicationsScript` → `-10006 Can't set visible of every
  application process to true.`
- `hideOtherApplicationsScript` → `-10006 Can't set visible of item 1 of
  every application process to false.`

`visible` is readable and read-only there: `set v to visible of process
"tbt-worker"` answers `false`, and every attempt to assign it fails. The
census confirmed the machine was unchanged after each attempt. This is the
real blocker behind C27's "Hide Finder timed out"; the settlement rule was
never the problem, and the dispatch it was waiting on could not have
happened. A working Hide needs a different mechanism — the act plane
driving the Application menu is the candidate, and it is what a person
uses — not a repair to this script.

**Fixed the same day, and separately: the census asked a question the
Finder cannot answer inline.** `visible of candidate` read straight into a
`&` chain is an object specifier, not a boolean, and the concatenation
raised `-1700 Can't make visible of «class prcs» "tbt-worker" of
application "Finder" into a string`. AppleScript fails a script WHOLE, so
the census returned no rows at all — which is why `now_mirror_snapshot`
showed `visible: null` for every process and a coverage claim that blamed
name ambiguity. Binding the property first fixes it; the corrected script
was run against the same machine and returned all 7 rows the Finder can
see. `MirrorStateEngine.enrichVisibility`'s sequence guard, which the
investigation began by suspecting, was never implicated: the coverage row
that appeared in the snapshot could only have been written by a census that
already passed it.

**Still open, and the reason a complete census is not enough.** The Finder
is absent from its own process list — `count of (every process whose name
is "Finder")` is 0, and `name of process "Finder"` errors — while the
replica always carries the Finder as an application. So
`matched == Set(replica.applications.keys)` cannot hold, coverage stays
`partial`, and a visibility postcondition still cannot settle even with the
script repaired. `visible of application "Finder"` does answer a real
boolean (`true`), but it addresses the Finder application rather than a
process row, nothing has yet watched it change, and a value that never
changes would settle mutations falsely — the failure
`docs/mirror-drive-loop.md` §2j exists to prevent. It is not to be adopted
until something has watched it go false.

**Unverified here:** the repaired census has not been watched settling an
operation end to end. The host app could not be run beside the one already
holding the per-user agent endpoint, so the script was proven against the
guest directly and the join proven by unit test, not the two together.
## P4's plane is intact; the reason named for its silence was wrong (2026-08-05)

**The symptom stands; the diagnosis attached to it does not.** A human drive on
2026-08-04 (guest `a4a59d37d100`, resident `67d5ef43`) found
`now_mirror_lifecycle` reporting **interaction generation 0** while structure sat
at 613025 and content at 1522260, and not one act settling `confirmed` in eight
minutes. That is real and still open.

The reason recorded alongside it was that the host's requested plane mask "flaps
between 7 and 15" with "the interaction bit (8) clear", pointing the repair at
`MirrorControlModel.requestedPlaneIDs`, `MirrorPlanePolicyStore`, and the arming
path. **That reading is wrong, and it points away from the defect.**
`contract/peek_table.h` states the bits once:

    kNowPeekTableCapAnchors = 1u << 0   P1
    kNowPeekTableCapTree    = 1u << 1   P2
    kNowPeekTableCapAct     = 1u << 2   P4   <- the act plane, BELOW P3
    kNowPeekTableCapContent = 1u << 3   P3

P4 sits below P3 because P3 asked for `1u << 2` while P4 already held it — the
near-miss recorded under "Two planes asked for the same bit" (2026-07-31). So
`cap=15 requested=7 active=7` says P4 **was requested and active**; the bit clear
in 7 is P3, whose request is a bounded lease by design
(`now_peek_claim_until`, from `qdtrace_cmd.c`), which is exactly what a mask
expiring and being reclaimed looks like. Host plane policy is not implicated by
that line. `now-guest-ppc/tests/peek_table_test.c` now pins each bit's value, so
the same misreading fails a gate rather than an evening.

**Where the defect actually has to be.** `mirror_probe.c :: plane_generation`
returns, for P4, `table->act_v2.resident_generation`. That word is written in
exactly one place — `now-guest-shared/src/now_act_guard.c`, where
`v2_echo_request` bumps it twice and `now_act_v2_note` bumps it twice per stage —
and both are reached only through `now_act_v2_begin`. Generation 0 therefore
means **`now_act_v2_begin` returned early on every act of the drive**, and it has
only three early exits:

- `now_act_plane_state(table) != kNowActPlaneReady` (length, caps or act_format),
- `cell->status != kNowPeekActStatusPending`,
- `cell->target_a5 != current_a5` — by design, since only the target process's
  own pump may proceed.

Arming is *not* a candidate: the same log line that opened this arc shows the
plane armed and active. Measurement below settles which of the three it is —
the second, `cell->status` never pending, because no act ever arrived.

**RESOLVED the same day: generation 0 means idle, not dead.** Reproduced on an
emulated Power Mac G4 (guest `16d99316ff6b`, resident `67d5ef43` — the same
resident as the drive), with all four planes reading
`requested=15 active=15` and every plane `active-current`:

    interaction=active-current/gen0     <- before any act
    interaction=active-current/gen6     <- after ONE console `actselftest`

Six is exactly one echo plus two stage notes at two bumps each, and the act
itself failed. So `resident_generation` advances as soon as an act reaches
`now_act_v2_begin`, and **generation 0 is a truthful "no act has ever reached
the resident" — not a broken plane.** P4's publish path is intact.

That moves the open question upstream, off the resident entirely: in the
2026-08-04 drive, acts were attempted and settled `unknown` /
`dispatched-but-unconfirmed` while the resident's counter never moved, so
those acts never got as far as a pending cell the resident could see. The
next investigation belongs in the host's act dispatch and the guest's
`now_act_submit`, not in arming, plane policy, or `ext/`.

**Two rig traps found on the way, both of which mimic a dead plane.**

1. `/private/tmp/now-u7-extension-only/session.qcow2` carries the NOW
   Extension in its file system, but its internal snapshots predate it.
   Resuming `--loadvm runner-ready` (a 2026-07-19 state) gives a guest
   reporting `lifecycle=absent`, `cap=-`. Cold-boot it and the resident is
   active. (An earlier draft of this entry claimed a cold boot still
   reported `absent`; that was wrong — it was reading stale lines from an
   append-only log that BOTH sessions' hosts write to. Mark the log length
   before an experiment and read only past the mark. `NOWBASE actmeta`
   lines carry `guest_build=`, which is the only way to tell whose guest
   a line describes.)
2. **A guest binary not named `New Old World` cannot arm any plane at
   all.** `peek.c :: current_app_identity` requires creator `NOWo` *and*
   the exact process name, and `maintain_writer` returns 0 without it —
   "dev-named app: read-only NWex" — so `publish_claims` never writes
   `arm_request`. Same build, same resident, same host: renamed from
   `now-guest-ppc` to `New Old World`, `requested` went **0 → 15**. The
   app looks entirely healthy meanwhile, and the host still reports
   `lifecycle=active cap=15`, so the Mirror simply shows nothing and every
   act refuses. AGENTS.md records this name as a *preferences* rule; its
   sharper consequence is that a dev-named build has no Mirror at all.

The instrument that settled all of this is now permanent: the `actmeta`
line carries each plane's own state and generation beside the masks.

## CYCLE 27 RETAINED-STATE CHECKPOINT; TWO ADVANCES, TWO BLOCKERS (2026-08-04)

The exact `d0a3e1a` host was driven through native Mirror mouse input and
compared with the explicitly identified QMP framebuffer oracle. Before that
drive, `scripts/test-all` passed 103 native tests, the PowerPC, 68K, and NOW
Extension cross-builds with their real Retro68 toolchains, and the full host
gate. This is tested and emulator-observed, not metal-verified and not a green
Mirror sweep.

Two earlier red cases advanced. Macintosh HD now opens with its item roster in
the first settled Finder scene instead of remaining blank until an unrelated
action. Key Caps now launches through a typed guest-Finder operation and comes
frontmost. Workshop resize and close also continued to mutate both surfaces,
and Workshop's structured content no longer disappeared during the observed
poll sequence.

Two blocking families remain. `Hide Finder` timed out without changing the
authoritative guest and produced no visibility-action line in the host log;
the retained visibility census correctly refused to confirm it, but dispatch
and observability are still broken. Key Caps is a successful launch with a
completely empty Mirror body: QMP shows the full keyboard while Mirror shows a
hatched unavailable region. That application has no standard controls, so its
draw-owned content needs an explicit structured placeholder until deferred
pixel transport is undertaken. Finder fidelity also remains partial, and
Sherlock was not re-driven in this continuation.

The apparent Apple-row count changed with the front application: NOW-front
began at AirPort, while Finder-front additionally exposed `About This
Computer`. Do not treat that contextual difference as destructive row loss
without an authoritative same-context comparison. Strict C27 rows remain
blocked because the captures do not include the complete correlated
operation/settlement/host-log/guest-log manifest. Exact identities, evidence
paths, and the bounded verdict are in
`docs/mirror-retained-planes-checkpoint-2026-08-04.md`.

## CYCLE 26 HIGH-WATER CHECKPOINT; APPLE REPAIRED, STATE MODEL OPEN (2026-08-04)

The exact C26 native host was driven through its Mirror and compared with QMP
guest captures. A later scene's empty Apple shell no longer erases complete
same-guest rows: the host retains only previously observed guest rows, keeps
the newest identity/geometry, marks the projection `expected-stale`, and never
invents an initial menu. The regression guard was watched fail under mutation
and pass after restoration. The full native/host gate passes; the cross-guest
build step skipped because Retro68 was unavailable on this shell path. This is
tested and emulator-observed, not metal-verified.

The direct sweep also fixes the verdict on several earlier reports. Macintosh
HD opens from Mirror input and Finder contents render. Date & Time opens, Set
Time Zone appears within 25 seconds, and Cancel works. Their fidelity remains
red: Date & Time lacks authoritative field values and explanatory text, and
the modal's guest city/country rows are blank in Mirror. Workshop structure
renders but its authoritative detail content is blank after the content ring
reports earlier bytes overwritten. Hide Finder briefly removes then restores
the window without changing the front application. `Windows > Workshop` is
refused because the guest never calls `MenuSelect`, so the window does not
reopen.

C26 is paused rather than falsely scored green: the strict evidence manifests
were not complete for every row. The durable build identities, direct sweep,
act-log evidence, paired images, and resume instructions are in
`docs/mirror-high-water-checkpoint-2026-08-04.md`. This checkpoint is the floor
for the host state-engine plan; no later implementation may trade these passes
for progress elsewhere.

### STATE ENGINE U7 READ PARITY BUILT; LIVE STAGING STILL OPEN (2026-08-04)

The native Mirror and MCP now have one state owner rather than parallel
observers. Local protocol v9 exposes status, snapshot, find, and wait as four
read-only projections over the existing session-pinned engine. They carry the
same snapshot ID, digest, stable process/window identities, freshness,
coverage, and generation counters the native renderer/evidence path reads.
Find is locally bounded and wait observes publication without polling the
guest or creating another cache.

Seven focused service/projection/codec tests pass. The derived MCP coverage
gate was watched failing because all four newly registered tools were absent
from `docs/mcp-coverage.md`, then passed after the rows were documented. This
is **tested, not yet live-parity verified**: the running host predates protocol
v9 and the development VM still has a stale guest application despite the
current NOW Extension.

**Later 2026-08-04 runtime correction:** protocol v9 was exercised through the
exact newly built Host and `now_mirror_status` returned the live engine's guest,
session, snapshot ID, sequence, digest, completeness, and both generations.
That proves the socket/read projection is live, but not whole-surface parity.
The first direct U8 preflight remained red: the cold Mirror acquired only a
desktop shell until the first Apple-menu click; that click recovered six
windows, but Finder and Date & Time content was blank/placeholder, the Apple
menu had no rows, and both `Windows > Workshop` and Application-menu Finder
selection refused because the displayed compatibility entities lacked stable
guest identities. The exact current extension file was then staged, but the
current guest application could not overwrite its running predecessor
(`create err -48`). The scoped Worker refuses both targeted quit and scripted
shutdown, so the image is explicitly **partially staged and not clean-saved**
until the visible app is quit and the full app/extension pair is cold-booted.

Two items remain explicitly deferred. The old `now_observe_elements` call
cannot be removed until the state engine owns structured control elements and
their capability references; removing it now would make the existing act rows
unaddressable. MCP mutation parity also remains off until a direct native
equivalent is proven against the exact staged guest. Neither API reach nor MCP
success can satisfy a direct-input/pixel gate.

### STRUCTURED LIST CONTENT PRESERVED; BROAD PANEL FIDELITY STILL RED (2026-08-04)

The Date & Time city/country failure was not an absent guest capability. The
NOW Extension already returned every List Manager cell as bounded row, column,
text, and selection records, but the application bridge collapsed the answer
to selected text before scene publication. The renderer then compounded the
loss by giving an unclassified DITL resource-control shell precedence over the
same live control after P2 had classified it as a list. The scene contract now
retains bounded `listCells` plus the guest's total count, marks the payload
complete only when every reported record is valid and present, and lets a
classified semantic control supersede only its matching unknown resource
shell. Focused native, IR decode/freeze, and renderer tests pass, and both PPC
guests plus the extension cross-build with the real Retro68 toolchains.

This is **built and tested, not emulator-verified**. The running VM disconnected
before the rebuilt extension could be cold-loaded, so no direct Mirror drive,
authoritative guest capture, or pixel comparison has yet proven the city and
country rows. Set Time Zone is currently known to be a titled Dialog Manager
window (`kind == 2`) with DITL items and stacking; the scene does not prove
whether the application is inside `ModalDialog`, so the host must not invent a
stronger alert/modal-loop claim.

The wider application/control-panel content problem remains red. P3
deliberately refuses to replace an application's existing custom QuickDraw
`grafProcs`; that is a safety boundary, not evidence that a blank interior is
acceptable. The next cold-boot sweep must collect multiple application and
control-panel surfaces in one pass, separating structured P2/DITL content,
settled P3 replay, and explicit unavailable placeholders before another shared
producer/renderer patch. A guest-side action performed outside the Mirror while
the connection was failing also demonstrated the expected-stale case: retained
same-session state is useful for continuity but must not be driven or scored as
current.

The same session ended with the guest showing the system bomb dialog
`“Finder” error type 10` after an earlier alert was dismissed, before reaching
a black powered-down framebuffer. The host log proves only that its Special >
Shut Down menu action was dispatched and the guest disconnected one second
later; it does not attribute the Finder crash to that action, P3, or the
unbooted list patch. Treat this as a blocking crash sentinel for the next cold
boot: record the resident extension identity, arm content conservatively, and
stop the sweep if Finder faults again.

**Later 2026-08-04 live correction:** the rebuilt extension and application
were cold-loaded, and a coherent QEMU memory sample reached the exact Set Time
Zone list control. The extension's `NWpt` semantic cell completed that request
as `UnsupportedCustom`; it did not return the city/country cells. The earlier
bridge-collapse diagnosis came from unit fixtures and is valid coverage for a
standard list, but it was not the live cause of this panel's blank rows. The
current guest classifier rejects any list box with a nonzero LDEF before
asking for its ListHandle. The generic, metal-compatible next step is to prove
the public List Manager backing record and widen the extension producer under
validated invariants, not special-case Date & Time or introduce pixels. The
read-only dev method and exact observed records are in
`docs/qemu-memory-oracle.md`.

The same run broadened the next batch before another extension rebuild.
Date & Time's base window has 20 DITL items and 21 controls but loses multiple
structured values and status strings. Sherlock has 35 live controls spanning
standard, edit, list-like, and application-defined definitions while its
Mirror is mostly structural shells. Key Caps has two windows and no controls
at all, so its missing keyboard is draw-owned and belongs to the explicit
placeholder/deferred-pixels path rather than the control-semantic patch. The
extension work remains open until the Date & Time and Sherlock control classes
are inventoried and patched together.

**Later 2026-08-04 implementation checkpoint:** P2 format v2 now classifies
Apple-owned controls through public `kControlKindTag`, reads bounded clock/text
values through public data tags, permits a public list-box ListHandle with a
nonzero drawing LDEF, offers every live control, and retains 64 compact class
facts plus four bounded list payloads. Sherlock's 35-control census therefore
cannot restart after eight entries, and typed-but-undecoded data browsers/user
panes/image wells produce explicit bounded placeholders. Key Caps remains the
separate zero-control, draw-owned placeholder case. Focused native/renderer
tests pass, the new placeholder guard was watched fail under mutation, and the
PPC, 68K, and flat-INIT Retro68 cross-builds pass. This is **built and tested,
not emulator-verified** until the new INIT is cold-loaded and the broad direct
Mirror sweep is repeated.

**Cold-load result:** the broad direct-input sweep is still red. Set Time Zone
and Sherlock retain bitmap-unavailable regions; the latter's newest settled P3
generation contains only its final CopyBits blit, so renderer ordering alone
cannot recover its structured controls. A paired state-engine/QEMU sample
showed Date & Time as the fresh front process while the live P2 request kept
naming one Finder control and the last completed response remained an older
`UnsupportedCustom` Date & Time base-control answer. The sample did not reach
the exact Set Time Zone list, so it neither verifies nor refutes the public
list-kind hypothesis and does not alone justify a scheduler rewrite. The
renderer now keeps unavailable CopyBits geometry behind structured ops and
lets a typed incomplete list suppress only its unknown DITL shell; both tests
were mutation-watched, but neither row is green without current P2 data.

A generic follow-up is now built and staged: a custom-signature control may
prove that it is List Manager-backed by successfully returning the public
`kControlListBoxListHandleTag` with the exact handle size. Apple-owned
non-lists are not probed, and a declined/malformed custom result stays
explicitly unsupported or invalid. The native semantic slice and real 68K
guest/flat-INIT cross-build pass; deleting the fallback fails its source guard.
The running VM still contains the prior resident code until a clean cold
reboot, so no UX claim has changed yet.

### STATE ENGINE U1A: TYPED COVERAGE AND LIFETIME IDENTITY BUILT (2026-08-04)

The IR v2 producer and MirrorKit consumer now agree on typed collection
coverage and durable process/window incarnation fields. Process census,
per-process window membership, and front-menubar coverage reach the wire as
`complete`, `partial`, `retracted`, `failed`, `stale`, or `unavailable` rather
than requiring a reducer to parse English diagnostics. The normative rule is
now explicit: only fresh complete parent coverage may prove deletion; weaker
coverage retains compatible state expected-stale and inert.

Native `scene_json_test`, MirrorKit IR-freeze tests, and host scene decode tests
pass. The test was first observed failing on both sides before the contract was
implemented. The cross-guest build gate skipped because Retro68 was unavailable
on this shell path, so this checkpoint is **tested, not guest-built and not
emulator-verified**. U1 remains open for exact Finder-item and application
visibility capability identities plus forced collector-exit coverage guards;
those must not be replaced with title/name matching merely to advance U2.

### STATE ENGINE U2A: PURE RECONCILIATION AND SETTLEMENT BUILT (2026-08-04)

MirrorKit now has session/process/window identities, an ordered scene
observation, a pure replica reducer, immutable projection metadata and semantic
digest, tombstones, and a separate pure operation reducer. Incomplete absence
retains compatible entities expected-stale, non-frontmost, and inert; only an
exact complete parent scope deletes. A complete process census plus complete
window membership for every process is the base-acquisition barrier. IR v1 is
still displayable but cannot enter durable maps or authorize deletion/action.

Fourteen focused reducer tests pass. A deliberate mutation that treated any
process coverage claim as complete made the background-retention test fail by
deleting New Old World, then the correct predicate was restored. The broader
MirrorKit suite is **not green**: seven historical fixtures compare current-v2
builder output with v1-stamped golden scenes. That pre-existing version
expectation is recorded rather than hidden or repaired inside this state slice.

This is still additive pure state, not visible Mirror behavior. Host shadow
plumbing, full producer coverage, content generations, bounded history,
capability-safe Finder/app actions, direct-input pixels, guest build, and VM
staging remain open. The implementation contract and limits are in
`docs/mirror-state-engine.md`.

### STATE ENGINE U3A: SESSION-PINNED SHADOW ENGINE WIRED (2026-08-04)

The host now keeps one shadow engine per exact `GuestKey` connection session,
publishes accepted projections into a bounded 32-snapshot/15-minute history,
and records bounded semantic differences against the still-visible legacy
scene. `NOWMirrorSource` pins the session it started on and sends structural
polls to that exact socket even after the active picker changes. Responses from
another session are ignored, and a second scene caller is refused instead of
silently replacing the first completion.

The old action and content paths remain active-session-only. This checkpoint
therefore pauses them and visibly refuses gestures whenever the selected Mac is
not the Mirror's pinned Mac; shadow state never authorizes mutation. A delayed
stop callback also cannot clear a newer Mirror binding. This is an honest
safety boundary, not the final addressed operation broker.

Five focused engine tests, the addressed two-guest polling test, and all 21
existing `NOWMirrorSourceTests` pass. The live C26 Mirror/VM were deliberately
not touched during this plumbing checkpoint. Full direct mouse/keyboard
preflight, shadow parity across Workshop/Finder/Date & Time, structured-content
and Finder enrichment reduction, native read cutover, guest build, and VM
staging remain open. The visible product is still the C26 legacy projection and
must not be described as state-engine-driven yet.

### STATE ENGINE U4A: ASYNC RENDER ENRICHMENT AND FRAME EXPORT BUILT (2026-08-04)

Settled QuickDraw content, cached Finder window items, and desktop items now
converge through the shadow engine after their exact structural sequence. The
pure enrichment path changes render-bearing fields only, requires the same
process/window incarnations and geometry, ignores stale sequences, and does not
publish semantic no-ops. Engine snapshots now expose stable structural and
content generations independently.

The native Mirror window also has an app-owned evidence export that pairs its
PNG with the full decoded engine scene, exact snapshot identity, guest/session,
sequence, digest, base completeness, and both generations. It refuses if the
visible legacy scene differs from shadow state or if the snapshot changes while
AppKit captures the frame. This is only the Mirror/state member of the strict
gate; it does not replace direct keyboard/mouse provenance, authoritative guest
capture, operation/settlement, or logs.

Ten focused engine/export tests plus nine content-plane and 21 Mirror-source
tests pass. The stale-enrichment guard was watched fail under mutation, then
restored. Guest-authored content epoch/generation metadata, typed
Finder/content coverage, the QMP-only oracle target split, live direct parity,
and visible read cutover remain open, so this is a **tested shadow checkpoint**,
not emulator-verified product behavior.

### STATE ENGINE U4B: EXECUTABLE QMP CODE IS ORACLE-ONLY (2026-08-04)

The QMP socket client, QMP-capable action dispatcher, and legacy live polling
controller now live in a separate `MirrorOracleKit` SwiftPM product.
`MirrorApp` opts into that development target; production NOW Host still links
only `MirrorKit` and `MirrorKitUI`. The Host app builds without the oracle
product, its binary contains none of the QMP handshake/dispatcher markers, two
host tests guard the manifest/source boundary, and the standalone legacy
MirrorApp still builds.

This is not yet the whole U4 cleanup: historical QMP-named action cases,
availability fields, and `MirrorTarget.qmp` remain in core data types even
though their executable behavior no longer links into NOW Host. Those types
must become platform-neutral or oracle-owned before U4 is complete. No live VM
or Mirror was touched, and this checkpoint changes no visible projection.

### STATE ENGINE U4C: PRODUCTION ACTION MODEL IS ORACLE-NEUTRAL (2026-08-04)

The remaining development-oracle vocabulary has been removed from production
state and action types. `MirrorTarget` now identifies only the guest wire and
machine. Positioned press, double-click, drag, menu tracking, and thumb
tracking are platform-neutral device actions behind `ActionPlanes.inputDevice`;
the optional QMP socket and its availability decision live in
`MirrorOracleKit`. `LiveMirrorController` exposes the adapter's actual planes,
so a development launch without a socket no longer advertises device tracking
that its dispatcher will refuse.

Sixty-one focused Mirror action/hit/Finder/scroll tests and 24 NOW source and
oracle-boundary tests pass. Both `MirrorApp` and production `Host` build, and
the Host binary contains none of the QMP client markers. The new model-source
guard was mutation-watched: adding a QMP sentinel to `ActionModel.swift`
failed the named test, and restoring the boundary passed it.

This is a **tested architecture checkpoint**, not visible or emulator-verified
progress. U4 still needs producer-owned content epochs, strict full-manifest
gate tooling, and live shadow parity; U5 read cutover, FIFO mutation, the
direct native input/pixel campaign, guest build, and staged VM remain open.
The live C26 Mirror and VM were deliberately left untouched.

### STATE ENGINE U4D: ORACLE CAPTURES ARE EXPLICIT AND IDENTITY-BOUND (2026-08-04)

`tools/shot` no longer guesses the newest `run/*/qmp.sock`. Each framebuffer
capture requires an explicit socket and a versioned oracle-identity artifact
that names the guest, exact connection session, guest build, QEMU VM name, and
socket. The helper verifies QMP `query-name` before `screendump` and emits a
capture sidecar with the same identity and capture timestamp.

The UX evidence gate requires that sidecar, joins its guest/session to the
engine state artifact, and rejects wrong build, VM, socket, frame, timestamp,
or missing sidecar. QMP remains observation-only; none of this supplies input
provenance. Twenty-eight scored-evidence tests and five shot-helper tests pass.
The socket-discovery guard was mutation-watched: restoring an implicit `find`
path failed the named test, then the explicit refusal was restored.

This is a **tested tooling checkpoint**, not a direct sweep. The operator still
has to create the identity artifact from the pinned live session, and a scored
row still needs native Mirror keyboard/mouse input, Mirror pixels, state,
operation settlement, both logs, stable generations, and human visual review.
The retained VM and Mirror were not touched.

### STATE ENGINE U4E: OVERWRITTEN CONTENT RETAINS THE LAST SETTLED DISPLAY (2026-08-04)

The content plane no longer clears a window's settled display when the guest
draw ring resyncs or reports overwritten bytes. It discards only the incomplete
accumulator and records the current guest `displayEpoch`/`generation` as a
replacement floor. Further records from that damaged generation are ignored;
only a strictly newer guest-authored epoch or generation may build a
replacement, and bounded `more` pages still cannot publish half a repaint.

All nine content-plane tests pass. The guard was mutation-watched by restoring
the old `settledOperations.removeAll()` transition: the retained-display test
failed at the resync and same-generation assertions, then passed after the
clear was removed again. This is the code-path repair for the C26 Workshop
blanking report, but it is only **tested**, not yet directly re-driven in the
native Mirror or compared with the guest. That row remains red until the full
sanity preflight and Workshop visual comparison are run on the new build.

### STATE ENGINE U4F: INACTIVE WINDOW CONTENT IS RETAINED, RUNTIME RECHECK OPEN (2026-08-04)

The first direct-input sweep of the U4E build reproduced a second destructive
transition that its ring-overwrite test did not cover. Selecting New Old World
left the Finder window visible but produced a frontless structural observation;
`NOWMirrorContentPlane.join` treated that bounded absence as a deletion and
cleared every settled display. Retargeting another front window also discarded
the accumulator identity used to find the last settled display. The Mirror
therefore oscillated between the Finder's 106 structured draw operations and a
five-operation `Bitmap unavailable` shell.

The content plane now records the last published identity separately from the
in-progress identity for each exact guest process/window slot. Frontless and
retarget observations retain compatible published content as expected-stale;
partial replacement pages keep drawing the settled display until the newer
guest epoch/generation finishes. Retention remains session-bounded and
`guestChanged` still clears it atomically.

Ten content-plane tests and all 21 Mirror-source tests pass. A mutation that
cleared the published identity on a frontless observation made
`testFrontlessObservationRetainsInactiveWindowDisplay` fail with a missing
display, then the correct transition was restored. This checkpoint remains
**tested, not emulator-verified** until the rebuilt host is directly driven
through the complete preflight.

That sweep also recorded action reds rather than hiding them: the Apple menu
and native Application menu rows rendered correctly; selecting New Old World
correctly activated only the application because its Workshop window was
closed, while `Windows > Workshop` failed to reopen it; clicking the inactive
Finder window was refused because the running guest accepted no `select`
window act; Hide Finder and Date & Time open were dispatched but did not
visibly settle. The source tree already carries `winact select`, so the
guest/build mismatch must be resolved by staging and proving the exact latest
extension and guest before treating those runtime results as current
implementation failures.

### STATE ENGINE U4G: ALL FOUR PLANES ARE RETAINED; LIVE REPROJECTION OPEN (2026-08-04)

Plane policy is no longer a destructive filter at the renderer adapters. The
session-pinned engine retains P1 structure in its replica, P2 semantics per
exact process/window/control or dialog-item identity, P3 content per exact
window identity and geometry, and P4 operation history in the same engine's
bounded journal. P1 cannot be disabled. Hiding P2 or P3 recomposes the current
snapshot without those contributions; showing either immediately restores the
cached contribution at the same guest sequence. Disabling P4 still gates
mutation, but policy changes cannot erase previously recorded attempts or
settlements. Evidence arriving while an optional plane is hidden is retained
for the next composition rather than discarded.

Cross-generation QuickDraw retention now belongs to the state owner rather
than `NOWMirrorContentPlane`. The adapter publishes only the newest settled
guest generation. If that generation is bitmap-only, the engine keeps
compatible prior non-bitmap operations—including their QuickDraw `state`
records—as expected-stale structured evidence. This addresses the observed
Sherlock transition where structured controls appeared briefly and were then
replaced by a CopyBits-unavailable overlay; it does not make bitmap pixels part
of the product path or turn Sherlock green by itself.

The focused state-engine, plane-domain, content-plane, and source suites pass.
Two guards were mutation-watched: dropping retained `state` operations fails
the structured-content test, and failing to cancel an old policy-refresh
sleeper fails the single-poll-cadence test. This remains **tested, not
emulator-verified** until the newly built host is directly driven through the
full sanity preflight, its live toggles are exercised, and every assessment is
paired with the authoritative guest capture.

The shipping review caught two lifecycle races before this checkpoint. A
pre-close scene completion could be accepted by a same-guest restart, and a
policy toggle could begin another structural request after scene transfer but
before that scene's content command settled. One run generation now invalidates
late callbacks, one cycle token covers scene plus content, and toggles made in
flight coalesce into one immediate follow-up. Policy lookup is also keyed by
the Mirror's pinned `GuestKey`, so changing the selected Mac cannot reproject
another session. The source tests now hold real scene/content completions and
count requests instead of inspecting source strings. Both lifecycle guards
were mutation-watched; the four focused suites pass 62 tests.

The first direct run of `ccf68a0` is recorded in
`docs/mirror-retained-planes-checkpoint-2026-08-04.md`. P2 and P3 live
reprojection behaved as designed: P3 could be hidden while P1/P2 remained,
P2 could be hidden while retained QuickDraw content remained, and restoring
P2 immediately restored the same semantic generation. The complete sanity
preflight is still red. Finder and Control Panels content arrived only after a
later polling cycle; Hide Finder remained unconfirmed; Date & Time's Finder
item was absent and therefore not actionable from the Mirror; Key Caps did not
launch; and Sherlock's structured content was again overwritten by a later
bitmap-only/invert observation. The last result is direct evidence that the
production renderer path still bypasses or obscures the engine retention that
the focused guard proves. Status is now **host-tested and partially
emulator-observed, not a green sweep and not metal-verified**.

The same sweep exposed a separate outcome-classification defect. Several
actions whose effects later appeared in authoritative pixels or scenes kept an
immediate `act-refused`, `outcome-unknown`, or
`dispatched-but-unconfirmed` label. A transport or resident-act answer is
attempt evidence, not the terminal verdict for the person's composite
operation. A refusal before any dispatch remains terminal; once any part of an
operation may have reached the guest, the operation stays non-green and
eligible for later same-session postcondition evidence. A later complete
authoritative observation may confirm that same operation; it must not erase
the earlier contradictory evidence or be attributed across another queued
operation.

### STATE ENGINE U6A: DIRECT OPERATIONS ARE SERIALIZED; CURRENT VM LACKS LIVE IDENTITY PROOF (2026-08-04)

The first direct-mutation state-engine slice is built and focused-tested. One
session-pinned FIFO now owns modeled native gestures and does not dispatch the
next gesture until the active one confirms or times out. Its operation journal
keeps displayed snapshot/sequence, exact entity, typed postcondition, attempt
reply, and later authoritative outcome separate. A post-dispatch
`act-refused` is therefore contradictory attempt evidence rather than a false
terminal verdict. Late complete scene evidence may confirm it; timeout remains
non-green and can later confirm only while no active retry makes attribution
ambiguous.

The direct run also exposed an unsafe bridge that is now closed. The running VM
can supply a compatibility scene that is drawable while the new replica cannot
mint stable identities for its windows/processes. The initial U6 code quietly
fell back to the legacy dispatcher in that case, recreating the raw
`act-refused` labels the broker was meant to replace. Modeled plans now refuse
before dispatch when identity is unavailable. The VM must be updated with the
current guest and extension before positive broker settlement can be scored.

After correcting two missed Computer Use targets, the live results were:

- Finder was selected first; the exposed `System Folder` title bar resolved to
  that exact second Finder window, but the stale guest refused `winact select`
  and the window did not come front.
- Selecting `New Old World` through the guest Application menu activated NOW
  and did not reopen its closed Workshop, which is correct.
- `Windows > Workshop` is the independent failing operation. It must create a
  named NOW window; the current guest does not call `MenuSelect`, so it remains
  red rather than borrowing success from application activation.

The focused gate currently covers FIFO serialization, contradictory refusal
then confirmation, timeout and late confirmation, same-postcondition retry
ambiguity, exact same-app window identity, Workshop named-window creation, and
the no-legacy-bypass rule. Mutation-checking removal of the FIFO guard made the
two-click test fail. This checkpoint is **tested and directly characterized,
not a green emulator sweep and not metal-verified**.

## CONTRACT FROZEN; UNIFICATION IMPLEMENTATION STILL OPEN (2026-08-03)

The unified NOW Extension prerequisite now starts from a source-derived
retirement ledger rather than the claim that AXPeek/QDPeek/Portal parity can be
remembered. The ordinary native guard derives 66 capability keys from the old
resident shared headers, agent dispatch, service, and staging paths. Each key
has a goal-facing outcome, allowed disposition, and one prerequisite proof
owner. Goal-relevant rows cannot close as a bounded refusal, retained fixture,
or retirement blocker. The older fold roadmap is historical; Mirror completion
plan 001 is blocked until the prerequisite completes and now retains only the
broker, broad renderer/UX, MCP, and later pixel work.

The scored-row gate also now enforces the full correlated evidence boundary.
A pass/fail needs native NOW Mirror keyboard/mouse provenance, Mirror pixels and
snapshot identity, a QMP observation capture within two seconds, decoded state,
plane state, terminal operation settlement, both host and guest logs, no
nonterminal operation, two unchanged pre-capture generation polls, and an
unchanged post-capture generation/owner-epoch reread. The previous gate was
watched accepting manifests without the new plane/settlement/log/quiescence
members; the focused test then failed seven cases before the validator changed.

This is **contract and guard work only**. No resident plane has been unified by
this entry, the focused corpus has not passed, and the development VM has not
yet been replaced with the final exact extension/application pair. Workshop and
menubar geometry remain the regression floor; Apple content, Finder/Date & Time
foreign content, direct controls, and truthful settlement remain red until the
direct-input paired sweep proves them.

### U2 source boundary implemented; resident runtime proof still open

The appended resident ABI now carries deterministic source and embedded build
identities, one canonical New Old World writer lease, named per-capability
owners, extension echo of the accepted owner epoch, and P1 cadence counters.
Content, interaction, scene, and Processes use the same owner union; the
Processes renewal is intentionally in its cooperative `idle()` callback, not
its repaint callback. Native layout, lease, resident-core, and guard tests pass,
and both guest applications plus the extension cross-build with the real
Retro68 toolchains.

That is **tested at the native/source boundary and builds, not emulator-
verified**. The generated INIT payload is about 59 KiB, above the INIT skill's
conservative 32 KiB audit budget (the preceding extension was already in this
size class and loaded on Mac OS 9). A disposable cold boot must still prove the
new exact `NWid` fingerprint, table identity, writer handoff, callback chaining,
and six-tick counters before any runtime row turns green. The stage image still
contains the older resident and must not be used as evidence for this build.

### U3 ABI checkpoint only; semantic resolvers remain red

The R11 evidence review is now durable in `docs/p2-semantic-evidence.md`. It
rejects every fact the bounded P1 reader already proves, rejects non-dialog
TextEdit from v1 because no documented safe root exists, and fixes a 32-record
envelope large enough for the measured 16-row Finder Apple menu. The table has
an appended exact-target P2 cell, explicit refusal/truncation states, and a
volatile generation-checked application copy. Mutation fixtures cover short
tables, stale/wrong identity, partial publication, overflow, resolver-kind
mismatch, and dishonest text completeness.

This is an **incomplete checkpoint**, not P2 behavior. NOW Extension does not
advertise or arm P2 yet. Invalid-handle-safe Control/Resource/List/Menu Manager
resolvers, request publication, scene joining, disabled-P2 degradation, and
the direct Date & Time/Apple UX proof all remain red. The ABI's ability to
represent those facts is not evidence that the guest has produced them.

**Update 2026-08-03: bounded partial P2 behavior is implemented, but the UX
rows remain red.** NOW Extension now advertises the plane and serves exact
standard List Manager state plus exact nonempty menu rows. The application
publishes at most one request per scene, joins only an owner/scene/object match,
retains bounded terminal facts across scenes, and resets them on owner change or
scene regression. Mirror renders a standard list as an explicitly partial,
selected-value-only list surface; it does not invent the unretained rows.
Native mutation fixtures and the real PPC, 68K, and flat-INIT cross-builds cover
this slice.

The Mac OS 9 system-root Apple submenu is still broken. The flat 68K INIT
cannot link the CarbonLib/CFM root-menu calls that expose the child behind the
empty Apple shell, and no undocumented trap or unproven Mixed Mode bridge was
substituted. That exact shell therefore returns `unsupported`. Direct Mirror
input against Date & Time and the Apple menu has not yet proved this partial
plane in the running guest, so neither case is green. The development stage
image also still contains the preceding resident build.

### U4 P3 lifecycle and coherent-redraw path built; runtime proof still red

P3 format v2 now arms one exact A5/window identity instead of every window in
a process. Every retained record carries the echoed PSN, exact A5 and port,
request generation, and resident display epoch. A retarget clears the old live
commit before rewriting any identity word; same-context target changes restore
only a still-live hook that NOW still owns, while dead or foreign-context rows
are forgotten by value and remain strict pass-through. The host joins only the
currently armed front window and rejects old process, window, generation, A5,
or display-epoch records, so pointer reuse cannot overlay a relaunched target.

After installing its exact hook, the resident requests one ordinary update and
does not call the application's draw handler itself. `InvalWindowRect` cannot
link into a flat 68K INIT, so this path uses the classic equivalent inside the
resident only: prove exact WindowList membership and hook ownership, save the
current port, set the target window port, call `InvalRect`, and restore the
saved port. It reports `redrawRequested` only after that sequence and
`redrawServiced` only after a later guest QuickDraw hook. A source-order guard
forbids `BeginUpdate`, `EndUpdate`, direct drawing, CopyBits, or event injection
in the shim.
The Carbon UI lexical audit flags `InvalRect`; that finding is expected for this
flat-INIT compatibility boundary, not waived for Carbon application source.

Native lifecycle/ring tests, the host/MirrorKit join tests, and the actual PPC
application and flat-68K extension cross-builds pass. This is **tested and
builds, not emulator-verified**. No guest has yet proved that a foreign Date &
Time window services the requested update, that target death/relaunch remains
safe at runtime, or that the resulting initial display is coherent. Bitmap and
CopyBits operations still carry only bounded geometry and render as explicit
`Bitmap unavailable` placeholders; no pixel transport was added. The stage
image still contains the preceding extension.

The U4 cross-build produced a 63,978-byte `INIT 128` (64,386-byte resource
fork), so the resident still exceeds the conservative 32 KiB inspection budget
and runtime loading remains a required gate. Its artifact SHA-256 is
`1b5ad7638477d974e71d6852d61ff428ea797d1690a3f4f1dd2b7f72264f9e11`;
the embedded source manifest is `ffe26237 08404b43 c9ae73ce c44e25aa
bb1c11a3` and build fingerprint is `707560f7 d034f202 a01a4a83 faa2c1c4
576c0239`.

### U5 P4 settlement is effect-owned; focused runtime proof remains red

P4 format v2 is appended after the original act cell, so the V1 act bytes and
every P1-P3 offset remain fixed. A request now carries one correlation,
canonical-writer epoch, exact A5 and PSN echo, source scene generation, typed
operation/object identity, and deadline. The resident may advance only its
monotonic requested/accepted/armed/fired/refused/expired evidence for that
tuple. PSN is correlation rather than resident authority: the foreign-context
safety boundary remains the exact A5 plus the operation-specific object guard.

That evidence is deliberately not the outcome. New Old World owns a bounded
16-record settlement history and reconciles a fired action against a later
normal-context scene and an operation-specific postcondition. Timeout remains
recorded if a later scene confirms the effect; writer replacement terminates
open records as session-changed. The host joins by correlation and renders a
checkmark only for `confirmed`. Refused, timed-out, session-changed, unknown,
and dispatched-but-unconfirmed remain visibly non-green. Successful keyboard,
typed-text, and Finder dispatches without a postcondition are explicitly
unconfirmed; activation requires the guest's own front-process reread, and
application visibility requires a Finder visibility reread. Menu acts require
the unique front PSN from the same scene rather than guessing the current app.

Native guard/settlement tests pass 100/100. The final host tree passes 1,289
tests with 54 opt-in skips; focused settlement presentation passes 17/17. The
real PPC, NOW-68K, and flat-INIT cross-builds pass. The final U5 extension is a
64,994-byte `INIT 128` in a 65,402-byte resource fork (65,536-byte MacBinary),
SHA-256
`76439badc2ef9499502592c4a3b533e657a768a6c7d89772a76e9bc36758fa7c`.
Its source manifest is `0fc7296f 1fd60fa0 4e7e5b68 b4a60944 a6174813` and
embedded build fingerprint is `b1e5890e 8cba499f 25c092c9 45d9e7c1
f54951b3`.

This is **tested and builds, not emulator-verified**. No direct-input sweep has
yet proved a menu, standard list, Date & Time Cancel, application visibility,
or window operation against its paired guest pixels and settlement. Operation
families without a stated postcondition honestly remain dispatched-but-
unconfirmed until that focused proof supplies one. The development stage image
still contains an older application/extension pair and is not evidence for U5.

### U6 one-extension lifecycle and plane policy built; runtime proof remains red

The wire contract is revision 2 and the PowerPC `mirror` command now reports a
schema-1 snapshot of only NOW Extension: exact lifecycle and build identity,
resident capability/request/active bits, heartbeat freshness, and one row for
each of Structure, Semantics, Content, and Interaction. The guest Console and
read-only Workshop use the same probe. The host decodes that object into one
plane domain, persists only optional-plane policy for an anchored machine,
keeps unanchored emulator policy session-local, and presents one native
Open/Close Mirror surface. No active UI asks for AXPeek, QDPeek, Portal,
`mirror-agent`, forwarded port 1420, QMP, or an external Mirror binary.

Policy now reaches named claims rather than stopping at toggles. Scene requests
carry the Semantics choice; Content off sends the bounded stop and retains an
explicit refusal if release fails; Interaction off refuses before dispatch and
logs the refusal. Structure is always required. Unsupported, enabled but
inactive, requested, refused, degraded, stale and active are distinct; an
actual resident-requested row degrades after five seconds without activation,
while a closed Mirror's legitimately inactive planes do not start that timer.
P1/P2/P4 claims stop renewing on close and expire through their ten-second
resident lease; P3 is released explicitly because its lease is much longer.

Focused native JSON/layout/lease tests and host domain/content/contract tests
pass, and the PowerPC guest, NOW-68K guest, and flat 68K extension cross-build
with the real Retro68 toolchains. One complete `scripts/test-all` run passed,
but two immediate primary-agent reruns exposed an unrelated nondeterministic
host-gate red: local guest-listener tests timed out waiting for loopback
connections in different cases (6 failures, then 8), while every named failure
passed when filtered and rerun alone. A stale C26 host process that had held
port 5250 since 20:25 was terminated before the second aggregate rerun, so that
process was real contention but does not explain the remaining suite-level
instability. Treat the focused U6 behavior as **tested and building** and the
aggregate host gate as unresolved red until a clean rerun is repeatable. This
is not emulator-verified. The revision-2 app/extension pair is not installed in the
development image, no direct keyboard/mouse Mirror sweep has compared its
pixels and mutations with a paired guest capture, and no metal claim is made.
U7 still owns runtime/staging retirement and the cleanly shut-down updated VM;
the old compatibility implementation remains internal seed material until
that slice, guarded from the active product UI.

## CYCLE 25 RED; SETUP CORRECTED BEFORE C26 (2026-08-03)

Cycle 25 directly re-ran the sanity preflight through the uniquely identified
C25 native host. Workshop resize and close both mutated the guest; their act
log rows answered `now-window-act-outcome-unknown`, while the paired guest
frames proved the operations landed. The Macintosh HD double-click likewise
dispatched and opened the guest Finder window.

Two real defects survived the sweep. Apple still opened a correctly placed but
empty dropdown, so resolving the empty low-memory shell only through
`GetMenuItemHierarchicalMenu` was insufficient. The next patch also checks the
installed menu with the same measured ID and the root item's hierarchical ID;
it remains red until C26 watches the rows. Separately, a locally synthesised
app-only selector still appeared whenever the guest Application menu was
absent. It collided with the native menu and necessarily dropped Hide, Hide
Others, and Show All. The custom dropdown, hit target, hover state, and action
route are now removed. Only guest menu `-16489` may open or act; missing menu
state is inert rather than replaced with a second control.

The sweep also made a setup error explicit. The extension *file* was staged,
but the running system had never cold-booted it. The first Mirror frame said
`content-plane-absent`, and the live act log later said "the NOW Extension is
not installed". The earlier carry-forward assumption that an old resident was
loaded was wrong. Therefore the missing foreign Finder and Date & Time windows
and menus in C25 are **not an implementation verdict**: foreign scene
collection was being tested without its resident plane.

The corrected local oracle is
`~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`. It contains the verified
`NOW Extension` and current `New Old World`, was stopped by a human-performed
guest shutdown (the exact QEMU PID exited on its own), and passed `qemu-img
check` before and after preservation. Its SHA-256 at creation was
`c466baa9a5455c343908e12197d68e57ffc7f07c140276a90c97a5ae2a137d70`.
(Re-verified 2026-08-06 with `tools/volclean.py`: its volume really is
cleanly unmounted, which the three images baked that night were not — see
the correction below. It is once again the installed oracle.)
Future extension changes must update and cleanly shut down this stage image
before a Mirror sweep; merely copying a new INIT into a running clone does not
change the resident code under test.

**That rule went unfollowed for three days, and is now enforced
(2026-08-06).** On 6 August the image on disk was still the 3 August one
while six extension commits had landed that day — the re-armed liveness
Time Manager vehicle, its ABI shim, the MacTCP `.IPP` probe. Every session
cloned the stale image, staged a fresh build into a throwaway clone and
discarded the clone, which is exactly the mistake the paragraph above
names. The rule was written and nothing checked it, so the *verified*
oracle went stale in silence: any sweep started from an old resident with
no warning, and a green sweep would have said nothing about the code
anybody was working on.

The gate is now three pieces, and the sequence a resident change follows:

- `scripts/bake-ext-image` — clone the oracle, stage this checkout's ext
  and app, cold boot so the INIT loads, ask the **guest** `mirror` and
  require lifecycle `active`, the expected capability word and a
  `buildFingerprint` equal to the local build's, then a guest-clean
  shutdown (`tools/shutdown-guest.py`, never a QMP `quit`), `qemu-img
  check`, `.bak-YYYYMMDD` of the old image, install, receipt. Any failure
  installs nothing and leaves the VM up. **Plus `tools/volclean.py` since
  the correction below — the container check was never evidence that the
  volume inside was unmounted, and three images were installed dirty
  before anything asked.**
- `ext/stage-receipts.json` — the repo-tracked receipts. Each bake records
  the source digest, the guest-reported fingerprint, the image sha256, the
  `qemu-img check` result, that the shutdown was guest-clean — and, since
  the correction below, `volumeClean`, which is the only one of them that
  answers whether the volume was actually unmounted.
- `tools/ext-bake-gate`, from `.githooks/pre-commit` — refuses any commit
  staging `ext/` or `contract/peek_table.h` unless the newest receipt is a
  bake of exactly that source. `TBT_DEFER_EXT_BAKE=1` with
  `TBT_DEFER_EXT_BAKE_REASON="…"` defers it and writes the reason into the
  receipts file, so a deferral lands as a written decision in the same
  commit as the work.

Two images were installed on 2026-08-06. The hand-run bake that found the
staleness produced sha256
`62be7be4d73a848f9d72818f42c879df7b4dfdfc83a18f6fdd2779529b297eae` and
preserved the 3 August one as `.bak-20260806`; the first run of
`scripts/bake-ext-image` then produced sha256
`46a51dcd0337baf3918a1fec6f2987bacbdf174d3dc28ffee61e04430bd5850c`,
keeping the previous as `.bak-20260806-2`. That image is the one
`ext/stage-receipts.json` certifies: the guest answered `mirror` with
lifecycle `active`, capabilities 63 and buildFingerprint
`bb95520ae51365c053f56d57d86bb10af09629c3`, shut itself down in three
seconds, and `qemu-img check` found no errors.

**Still stale for one branch, and this is the gate working rather than a
defect.** `claude/012-resident-transport` gives the resident its own
MacTCP connection and a sixth plane — capability word 127, not 63 — so the
image above does not contain that resident. The first commit touching
`ext/` on a branch carrying it will be refused until `scripts/bake-ext-image`
runs there, which is exactly the warning nobody got on 3–6 August.

### CORRECTION (2026-08-06): every image baked that night was DIRTY, and the receipts could not have known

Read the three paragraphs above with this attached. **All three images
baked on 6 August were installed with their HFS volume still marked
mounted**, so every clone of them opened with "Your computer did not shut
down properly" and a Disk First Aid pass. Measured with
`tools/volclean.py`, by sha256, on the files still on disk:

| image | sha256 | volume |
| --- | --- | --- |
| `.bak-20260806` — the 3 Aug one, human shutdown | `c466baa9…` | **CLEAN** |
| hand-run bake | `62be7be4…` | DIRTY |
| first `bake-ext-image` (caps 63) | `46a51dcd…` | DIRTY |
| second `bake-ext-image` (caps 127) | `0785871a…` | DIRTY |

The last two are the images the two receipts in `ext/stage-receipts.json`
certify, matched by their own recorded `imageSha256`. Both receipts say
`shutdown: guest-clean` and `qemuImgCheck: clean`.

**Both statements are true. Neither is the question.** `qemu-img check`
validates the qcow2 *container* and knows nothing about the Macintosh
filesystem inside it, so a volume the Mac will greet with Disk First Aid
passes it without a word. And the guest really did run its own shutdown
sequence — the Shutdown Manager quits applications *first* and flushes and
unmounts volumes *after*, so the anchor worker, an application, falls
silent while the volume is still being written. The rig then took the
process away five seconds later. Measured that night: **the disk image
kept changing for 49 seconds after the worker went quiet.** The sentence
above, "shut itself down in three seconds", was reporting how fast the rig
stopped watching.

The general lesson is the durable part, and it is bigger than this rig:
**a check adjacent to the question reads exactly like an answer to it.**
Two honest, passing checks sat where a third was needed, and nothing in
the receipt distinguished them — which is why `volumeClean` is a separate
field rather than a stricter reading of `qemuImgCheck`.

What changed:

- `tools/volclean.py` asks the volume itself: HFS's "volume unmounted"
  attribute bit, the very flag the Mac's startup check reads. It follows
  `drEmbedSigWord` into the embedded volume, because the HFS *wrapper*
  every OS 8.1+ HFS+ disk carries has its own flag that reads dirty on a
  perfectly clean machine — checking that one reported the human-verified
  3 August oracle as dirty, which is how the positive control earned its
  keep.
- `scripts/bake-ext-image` runs it and installs **nothing** when the
  volume is dirty. The container check stays, demoted to what it always
  was.
- The receipt gains `volumeClean` and `shutdownPath`;
  `tools/ext-bake-gate` requires the first. The two existing receipts are
  corrected in place with `volumeClean: dirty` and the reasoning, and the
  gate refuses a receipt carrying a correction.
- `tools/shutdown-guest.py` waits for the **disk** to stop changing rather
  than for the worker to go quiet. Necessary, and not sufficient: a
  shutdown waited out to full disk quiet still left the volume dirty.

**The oracle is repaired by restoring, not by re-baking.** The dirty image
was replaced with `.bak-20260806` (sha `c466baa9…`, verified CLEAN), kept
as `.bak-20260806-4-dirty`. That is the cheap fix and it is the right one,
because `scripts/spin-up-ppc` stages the current `ext/` and app into
whatever clone it makes and cold-boots so the INIT loads — **the resident
under test comes from the staging, not from the base image.** What a base
image has to be is *clean* and *furnished* (Rumpus, the anchor worker, the
folder layout), and that one is both.

Which means the framing higher up this section — "the oracle went stale" —
was itself imprecise, and the note belongs next to the gate: a bake
receipt proves that a resident was built, loaded by a cold boot, and
identified itself over the wire. That is a real and valuable proof, and it
is the one thing no amount of staging gives you. It does **not** prove
that a later sweep runs that resident, because staging replaces it anyway,
and it does not prove the base is clean unless `volumeClean` says so. The
gate is not weakened here — Michelle asked for it deliberately, and
"someone cold-booted this resident and it answered" is exactly the check
that was missing on 3–6 August. It is simply worth writing down that its
value is the *boot-and-answer*, not the *image*.

### The applet's shutdown does not finish; the Finder's does (2026-08-06)

`tools/guest-shutdown`'s applet calls `ShutDwnPower` and nothing else. It
reliably *starts* a shutdown. It does not finish one: on mac99 QEMU never
exits, and every image preserved after it — including ones waited out to
full disk quiet — has the volume still marked mounted.

**The Finder's own Special > Shut Down does finish it.** Driven through
the act plane's `menuact`, on a guest booted from the stage image: the
machine powered off, **QEMU exited on its own within 10 s**, and
`volclean.py` read the resulting image CLEAN. QEMU exiting by itself is
the machine really cutting power, which is the thing the applet path never
achieves — and it matches the one image anybody trusted, the 3 August one
a human shut down from the Finder.

This route had been recorded as impossible, and *why* is the more useful
finding. `menuact` **requires `serialHi`/`serialLo`** from the scene's
front process, because a menu bar belongs to one exact process and the
guest refuses rather than guess at whichever application happens to be
front. The probe that wrote the route off omitted them **and** sent the
act fire-and-forget, so the guest's `bad-request` — a perfectly good
refusal, naming its own cause — went into the void, and a null reading was
reported as a property of the mechanism. That is drive-loop rule 2e: a
null reading needs a positive control before the mechanism is blamed.
Supplying the serial and reading the reply was the entire fix; the machine
had been answering correctly all along.

`docs/mirror-knowledge.md` records upstream Mirror finding that
`ShutDwnStart`, `ShutDwnPower`, Finder Apple Events and embedded OSA all
failed to power off a mac99 OS 9 guest, and that posted clicks cannot
reproduce the Finder's held `MenuSelect` gesture — logged there as
"deferred, not solved". **That is now solved, and by a route upstream did
not have**: NOW's act plane does not post a click, it answers the
application's own `MenuSelect`, so the held-gesture problem does not
arise. `tools/shutdown-guest.py --wire <port>` takes the Finder route
first and keeps the applet as the fallback for a guest with no act plane;
`tools/guest-shutdown/probe_shutdown.py` is the bench that established it.

Still unverified: this was watched once, on one guest, on QEMU. Nobody has
run it on the PowerBook, and the applet fallback has no measurement
showing it *ever* produces a clean volume — only that it starts a
shutdown.

## CYCLE 24 RED BASELINE; FIX BUILT, NOT UX-VERIFIED (2026-08-03)

Cycle 24 was driven through the uniquely identified native C24 Mirror and
paired with QMP screendumps used only as the guest oracle. The restored
menubar geometry held: Apple, File, View, Windows, Help, the clock, and the
right-aligned Application menu matched the authoritative frame. The following
remained broken, and none is green merely because the subsequent patch builds:

- Apple opened a correctly placed but empty dropdown. The live low-memory
  MenuList supplies the system menu's measured identity and left edge, but its
  Apple MenuHandle carries no rows under CarbonLib. The patch now retains that
  identity/geometry and reads the corresponding submenu's rows from
  `AcquireRootMenu`; it needs a C25 native drive.
- Clicking bare desktop did not bring Finder forward. A NOW self-scene carries
  no Finder desktop-backdrop window, so desktop ownership resolved to nil. The
  patch falls back to the live Process Manager row with Finder signature
  `'MACS'`; it needs a C25 native drive.
- Hide New Old World did nothing. Hide, Hide Others, and Show All were generic
  menu commands even though menu -16489 is system-owned. They now resolve as
  typed visibility operations, preserve the guest's enabled/disabled state,
  and use the classic Finder on the guest. Each of the four switcher cases —
  Hide, Hide Others, Show All, and selecting another app — remains red until
  directly driven and compared in C25.
- Clicking NOW Workshop's close box resolved to the correct named window, then
  refused because the optional resident extension was absent. `winact` already
  had a direct self-window implementation, but an unconditional
  `now_act_ready()` check made it unreachable. The patch moves only self-window
  Window Manager acts ahead of that optional-plane gate; foreign windows and
  self controls still require their real application event path.
- Finder-front rendering remained a stale, disabled NOW Workshop with
  `content: no front window`. Workshop whole-frame fidelity also remains red.

The repository gate passes (90 native tests plus the host Debug/Release gate),
and an explicit Retro68 PowerPC Carbon cross-build passes. Mutation checks were
watched fail against the pre-patch self-window route and pre-preflight gate.
This is **tested, not emulator UX-verified and not metal-verified**.

Every future cycle now begins with a gate-enforced eight-step sanity preflight:
compare Workshop, compare the menubar, inspect Apple's real rows, resize and
close Workshop, double-click Macintosh HD, compare Finder, and hide Finder
through the native Application menu. Slice-specific work is currently Date &
Time. Every row is attempted before patching independent failures in a batch;
one red row does not erase coverage of later independent rows.

## WATCHED, FIDELITY STILL RED: Workshop reports its manually drawn structure (2026-08-03)

Cycle 19 paired the native Mirror with the authoritative guest and corrected an
earlier, too-narrow assessment: proper Control Manager chrome did not make the
Workshop render. Its entire 13-row sidebar, page header, explanatory text,
status line, and screenshot-page labels were absent. The bounded missing-content
placeholder was honest, but a nearly empty window is still red.

The Workshop now describes those manually drawn regions through the same scene
IR as controls: panels, placards, selection bands, separators, static text, and
bounded icon/picture placeholders carry `guest-workshop-model` provenance. The
host renders that structure from guest-authored data; it does not read or pipe
guest pixels. The Screenshots page also reports its current dimensions, depth,
streaming state, transport disclosure, and rate text. Actual icon and screenshot
art remains deliberately out of scope and visibly placeholder-backed.

Cycle 20 staged that build without rebooting the guest and drove the native
Mirror with Computer Use. A same-moment Mirror/QMP pair showed the structure
above while the resident content plane still reported absent. This proves the
fallback no longer depends on drawing capture: the empty/hatched Workshop
regression is fixed on the watched surface.

The whole-frame fidelity row is still red. Mirror showed Depth as numeric `4`
while the guest showed the selected popup title `8-bit`; it also overlapped the
preview placeholder text, and removed disabled controls when Finder was
frontmost instead of dimming them. Sidebar icon art remains a named placeholder
and is not scored while bitmap/picture work is out of scope. The popup-value
cause was in the guest producer: it looked only in the process menu list, while
the Appearance popup CDEF owns its MenuRef as control data. The producer now
asks `kControlPopupButtonMenuHandleTag` first and retains the old lookup as a
fallback. Cycle 21 watched the corrected Mirror value `8-bit` beside the same
guest value. Opening or choosing the popup remains red because the old resident
act plane was still absent; correct presentation is not evidence of mutation.

The same structural patch fixes the application switcher's asymmetric
geometry. The real guest menu title is correctly right-aligned even though Menu
Manager reports its nominal `left` as zero; its dropdown must therefore be
anchored to the right screen edge too. Ordinary menu hit spans now exclude that
special menu, and a missing Apple menu is synthesized independently. Cycle 20
watched the right switcher open at the right edge and switch Finder/New Old
World. It also proved the left Apple glyph was only a drawn fallback: clicking
it answered `nothing under the pointer`. An initial follow-up guessed menu id
128 from NOW's own resource convention. Cycle 21 disproved that guess live: the
Apple glyph remained inert. The preserved Aug 1 scene that produced the earlier
nearly faithful Mirror records Mac OS 9's system Apple menu as id 256. The self
scene now uses that measured system id so drawing, hit-testing, and MenuSelect
can share one guest object. It remains red until a later drive watches it open.

Cycle 20 also found that the synthesized switcher lists background-only
processes when Finder is frontmost. Choosing one refuses accurately as
`activate-background-only`, but those rows should not be offered by an
application switcher. The original switcher predicate already encoded the
data-driven distinction available here: frontmost, owns a visible window, or
owns the Finder desktop. The later unconditional process fallback caused this
regression. It is removed without a host signature allowlist; this remains red
until a later native drive watches the resulting roster.

## BUILT, NOT UX-VERIFIED: proven control roles survive the scene (2026-08-03)

The guest already derived exact roles for NOW-owned Control Manager controls,
including checkbox, radio, popup, group, progress, and disclosure controls.
`scene_json.c` then collapsed every proven role except scroll bars into
`pushButton`. The loss was in the producer, before Mirror rendered anything:
Workshop's checkboxes and Depth popup therefore arrived as authoritative
rounded buttons, and no renderer could recover the right kind honestly.

The scene now preserves each proven role, its applicable state or value, and
only the action that role advertises. Mirror draws those semantic kinds
directly; a v2 unknown no longer falls back to a title-and-geometry button
guess. CopyBits still carries no pixels by design, but its exact destination
now gets an explicit bounded placeholder instead of becoming unexplained
white space. Guest-native tests, the PPC cross-build, and offscreen render
tests pass. This is **not green** until a later drive clicks and types in the
native Mirror and compares the whole same-moment frame with the guest capture,
state, operation, and logs.

Update 2026-08-03, cycle 19: paired native frames confirmed the checkbox is
box-shaped, the disclosure triangle is visible, and the buttons retain button
chrome. The Depth popup still omitted its `8-bit` value, and the missing
Workshop structure made the whole-frame fidelity row fail. Those observations
are inputs to the patch above, not a green result.

## BROKEN: the staging reboot dirtied its own fresh clone (2026-08-03)

**Emulator-observed; deferred from the Mirror UX arc.** After
`tools/stage-ext.py`, the old `scripts/spin-up-ppc` sent QMP `quit`; the cold
boot of that same private clone then reported that the computer had not shut
down properly. “Fresh clone” described ownership, not cleanliness after a
host-side power cut. Later probes also found the current layers of both shared
OS 9 bases already presenting Disk First Aid before staging, so neither was a
valid oracle for proving a repaired stop path.

The first repair replaced `quit` with the parent `tools/shutdown-guest`, but
the live os91-runner Worker did not grant its required `script` verb. Its
hello advertised `click`, `key`, `type`, and `launch`; the Finder AppleScript
was correctly refused. Two posted clicks are not a fallback: the first opens
Special, then Finder is inside MenuSelect's tracking loop and the separately
posted second click does not complete the held menu gesture.

Several bounded guest-native probes were rejected: `ShutDwnStart`,
`ShutDwnPower`, Finder shutdown Apple Events, and an embedded OSA script did
not power the VM off; a 120-second observer left it intact. QMP power/eject
keys also failed, and relative-pointer capture was not a trustworthy held-menu
gesture. This remains **broken** and is explicitly punted until after the
Mirror's data-driven fidelity and direct-input loop are proven. Do not dismiss
Disk First Aid, and do not present QMP `quit` as a clean stop.

## WATCHED: the Workshop menu no longer overwrites the Apple slot (2026-08-03)

**Emulator-verified, not metal-verified.** The self-scene synthesized Help at
left coordinate zero. That is the Apple menu's slot, so NOW Mirror showed
Help over the left edge while the authoritative guest showed Apple, File,
View, Windows, Help. The scene now reads `MenuList.last_right`, and a fresh
paired live frame showed File, View, Windows, Help in the correct order.

This fixes one menu placement defect, not Workshop fidelity as a whole. The
live Mirror still lacks sidebar icon representations, draws several control
kinds with the wrong chrome, and defers CopyBits without a bounded
placeholder. The Workshop is no longer structurally empty; those whole-frame
mismatches remain red.

## WATCHED: a person drove the guest from NOW's mirror (2026-08-03)

**Emulator-verified.** Open Mirror on the Mirror page opens a NOW window
that renders the connected Mac and drives it. Watched, in the window, on
a live Power Mac G4:

| act | what happened |
|---|---|
| click a scroll arrow | the folder scrolled; status read "the lineDown of a scroll bar" |
| double-click a folder | it opened, BY NAME, and its window appeared |
| drag a title bar | the window moved to where it was dropped |
| pull a menu, pick a row | View → as List; the window changed to list view |
| press a key | "key e ✓" — the first keystroke ever to cross this wire |

None of it uses QMP, so all of it is shaped for metal.

### Objects first, which is what made the rest possible

A gesture now resolves to an OBJECT with identity — window, control,
menu row, app, Finder item, and the **desktop** — and the gesture rides
along as metadata the object interprets. Two things fall out that a
gesture-first model could not express:

- **An icon is reached by name.** NOW's contract has no click-at-a-point
  verb, so a desktop icon was previously unreachable by anything. As an
  object it is a file the Finder knows, and `select item "X" of desktop`
  works. Measured; so does `item "X" of window "T"`, while the
  remembered `target of window "T"` fails with osaErr -1753.
- **The point picks the part.** A press resolved as `.lineDown` of a
  scroll bar carries that, so no driver re-derives it from coordinates.

### Three defects the machine found that no gate could

- **Every number this host sent arrived as ZERO.** `CommandRequest.args`
  was `[String: String]`, so `part` crossed as `"21"`; the guest reads
  numbers with `strtol`, which stops at the quote. Measured on a live
  scroll bar: `21` moved it one line, `"21"` moved it somewhere else,
  and both replies said `dispatched`. Fixed on both sides — `CommandArg`
  carries a number as a number, and `now_json_read_int` distinguishes
  absent from present-and-unreadable so a quoted one is now a refusal
  that quotes the fix.
- **`key` was unreachable over the wire, always.** It read an argument
  called `name`; the guest scans a request FLAT, so it always got the
  envelope's own `"name": "key"` and refused every call as an unknown
  key name. The console face parses a typed line, so `key space` at the
  machine worked the whole time. Now `named`, and
  `arg_shadow_source_test.py` gates the whole class.
- **This Carbon guest cannot post a MODIFIED keystroke** and says so:
  `PPostEvent` is not in CarbonLib. So ⌘ menu items take the MenuSelect
  route, and `ActionPlanes.modifiedKeystrokes` records the difference
  rather than every shortcut failing quietly.

### Still open

- **Window interiors are empty.** The content plane (P3) has never
  captured a drawing op, so a document window is chrome around blank
  space. Finder windows are fine — their icons come from the Finder.
- **A scroll thumb cannot be dragged.** It needs a verb that SETS a
  control's value; `ctlact` presses a part at the control's own centre.
  Named as unsupported rather than approximated by paging, which would
  overshoot and read as a stutter.
- **No window raise.** `winact` serves move/resize/zoom/close; nothing
  selects one window among an application's own, so clicking a
  background window fronts its APP and the rest is the Finder's choice.
- **`role` is still a guess** (`min != max`), so About This Computer's
  memory bars are reported as scroll bars.
- **The process strip is drawn but not clickable.** `SceneRenderer` paints
  it at the bottom of the guest canvas, so its pixels are in GUEST
  coordinates and `HitTester` — which only knows what the scene
  contains — resolves a click there to whatever guest window is behind
  it. Switching applications works, through the Application menu at the
  top right (`appMenu` → `appMenuItem` → `activate`); the strip is the
  obvious-looking route and is the one that does nothing. Either it
  becomes a hit target or it should stop looking like one.

## The mirror NOW draws itself: built, gated, not yet WATCHED (2026-08-02)

**Unverified in the one way that counts.** "Open Mirror" on the Mirror
page opens a NOW window running Mirror's `LiveMirrorView` over
`NOWMirrorSource`, which polls `scene.request` and dispatches to the act
lane. Every link is proven against a live emulated Mac, separately:

| link | evidence |
|---|---|
| scene reaches the host | `NOWMirrorSource` is this host's FIRST caller of `requestScene` |
| it decodes as IR v1 | `SceneIRDecodeTests`, against a captured fixture |
| it draws | `SceneRenderTests`, and a person looked at the PNG |
| a pixel finds the right element | `SceneHitTestTests` (round trip) |
| the document agrees with the screen | `mirror-geometry-probe.py`, real QMP click |
| the act moves the machine | `act-parts-probe.py`, 60→156→60 by part code |

**Nobody has opened the window and clicked in it.** That is the gap, and
it is deliberately the human's: this side cannot screenshot the host
app's own window (mirror/CLAUDE.md), so the assembled product is judged
by a person or not at all. Both build systems compile it, Debug and
Release, which is a different and weaker claim.

### Known gaps in what it can drive

- **No positional click.** NOW's contract has no click-at-a-point verb
  (`asyncapi.yaml:3294`, deliberate). So a click on bare desktop, on a
  desktop icon, or in bare window content is a NAMED refusal rather than
  an act. Controls, menus, windows and keys all work; the Finder's icons
  do not, and that is the largest hole in "drive the Mac".
- **Interiors are empty.** The content plane (P3) has still never
  captured a drawing op, so windows render as chrome around blank space.
  The renderer is ready for it (`MirrorKitUI.DisplayReplay`); the guest
  side has never been armed in anger.
- **A raise is missing.** `winact` serves move/resize/zoom/close but
  nothing selects one window among an application's own, so a title-bar
  click still falls back to a QMP press — emulator only. This is stated
  in `MirrorAction.WindowAct` rather than invented.
- **`role` is a guess.** Derived from `min != max`, so About This
  Computer's memory bar graphs are reported as scrollbars and a click
  there asks a bar graph to scroll. The honest derivation needs the
  control's defProc, which the walk does not read.

## FIXED: the mirror could not have clicked, and no gate could see it (2026-08-02)

**Fixed on the guest, gated on the host, TESTED — not metal-verified.**

NOW's scene emitted `windows[].controls[].rect` in **global** screen
coordinates. IR v1 documents that field as content-relative, Mirror's own
`SceneBuilder` subtracts the content origin to produce one, and
`MirrorKit.HitTester` subtracts it from a click before it compares. So
every control was hit-tested against a box displaced by its own window's
origin.

Nothing errors when that happens, which is the entire problem. Measured
on a live Finder: a point computed from the centre of one scrollbar in
About This Computer resolved to a **different control ninety pixels
away**, and a point at the centre of another resolved to the **desktop**.
The render looked correct throughout — the same picture a person would
call working.

This is the cause underneath "The last functional gap: a person cannot
click the mirror" below. That entry described a chain with no join; this
is what the join would have been wired to had it existed, and it would
have mis-fired silently.

### Why nothing caught it

Both conventions are four honest integers, so:

- the decode gate passed (the document is structurally valid IR v1);
- the render gate passed (a displaced control still draws somewhere);
- the guest's own `scene_walk_test` **asserted the wrong space in so many
  words** — "a control's rect is translated to global coordinates" — and
  had done since the day it landed.

The only assertion that can hold this is one that names the space, so
there are now two:

- `now-guest-ppc/tests/scene_walk_test.c` — content-relative, stated,
  mutation-verified;
- `now-host/Tests/HostTests/SceneHitTestTests.swift` — a **round trip**:
  compute a control's own centre from the document, hit-test it, require
  the same control back. It cannot pass through a space mismatch. Run
  against the pre-fix fixture it fails naming both the control aimed at
  and what was hit instead.

### The second half, found by asking the machine

The control rects were only half of it. `windows[].rect` was the CONTENT
region, where IR v1 wants that region grown UP by a title bar — the
consumer recovers the content origin by adding the constant back, so a
producer that skips the growth puts every control in the window twenty
pixels low.

**The round-trip gate cannot see this one**, and that is worth
understanding rather than patching: it derives the click point from the
same rects it hit-tests, so an offset shared by both halves of the
document cancels exactly. It stayed green.

So `scripts/probes/mirror-geometry-probe.py` asks the Macintosh. It
computes the down arrow's position the way a renderer places it, delivers
a real hardware click there over QMP, and reads the control back:

    before   clicked (410,263)   value -4 -> -4    no change
             clicked (410,243)   value -4 -> 60    MOVED
    after    clicked (410,243)   value -4 -> 60    MOVED, downward
             clicked (410,263)   value 60 -> 60    no change

Its negative control displaces DOWNWARD, and passing requires the arrow
to scroll DOWN rather than merely to scroll. Both were learned in the
same hour: the first draft displaced upward into the page-up region,
watched the bar move for a legitimate reason, and reported inconclusive
on a build that was already correct.

### Still open

- `role` on a control is derived from `min != max`
  (`now-guest-ppc/src/scene/scene_json.c`), so About This Computer's
  **memory bar graphs are reported as scrollbars**. Harmless to render;
  it means `Scrollbar.part` computes arrow and thumb regions for a thing
  that has none, and a click there would ask a bar graph to scroll.
- The twenty-pixel title bar the two rectangles are related by is now
  stated in three places that share no header — `SceneBuilder
  .titleBarHeight`, the guest's `kNowSceneIRTitleBarHeight`, and the
  probe's own constant. The probe is what keeps them honest; there is no
  compile-time tie, and there cannot be one across a Swift package, a
  cross-compiled C guest and a Python instrument.
- The FALLBACK window path (`now_peek_windows_for_psn`, taken for the
  self process and for anything that does not bind) reports the
  STRUCTURE region, which is a third convention again. It has not been
  measured and no consumer has complained, because the windows that
  matter come from the bound path.
## UNVERIFIED: Hide has a route now, and nothing has watched it (2026-08-05)

**This amends an entry that is not in this file yet.** The branch this was
written on forked before "BROKEN: both Hide routes fail, each in its own
way" landed; when the two meet, fold this into that entry rather than
leaving two. What follows is written to stand alone either way.

**The route is real and it is the Process Manager's own.** `ShowHideProcess`
(selector `0x0060` under `_OSDispatch`, `$A88F`) and `IsProcessVisible`
(`0x005F`) — Universal Interfaces 3.4.1, **CarbonLib 1.5 and later**, and
our floor is 1.6, so they exist across the whole target range. The PowerPC
guest now serves them as one `hide` verb on both faces
(`hide [--show | --status] <name>`), and the contract declares it.

**Two things had to be true first, and each had closed this route once
before.** The headers on the toolchain's include path are Universal
Interfaces 3.4 and both calls arrived in 3.4.1, so the guest declares them
itself. And Retro68 ships **two CarbonLib import libraries that differ**:
the default `-lCarbonLib` resolves to
`toolchain/universal/libppc/libCarbonLib.a`, which does not export them,
while `toolchain/multiversal/libppc/libCarbonLib.a` (3.4.1-derived, byte
identical to Retro68's own `ImportLibraries/`) does. The earlier finding
that "the Process Manager's visibility call is absent from the toolchain
under any spelling" was measured against the archive that lacks it. **A
sweep of a toolchain is only as good as the copy it swept.**

**What is proven, and it is less than it sounds.** The verb cross-compiles;
its argument grammar and its outcome vocabulary are native-tested
(`proc_hide_args_test.c`); and the weak import is verified as far as the
build products — the two symbols appear in the guest's PEF loader section
as import class `0x82` (weak) inside a `0x40` (weak) CarbonLib entry, and
the generated PowerPC for the guard loads the TOC word CFM fills and
compares it against zero. Pointing the build at the archive without the
symbols still links, and produces a guest that answers `unavailable`
naming `ShowHideProcess` instead of one that will not build.

**What is NOT proven is whether Hide works.** No Macintosh, emulated or
metal, has been watched hiding anything. **Hide is UNBUILT in this ledger,
not fixed.** Two questions only a machine can answer are open:

- Whether `ShowHideProcess` accepts the FRONTMOST process. The Application
  menu hides the front application, so the Process Manager plainly can —
  but whether this entry point declines it is not known here.
- What it returns for the processes it is documented to decline, and
  whether a background-only application behaves differently. The verb
  reports the `OSErr` rather than swallowing it, so the first run answers
  this.

**One trap found while building it, worth more than the verb.** A CFM weak
import is checked by comparing the symbol's address against
`kUnresolvedCFragSymbolAddress` (zero) — and **GCC deletes that comparison
at `-O1` and above**, because a function designator is never null in
standard C. Read in the generated assembly: the guard simply was not there.
The address must be laundered through a `volatile` local so the compiler
must load the TOC word CFM actually wrote. Any other weak-import guard in
this tree written the obvious way is not a guard.

**Swept 2026-08-05, and there are none — this worry is closed, not
open.** `kUnresolvedCFragSymbolAddress` appears in exactly one file
(`proc_actions.c`, the guard above, correctly laundered), and no other
guest or extension source compares a Toolbox function's address against
zero or NULL by any spelling. So the rule stands as a rule for the NEXT
weak import rather than as a defect anyone still has to go and find. It
is worth re-running that sweep the first time a second weak import
appears, because the failure is silent in both directions: the guard
compiles, the tests pass, and the binary simply does not contain it.

## "Agent: Running" was true and useless (2026-08-02)

**Fixed on the guest, unverified on a machine.** Measured on a live
guest: NOW's Mirror page (`now-guest-ppc/src/mirror/`) reported the agent
Running — correctly, the process was there — while that agent was bound
to a stale port out of the base image's own `mirror.port`, so every
connection from a host Mirror instance hit a QEMU forward with nothing
behind it and was reset. **RUNNING and SERVING are different facts and
the page reported one of them.**

Mirror's agent learns its TCP port from a text file called `mirror.port`
sitting beside it, read once at launch
(`mirror/guest/app/src/main.c :: read_port`, reached through
`set_dir_to_app` — the file is beside the application and nowhere else).
So the port file is now a fact of its own: `mirror_probe.c` reads it out
of the same folder its catalog walk already resolves for the agent
binary, and `MirrorFacts` carries three separable things — the process
state, whether the file is there, and the port it names. The page has a
Port row; the State row distinguishes running-and-named from
running-with-nothing-naming-a-port; the placard carries the number.
Enable REFUSES rather than launching an agent whose port nothing here can
name, before `LaunchApplication`, because the alternative is this page
manufacturing the state it was corrected for.

**What it deliberately does NOT say is "serving nothing".** `read_port()`
falls back to a compiled-in 1420 when the file is absent, so an agent
launched without one does bind something. The honest complaint is that
the number is then a property of a binary nobody on this side can
inspect — which is also why Mirror's own stager writes the file rather
than leaning on that default. A page that replaced one confident wrong
sentence with another would have learned nothing.

**Three things it still cannot see, and two of them need a socket.** It
cannot report the port the RUNNING process actually bound: that was read
at *its* launch and only re-reading the file now is available here, so a
restage underneath a live agent shows the new number beside the old
process. It cannot say anything answers on that port — nothing in this
application opens a socket to Mirror. And the port fields are refreshed
by the probe, not by the idle poll, because a file opened every second on
the idle path is the starvation rule in
[guest-ui-start-here.md](guest-ui-start-here.md); a `mirror.port` staged
while the page is open is stale there until the next action.

**And NOW's staging now writes it.** `tools/stage-ext.py` grew an
optional Mirror bundle (`NOW_STAGE_MIRROR=1`, `NOW_MIRROR_DIR`): the
three INITs, the agent, and `mirror.port` written with `overwrite` and
`truncate` rather than inherited from the base image. Off by default —
Mirror is a separate application and three more residents is not a thing
to put on a guest nobody asked to. `scripts/spin-up-ppc` needs no flag;
it passes its environment through. Host-cc tested
(`mirror_layout_test.c`, `mirror_port_staging_source_test.py`, both
mutation-watched); **nothing in this entry has run on a machine.**

## BROKEN: the scene and `observe` disagree about the same machine (2026-08-02)

**Measured**, one machine, one moment, Finder in front, guest build
`88507f25a8b9`:

| asked | answer |
|---|---|
| `axsnap` | Finder `bind=ok`, `hasWindows=true`, a5 `0x1f50f550`, fresh stamp |
| `observe(front)` | Finder, window "Desktop", with a minted ref |
| **`scene.request`** | **one window, and it is NOW's OWN** — no Finder at all |
| Mirror agent's `axtree` | the front app's window with **ten controls**, plus Desktop |

The scene enumerates all nine processes correctly and marks the Finder
front, so enumeration is not the gap. The Finder's app row carries **no
error token**, meaning its anchor resolved — the scene admitted none of
its windows and said nothing about why.

**Two readers in the same binary disagree about the same process at the
same instant.** `observe` goes through `now_ax_bind_process` and sees the
window; the scene goes through `peek_read.c :: resolve` →
`now_peek_windows_for_psn` and sees nothing. The capability is present
and reachable — the scene is not using the path that works.

**Why this matters beyond the bug.** This was run as the go/no-go for
dropping Mirror's agent and integrating fully. It answers it: NOW's scene
is **not** structurally poorer than the agent's. It already carries the
front application's MENU BAR (eight menus, eighty items) which the
agent's `axtree` does not carry at all, and the windows it is missing are
readable by code in the same binary. The agent is not compensating for
something NOW cannot do.

**Two instrument gaps found on the way**, both worth closing with the
reader:

- The per-process anchor **verdict** is computed (`scene_collect.c` hands
  it to `now_scene_add_process`) and **never encoded**. A process that
  resolved fine and yielded no windows is indistinguishable from one that
  genuinely has none — which is exactly what this investigation spent its
  time on.
- `kNowSceneAnchorNoWindows` produces no error token by design. Right for
  a process with no windows; wrong here.

**Not the cause, but fixed while here:** the scene path never armed the
anchor plane at all. It does now.

## FIXED: the act plane now acts inside foreign applications (2026-08-02)

**The diagnosis below was right and the repair is in.** `act_install`
installed the six trap patches once, on the first armed pass, in
whichever process pumped first — always NOW's own application, because
it is the one serving the wire. The patches were then not in the
dispatch path anywhere else. `act_install` now runs on each armed pass,
and `install_patch` returns early when the incumbent is already its own
shim — which makes a repeat install a no-op under a system-wide trap
table and a real install under a per-context one, correct either way,
and forecloses the fatal version where the chain points at itself.

**Measured after the change**, emulated Power Mac G4, dev INIT staged as
"NOW Ext PerCtx" per the resident charter:

| | before | after |
|---|---|---|
| `actselftest` vs NOW's own app | abi-agreed | abi-agreed |
| `actselftest` vs the **Finder** | `act-no-patch` | **abi-agreed** |
| `actselftest` vs **SimpleText** | `act-no-patch` | **abi-agreed** |
| `menuact` File/New Folder in the Finder | `act-not-taken`, 0 folders | **8/8 folders on the Desktop** |

The folder is the oracle — a fact on disk the Finder created, not
anything a verb said about itself. **This is the first time NOW's act
plane has acted inside an application that is not its own.**

**A second defect the fix exposed, also repaired.** With the plane
working, `menuact` actuated 8/8 and *reported* `act-not-armed` 8/8: the
resident arms and queues the press in one pass, so the application can
dequeue, call the trap, and have the patch answer — setting `fired`,
clearing `armed` — before this side looks at its snapshot. Reading
`armed` alone called a completed request one that never armed. A false
negative in the worst direction, since a caller that retries gets a
second folder. All three sites (`winact`, `ctlact`, `menuact`) now ask
whether the request reached the machine at all: armed OR already fired.
Re-measured: **8/8 actuated, 8/8 replied ok.**

**And the guard was re-tested, because it had never really been.** The
menu no-hijack case was re-run on the same boot that had just driven
File/New Folder 8/8: **0/17 hijacks, 17/17 clean chain-through, 3
dropped** (a dropped trial is one whose QMP stimulus missed, measuring
nothing). That is the number comparable to upstream's 0/19. The earlier
0/20 is not, and is marked void in the ledger: it was taken when the
plane could not fire in that process at all, so a guard that held and a
plane that could do nothing looked identical.

## The diagnosis, kept: the act plane arms in a foreign app and its click is never taken (2026-08-02)

**Measured, emulated Power Mac G4, guest build `3c6be9ffa460`, both
resident families staged.** Against the Finder, addressed by PSN, with a
`titleLeft` the scene supplied, `menuact` answers:

> `act-not-taken: armed, and the application never called MenuSelect`

Read that carefully, because it is good news and bad news in one
sentence. **Armed** means the extension's filter runs inside the
Finder's context, the guard matched the target, and the plane posted its
own press. **Never called MenuSelect** means the Finder did not consume
that press. `actselftest` refuses against the same process in the same
pass, while abi-agreeing against NOW's own application minutes earlier
on the same build.

**Every click-driven act verb depends on this one step.** `menuact`,
`ctlact` and `winact` all work by queueing a `mouseDown`/`mouseUp` with
`PPostEvent` from inside the target's context and letting the
application's own event loop dequeue it, call `FindWindow`, and call the
trap the patch answers (`ext/src/now_ext_act.c :: act_post_click`, and
the comment above it explains why the press is queued there rather than
by the application). If the press is never dequeued, the whole family is
inert in foreign applications no matter how correct the patches are.

**It matches a finding that was never written down.** The overnight arc
of 2026-08-01 (`claude/mirror-parity-overnight`) measured the same
family at 0/10 and recorded that a `PPostEvent`'d `mouseDown` is never
delivered to any app on this guest while a `keyDown` from the same
resident context IS. That branch's note lives in no document; this entry
is where it now lives.

**What it invalidates.** The menu no-hijack case's **0/20** cannot be
read as "the guard held" — a guard that held and a plane that cannot act
in that process produce the same zero, and this measurement says the
second is happening. Upstream's number has no such ambiguity because
Portal measured 18/20 hijacks *before* its guard was fixed, proving it
could act there. See the parity ledger.

**ANSWERED, 2026-08-02, once the verb was made to report the plane's own
error instead of the status.** Four `actselftest` calls on one boot,
guest build `b77ba1c82e50`:

| | target | answer |
|---|---|---|
| A | NOW's own app | `abi-agreed` |
| B | the Finder, by PSN | **`act-no-patch`** |
| C | SimpleText, by PSN | **`act-no-patch`** |
| D | NOW's own app again | `abi-agreed` |

D is the discriminator and it rules out the "only the first request since
boot works" reading: A and D both agree, B and C both refuse. So this is
about **whose context the patch is asked to fire in**.

And `act-no-patch` locates it exactly. `cell->patches` is one field in
one shared table — the same value whichever process reads it — so if the
GUARD's `patches_present` check were failing it would fail for NOW's app
too, and it does not. The refusal therefore comes from the other place
that returns `kNowPeekActErrNoPatch`: `act_serve_selftest`'s
`if (!cell->fired)`. The resident called `MenuSelect(0,0)` **from its own
68K code, inside the Finder's and SimpleText's contexts, and its own
patch did not fire** — while the identical call inside NOW's application
fires and returns exactly what it wrote.

**The measured fact, stated without a mechanism:** the act plane's trap
patch intercepts `MenuSelect` in the process whose context installed it,
and not in others. The `why` is not established. The prime suspect is
`act_install`'s one-shot `static int installed` in
`ext/src/now_ext_act.c`: it installs the six patches on the FIRST armed
pass in whatever process happens to pump first — which is NOW's own
application in every run so far — and never again. If Mac OS 9's trap
dispatch is not as system-wide as a classic 68K machine's for this case,
a one-shot install is exactly the shape of bug that produces this table.

**The obvious experiment does not work, and why it does not is itself
evidence.** The plan was: from a fresh boot, arm while a FOREIGN
application is frontmost so the first armed pass happens in its context,
and see whether the answers invert. But `act_install` runs on the first
pass *of whatever process pumps*, and **NOW's own application is always
pumping** — it is the one serving the wire the request arrived on. So the
install lands in NOW's context by construction, on every boot, no matter
which application is in front. Fronting cannot move it.

That is not a dead end; it explains why the table always comes out this
way round, and it makes the one-shot a stronger suspect rather than a
weaker one. It also means **the repair and the confirmation are the same
change**: make the install per-context (or prove the patch genuinely
system-wide some other way) and the foreign-application answers should
change. Per the resident-components charter that is developed as a
throwaway dev INIT under its own name before it is folded in, because it
edits the one file whose failure mode is a machine that will not boot.

**Narrowed earlier the same day.** The test
was repeated against **SimpleText** — a plain classic application,
launched, frontmost, and bound by the anchor plane (`bind=ok`, fresh
`a5`) — and the result is identical: `menuact` answers `act-not-taken`,
and `actselftest` answers `act-refused`. So:

- **It is not Finder-specific.** It is general to foreign applications.
- **It is not only about the posted click.** `actselftest` requires NO
  event to be dequeued by anybody: the resident calls `MenuSelect`
  itself, in the target's own context, and checks whether its own patch
  answered (`act_serve_selftest`). That refuses in SimpleText and in the
  Finder, while abi-agreeing in NOW's own application on the same build.

Since the anchor plane demonstrably runs in those same foreign contexts
on the same event-loop pass (it captures their A5s), the sharper question
is no longer "why is the press not delivered" but **"why does the act
pass not SERVE in a foreign process when the anchor pass in the same
filter plainly runs there?"** Candidates worth reading in order:
`now_ext_act_apply`'s verdict path and the A5 comparison it makes;
whether the act arm bit is still set in `arm_request` at the moment the
foreign process pumps, or has been withdrawn by the requesting
application first; and whether `act_install`'s one-shot `static int
installed` interacts with which process armed first.

The event-delivery question is still real for `menuact` and remains
open — but it is now downstream of this one, and fixing it first would
prove nothing.

## The Mirror page is a lifecycle now, and NOW cannot see residency (2026-08-02)

**Landed, and the thing it cannot do is worth writing down.** The Mirror
module used to print the shell commands it was about to run and spawn
`swift run` / `spin-up.sh` against Mirror's OWN throwaway emulator
session — so a person with a Mac connected had no way to mirror THAT Mac,
and a failed launch said nothing about why. It is now a module page that
owns one Mirror instance pointed at the connected guest
(`MirrorControlModel`, `MirrorProduct`, `MirrorControlView`): a status
card, a lifecycle card, and settings. `MirrorLauncherModel`,
`MirrorLauncherView` and their suite are gone, along with
`NOW_MIRROR_PATH` and the remembered-checkout default.

**The gap: NOW cannot tell whether Mirror's INITs are RESIDENT.** The
obvious probe is `Gestalt('TBax')` — the selector each INIT publishes at
startup. NOW's `gestalt` verb takes no selector: `run_gestalt` gathers a
fixed set and slices it by group, and the census `selectors` probe walks
a closed documented list. Worse, an unknown argument on that verb is
IGNORED rather than refused, so a host that sent one would get `ok:true`
carrying every group and no evidence of the selector at all — which reads
as a yes, which is the worst answer available. The page therefore asks
`software.list` over the `extensions` domain, which sees the Extensions
Manager disabled folder too, and reports **installed / disabled /
missing**, saying plainly that an INIT loads at boot and that this side
cannot see what is resident.

**CLOSED on the guest side, 2026-08-02 — and the host still does not
read it.** The `mirror` verb landed: contract first, then the guest's
wire face (`commands.c` → `mirror_json.c`) and its console face
(`console_model.c`), both rendering the same `MirrorFacts` the page
draws. Measured on an emulated Power Mac G4 with all three staged:
`AXPeek resident v4, QDPeek resident v1, Portal resident v4`, agent
stopped, port named 1420 — the residency answer this entry says the host
cannot get. NOW-68K answers `unknown-command`, and that is the ANSWER
rather than a gap: Mirror's agent is PowerPC/CFM and its build refuses
the 68K toolchain outright, so the residents have nothing to serve there
(declared in contract-coverage.md).

**What is still open is the two READERS.** `MirrorControlModel` still
calls `software.list` over the `extensions` domain and reports
installed/disabled/missing, so the page a person looks at is still one
step short of the truth the machine now tells; and there is no projection
row, so no agent can ask either (declared `unnoticed` with its
disposition in mcp-coverage.md). The verb is served and nothing reads it
— which is the mirror image of the split this entry was written about,
and worth not leaving long.

**The original diagnosis, kept because it is still why the verb exists.**
The PowerPC guest's own Mirror page (`now-guest-ppc/src/mirror/`) calls
Gestalt for all three selectors and distinguishes absent / resident /
other-version — on its own screen only. That is the wire-only-versus-console-only split
this repository has been bitten by before, in the other direction, and it
is why the host has to infer from a folder listing what the machine
already measured. Closing it is a contract change: either a `mirror` verb
serving `MirrorFacts` (which the console face already has, so it is the
cheaper half of command parity) or an optional `selector` argument on
`gestalt`. Either way the contract moves first, then both guests' faces,
the host projection, contract-coverage.md and the exact-set projection
suites — and whether NOW-68K serves it is the parity question that
arrives with it.

**Never run against a real Mirror.** The suite uses fakes throughout —
nothing in this arc spawned MirrorApp, opened a socket to port 1420, or
saw the page on screen. Specifically unproven: whether the launch
invocation brings up a live window against a NOW guest; whether the
emulator forward default (1724) matches the rig a person is actually
running; whether `mirror-agent` is the name the agent's process wears in
the guest's own `process.list` (it is the name Mirror's source and
`spin-up.sh` use, read rather than observed); and whether SIGTERM
releases the agent's single client slot as cleanly as the code assumes.
## The host suite was fighting itself over ports (2026-08-02, settled 2026-08-05)

**It WAS contention — and the suite was manufacturing it.** For three
days a red `scripts/test-all` here was read as "something else is
running on this Mac", which was true and stopped the enquiry one step
too early: the something else was another session's copy of this same
suite, holding the product's own port because five of these tests take
it by accident and none gives it back. Alongside that, the tests were
hard-coding ports out of the range the kernel hands out, and abandoning
several hundred sockets a run. Three separate defects, all in the test
target, all now fixed — `swift test` is 1408 tests, 0 failures, and
51 s rather than 86.

**What was actually wrong.**

1. **Five tests were binding 5250 — the shipping port — and never
   letting go.** `SettingsModel` reads an ABSENT `listenAtLaunch` as
   true and an absent (or zero) `listenPort` as `defaultPort`, so a
   `HostAppState` built on a fresh `UserDefaults` suite starts
   listening during `init`. Four cases in `HostAppStateTests` and one
   in `GuestFilesCommandTests` only wanted the module list and got a
   live listener on the port a person's own NOW app holds. Watched
   directly: `lsof -nP -iTCP:5250 -sTCP:LISTEN` during those tests
   shows `xctest ... TCP *:5250 (LISTEN)` before the fix and nothing
   after. `UserDefaults.offTheWire()` states it once. It also makes
   `testHostCommandRegistrationDoesNotAddUIOrStartTheListener` mean
   something: it was asserting `.idle` on a listener that WAS starting
   and had not finished binding — an assertion that passed by winning a
   race.
2. **Four fixed ports sat inside the ephemeral range.** 52981, 52983
   and 52987 were each chosen as "a specific, unlikely-taken port", and
   all three are inside 49152–65535 — which is exactly where this same
   process is handed every port-0 listener and every dial. So the suite
   took those ports from itself, and `HostAppStateWiringTests`,
   `GuestStatusTests` and `ConnectionsModelTests` intermittently failed
   to bind with EADDRINUSE. They use port 0 and read the bound port
   back now. `HostAppStateWiringTests` is the one test that must name a
   port before it binds — it is the only one still proving
   listen-at-launch — and it uses a pid-keyed port outside the range.
3. **The fake guest let the kernel choose its source port.** macOS picks
   one by hashing the DESTINATION (RFC 6056), so one listener port is
   always offered one source port. A full run makes ~400 loopback dials
   and leaves ~150 of the sockets open — a test that stops its listener
   and drops its guest leaves one in CLOSE_WAIT for the life of the
   process — so when a later port-0 listener is handed a port that has
   been used before, the kernel proposes the source port that went with
   it, the 4-tuple already exists, and `connect` is refused.
   Network.framework does not FAIL such a connection: it parks it in
   `.waiting` and keeps it there, which at the test reads as a guest
   that never arrived. Measured with the state handler logging its
   endpoints: twelve dials in a row refused, every one from
   `127.0.0.1:55961` to `127.0.0.1:55963`. `FakeGuest` names its own
   source port now, from a per-process lane above 1024 and below the
   ephemeral floor, never repeating a number in a run — so no 4-tuple
   can repeat.

**What was wrong in the old entry, and is deleted.** "The suites bind
port 0, so this is not a simple port collision" — port 0 is what made
it one, because the ephemeral range is shared with every client socket
in the process. "A different subset fails on each run" (2026-08-02) and
"the SAME subset every run" (2026-08-05) were the same defect at two
machine loads, not two different signatures. The 2026-08-05 addendum
also guessed at "a shared listener, a per-user socket path, a
global/static, or a leaked task": there was a shared listener (5250),
but the agent socket was never implicated — `AgentIntegrationSocketTests`
already builds its endpoint under a unique temporary directory — and no
global or leaked task was involved.

**Found from the other end at the same time, and the two halves fit.**
A parallel session went looking for what was holding the machine rather
than for what the suite was doing, and found it: **check the PORT, not
the process name.**

```
lsof -nP -iTCP:5250 -sTCP:LISTEN
```

`ps | grep` for `New Old World`, `swift build`, `swift test` and
`xcodebuild` matches none of them, because a SwiftPM suite runs as a
bare `xctest` — so "nothing else is running" was never checked. `lsof`
found an `xctest` from ANOTHER WORKTREE's session holding 5250, and it
surfaced through `scripts/spin-up-ppc`, which now carries that check
and says so in one line. That is the host-side twin of
`MetalMachineGuard` this entry had been asking for.

**But that foreign `xctest` was holding 5250 BECAUSE of defect 1.** No
test asks for that port; five of them take it by accident, and none
gives it back. So "another session was running" and "the suite binds
the product's port" are one fact from two directions, and the reading
that the 2026-08-02 diagnosis therefore stands unchanged is too
generous to it: the contention was manufactured here. A second
`xctest` also explains the collisions in defect 3 far better than
anything inside one process does — two suites drawing from one
ephemeral range, each leaving ~150 sockets open.

**What is NOT proven, and it matters.** The five timeouts stopped
reproducing on this Mac partway through the investigation, with the
ORIGINAL code: a full run of the unfixed tests is green. The most
likely reason is simply that the other session's `xctest` finished. So
the before/after A/B that would settle it cannot be run any more.
Defect 1 is verified by observation
(the `lsof` above, watched by mutation: `xctest ... TCP *:5250
(LISTEN)` with the old code, nothing with the new). Defect 2 is
verified by the failures in the trace logs (`listener -> failed(...48...)`
on 52981 and 52983). Defect 3 rests on the captured port pairs plus a
fix that removes the mechanism by construction, NOT on a watched
before/after.

A reproduction was attempted and deleted rather than kept: building the
collision by hand — dial a listener, abandon the socket, put a new
listener back on that port — does not reproduce it, because the
kernel's source-port choice advances on every successful bind
elsewhere. A test that passes with and without the fix is worse than no
test, so there is no guard here. If the five ever come back, the way in
is `FakeGuest`'s state handler: log `state`, `currentPath?.localEndpoint`
and `remoteEndpoint`, and look for `.waiting(EADDRINUSE)`.

**The guard now exists** (`HostMachineGuardTests`, 2026-08-05). It is a
TEST rather than a line in `scripts/test-host`, because the person who
reproduced this ran `cd now-host && swift test`, which no script wraps
— a guard that only fires through the gate script is absent exactly
when somebody is narrowing a failure by hand. It fails naming the
process holding the wire port (watched by mutation: holding 5250 from
another process produces `python3.12 [pid 68233] *:5250 (LISTEN)` in
the failure text), takes `NOW_ALLOW_BUSY_MACHINE=1` to proceed and
label the result unattributable, and reports — without failing — any
other copy of this suite running beside it. It reuses
`MetalMachineGuard`'s `lsof` reader rather than adding a second one.

Adding it turned up a fourth instance of defect 1, the worst one: a
bare `AppDelegate()` builds its `HostAppState` on the PRODUCT's
preference domain, so eight tests were reading a person's own saved
settings and binding 5250 with them. `AppDelegate` takes an injectable
`defaults` now (shipping behaviour unchanged) and the tests use
`quietAppDelegate()`.

Two things this entry has taught twice, worth keeping whichever way you
come at it next time: a FIXED failing subset does not rule contention
out, so subset stability is not a signal to reason from; and the only
check that has ever given a straight answer is `lsof` on the port.

### Still open: two more things the suite shares across processes

Found on 2026-08-05 by running two suites at once — which is NOT what
`swift test` twice gives you, because SwiftPM locks `.build` and the
second invocation waits. Invoke `xctest` on the built bundle directly,
or run from two worktrees. Both of these are unfixed and neither is
about ports:

- **`HostLog.shared` is one file per LAUNCH SECOND, not per process.**
  Two runs starting in the same second share
  `now-logs/<yyyy-MM-dd HHmmss>.log` and read each other's lines:
  `HostProjectionAuditTests testTheEventReachesTheHostLogInTheSpecFormat`
  failed reading `a line worth keeping`, a string belonging to
  `HostLogTests` in the OTHER process, and `LoggingSpecTests
  testALineMatchesTheFormatTheSpecDefines` failed the same way. Two NOW
  apps launched together would do this too, so it is arguably a product
  defect and not only a test one; the fix (a pid in the name) is
  product-visible, which is why it is recorded rather than taken.
- **`CloudModuleModelTests testTheToggleRemembersAndRestoresTheShare`**
  fails across processes on a share path. Undiagnosed.

Both were measured with the fixes above already in: one of the two
concurrent runs was 1410 tests and fully green, the other carried these
three. An earlier reading of the same experiment also blamed
`HostServingTests testGuestCanSendAFileAndItLandsInTheShare`; that one
stopped recurring once `AppDelegate` stopped binding 5250, so it was a
knock-on and not its own defect.

## Photo sizes became long-edge stops; three metal defects fixed, none re-verified on metal (2026-08-02, latest)

**Unverified, deliberately labelled.** Metal feedback named three
things about the Photos save controls, and all three are fixed and
TESTED — nothing here has been looked at on the PowerBook since.

- **The Size caption overprinted the popup.** `view_draw` drew "Size"
  into `size_popup`'s own rect — a popup paints its value across the
  whole control, so the caption landed on top of it and read as
  garbage. The caption now has `CloudLayout.size_label` of its own, on
  the same row at the group box's left inset, the shape `dest_row` +
  `dest_btn` already used one line below. `cloud_layout_test.c`
  asserts `size_label.right <= size_popup.left` relationally, watched
  failing under a mutation that puts the caption back on the popup.
- **"Host default" is gone.** Every popup item now names a real size,
  and the host's configured setting arrives as data instead
  (`CloudReport.defaultSize`, additive) and is PRESELECTED. `cloud.get`
  from this guest always carries an explicit token.
- **The stops changed meaning.** `original` / `long640` / `long1024` /
  `long1600`, each naming the LONGEST edge (aspect preserved, never
  upscaling). The `fitN` fit boxes are **retired, not aliased** — see
  the contract's own `CloudGet.size` prose for why the graceful
  refusal is what let a deliberate semantic break skip a revision bump.

What only metal can settle:

- **The caption and popup side by side at 640x480.** The layout test
  proves they do not overlap in arithmetic; whether "Size" is legible
  beside a popup wearing "3024 x 4032" on a real 640-wide screen is a
  looking question, and the pane's inset clamp has never been seen.
- **A portrait photo actually arriving at 480x640.** The scale is
  proven twice off-machine (`PhotosProcessingTests` through the real
  CoreGraphics pipeline, `cloud_photo_size_test.c` for the guest's
  label arithmetic, both mutation-watched) but never against a real
  PHAsset with real EXIF orientation, which is the one input a
  fixture cannot fake honestly.
- **The preselect on a real report.** `defaultSize` riding the wire
  and moving the popup has run in no loopback test of the GUEST half
  — the guest's parser is unit-tested, the control mutation is not
  reachable from a host cc.
- **Whether anything still sends a retired token.** Nothing in this
  tree does; a stale build on the PowerBook would, and would get the
  named refusal rather than a wrong picture. Nobody has watched that
  refusal land in the guest's status line.

## RESOLVED: every modern classic-date field was silently dropped (2026-08-02)

### Fixed, tested — not yet re-verified on metal

Watched on metal 2026-08-02: the iCloud Photos list showed "--" in
Modified for every 2026 photo. Traced to `ClassicDate.guestWireSeconds`
(`now-host/Sources/Host/FileConverter.swift`), which stopped at
`Int32.max` — January 1972 in classic (1904-epoch) seconds — because
the deployed guest read the field with `strtol` into a signed 32-bit
`long`. Every date after that came back `nil` from the host function,
`modified` was omitted from the wire entirely, and the guest drew the
"unstated" dash instead. Not Photos-specific: `CloudServices.swift`,
`HostShare.swift` and `FilesModel.swift` all route through the same
function, so cloud listings and the drive/files browser carried the
same silent gap — every date after early 1972, on every listing
either guest reads.

A classic file date is actually **unsigned** seconds since 1904, good
to early 2040; the host's ceiling was simply wrong, not conservative.
Fix: the host stops clamping early (`guestWireSeconds` now just
forwards `macSeconds`'s own, correct, unsigned ceiling), and the guest
gained an unsigned reader to match — `now_json_find_u32`
(`now-guest-ppc/src/core/json.c`) and `now68k_json_find_u32`
(already existed on the 68K side for CRC32, just needed pointing at
this field) — used at every classic-seconds field either guest parses
off the wire: the PPC guest's cloud listing rows, browse/pull replies
(drive/files browser, `file.pull`), and both guests' `file.offer`
push.

A second, independent site carried the identical bug and is not
reached by `ClassicDate` at all: `GuestFileUploadCommands.begin`'s
own inline `modified <= Int32.max` clamp on the MCP agent-upload
path (a raw already-classic-seconds `Int`, not a `Date`). Found by
grepping `now-host/Sources` for `Int32.max` once the first site was
fixed. Two PRE-EXISTING host tests turned out to encode the bug as
correct behavior (asserting `.modified == nil` for a modern date) and
needed correcting alongside the fix — caught by running the full
host suite, not by writing new tests.

**Tested, nothing more; full account in
[icloud.md](icloud.md#every-modern-modified-date-silently-dropped-fixed-2026-08-02).**
Host XCTest and guest `json_native_test`/`cloud_model_test`/`test_putrx`
all pass, mutation-watched by hand. Nothing has run on the emulator or
the PowerBook since the fix — confirming a 2026 photo's Modified column
now draws a real date, rather than merely that the wire carries one, is
the next metal session's job.

## Drive's split-view pane has never run anywhere (2026-08-02, later still still)

**Unverified.** Drive stopped being the full-width flat list the
2026-08-01 entry below documents and went back to a list/detail split
— the SAME split every other iCloud view uses, not a second one
(`cloud_layout.c` computes one list/detail geometry and reuses it for
drive mode too, differing only in `list_top`, pushed down by the
breadcrumb row above it, and in the pane's own furniture below). The
destination row and Choose... moved off the old toolbar strip and
into the pane; the pull's moving bar and byte line moved there too,
reusing Photos' own `cloud_dl_bar_value`/`cloud_dl_bytes_line` idle
discipline against a different wire entry point
(`now_wire_get_active`, since Drive pulls through `now_wire_get_host`
rather than `cloud.get`); and the selected item's own name/kind/
size/date plus the double-click affordance line — which the
2026-08-01 review below moved onto the placard — moved back into the
pane, so the placard no longer changes on selection or on a pull's
byte count, only on durable folder/error/outcome news. No image
preview for drive files: a drive row carries no cloud item id, so a
later arc that wants one needs a real fetch-and-decode path, not this
pane's text — the seam is named in `cloud_drive_view.c`'s
`draw_item_card`.

`scripts/test-all` is green with each exit code read directly (79
native tests including `cloud_layout_test.c`'s rewritten, relational
drive-mode assertions — the old ones asserted full width and had to
change outright — both guest cross-builds, `swift test` at 1355
tests with 0 failures, `xcodebuild` Debug and Release), the new
layout assertions were watched failing via a deliberate mutation
before being trusted, and `audit_source.py` over both touched files
raised only already-reviewed lexical categories (the new
`SetControlValue` on the download bar is change-guarded, read back to
confirm). **None of this has run on the emulator or the PowerBook.**
The 2026-08-01 metal pass for Drive (below) predates every layout
Drive has worn since, including this one — what it proves is the
browsing logic (list, descend, Up, double-click fetch), not any pane
pixels. Before this can move past "tested": watch the split render at
640x480 and at a roomier size, select a folder and a file and confirm
the pane's text matches what the columns already say, start a pull
and watch the bar/byte line move in the pane while the placard stays
on the folder's own listing, and confirm Choose... still redirects a
pull's landing folder from its new position.

## The polish2 integration merged three UI arcs; the seam between them has never run (2026-08-02, later still)

**Unverified, and the specific claim is narrower than "the union is
untested."** `claude/polish2-drive-dest`, `claude/polish2-photos-cols`
and `claude/polish2-contacts` — each individually tested against the
shell as it existed on `claude/polish2-foundations` — merged onto
`claude/polish2-integration` with real conflicts in `cloud_module.c`
and `cloud_photos_view.c`, not just adjacent additions:

- **`cloud_module.c`**: `view_own_browser()`/`active_browser()`/
  `show_own_browser()` had to generalize from two view-owned browsers
  (Drive, Photos, from the drive-dest+photos-cols merge) to three
  (adding Contacts) rather than picking either side's flag check
  wholesale — a real design decision made at merge time, not a
  mechanical union.
- **`cloud_photos_view.c`**: photos-cols' own Data Browser (Name/Size/
  Modified columns, the Size popup's exact-resolution labels) had to be
  kept while adopting polish2-contacts' extraction of the preview
  GWorld/fetch state out of this file into the new shared
  `cloud_preview_well.c` — meaning Photos' preview path now goes
  through the well's rebind-on-select `note` callback for the first
  time. Photos' OWN branch never tested against that extraction
  (contacts' branch predates photos-cols' columns); contacts' OWN
  branch never tested against Photos having a Data Browser of its own.
  Neither branch's tests can have exercised this interaction, only the
  merged tree's tests can, and `scripts/test-all` at the pure-logic
  level cannot see a Toolbox-level selection/rebind race.

`scripts/test-all` is green on the merged tree (79 native tests
including all seven `cloud_*` ones, both guest cross-builds, the host
suites and the Xcode app target) and `audit_source.py` over every
touched `now-guest-ppc/src/cloud/*.c` file raised nothing new past
already-reviewed, already-guarded lexical patterns. **None of this ran
on the emulator or the PowerBook.** What only metal can prove, most
load-bearing first:

- **The preview well correctly rebinds across a Photos-to-Contacts
  switch on a REAL machine.** Select a photo, let its preview arrive
  on the new Data Browser, switch to Contacts mid-flight or right
  after, pick a card, and confirm the well's eviction/rebind hands the
  right pane its pixels — not a stale Photos preview drawn into the
  Contacts well, not a Contacts ask silently landing in the Photos
  pane.
- **Four browsers (shell, Drive, Photos, Contacts) sharing one window's
  activate/show lifecycle** — `cloud_activate`'s `lists[4]` and
  `show_own_browser`'s four-way dispatch are new arithmetic this merge
  wrote, unexercised past compiling and the pure geometry tests.
- Every per-branch metal gap already ledgered below (Contacts guest UI,
  Photos download UX, Photos preview) still applies undiminished — this
  entry is additionally about the THREE arcs running together, not a
  replacement for any of them.

## polish2-foundations: contract + host only, tested with fakes; the two real-data paths and the whole guest half are unbuilt (2026-08-02, later still)

**Unverified, deliberately labelled — and narrower than the other
2026-08-02 entries: no guest UI exists for any of this yet.** The
foundations arc (contract: `CloudGet.size` grows fit1440/fit2048,
`CloudListing` entries grow optional width/height, x-cloud contacts
gains `cloud.preview`; host: `PhotosCloudProvider.DownloadSize` grows
the same two boxes, `.list` fills width/height from
`PHAsset.pixelWidth`/`pixelHeight`, `ContactsCloudProvider.preview`
reuses the photos decode/fit/dither pipeline against
`CNContactThumbnailImageDataKey`) is TESTED — loopback-proven with
FAKE providers (`CloudServingTests`, `CloudModuleModelTests`) — and
none of it has touched a real PHAsset or CNContact. What only a
granted library/address book (this Mac's existing TCC grants) and
metal can prove, additional to the items already ledgered below for
`PhotosCloudProvider`:

- **`PHAsset.pixelWidth`/`pixelHeight` actually land in a real
  listing.** The fill is one line reading documented public
  properties, but "documented and public" is a code-reading claim
  until a real library's rows carry real numbers a person can compare
  against Photos.app.
- **`ContactsCloudProvider.preview` has never run granted.** The
  `CNContactThumbnailImageDataKey` fetch, a REAL contact that has a
  thumbnail, a real one that does not (proving the not-found "no
  photo" path fires from the actual store rather than only from a
  fake's scripted fault), and the reused pipeline against a real
  Contacts-app thumbnail's actual bytes (not the flat synthetic JPEG
  the loopback test generates) are all unexercised.
- **fit1440/fit2048 against a real multi-thousand-photo library.**
  `processedJPEG`'s box arithmetic is shared code already proven for
  the other three tokens (`PhotosProcessingTests`), so this is lower
  risk than a new pipeline — but "lower risk" is still a claim, not a
  measurement, until someone asks a real original at 2048x1536 and
  looks at the JPEG that comes back.
  *(2026-08-02, later: moot as written — all five `fitN` boxes were
  retired the same day for the four `longN` long-edge stops, and the
  unmeasured claim now belongs to those. See the long-edge entry at
  the top.)*
- **The guest half is entirely unbuilt.** Nothing here has a
  `now-guest-ppc` counterpart: no Size popup entries for the two new
  boxes, no exact-resolution-from-dimensions arithmetic on the guest
  side, no contacts card wired to ask `cloud.preview` or draw the "no
  photo" placeholder. This arc is contract + host seams for those
  pages to consume, not the pages themselves.

  **No longer true for the contacts half (2026-08-02, later still):**
  the contacts card now asks `cloud.preview` on selection and draws
  the "no photo" placeholder — see the Contacts guest UI entry below.
  The Size-popup entries and exact-resolution arithmetic remain
  unbuilt; those are Photos-only and this arc did not touch them.

## Contacts guest UI shipped tested; nothing has run past cross-compilation (2026-08-02, later still)

**Unverified, deliberately labelled — narrower than "tested" usually
reads here.** Built atop polish2-foundations: Contacts gets its own
Data Browser (Name/Company columns, `cloud_contacts_view.c`, the drive
browser's view-owned recipe), a real address-book card (photo well,
name, grouped rows — `cloud_contacts_card_layout` in
`cloud_contacts_card.c`), and a photo well shared with Photos
(`cloud_preview_well.c`, extracted from `cloud_photos_view.c`). What is
actually verified: the pure card layout is host-cc tested and
mutation-watched (`cloud_contacts_card_test.c`), and the PPC guest
cross-compiles clean with zero warnings. That is ALL — nothing here has
run against a live host wire, on the emulator, or on the PowerBook:

- **The Data Browser itself is unwatched.** Two real columns, its own
  UPPs, the fill-hilite call — all follow the drive browser's proven
  recipe, but "follows a proven recipe" is not the same claim as
  "watched drawing rows on the PB1400c."
- **The photo well's CopyBits landing is unwatched.** Reused verbatim
  from Photos' own preview (metal status there is itself only
  loopback-proven, see the entries below), but landing into a SMALLER
  well (48x48) rather than the photos pane is new geometry nobody has
  seen render.
- **The hand-drawn silhouette placeholder has never been seen.** A
  gray head-and-shoulders in two `PaintOval` calls, clipped to the
  well — geometry read by eye in the source, not by eye on a screen.
- **The preview-well extraction is a real behavior change for Photos,
  not just a file move.** `cloud_preview_well.c`'s `_select` rebinds
  the settle callback on every call, which changes exactly which
  view's pane gets invalidated when a late preview answer lands after
  the selection has moved on. Photos' preview path carried a metal
  pass before this refactor (2026-08-01); that pass does not cover the
  code as it exists now.
- **A contact WITH a real thumbnail has never been asked for.** The
  wire path is loopback-proven (polish2-foundations, above) with a
  synthetic JPEG; nothing here has asked a real granted `CNContactStore`
  for a real photo and watched it dither and land in the well.
- **The card became titled GROUP BOXES (2026-08-02, later still) and
  no box has ever been drawn.** The judged design replaced the flat
  label/value column with one `kControlGroupBoxTextTitleProc` control
  per section (Phone, Email, Address, Other), held as a fixed pool of
  four that a selection only retitles, moves and shows or hides. The
  pure half is host-cc tested and mutation-watched, and the guest
  cross-compiles — but the constructor is proven in this codebase only
  by `software_module.c`'s ONE static box, never by four that move and
  retitle under a live selection. Three specific things nobody has
  watched: whether `SetControlTitle` + `MoveControl` on a visible
  group box repaints cleanly on CarbonLib 1.6 rather than leaving
  frame debris; whether the hand-drawn rows survive the box's own
  redraw ordering inside an update event (the pane is invalidated once
  per settled sync, which SHOULD make that moot, and "should" is the
  word doing the work); and whether the `truncEnd` values read as
  intended in the 70-point column at the smallest pane.

## Photos download UX shipped tested; every visible behavior awaits metal (2026-08-02, later)

**Unverified, deliberately labelled.** The four-item download arc
(the pane's "Loading preview..." state; the download bar + byte count
off the new read-only `now_wire_receive_active`; the per-ask `size`
on `cloud.get` — contract-additive, host loopback-proven with watched
mutations, guest Size popup MENU 136; the guest-side destination
chooser redirecting a cloud-born offer through
`now_files_receive_begin_at`; and the receive-outcome seam replacing
the stuck "Receiving..." status) is TESTED at its decidable seams and
cross-compiles, and none of it has been watched on a machine. The
specific things only metal can prove:

- **The furniture rows draw where the geometry says** (size popup row,
  destination row, bar, byte line stacked over Save at 640x480), and
  the card/preview genuinely never draws under a live control.
- **The bar moves and the byte line ticks without flicker** during a
  real multi-hundred-KB receive — the change-gates are unit-tested,
  the pixels are not.
- **A redirected offer lands whole in the chosen folder** with type/
  creator/date stamped, and choosing the share root really is
  byte-identical (it never sets the override; only a code-reading
  claim so far).
- **The outcome line replaces the status at completion** on a real
  wire, including the refusal endings (exists / too-big / busy).
- **The popup CDEF under CarbonLib 1.6** accepts the fixed MENU 136
  the way the services popup accepts its rebuilt one — same recipe,
  never this menu.

## Photos preview + processing shipped tested; a granted library and metal own the rest (2026-08-02)

**Unverified, deliberately labelled.** The list+preview arc
(`cloud.preview` / `preview.begin` / `preview.end`, contract-additive;
`ClassicDither`; `cloud_photos_view.c`; the Downloads picker feeding
`cloud.photos.downloadSize` into the get pipeline) is TESTED — pure
ditherers with watched mutations, loopback serving with bytes-intact
and lane-exclusivity proofs, in-test JPEG/HEIC fixtures for the
resize pipeline, host-cc guest units — and none of it has met a
machine. What only a granted library and metal can prove:

- **The palette is the real one only by construction.** ClassicDither
  generates the standard 'clut' 8 layout (cube minus black slot, four
  ramps, black at 255) and dithers against it; the guest's GWorld
  wears whatever a NULL colour table gives an 8-bit depth. That the
  two tables are THE SAME TABLE on a real CarbonLib screen — the
  whole reason no palette travels — is a code-reading claim until a
  preview is looked at on the PowerBook. If colours arrive scrambled,
  suspect this first.
- **PhotosCloudProvider.preview has never run granted**: the
  local-bytes-only fetch, the busy bargain for an un-materialized
  original, and a real HEIC through decode->fit->dither all need this
  Mac's TCC grant.
- **The pane under a held lane** ("Preview after the download", the
  re-ask when selection moves mid-transfer) is guest logic past the
  pure units: builds only, exercised on no machine, and 1-bit asks
  (screens under 8-bit) have no fixture anywhere.
- **Downsized downloads against a real library**: processedJPEG is
  fixture-tested; a 48 MP original through `long640` (was `fit640`
  until the long-edge arc, same day) on the wire to a real guest is
  not.
- **Preview pacing on real hardware**: a 300x200 8-bit preview is
  ~60 KB, ~0.2 s at the measured 300 KiB/s — arithmetic, not a
  measurement; nobody has felt the selection-to-pixels latency at
  the PowerBook.
## The cloud.* family: real providers are untested, and the guest half does not exist (2026-08-01)

**Unverified / unfinished, deliberately.** The host serves
`cloud.services`/`list`/`detail`/`get` from a provider registry
(`now-host/Sources/Host/CloudServices.swift`), tested over a loopback
wire with FAKE providers only (`CloudServingTests`). Still unproven:

- **PhotosCloudProvider and ContactsCloudProvider have never run
  granted.** They need this Mac's TCC consent (usage strings are in the
  Xcode project; the iCloud page has the grant buttons). First run:
  turn each on in the host's iCloud page, grant, and ask over the wire
  — `cloud.list` paging against a real multi-thousand-photo library,
  the JPEG/HEIC transcode, and the busy-then-bytes path for an
  un-materialized original are all claims from code reading.
- **The guest module does not exist yet.** One Workshop page, service
  dropdown, per-service render (docs/icloud.md). Until it lands, the
  family is host-only and nothing exercises it end to end; when it
  lands, the guest's emitted cloud.* messages owe fixtures to
  GuestWireFixtureTests, and contract-coverage.md gains the family's
  guest rows.
- **cloud.get on a busy lane** refuses busy by unit-tested logic, but
  no test drives a real concurrent capture/stream against it.

Update 2026-08-01, late: the entitlements fix is METAL-ADJACENT
VERIFIED — with the hardened-runtime personal-information
entitlements signed in, the Grant Access buttons surface macOS's real
prompts, and with the grants given Michelle reports the granted
services working as intended against the PowerBook, fan-out included
("functional enough"; her detailed notes are pending and may reopen
items here). Narrower claims that remain untested by suites: the
Photos fetch cache against a real library-change event, non-English
Birthday parsing, unclipped long card values.

Update 2026-08-01, night: the fan-out landed (view seam, full-width
drive browser + Up, contacts card view, photos hardening, live
search) and its adversarial review's four must-fixes are in. Still
open from that review: PhotosCloudProvider's fetch cache has no test
(needs a granted library or a PHPhotoLibrary fake); contacts
Birthday parsing matches English month names only (non-English hosts
fall back to echoing text); long contact card values draw unclipped.
Native tests now number 76; everything since the last metal pass —
the whole fan-out — is tested, not metal-verified.

Update 2026-08-01, evening: METAL-VERIFIED for Drive on the
PowerBook 1400c — the cloud.services round trip, the dropdown, and
the in-page drive browser (list, descend, Up, double-click fetch)
all watched working. Three faults the first metal pass found are
fixed and their fixes watched: status_text garbage, popup menu
reachable only through GetControlData, first-ask-before-connect.
Still unproven: Photos and Contacts with real TCC grants, and
cloud.get end to end (no serving service had it enabled yet).

Update 2026-08-01, same day: the guest module LANDED
(`now-guest-ppc/src/cloud/`, docs/icloud.md) — parsers and geometry
native-tested and mutation-watched, all three guests cross-compile,
conformance gates cover the emitted asks. What remains unproven moves,
not shrinks: the page has never been drawn on any screen (emulator
pass owed first, then metal), the TCC-granted providers are still
untried, and no end-to-end ask has crossed a real wire.

Update 2026-08-01, later: the metal-verified drive browser above is
now a full-width flat list rather than the narrower list-beside-card
layout it was verified in — `cloud_layout.c` gained a drive-mode
variant (full width list, detail/save collapse to an anti-rect, a new
`up_btn` in the toolbar row) and the card pane's per-row detail and
pull progress both moved to the status placard
(`cloud_drive_view.c`'s draw is now NULL). **TESTED, not
metal-verified**: `scripts/test-all` is green (74 native tests
including new `cloud_layout_test.c` drive-mode cases, both guest
cross-builds, host gate), and the new geometry was watched failing via
a deliberate mutation, but nobody has driven this exact layout on the
PowerBook or the emulator — the metal pass this arc references above
predates this change. Before it: Data Browser's hierarchical/container
surface (disclosure triangles, a real tree) was investigated and found
**not proven viable** for this runtime — declared in the headers and
compiles clean against a real container-callback call
(`spikes/databrowser-container-probe`), but the container-specific
entry points were never in `spikes/databrowser`'s runtime symbol check
against CarbonLib 1.6.0 on the PB1400c, so the drive view stays the
flat, replace-on-navigate list it already had rather than adopt an
unverified tree. Reopening that is a rerun of the runtime probe with
four more symbol names, not another compile check — see
`spikes/databrowser-container-probe/README.md`.

Update 2026-08-01, later: Photos hardened for an enormous library
against FAKES only (docs/icloud.md > Hardened for an enormous
library) — `PhotosCloudProvider`'s PHAsset fetch cached per instance
and invalidated by `PHPhotoLibraryChangeObserver`, a 10,000-row paging
walk and the 4KB page bound proven and mutation-watched
(`CloudServingTests`), a 3MB photo riding the ordinary transfer lane
end to end, and the guest's cap-hit status wording made honest
(`cloud_listing_status`, native-tested and mutation-watched). None of
this touched a real PHPhotoLibrary: the cache's invalidation path, the
real fetch's actual cost at 40,000+ photos, and whether Photos'
authorization APIs behave as read on this Mac are all still claims
from code reading, folded into the TCC-grant item above rather than
duplicated here. `PHAssetResource`'s byte size stayed out of scope —
no public API exposes it short of downloading the resource — so
`CloudEntry.bytes` stays unstated for photos, deliberately, not as an
oversight.

Update 2026-08-01, later still: the three fan-out branches above (drive
full-width layout, Contacts card view, Photos hardening) are merged
into one tree (`claude/swarm-icloud-integration`, base
`claude/swarm-icloud-split`). One conflict, in `cloud_module.c`'s
`choose_service()`: the drive branch added a layout recompute on every
service switch, the contacts branch added per-service view dispatch —
both intents kept, dispatch then relayout. Two more conflicts, in this
file and docs/icloud.md, were two branches appending different ledger
paragraphs after the same anchor line rather than true disagreement —
both paragraphs kept. **TESTED, not metal-verified**: `scripts/test-all`
is green post-merge (75 native tests including `cloud_contacts_card_test`,
both guest cross-builds plus the NOW Extension, `swift test` at 1324
tests, `xcodebuild` Debug and Release) with the exit code read directly.
Nothing here changes what each branch's own entry above already says is
unproven — a clean merge does not prove Photos or Contacts against a
real TCC-granted library, or put the new drive layout or the Contacts
card in front of anyone on the PowerBook.

## iCloud Drive sharing is tested against fabricated stubs only (2026-08-01)

**Unverified.** The share now sees a directory logically — iCloud
placeholder stubs (`.name.icloud`) list under their logical names with
the size the stub's plist promises, and a `file.get` for one calls
`startDownloadingUbiquitousItem` and refuses `busy` with the reason
(`now-host/Sources/Host/HostShare.swift`, `HostShareCloudTests`). Every
test fabricates the stubs, so three claims rest on Apple keeping a shape
no contract guarantees, and none has been tried against a signed-in
iCloud Drive on this Mac:

- the stub is a binary plist whose size lives under `NSURLFileSizeKey`
  (the fallback chain — promised-item API, then an honest zero — makes
  a format change degrade to "size 0", not a failure);
- `startDownloadingUbiquitousItem(at:)` accepts the logical URL (the
  code retries with the stub URL, and swallows the error either way —
  the refusal is already on its way);
- a download actually materializes the file where `resolve` will find
  it on the retry.

Trying it is cheap: sign-in, point the Sharing picker at iCloud Drive,
browse from the emulator guest, pull an undownloaded file twice.
Metal-verified is further still.

The name bridge (`ClassicName`) closed a live defect on the way: listed
names were mangled one way (`hfsName`) and resolved verbatim, so any
name the projection changed was advertised and then unreachable —
`file.get` answered `not-found` for the listing's own spelling. Covered
by round-trip tests now (`HostShareTests`, "The name round trip"), but
the guest-side experience of fingerprinted names (`Report#1A2B.txt` in
the Files page, Data Browser column width, MacRoman rendering of "#")
has not been looked at on a real screen.

Related, found while mapping (2026-08-01): **the host's serving half
has no metal coverage at all.** `HostServingTests` is loopback-only,
and no `Metal*` suite exercises a real guest browsing this host's
share. The browse direction guest→host is metal-verified only from the
2026-07-20 arc, before the name bridge and placeholders landed.
## The Files path row names the share, unverified on metal (2026-08-01)

**Unverified.** `file.listing.root` now carries the host share's Finder
display name ("iCloud Drive", "Downloads") through the standard MacRoman
projection, instead of the raw POSIX path, and the guest's Files path
row renders it — breadcrumbs from the share root for subfolders, with
"Shared folder" kept only as the fallback for hosts predating the field.
Host side is tested end-to-end over loopback (`HostServingTests
.testTheRootListingNamesWhatIsShared`); the guest's label assembly is
split Toolbox-free (`files_path_label.c`) and pinned natively. What
nobody has watched: the row on a real screen — the root name arrives
over the wire UTF-8→MacRoman via `now_json_find_text`, and an accented
share name drawn through `DrawString` is exactly the kind of thing the
emulator has hidden before.
## The Mirror page has never been on a machine (2026-08-01)

**Unverified, and the whole page is unverified together.** The guest now
has a Mirror page in the Workshop (`now-guest-ppc/src/mirror/`): three
read-only rows for Mirror's resident extensions, three rows for its
agent, and Enable / Disable for the agent alone. It builds, and its value
core is covered by `mirror_layout_test.c`. Nothing about it has run on a
Macintosh.

What a machine has to settle, none of which a host test can:

- **That Gestalt answers at all.** The three selectors and the two or
  three longs read behind each of them (`'TBax'`, `'TBqd'`, `'TBpt'`)
  come from Mirror's own shared headers, cited in `mirror_probe.c`. If a
  selector answers with an address whose magic does not match, the page
  says absent — which is the safe direction, and also indistinguishable
  from "we read the wrong offset".
- **That the agent is found where the page looks.**
  `mirror/tools/stage-agent.py` puts the agent at
  `Macintosh HD:TimBotTu:mirror-dev:mirror-agent`; the page walks the
  boot volume to it and matches a running process by its
  `processAppSpec`. An agent staged anywhere else reads as not installed.
  There is no preference for the location and no browse button.
- **That `LaunchApplication` starts a faceless background application
  from a Carbon app**, and that a `kAEQuitApplication` reaches one that
  owns no menu bar. Both are ordinary calls; neither has been watched
  against this particular target.

**Why the agent is matched by file and not by creator.** Mirror's agent
is a Retro68 build with no creator override, so it carries the default
`'????'` — read out of the MacBinary header of
`mirror/guest/app/build/mirror-agent.bin`. So does every other Retro68
build on the machine, including the lab's own workers, which is why a
signature match would cheerfully report the Mirror agent running about
something else entirely. The signature is shown on the page and matched
on by nothing. If Mirror ever stamps a real creator, this becomes a
one-line change and a better rule.

**The three extensions are deliberately not switchable**, and the page
says so in two lines rather than offering a control that does nothing. A
file-move enable/disable *is* possible and is already proposed below
("an extension is a thing you enable, not a thing you launch") — it needs
a guest verb, a confirmation, and the restart notice in the *result*, and
none of that is what "status and enable/disable" asked for. Deferred, not
overlooked.

**No console or wire verb.** This is a UI-only page: it adds no
`x-commands` verb, no message type, and nothing to
docs/contract-coverage.md. The parity rule is about capabilities the two
faces of a guest reach, and nothing here is reachable from the wire
because nothing here was added to it. A `mirror` console verb would be a
real capability and would need both faces — worth doing, and not done.

**The View menu was one item short, and this fixed it.** Networking went
in on 2026-08-01 without a menu item, and the handler maps item number to
module id: Cmd-9 read "Logs" and selected Networking, Cmd-0 read
"Connection" and selected Logs, and Connection could not be reached from
the menu at all. Adding Mirror without repairing that would have moved
the mismatch along. Logs and Connection now carry no Command-key — the
digits ran out — and are one click away in the rail.

## The Mirror port was thrown away (2026-08-01)

**Settled, and it settles a great many entries below.** NOW's
re-implementation of Mirror's live-UI mirroring — `MirrorKit`,
`MirrorKitUI`, the Mirror module's model, view, scene adapter, action
driver, content join and window resolver, with their tests — has been
**deleted from `now-host`**. In the built app its menu bar was mostly
empty, its menus dropped down and did nothing, and nothing could be
launched, clicked, moved or resized. Mirror already does all of it,
working, on the same OS and the same emulator.

Mirror is now vendored whole at `mirror/` — its own wire, its own 68K
INITs, its own agent surface, its own SwiftPM package, built by nothing in
`now-host` — and NOW's Mirror module is a **launcher** for its two halves
(`MirrorLauncherModel`). The removed code is archived unchanged at
`archive/mirror-port-2026-08-01/`, whose README says what is worth reading
in it.

Update 2026-08-02: `MirrorLauncherModel` is itself gone. The launcher it
describes pointed at Mirror's own emulator session and showed the shell
lines it ran; the module now controls one Mirror instance aimed at the
CONNECTED guest. See the 2026-08-02 entry at the top of this page.

**So: every entry below that names `MirrorKit`, `MirrorKitUI`,
`MirrorModuleView`, `MirrorModuleModel`, `MirrorActionDriver`,
`MirrorSceneAdapter` or the Mirror pane describes code that is no longer
in this tree.** They are left standing per the rule at the top of this
page — the shape of the mistake is the value — but none of them is a
thing to pick up.

The lesson, which is not about Mirror: every acceptance number in that
work was measured by probe scripts against the wire verbs, and **the path
a person actually uses was never once tested end to end**. "`winact`
closed a window 10/10" and "a person can close a window in the mirror" are
different claims, and the gate only ever checked the first — so it stayed
green for two days while the product did nothing.

**Closed 2026-08-01: the guest spin-up works from here.** It used to
resolve the lab it borrows its emulator instruments from as its own parent
directory, which inside NOW is this repository rather than the TimBotTu
checkout that has them. Both scripts and both Python stagers now honour
`MIRROR_LAB_ROOT` and otherwise walk up until a directory actually holds
`tools/lib.sh`; `MirrorInstallation.lab` resolves it the same way and
passes its answer down, so the preflight and the run cannot disagree.

Emulator-verified, not merely built: `MIRROR_DISPLAY=1 tools/spin-up.sh`
from `now/mirror/` booted a fresh mac99 clone (anchor at 90s), staged all
three INITs, cold-rebooted with all three surviving, and the agent
answered — `oracle=ok v4`, `observe` 9 processes front=Finder, `axtree`
walking. Both preflight halves then read green against this checkout.

Two things it left behind:

- `stop-mirror.sh` had a worse version of the same bug and now refuses
  rather than proceed: with no lab found, `LAB` resolved to `/`, the QMP
  quit failed into its own `||` branch reporting "VM may already be down",
  and the `rm` then unlinked the session disk out from under a QEMU that
  was still running it.
- The standalone `timbottu/mirror` repository still carries the old
  resolution in all four files. It is not broken there — its parent really
  is the lab — but the vendored copy and the origin have diverged, and the
  walk-up version is the one that works in both geometries.

## The last functional gap: a person cannot click the mirror (2026-08-01)

**Retracted 2026-08-01, later the same day: the pane this describes no
longer exists.** See "The Mirror port was thrown away" above. The
diagnosis below is why it was thrown away rather than finished, and is
kept for that reason.

**Broken, in the sense of unfinished rather than wrong.** Every piece of
the act path exists and is tested, and the path has no join. An agent can
drive a Macintosh through the MCP act rows today. **A person clicking a
rendered control in the Mirror pane gets nothing** — not a refusal, not a
log line, nothing, because no code observes the click.

Three separate breaks in one chain. Each was verified against the tree on
2026-08-01, and none of them is recorded anywhere else.

### 1. The renderer has no hit-testing wired into it

`HitTester.hitTest(_:x:y:)`
(`now-host/Sources/MirrorKit/HitTester.swift:155`) has **no caller outside
the test bundle.** Nor does `ActionModel.click(on:count:mods:)`
(`ActionModel.swift:244`), which is the only thing that constructs a
`MirrorAction`. So at runtime **no `MirrorAction` is ever built**.

The pane draws and nothing more: `MirrorModuleView.swift` hands the scene
to `SceneView`, which wraps a `Canvas`, and there is no `onTapGesture`,
`DragGesture`, `.gesture(`, `onHover` or `contentShape` anywhere in
`MirrorKitUI/`, `MirrorModuleView.swift` or `MirrorModuleModel.swift`.
The pane's only interactive controls are *Close Scene*, *Look Now* /
*Look Again* and *Open Scene…*.

Other `HitTester` statics **are** live in production — `isDesktopBackdrop`,
`switchableApps`, `appMenuWidth`, `menubarHeight` — which is why the type
does not read as dead. The type is alive; the hit-testing is not.

### 2. The driver that would receive the gesture has no caller

`MirrorActionDriver` (`now-host/Sources/Host/MirrorActionDriver.swift:56`)
is the seam a pane would call. It is built, it is tested
(`MirrorActionDriverTests.swift`), and **the only thing that constructs it
is its own test.** This is the half that could be finished without a
machine, and it was; the pane is the half that wants one.

### 3. A window has no scene-side reference host-side

The guest emits `windows[].ref` — `now-guest-ppc/src/scene/scene_json.c:318`
(`put_ref(k, w->ref)`), set by `now_scene_set_window_ref`
(`scene_build.c:314`) off `now_obs_walk_window_ref`. It is an addition to
IR v1's window field set, taken under the accretive rule, and the reason
it was added is exactly this one: `winact` names a window, not a control.

**Neither host model has a field to put it in.**
`NOWSceneDocument.Window`
(`now-host/Sources/NOWAgentIntegration/AgentIntegrationSceneModels.swift:195`)
and `MirrorKit.Scene.Window` (`Scene.swift:155`) both carry
`id / app / psn / title / rect / front / z / visible / kind? / controls? /
text? / items?` and no `ref`. `NOWSceneCodec.decode` is a plain synthesized
`Codable`, so the key **decodes without error and is discarded.**
`MirrorSceneAdapter.window(from:)` never mentions it.

Control refs do survive (`NOWSceneDocument.Control.ref`, mapped at
`MirrorSceneAdapter.swift:188`). Window refs do not.

**So `winact` has no caller from a rendered scene.** The one place that
sends it — `AgentIntegrationActControl.swift:120` — takes its `window`
argument from an opaque `now-window-…` minted by `now_observe_elements`,
supplied by the agent caller. `MirrorActionDriver` has no `winact` route
at all.

**One correction to a phrasing that has been repeated:** `Scene.Window.id`
is **not** host-synthesised. It is minted by the guest at
`now-guest-ppc/src/scene/scene_build.c:197` as `"%ld.%lu/%s#%d"` —
`psn.hi.psn.lo/title#z` — deliberately in upstream `SceneBuilder`'s own
form, so an id minted here means what one minted there means. The host
carries it through unchanged (`MirrorSceneAdapter.swift:160`). It is a
*name*, not an address: nothing resolves it back to a `WindowPtr`.

### The five faces are `notReached`, and honestly so

Each act row declares `.appUI: .notReached` with its reason, and the
ledger is enforced both ways by
`HostFaceParityTests.appUIDivergences`:

| capability | file | line |
|---|---|---|
| `now_window_act` | `Projection/WindowActProjection.swift` | 72 |
| `now_control_act` | `Projection/ControlActProjection.swift` | 55 |
| `now_menu_act` | `Projection/MenuActProjection.swift` | 59 |
| `now_text_get` | `Projection/TextGetProjection.swift` | 43 |
| `now_text_set` | `Projection/TextSetProjection.swift` | 48 |

Eleven rows in total carry `.appUI: .notReached`; the other six are
`now_observe_elements`, `now_session_capabilities`,
`now_transfer_approved_artifact`, `now_guest_files_capabilities`,
`now_guest_files_upload_begin` and `now_guest_files_upload_append`.

**These declarations are the good news, not the bad.** Rule 3 is recorded
as *owed*, not waived, and the gate would have gone red if a row had
claimed a face it did not have. What is missing is the pane, and the pane
was correctly sequenced behind the thing it renders.

**One reason has aged, and is worth fixing when the pane lands.**
`WindowActProjection`'s reason says *"the host has no window observation to
select one from"*. That was true when it was written; the guest has emitted
`windows[].ref` since 2026-08-01. The half that is still true is that the
host model discards it.

### Two stale claims in source, found while verifying this

Recorded here because they are in `now-host/Sources/**` and this pass owns
no source:

- `MirrorSceneAdapter.swift:41-42` still says *"NOW's walk reads a
  ControlRecord and cannot name a ref, so it is `""`"*. The reference plane
  landed 2026-08-01; the code below the comment already maps
  `control.ref ?? ""` correctly. Comment only.
- `ActionModel.availability`'s `.key` / `.type` reason
  (`ActionModel.swift:130-137`) says *"NOW's contract declares no keystroke
  command."* The contract declares `key` at `contract/asyncapi.yaml:3024`.
  What is actually missing is a host **projection row** — tracked as W3 in
  [mcp-coverage.md](mcp-coverage.md). The refusal is right; its stated
  reason is not.

## `.activate` reports available and this host has no lane (2026-08-01)

**Broken, and it is a live inconsistency rather than a gap.**

`ActionModel.availability(.activate)` answers
`.available(command: "activate")` (`ActionModel.swift:140-142`), on the
grounds that a scene carries a process serial for every window. The
contract agrees that the verb exists — `contract/asyncapi.yaml:2923`
declares `activate`, taking `serialHi` / `serialLo`, described as *not a
second `front`*.

**This host carries no lane for it.** There is no `activate` case in
`AgentIntegrationLocalProtocol.Operation`. So `MirrorActionDriver.drive(_:)`
passes the `switch ActionModel.availability` guard — because availability
said yes — and lands in an explicit refusal at
`MirrorActionDriver.swift:145-155`:

> NOW's contract declares the activate command and this host carries no
> lane for it. The scene's process serial is not the opaque reference
> bring-to-front takes, so there is nothing to substitute.

**The refusal is the right call and should not be traded for a
substitution.** `now_bring_to_front` takes an opaque `now-process-…`
reference minted by `process.list`, validated by
`AgentIntegrationQuitPolicy.isValidReference`, and **re-listed and matched
by full observed identity before it acts**. A scene's bare `"hi.lo"` PSN
string was minted by no host-side observation. Bridging the two would mean
acting on an identity nothing on this side ever confirmed — which is the
exact property the quit/front family was built to have.

**What is actually owed** is either a lane (an `activate` operation, with
the serial's own validation story) or an availability answer that stops
saying yes. Today the row is the one act in the vocabulary that reports
sendable and has no route.

## `type` and `click` are unavailable by design; `key` is now mods-gated (2026-08-01, updated same day)

Not a defect. Recorded because *"why can't I type into the mirror"* is the
first question the pane will raise, and the answer is a hardware-era fact
rather than a to-do for the MODIFIED half — but a plain keystroke is no
longer one of these rows.

**Updated same day: `key` split into two answers, not one.** It read
`.unavailable` unconditionally when this section was first written; that
was too broad. `now-guest-ppc`'s `key` verb posts an unmodified keystroke
fine (`mods` is accepted as exactly 0) — the wall below is real for
`mods != 0` and was never a fact about `mods == 0`. `ActionModel
.availability(.key)` now reads:

| act | mods | answer | why |
|---|---|---|---|
| `key` | `== 0` | `.available(command: "key")` | the guest posts it; `MirrorActionDriver` routes it to `AgentIntegrationHostAdapter.key` and the pane's drawing (`MirrorModuleView` + `MirrorKeyCaptureView`) sends one on a keystroke |
| `key` | `!= 0` | `.unavailable` | the CarbonLib wall below — unchanged |
| `type` | any | `.unavailable` | NOW writes text through `textset` against a referenced control (`typeInto`), never through a bare typed action with no target |
| `click` | — | `.unavailable` | NOW's contract declares no positional click. A control is acted on through `ctlact` **by reference**, not by where it is drawn |

**Not verified even for `mods == 0`:** the pane's AppKit key-capture view
(`MirrorKeyCaptureView`) has not been exercised in the running app — no
display was attached to the work that added it. The specific, named risk
is in `docs/pane-keys-audit.md`: whether its `hitTest`-returns-nil design
actually leaves the drawing's existing click gesture untouched, and
whether focus reaches it reliably after a click. `swift build` and `swift
build --build-tests` both pass; nothing about the AppKit event path has
run.

**`key` still refuses modifiers outright.** An event's modifiers live on the
Event Manager's **queue element**, not in the message, and the only call
that hands that element back is `PPostEvent` — which CarbonLib does not
have (`CALL_NOT_IN_CARBON`). NOW's application is Carbon. So the guest can
queue a keystroke and cannot say what was held down while it was typed;
`mods` with any non-zero value answers `unsupported` and names the reason,
and `mods: 0` is accepted. The alternative — post the keystroke and drop
the modifier — is a defect upstream already paid for: a literal character
went into a document and the reply said success. Stated at
`contract/asyncapi.yaml:3036-3044`, in
[input-plane-decisions.md](input-plane-decisions.md), and in the guest at
`now-guest-ppc/src/input/input_args.c`.

**The reach exists, and only through the act plane's resident half.**
`ext/src/now_ext_act.c` is a **68K resident**, not Carbon, so it can do
what the application cannot: `act_post_click()`
(`now_ext_act.c:497-533`) sets `LMSetMouseLocation` and calls `PPostEvent`
for the press and the release itself, stamping `evtQWhere` and
`evtQModifiers`. That inversion is worth holding onto — the older, less
capable-looking half of this project is the half that can reach the queue
element.

## `MirrorKit.SceneIslands` kept its policy and lost its fetch (2026-08-01)

**Unfinished, and it will read as dead code to the next auditor.**

`SceneIslands` (`now-host/Sources/MirrorKit/SceneIslands.swift:20`) carries
upstream's capture / hold / shift policy for pixel islands intact. The
fetch it drives is an **injected closure** —
`typealias Capture = (Rect) throws -> PixelIsland` (line 24), consumed by
`attach(_:poll:capture:)` (line 53), `island(for:key:capture:)` (line 105)
and the metered `fetch(_:_:)` (line 168).

**Nothing supplies one.** The only construction site in the repository is
`IslandLifecycleTests.swift:41`. Nothing in `Sources/**` constructs
`SceneIslands` or calls `attach`.

The file says so itself, and the reason is real rather than an oversight:
the host's pixel path is `GuestListener.requestCapture` + `CaptureDecoder`,
and no code joins it to a rendered scene. Joining them is a decision about
the transfer lane — an island is a capture, and the lane is one transfer
wide — not a wiring job.

**Why it stayed:** the policy is the expensive part and it is tested. A
closure with no supplier is an honest shape for *we ported the judgement
and not the plumbing*; deleting it would throw away the judgement.

## The content plane has never run anywhere (2026-08-01)

**Unverified in the strongest sense on this list, and not a fault to
chase.**

The reader is complete and natively tested against fabricated rings —
`now-guest-ppc/src/content/qdtrace_read.c` (the ring walk and the
seqlock), `qdtrace_json.c` (the replies), `qdtrace_cmd.c` (the only
Toolbox, four subcommands: `status` / `start` / `stop` / `drain`),
registered at `commands.c:1376` with a help row.

**The writer has never executed on any Macintosh.** `ext/src/now_content.c`
and `now_content_logic.c` are the resident half that fills the ring at
draw time, and nothing has armed them — not on an emulator, not on metal,
not upstream in this shape. No captured output, fixture or run log for an
armed plane exists anywhere in the tree.

**So `qdtrace status` answers `content-plane-absent` on every machine that
exists, and that is correct.** The refusal is emitted at three sites
(`qdtrace_cmd.c:198` on `start`, `:275` on `stop`, `qdtrace_json.c:420` on
`drain`), gated on the caps bit `kNowPeekTableCapContent`
(`contract/peek_table.h:93`, `1u << 3` after the collision described
below). A run that gets `content-plane-absent` is not a failure. **A run
that gets anything else is news.**

One stale comment in guest source, flagged rather than fixed here:
`qdtrace_cmd.c:11-15` still says *"REGISTRATION IS NOT OURS"*. It is
registered.

### `qdtrace`'s `torn` retraction: what is covered and what is not

The brief this checkpoint was written against said `torn` was "the one
untested line". That is close and worth stating precisely, because the two
halves have different standing.

| Layer | Path | Covered? |
|---|---|---|
| Read | `qdtrace_read.c:307-326` — re-sample, `seq1 != seq0` **and** the writer lapped the cursor → `kNowQDDrainTorn`, `records = 0`, `resync = 1` | **Yes.** `qdtrace_read_test.c:526-543`, driven by a deterministic `lapping_sink` |
| JSON | `qdtrace_json.c:444-450` — rewind `e.pos` to `head`, discarding whatever ops were already serialized | **No**, and the test file names it as a gap (`qdtrace_json_test.c:19-28`) |

**Why the JSON line cannot be reached from a fixture:** getting there needs
a live writer lapping the ring *between* the seqlock sample and the
re-sample. No host fixture can stage that, and a fixture that could would
be staging the answer.

**The nearest thing to coverage is a proxy, and it is a real one.** `Busy`
takes the *same* retraction branch, and `test_busy_says_call_again`
(`qdtrace_json_test.c:344-355`) asserts the reply comes back with
`"ops":[]`. So the discard is exercised; what has never been exercised is
the discard **after ops were written into the buffer**.

**The falsifiable claim, for whoever gets the first armed run:** a `torn`
reply is `ok: true` with `"ops": []`, `"records": 0`, `"torn": true`,
`"resync": true`. The `"ops":[` is emitted *before* the walk
(`qdtrace_json.c:407-409`) and the retraction rewinds only as far as
`head`. **If a `torn` reply ever arrives carrying a non-empty `ops` array,
that is the defect** — it means ops survived a retraction that was
supposed to discard them, and every one of them is a reading of a ring the
writer had already overwritten.

Worth knowing about the shape: `torn` and `busy` are *successful* replies
carrying flags; `absent`, `mismatch` and `corrupt` are `ok: false` errors.
A caller that treats `torn` as an error will retry something that was
telling it to call again.

## Stale branches and two worktrees against a layout that is gone (2026-08-01)

Housekeeping, recorded rather than swept, because deleting another
session's work is not this pass's call.

**Four branches, none merged into `main`, none checked out anywhere:**

| Branch | Head | Behind main by | Unmerged commits |
|---|---|---|---|
| `claude/next-module-direction-02becd` | `3094e89` | 550 | 13 |
| `claude/laughing-tesla-b4cc41` | `686aa9c` | 605 | 10 |
| `fork/carbon-ui-cleanup` | `b185b8a` | 692 | 6 |
| `claude/guest-installer` | `664cfd0` | 423 | 5 |

**Two worktrees holding uncommitted edits against a directory layout that
no longer exists:**

- `.claude/worktrees/sweet-bouman-a714dd` — HEAD `a3f3adb`, branch
  `claude/sweet-bouman-a714dd`. Five modified files: `docs/open-issues.md`,
  `guest/src/commands.c`, `guest/src/wire.c`,
  `guest/tests/json_native_test.c`,
  `host/Tests/HostTests/GuestWireConformanceTests.swift`.
- `.claude/worktrees/youthful-lumiere-d6e7be` — HEAD `1cd1303`, and the
  branch checked out is **`claude/68k-pn-180c-9c0940`**, not the one the
  worktree is named for. One modified file: `guest68k/src/wire68.c`.

**Why they cannot simply be applied.** `main` has no `guest/`, `guest68k/`
or `host/` at top level — the trees are `now-guest-ppc/`, `now-guest-68k/`
and `now-host/`. Both worktrees sit on pre-rename commits. Salvaging an
edit means path-mapping `guest/src/` → `now-guest-ppc/src/`,
`guest68k/src/` → `now-guest-68k/src/`, `host/` → `now-host/`, onto files
that have moved *and changed substantially* across roughly 600 commits.

**The honest read is that these are almost certainly not worth salvaging**,
and the reason to write them down anyway is that an uncommitted edit in a
worktree is invisible to every other kind of audit. Whoever prunes them
should look at the five diffs first and record `corpus_impact` for
anything that turns out to be a finding.

## Two planes asked for the same bit, and one collision was silent (2026-07-31)

**Found and fixed during the fold-in, recorded because the near-miss is the
lesson.** The act plane (P4) and the content plane (P3) were ported by different
agents, in parallel, neither able to see the other's edits to
`contract/peek_table.h`. Both appended a capability bit and a state cell. Both
asked for **`1u << 2`** and for the offset **`36 + 60 * kNowPeekMaxAnchors`**.

The offset collision would have **failed a compile** — the header's static
asserts pin every offset, which is exactly what they are for.

The bit collision would have been **silent**, and it is the dangerous one:
arming the content plane would have armed **P4's six trap patches inside another
process.** A person switching on a QuickDraw op counter would have been patching
`MenuSelect`, `TrackControl` and `FindWindow` system-wide without asking for it.

P3 now sits at `1u << 3`, appended after P4's cell. The shim keyed on
`NOW_PEEK_TABLE_HAS_CAP_CONTENT` was deleted rather than left standing once it
had retired.

**What to carry forward:** the accretive discipline (`stamp_ticks` never moves,
gate on the format word, append only) was written for **versions** — one writer
extending a table over time. It says nothing about **two writers extending it at
once**, and parallel ports are now normal here. A test asserting that every cap
bit is distinct and every plane's cell offset is unique would have caught this at
the same moment the compiler caught the other half.

Related: `now_act_guard_test` went red on the append and was **right to** — it
spelled "one byte short of the act cell" as `sizeof(table) - 1`, which is true
only while that cell is the last field. A test written against the *end of a
struct* is a test that fails the next time anyone appends.

## `menuRowHeight` is a known-wrong constant (2026-07-31)

`now-host/Sources/MirrorKit/ActionModel.swift:92` hardcodes
`menuRowHeight = 16`, and `ActionDispatcher`'s `.menuDrag` releases on a point
computed from it. That is the uniform-row assumption upstream **measured** as a
**~30 px accumulated error** once a menu contains separators — the rows are not
uniform and the error compounds down the menu.

It survived the port because it is a constant rather than a mechanism, and
nothing crossing looked at it.

The fix upstream built for this is `MENU_GEOMETRY`, which the act-plane port
deliberately left behind on the grounds that *"nothing in NOW consumes item
rects."* **That reason has expired** — `ActionModel` consumes them implicitly, by
assuming them. Porting it needs a new resident op (`peek_table.h`, `ext/`, the
guard), so it is not a small change.

**Until then, prefer `menuact`**, which is identity-addressed and computes no
geometry at all. The drag path this constant serves is emulator-only, so the
blast radius is bounded — but a number that is wrong by 30 px two-thirds of the
way down a menu will find a way to be believed.

**Resolved 2026-08-01, on `audit/menu-honesty`.** The ruling in
`docs/input-plane-decisions.md` §3 was "measure the rows, or delete a
computation nothing performs" — and by the time this branch landed,
`menuSelect` already routed every item through `.menuInvoke`, so nothing
performed it. `menuRowHeight`, `ActionModel.menuItemPoint`, and the
`MirrorAction.menuDrag` case that was their only reader are deleted; no code
path in `now-host` computes a menu-item pixel point from a row-height
constant, live or dead. `menugeom` stays unported (still the riskiest call
in upstream's file, still serving nothing) — re-open only if a caller needs
an on-screen menu-item rect, per the re-open condition already on record.

## Proposed: an extension is a thing you enable, not a thing you launch (2026-07-31)

**Proposal, nothing built.** From the manual review pass, and recorded here
because it is a *new guest capability* rather than a UI gate — the gating half
(never offering Launch or Bring to Front for an extension or a faceless
background process) is being handled separately and is not this.

The user's shape for it:

> extensions can surface an enable / disable function that just moves the
> extension between Extensions and Extensions (Disabled), plus a message that
> changes will take effect after restart

Three things make this worth writing down before anyone builds it.

**It belongs on the guest, not composed on the host.** The mechanism is a file
move, and NOW already has a guest move verb — so the tempting cheap version is
the host composing "disable" out of two paths it constructs itself. That is the
projection layer *deciding*, which rule 2 forbids, and it breaks the first time
it meets a System Folder that is not where the host assumed: a non-English
system, a renamed volume, a machine with no `Extensions (Disabled)` folder yet.
The guest knows where its own System Folder is and whether the disabled folder
exists. The host should ask for "disable this extension", not for two paths.

**The restart notice is part of the capability, not decoration.** An INIT loads
at boot and only at boot, so a disable that reports success is telling the truth
about the file and a lie about the machine until it restarts. That gap is
exactly the class of thing this product refuses to paper over elsewhere — it
belongs in the *result*, not only in a label beside the button.

**It is a destructive-ish capability with an easy undo**, which puts it in the
same family as the Files verbs: it wants the same confirmation and audit
treatment, and an agent reaching it must appear in the audit line like any other
mutation. It is also a good candidate for the consent tiers — a read-only tier
should not be able to disable a system extension.

Open questions a builder must answer rather than assume: what happens when the
disabled folder does not exist (create it, or refuse?); whether re-enabling has
to remember where the file came from or can assume `Extensions`; and whether the
68K guest serves it at all.

## A refused `stream.start` closes its bracket (2026-07-31)

The bracket is opened optimistically — `activeStreamId` is set before the guest
has accepted — and its id is held by no pending map, so `recordGuestError` had
nothing to match: the refusal set `lastGuestError` and the bracket stayed open
on a stream that was never running. The 68K guest refuses `stream.start` every
time (`send_error_reply`, `now-guest-68k/src/core/wire68.c`), which makes this
that machine's ordinary behaviour rather than an edge case. `GuestListener` now
recognises its own bracket id: it closes on the refusal, with the guest's own
reason, and records the `stream.start` family through `observeFamily` in both
directions. **Tested, and mutation-proven both ways; no part of it has met a
Macintosh.**

**Unverified:**

- **Nobody has watched a real 68K Mac refuse a stream.** The whole arc is
  proven against a fake guest that answers `not-implemented` on cue. What that
  cannot show is what the person sees: the Screenshots page should say the
  machine does not serve live streaming and grey the button, instead of sitting
  on "Waiting for the first frame…". That is the gate, and it wants the
  PowerBook rather than an emulator, because the emulated guest is the one that
  serves the family.
- **A guest that serves the start and refuses a STOP is reasoned about, not
  observed.** Such a guest closes on the refusal rather than on the five-second
  fallback, and its `stream.stop` stays `unproven` rather than being recorded as
  a "no" — the three stream messages share one id, so the listener attributes a
  refusal to the open rather than guessing between them. No guest on the wire
  does this today, so the branch is untravelled.
- **The two capability stores still both exist.** `familyObservations` on the
  listener now has the `stream.start` answer, and `GuestCapabilityRecord` — the
  page-side store that exists precisely because the listener could not see this
  refusal — records it separately from `ScreenshotModuleModel`. Whether one of
  them should now absorb the other is a question this change makes askable and
  did not answer.

## The live stream reached the agent surface, and the bracket is a lease (2026-07-31)

`now_stream_screen` closes the last three unnoticed gaps in
[mcp-coverage.md](mcp-coverage.md) — `stream.start`, `stream.stop`,
`stream.refresh` — as **one row with three intentions**, so that list is now
empty. **Tested throughout; no part of it has met a Macintosh.**

**Unverified, and the first one decides whether the row should exist:**

- **Nobody has measured whether a frame is cheaper than a capture.** The whole
  premise is that an open bracket has the guest capturing continuously, so a
  frame is *waiting* rather than *starting* — against a capture measured at
  0.5–0.6 s on the 1400c. If it is not clearly cheaper on metal, the row's
  reason for existing is wrong. The procedure is section 8 of
  [metal-and-ux-review.md](metal-and-ux-review.md).
- **The default pace of 1000 ms was argued, not measured.** It exists because
  the contract's absent-means-the-guest's-floor (~15 fps) is a Macintosh
  grabbing fifteen screens a second for a caller that reads one per call. The
  right number is a measurement nobody has taken.
- **The ownership rule has never met a real companion.** Both halves are
  mutation-proven against injected values — a pid set and a movable clock —
  and both rest on an assumption about a real MCP companion's process: that it
  outlives a single call and dies with its client. If that is wrong, the
  liveness half is dead weight and the lease is doing all the work.
- **Nobody has seen contention happen.** An agent's stream turns the person's
  live view on and greys out their Capture button; the sentences that explain
  that, on the Screenshots page and on the Agent page, have not been in front
  of anybody.

**Three decisions worth revisiting rather than defects:**

- **`readOnlyHint: true`, so the row sits at the Read Only consent tier.** It
  is honest — a stream observes and changes nothing — and it means a machine
  that consented to being *read* has consented to a bracket that keeps
  reading, for as long as an agent keeps calling. **The two tiers cannot
  express duration**, which is the same gap `now_reveal_item` fell into from
  the other side, and more evidence for the middle tier. Declaring the row
  non-read-only to buy Full Access was rejected: it would corrupt the
  annotation agents actually read.
- **No maximum duration.** An agent that keeps asking for frames is watching,
  and a ceiling would be a number with nothing behind it. The person can end
  any stream in one click. The cost is real and stated: a calling agent can
  hold a 1400c's screen lane indefinitely.
- **Capture does not end an agent's stream.** The person wins by clicking Stop
  Streaming, not by pressing Capture — a button that says Capture and also
  silently ends somebody else's work does two things and shows one. If the UX
  pass finds that annoying enough, the other design is a small change.

**One lesson that generalises past this row**, recorded in
[source-text-gates.md](source-text-gates.md): **an asynchronous negative
assertion is a gate that cannot fail.** Two ownership guards were deletable
with the suite green because "no `stream.stop` was sent" was read off the fake
guest immediately after the call, before the message could have arrived. The
cure is ordering against the wire, not sleeping — and applying it failed on
unmutated code, which is how a real lease-renewal defect was found.

## The agent surface can be seen, and refused (2026-07-31)

[Plan 006](plans/2026-07-30-006-feat-now-mcp-module-and-guest-consent-plan.md)
is built except its guest-side half. The host tracks companions, an **Agent**
module shows what they have done, and `HostProjectionDispatch` refuses a call
the connected machine has not consented to. **Tested throughout; no part of it
has met a Macintosh, and no person has looked at the pane.**

**Unverified, and the list is the point:**

- **Nobody has seen the module.** Everything asserted about it is about the
  model's words, not how they land in a window. The state most worth looking at
  is `.neverAttached`, because it is what the pane says on most machines for
  most of their lives. A screenshot on the host Mac closes this.
- **No real companion has ever attached.** Presence, the 120-second active
  window and the `LOCAL_PEERPID` identity are all reasoned rather than observed
  against real agent traffic. Pid reuse can merge two short-lived companions
  into one — it undercounts rather than inventing, and is documented where it
  happens.
- **The ceiling has never met a guest that answers.** No guest sends
  `hello.agent` yet except the PPC guest's hardcoded `full`, so `disabled` and
  `read-only` have been exercised only against fixtures.
- **The audit stream is per-launch and in memory**, unlike the log, which can
  persist. A person looking for last week's agent activity needs the log.

**Two decisions worth revisiting rather than defects:**

- **`now_reveal_item` derives Full Access, against plan 006's stated intent
  that reveal is safe.** Not a bug and not a slip: the row publishes
  `readOnlyHint: false` because it takes over the screen of whoever is sitting
  there, and the tier derives from the published annotation rather than a
  hand-maintained list — which is one of that plan's own stop conditions. The
  real cause is that **two tiers cannot express reveal**: derive from
  `readOnlyHint` and it is Full Access, derive from `destructiveHint` and so is
  *upload*, which writes to somebody's disk. Reveal is the case that fell in
  the gap when read / safe-write / full collapsed to two, and it is the
  evidence for reinstating the middle tier when something has actually used the
  first two.
- **Silence still fails open.** Recorded in the schema as a decision, not a
  property, with the installer's arrival named as the moment to revisit.

**One known skew:** a host built before this change rejects an audit report
carrying the new `denied` outcome. It costs one log line on a mixed install and
never a failed call — deliberately cheaper than bumping the local protocol
version, which would make such a host reject every request instead.

## Debts the parity phase left behind (2026-07-31)

Twelve capabilities landed across twenty-six projection rows. These are the
things that arc noticed and did not stop to fix, collected here rather than
left in twelve agents' reports.

**Gates that were not what they claimed:**

- **Two source-scanning gates were decorative and nobody knew.** The `hello`
  seam gate and the `build` gate each searched raw source for identifiers that
  their own explanatory comments also contained, so a mutation deleting the
  real call left each gate reading its own prose and passing. The `build` gate
  shipped that morning, mutation-proven at the time, and was hollow by lunch.
  Both now share a comment-stripping reader. **Whether a third exists is being
  audited**; the result belongs beside this entry.
- **`MCPCoverageTests` catches an omission and not its inverse.** A capability
  that fails to add a `familyPolicy` row is named loudly. One that adds a row
  for a *command*, which needs none, passes in silence. Found by the machine-
  facts row, which has a test whose docstring claims the asymmetry and
  demonstrates it.
- **The guest-identity guard fires on prose.** It scans `Projection/` for guest
  names with comments included and has rejected **doc comments four times this
  week**, once per agent, costing an amend each. It is right about the rule and
  over-broad about the medium.

**Timeouts classified wrong, twice:**

The batched verb edit assigned each new operation a local receive window, and
two were wrong in the same direction — a host bound shorter than the work it
was waiting on. `guest_file_mutation` took the 2-second read-only window
against a 20-second guest-side change watchdog, so a slow `PBCatMove` could
time out locally on a call the machine then completed. `census` took the same
2-second window although its `overview` probe synthesizes every other probe.
Both were patched by whoever tripped over them. **The whole table deserves one
pass**, because the third instance will present as a machine fault.

**Unexercised:**

Ten of the twelve capabilities have never crossed a real wire — only capture
and addressing are metal-verified. The capability ledger reads `unproven` on
every guest by construction for several families, because the listener records
no observation for them. That is honest and it means the first real call is
also the first evidence.

**Still open by decision:**

Streaming (`stream.start`/`.stop`/`.refresh`) is the last unnoticed gap and the
one genuinely undecided item. The 68K half of download stays a planned gap
until `HostProjection` can express a **disjunctive** requirement — `requires` is
a conjunction today, so a row needing "`file.get` or the `put` verb" cannot say
so.

## The machine's vote is carried (2026-07-31)

`hello` now has an optional `agent` field — `disabled`, `read-only`,
`full`, or nothing — and the host decodes it, keeps it on the session
health record, the roster row and
`AgentIntegrationSessionHealth.Guest`, and writes it into the connect
log line when the machine said something. That is section 2 of
[plan 006](plans/2026-07-30-006-feat-now-mcp-module-and-guest-consent-plan.md).
**Tested**; nothing here has met a Macintosh.

The three unfinished things, and they are unfinished on purpose:

- ~~**Nothing enforces it.**~~ **Enforcement landed the same day** — see
  "The agent surface can be seen, and refused" below. It went exactly
  where this entry said it belonged: `HostProjectionDispatch`, on the
  same line as the audit event. A machine sending `disabled` is now
  refused.
- **Absence fails OPEN**, which is a decision recorded in the schema and
  not a property of the field. It matches today's default-on behaviour
  and keeps every deployed machine working. The moment to revisit is when
  the installer ships and silence stops being the common case.
- **Nothing on either machine can change the answer.** The PowerPC guest
  answers `full` from `now_agent_access()`, a function with no
  preference and no switch behind it yet; the guest toggle, the mid-call
  prompt and the installer's AI-BAD path all land there. NOW-68K sends
  no `agent` at all — it has no switch to report and no installer, so it
  is a guest that has not been asked rather than one that answered.

## The parity slice's capture lane and addressing met the PowerBook (2026-07-30)

Two capabilities of the [parity
slice](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md)
had been proven at the codec and socket layers and never on hardware.
Both have a gate now, and both ran on the **PB1400c (10.91.5.47) on
2026-07-29** — `MetalCaptureProjectionTests`, `MetalAddressingTests`,
over `MetalAgentLocalSurface`. The rig is the shipped stack at every
layer but the dispatch, which the file writes itself, mirroring
`App.swift`.

### Metal-verified

`now_capture_screen`, end to end from the agent face:

| | measured | notes |
|---|---|---|
| screen | 800x600 | |
| PNG at 1bpp | 25,110 B in 4 pages | 8 KiB pages |
| PNG at 8bpp | 38,833 B in 5 pages | |
| largest local response | 11,643 of 16,384 B | the local cap, enforced by the code that enforces it in production |
| guest-side transfer | 278–349 ms | |

The claim no fake can make is the one that carries the entry: the
reassembled bytes are decoded with ImageIO and their pixel dimensions
checked against what the guest reported. **Mutation-checked** — one
flipped byte in one fetched page fails the run as
`now-capture-digest-mismatch`.

Addressing, four of the five selector states:

| selector | outcome | status |
|---|---|---|
| absent | answered by the driven machine | metal-verified |
| the driven machine's id, and its session id | answered by that machine | metal-verified |
| a machine that is not connected | `now-guest-not-connected` | metal-verified |
| a session id whose connection ended | `now-guest-session-ended` | metal-verified |
| a machine connected but not driven | `now-guest-not-addressed` | **not verified — see below** |

**Mutation-checked**: bypassing the refusal has the PowerBook answer for
a machine nobody has ever seen, which is the substitution the scheme
exists to prevent.

### Not verified: the fifth selector state

`now-guest-not-addressed` means *connected but not driven*, and **one
connection cannot be in that state** — the host refuses to re-point the
console out from under whoever is at the machine, so the condition needs
two live sessions to exist at all. `testAConnectedButNotDrivenMachineIsRefused`
runs when a second peer is present and reports exactly what it needed
when it is not.

It was exercised only with a supplied second peer
(`NOW_METAL_SECOND_PEER`), and the distinction matters: the refusal is a
decision **the host** makes — it holds two sessions, drives one, and a
caller named the other. Nothing about that decision depends on what the
far end of the second socket is, only on its being there. So a run with
`tools/fakeguest.py` as the second peer is evidence about the **host's
addressing decision and about no guest at all**; per AGENTS.md nothing
verified against that harness may be called metal-verified. Unconditional
coverage wants a second real Mac — or a QEMU guest — dialling the same
port while the run waits.

### `capture.request` reads `unproven` on every guest, by construction

The capability ledger cannot say more, and the reason is not the guest's:
`GuestListener.requestCapture` is **not wrapped by `observing`/`observeFamily`**,
so a settled capture records no family observation, and `CaptureFailure`
carries a human sentence rather than the guest's typed refusal code, so
there is nothing for the ledger to file even if it were wrapped. A
capture is also deliberately not probed — it costs a whole screen grab
and holds the connection's only transfer lane — so nothing else settles
the row either. `unproven` is the truthful answer and leaves the
capability callable; the note is in
`AgentIntegrationCapabilityLedger.swift` beside the row. Fixing it is a
behaviour change in the listener: give the capture lane a typed code and
put the request through `observing`.

### `census.request` joins it, and its page bound is unmeasured

`now_hardware_census` landed against the same two gaps and neither is
new to it.

- **`unproven` on every guest, by construction.**
  `GuestListener.requestCensus` is not wrapped by
  `observing`/`observeFamily` either, and the listener's own failure path
  folds a guest's typed refusal code into a `CensusReport` note
  (`"[code] message"`) rather than keeping it typed — so there is nothing
  for the ledger to file even if the request were wrapped. The family is
  also not probed, and its reason is sharper than capture's: the probe
  argument is **required**, so a probe would have to choose one, and the
  registry's default is `overview` — the synthesis that arranges what
  every other probe read. Same cure as capture's: a typed code plus
  `observing` in the listener.
- **The adapter's 30 s page bound is a guess, and declared as one.**
  `census.request` has no guest-side watchdog, so
  `AgentIntegrationCensus.pageTimeout` is the only bound on a probe. Not
  one census probe has ever run against a Macintosh
  ([contract-coverage.md](contract-coverage.md)), so the number is the
  same order as the measurements beside it — `catsearch` ~20 s per pass,
  the `software.list` sweep ~4 s — and the first metal run is what
  replaces it. The local surface's window for the operation was moved off
  the 2 s read-only one at the same time, for the same reason: a page is
  16 rows, and what costs is the probe.

### `software.list` is the family that DOES settle, and no agent has settled it

Worth recording as the contrast to the two rows above rather than as a defect,
because it is the shape those two are missing: `GuestListener.listSoftware` IS
wrapped by `observing`, so an ordinary `now_software_inventory` call moves the
ledger row to the guest's own answer and makes a later `probeCostly` report
free. That is the cure capture and the census want, already working one lane
over.

What is unverified is everything downstream of it:

- **No guest has served this family to an agent face.**
  [contract-coverage.md](contract-coverage.md) already records the software
  family as *tested only* — no guest has run the sweep for anyone — and
  `now_software_inventory` inherits that unchanged. The 25 tests behind it are
  over a real socket and a fake guest.
- **The ~4 s sweep figure is one disk's.** It is metal-measured, but by
  `catsearch` on the 1400c. NOW-68K's `apps` path has two shapes the number
  has never covered: the 48-FSSpec cache, and the `PBCatSearch`-unusable
  fallback that walks the volume root. Neither has been timed on that machine,
  so nothing here knows whether the listener's 30 s watchdog is generous or
  tight there.
- **The `note` sentences have never crossed a real wire.** Both are asserted
  against the guest's own literals, which proves the host carries whatever it
  is handed; it does not prove a 68K Mac with 60 applications actually emits
  the truncation note rather than a short page and silence.

### The face-reachability proofs are textual, deliberately

Three coverage gates landed with the slice, and none of them proves what
a reader may assume:

- **`HostFaceReach.reached(file:symbol:)` is `file.contains(symbol)` and
  nothing more.** It catches the failure it was built for — the
  affordance deleted or renamed, the file gone — and cannot catch an
  affordance that is still *spelled* and no longer *reachable*: a call
  site wrapped in `if false` or `#if`, a control left permanently
  `.disabled(true)`, a symbol surviving only in a comment or a
  `#Preview`, or the whole view no longer instantiated because its module
  left the sidebar registry with file and symbol untouched. Documented at
  the declaration rather than mechanised, because the mechanical version
  is a Swift-source reachability analysis and the honest cheap gate plus a
  stated limit beats a gate whose weakness nobody wrote down.
- **The MCP-face check is textual over `NOWMCPServer`'s registry loop** —
  it matches `registry.projections.map` and
  `registry.projection(named:)`. A `guard … continue` added inside the
  loop body would skip a row without changing any matched string. It is
  still the stronger of the two: a loop fails uniformly, where a
  hand-built pane fails one row at a time.
- **`docs/mcp-coverage.md` and `MCPCoverageTests` are tested only.** No
  part of the registry-versus-contract join has been read against a
  guest; the `Served` column claims only what a dispatch table answers.
  `contract-coverage.md` owns the how-far-proven axis and this file does
  not duplicate it.

### Nine served capabilities that nothing asks for

`docs/mcp-coverage.md` derived the gap table and found the hand analysis
had undercounted: **nine capabilities are `unnoticed`** — served by a
guest right now with nothing in this repository arguing for their
absence. They are absent because the question never came up, which is the
`process.list` drift `command-parity.md` was written for, one layer out.

`stream.start`, `stream.stop`, `stream.refresh`, `catsearch`, `gestalt`,
`putstat`, `reveal`, `shotdiag`, `vprobe`. Two are worth naming on their
own:

- **`gestalt`** is the largest single gap: one PPC verb answering CPU,
  memory, OS, network and hardware for the whole machine, served
  throughout, reachable from **no face**.
- **`shotdiag`** is the verb that found the 180c's 24-bit addressing
  defect — precisely what someone standing at a misbehaving machine wants
  — and is reachable from nothing.

They were ten; `capture.cancel` left the list by being **decided** rather
than by being built.

**Updated 2026-07-30: all three diagnostics are now reachable, and only the
streaming bracket is left on that list.** `vprobe`, `shotdiag` and `putstat`
are `now_framebuffer_probe`, `now_capture_diagnostics` and
`now_transfer_diagnostics`, plus a Diagnostics module — three rows for one
plan item and one wire operation, because `requires` is a conjunction and no
guest serves all three (the argument is in `docs/mcp-coverage.md`, "One
capability is three rows"). **Tested, not metal-verified**: nothing in this
row set has run against a Macintosh, and the two unverified things worth
naming are that the module's per-card availability reads the connected
machine's own `help` table (so a machine that never answers `help` leaves all
three cards `unknown`, which is stated rather than guessed past), and that the
host's 40 s bound on a diagnostic is the **only** watchdog in the chain —
neither `vprobe` nor `shotdiag` has a guest-side give-up, so a 68030 slower
than that bound would read as a refusal and nobody has timed one.

### `AgentIntegrationLocalProtocol.swift` is the real serialization point

Any capability needing a new client verb edits four things in that one
file — an operation case, a result case, a response field and init
parameter, and a strict-decode branch — at the tails of three lists.
**Those three tails conflicted on every merge that touched them this
slice**: the audit gate, the codec fix, its harvest, and the capture
template. Always trivially, always needing a human decision. It belongs
on the collision-hazard list beside `contract/asyncapi.yaml` and the
`scripts/test-native` manifest: **one owning agent per phase**, and
prefer batching a phase's verbs into a single edit over one agent per
capability. W0.1's registry removed the tool-enum switch, which made the
shared-file hazard look solved; it was displaced here.

### Four hand-maintained capability lists survive the registry

So "one file plus one row" is true of the **row** and not of the
capability. Each is trivial alone; eight times over it is a serialized
edit on shared test files.

| List | Where |
|---|---|
| known-names set | `HostProjectionRegistryTests` |
| approved-tool list | `NOWAgentCompanionTests` |
| exhaustive switch over the operation enum | `AgentIntegrationSocketTests`, `NOWAgentCompanionTests` |
| assertion matching a doc heading that names the tool **count** literally | `MCPCoverageTests` (`## What the thirteen reach`) |

The last is the worst: every new capability renames a heading in
`docs/mcp-coverage.md` and a string in a test. Worth fixing before a wide
phase, not during one.

### An integer command argument cannot ride `CommandRequest.args`

`CommandRequest.args` is `[String: String]`, so every typed argument
reaches the guest quoted. A guest reading an integer argument uses
`now_json_find_int`, which is `strtol` on the byte after the colon —
`strtol("\"40\"")` is 0. The failure is silent in the worst way: `tail`'s
`run_tail` clamps 0 up to 1, so a caller asking for forty log lines gets
**one**, with `ok:true` and nothing anywhere saying so.

Nothing had met this edge because `launch`, `reveal`, `help` and the census
all take strings; `tail` (P1 #9) is the first host-side caller whose typed
argument is a number. It sends the count on `line` instead, which the
contract declares for that verb (`x-commands.tail.x-line`) and which
`run_tail` reaches precisely when no typed `lines` is present, with a test
that fails if somebody tidies it back into `args`.

**Unfixed, and it will bite the next numeric argument.** The fix is a typed
args value on both sides of the wire, which is a `contract/asyncapi.yaml` +
both-guests change and belongs to one owning agent, not to whichever
capability trips over it. Until then: an integer argument goes on the line,
and a reviewer seeing a number in an `args` dictionary should ask what the
guest parses it with.

### The guest log is readable by an agent and has not been read on metal

`now_guest_log_tail` (P1 #9) is **tested, not metal-verified**. Two things
about it are worth knowing before it is trusted on a real machine:

- The audit line it writes under `app` shares the state of every other
  agent-facing log line — see *The agent audit line has never been read on
  a real run* below.
- It is the first row that returns text the machine wrote, so it is the
  first that can disclose a name from **outside** `guestRoot`: the guest's
  own `get`, `put` and `files` lines quote the items they handled. That is
  argued and recorded in [mcp-coverage.md](mcp-coverage.md) rather than
  accidental, but it is a widening over the Files family's authority and a
  reviewer should agree with it explicitly rather than inherit it.

### A schema rejection surfaces as the wrong error

`AgentIntegrationLocalServer` replies to a `decodeRequest` failure with
`.init(error:)` and no request id, so the response carries
`requestID: nil`. The client checks the id first
(`decoded.requestID == request.requestID`), so the caller sees **"Local
response request ID did not match"** rather than the `invalid-request`
error anyone would grep for. Minor, and explanatory: it is why the
`guestSelector` defect below presented as a mismatched id rather than as
the schema rejection it was.

### Dead code

`AgentIntegrationLocalProtocol.strictObject(_:keys:)` — the private
overload that also requires the keys to be *present* — has no callers.
Both call sites use `strictObject(_:allowedKeys:)`.

### `vprobe`'s `CopyBits failed` is not `capture.request`'s

`MetalCaptureProjectionTests` was written expecting the guest might
refuse, because an earlier `vprobe` on this PowerBook reported `CopyBits
failed`. **It did not reproduce**: two clean captures at two depths. The
two paths differ — `vprobe` measures framebuffer reads on its own bands,
the capture lane stages through the guest's normal screen grab — so a
`CopyBits` failure in one is not evidence about the other. Recorded so
nobody conflates them again, and so the reverse is also clear: had the
capture been refused for that reason, it would have been a finding about
this machine and not a defect in the gate.

**This distinction is now carried by the product rather than only by this
ledger (2026-07-30).** `vprobe` has a face on both sides — the
`now_framebuffer_probe` tool and the Diagnostics module's first card — so the
misreading is available to more people than the two who wrote these
paragraphs. The tool description states it, and the card states it **before**
the probe is run rather than beneath a number that has already sent someone
looking for a bug in Screenshots.

## `PRODUCT_VERSION` cannot tell two builds apart (2026-07-30)

### Broken

`PRODUCT_VERSION` is `"0.1.0"` in
`now-guest-ppc/src/core/product_identity.h` and was **also `"0.1.0"` on
the build previously deployed to the 1400c**. It rides `hello` and is
what `now_session_health` reports, so the one string a host has for "is
this the build I just deployed" answers the same for every build there
has ever been.

This cost a real misdiagnosis on **2026-07-30**: a stale guest on the
1400c was failing every exec test, and the version string gave no signal
that the machine was running old code. The metal gates now assert which
build answered from the host-observed address and from the guest's own
verb table, **never** from `PRODUCT_VERSION` — which is the right
workaround and not a fix.

The fix is a build identity that changes when the build does. NOW already
has `build_stamp.c`, which CMake touches at the end of every build and
AGENTS.md already tells a human to check before believing a test result;
putting that stamp where `hello` can carry it is the cheap version.
(Hypothesis, not measured: the 68K guest has its own version string and
is likely to have the same weakness.)

## The agent audit line has never been read on a real run (2026-07-29)

### Unverified

Every capability the MCP face invokes now emits one audit event, and the
host writes it under the `agent` area of its log
([agent-integration.md](agent-integration.md#every-agent-call-leaves-a-trace)).
The gate is mutation-checked and the whole path is exercised over a real
private socket in `NOWAgentAuditTests` — but with a fake host at the far
end. **Nobody has yet driven the running app from a real MCP client and
read the lines out of `~/Library/Logs/now-logs`.** The host app's own
handler for the operation (the `.audit` case in `App.swift`) is the one
piece with no automated cover, because nothing in this tree tests that
closure; the line's format is tested one layer in, at
`AgentIntegrationAuditLog`.

Two known gaps, stated rather than left to be discovered:

- A call still waiting on a 32-second launch has not been logged yet. The
  event is emitted once, when the outcome is known — a begun/ended pair
  would double this face's local round-trips per call — so a launch in
  flight is invisible until it settles, and one that takes the process
  down is never logged at all.
- A malformed `guest` selector is refused by the face before any
  capability is invoked, so it names no capability and emits nothing.
  (Still true, and now true one layer deeper: since 2026-07-29 the codec
  refuses an empty selector as well — same consequence for the audit
  line.)

**The 2026-07-29 metal run did not touch this.** `MetalAgentLocalSurface`
refuses `.audit` by name, along with every other operation that could
change the machine, so nothing about the audit path was exercised on the
PowerBook. This entry stands unchanged.

## RESOLVED: local schema v7's addressing could not survive its own codec (2026-07-29)

### Fixed, and metal-verified

Both defects are fixed on this slice and the path is
**metal-verified on the PB1400c (10.91.5.47), 2026-07-29** for four of
the five selector states. The table, and why the fifth state one
connection cannot reach, are in "The parity slice's capture lane and
addressing met the PowerBook" above.

What the fix is:

- `decodeRequest` admits `guestSelector` — once, in the top-level
  allowlist, and as a **conditional** per-operation key added only when
  the caller actually sent it, so an absent selector stays absent rather
  than becoming a required field on every operation.
- An **empty** selector is now refused as its own error ("Local request
  names an empty machine") rather than reaching the adapter as a third
  state that is neither nil nor an id. Validated in the codec and not only
  in the companion, because the companion is not the trust boundary: any
  process of this uid can write that socket.
- `decodeResponse` admits `notAddressed` **and counts it in the
  exactly-one-of guard**, beside the operation results rather than outside
  them — the refusal is set *instead* of an answer, so a response carrying
  both is malformed for the same reason two results are.
- `AgentIntegrationAddressingCodecTests` asserts, from a `Mirror` over the
  request type and over the response type, that each allowlist admits
  **every field on it** — derived rather than listed. That is what makes
  the whole defect class visible rather than these two instances of it.

### What was wrong, kept because the shape recurs

Found while adding the audit operation; both were on `main`, both
untested, and `grep -rn "guestSelector\|notAddressed" now-host/Tests`
returned nothing, which is why neither was failing anything.

- `decodeRequest` omitted `guestSelector` from its `allowedKeys` and from
  every operation's `expectedKeys` — a *strict* object check — so any
  request that actually named a machine was rejected as not matching the
  schema. Nil selectors are omitted by the encoder, which is why the
  single-Mac path kept working and the whole machine-id / session-id
  scheme landed 2026-07-28 could not work through this path at all.
- `decodeResponse` omitted `notAddressed` from its allowlist, so the
  refusal `SocketAgentIntegrationClient` is specifically written to pass
  through as itself arrived as `now-host-invalid-response`: a real refusal
  wearing a protocol error.

Two omissions of one shape is the lesson, not either omission: an
allowlist and the fields it is supposed to admit are two lists that drift
silently, in both directions, and nothing observed it here until an
unrelated feature needed the field.

## NOW-68K has a hardware census, and none of it has run (2026-07-28)

### Unverified, in the strongest sense on this list

NOW-68K answers all fourteen probes of the contract's `x-census`
registry, on both faces (`census.request` on the wire, the `census` verb
for a person), where it previously answered every one of them `refused`
with the note "no probes implemented". **Not one probe has run on a
Macintosh** - emulated or metal.

That is worth stating sharply because the automated cover looks better
than it is. `test_census.c` (native, 680 checks) covers the page, the
cursor arithmetic, the frame bound and both renderers, and the host
decodes three pinned frames. All of that is the half with no Toolbox in
it. Every PROBE is Gestalt, the GDevice list, `PBHGetVInfo`, the drive
queue, the unit table, ADB, `GetSysPPtr` and the Power Manager, and no
gate in this repository can reach any of them.

What a first pass should look at, in rough order of what could plausibly
be wrong:

- **`drivers`** is the riskiest walk. It reads the Device Manager unit
  table from `LMGetUTableBase`, and a driver's name is a Pascal string at
  offset 18 of the driver header - reached through a HANDLE for a
  RAM-based driver and a POINTER for a ROM-based one (`dRAMBasedMask`).
  The flag is checked rather than assumed, but the check has never been
  exercised. Bad names, or a hang, would point here.
- **`power`** picks its call from `gestaltPMgrDispatchExists`:
  `GetScaledBatteryInfo` (a `_PowerMgrDispatch` selector) where that bit
  is set, the classic `BatteryStatus` otherwise. A 180c under 7.1 is
  expected to take the second path. If the machine takes the first and
  the selector is not really there, that is a crash and not a bad row.
- **`pram`** should read `valid $A8` on a machine with a live PRAM
  battery and something else on the 180c, whose battery is dead (the
  entry below). If it reports `$A8` there, the byte is not saying what
  this probe claims it says.
- **`adb`** should find two devices on the PowerBook (keyboard and
  trackball) and may find none under an emulator, which answers
  `absent` - correctly, and worth not misreading as a defect.
- **`ata`, `pccard`, `pci`** should all answer `absent` on the 180c and
  the Q800, each with its reason. An `absent` there is the probe working.

### What is deliberately NOT served, with the reason

Two of the fourteen answer `refused`, which means this build declined to
look rather than the machine saying no:

- **`scsi`.** The contract calls it the declared exception to
  passive-by-rule - an INQUIRY bus scan is active bus I/O - and says
  attended first runs on real hardware are the expected discipline. The
  180c's internal disk is on that bus, nobody has ever attended a scan
  from this guest, and a wedged target on a cooperatively-scheduled
  68030 is a power cycle. `drives` and `volumes` answer what is attached
  without touching it. **Doing this properly means someone in front of
  the machine**, which is the whole reason it is parked.
- **`selectors`.** The PowerPC guest walks a snapshotted table of
  documented Gestalt selectors; that table is 32 KB of names, against a
  384 KB partition. `identity` carries the rows a person actually reads.

### Cost, measured

The 68K binary grew 197,248 -> 215,808 bytes of code (+18.1 KB, ~4.7% of
the partition), and the census owns two ~1.1 KB BSS pages - one in
`wire68.c` for the wire, one in `commands68.c` for the console, separate
because a request arriving while somebody is reading must not overwrite
the page they are reading. Most of the code is the notes: fourteen
probes' worth of sentences explaining what `absent` means on this
machine. That is the trade this subsystem exists to make.

### Still missing beside it

`gestalt` - the five-group verb - is now the largest thing NOW-68K does
not serve, and it is mostly a renderer: `health.c` already samples the
facts and the census now reports most of them again. A host asking for
it by name still gets `unknown-command`.
## NOW-68K's software listing has never touched a disk (2026-07-28)

`software.list` and the `sw` verb are served on NOW-68K
(`now-guest-68k/src/software/`). The status is **tested**, and the half
that is tested is the half with no Toolbox in it.

### Unverified

- **The sweep has never run.** `n68_swenum.c` is pure Toolbox and no gate
  in this tree can reach it. Nothing has confirmed that `PBCatSearchSync`
  finds a single application on a System 7.1 volume, that the disabled
  sibling folders resolve through `FindFolder`, that the parent-chain
  climb produces a launchable HFS path, or that a folder domain's
  two-catalog cursor lands on the right item at the boundary. The
  emulator (`scripts/q800-68k`) can answer all of those and has not been
  asked.
- **The timing is a guess.** The contract records ~4 s cold for the
  equivalent sweep on a PowerBook 1400c. The 180c is a 33 MHz 68030 with
  a much smaller, much older disk, and nobody has measured it. The
  budget in force is `proc_launch_search_seconds()` (20 s by default,
  shared with `launch`), so the honest statement is that the sweep will
  either finish or truncate inside 20 s — not that it finishes.
- **The pump has never been exercised under load.** The sweep calls
  `proc_yield_ticks()` between slices, which runs `wire_idle()` and can
  re-enter the frame reader. That is the DEFECT 3 path proc68.c
  documents; it is guarded by the same single `pumping` flag, which is
  precisely why the pump was exported rather than copied. Nothing has
  pipelined a second request into a running sweep to watch it hold.
- **48 may be the wrong bound.** `NOW68K_SWLIST_APP_CACHE_MAX` was
  chosen from the memory budget (3360 bytes of BSS), not from a count of
  what is on the 180c's disk. If that machine has 200 applications the
  listing is honest and mostly useless; if it has 30 the bound never
  fires. One `sw apps` on metal answers it.

### Open

- **No `version`, no `running`.** Both are omitted on this guest with
  their reasons written down (contract-coverage.md). `version` is the
  one a person is most likely to want, and the bounded way in exists —
  a page is at most ten entries, so ten resource-fork opens — if the
  heap on a 4 MB machine turns out to tolerate it. That is a
  measurement, not a decision, and it has not been taken.
- **`launch` and the listing do not share a search.** `proc68.c` sweeps
  for one named application and `n68_swenum.c` sweeps for all of them;
  the SHAPE is shared (slice, budget, retry, fallback) and the code is
  not. Two sweeps that drift would disagree about which applications
  this machine has, which is the `two-halves-never-met-in-a-test` shape
  one file over. Worth folding together the next time both are open.

## The 180c's garbled capture was 24-bit addressing (2026-07-28)

### Fixed, and confirmed on metal by remedy

A screenshot taken on the PowerBook 180c saved correctly to that machine's
own Desktop and arrived at the host as **structured noise**. `shotdiag`,
run on the 180c, answered it in one pass:

```
Base          0xFC080000
StripAddress  0x00080000
Addressing    24-bit (!)
Walk row 0    04 0F 0D 07 01 04 02 0E 0F 02 0B 0D 08 01 03 0A
Walk again    04 0F 0D 07 01 04 02 0E 0F 02 0B 0D 08 01 03 0A
Blit row 0    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Verdict       DIFFERS at byte 0 - wrong memory
```

The machine was in **24-bit addressing**, so the top byte of the
framebuffer's address was thrown away and every raw read went to
`0x00080000` — main RAM. `Walk` and `Walk again` agreeing proves the screen
held still, so the run is valid. `Blit row 0` (CopyBits) is correct, which
is why the on-disk PICT was always fine: QuickDraw resolves addressing
itself. **Confirmed by remedy** — 32-bit addressing switched on in the
Memory control panel, and captures crossed correctly at once.

### Why the earlier refutation was wrong, and the lesson in it

A previous pass retired this exact hypothesis on the grounds that
`vprobe`'s fidelity sweep reported **480/480 rows matching** at base
`0xFC080000` (docs/vram-readout-68k.md, 2026-07-25), so the base must have
been reachable. Re-run beside `shotdiag` three days later, the same sweep
on the same machine reported **480/480 differ, 1st 0**. Nothing had
changed but the Memory control panel setting, which had reverted on its
own — **the PRAM battery is dead**.

So `vprobe` was broken in exactly the same way as the capture, and the
inference drawn from their difference ("the difference between them is the
file the capture opens first") was drawn from a measurement taken in a
different machine state. Two runs of one probe on one machine are not
comparable unless the addressing mode is recorded beside them. `vprobe`
now carries an **Addressing** row for that reason.

### The fix

`core/screen68.c` decides, from the machine's actual state, how a raw read
reaches the framebuffer:

- **32-bit capable** (Gestalt `gestaltAddressingModeAttr` /
  `gestalt32BitCapable`, confirmed by performing the switch once and
  checking low memory `0x0CB2` moved) → `SwapMMUMode(true32b)` around the
  VRAM copy, always, whichever mode the machine is currently in. The mode
  can change between the check and the read — the File Manager runs in
  between on the capture path — so the switch is not conditional on it.
- **not capable, address survives 24 bits** → read it as it is.
- **not capable, address does not survive 24 bits** → refuse the capture
  with a reason. Wrong pixels are worse than a refusal.

**24-bit is the expected state of a vintage Mac, not an anomaly.** Most of
these machines have dead PRAM batteries and come up with 32-bit addressing
off however it was left. Asking a human to set it is not a fix: it reverts
on the next power cycle and reads as a regression.

**The switch wraps the VRAM copy and nothing else.** While switched, the
machine is in an addressing mode the rest of the system was not told
about, so no Toolbox or OS call may be made — and the staged capture
interleaves the read with PackBits and File Manager writes. The copy goes
out through a `row_copy` hook on `N68ShotWireSink`, which keeps
`n68_shotwire_emit()` Toolbox-free (the host `cc` still compiles and drives
it) while the dereference itself happens where the Toolbox is allowed. The
hook is **required**: a NULL is refused rather than filled in with memcpy,
because a caller that forgot would send main RAM at full speed with every
test green.

**`StripAddress` is a different question and is not the fix.** Stripping
`0xFC080000` *is* the bug, spelled deliberately. It is used as a predicate
on the screen's base ("does this address survive 24-bit mode?") and as a
normalisation of the offscreen **band's** base, which is a Memory Manager
block whose top byte is master-pointer flags in 24-bit mode. It never
rewrites the framebuffer address.

There are exactly two addressing modes on a Mac, 24-bit and 32-bit. There
is no 16-bit mode; "16-bit" in `vprobe`'s readout is a read WIDTH and
"8-bit" beside the screen is colour DEPTH.

### Unverified

**Tested, not metal-verified.** The fix has not run on the 180c — nobody
here has a machine. Both guests cross-build, `scripts/test-all` is green,
and the emitted 68K code contains the `_SwapMMUMode` trap (`0xA05D`)
inline, so it links. What a metal pass should show, on a machine left in
its default 24-bit mode:

- `shotdiag` → `Addressing 24-bit`, `Raw read SwapMMUMode to 32-bit`,
  `Walk row 0` equal to `Blit row 0`, `Verdict identical - the base is
  right`.
- `vprobe` in the same session → `Addressing 24-bit, 32-bit for reads` and
  `Fidelity MATCH (480 rows)`, with the bandwidth rows unchanged from
  2026-07-25 (a switch is two traps against passes of 150 ms).
- A capture over the wire, decoded, showing the 180c's screen — with no
  visit to the Memory control panel.

If `Raw read` reads `REFUSED - unreachable`, the machine reported itself
not 32-bit capable and the framebuffer is above 16 MB; that combination is
believed impossible and would be the thing to report.

## Two guests on one port (2026-07-28)

The host serves several guests at once, told apart by the identity in
their `hello` (the name, trimmed and case-folded). Both PowerBooks can
dial one port, and the window can be pointed at either. **Tested, not
metal-verified** — neither machine has been near this, and the emulator
has not either. Nothing below has ever run against a real classic Mac.

One guest is ACTIVE: every request-shaped call (`runCommand`, `exec`,
`listFiles`, `requestCapture`, the modules, the agent projection) drives
that one. What a guest gets regardless is the half it initiates — its
pings, its pushes, and our share served back down its own socket.

### Choosing which Mac

`GuestListener.selectGuest` is now reachable two ways: a pop-up in the
sidebar footer, which appears only when a second machine is connected,
and **Guest ▸ Drive** in the menu bar, rebuilt as the menu opens.

Each module model decides for itself what a switch means to it, and the
decisions are not the same — the reasoning is at each `Snapshot` type,
and the mechanism is one small cache (`GuestScopedState.swift`):

- **Kept per machine**, because it cannot be re-fetched or is expensive
  to: the console scrollback, history and completions; the screenshot
  history; the census dossier; the software inventory; the Files
  breadcrumb and listing.
- **Discarded on a switch**, because it goes stale on its own machine
  faster than a person can read it: the process table. Also every
  in-flight thing — stream brackets, sweeps, loads — which the listener
  has already failed by then.
- **Dropped rather than parked**: a queue of files still waiting to be
  sent. They were meant for the other Mac; the module says so.

A machine that DISCONNECTS keeps its parked state (the same machine
dialling back in finds its own scrollback), except the software
inventory, which dies with the connection exactly as it did before —
a redeployed guest has a different disk.

### A pushed capture now says which Mac sent it

`CaptureDelivery` carries the sender's name and key, stamped in
`Session` from the socket it arrived on. A background machine's push is
filed under that machine — it no longer appears in the driven Mac's
history — and the system notification names the right Mac. It is still
auto-saved to the landing pad, and it does NOT take the clipboard.

**No contract field was added and none was needed.** Which machine sent
a message is answered exactly by which socket it arrived on; a name in
the payload would be a second, weaker copy of that fact. Both guests are
unchanged, and neither now differs from the other.

Visible consequence, not yet addressed: a background push is announced
and saved but appears in no list until you switch to that machine.

### Open

- **Pending requests share one id space across guests.** Ids are drawn
  from one host-side sequence so they cannot collide, and answers from a
  non-active connection are now dropped rather than settling somebody
  else's waiter — but the maps themselves are still flat on the listener
  rather than per guest. A switch fails what was in flight instead of
  keeping it.
- **One stream, one capture, one put, host-wide.** Two guests cannot
  stream at once; the second is refused `stream-busy`. Honest, but a
  limit nobody chose for its own sake.
- **Nothing on screen says a background Mac is doing anything.** The
  picker names the machines and nothing more: a push that landed under
  the other one, a transfer it started, an error it reported are all
  invisible until you switch to it. The roster is the obvious place for
  a badge, and it does not have one.
- **One stream, one capture, one put, host-wide** (see above), and with
  it the reason MCP addressing is an assertion rather than a switch.

### A guest is addressed by a machine id, mapped to its address

Identity used to be the folded `hello.name`. Two consequences, both
wrong: two Macs calling themselves the same thing were ONE guest and the
second was refused `busy`, and — because a deployed guest runs under its
MacBinary name and that name carries the version — every redeploy minted
a phantom machine. An identifier that changes when you deploy is not an
identifier.

There are three identities now, kept apart on purpose
(`now-host/Sources/Host/GuestIdentity.swift`):

| | what it is | who asserts it | changes when |
| --- | --- | --- | --- |
| **machine id** | `pb1400c` — the handle a person or an agent types | the HOST assigns it | only a human rename |
| **session id** | `pb1400c-<uuid>` — one connection | the host mints it at hello | every dial |
| **address** | the peer IP off the `NWConnection` | host-OBSERVED | DHCP |
| display name | `NOW Guest 0.14` | the GUEST asserts it | every deploy |

The roster pairs them: the picker and the Drive menu read
`pb1400c — NOW Guest 0.14`, the log line adds the address, and a caller
gets the id and session id together.

**No contract change, and none was needed.** The address is host-side
knowledge, arriving on the socket; the name is already in `hello`.
Neither guest is touched, neither now differs from the other, and
`docs/contract-coverage.md` is unchanged because nothing about what a
guest SERVES moved.

**Where the id comes from.** Assigned host-side and persisted host-side
(`GuestRegistry`), anchored on the observed address plus a fingerprint
(the hello's os and its name with the version stripped). The reasoning,
including why Gestalt cannot supply one — no serial number;
`gestaltMachineType` is a MODEL; `gestaltSerialAttr` is serial PORTS —
is written out at the top of that file. First sight is `guest-1`,
addressable with zero configuration and flagged auto-assigned; a human
rename makes it `pb1400c`.

**The rules, and what each costs.** An id never silently rebinds:
adoption needs address AND fingerprint to match, so a stranger inheriting
a DHCP lease does not inherit `pb1400c` — and the same rule means a Mac
whose lease changes costs the human one rename. Two machines never
collapse onto one id: ordinals are unique and a rename onto a taken id is
refused naming the holder. Where the address cannot tell machines apart —
loopback, and therefore every emulated guest and every test — a slot
completes the anchor, and the row says `idIsAnchored: false` rather than
pretending.

**The MCP surface is addressable** (local protocol v7). Every tool takes
an optional `guest`: a machine id ("whatever is connected to that Mac
now", which follows a reconnection) or a session id (precise, and refused
`now-guest-session-ended` once that connection is over rather than being
answered by its successor — the same staleness contract the process and
quit references already keep). `now_session_health` reports the driven
machine's reference and the WHOLE roster, so a caller can discover the
ids. Availability by capability is untouched: this decides which machine
a question reaches, never what a machine can do.

Open, from this slice:

- **Addressing is an assertion, not a switch.** Naming a machine the host
  is not driving is refused `now-guest-not-addressed`, with the driven
  machine and the roster in the message. It cannot be answered, because
  the request-shaped listener API drives one session at a time and every
  waiter map is still flat (above). Making an agent call re-point it
  would also take the console out from under whoever is sitting at it —
  a policy question, not just a plumbing one.
- **Not every projection names the guest yet.** Session health, the
  process snapshot and the roster do. Launch, quit, artifact transfer and
  the Files results still carry only the session UUID. They cannot answer
  for the wrong machine — addressing is checked before any of them — but
  a caller reading one of those results alone still has to remember what
  it asked about.
- **The real fix is still a guest-minted id in `hello`.** A stable id the
  MACHINE knows would survive a DHCP change without a rename and would
  tell two emulated guests apart. It is a contract change and both
  guests, deliberately not half-implemented here. The candidates and
  their failure modes — boot volume creation date (a cloned disk yields
  two machines with one id), a self-assigned id in the guest's own
  preferences (PPC preferences key off the BINARY'S name, so a side build
  mints a new one), PRAM (wiped every power cycle on the 180c), the
  Ethernet address (it belongs to a SCSI-Ethernet dongle that moves) —
  are recorded in `GuestRegistry`'s header so the next attempt starts
  where this one stopped.
- **The address is not on the agent surface, on purpose.** The host
  observes it and uses it internally; the companion is told the id, the
  session id and the display name, and nothing about where anything is.
  Being able to NAME a machine does not require being told its address.
  The human-facing halves — the app's roster and its log — do show it,
  because that is the human's own desk.

## The README shows neither interface (2026-07-28)

**Missing, not broken.** There are no screenshots of either half, in a
project whose entire subject is two Macintosh interfaces. A reader is
being asked to take the interesting part on faith, and the README says
so rather than quietly not mentioning it.

Wants: the guest's Workshop window on the classic Mac (the Files page
with a real listing is the most legible single frame), and the host
window from the same session, so the two images are visibly the same
connection from both ends. On real hardware if possible — an emulator
capture is honest, but a photograph of the PowerBook says more about
what this is for.

What to capture and the rules for it (native size, nothing identifying
in frame) are in [images/README.md](images/README.md). Michelle is
taking these; the row closes when they land.

## The 180c, 2026-07-26: two suites metal-verified, the ladder not (0.22)

Five branches merged, deployed as `NOW-68K 0.22`, and run against the
PowerBook. What is now metal-verified, what is not, and three defects
the attempt found.

### Metal-verified on 0.22

- `Metal68KTests` — dial, handshake, keepalive, bounded catalog search,
  farewell, redial. 3 run, 2 skipped, 0 failures, **50.8 s**.
- `Metal68KContractTests` — 3 run, 0 failures, **72.7 s**. Individually:
  an unimplemented message refused in 6.4 s, a second request during a
  confirm wait handled in 15.6 s, an oversized control frame costing one
  message rather than the wire in 67.3 s.

**The control plane is healthy on this machine.** That is the whole of
what tonight added to the metal column.

### Still NOT metal-verified

**The file family, both directions.** `Metal68KPutTests` never produced
a usable result: contended the first time (below), killed the second
when the machine was rested. Receive and send remain emulator-verified
only, and the emulator's ~350 KB/s receive is a 68040's number that
predicts nothing here. No `NOWBASE` baseline lines were captured either
— neither run reached the point of emitting any.

### Broken

- **The handoff cannot retire a build older than `isSelf`.** The
  identity gate correctly refuses to name a process the guest has not
  marked as itself, and 0.19 predates `ProcessListing.isSelf` — so it
  declined to guess, and could not proceed. A one-time migration cliff
  created by the fix itself: the first build carrying the field has to
  be launched some other way. Worth deciding whether the gate should
  accept an explicitly-named outgoing build for this case, or whether
  the answer is simply "a human double-clicks once".
- **`launch` with a colon-bearing HFS path did not launch.** Asked over
  the wire to launch `Macintosh HD:Lab:now-68k:NOW-68K 0.22`, the
  running 0.19 returned no reply within 40 s and the application did not
  start; a human launched it by hand. `proc_launch_named` is documented
  to treat a colon-bearing string as a full path and skip the catalog
  search — which is also the step `deploy-68k --handoff` depends on, so
  this is very likely the root of both failures rather than two.
  **Not diagnosed**; the machine is resting.
- **`Metal68KContractTests` was failing by SUCCEEDING.** Its canary for
  "an unimplemented message is refused and says so" was `file.list`,
  which the browse branch implemented — so the guest answered success
  and the test reported a defect that was really a feature. Repointed to
  `file.move`. A test whose subject is a GAP has to be repointed every
  time that gap closes; picking a message nobody will ever implement is
  the worse alternative.

### The machine set its own limits

A 1 MB push moved **606208 of 1048576 bytes** with 77 progress reports
at a healthy cadence, then stopped; every rung after it got **0 of N**,
including the empty and one-byte cases. Round-trip went from
14.4/21.4/28.4 ms idle to 39.3/266.7/439.5 ms. That run was contended by
another session deploying into the same folder mid-ladder, so it is not
cleanly attributable — but the shape is a silent MacTCP wedge, not a
throughput limit, and a machine that is merely slow does not fail a
zero-byte transfer.

Later that evening the display began to flicker and the machine was
rested. The same panel failed mid-session days earlier.

The 4 MB rung exists to find protocol bugs at scale and the emulator
finds those for free, while on this machine a serial multi-megabyte push
is what wedged the stack. The parent corpus carries the envelope as
`vintage-laptop-sustained-load-envelope`: **ladders on the emulator,
character on the metal, sessions in minutes.** If the boundary is ever
worth finding, the experiment holds total bytes constant and varies
burst size and rest between bursts rather than climbing a size ladder.

## The 68K file family's browse half (2026-07-26)

`file.list` / `file.listing` and the `ls` command. Additive: both messages
were already in `contract/asyncapi.yaml`, already decoded by the host, and
already served by the PowerPC guest — checked before designing, and
nothing in the contract changed. NOW-68K now serves 15 inbound message
types.

### Broken

Nothing found in this pass. What the pass DID find is below, under
unverified — most of it is about what a small frame costs.

### Unverified

- **Indexed catalog cost at a deep cursor is unmeasured.** `PBGetCatInfo`
  at index N on a large folder is not O(1), so a host paging into a
  thousand-entry folder pays more per page the further in it goes. Never
  measured, on either machine. If it ever needs bounding, the bound
  belongs in `n68_fileenum.c` as a wall-clock budget with an honest
  "truncated at the budget" answer — `proc68.c`'s
  `kLaunchSearchBudgetTicks` is the local pattern — and NOT as a silently
  short page. Nothing pages a large folder today, which is the only
  reason this is parked.
- **Nothing has browsed the 180c.** Emulator-verified only, on a Quadra
  800 under Mac OS 8.1: a host lists files it just pushed, walks a
  twelve-file folder across several pages losing nothing and duplicating
  nothing, gets a `file.refuse` (not a timeout) for a folder that is not
  there, and sees the same entries through `ls`. That rig is a 68040 with
  128 MB and a cached disk; the 180c is a 68030 with 4 MB and a real one.
  `Metal68KBrowseTests` is the gate to point at it.
- **A worst-case page carries ONE entry.** This guest's outbound payload
  cap is 1024 bytes against the PowerPC guest's 4 KB, and an HFS name of
  31 accented characters escapes to 186 bytes of `\uXXXX`. The
  arithmetic is pinned by static asserts and by
  `test_filelist.c`, so this is correct behaviour rather than a defect —
  but a host that assumed a page means a folder would be wrong here in a
  way it is not against the other guest. Never observed: no folder on
  either test machine has names like that.
- **A UTF-8 path does not resolve.** NOW-68K has no UTF-8-to-MacRoman
  decoder, so a host asking for `Café:Notes` sends bytes this guest
  cannot turn into an HFS name and gets `not-found`. Truthful, and the
  same property the receive half already has (`n68_putrx.c`), so the two
  halves at least agree — but a folder a person can see in the Finder is
  a folder the Files module cannot open. The PowerPC guest decodes
  (`now_json_find_text`); this one needs the same table before it can.
  `GuestWireConformanceTests.testHfsPathArgumentsAreTextDecoded` does not
  catch it, because it checks for the wrong FUNCTION and this guest's
  scanner has a different name.
- **`identity` is absent from every entry.** Deliberate — it is a
  precondition token for mutations this guest does not serve, and nothing
  in `now-host/Sources` reads it. It is the first field to add if
  `file.move`, `file.trash` or `file.get` ever land here, and adding it
  costs ~30 bytes of a 1024-byte page, which is roughly one entry.
- **Three row-array commands still answer inside
  `now68k_commands_dispatch`.** `help`, `ps` and `vprobe`. The result
  type `docs/command-parity.md` called for now exists (`N68CmdRows`) and
  `ls` uses it; moving the other three is a refactor of working code that
  was deliberately not done in the same change as a new message family.
## An abandoned transfer wedged NOW-68K against all future ones (2026-07-26)

`file.cancel` appeared nowhere in `wire68.c`'s dispatch. The guest sent
`file.progress` and handled no cancel inbound, so the question nobody had
answered was what it actually did when a host walked away mid-transfer.
The answer was worse than "it leaks a staging file", and the ledger
entry is the finding rather than the fix.

### What it did, measured before anything was changed

A fake host (a probe, not a fixture — it speaks just enough of the
contract to arm a transfer and then abandon it) against `0.19` on the
Quadra 800 emulator, all on ONE connection that stayed up throughout:

```
-> file.begin transfer 11 ... 8 KB of bulk ... file.cancel {transfer:11}
<- {"type":"error","code":"not-implemented","message":"unsupported message type"}
-> file.offer id 2
<- {"type":"file.refuse","id":2,"code":"busy","reason":"a transfer is already in flight"}
-> command.request put
<- {"ok":false,"error":{"code":"put-refused","message":"a file is arriving right now"}}
```

The guest **answered the cancel with `not-implemented` and kept
holding the transfer**. Every later transfer, in either direction, was
refused for the life of the connection — the lane is one transfer wide
and shared across both — and pings were answered normally the whole
time, so from the host's side the guest looked healthy and simply
refused to move a byte ever again.

### Why nothing rescued it

- **There is no transfer timeout, and there is no message for "I have
  lost interest".** An abandoned transfer is indistinguishable from a
  slow one, and neither `n68_putrx` nor `n68_puttx` carries a clock.
- **The only clock in reach is `service_live()`'s 65 s no-traffic
  watchdog, and it is the wrong one.** It is a property of the
  CONNECTION — `kWireDeadTicks` since the last inbound byte — and the
  guest's own 30 s keepalive ping keeps being answered, so on a live
  connection it never fires. A DROPPED connection was always fine
  (`reset_read_state` cancels both directions, which closes the
  outbound fork and deletes the staging file); the case nobody had
  established is a host that stays connected and stops caring.
- The receive half held its staging file (`NOW incoming <hex>`) open
  for a transfer that would never end. Observed as the wedge; the
  orphan on the Desktop follows from the staging file never being
  discarded and was not separately confirmed on the baseline disk.

### The send half had a second door into the same wedge

Found on the way. The host sends `file.cancel` **and** `file.done`
together the moment its sink fails (`GuestListener.swift ::
failInboundStream`), and `n68_puttx_done()` acted only in
`kN68SendEnded` — so a `file.done` arriving while bytes were still going
out was dropped, the guest streamed the rest of the file at a host that
had already discarded it, and then parked in `kN68SendEnded` waiting for
a reply that had already been and gone. The host does not send a second
one: `finishFile` returns early for a transfer it is discarding. **A
receiver's `file.done` is final whenever it arrives**; requiring our own
`file.end` first is what made the park permanent.

### Fixed, and what the fix is verified to do

No contract change was needed — `FileCancel` and `file.done`'s
`cancelled` code were already there, which is worth recording because
the gap was entirely on the implementing side. `file.begin`'s `transfer`
is now remembered, because `file.cancel` names a transfer and carries no
id, so nothing else could tell a live cancel from a late one.

Same probe, same emulator, `0.20`:

| Probe step | Result |
|---|---|
| cancel a push after 8 KB | `file.done ok:false code:cancelled received:8192 cleanup:temp-discarded` |
| offer again immediately | accepted, completed, CRC-confirmed |
| cancel the guest's own send mid-stream | `file.end ok:false`, **0 bulk frames after the cancel** |
| ask for that send again | offered again — the lane is free |

`cleanup:temp-discarded` was checked against the disk rather than
believed: `hls` on the session image afterwards shows the completed
`After Cancel` and **no `NOW incoming`** staging file. (`xfer_tmp_1` in
that listing predates this work by weeks and is base-image debris.)

The deliverability claim in `n68_puttx.h` rule 3 held up under the one
case it exists for: the cancel was acted on one chunk after it arrived,
not at the end of the transfer. A staged bulk frame nobody has seen is
dropped; one already part-way out finishes, because a frame cut short is
a desynchronised wire rather than a cancelled transfer.

### Still open

- **Not on the 180c.** Emulator-verified only, and the emulator is a
  68040 with 128 MB. The behaviour under test is a state machine rather
  than a rate, so it should carry — but nobody has watched it.
- ~~**A cancel has no console face.**~~ Closed in the same pass. It is
  a `cancel` verb now — contract's `x-commands` first, then
  `commands68.c`, which the console reaches through
  `now68k_commands_run` without conwin.c gaining a second dispatch, so
  both faces run one implementation and `help` lists it. Verified on
  the emulator from the console face specifically: `help` shows the
  row, a quiet machine answers `nothing-to-cancel` rather than
  pretending, and the verb produces the same `file.done ok:false
  code:cancelled cleanup:temp-discarded` the wire message does. The
  PowerPC guest deliberately gains no verb — a host cancels it from
  the Files UI and a person at that guest from its own Workshop — and
  that decision is named with its reason in
  `CommandRegistryTests.notOnThePowerPCGuest` rather than left as a
  silent gap.
- **The other 65 s window is unexamined.** A host that abandons a
  transfer AND stops answering pings is cleaned up by the watchdog, but
  no one has watched that path either, and it is the only path in which
  a transfer's cleanup depends on a timer.
- The probe lives in a scratchpad, not the repository. Turning it into
  a metal gate belongs with whoever is working on that harness; it
  needs `requireTheBuildUnderTest()` before anything it reports can be
  believed.
## `front`, on both faces of both guests (2026-07-26)

`process.front` had been on the PowerPC guest's wire since the Processes
module was built, and there was no way to **type** it — not at either
guest's own keyboard, and not from the host console, which is a dumb
shell that knows no message families. A capability reachable only by
clicking a button in one module is the `ps` shape exactly
([command-parity.md](command-parity.md)).

So `front` is now a contract `x-command` served by both guests, over the
same list → match → re-validate → act → re-check composition `quit`
uses, and NOW-68K additionally answers the `process.front` drive verb it
did not before. Its outcomes are deliberately not `quit`'s with the
words changed: `not-running` is ok:**false** here (nothing can bring
forward a process that is not there, where quit was asked to produce
exactly that state), and NOW itself is a fair target (fronting severs
nothing; quitting would cut the reply mid-send).

### Unverified

- **The confirm branch has never run.** `SetFrontProcess` returning
  noErr means the switch was *scheduled*; it lands when the guest
  yields, and both guests yield with an event mask of zero. Whether a
  process switch completes inside that yield is **unproven on either
  machine** — if it does not, `front` will report `unconfirmed` every
  time while the screen plainly shows the switch happened. That is
  visible and diagnosable rather than a silent lie, which is why it is
  written this way, but it is the first thing to watch on metal.
- Nothing else here has been on a machine either: both guests build
  clean, the host suite is green, and no PowerBook has run it.

### Open

- **`front`'s argument parser is not natively testable.** `quit`'s
  grammar lives Toolbox-free in `proc_quit_args.c` and has its own
  native test; `front`'s is four lines of trim-and-unquote, static in
  each guest's command file, and duplicated across the two. It is small
  enough that a shared module would be more moving parts than it saves —
  but it is the second copy of a grammar, which is how the first one
  started.

## `quit` targets a process identity, not a file name (2026-07-26)

The handoff's retire step named the outgoing build `"NOW-68K " + <the
version it reported in hello>` — a FILE NAME derived from a compiled
constant. They agree by convention only. On 2026-07-25 a build deployed
as `NOW-68K 0.18` reported `0.16`, so the retire sent
`quit NOW-68K 0.16`, the guest answered honestly that nothing of that
name was running, the old build kept running, and a 4 MB machine was
left with two NOW-68Ks. Nothing was broken on the guest; the identifier
was invented on the host.

Fixed by naming the target the way a machine should:

- `process.listing` gained **`isSelf`** (contract first), set by both
  guests on their own row. It is the only trustworthy answer to "which
  process is on the other end of this connection".
- NOW-68K now answers the contract's **`process.quit`** drive verb —
  re-validate the PSN, refuse self, send — over `proc_quit_psn`, the
  same three steps `proc_quit_named` ends with. It does not confirm, and
  that is the contract's decision: `process.result.ok` means DELIVERED,
  and there is no field that could tell a granted quit from a declined
  one. A caller confirms by re-reading `process.list`.
- The `quit` command still takes a name, because a person types what
  `ps` shows them. `ps` now says `self` on that row, on both guests.

### Unverified

- **None of it has been on a machine.** Both guests build clean and the
  host suite is green (511 tests), but `isSelf`, `process.quit` on
  NOW-68K, and the PSN-targeted handoff have not run on the 180c. The
  loopback test `HandoffIdentityTests` reproduces the version/name
  disagreement over scripted guests and watches the old derivation fail
  — that proves this side never invents an identifier, and proves
  nothing about the Toolbox code.
- **The first handoff has to be launched by hand.** The build currently
  on the 180c is 0.19: it serves `process.list` without `isSelf` and
  does not answer `process.quit` at all. `Handoff68K.identifySelf` fails
  with a message saying so rather than falling back to a name — a
  fallback would be the defect, reintroduced. From 0.20 onward the
  handoff is automatic again.
- **`process.front` and `process.shot` are still unimplemented on
  NOW-68K.** They fall through to `send_error_reply`, visibly. Only the
  verb the handoff needed was added; the family is deliberately partial
  rather than quietly half-served.

### Open

- The host's `ProcessEntry.id` is `name#code#creator`, so two processes
  of the same name collide in the table's identity — exactly the case
  `isSelf` and the PSN exist to handle, one layer up. Not hit by
  anything today; worth the PSN when it is.

## The 68K file family, both directions in one tree (2026-07-25 night)

Three branches merged and verified together: the receive half (MacBinary,
Desktop landing, the `FSClose` fork repair), the send half (the
byte-source sender), and the version-bump commit that carried them to the
machine. What that merge found, and what it left open.

### Broken

- **~~The two halves disagreed about where files live.~~** Fixed in this
  pass, and worth keeping in the ledger for how it hid. Receiving landed
  on the Desktop, sending read from the application's own folder; each
  branch was self-consistent, so no reviewer of either could see it. It
  survived the merge (no textual conflict — two roots in two files), 27
  native tests, 508 host tests, both Xcode configs, and `-Werror`. The
  round-trip ladder on the emulator named it as `fnfErr` on all ten
  rungs. **A cross-direction test is the only kind that could have
  caught this, and it could not exist while the halves were on separate
  branches.** `now68k_desktop_folder` is now published from
  `n68_putfile.h` and both directions read it.
- **A merge can drop an `#include` with no conflict.** `git` took one
  side's include block wholesale and `<Processes.h>` went with it. The
  block was never marked conflicted, so reviewing the conflicted hunks
  would not have shown it. `-Werror` caught it; nothing else would have
  until link time.
- **A conflict region can cut a function mid-body.** The resolution
  looked complete — every declaration present — and the function simply
  never closed, which the compiler reported as four *unrelated*
  functions being "defined but not used" and a fifth reaching the end of
  a non-void function. The error names never mention the function that
  is actually broken.
- **The handoff's retire step may quit the wrong build.** `NOW-68K 0.17`
  reached the 180c and its log reads `wire: connected` then `cmd: quit
  ok 0` — the incoming build took a quit and executed it, where the
  outgoing one was meant to. Not diagnosed, and **not confirmed**: the
  run it came from was contended (see below), so this is a suspicion
  with a log line behind it, not a defect with a repro.

### Unverified

- **Neither direction has moved a byte on the 180c.** Both are
  emulator-verified on a Quadra 800 under Mac OS 8.1 — receive 4 MB in
  11.7 s (350 KB/s, 512 progress reports, CRC-confirmed), send 4 MB in
  1.8 s, MacBinary both forks, control lane 0.05 s idle against 0.10 s
  during a 1 MB push. A 68040 with 128 MB is not a 68030 with 4 MB, and
  the send rate in particular reads off a disk the emulator caches —
  read it as "the path works", never as a rate.
- **The PackBits ratio and encode cost are unmeasured.** `vprobe` has
  the framebuffer READ at 159 ms for a 300 KB frame
  ([docs/vram-readout-68k.md](vram-readout-68k.md)); nobody has measured
  what compressing it costs on a 33 MHz 68030, and **the ratio is what
  decides whether screenshots are viable over MacTCP at all**. No branch
  in this repository implements PackBits. The send half was built as a
  byte source (`n68_bytesrc.h`) precisely so a capture can feed the pipe
  in bands rather than buffer 300 KB against a 384 KB partition — that
  shape held through the merge, so a screenshot sender does not need a
  second send path.

### Two host sessions can contend for one PowerBook, invisibly

A metal run of these suites on 2026-07-25 held port 5252 for the better
part of an hour while another session deployed a build into the same
folder mid-ladder. The results were unattributable: a 1 MB push stalled
at 606208 bytes and every rung after it timed out at `0 of N`. The most
likely cause is contention rather than a defect — NetPresenz serving an
FTP upload while NOW-68K received a push, both on MacTCP, on a 68030
with 4 MB — but nothing proves that either, which is the point.

**`requireTheBuildUnderTest()` would not have caught it.** That guard
asks whether the connected guest is the right *guest*, and it was. The
gap is that nothing establishes whether the *machine* is already busy.
`lsof -iTCP:<port>` before a run answers it in a second. The existing
rule covers several guests reaching one listener; this is several
listeners reaching one guest, and it is not written down anywhere else.

**Fixed on 2026-07-26**, test-side only — see `MetalMachineGuard` and
[68k-metal-runbook.md](68k-metal-runbook.md). Before any 68K metal suite
binds, it establishes that nothing else on this Mac holds the port and
(when `NOW_METAL_MACHINE` names the guest's address) that nothing else
is talking to the machine, and fails in about a second naming the
process rather than producing an unattributable result. It also reports
a bind failure as a bind failure: the suites used to wait out a full
120 s and say "no guest dialled in", which aims the diagnosis at the
Macintosh for a fault entirely on this side.

What it still cannot see is below, and it is the honest limit of the
fix.

### A host cannot ask a 68K guest whether it is busy

**Found 2026-07-26 while building the guard above; no code changed.**

NOW-68K knows perfectly well whether it is mid-transfer in either
direction, and renders exactly that: `xfer` reports an active receive
with its byte count, an active send, and the last completed one either
way. **There is no way for a host to ask.** `xfer` is console-only by a
recorded decision (`CommandParityTests :: consoleOnly` — "renders the
file.* family's state; the host reads it from file.progress and
file.done instead"), and the PowerPC guest's wire-only `putstat` has no
68K counterpart.

That reasoning holds for a host that is *driving* the transfer, which is
the case it was written for: such a host has the progress messages. It
does not hold for a host that wants to know whether the machine is free
before it starts — which is precisely the question the contended run
needed to ask and could not. So contention detection is host-side only,
and the guard says so rather than guessing.

Not fixed here, because it is a product change and this pass was tests
and documentation. If it is taken up, the cheap version is a `busy`
verb (or an `xfer` promoted to both faces per
[command-parity.md](command-parity.md)) answering the two booleans and
the two byte counts `N68PutStatus` / `N68SendStatus` already hold. The
gap it would close is real but narrow: it tells a second session that
the machine is busy, and tells it nothing about who has it.

Related and unresolved: the name a build has on the disk and the version
it reports on the wire are established by different means, and a guest
answering `"version":"0.16"` was found on a machine whose deploy folder
had just gained a file named `NOW-68K 0.18`. Whether those were the same
application was never established. `deploy-68k` stamps both from one
source, so this only arises when something bypasses it.

### `--filter Metal68K` used to report a failure that meant nothing

**Fixed 2026-07-26**, test-side only. `Metal68KHandoffTests` is a deploy
step, not a coverage gate: it needs a freshly uploaded build and the
exact HFS path of it, which only `scripts/deploy-68k --handoff` knows.
It used to FAIL when those were absent, on the argument that asking for
a metal run with no build to hand off to is a broken invocation — sound
in isolation, but `--filter Metal68K` catches that class too, so every
ordinary 68K metal pass reported one red that meant nothing. A red that
always fires is a red nobody reads.

It now SKIPS when `NOW_68K_NEW_APP` is unset, with the same second
opt-in shape `MetalQuitTests` already uses for the dirty-document case
("NOW_METAL=1 alone does not say a human is at the keyboard"). Set but
EMPTY is still a failure, because that is somebody having tried.

This is a deliberate exception to "a metal gate fails rather than
skips", and it is narrow: the thing being skipped is a deploy action,
not evidence about the guest.

### NOW-68K cannot send the same file twice, and says it can

**Found 2026-07-26 on the emulator, by the repeat sampling above; no
code changed.**

`n68_puttx.c`'s offer never sets `overwrite`, so the host applies the
contract's default of false (`GuestListener.acceptOffer`) and REFUSES
the second offer of a name the share already holds. That is defensible
policy — the host will not silently replace a file — but the guest end
of it is not honest:

- `put <name>` has ALREADY answered `ok` by then, because the command
  returns as soon as the offer is away (deliberately: a command that
  blocked for a multi-megabyte transfer would hold a `command.result`
  for minutes). So the person who typed it is told it worked.
- The refusal arrives afterwards as `file.refuse`, and the only place it
  surfaces is `xfer`'s "last FAILED" line — which nobody has a reason to
  type after being told `ok`.

From the host side it presents as a transfer that never starts: the
offer goes out and nothing ever arrives. It cost a 300 s timeout per
sample to work out, and read exactly like the machine having gone away
— the same signature as the contended run, from an entirely different
cause, which is worth knowing on its own.

Not fixed here (product change; this pass was tests and docs). Three
candidate fixes and they are not equivalent: the guest could set
`overwrite` on its offer (wrong — that hands a guest the right to
replace files on the host), the host could decline more visibly, or the
guest could hold the send's outcome somewhere `put`'s caller can reach.
The last is the one that matches the direction the contract already
takes for progress.

The suites work around it by naming every sample separately
(`RT<size>r<rep>`), which is a harness fix and not a fix.

### Two `swift test` runs on one Mac fail three suites

**Found 2026-07-26, reproduced deterministically; pre-existing, no code
changed.** Three suites share state outside the process:
`HostLogTests` and `LoggingSpecTests` both write
`~/Library/Logs/now-logs`, and `HostAppStateWiringTests` binds a fixed
port 52981. Running two `swift test` processes concurrently fails them
every time.

It surfaced here because a metal pass and an ordinary gate run overlapped
by a few seconds, and the result was two failures that vanished on
re-run — the flakiness signature, from a cause that is not flaky at all.
Worth fixing at some point (a per-process log path and an ephemeral
port), and worth knowing meanwhile: the runbook says one at a time.

### What a 68K metal run should record

[68k-metal-baseline.md](68k-metal-baseline.md). In short: the suites now
emit one greppable `NOWBASE` line per measurement, carrying the
conditions (build, machine, port) beside the numbers, because the
2026-07-25 run's numbers were real and unattributable. `NOW_METAL_REPEATS=3`
takes three samples of every rung at or above 1 MB, so a rate can be
told from an interruption — which one sample from this machine
demonstrably cannot do.

## Host -> guest file transfer on NOW-68K (2026-07-25)

NOW-68K receives a pushed file. Offer, accept, stream, checksum, done -
the contract's `hostPutsFiles` sequence, served by the guest that
previously discarded every bulk frame to stay in frame sync.

**Emulator-verified, NOT metal-verified.** Everything below was measured
on a Quadra 800 under Mac OS 8.1 with 128 MB (`scripts/q800-68k`). The
real target is a 68030 under System 7.1 with 4 MB. What carries over is
correctness; what does not is every number in the table.

| Size | Result (emulator) |
|---|---|
| 0, 1, 8191, 8192, 8193 B | ok - the boundaries either side of one frame |
| 64 KB | ok, 299 KB/s |
| 256 KB | ok, 348 KB/s |
| 1 MB | ok, 357 KB/s |
| **4 MB** | **ok, 11.6 s, 352 KB/s, 512 progress reports** |

The 4 MB file was pulled back off the disk image with hfsutils and is
**byte-identical** to what was sent (CRC-32 `A627E416`, agreeing with
zlib and with the guest's own). The catalog shows exact sizes rather
than allocation-block-rounded ones, so the `Allocate` + EOF-trim pair
works, and no `NOW incoming ...` staging file was left behind.

The guest's event loop is not starved by the receive path: `help`
round-tripped in 0.05 s during a 1 MB transfer against 0.06 s idle.

## MacBinary on NOW-68K: the fork corruption, found and fenced (2026-07-26)

Full record: **[68k-file-receive.md](68k-file-receive.md)**. In short.

`FSClose` of a written resource fork on Mac OS 8.1 splices 77 bytes of
File Manager catalog state into the fork's first block at offset 48 - an
in-memory record layout that matches nothing on disk. Deterministic:
every resource-carrying MacBinary file, every run; data forks never; a
MacBinary file with an empty data fork never affected.

Pinned by three structural facts, in this order: the splice is
sub-sector, so the bytes were wrong in RAM and no allocation-level
theory survives; the spliced content carries the staging name and
`BINA` but both FINAL fork lengths, which brackets the write to the
close window and explains why disabling `Allocate`, `SetEOF`,
`FSpRename`, `FSpSetFInfo` and `PBSetCatInfo` each missed; and read-back
probes read clean before the close and spliced after it, 5/5.

The guest keeps the fork's first 512 bytes as written, re-reads them
after the close and after the rename, rewrites them when they diverge,
and re-verifies through a fresh open. Unrepairable before rename fails
the transfer; after rename it deletes the file rather than leave a
corrupt application to be double-clicked. Detected 5/5, repaired in one
round 5/5, raw disk clean, both forks byte-identical.

**Still open, and the first is the one that matters:**

1. **System 7.1 on the real 180c is untested** - the 7.5.3 image in the
   lab has no MacTCP, so the OS discriminator is blocked. The shipped
   probes double as the experiment: push one MacBinary file and the log
   either names the scribble or stays silent. Either answer is safe.
2. QEMU's contribution is not separated from 8.1 itself.
3. The PowerPC guest's resource forks have never been byte-verified.

### What is deliberately not there

- **No resume.** The guest never reports `have`, which the contract
  reads as "start from the beginning". Partials are always discarded.
  Deliberate: resume is an open hang on the PowerPC side (see the large
  transfer notes) and a 4 MB transfer is not long enough to make
  restarting a hardship.
- **~~Receive only.~~** Superseded — NOW-68K now sends as well as
  receives; see the next section. `file.list`, `file.move`,
  `file.trash` and the host-initiated PULL (`file.get`) still answer the
  generic not-implemented error, so the guest can push a file it is told
  to push but cannot serve a host that wants to browse or fetch.
- **~~The destination is the application's own folder.~~** Superseded —
  **files land on the Desktop, and nothing is gated.** NOW-68K has no
  preferences and no share root, so there is nothing to read a
  destination out of. The Desktop needs no state to name and is where a
  person looks for something that arrived. `path` from the offer still
  resolves relative to it and a host may reach a subfolder — deliberate
  until the browse/ls verbs exist, because a boundary drawn before
  there is anything to browse is a guess dressed as a policy. It was
  briefly the application's own folder, which meant a host could write
  into the System Folder. The send half still reads its SOURCE from the
  application's own folder (`now68k_app_folder`), which is a different
  root for a different direction and deliberately so.

### Open

1. **Nothing has run on the PowerBook 180c.** Everything above is an
   emulator result. The 180c has 4 MB against the emulator's 128, a
   68030 against a 68040, and MacTCP that has already been observed to
   wedge silently on that machine. A 4 MB transfer into a 384 KB
   partition is exactly the shape that behaves differently there.
2. **A contract gap: `FileRefuse.code` has no value for "this receiver
   cannot handle that".** An unrecognized container is reported as
   `io-error` with the truth only in `reason`, which is a lie of
   category - nothing failed, the request was never serviceable. The
   honest fix is an additive enum value in the contract, which touches
   both halves and was out of scope for a spike. (Unknown containers are
   now REFUSED rather than treated as `data`; writing an unknown
   envelope out as a raw fork produces a file of the wrong length and
   the wrong shape and blames the disk.)
3. **`FileOffer.modified` has no stated units in the contract.** Both
   guests treat it as Mac-epoch seconds (it goes straight into
   `ioFlMdDat`), and the two agreeing is the only reason it works. It
   should be written down.
4. **The host never uses the `chunk` it negotiates.** `hello.chunk` is
   computed and echoed (`GuestListener.swift`), but the file sender's
   frame size is a hardcoded 8192. NOW-68K advertises 4096 for a stated
   MacTCP reason and is sent 8 KB frames regardless. Harmless today - the
   guest streams and needs no frame-sized buffer - but the negotiation
   is decorative, and a guest that genuinely could not take 8 KB would
   have no way to say so.
5. **The application partition is getting tight.** This pass cost
   +19408 bytes (~5% of 384 KB), leaving roughly 184 KB of image before
   stack and heap. Preferred == minimum on a 4 MB machine, so there is
   nothing to borrow. The next addition this size needs the budget
   looked at rather than assumed.
6. **`g_sink` is still 256 bytes**, inherited from when it was a pure
   discard sink. A 4 MB transfer therefore makes ~32 passes per 8 KB
   frame. Cheap memcpys, but it is a knob nobody has measured on the
   180c, where BSS is the scarcer resource.

## Guest -> host file transfer on NOW-68K (2026-07-25)

The other direction. NOW-68K makes the offer, streams the bulk frames
and closes with a checksum: `file.offer` -> `file.accept` ->
`file.begin` -> bulk -> `file.end` -> `file.done`. **Additive — no
contract schema changed.** Every message and every field already
existed, is already served by the host (`GuestListener.onAcceptOffer` /
`finishInbound`) and is already sent by the PowerPC guest; that was
verified against the schemas rather than assumed.

**Emulator-verified, NOT metal-verified.** Measured on a Quadra 800
under Mac OS 8.1 with 128 MB (`scripts/q800-68k`), driven by
`Metal68KSendTests`. The real target is a 68030 under System 7.1 with
4 MB. What carries over is correctness; what does not is every number.

Each case pushes a known pattern to the guest, asks the guest to send
that same file back, and compares the bytes **the host still holds**
against the bytes that came back. Nothing in the comparison comes from
the guest's own accounting — not its progress, not its CRC, not its
byte count, because a sender marking its own work proves nothing.

| Size | Result (emulator) |
|---|---|
| 0, 1, 4095, 4096, 4097, 8192 B | ok — the boundaries either side of one chunk |
| 64 KB | ok, 313 KB/s |
| 256 KB | ok, 1227 KB/s |
| 1 MB | ok, 2198 KB/s |
| **4 MB** | **ok, 2.5 s, 1648 KB/s, byte-identical** |

Sending reads from a disk the emulator caches, so these rates are
several times the receive direction's 352 KB/s and mean nothing about
the 180c, where the read is a real one off a real disk.

**The wire-sharing rule holds under real back-pressure**, which is the
claim nothing off-metal can check: during a 4 MB send, 28 `help`
requests were answered, **none dropped, worst 0.10 s**. That is the
rule working — control drains before bulk, and a reply waits for the
chunk in flight rather than for the transfer.

The 0-byte case is worth its row: a zero-length source sends **no bulk
frame at all**, begin then end, and the receiver closes out correctly
rather than waiting for a stream that never comes.

### It is a byte-source sender, not a file sender

The point of the shape, stated because it is the thing most likely to
be undone by someone in a hurry. The source is an interface
(`n68_bytesrc.h`) with four promises: it knows its length before the
first fill, it returns promptly, it does not allocate, and it never
touches the wire. A file (`n68_filesrc.h`) is the FIRST implementation,
not the only intended one — a screen capture is ~300 KB against a
384 KB partition, so it can never be a buffer and cannot be staged to a
disk that may not have room. **If a screenshot ever needs a second,
parallel send path, this was built wrong.**

### How bulk and control share the wire

Stated once in `n68_puttx.h` and enforced in `flush_outbound()`:

1. Bulk never touches the four 1024-byte control slots; it has one
   dedicated 4104-byte slot, so no volume of bulk can consume the slot
   a `command.result` needs.
2. A frame already being handed to `net_queue_send` finishes before any
   other frame's first byte.
3. Otherwise control drains before bulk, so a reply queued mid-transfer
   waits for the chunk in flight (~12 ms) and never for the transfer.
4. Back-pressure is `net_queue_send`'s short accept and nothing else.

Rule 4 is the one that will read as a bug later, so: this side does
**not** need the receiver's `file.progress` to clock itself and the
host **does**. MacTCP's staging buffer is small and reports truthfully
and synchronously how much room is left; the host writes into
Network.framework, which accepts essentially unbounded writes and so
tells it nothing. Two senders, two mechanisms, neither one the other's
bug.

### Parity: `put` is on both faces here, and console-only on the PPC guest

Deliberate, and the two guests genuinely differ. A host driving the
PowerPC guest reaches the same capability through `file.list` and
`file.get`, so that guest needs no verb. NOW-68K is the machine whose
display has already failed mid-session and whose host console is a dumb
shell with no knowledge of message families — so on that guest the
capability is a verb in `commands68.c`'s table, reachable from both
faces through one implementation. The contract declares `put` in
`x-commands` first, per AGENTS.md.

`CommandRegistryTests` had to learn this: it assumed the registry IS
the PowerPC guest's command set. NOW-68K always answered a strict
subset, which that test never had to notice; `put` is the first command
going the other way, and it is named in `notOnThePowerPCGuest` with its
reason rather than subtracted silently.

### Open

1. **Nothing has sent a byte on the 180c.** The emulator results above
   say the code is correct; they say nothing about a 68030 with 4 MB,
   whose MacTCP has already been observed to wedge silently. Reading a
   4 MB file off a real disk while streaming it is exactly the shape
   that behaves differently there.
2. **Several guests can reach one listener, and one of them is not
   yours.** Every QEMU guest on this Mac sees the host as `10.0.2.2`
   under user-mode networking, so any session's VM can answer any
   session's listener. This cost real time: the first run of
   `Metal68KSendTests` reported `unknown-command` for `put` from a
   guest that was simply another branch's build — and the refusal test
   PASSED against it, because "unknown command" is also a refusal with
   a reason. `requireTheBuildUnderTest()` now asks the connected guest
   whether `help` lists `put` before believing anything it says. Run
   with `NOW_METAL_PORT` set to something nothing else is dialling.
3. **No MacBinary, so no application and no resource fork.** The data
   fork only — which is the contract's own default for a both-forks
   file, so it is legal rather than a shortcut, but it means a file
   whose content lives in its resource fork (most classic Mac
   applications, every ResEdit document) arrives empty or meaningless.
   This is the natural SECOND implementation of `N68ByteSourceOps` —
   header, data fork, padding, resource fork, each in bands — and
   writing it is the real test of whether the interface earns its keep.
4. **The source is limited to the application's own folder.** Same
   weakness the receive half has and for the same reason: NOW-68K has
   no share root. `put` takes a leaf name, not a path.
5. **One transfer at a time is enforced across both directions**, and
   the answer to a second request is `busy` with a reason. Not
   exercised against a host that offers a push while a send is in
   flight — the check exists and has never been raced.
6. **A contract gap, the mirror of the receive half's.** `FileEnd` has
   no way to say "the sender's own source let it down", so
   `kN68SendSourceFailed`, `kN68SendShort` and `kN68SendLong` all
   render as `io-error` with the truth only in the reason. Same honest
   fix: an additive enum value.
7. **The contract's operations index is asymmetric about this
   direction, and was before this change.** `guestServesFiles` lists
   `file.begin`/`end`/`progress`/`refuse`/`listing` but not
   `file.offer`; `file.accept` and `file.done` appear in **no**
   operation at all, in either direction, though both sides send both.
   The schemas are complete and correct — this is the index above them.
   Left alone rather than fixed in passing: it is a contract edit that
   touches how both halves are described and deserves its own pass.
8. **`sendMs` is computed from `TickCount` at 1/60 s.** Fine for a
   figure the contract types as advisory, but it is not milliseconds
   measured, it is ticks scaled.

### Two defects found by this pass, in code that predates it

- **`GuestWireConformanceTests` could not see `bye`.** Its C-literal
  scanner did not understand character literals, so the three `'"'` in
  wire68.c's `read_string_field` inverted its quote parity and every
  literal after them was read inside-out. `bye` had been piecemeal since
  the day it was written and never appeared in the cannot-check set -
  the set read complete and was not, inside the mechanism built to
  prevent exactly that. Fixed, and `bye` has the fixture it should
  always have had.
- **The console printed one line's tail on the end of the next.**
  `now68k_fmt_append_*` do not NUL-terminate, and every builder in
  `conwin.c` declares `char line[80]` inside its loop, so a line shorter
  than the one before it trailed that one's tail: "files land in Startup
  Items" rendered as "files land in Startup Itemsbytes". `show_help` and
  `show_processes` had it latent and only escaped because their lines
  happen to grow rather than shrink. All emission now goes through
  `con_out_built`, which terminates. **No native test could have caught
  this** - it is pixels, and it was found by looking at a screen.

## Deferred by decision

**NOW agent-integration V0 is complete** (2026-07-24). All five bounded
projections are implemented, tested, and covered by one combined
PowerBook acceptance receipt: `now_session_health`,
`now_list_processes`, exact safe launch, revalidated cooperative quit,
and receipt-only approved artifact transfer through the existing put
lane. The pass also observed typed host absence, automatic guest redial,
new session identity, stale-reference refusal, and unchanged ordinary
Files/Connection UI. Exact evidence and limits live in
[`agent-integration.md`](agent-integration.md).

The artifact pass found one compatibility defect and closed it before
V0 closeout: modern classic-epoch dates saturated the deployed guest's
signed 32-bit JSON reader and stamped January 1972. Host→guest lanes now
omit an optional date outside the deployed reader's range; the numeric
guard, wire omission, mutation failure, and corrected live listing are
recorded in [`files.md`](files.md#classic-date-compatibility-boundary).
The first disposable evidence file retains its bad stamp; no destructive
cleanup was attempted.

The companion still has no guest component, lifecycle control, raw-path
input, shell or general filesystem surface, force-quit surface, or
CodeKitten/shared-transport dependency. Sustained load,
destination-byte read-back, and any shared-transport extraction remain
outside V0 rather than hidden completion claims.

**Guest-initiated change controls.** The browser on the classic side can
list, navigate and pull, but offers no rename, delete, new folder or
move. Michelle punted this 2026-07-20: write and overwrite were the
goals of the slice and both work.

Worth knowing before anyone reopens it: `file.move`, `file.trash`,
`file.restore` and `file.mkdir` already exist in the contract, the guest
already SERVES all four, and `HostShare` learned to serve them too
(2026-07-20, 13 tests). So the wire and both servers are done and the
only missing piece is guest UI — plus a decision about undo, which the
host side keeps on whoever initiated the action. **That host-side
implementation currently has no client.** It is tested and symmetric,
and it is also unused code until this is picked up; anyone auditing for
dead weight should know it was built deliberately, not left over.

## In flight elsewhere

**The unified Workshop landed** on `claude/guest-workshop-unified-a3aab9`
(2026-07-21): one window, a hand-drawn sidebar rail, and all four
modules (Screenshots, Files, Console, Connection) behind the
`WorkshopModuleOps` contract. The five old windows and the Connection
dialog are deleted, and all four pages were watched working on the
PowerBook the same night. The codex branch `codex/guest-console-invert`
is **abandoned by decision** (Michelle, 2026-07-21) — do not merge it.
Its one still-valuable idea, the **async OT connect path** (`160ed85`),
was reimplemented against `claude/processes-module-cb2d9c` on
2026-07-21 (see "An unreachable host presents as a hang" below); the
branch itself stays abandoned.

**The Processes page landed and is metal-verified** (2026-07-21,
`main` at `22f129a`; spec in `processes-and-peek.md`). The fifth
Workshop module: a split view with a Data Browser process list
(icon-and-text column, header sort) on the left and a detail pane
(kind, type/creator, memory text + partition bar, launch date) on the
right, plus Bring to Front and Ask to Quit (confirm -> quit Apple
Event -> keep the PSN until the walk proves the process gone ->
`(no reply)` after 10 s). The `peek.h` seam ships answering "NOW
Extension not installed"; the group box renders it. Watched working on
the PowerBook the same day. This is **rung 0** of the extension ladder
- everything above it (the NOW Extension itself, `process.*`/`peek.*`
wire families, the semantic mirror) is still ahead.

The detour that dominated the arc was NOT the Processes page - it was
reaching the Connection settings to repoint a chip that was listening
on the wrong port. That exposed two real, now-fixed defects, both
metal-verified: the async-connect launch wedge, and Connection field
editing (see below). The Processes page itself was good across those
rounds.

**NOW Extension M0 is metal-verified** (2026-07-21, rung 1, `ext/`).
The guest's first resident code: a 68K INIT publishing the shared
table, registering Gestalt `'NWex'`, and chaining a jGNE heartbeat
filter. Booted on the PB1400c at 9.1; the app's `now_peek_status()`
probed it and the Processes group box read "NOW Extension active."
That proves install, DetachResource residency, Gestalt registration,
table validation across the compiler boundary, and a live jGNE chain -
the whole of M0. Size ~48 KB (Retro68 flat runtime), loads at 9.1;
8.6 loader ceiling still unprobed (waits on the 3400c). The recovery
drill (Shift-boot off, drag-out) and the QEMU-clone pre-check remain
good practice for the next resident change but M0 itself is done.

**Rung 2a is metal-verified** (2026-07-21) - the anchor plane and the
first foreign-memory read. The extension's jGNE filter, once the
Processes page arms the plane, records each process's low-memory
CurrentA5/WindowList/MenuList into A5-keyed slots. Clicking a process in
NOW's list reads THAT process's front-window global bounds (the
per-process `axtree` behaviour): PSN -> partition
(`GetProcessInformation`) -> the fresh anchor whose A5 lies in that
partition (the correlation, validated by containment) -> `strucRgn` ->
`rgnBBox`, every foreign pointer checked inside the partition OR the
system heap before it is dereferenced (`peek_validate.c`, native-tested
+ mutation-checked), byte reads at fixed classic offsets. Watched on the
PB1400c: NOW's own window read correct, and Finder read "516 x 557 at
(7, 25)" - a real other process's window - once the validation was
widened to accept the system heap (partition-only read "unreadable",
exactly tbt's axtree lesson). The foreign read lives in the app, never
the extension.

Known texture, not a defect and not fixable: the readout is only as
fresh as the target process's last event-loop pass. Window state is a
SNAPSHOT captured by the filter when the process pumps - classic Mac OS
has no cross-process live window feed (`axtree` had the identical
limit), so no reader can re-take it on demand. There is deliberately no
time-based freshness gate on WHETHER to read: the A5-in-partition match
and the fail-closed validation, not a clock, prove a slot is this
process's, and the app carries the last good read across a stale blip.
But staleness is surfaced HONESTLY (the AXPeek/qdpeek discipline, which
hit this same wall): the reader reports the anchor's capture tick, and
the detail's Windows header shows "as of a moment ago" / "as of N min
ago" once the snapshot ages past ~3 s - an actively-pumping app stays
live with no marker. An app that never pumped since arming reads "no
anchor yet" until it does; an app with no windows reads "none open". Still open for a later pass: whether any app keeps its
window structures in a zone neither the partition nor the system heap
covers (would read "unreadable"); and rung 2b, cropping the actual Front
& Capture to the rect.

**Rung 2b - Front & Capture is metal-verified** (2026-07-21). The first
USE of the window bounds, and the anchor plane's first real artifact: a
"Front & Capture" button in the NOW Extension group box brings the
selected process forward, DEFERS the capture to a later idle (~0.75 s, so
nothing nests an event loop - the main loop's WaitNextEvent yields let
the target come forward and redraw), reads the now-front window's fresh
bounds, crops the capture to them (`capture_screen_rect` - one blit,
clamped to the screen), saves a PICT to the Desktop, and restores NOW.
Watched on the PB1400c: a captured window PICT, well-formed 8-bit with
its CLUT and PackBits rows, opened as the real window. So the whole rung
proves out end to end: extension captures anchors -> app validates and
reads bounds -> app crops a genuine screenshot to them.

**Rung 3 - the `process.*` wire family is metal-verified, host Processes
module metal-verified** (2026-07-21). The contract
gained
`process.list`/`process.listing` (symmetric, paginated by a 1-based
cursor, entries capped at 24 a page). The guest serves its own Process
Manager walk on request (`serve_process_list` in `wire.c`: name, kind of
application/background/finder, code/creator 4CCs, sizeKB, front). The
host answers the mirror direction with its own running apps
(`HostProcesses` off `NSWorkspace` - the degraded plane: modern macOS
gives no OSType code/creator and no classic partition size, so those
fields are honestly absent), and can ASK via `GuestListener.listProcesses`.
Tested here: a byte-accurate guest fixture (multi-`snprintf`, so the
conformance check names it as needing one), a `process.list`/`.listing`
round-trip, and the conformance known-partial set. A `NOW_METAL` test
(`MetalProcessTests`) pages the real PowerBook's process table onto the
host and prints it; run on the PB1400c (2026-07-21) it read 8 processes
correctly classified - the `appe` faceless-background set (Control Strip,
Folder Actions, ORiNOCO Monitor, tbt-appe), the Finder by `FNDR`, three
`APPL`s, and the guest itself flagged front. The host now DISPLAYS it: a
read-only Processes module (`ProcessesModel`/`ProcessesModuleView`) that
pages the whole table in on refresh, groups it into Applications (with
the Finder) and Background, flags the front process, captions each row
with kind/4CCs/partition size, and reads as the snapshot it is ("as of
HH:MM:SS"). Metal-verified on the PB1400c: the pane drew the machine's 7
processes correctly grouped and flagged.

**The one-way direction is by design, not a gap.** NOW drives old-from-
new - the host is the cockpit, the guest the operated machine - so
host-sees-guest is the product and guest-sees-host is a non-goal. The
guest issues no verbs at the host and has no ASK/UI for the host's
processes, on purpose. The wire family stays symmetric in MEANING, but
the host serves nothing back: the dead `HostProcesses`/`NSWorkspace`
serve was removed rather than kept as ballast (2026-07-22).

**Drive verbs added (2026-07-22).** The Processes pane grew three actions
on the selected row, all host->guest: Bring to Front (`process.front` ->
`SetFrontProcess`), Ask to Quit (`process.quit` -> a 'quit' Apple Event it
may decline), and Screenshot App. Each names its target by the PSN the
listing now carries (`psnHigh`/`psnLow`); the guest re-validates the PSN
against a live process before acting, and refuses a quit of NOW itself -
that would sever the wire mid-reply. `process.front`/`.quit` share one
`process.result` reply; their Toolbox calls are factored into
`proc_actions.c` so the guest page and the wire handler use one
implementation. **Front, Quit, and the self-quit refusal are
metal-verified on the PB1400c.**

Screenshot App is its own verb, `process.shot`: the guest fronts the
process, waits ~0.75 s for it to repaint (a deferred service pass, like
the page's Front & Capture), reads its front window's fresh bounds off
the anchor plane, captures ONLY that rectangle (`capture_screen_rect`),
restores NOW, and delivers the crop over the capture transport - it
reuses `arm_transfer`/capture.begin so the host receives it exactly as
any capture, landing in the Screenshots module. The guest owns the
timing, so the host-side delay hack is gone. **Metal-verified cropping
Finder and Strider on the PB1400c** (2026-07-22). When the window bounds
cannot be read - a genuinely windowless process - it falls back to a
full-screen capture rather than erroring: the app is front, so the screen
with it on it is a truthful answer.

**Self-read fixed** (2026-07-22): NOW reading its OWN windows returned
"unreadable" (in the detail pane and to `process.shot`, which then failed
"capture ended without a begin"). Cause: the anchor plane walks foreign
memory at the classic 68K `WindowRecord` offsets, and NOW is a Carbon app
whose own window records do not sit there. `now_peek_windows_for_psn` /
`now_peek_window_count` now special-case self (`SameProcess` with
`GetCurrentProcess`) and read NOW's own windows straight from the Window
Manager (`FrontWindow`/`GetNextWindow`/`GetWindowBounds`/`GetWTitle`) -
no reason to go foreign for oneself. So self now crops like any other
process; the full-screen fallback remains only for the truly windowless.
**Metal-verified on the PB1400c** (2026-07-22): the detail pane reads
NOW's own windows and Screenshot App crops NOW's Workshop window.

With that, the whole drive arc is metal-verified: Bring to Front, Ask to
Quit, the self-quit refusal, and Screenshot App cropping Finder, Strider,
and NOW itself.

**Smell, now fixed (tested, not yet metal-verified):** the host's process
list could hold stale PSNs across a guest relaunch, and a drive verb on a
stale PSN failed (safely - the guest re-validated and answered ok:false /
capture.end ok:false) until a manual Refresh. The list now notices the
connection itself: `ProcessesModel` drops its whole table the instant the
connection leaves `.connected` (rows belong to one connection, and the
next guest reconnects with fresh PSNs), and the view re-reads on any
transition back to connected - so a reconnect, or a pane reopened after
one, reads afresh without a manual Refresh. Clearing on disconnect also
covers the case the view's `.onChange` cannot see, a reconnect that
happens while the Processes pane is closed. Host suite passes and the app
builds; still needs a metal pass (relaunch the guest, confirm the list
updates and the three drive verbs work with no Refresh). `process.launch`
(opening an
app that is not yet running) is the honest next verb; it needs a
path/signature to name an unlaunched app, not a PSN. Everything is tested
(contract round-trips incl. `process.shot`, a guest `process.result`
fixture, the drivable/PSN decode) and builds clean on both halves.

**Metal found one rung-0 bug, now fixed:** the detail pane's "Launched"
line read "1/1/04" for every process. `ProcessInfoRec.processLaunchDate`
is ticks since boot, not a 1904-epoch date, so `LongDateString` clamped
it. Now rendered as elapsed time via `proc_uptime_text` (pure, native-
tested, watched failing by mutation): "3 min ago", "2 hr 14 min ago".

**Workshop follow-ups, deliberately not done in the arc:** a CarbonLib
1.6 launch gate (wire.c still surfaces `kConnNeedsCarbonLib` at connect
time instead); the capture disclosure's expanded state is session-only,
not persisted; the Files page's Send File button sits in the share block
rather than the header placard the spec drew; and the sidebar has no
focus ring, so Tab reaches controls but never the rail (arrows work
whenever no field has focus).

## Broken

**Hard system crash (error 10) on quit — root-caused and fixed, metal
soak pending (2026-07-23).** Twice, quitting NOW hard-crashed the guest
(error 10, a Line-F/unimplemented-instruction exception) and required a
reboot; not every quit, and the app logged its own clean "stopped"
first. Root cause: a shutdown use-after-free in every Data Browser
module. `workshop_close` disposes each module (`g_ops[i]->dispose()`)
BEFORE `DisposeWindow`, but each module's dispose freed its Data Browser
item-data/notification/compare UPPs while the browser control was still
live in the window — on the belief that "the window took the controls
with it," which the call order makes false. `DisposeWindow` then tore
down that live browser, which fires item notifications (removal, a
deselect) through the now-freed UPPs. On PPC a UPP is a transition
vector; once freed and reused, that call lands in garbage — an illegal
instruction that corrupts the system heap, hence the reboot. Intermittent
because it depends on whether the freed block was reused yet and whether
the browser still held items to notify on. Fixed in all four DB modules
(software, processes, census, files_browser_view): `DisposeControl` the
browser FIRST — while its UPPs and model are still valid — then free the
UPPs, then the model. Builds clean under `-Werror`. **Unverified:** an
intermittent crash cannot be proven gone by one quit; it needs a soak of
repeated quits from each Data Browser page on the PowerBook. The Processes
page was "metal-verified" and still carried this — the verification never
included a quit-crash soak, which the ledger should now expect. To make a
recurrence diagnosable, teardown now leaves a FLUSHED breadcrumb before
each step (`quit: closing connection` → `stopping pump` → `removing
handlers` → `disposing window` → `clean`) and closes the log LAST: a
crash log that ends at `quit: disposing window` says the fix did not
hold; one that reaches `quit: clean`/`stopped` is a clean teardown.
Ordinary log lines sit in the disk cache and a crash loses them, so the
breadcrumbs force `FlushVol` (`now_log_flush`), the same guarantee
`now_log` already gives an error line.

**Resume by offset hangs.** A transfer resumed against a matching
partial does not complete. The failing test is committed rather than
skipped (`MetalLargeTransferTests`), which is the right shape: the
feature announces its own absence. See `docs/large-transfers.md`.

**One large transfer in about six degrades badly.** 12 MB normally lands
at ~293 KB/s; occasionally a run collapses anyway. The mechanism behind
the common case is understood and fixed — this residual says the
understanding is not complete. Measured, not reasoned about; the numbers
are in `docs/large-transfers.md`.

**An unreachable host presents as a hang.** Reimplemented on
`claude/processes-module-cb2d9c` (2026-07-21) after the wedge bit again
on metal: `now-guest-processes` decoded under a fresh name, found no
prefs, dialed `10.0.2.2`, and a synchronous `OTConnect` to an address
that never answers blocks INSIDE the call — before the first update
event, so the window stays blank and only a force quit ends it. The fix
is the codex branch's shape (`160ed85`) rebuilt against this tree: the
endpoint goes asynchronous for the dial only, a notifier publishes one
flag, the main loop finishes or fails the connect, and the endpoint
returns to synchronous before the hello. `now_log_open()` also moved
above `conn_init()` so this failure finally leaves a log.
`ot_connect_source_test.py` pins the sequence — it was watched failing
against the pre-patch sources — because this fix has now been lost
once. **Metal-verified 2026-07-21** on the PB1400c: launched with no
prefs it dials the gateway and the UI stays alive and drivable, where
before it wedged blank. (The emulator forgives the synchronous form,
so this could only ever be proven on hardware.)

**The Connection fields were dead once Connection became a page**
(fixed 2026-07-21, `claude/processes-module-cb2d9c`). Address and port
took no clicks. The real cause, after two wrong guesses: the Workshop
window had **no root control**, so it had no control-embedding
hierarchy, so `SetKeyboardFocus` could not work and an edit-text
control could take neither focus, clicks, nor keystrokes. This is the
same wall the Console hit on metal - "the edit-text field never took a
keystroke" - which is why it hand-rolled its input. Connection is the
only page that uses edit-text controls; every other page's controls
(buttons, checkboxes, popups, Data Browser, scrollbar) respond through
`TrackControl`/`HandleControlClick`, which need no focus, so only
Connection was affected.

Two dead ends before the fix, both worth recording because they are
the wrong instinct:

1. `FindControlUnderMouse` instead of `FindControl` - no effect, because
   the window had no embedding hierarchy to be wrong about.
2. Adding a root control to the window. It got the field to *focus* but
   it still took no mouse or keys (the Appearance edit-text control just
   does not work for entry in this WaitNextEvent app), AND it **broke
   every other control in the group**: a root control turns the
   group-box control into an embedder, and an embedded control only
   receives clicks when HIToolbox's standard Carbon Event handler routes
   them, which this app deliberately does not install. So the retry
   popup and checkbox - which had worked - went dead too. The root
   control was removed.

The fix that holds: no root control anywhere (controls stay flat
siblings the classic Control Manager hit-tests directly, with plain
`FindControl`), and text entry moved out of the page entirely. Address
and port are drawn **read-only**; an **Edit** button opens a
movable-modal **dialog** (`conn_edit_dialog.c`, DLOG/DITL 301) whose
entry the **Dialog Manager** drives - `GetNewDialog` +
`ModalDialog(now_pump_modal_filter())` + `GetDialogItemText` on
`editText` items. That is the exact mechanism the original Connection
dialog used before the Workshop rewrite, proven on this PowerBook; its
own window has its own text handling, independent of the Workshop
window. The filter pumps the wire; validation stays in `conn_fields.c`.

Net change from the last metal-verified state is only the Connection
dialog: every page's control handling is back to no-root + `FindControl`.

**Metal-verified 2026-07-21** on the PB1400c: the "Other Mac"
popup/checkbox/Edit button click, the Edit dialog's fields take clicks
and keys, and Save repoints the connection - which is how the
wrong-port chip got corrected. Screenshots/Files/Console unchanged.

**Type-select does nothing in the browser list.** Selection,
double-click and header sorting all work; typing a letter does not jump.
`SetKeyboardFocus` is set and the key reaches the control. Universal
Interfaces 3.4 has no type-select column flag, so the likely answer is
that Data Browser wants the Carbon Event path — which means an event-
model migration, and the Carbon UI skill explicitly warns against
running two competing top-level loops in a mature `WaitNextEvent` app.
Not load-bearing; parked as a known gap rather than chased.

## Unverified on the machine

Everything here builds and passes its tests. None of it has been watched
working on the PowerBook.

- **The `gestalt` reply's truncation path** (2026-07-30, branch
  `claude/goofy-sutherland-3e6cf4`). `run_gestalt` used to write every
  structural byte of its JSON — the `[`, `]`, `,` and the quotes around
  each label and value — with a bare `out[pos++]`, checking the cap only
  around the escaped text and once more at the very end, *after* all the
  unchecked writes. It never bit: a whole-machine gestalt is about 26
  rows and sits well inside the 3072-byte buffer `wire.c` passes. But
  `kGestaltMaxRows` is 48 and a `GestaltRow` is 96 bytes, so a machine
  answering more selectors, or one more group, would have run past the
  caller's buffer rather than truncating.

  The serializer now lives in `now-guest-ppc/src/commands/gestalt_json.c`,
  split out precisely so the host `cc` can run it at caps no Macintosh
  will ever produce — `gestalt_json_test.c` sweeps every cap from the
  floor to 6000 with a poisoned guard region past the bound. That sweep
  found a second defect the hand-picked sizes missed: the `]` closing a
  group is a write like any other and can be the one that hits the
  bound, and clearing `group_open` regardless left an array nothing
  closed.

  A truncated reply now says so, in a `notice` group carrying
  `["truncated", "<n> rows omitted - reply buffer full"]` (contract:
  `x-commands/gestalt/output`), because a short reply and a machine with
  fewer facts to report were previously indistinguishable. Room for it is
  held back from the cap up front — a buffer too full for rows is also
  too full for the sentence explaining why.

  **What has not happened:** no real gather has ever been large enough to
  truncate, so the notice has never crossed the wire from a Macintosh,
  and no host UI has been seen rendering it. The host's console shows
  command.result groups generically, so it should appear as a group named
  `notice` with one row; that is inferred from the code, not watched.
  Anyone with a machine that answers unusually many selectors is the
  first person who could confirm it.

- **`ps` on NOW-68K's wire** (2026-07-25, branch
  `claude/host-console-remote-shell`). The dumb-shell console landed and
  `ps` still came back `unknown-command` from a 68K guest that ran it
  perfectly at its own keyboard: it had been added to `conwin.c` alone,
  reading the `process.list` family the wire already served. A message
  family serves a module, not a person — the host console sends commands
  and nothing else — so `ps` is now in `commands68.c`'s table and its
  reply is built by `n68_proclist_render_ps()` from the same
  `proc_list_rows()` walk that feeds `process.listing` and the guest's
  own console text.

  Tested here: the new renderer's shape, its empty case, its refusal at a
  hopeless cap and its worst-case row bound (`test_proclist.c`, and the
  truncation guard watched failing by mutation); two host fixtures for
  the reply as the guest writes it; and a new parity test,
  `testEveryVerbTheSixtyEightKConsoleAnswersIsAlsoOnItsWire`, watched
  naming exactly this bug when `ps` is pulled back out. The 68K guest
  cross-compiles clean. **Unverified:** nobody has typed `ps` into the
  host console against a real 68K Mac. Two things to watch when someone
  does — the truncation row (`["...", "N more not shown"]`) appears only
  on a machine running more processes than a 1 KB control frame holds,
  which is roughly a dozen and may never happen on a 7.1 machine; and the
  detail column is meant to read identically to the PowerPC guest's, which
  no run has yet compared side by side.

- **The dumb-shell console, both guests** (2026-07-25, branch
  `thread/host-menu-dumb-console`). The host console no longer knows what
  commands the guest has: it sends `command.request` with `line` — the raw
  text a human typed — and renders whatever comes back. Every argument
  grammar moved to the machine that serves the verb
  (`now-guest-ppc/src/commands/cmd_line.c`, natively tested by mutation), `help` became an
  x-command answered from the one doc table each guest already showed its
  own console (`now-guest-ppc/src/commands/cmd_help.c`,
  `now-guest-68k/src/commands/commands68.c`), and the host's Tab completion is that
  answer at runtime.

  Tested here: 459 host tests, the two new native guest tests, and both
  guests cross-compile clean at `-Wall -Wextra -Werror`. **Nothing has
  been typed into a console on either machine.** What that leaves
  specifically unverified:

  - `gestalt` slicing now happens guest-side from the line (`--full`,
    `--cpu`, …). Absent-`line` behaviour is unchanged for modules, but no
    human has typed `gestalt --memory` at a PowerBook.
  - `screenshot --depth 8 --no-save` and `tail 40` parse from the line
    for the first time; the old host-side parsers are gone.
  - `help` on the PowerPC guest builds a ~1.2 KB reply against a 4 KB
    control frame with a byte-budget truncation row. The budget is
    reasoned, not measured on the wire.
  - `help` on NOW-68K builds into a 512-byte payload buffer and measures
    ~260 by hand-count. It has never been sent.
  - The MacRoman decode of an accented path typed as a console line
    (`ls Café:Notes`) is covered by a native test on the decoder, not by
    a file with that name on a real HFS volume.

- **⌘Q's farewell, on metal** (2026-07-25, same branch). The host now
  returns `terminateLater` and waits for `bye shutting-down` to reach the
  socket before the process ends, bounded at 0.5 s. Tested here by
  sequencing (mutation-verified: a shutDown that reports synchronously
  fails), and the menu bar and its Quit item were driven live through
  accessibility on this Mac. **Not verified:** that the ⌘Q *keystroke*
  dispatches (script-driven activation is refused in this environment, so
  the item was clicked rather than typed), and that a PowerBook watching
  the wire draws the right conclusion — the guest's own "host went away"
  handling has not been observed against a real quit.

- **`quit <name>` — the deploy loop's missing half** (2026-07-25,
  branch `thread/guest-quit-command`). A console command and x-command
  that composes `process.list` → match by name → re-validate →
  `process.quit` → **re-list**, so it can report `gone` apart from
  `still-running`. Design, outcome table and the decisions behind each
  case: [`processes-and-peek.md`](processes-and-peek.md#quit-name--the-same-action-named-the-way-a-person-names-it).

  **Emulator-verified, end to end, on mac99 / OS 9.1 / CarbonLib 1.6** —
  both invocation paths, and every outcome the composition can produce:

  | Watched | Result |
  |---|---|
  | Guest console `quit SimpleText` | `"SimpleText" is gone (0.3 s)` |
  | Guest console `quit --no-wait SimpleText` | `asked "SimpleText" to quit; NOT confirmed (--no-wait)` |
  | Guest console `help quit` | renders |
  | Wire `quit SimpleText` | `gone (0.1 s)`, and confirmed absent by an independent `process.list` |
  | Wire, dirty document | `[quit-declined] … is STILL RUNNING after 4 s`, with SimpleText visibly sitting on its Save dialog |
  | Wire, nothing of that name | `not-running`, `ok:true` |
  | Wire, its own name | `[quit-refused]`, and still there afterwards |
  | Wire, no target / unknown flag | `[quit-bad-args]` |

  The acceptance driver is committed: `MetalQuitTests` (`NOW_METAL=1`,
  plus `NOW_QUIT_DIRTY=1` for the human-in-the-loop declined case).

  **What the PowerBook still has to settle.** The emulator says nothing
  about *timing* on a 117 MHz 603e: SimpleText answered in 0.1–0.3 s
  there, and the 6 s default was chosen for a slower machine, not
  measured on one. Nor has the deliberate stall been felt on metal — for
  up to `--wait N` the guest's window does not repaint (it keeps
  servicing the wire; see [`nested-loops.md`](nested-loops.md)), and
  "does that read as a hang?" is a question about a real screen. An
  isolated copy is staged at `Lab:now-quit` on the 1400c (its own name,
  so its own preferences; fork sizes verified against the local
  MacBinary, 565127 / 2439). Being non-canonical it starts with no
  preferences and dials 10.0.2.2, so the **console** path needs no host
  at all — that is the one to run first. The real target is NetPresenz
  on a 180c, which is a different machine and a different client.

- **`catsearch` — the Software module's feasibility probe** (2026-07-22).
  Times a whole-volume `PBCatSearch` sweep for APPL files on the startup
  volume, in 15-tick slices, cold then warm. Console verb on both sides
  (contract `x-commands`, guest `commands.c`, host `ConsoleModel`).
  **Metal-verified on the 1400c** (guest console path; same-day emulator
  run agreed in shape): 22,127 files / 2,411 folders, 601 APPL hits,
  cold sweep **228 ticks = 3.8 s in 184 slices**, warm 172 ticks =
  2.9 s, longest slice 3 ticks against the 15-tick budget, zero
  restarts. Two conclusions the Software module can build on: a full
  inventory sweep is affordable as background `idle()` work (~50 ms
  worst slice), and 184 slices ≈ the catalog arriving one 16 KB opt
  buffer per call — so the buffer size, not `ioSearchTime`, is the
  real slice-length dial. Warm is barely cheaper than cold; do not
  design around the cache. The host-console invocation was watched
  working too (2026-07-22, post-merge build), so both invocation paths
  are metal-verified — including MacRoman-high-byte names in
  `First hits` crossing the wire through the `\uXXXX` escaper.

- **Software rung 3 begins: the page is registered and appears**
  (2026-07-22, spec in `software-module.md`, mock in
  `mockups/software-mockup.html`). The six-edit registration for a new
  nav module landed and is **emulator-verified**: Software shows as the
  6th rail row (a boxed-app-tiles `ics#` 136) between Hardware and the
  pinned Logs/Connection pair, Cmd-6 selects it, and it draws the live
  installed-software overview (139 extensions, 33 control panels, …).
  The delicate part — inserting Software as id 6 pushed Logs 6→7 and
  Connection 7→8, the first insert to move an existing non-pinned id —
  bumped prefs to **format 14** with a remap lifting both; the
  save/load round-trip is verified (quit + relaunch reopened on
  Software). Two supporting pieces are host-cc tested and integrated:
  `software_layout.c` (split-view geometry) and `sw_vers_parse.c` +
  `now_software_read_version()` (the `'vers'` parse extracted to a unit
  with a mutation watched failing under ASan; the per-row primitive the
  trickle will call). **Still ahead on this rung** (the frame is drawn,
  these land on it): the interactive Data Browser with the FSSpec-
  bearing item model, the domain popup, live search, the launch/front/
  quit/reveal buttons, and the idle-paced version trickle. None of that
  is metal-verified yet — only the emulator, and only the page's
  appearance + prefs migration.
  - **Interactive cut (2026-07-22):** first version was hand-drawn and
    metal-tested the same day; the second metal round found real
    problems, all fixed and re-verified in the emulator:
    - **The module leaked port state.** Three `RGBBackColor(white)`
      calls on the one shared Workshop window turned EVERY page's
      background white. Fixed by rule, not by restore: the module
      never touches the background color — white interiors are
      fore-painted with `PaintRect`. Watched fixed (Hardware gray
      again after visiting Software).
    - **The list is a real Data Browser now** (the processes_module
      pattern): Platinum header buttons, native four-column sort,
      native truncation/scrolling. Loading appends items and versions
      update one cell — the flashing was the hand-drawn list's
      invalidation model, and it is gone with the list.
    - **Domains cache in memory for the run** (lazy NewPtr each);
      switching rebuilds the browser from the cache, never the disk;
      Rescan is the only re-read; the apps sweep is resumable across
      switches. Watched: Extensions ↔ Applications both ways, the
      restore instant with versions intact.
    - The search field takes its click (focus ring); the detail pane
      is a group box with theme fonts and the selection's icon
      (`GetIconRef` on first selection only, cached for the run).
    **Emulator-watched:** sweep→browser fill, version cells trickling,
    live search (8 of 205), the domain popup driven by a genuine held
    QMP drag, cache restores, page-switch persistence, the bg fix.
    **Not watched, needs a human click:** row click-to-select and the
    search focus ring — a control experiment showed the metal-verified
    Processes browser ALSO ignores injected clicks (atomic and
    QMP-held), so this is an injection-vs-DataBrowser artifact, not a
    known defect; still, only a hand on a mouse closes it.
  - **Fourth round (2026-07-22):** the third metal round's four asks.
    The residual flashing was batched *sorted* inserts shuffling
    visible rows — the browser is now fed nothing mid-sweep (the
    placard counts arrivals) and populates ONCE at sweep end, watched.
    **Duplicate groups**: same-name items collapse under a container
    row (disclosure in the Name column, "N items", aggregate size,
    running-if-any; parents disclose, never select) — watched as
    "now-guest · 2 items · 1.0M · running" with indented per-version
    children, isolated by search ("2 of 206"). **Where:** the full
    path, wrapped, in the detail — watched, computed on selection
    never in draw. **Show in Finder**: alias in a 'misc'/'mvis' Apple
    Event, Finder fronted — watched revealing Note Pad in Apple
    Extras, matching the detail exactly. **Bring to Front / Quit**:
    wired over the metal-verified `proc_actions` with a fresh
    at-act-time PSN join; unwatched as buttons (the VM's only running
    singleton is the injection channel itself). Also unwatched:
    groups' collapsed-default on the unfiltered list. Nothing in this
    round is metal-verified yet.
  - **Metal feedback on the host page (2026-07-23), two fixes.**
    (1) **The `®` was passed down poorly.** A launch/reveal from the
    host against an app with a non-ASCII name ("Adobe Photoshop® 5.0")
    came back "no such file", the echoed path double-mangled to `¬Æ`.
    Cause: the host sends HFS names as UTF-8 (® = `0xC2 0xAE`), but
    `run_launch`/`run_vers`/`run_reveal` read `target` with
    `now_json_find_string` (a raw byte copy), so `FSMakeFSSpec` never
    saw the MacRoman byte (`0xA8`). Fixed by reading `target` with
    `now_json_find_text` — the inbound half of `now_json_escape`, which
    decodes `\u` and raw UTF-8 back to MacRoman (a json_native_test case
    pins the ® round trip). **The same latent bug in the Files path
    commands** (mv/trash/restore/mkdir/offer/list/get in wire.c, console
    `ls`) was fixed in the same defect class by a parallel task — see
    "Non-ASCII paths INBOUND" in the Files section, guarded by
    `test_inbound_hfs_path` and a source-reading conformance test.
    (2) **Selection hilite
    hugged the text.** The Data Browser's default
    `kDataBrowserTableViewMinimalHilite` draws the selection only behind
    each cell's glyphs, so a selected row read as three disconnected
    patches; switched to `kDataBrowserTableViewFillHilite` for one
    continuous full-row bar (CarbonLib 1.1+, we floor at 1.6). Guest
    builds clean under `-Werror`; both **unverified on metal** — the
    reveal round trip needs the connected session, and the hilite is a
    visual change to watch on the PowerBook.
  - **Host page reaches parity: split-pane, detail, reveal
    (2026-07-22).** The host Software page grew a second half. It is now
    an `HSplitView` — the inventory Table on the left, a detail pane on
    the right carrying the selected item's version, size, state, kind,
    and full path (selectable), with **Launch** and **Show in Finder**
    beneath it. Search was already there; it stays, above the split.
    "Show in Finder" is a **new wire verb, `reveal`** — launch's
    read-only twin: it resolves a target exactly as launch and vers do
    (path / `#n` / bare name) but reveals ANY item (an extension, a
    control panel), since it opens nothing. The guest serves it by
    sending its OWN Finder a `kAEMakeObjectsVisible` for the item's
    alias then fronting the Finder — the same `now_software_reveal` the
    guest page's own button uses, now reachable from the host and the
    console (`reveal <name|path|#n>`). Contract-first: the `reveal`
    x-command is declared, answered in `commands.c`, and offered by the
    host console — `CommandRegistryTests`' three-way agreement holds.
    Host suite green (276) incl. a reveal test; guest builds clean under
    `-Werror`; audit clean. **Never run live**: like rung 4, the reveal
    round trip and the split-pane page both await a connected session
    with both new builds. `reveal` from the host console against a live
    guest, and the detail pane's two buttons, are the one-sitting check.
  - **Rung 4 lands (2026-07-22): versions on the wire + the host
    Software page.** `serve_software_list` now fills each served
    entry's version (a page's worth of fork opens per request, bounded,
    explicitly asked for); the contract, fixture, and Swift docs agree.
    `SoftwareModel`/`SoftwareModuleView` mirror the guest page
    host-side — domain picker over a Table, client-side search, Launch
    by the entry's path (the guest's words shown either way), the
    listing's `note` surfaced verbatim — registered between Hardware
    and the footer. Host suite green incl. `SoftwareModelTests` and the
    updated registry manifest. **Never run live, all of it**: the
    `software.list` round trip (and now the version enrichment and the
    page on top of it) awaits the first connected session with both new
    builds — `swpage extensions` in the host console, then the Software
    page itself, is the one-sitting check.
  - **Fifth round (2026-07-22):** the metal report "a collapsed group
    will not re-expand" was a real contract miss: closing a container
    REMOVES its children (the Data Browser's own behavior) and
    item_notify ignored container notifications, so reopen had nothing
    to show. Fixed: kDataBrowserContainerOpened re-adds the group's
    children, idempotent via GetDataBrowserItemCount. **Unwatched** —
    the disclosure triangle defeats click injection; the repro is on
    the PowerBook. Also added: a **draggable splitter** between the
    panes (gray XOR outline, own StillDown loop pumping the wire —
    nested-loops.md row added — clamps tested host-cc, session-only
    width). **Watched end to end** in the emulator. Bonus close: a
    press-MOVE-release drives the Data Browser under injection, so
    **row click-to-select is now watched** (previously the oldest gap).
    Known nit: below ~260px list width the fixed columns clip; a
    tighter clamp is a one-liner when it bothers. The whole-window
    redraw on module switch is spun off as its own task (parent
    container, not this module).
  - **Sixth round (2026-07-22):** the search field repainted the whole
    module per keystroke — Remove-all/Add-all, an unconditional detail
    invalidation, the group qsort, and a catalog walk, every key.
    Typing now refilters by DIFF against a view set (delta rows only,
    groups leave children-first), the detail is touched only when the
    selection actually changed, and there is no auto-pick mid-typing.
    The full rebuild remains for content changes. Per the redraw
    contract added to `classic-mac-carbon-ui` the same day. Emulator-
    watched: the selection and detail pane SURVIVE keystrokes
    untouched; a filtered-out selection clears once. The reduced
    repaint itself, like all flicker, only reads on metal.
    - The field itself still blinked (whole-field invalidate + full
      white repaint per key). Typing now echoes the DELTA directly —
      the contract's immediate-feedback exception: erase from the end
      of the unchanged prefix only, draw the tail + caret, clip
      restored, nothing invalidated; draw_search reproduces the same
      pixels at any real update. Emulator-watched ("quicktime" typed
      and backspaced entirely through the echo path).

- **Software rungs 1–2: resumable sweep, `vers`, running tags, and the
  `software.list` family** (2026-07-22, spec in `software-module.md`).
  Rung 1 is **emulator-verified**: `sw extensions` tagged exactly the
  three running `appe` files the harness's process list names
  (Control Strip Extension, DVD AutoLauncher, FBC Indexing Scheduler),
  and `vers SimpleText` read Version 1.4 / "1.4.0 final" / the Get Info
  string / Product 1.1 by name-search resolution. Known texture:
  Application Switcher runs but is untagged — its process appSpec
  evidently names the System file, and the strict FSSpec compare
  declines to guess; that is the join being honest, not a defect.
  Rung 2 (the wire family, served from a one-domain cache with
  full-path launch keys) **builds and is host-tested** — fixtures pin
  the piecemeal listing including a MacRoman ® — but has **never run
  live end to end**: it needs the new host build connected to the new
  guest build, driven by the host console's `swpage [domain] [cursor]`.
  - **First metal round (2026-07-22, partial):** `sw apps` and `vers`
    ran on the 1400c from the host console. Two findings, both closed
    the same day: `launch` from the host dispatched as unknown-command
    — the host sorts JSON keys, `args` precedes `name`, and the guest
    scans frames FLAT, so launch's arg named "name" was read as the
    command name (arg renamed `target`; the never-shadow-an-envelope-key
    rule now lives in the contract's x-commands preamble); and `vers`
    on a bare name met the disk's several SimpleTexts — it now shows
    every match path-first instead of refusing, `launch`'s ambiguity
    refusal names the paths, and a duplicate finder (same/different
    version, user-driven consolidation) is marked in the spec as later
    work.
  - **Second metal round (2026-07-22, same day):** the multi-match
    view worked but truncated paths mid-folder, and retyping a full
    HFS path to disambiguate is brutal. Both fixed: matches print as
    a **numbered list whose paths wrap** across continuation rows,
    the list is **stored on the guest**, and `launch #2` / `vers #2`
    pick from it — either console, one wire frame. launch's ambiguity
    answers a distinct `launch-ambiguous` code for a future host UI.
    Emulator-verified with a manufactured duplicate (two now-guests:
    refusal listed both full paths, `vers #2` read the picked copy,
    `launch #1` launched).
  - **Third metal round → launch redesign (2026-07-22, same day):**
    the numbered-pick flow worked on the 1400c but read as too much
    ceremony for "just open it." `launch <name>` now launches the
    **highest-versioned** copy and names it in the reply (a visible
    answer, not a hidden guess); `launch <name> <version>` forces a
    copy by its short version string; full path and `#n` still work.
    The whole arg is tried as a literal name first, so "Sherlock 2"
    stays whole. Emulator-verified (newest-of-2, version pick,
    wrong-version message, single-match plain launch).
  - **Fourth round → `-v` flag (2026-07-22):** launch-newest became
    too surprising to reason about (which version won?), so the shape
    settled: `launch [-v VERSION] NAME`, NAME the whole remainder
    (spaces need no quotes; quotes stripped if used), a bare ambiguous
    name launches the FIRST found and names its version (one fork
    open, no walk), `-v` forces a copy, positional `Name 1.2.3` retired
    with a "did you mean -v" hint. Emulator-verified: quote-strip,
    first-of-2-with-version, the hint. The `-v` launch flag is
    **metal-verified** (Michelle, 2026-07-22, human-typed — the
    emulator keystroke injection had dropped its leading chars, an
    input artifact, never the code). The `software.list` wire family
    (`swpage`) remains the one never-run-live path — it needs a host
    linked to the guest, deferred until the guest page is dialed in.

- **`sw` and `launch` — the software family's first verbs** (2026-07-22).
  The Software module's data layer (`software.c`) surfaced as console
  verbs on both sides before the page exists. `sw` inventories the
  special folders live (Extensions Manager's disabled siblings tagged
  "(off)") and pages applications via the catsearch-verified APPL sweep,
  stopped at one page; `launch` opens an application by exact-name
  search or full HFS path, refuses ambiguous names, and logs outcomes
  under `sw` — it is the family's one mutation. Versions are
  deliberately absent: one `'vers'` read per file is the expensive
  path, deferred to the module's lazy detail.
  **Emulator-verified** (OS 9.1 clone): overview counts (139/33/0/13),
  `sw extensions` with types+sizes, `sw apps` page with the more
  marker, and `launch SimpleText` bringing a live SimpleText to front.
  **Not yet watched on the 1400c**, and the guest's LOCAL `launch`
  intentionally does not log (only the wire path does — same rule as
  `ls`/`ps`); the host-console invocations of both verbs are
  host-tested but unrun live.

- **A page switch paints once, and only what changed** (2026-07-22).
  Michelle watched Workshop page switches repaint the whole window on
  the PowerBook — rail, placards, everything. The investigation found
  the container's *invalidation* was already scoped (header/body/status
  plus the two selection rows); the churn was in the *painting*, three
  ways: `HideControl`/`ShowControl` draw immediately, so
  `show(false)`/`show(true)` repainted the pane piecemeal before the
  update event repainted it again; the update handler's full-port
  `EraseRect` painted the invalidated rail rows theme-gray a beat before
  the rail's own white erase; and `DrawControls` followed by
  `UpdateControls` drew every control twice per update. All three fixed
  in `workshop_window.c` alone: the swap runs under an empty clip and
  paints exactly once at the coalesced update, the erase narrowed to the
  body plus the sidebar gutter outside the rail panel (the placards and
  the rail fill their own faces), and one `UpdateControls` pass.
  Emulator-verified: all seven pages cycle with no stale pixels, zoom
  leaves the gutter clean, controls still track after switches. **Watch
  on metal:** that the rail genuinely stops flashing at the machine's
  real drawing speed — the emulator is too fast to show a flash either
  way. One module-side offender remains, out of the container's scope:
  the copy-pasted `set_status` in screenshots/census/connection
  invalidates a full-width bottom strip (port bounds, bottom 23 px) that
  crosses the rail's foot, so the Connection row can still flick when a
  module's status line changes. The module fix is to invalidate the
  status placard's rect, not the port's.
- **The Logs page, both machines** (2026-07-22). A Monaco dump of the
  in-memory log ring that follows the tail live like a terminal, with
  Invert and Log-to-disk switches. The **guest** page was watched working
  on the PB1400c; the footer move, the invert switch, and the whole
  **host** module are built and tested but unrun since.
  - **Placement.** Pinned in the footer below the divider, directly above
    Connection — a `logs_row` on the guest (id 6, Connection 7), a
    `.footer` descriptor before `settings` on the host. The host footer
    row now shows link status only for the row that IS the link.
  - **Guest scrollback.** The ring grew 200 -> 2000 lines (`kLogKept`),
    ~240 KB of statics against a 6 MB partition. `run_tail`'s stack index
    was decoupled from `kLogKept` so it stays 48, not 2000, pointers.
  - **Disk toggle.** `now_log_set_disk`/`now_log_disk_on` (guest) and
    `HostLog.setPersistsToDisk` gate the file at runtime; the ring is
    always live. Default on (crash survival is the point). Both switches
    reflect the ACTUAL state, so a failed open reads as off. On the host
    the file is now a switch, not opened at launch — `LogsModel` applies
    the saved choice.
  - **Invert.** A dark canvas like Console, saved per page. Guest prefs
    reached format 13 for it (12 was the disk field + Connection renumber);
    the host keeps `logsInvert` in UserDefaults.
  - **Watch on metal:** the host module unrun entirely; on the guest, that
    the invert switch redraws cleanly and the footer pair (Logs above
    Connection, under the divider) lays out at 640x480.
- **`ps` and `census` console commands + guest verb logging**
  (2026-07-22). The two new modules — Processes and Hardware/census —
  had no console verb and logged nothing; both are now closed.
  - **Console.** `ps` (flat process list, the reading of `process.list`
    the Processes module drives) and `census [probe]` (one probe page,
    the flat cousin of `censusExchange`) were added across all three
    halves — contract `x-commands`, guest `commands.c` dispatch, host
    `ConsoleModel` offer + help — the way `ls` is to `file.list`.
    `CommandRegistryTests` reads all three and is green, so the set
    agrees and every offered command has help. The guest's own console
    (`console_model.c`) renders both locally too.
  - **Logging.** The guest drive verbs (`process.front`/`quit`/`shot`),
    census outcomes, and the process-list refresh now log their shape
    with the wire id (areas `proc`, `census`). The refusal *reasons*
    that used to live only on the wire now reach the log. `process.list`
    logs once per refresh (cursor 1), never per page, to stay off the
    per-chunk heartbeat rule.
  - **Verified only here:** host suite (263 tests) green, `audit_source.py`
    clean, the census/json header chains compile under
    `cc -Wall -Wextra -Werror`. **Not** cross-compiled — no Retro68
    toolchain this session, so the guest-only additions (`run_ps`,
    `run_census`, the two console handlers, the `wire.c` log lines) are
    not even at *builds* yet. First metal run should confirm `ps`,
    `census pci`/`ata`/etc., and that a declined `quit` shows in the log.
- **The Processes page's product pass** (2026-07-21) - built and
  suite-green, unrun on metal. All app-side (extension unchanged):
  - **Kind grouping.** Processes are classed from `processMode`
    (`modeOnlyBackground`), not guessed from the `'appe'` type. The list
    sorts front-process first, then applications, a divider row, then
    background-only - kind and front-ness are the sort axes, never
    window state, so a row never jumps when a window opens/closes.
  - **Row badges.** Front app reads "(front)"; apps show their window
    count ("3 windows"); windowless and background rows show none - the
    windowed/windowless distinction, visible without selecting.
  - **Richer detail.** CPU time (`processActiveTime`), accurate Kind
    with "(frontmost)", and a Windows section listing each window's
    title + size (up to 3, "...and N more"), read through the anchor
    plane's validated foreign path (now walking the `nextWindow` chain
    and reading `titleHandle`). Menus line is a reserved STUB - the
    anchor captures `MenuList`, the walk is a later pass.

  **Watch on metal:** the **divider row** is a non-process sentinel item
  in the Data Browser (`kDividerItem`), non-selectable by bouncing the
  selection off it - the one bit of fake-row territory in an otherwise
  proven-DB design; confirm it draws between the groups and cannot be
  selected. Also that window titles read correctly (another foreign
  pointer hop, `titleHandle`), and that per-app window-count reads every
  second don't cost visible time on the 33 MHz metal.
- **Prefs v10 module renumbering.** Connection moved 4 to 5; a v9 file
  should reopen on the page the person had (the remap is three lines
  in `now_prefs_load`), exercised only by reasoning - same status as
  the v9 note below.
- **Corners of the Workshop no one has exercised anywhere:** the send
  progress bar actually moving, and the preview well at 16/32-bit
  depths. (The first metal pass found two bugs - a mute Console
  edit-text and Modified dates clamped to 1/19/72 by signed
  DateString - both fixed the same night and metal-verified the next
  morning, 2026-07-21.)
- **Prefs v9.** Reads v1-v8 files and seeds the Console page from a
  legacy console_open flag; exercised only by reasoning, not by an old
  prefs file on the machine.
- **The host serving move / trash / restore / mkdir.** 13 tests, zero
  minutes of machine time. No client asks for it yet (see above).
- **Accented file names.** macOS stores names decomposed, so "café" is
  "cafe" plus a combining accent, and MacRoman has the letter but not
  the mark — every accented name was arriving as "cafe_". The fix
  composes first. Nobody has pulled an accented file to the PowerBook.
- **Non-ASCII paths INBOUND, host to guest.** The complement of the
  above, and the same defect class as the Software fix: the host sends
  every path UTF-8 (® is `0xC2 0xAE`), but `FSMakeFSSpec` wants the
  MacRoman byte (`0xA8`). The guest's file-op verbs were pulling
  `path`/`toPath`/`trashedAs` with `now_json_find_string`, which does
  not convert, so a move/trash/restore/mkdir/list of any non-ASCII name
  looked for a file that does not exist. Fixed by switching those
  extractors (and `file.offer`'s `name`, and console `ls`) to
  `now_json_find_text`; `container`/`fileType`/`creator`/tokens stay
  find_string, ASCII by contract. Guarded two ways —
  `json_native_test.c :: test_inbound_hfs_path` proves `café®` decodes
  to `0x8E 0xA8` (and that find_string leaves the raw four bytes), and
  `GuestWireConformanceTests :: testHfsPathArgumentsAreTextDecoded`
  reads the C and fails if any of those keys reverts to find_string
  (mutation-verified). **Tested, not metal-verified:** no one has moved
  or trashed an accented file from the host to the PowerBook.
- **The Finder reveal button.** "Open" in the browser sends `odoc` to
  the Finder with an alias to the downloads folder. Standard, and
  untested on metal; it is `kAENoReply` so it should not block, but that
  is reasoning rather than evidence.
- **The Hardware census module (slice 1).** New Workshop page: a passive
  census of this Mac, three Carbon-clean probes (gestalt full
  selector-table walk, video GDevice walk, volumes PBHGetVInfo), served
  over the new symmetric `census.request`/`census.report` family and
  shown in a split pane (probe list left, rows right). Builds clean
  (whole guest links; the ics# 133 chip icon compiles) and the host
  suite is green (242 tests), including a guest→host refusal round trip,
  the census.report fixture, and a mutation-checked serializer. **Not
  watched on the PowerBook.** Specific unknowns for the first metal pass:
  (1) two Data Browsers in one window — one is proven by the Files page,
  two side by side is not; (2) the full ~203-selector Gestalt walk
  paging 16 at a time; (3) the chip icon actually plotting from `ics#`
  133 rather than losing to a System family at that id. See
  docs/adding-a-workshop-module.md.
- **The host Hardware module — runs and reads the GUEST's census**
  (2026-07-22). A native macOS dossier: a `census` module in the sidebar
  (`CensusModel` + `CensusModuleView`), a probe list on the left and the
  selected probe's rows on the right, a Run Census sweep and per-probe
  rerun. It is a REQUESTER only — it asks the guest and displays the
  reports, following the `more`/`cursor` pagination to accumulate a
  probe's rows one page per request. The host probe registry
  (`CensusProbes.all`) is a copy of the guest's `k_probes[]` and the
  contract's `x-probes`; `CensusProbeRegistryTests` pins the set to the
  contract and the order to the guest, so a probe grown on one side and
  forgotten here fails a test. **Tested, not seen against a real guest.**
  `CensusModuleModelTests` drives the whole request→report path over the
  loopback listener with a scripted guest (pagination, cursor threading,
  outcome/note propagation, the full sweep, the disconnected guard, and
  rerun-replaces-not-appends); the SwiftUI view itself has not been run
  against a connected PowerBook.
- **The host does NOT serve its own census, by design.** The `census`
  family is symmetric in the contract, but the guest is the machine with
  hardware worth asking about; the host is the requester. When the guest
  sends the host a `census.request`, the host answers `refused` ("the
  host does not serve a census yet"). That is a deliberate, permanent-
  feeling asymmetry now, not a scheduled stub — a host self-census (IOKit/
  sysctl) is not planned as part of this feature.
- **The `ata` and `pccard` probes reach 68K-trap-only managers through a
  metal-proven Mixed Mode dispatch** (`census_trap.c`, 2026-07-22). The
  1400c's ATA Manager ($AAF1) and PC Card Manager ($AAF0) are trap-only
  — no CFM fragment, and `gestaltATAAttr` answers falsely absent — so a
  PowerPC Carbon app cannot import them. `census_trap.c` reaches them the
  way the parent project proved safe after four machine wedges (corpus
  `cis-metal-safe-mixed-mode-fix`): a hand-built M68K `RoutineDescriptor`
  so `CallUniversalProc` thunks PPC→68K, `CallUniversalProc` resolved from
  InterfaceLib and called **variadically** (a fixed-arg pointer leaves the
  args in registers → Type 1 bus error), and each thunk keeping its RTS
  return address on the stack. The mechanism itself is **metal-verified**
  by `spikes/census-trap`: selftest `$4242`, then real traps.
  - `pccard` (CSGetCardServicesInfo, selector 7) is **metal-verified** on
    the 1400c: CS 2.01, 4 sockets, Apple vendor string. Read-only, touches
    no socket or card, so it runs in the sweep. A card's own identity
    (its CIS) stays OUT until a gated design — the CIS is what froze the
    1400c historically (`pb1400-pccard-trap-only`).
  - `ata` (IDENTIFY DEVICE) reaches the manager and it answers `noErr`,
    but on the 1400c internal drive the IDENTIFY buffer comes back
    **empty** (metal, 2026-07-22 — buffer dumped all-zeros for the one
    device that answers, device id `$0000`). So the row honestly reports
    the device *present* without a model. A drive that fills the buffer
    decodes into model/capacity/firmware; that path is **builds-only**.
    Getting model/serial off *this* drive is a separate follow-up
    (`kATAMgrBusInquiry` enumeration, or `kATAMgrExecIO` issuing a raw
    IDENTIFY task file rather than the manager's empty DriveIdentify) —
    deferred, banked with the wins per Michelle's call.
  - The whole integrated page — `pccard`/`ata` running inside the census
    sweep and rail — is **tested and builds** here; it has **not** yet
    been metal-verified as a page (only the underlying trap calls have).
- **The `power` probe.** Slice-2 follow-up (2026-07-21). Carbon-clean
  (BatteryCount / GetScaledBatteryInfo, gated on `gestaltPowerMgrAttr`)
  and low-risk. Compiles, links and passes its decoder unit tests; has
  not run in the page on metal.
- **`network` and `software` probes, deferred as future modules**
  (decided 2026-07-21). Network (Open Transport interfaces and TCP/IP
  config) and installed-software (extensions and control panels with
  their `vers`) are both Carbon-clean and were scoped OUT of the census
  probe rail — Michelle's call was to grow them as their own future
  Workshop pages rather than more rows on Hardware. Not built; recorded
  so the intent is not lost.
- **The rail has no scroll bar.** At fourteen probes the hand-drawn probe
  rail fits the standard window (~371px of rail for 352px of rows at
  25px/row) but overflows below about the minimum window. `draw_rail` now
  clips the row list to the rail rect, so the tail truncates cleanly
  instead of painting over the button strip — but truncated rows are then
  unreachable. This is the point where the rail needs a real vertical
  scroll bar rather than shorter rows; it lands with the extension
  "witness" tier that adds the next probes.

## Reverse file streaming is bounded and verified on the machine

The 2026-07-24 reverse-path pass removed both whole-artifact buffers.
The guest now opens the source forks only after acceptance and emits one
bounded frame at a time, including MacBinary header/fork/padding
segments. The host writes each frame to a same-folder temporary file,
preflights free space, computes CRC-32 incrementally, sends batched
`file.progress`, verifies count and optional checksum, and only then
moves or stream-converts the result into place. Cancel, truncation,
checksum failure, write failure, and disconnect all delete the partial.

The native host suite exercises 256 KiB, 2 MiB, and 16 MiB payloads with
a fixed 32 KiB append bound, CRC/truncation/overrun/cancel cleanup,
atomic materialization, and text conversion across a chunk boundary.
Both guest send entry points have a source gate against whole-file
allocation, and the Retro68 guest build passes.

The bounded path is **metal-verified** on the PowerBook 1400c
(2026-07-24). A separately named guest on port 5252 preserved the
canonical pairing and persistent preferences. Data-fork pulls at 32767,
32768, 32769, 256 KiB, 1 MiB, and 4 MiB matched their generated content
and independent CRC-32. MacRoman/CR conversion and explicit MacBinary
data/resource-fork fidelity passed. Cancelling a 4 MiB pull removed its
host partial and left the session responsive. The guest process
partition was 6506 KB before and after; the 4 MiB pull added 2.23 MiB
peak host RSS and 1.94 MiB live malloc bytes.

Those numbers are bounded observations, not a transfer-rate guarantee.
The metal pass did not exceed 4 MiB, run longer than two minutes, mutate
a source during transfer, or measure guest free heap. It does not prove
rate hardening.

Reverse resume remains deliberately absent. A deployed guest supplies
no source identity before the receiver chooses an offset, so the host
cannot prove a retained partial belongs to the current source. An
interruption therefore deletes the partial and retries from zero. Adding
resume safely needs an additive guest-issued source token (and fixtures
for old peers), not an offset guessed from a filename and size.

## Structural work deferred on the host

A cleanup pass (2026-07-20) applied what was cheap and left three
extractions from `GuestListener.swift`, which is 2094 lines:

- `Session` is built with 28 `on...` closures, 25 of which only forward
  to a listener method. A `weak var owner` or a delegate protocol
  collapses about 180 lines, and adding a message stops meaning edits in
  four places.
- The share-serving block (~140 lines) touches only `share`, `session`
  and `state`. It is a file server living inside a listener.
- The outbound write path (~400 lines) shares one invariant — nothing
  may write to the connection while a bulk frame is half-written —
  currently enforced by a flag two unrelated methods must remember to
  check. As its own type the flag cannot be forgotten.

These were skipped on purpose. Two reviews proposed DIFFERENT
reorganisations of the same file, and the receiving-half work above
implies a third (one transfer sink rather than three accumulators).
Doing any one now makes the others harder, and only the receiving half
has a consequence beyond tidiness. Whoever takes that should take these
with it.

## V1 host product work is planned, not implemented

The [NOW V1 host product roadmap](plans/2026-07-24-002-feat-now-v1-host-product-roadmap-plan.md)
starts only after the optional MCP companion V0 is complete. It commits a
persistent target catalog and host-side improvements to Files, Processes,
Software, the menu bar, quit policy, and Settings while retaining the
current guest-dials-host, one-port, single-session transport.

V1 explicitly defers a guest listener, multi-session runtime, mobile
transport, and shared protocol service. Any common-protocol extraction
waits for CodeKitten's separate listener, pairing/security,
health/latency, recovery, cooperative-loop, and adversarial multi-peer
proof and would begin in another worktree. The exact target-switcher
information architecture, pairing-conflict UX, thumbnail and history
retention, inventory analyses, local-browser defaults, and remembered
module-state policies remain intentionally open.

## MCP V0.5 guest Files command seam has a tested staged-upload slice

The approved
[NOW MCP V0.5 guest-files roadmap](plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md)
now has its first host-owned command slices: an explicit, persisted and versioned
root-relative `guestRoot` policy; canonical HFS path validation; capability,
one-page listing, and bounded exact-stat commands; typed receipts; and normal
host audit lines. It also has a create-only staged upload command: private
disk-aware reservation, ordered 8 KiB-or-smaller chunks, SHA-256 sealing, a
file-backed sender through the existing transfer lane, and bounded progress,
reservation, finalization, integrity, and cleanup evidence. No host path crosses
the API. The destination parent must already exist: this slice does not
implicitly implement `mkdir`. The existing private local socket and
client-launched stdio companion
project those completed commands; download, mkdir, overwrite, move, delete,
tree deployment, and prune remain unavailable.

The read-only slice composes the existing `file.list` exchange and therefore
adds no guest message or guest code. It is **tested** against fake paired
sessions, including root escape, invalid policy recovery, empty and populated
listings, paging bounds, stale sessions, concurrency, and host-product
noninterference, plus local-schema and stdio validation. A bounded
2026-07-24 PowerBook 1400c acceptance verified capability discovery, two
16-entry root pages with cursors 17 and 33, and exact stat. The first live
page exposed one legal HFS name containing control bytes; path validation now
keeps those exact MacRoman names addressable, rejects only untransportable
NUL, and escapes them in audit text. Download and every broader mutation remain
unverified and unavailable.

The staged-upload slice is **tested**, including host-space refusal, ordered
offsets, integrity failure cleanup, dead-process orphan recovery, root escape,
unavailable/stale sessions, replay, concurrent commit, malformed local/MCP
requests and MacBinary, strict guest completion evidence, late-collision
preservation, stale-accept invalidation, cleanup-needed recovery, guest refusal
evidence, and unchanged one-at-a-time transfer ownership. Host staging and
outbound reads use bounded off-UI-actor disk I/O. The host builds and the
Retro68 guest cross-builds cleanly. It is
**not metal-verified**: no new disposable upload was sent to the PowerBook in
this slice, so real-volume reservation values, Finder-visible finalization,
fork/type/creator fidelity, interruption cleanup, and live throughput remain
open.

The reconciliation also exposed two pre-metal hardening gaps. Host byte
reservation does not yet cap the number of active stages, so repeated
zero-byte or tiny begins can retain bounded-lifetime records without consuming
meaningful byte quota. A stage is bound to session and policy version but not
to an opaque active-share identity, so a human share change between begin and
commit is not yet a typed stale condition. Both must be resolved and tested
before staged upload advances to attended PowerBook acceptance.

Invalid persisted `guestRoot` recovery currently rejects the malformed value,
logs the event, and restores the approved share-root default. That is the
implemented and tested behavior, but it can broaden a future narrowed policy.
Fail-closed recovery versus explicit rebinding remains a policy decision before
an Integrations UI can configure narrower roots.

The reverse-streaming prerequisite is now integrated: the guest reads outbound
forks one bounded frame at a time, and the host receives into a private disk
sink with progress, length/CRC validation, interruption cleanup, and atomic
finalization. This does not expose arbitrary download. That capability remains
gated on a typed NOW command, root/size policy, deterministic receipts and
audit, and an explicit MCP projection. Reverse resume also remains separately
deferred pending a contract-first guest source-identity rule.

The combined V0.5 tree—root-scoped capability/list/stat, create-only staged
upload, and reverse streaming—has been reconciled and promoted to local
`main`. The read-only commands and reverse transport carry the bounded metal
evidence stated above; staged upload is implemented and tested but remains
unrun on the PowerBook. This integration did not add download, mkdir,
overwrite, move, delete, tree deployment, prune, broad host filesystem access,
plugin infrastructure, resume, or transfer-rate hardening.

Mutation is gated separately on guest-side revalidation of an opaque file
observation. Listings now carry a responder-generated opaque catalog identity,
and the host mints short-lived session/root-bound observation references, but
no mutation accepts them yet. The current move/Trash/restore/mkdir messages
still act by path alone; host-only precondition checks would permit a changed
item to be acted on between check and use. The exact guest-side revalidation
field and command behavior remain the next contract-first mutation gate. Tree
deployment and mandatory-preview manifest prune follow only after it.

## The companion against a partial guest: capability-derived, unverified on metal

NOW has two guests now, and the agent-integration companion was written
against one of them. It is now guest-agnostic — but only two of its
projections have ever been watched against a guest that implements part of
the contract, and neither of those was the new one.

**What changed.** A twelfth tool, `now_session_capabilities`, reports what
the connected guest can do and therefore which tools are available against
it. The derivation has exactly two sources and neither is identity:

- **Commands** come from `help`, which both guests serve on the wire, one
  fetch per connection. It is the same live source the host console's Tab
  completion already uses, so a guest that grows a verb becomes usable
  without a companion release.
- **Message families** are not in any command table — that gap is how `ps`
  shipped wire-only here — so they are established by asking. Every family
  request the host makes records its own outcome as it settles, and the
  report additionally probes the read-only families it can settle cheaply
  (`process.list`, `file.list`). It never probes a family whose smallest
  request changes the guest (`process.quit`, `file.put`), and it probes
  `software.list` only on request because that first page is a whole-volume
  sweep. Those stay **`unproven`**, a third state that explicitly does not
  mean "no" — collapsing it into "no" is how a report would start
  understating a machine it never asked.

`AgentIntegrationCapabilityTests` fails the build if any deciding file in
the companion surface reads a hello field or names a guest. That guard
exists because the same mistake already happened in the other direction:
`MetalQuitTests` derived a guest's abilities from its hello name and went
stale the same afternoon that guest grew `process.list`, understating its
own evidence with nothing failing.

**The refusal path, which was half-built.** `GuestListener.recordGuestError`
claimed to route a guest `error` to "every waiter" and routed three of the
six maps. Process listings, software listings and process results — exactly
what a partial guest refuses — still sat on their 15 s and 30 s watchdogs
and arrived with `timeout` instead of the guest's reason. All six are routed
now. The mutation that removed three of them reproduced the original
symptom: 15 s, 30 s and 15 s waits, each arriving as `timeout`.

That mutation also exposed a hazard in the first version of the fix: it
cleared the watchdog before routing, so a waiter kind the function forgot
would have had neither an answer nor a timeout and would have hung forever
rather than merely slowly. The watchdog is now cleared only when a waiter
was actually answered.

**What this does NOT change.** No safety property moved. Opaque
session-bound references, revalidation before use, one-use receipts,
create-only uploads, and the rule that no guest path or PSN crosses the
adapter are all as they were. In particular `now_request_quit` was **not**
made to work against a guest without `process.quit`: the opaque-reference
and PSN-revalidation model has nothing to stand on there, so the tool is
unavailable in typed form and that is the whole answer.

**Unverified.** All of it is **tested** here — twelve projections, 490 host
tests, both xcodebuild configurations — and none of it is
**metal-verified**. Specifically open:

- No capability report has been taken against the PowerBook 180c. The
  fake partial guest in the tests answers `not-implemented` the way
  `now-guest-68k/src/core/wire68.c` does, but a fake guest proves the host's half
  twice and the guest's half not at all.
- `now_list_processes` against NOW-68K is the tool this arc claims is newly
  possible, and it has not been called against that machine. The 68K's
  `process.listing` does carry PSNs, so references will be minted there —
  what happens when one is offered to `now_request_quit` and the guest
  refuses `process.quit` is tested against a fake and unobserved for real.
- The `help` command table parse is exercised against a synthetic table.
  Neither guest's real `help` output has been fed to the ledger.
- `software.list` probing is opt-in on the stated grounds that a guest which
  does not implement it refuses instantly. That asymmetry is reasoning, not
  a measurement; the ~4 s figure for a guest that does implement it comes
  from the earlier 1400c catalog sweeps, not from this code path.
- The local protocol moved to v6 and the capabilities call gets a 90 s
  response window because it may wait on several guest-side watchdogs in
  turn. That number is a sum of the existing bounds, not an observed one.

## NOW-68K: what has not been on the machine

The 68K guest for the PowerBook 180c is metal-proven for dial, handshake,
keepalive, health, logging, clean quit, `launch` and the `gone` path of
`quit`. Everything below has been built and cross-compiled and has never
run **on a Macintosh** — some of it now runs under host-compiled native
tests, which is a different and lesser thing, and each entry says which.
Listed because "we shipped it and here is what we still do not know" is
the useful half.

- **The interactive console is a SECOND WINDOW, by decision, and that is
  a standing exception rather than drift** (2026-07-25). Every other
  statement this project makes about guest UI says the opposite: the
  Carbon guest's rule is that a new feature is a Workshop module and
  never a window (`docs/adding-a-workshop-module.md`), `window.h` and
  this README both describe NOW-68K as one page with no tabs, and
  `now-guest-68k.r`'s `SIZE` comment agrees. Michelle asked for the console
  in its own window on this guest, and it is implemented that way.

  The reason it is defensible: the main window's console pane is a **log
  viewer** — it shows what the wire and the status line said, it takes no
  input, and this change leaves it exactly as it was. An interactive
  console needs a keyboard focus, an edit field, an insertion point and a
  key-by-key event path, and the one 512×300 page already carries three
  connection fields, two controls, a status line and a health readout.
  Making it carry both would mean shrinking the log viewer to a few rows
  or growing the window past the 180c's 640×480 panel.

  **The next feature is still a page on the main window** unless someone
  writes down a reason this good. `conwin.h`'s header comment carries the
  same paragraph so it is read by whoever edits the code, not only by
  whoever reads the ledger.

- **The console runs the command table, not a copy of it — and only the
  seam is tested** (2026-07-25). `commands68.c` used to run a command and
  emit its `command.result` JSON in one pass, which is fine with one
  reader and impossible with two. It now fills an `N68CmdResult` (the
  facts, no formatting) via `now68k_commands_run()`, and
  `now-guest-68k/src/commands/n68_cmdresult.c` holds **both** renderers side by side:
  JSON for the wire, text for the console. Adding a command means one
  case in `now68k_commands_run` and nothing else — it appears in both
  places in the same commit. This is deliberately aimed at the parent
  corpus finding `two-halves-never-met-in-a-test`.

  What is proven: `now-guest-68k/tests/test_cmdresult.c` (50 checks) pins the
  JSON bytes for all three reply shapes against literals written out in
  full — not assembled from the renderer's own pieces — and walks six
  outcomes through both renderers asserting they never disagree about the
  `ok` bit or the error code. `now-guest-shared/tests/console_history_test.c`
  (38 checks — it was `now-guest-68k/tests/test_history.c` until the
  history became one file both guests compile) covers the arrow-key
  history, including the two cases that are wrong in most first attempts:
  "nothing further that way" must leave the field alone rather than clear
  it, and a walk must not re-capture a recalled entry as the half-typed
  line. Both were wrong in the PowerPC guest's own copy, which is why
  there is now only one.

  **The wire did not change, and that was checked differentially rather
  than assumed.** A scratch harness ran the *old* `finish_error` /
  `finish_ok_row1` / `finish_ok_row2`, extracted verbatim from `4a7703f`,
  beside the new renderer over 1,092 combinations of reply shape ×
  message × error code × output capacity (512 down to 0, including the
  caps where the compact fallback fires): **0 differences**, in both the
  bytes and the returned length. The harness first reported 37, which was
  a real finding — the new `N68CmdResult` copies the message into a fixed
  160-byte member where the old builders took an unbounded pointer, so a
  message longer than 159 bytes now truncates instead of falling back.
  That case is structurally unreachable (`kDetailCap` is *defined as*
  `kN68CmdTextCap`, and every message source is one of those buffers),
  and it is written down in `n68_cmdresult.h` rather than left for
  someone to rediscover.

  What is **not** proven anywhere: that `launch` and `quit` behave the
  same when driven from the console as from the wire. Both paths call the
  same `now68k_commands_run`, which is the point of the design, but no
  test drives the console path (it needs a Toolbox) and no metal run has
  done it by hand. That is the first thing to check on the machine.

- **The console has never run on the PowerBook.** It builds under the 68K
  toolchain at `-O2 -Wall -Wextra -Werror` and its Toolbox-free halves
  pass their native tests; nothing more. Specifically unproven on metal:

  - **Up/Down history.** The interception happens before `TEKey` because
    TextEdit given `kUpArrowCharCode`/`kDownArrowCharCode` moves the
    insertion point between display lines, which is a no-op in a one-line
    field. That reading is verified-document (Events.h constants read
    from the installed Universal Interfaces: up 30, down 31), not
    verified-target.
  - **Left/right cursor movement**, which is deliberately handed to
    `TEKey` rather than reimplemented. Same evidence level.
  - **Option-Up/Option-Down scrollback.** `kPageUpCharCode` /
    `kPageDownCharCode` (11, 12) are also accepted, but the 180c's
    built-in keyboard has no dedicated page keys, so Option-arrow is the
    binding that has to work on the target and it has never been pressed
    there. Command-arrow was not available: `MenuKey` in `main.c`
    consumes every Command chord first.
  - **The two-window event routing.** `main.c` now routes update,
    activate, click and key events by the window they name rather than
    assuming one exists. A mistake here does not crash — it draws the
    wrong window or types into the wrong field — and nothing off-metal
    catches that.
  - **The memory cost — measured at link time, not on the machine.**
    Against `4a7703f` built the same way, the console and the seam it
    needed cost **text +4,428 and bss +10,954 = +15,382 bytes, +4.0% of
    the 384 KB partition** (`m68k-apple-macos-size` over the object
    files). The BSS is an 8.2 KB scrollback ring plus a 2.3 KB history,
    beside `window.c`'s existing 9,186 bytes. What that does NOT include,
    and what nobody has sized: the `WindowRecord` and the `TERec` plus
    its text Handle that the Toolbox allocates out of the application
    heap when the window is opened. With ~231 KB free that is very
    probably fine and it has not been watched.

- **The console cannot copy text out, and its scrollback is 32 lines.**
  The output pane is drawn text, not a `TERec`, so a click in it does
  nothing and there is no way to get a result off the machine except by
  reading it. The 32-line ring is `n68_console_ring.h`'s compile-time
  capacity, shared with the main window's log viewer; Option-arrow paging
  makes all 32 reachable, but a long `quit` transcript still ages out.
  Both are deliberate: a selectable output pane means a second `TERec`
  and its text Handle, and a deeper ring is 256 bytes a line.

- **The declined quit — METAL-VERIFIED 2026-07-25.** The whole re-list
  composition exists so a target that stops to ask about an unsaved
  document answers `ok:false` / `quit-declined` rather than claiming
  success, and it had never run anywhere. On the 180c, against a
  TeachText holding typed-but-unsaved text:
  `[quit-declined] quit: TeachText is still running - declined, or busy`.
  `MetalQuitTests :: testADirtyDocumentDeclinesAndSaysSo`
  (`NOW_QUIT_DIRTY=1 NOW_QUIT_NO_LAUNCH=1 NOW_QUIT_APP=TeachText`).

  Two things the run taught that the design had not:

  **`quit-ambiguous` also ran, by accident, and was right.** The test
  launches its victim before quitting it; against a TeachText a human had
  already opened, that produced a second copy, and `quit` refused the
  whole request rather than guess which one was meant. Correct behaviour,
  never previously exercised — and a test that manufactured the very
  ambiguity it then failed on. Hence `NOW_QUIT_NO_LAUNCH`.

  **The 68K re-check WAS weaker than the sentence "still running"
  suggests** — true when written, and fixed since by `process.list`. With no `process.list`, confirmation is a second `quit`
  through the same subsystem, and it came back "asked TeachText; not
  confirmed (wait_ticks <= 0)". The assertion that holds is only that the
  target did not answer `not-running`. That is real evidence and it is
  not corroboration; the run says so in its own output.
- **The farewell — METAL-VERIFIED 2026-07-25.** A menu quit on the 180c
  produced `now-68k is shutting down` on the host, which is the bye path;
  the abortive one reads `Connection lost`. `Metal68KTests
  :: testTheFarewellIsOrderly` (`NOW_68K_BYE=1`, human at the keyboard,
  because the guest refuses to quit itself).
- **The redial — METAL-VERIFIED 2026-07-25.** Host dropped mid-session
  and restarted; the guest redialled and re-helloed in 15.5 s.
  `Metal68KTests :: testTheGuestComesBackAfterTheHostGoesAway`
  (`NOW_68K_REDIAL=1`; the cadence is human-armed by design, so the
  checkbox is part of the test's precondition). The reconnect
  re-handshakes, as the contract requires.
- **Oversized control frames — now tested, still never sent.** The
  skip-not-fatal path (a frame larger than our 4 KB buffer but inside the
  protocol's 32 KB) is covered off-metal since 2026-07-25: the reader
  moved to `now-guest-68k/src/core/n68_reader.c` behind an ops table, and
  `now-guest-68k/tests/test_reader.c` drives it through a scripted transport —
  the oversized frame is skipped **and the next frame still parses**,
  which is the actual claim, under four chunkings plus a stall at every
  one of ~380 byte offsets. What that does not prove: **nothing in NOW
  has ever sent one.** The host does not produce a control frame over
  4 KB, so the reader's contract is proven and the host's honouring of it
  is not.
- **FIXED 2026-07-25 — `launch` of a name not on the disk never answered.**
  Watched broken on the 180c three times (60 s, 150 s, 300 s), then
  watched fixed on the same machine: `NOW-68K 0.6` answers in **2.5 s**
  with "nothing named X is on the startup volume". Kept in full below
  because the diagnosis was wrong twice before it was right, and the
  wrong turns are the reusable part.

  The cause was one limit stated three times in two units, smallest
  winning: the builder's buffer 512 (a literal in `wire68.c`), the
  module's documented floor 320 (`commands68.h` prose), the outbound slot
  160 (sized by a comment reading "hello (~110), ping (~30), or an error
  reply (~95)" — true when this guest had no commands, never revisited
  when `launch` and `quit` arrived). The reply built correctly at 166
  bytes; `commands68.c`'s compact fallback never fired, because from the
  builder's side nothing was wrong; the slot dropped it. Both numbers now
  come from `commands68.h` (`NOW68K_COMMAND_RESULT_CAP`), +704 bytes BSS.

  The original diagnosis, retained:

  What the guest's own log says: `cmd: launch refused -50`, then
  `command.result dropped, outbound queue full`. So the search RAN and
  RETURNED — `launch` is not hanging — and the reply was built and then
  thrown away on the way to the wire.

  Two theories died on the way to that, both worth keeping because each
  cost a metal run. **(1) The guest goes deaf inside `PBCatSearchSync`
  and writes its reply to a socket the host's idle timeout already
  killed.** Refuted: the metal test now watches the wire during the
  search, and it stayed up for the whole 150 s with keepalives answered —
  `yield_ticks(0)` pumps between slices exactly as intended. **(2) The
  reply is too long for the 160-byte outbound slot.** "Refuted" by
  reading `commands68.c`'s compact fallback — and this refutation was
  itself wrong, which is the lesson worth keeping. The fallback exists
  and would have fitted; it never ran, because the builder had 512 bytes
  and succeeded. Reading one half of a size mismatch and concluding the
  other half is fine is how the mismatch survived in the first place.

  What is actually established is narrower: `enqueue_control_send`
  refused the payload, and its 0 return covers **two** different failures
  — payload too big for a slot, and both slots busy
  (`kWireOutQueueDepth` is 2) — which every caller logged with the same
  sentence. That is why the log could not settle it. 0.5 logged them
  apart, and the very next run on the machine said it outright:
  `wire: send dropped - payload too big for a slot, bytes 166`.

  **The method note, which is the transferable part.** Two theories, two
  metal runs, both wrong, and the thing that ended it was not a better
  theory — it was making the log able to tell two causes apart. One
  message covering two failures is what turned a five-minute question
  into an hour, and the fix for that was three lines. When a log cannot
  distinguish the candidates, instrument before theorising again.

- **`launch` at scale.** The catalog search is double-bounded on purpose —
  a whole-volume Finder search has hard-wedged this fleet before — but it
  has only resolved an application sitting in an obvious place. The
  truncation branch is still unproven: the one metal attempt at it never
  got its answer back (above), so whether the bound reports honestly is
  exactly as unknown as it was this morning.
- **The confirm wait under load.** It yields with an event mask of zero and
  pumps the wire each pass, with a re-entrancy guard so a command arriving
  mid-wait cannot recurse into it. Neither the pump nor the guard has been
  observed under a second concurrent request.

- **`error` has a fixture and has still never been emitted.** (2026-07-25,
  closing the old "`hello`, `ping` and `error` are not conformance-checked"
  entry.) All three now have hand-written fixtures in
  `GuestWireFixtureTests`, derived by compiling the guest's own emitters
  with the host `cc` rather than by reading the C — a fixture written from
  the decoder's side would test one half twice. `hello` and `ping` have
  also run live against a real host. `error` has not, anywhere: reaching
  it needs the host to send a live-state message type NOW-68K does not
  handle, which nothing does today. The fixture is a claim about
  `send_error_reply`, not evidence from a capture. Its negative-id echo is
  reachable in principle and has never been observed.

  Worth correcting in the same breath, because it was written down wrong
  here: `unknown-command` and `refused` are **not** `error` shapes on this
  guest. `unknown-command` is a `command.result` error object and
  `refused` a `census.report` outcome; `wire68.c` routes both away from
  `send_error_reply` on purpose, because the wrong envelope leaves a
  different waiter blocked. The `error` emitter has one code,
  `not-implemented`, in two shapes. `command.result` is the one message
  still in the cannot-check set with no fixture at all.

- **Three oddities in the 68K frame reader, found and deliberately not
  fixed** (2026-07-25, during the extraction to `n68_reader.c`). The
  extraction was kept pure because the code is metal-proven and no
  PowerBook was on the LAN to re-verify a behaviour change against; these
  are the things a fix would have quietly changed. (1) `RS_HEADER` and
  `RS_BODY` return on a short read while `RS_SKIP` loops and calls `take`
  once more — harmless, one no-op call per drained bulk frame, and it is
  why `n68_reader_drain()` means "one event-loop pass" rather than "read
  everything available". (2) `handle_control_message`'s empty-frame branch
  is dead: the reader short-circuits zero-length control frames before
  dispatch, so there are two copies of that log string and one cannot
  fire. (3) `frames_in` counts skipped frames but not the fatal
  oversized one, so it means "frames whose header we accepted" rather than
  "frames received" — probably intended, but the stat's name does not say
  so.

- **The extraction is METAL-VERIFIED (2026-07-25).** It was
  argued-faithful only — structure, call order and a clean `-O2 -Werror`
  build — until `NOW-68K 0.4` ran on the 180c: handshake, one
  guest-driven keepalive answered after the 30 s silence, and a control
  frame round trip afterwards. `Metal68KTests
  :: testTheWireStillWorksAfterTheReaderExtraction`. The version bump is
  what makes it attributable — 0.3 predates the extraction and the wire
  carries no other way to tell two builds apart.

Both of the things that were known-wrong here are fixed (2026-07-25):

- **The metal gate no longer reads green when it never ran.** Under
  `NOW_METAL=1`, the port being held and no Mac dialling in are two
  distinct failures with distinct messages rather than skips; the only
  skips left are the opt-ins themselves (`NOW_METAL`, and `NOW_QUIT_DIRTY`
  for the case that needs a human at the keyboard). Guest identity now
  comes from the hello handshake, and where NOW-68K cannot serve the
  independent `process.list` confirmation the run says **WEAKER** out loud
  in its output and in every failure string. Watched directly: unset skips
  3 clean, `NOW_METAL=1` with nothing dialling in fails at 120.1 s, and a
  deliberately lying guest is caught on both the strong and the weak path.
  It is **tested**, not metal-verified — the guests were simulated by
  `tools/fakeguest.py`, which is a claim about the harness and never about
  a guest.

- **The contract's reconnect clause is amended.** Cadence is guest policy,
  capped backoff is the reference default, and the one surviving
  obligation is a ≥1 s floor between dial attempts. No revision bump:
  nothing changes shape and an older peer cannot tell. NOW-68K already
  clamped to the floor; the PowerPC guest reached it only incidentally
  through a prefs range check and now enforces it at the wire.

## vprobe on the 180c: measured, and what it does not cover

`vprobe` is **metal-verified** on the PB180c (2026-07-25, `NOW-68K 0.16`):
ran in 3.0 s, whole-frame on every row, answered in one frame, and the
wire survived it. Numbers and their reading:
[vram-readout-68k.md](vram-readout-68k.md).

The hypothesis it was built around resolved cleanly and in the direction
that costs us: `MOVEM.L` does **not** burst on this machine (6% over
unrolled `move.l`), and the reread row explains it — the VRAM is uncached,
and burst fills are cache-line fills. The unexpected result is a **~16-bit
width ceiling**: 8→16-bit more than doubles the rate, 16→32-bit buys 12%.
The 1400c's "the bus charges per transaction" does not transfer.

Unverified, and worth naming because the numbers will get quoted:

- **The CopyBits row is fifteen banded calls, not one blit.** Best raw
  beats it 1.54×, which is the opposite of the 1400c result — but an
  unknown share of that gap is per-call overhead. It is a floor on the
  margin, not the margin.
- **Nothing at a non-native depth was measured.** That is precisely where
  the 1400c's raw-vs-CopyBits margin evaporated, so the one number most
  likely to mislead a future capture stage is the one not taken.
- **`fmove.d` is content-dependent** — extended conversion, and a 68882
  handles denormals slowly — so it is what an FPU reader costs on that
  screen, not a bus figure.
- **`Microseconds()` has no availability gate.** Its trap is assumed
  present on 7.1 from documentation; a wrong availability test fails in
  the wrong direction (disabling vprobe where it works), so none was
  added. It answered with 37 µs resolution on the 180c, which settles the
  assumption for this machine and no other.
- **`fmovem.x` was not measured** — no conversion, no exception path, and
  the one row that might have rescued the FPU result. The reply cannot
  carry a 17th row; the honest next step if the `fmove.d` number ever
  looks wrong.

## The capture tx: staged, and crossing the wire on the emulator

Slice two — the pixels reaching the host — **works on the Quadra 800**
(OS 8.1, 640x480x8, 2026-07-26). The host sends `capture.request`, the
guest stages a PackBits capture, announces `capture.begin`, streams it
down the bulk lane and closes with `capture.end ok:true`; the host
decodes the palette and the packed rows into a pixel-accurate PNG of the
guest's screen. 137,783 bytes for a full frame, every byte accounted for
(`consumed 137783 of 137783`), 2.2:1 on that busy desktop. **Nothing has
run on the 180c**, and the emulator's `captureMs 16, encodeMs 3` are a
68040 reading host memory — meaningless as predictions, as ever.

Two ways to send exist now and they are not rivals:

- **staged** (`shotstage68.c`) — pack the whole frame to a scratch file in
  the published root, whose size is then an exact fact, and stream that
  file through the tested file source. Costs a disk round trip; buys
  compression. This is the one that crossed.
- **streaming** (`shotsrc68.c`) — read the framebuffer straight down the
  wire as `raw`, no staging and no scratch file, at ~300 KB. Built and
  native-tested; **not yet routed**, because the staged path answered
  `capture.request` first and one lane is one transfer wide.

The header of `n68_bytesrc.h` argues against staging ("cannot be staged
to a temporary file first either"). It was written before anyone had
measured a capture, and it is right about 300 KB and wrong about 65 KB.
That argument is now answered with numbers rather than overridden.

**PICT is not the wire format, and the contract said so first.**
`CaptureBegin.encoding` is `raw | packbits`, described as "NOT PICT: modern
macOS cannot decode QuickDraw pictures, so the wire uses a format both
sides own". So none of `shot68.c`'s picture machinery is on this path. The
stream is the palette as RGB triples, then rows top to bottom — which the
host already decodes, because the PowerPC guest already sends it. The
envelope is built field for field from `now-guest-ppc/src/core/wire.c`'s, and
`bytes` includes the palette (the contract's one-line description says
`rowBytes * height`; the sender that exists sends `GetHandleSize` of
palette-plus-rows, and the host agrees with the sender).

**The pull/push problem, which is why the source reads the screen and not
the picture.** `shot68.c` hands the whole frame to QuickDraw in ONE
`CopyBits` that runs for ~480 ms and cannot be suspended. `fill()` is a
pull. There is no way to pull from inside a call that is pushing — no
threads, no coroutines, and the banded recording that would have made it
incremental is the thing that killed QuickDraw on the third band. So the
source reads the framebuffer directly through the shared walk, which is
exactly what `raw` already is. PICT stays the disk format. The two paths
meet at the screen and nowhere else.

**This rung sends `raw`, and packbits is blocked on a real constraint,
not on effort.** `n68_bytesrc.h`'s first promise is that `total` is exact
before the first fill, because `capture.begin` carries the byte count and
the receiver sizes its staging from it. For raw that is arithmetic. For
packbits it is not knowable without packing, and this machine cannot hold
a packed frame to measure one:

- the packed frame is **not bounded**. The 180c's own desktop packs 4.7:1
  (65.6 KB), but PackBits *expands* incompressible data, so the worst case
  is ~303 KB against a 384 KB partition. "Usually fits" is not a budget.
- a counting pass then an emitting pass would produce an exact number for
  a screen that no longer exists. The two passes read the display at
  different moments, so their lengths can differ — and `capture.begin`
  would then be a lie the receiver sized its buffer from. Worse than
  sending more bytes.

So packbits over this lane needs **a decision, not code**: either stage
the packed frame in a temporary file (whose size IS exact — the 180c wrote
65 KB in ~800 ms, and `screenshot` already writes that file today), or a
contract that can carry a transfer of unknown length. Neither is taken
here. The cost of the rung that needs no argument is stated plainly: raw
is ~300 KB where packed would be ~65 KB on a quiet screen, and on this
machine's wire that difference is the whole user-visible experience.

**Two bugs the wire found that no test could have.** Both are recorded
because both are the same shape — a thing that is only wrong when two
real halves meet:

1. **The staged file was written where the sender does not look.** Staging
   put it beside the application; `n68_filesrc` reads from the published
   root (the Desktop). The capture staged perfectly, 137,760 bytes, and
   then could not be found. This is the *second* time this tree has made
   exactly this mistake — `n68_putfile.h` records the send and receive
   halves briefly disagreeing about the root, and says only a real file
   system can notice. `now68k_desktop_folder()` is the one place it is
   decided and now this uses it too.
2. **`capture.begin` announced `raw` while the payload was `packbits`.**
   The envelope builder was written for the streaming rung and hardcoded
   the word; the staged rung reused it. Every native test passed — they
   only ever built raw plans — and the guest sent 137,794 perfectly
   correct packed bytes under a label telling the host to read 307,968
   unpacked ones. The encoding is a parameter now, and a native test pins
   both spellings.

### RESOLVED: the 180c's wire capture arrived garbled — 24-bit addressing

Superseded by the entry at the top of this file, which carries the metal
evidence, the fix and what is still unverified. **The reasoning recorded
here was wrong and is kept because being wrong in this particular way cost
two passes.**

What was written here: the `StripAddress`/`SwapMMUMode` hypothesis "is
contradicted by this tree's own metal evidence", because `vprobe`'s
fidelity sweep reported MATCH (480 rows) at base `0xFC080000`, and because
that base "is only reachable with 32-bit addressing on", so the machine
must have been in 32-bit mode.

Both halves were true of the session they were measured in and neither
generalised. The 180c's **PRAM battery is dead**, so its Memory control
panel setting reverts to 24-bit on every power cycle; the vprobe run and
the garbled capture were in different machine states, three days apart.
Re-run beside `shotdiag`, the same sweep reported 480/480 rows DIFFERING.
The address does read like a 32-bit one because `GetPixBaseAddr` returns
what QuickDraw knows — QuickDraw is not the thing that truncates it, the
CPU is, at the moment of the dereference.

**The lesson worth keeping.** A measurement retired a hypothesis, and the
measurement did not carry the state it depended on. Everything raw this
tree measures on a 68K Mac is now reported beside its addressing mode for
that reason.

**What did change: the walk now has a gate.** The framebuffer walk was
the one part of the lane no test could reach — it sat between an `FSSpec`
and a `ShieldCursor`, and the only other reader of that memory (`vprobe`)
merely *times* it, so a wrong base reads at full speed and every number
stays green. `n68_shotwire_emit()` now owns the walk with no Toolbox in
it, `shotstage68.c` keeps the file, the cursor and the clock behind hooks,
and `test_shotemit.c` drives it over a synthetic framebuffer whose padding
is poisoned, decoding the result with the **host's** PackBits decoder
transcribed from `CaptureDecoder.swift` rather than this guest's own
unpacker. Both stride shapes are driven: 640-over-640 (the 180c, where a
stride bug is invisible) and 640-over-1024 (the Quadra, where it is not).
Mutation-verified — reintroducing the stride confusion fails the Quadra
shape and the poison check and leaves the 180c shape green, which is the
whole argument for testing both.

**What that gate does NOT prove.** It proves the arithmetic and the
encoding, over memory the host cc can allocate. It cannot say anything
about whether `sc.base` points at the 180c's framebuffer, which is the
open question. Tested, not metal-verified.

**What is left before metal.** Nothing structural — this is a deploy and
a run. Worth doing on the 180c specifically because every timing number
so far is an emulator's, and because the compression that makes this lane
worth having was 4.7:1 there against 2.2:1 here.

**One thing that already works and is worth knowing.** `screenshot`
followed by `put` gets pixels to the host *today*, using two shipped
verbs and no new code — as a PICT, which the host cannot render but can
store. That is a stopgap, not the lane.

## `screenshot` on NOW-68K: metal-verified, and what it measured

`screenshot` slice one is implemented on NOW-68K
(`shot68.c` / `n68_shot.c`, contract-declared already — nothing in
`contract/asyncapi.yaml` changed to add it). It captures the screen,
encodes a packed 8-bit PICT, writes it to the guest's own desktop as
`Screenshot YYYY-MM-DD HH.MM.SS` (type `PICT`, creator `ttxt`), and
returns the measurement rows. No pixels cross the wire; that is slice
two and belongs to the bulk-send work.

**Metal-verified on the PowerBook 180c** (System 7.1, 640x480x8, 4 MB,
2026-07-26) — deployed as a spike (`NOW-68K shot 0.14+shot`, its own
folder and its own dev-settings file so the current build's 5252 was never
touched), launched by asking the running build to `launch` it by path, and
driven over the wire on 5050. Three captures: one `--no-save` and two
saves. Both files landed on the guest's desktop with distinct names, and
one was pulled back over FTP and **decoded here** — 640x480, `pixelSize`
8, 256-entry colour table, and the 180c's own screen, correctly. The
capture ran inside the partition with room to spare (the guest reported
`free=489K max=179K` at the time; the capture's ceiling is ~21 KB).

**The numbers, which are the point of the slice:**

| | 180c (metal) | notes |
|---|---|---|
| read | 187–227 ms | matches vprobe's ~200 ms banded CopyBits |
| pack | 431–542 ms | **the unknown this slice existed to measure** |
| write | ~800 ms | 65 KB to the internal disk |
| output | 65,648–65,692 B | full 640x480x8 frame |
| ratio | **4.7:1** | |

**Packing costs about 2.4x the read, not 10x.** The worst case in
`shot68.c` was written assuming up to 10x and is therefore conservative by
a wide margin: a whole capture is ~1.5 s wall clock, against a ~65 s
death timer. And **4.7:1 on a real desktop means a frame is 65 KB**, not
300 — which is the number slice two turns on, and it is a far friendlier
number than the emulator's 2.2:1 suggested (the emulator's desktop was
busier; a real 180c desktop packs better).

**The 180c's clock is not set** — its PRAM battery is dead, and the 2020
capacitor/battery work is queued for that machine anyway. Both captures
were named `Screenshot 1904-01-01 23.49.0x`, the Mac epoch, which is what
`GetTime` returned. The naming code is doing the right thing with the
wrong input. What is worth keeping is that the per-second collision guard
is carrying more weight on this machine than it was written for: every
session after a restart starts near the same instant, so the tick-stamped
fallback — not the timestamp — is what keeps shots from overwriting each
other until that battery is replaced.

**Also verified on the Quadra 800 emulator** (OS 8.1, 640x480x8, 2026-07-25):
run from the guest's own console, three captures in one session
(`--no-save`, then two saves), the app survived all three, both files
landed with distinct names, and one of them was pulled off the disk image
with `hfsutils` and **decoded on the host** — 640x480, `pixelSize` 8, a
256-entry colour table, and pixel-for-pixel the screen at the moment of
the command with the cursor shielded out of it. That is the strongest
statement available short of hardware: the picture is not merely a file,
it is the right picture.

**The emulator settled nothing about TIME, and said so at the time.** It
reported `read 0 ms, pack 23 ms, write 8 ms` — a 68040 with a
host-memory framebuffer. Its 2.2:1 ratio also did not carry: the 180c's
own desktop packs to 4.7:1. Both were correctly labelled as proving the
code RUNS and produces the right picture, and nothing more; the metal run
is what produced numbers.

Still unverified, and named because these are the ones that will bite:

- **Only one screen has been captured, and it was quiet.** 4.7:1 is a
  desktop with two windows on it. A screen full of dithered photographic
  content will pack far worse, and nothing here establishes a floor.
- **The timing split is a difference of two passes.** `read_ms` is a real
  banded-CopyBits measurement (vprobe's, on vprobe's band); `encode_ms`
  is the recording pass minus the read minus the write, so it carries
  both passes' noise. On a machine where packing dominates that is fine;
  if the two ever land close together the number degrades to noise, and
  it is floored at zero rather than allowed to go negative.
- **8-bit only, by refusal.** A screen at any other depth is declined
  with a sentence naming the depth. `CopyBits` would convert for free but
  the 1400c showed a non-native path eats the whole margin
  (`vram-readout.md`), and nobody has measured that here.
- **The capture does not pump the wire.** Bounded by arithmetic at ~10 s
  worst case against the host's ~65 s death timer (`kShotWorstCaseMs`) —
  measured at ~1.5 s, so the bound is conservative by ~7x,
  deliberately, because a pumped event can move a window mid-recording
  and tear the picture. If a real 180c ever exceeds that bound the fix is
  to band the PUMP, not the picture.

One refactor rode along with this and is worth naming: **`vprobe`'s walk
to the framebuffer and its one-band GWorld moved out of `vprobe68.c` into
`screen68.c`**, unchanged, because `screenshot` needed the same three
answers and a second copy of a fail-closed geometry check is one copy
that falls behind. `vprobe` is metal-verified on the 180c; the moved
version is not, and the move was verbatim rather than a rewrite, but
"verbatim" is a claim about the diff and not about the machine.

### The banded recording that had to be abandoned — worth knowing

The first implementation recorded the picture **a band at a time** into a
640x32 offscreen port, which is the obvious way to bound memory and is
what the task was scoped around. On System 8.1 it **killed the
application on the third band, every time**, while QuickDraw was writing
that band's colour table. It was bisected on the emulator against the
guest's own log:

- not the file: `--no-save` (no `FSWrite` at all) died identically;
- not the geometry: removing `SetOrigin` and recording every band at the
  port's top died identically;
- not the partition: 2 MB instead of 384 KB died identically;
- not the put proc: it was entered correctly and had already streamed
  6.7 KB across two good bands, and the partial PICT recovered from the
  disk image decodes as two valid `PackBitsRect` opcodes.

The cure was to stop banding the *destination* at all, which the design
did not need: **a picture being recorded is never drawn into.** QuickDraw
diverts the bottleneck and hands the source pixels to the put proc, so
the destination port supplies only a coordinate space, a depth and a clip
— and the Window Manager's colour port is all three for free. One
recording `CopyBits` over the whole frame, one colour table instead of
fifteen, ~21 KB ceiling, and none of the above. The root cause inside
QuickDraw was never identified; if anyone reopens banded recording, that
is the thing to find first.

## The 180c, 2026-07-25 evening: everything automated is green

The display came back (a via that wiggled against its pad, found by
beeping continuity, reflowed). `NOW-68K 0.14` landed itself by handoff and
every automated gate passed against it: the reader extraction, `ps`, the
bounded `launch` search, the redial, the `error` refusal, the
oversized-frame skip with frame sync surviving, two overlapping requests,
and `quit`'s whole outcome table including the self-refusal.

**`quit`'s confirmation on this guest is now STRONG.** With
`process.list` served, a disappearance is re-checked against a different
code path instead of by re-asking `quit`. `MetalQuitTests` probes for the
capability rather than deriving it from the hello name, because deriving
it meant the file kept understating its own evidence the moment the guest
grew.

**Three defects were in the GATES, not the guest**, and the worst of them
had been reading green:

- The self-refusal case quit `now-guest-68k` — the CMake target name —
  while a deployed build runs as `NOW-68K 0.14`, its MacBinary name. It
  asked to quit a process that does not exist, got "nothing named that is
  running", asserted nothing, and passed. It had never once tested the
  behaviour it is named for.
- The harness raced its own teardown: `stop()` reports `.idle` while
  `NWListener` cancels asynchronously, so the next test in a suite bound a
  port its predecessor still held. Two of five failing while three passed
  against the same live guest is a race, not a busy port.
- The strength banner was printed before the capability probe ran, so it
  announced the strength assumed rather than the one measured.

Understating evidence is the same species of dishonesty as overstating it,
and it is harder to catch because nothing fails.

## The console, and what it is not verified to do

- **NOW-68K's interactive console is METAL-VERIFIED** (2026-07-25,
  evening). Watched by a human at the 180c after its display was
  repaired: `ps`, `help` (rendering the shared command table plus the
  console-local verbs), and **up/down history** — the last of which had
  never been observed anywhere, on metal or in an emulator, and was the
  feature the console was asked for.

  The two redraw bugs found in the q800 emulator earlier the same day
  were one cause: `draw_output` and `draw_input` drew without erasing
  first, and the Window Manager erases only what it newly exposes, so a
  rectangle the app invalidates itself keeps its old pixels. The command
  stayed on screen after Return looking unrun — inviting a second Return,
  which for `quit` or `launch` repeats a real action — and `clear`
  appeared broken while working perfectly. Neither was reachable by a
  native test; they are pixels.

- **The console pane cannot be copied out.** A click in the output pane
  does nothing on purpose: it is drawn text, not a TERec. Reading a long
  result means retyping it. Real gap, not a decision anyone would defend
  on its merits.

## Rough edges

**A console line reaching a guest older than `line` is misread, not
refused.** Such a guest ignores the field and runs the command bare, so
`ls Lab:Code` lists the share root and says nothing about the path it
dropped. The field is additive by the contract's own rules — an unknown
field is ignored — and this is the one place that politeness costs
honesty. Both guests in this tree read it; the exposure is an older
binary still sitting on a machine, which is a realistic state for the
PowerBook. Stated beside the field in `contract/asyncapi.yaml` rather
than only here.

**No `help`, no completion.** Tab completion is the guest's own answer,
so a guest that does not serve `help` has none — deliberately, because a
host-side fallback list is exactly what was removed. It does mean a shell
that offers nothing until the guest is updated, and `help` there answers
`unknown-command`, which reads as an error rather than as "this build is
old".

**Reverse streaming still needs longer and adversarial metal evidence.**
The PowerBook ladder now covers direct data-fork and MacBinary pulls
through 4 MiB plus cancellation. It does not yet cover a transfer longer
than two minutes, a file larger than 4 MiB, source mutation during a
pull, or direct guest free-heap measurement.

**The build stamp can read a few minutes early.** CMake touches
`build_stamp.c` at the END of a build, so the stamp reflects when that
file was last compiled rather than when the binary was linked. It has
already caused one "is this the build I think it is?" moment, and the
verification ritual depends on it. `touch now-guest-ppc/src/core/build_stamp.c`
before a build forces it current.

**The wire fixtures are transcribed by hand.** `GuestWireFixtureTests`
holds copies of the strings `wire.c` emits. `GuestWireConformanceTests`
reads the source directly and needs no maintenance, but it cannot
reconstruct the three messages built across several `snprintf` calls
(`file.listing`, `file.result`, `command.result`), which is why the
hand-written copies exist. They can drift.

**The browser stops at 128 rows** (`kMaxRows`) and says so in its status
line rather than paging further.

**No icons in the browser list.** `GetIconRef` is present on the machine
(the type/creator lookup a listing off the wire needs, since it has no
file to ask about) and `GetIconRefFromTypeInfo` is absent. Nothing uses
either yet; the list is text-only.
