---
title: The surface as a foundation - Plan
type: feat
date: 2026-08-07
---

# The surface as a foundation — Plan

Successor to [018](2026-08-06-018-feat-stable-honest-render-plan.md),
which hardened the render and, on the way, found that the surface
underneath it was advertising far more than it served.

## Why this exists

On 2026-08-07 a lane sent to revive **seven** dead MCP tools found the
transport itself broken:

> `FileHandle.standardInput.readData(ofLength: 4096)` blocks until it has
> the full count or the pipe closes. A real MCP client holds stdio open
> and sends one small line at a time, so the loop sat on a 76-byte
> `initialize` waiting for 4020 bytes that never came — **all 41 tools,
> not seven.**

Measured: one small line with stdin open, no reply in ten seconds; the
same line padded to exactly 4096 bytes, answered immediately.

**It survived because every driver this binary ever had wrote its whole
script and closed stdin.** In the lane's words: *a pipeline that closes
the pipe is a batch, not a client.* So the MCP surface has never been
exercised the way a client uses it, and its tests could not see that,
because they all used it in the one mode that worked.

The same lane corrected the audit on a related point: `observe_elements`
did not exist on the agent socket **at all**, so the reassurance that
"it all works through `tools/now-agent`" was false — that tool speaks the
same socket. **The act plane's four addressed rows had no argument
producer on any face of this host from 2026-07-31 until today.**

## What this plan is for, beyond fixing bugs

Michelle, 2026-08-07, on where NOW is going:

> the file server and process host angle is what takes mirror from being
> really fucking cool to actually being useful and in alignment with what
> new old world is all about … i want to go out and build the file/proc
> server product. but i also dont want to let that orphan the actual
> mirror at "it kinda works but its kinda broken"

**That product is built on this surface.** Every capability a native
host-side Finder would need — files, processes, windows, acts — arrives
through these verbs. So the surface is no longer a developer
convenience; it is the foundation, and its defects are the product's
defects.

And most of what makes the Mirror "kinda broken" lives here rather than
in the renderer. Plan 018's defects were overwhelmingly **capture and
instrument**, not drawing: worlds born before arming, anchor
acquisition, an act plane that could not report its own effect, two
window readers returning different rectangles. A native Finder inherits
every one of them. **So this work funds both products at once**, which
is the argument against treating them as competitors for the same
effort.

### The principle that governs the native surface

Michelle, on whether a ported carbon-era Finder may improve on the
original:

> its allowed to be better, but only after its been made truly faithful

Read as a rule: **faithfulness is the gate, improvement is the reward.**
A surface may diverge from the machine only once it has been proven to
match it — because the faithful mode is what makes divergence
*measurable* rather than merely asserted. Improvement built on an
unfaithful base has nothing to be checked against, and the ability to
check is the property that has kept this project truthful.

Practically: any native reimplementation keeps a faithful mode, and that
mode stays gated against the machine, forever. Deliberate divergence is
a declared, tested departure from a known-good baseline — never a place
we ended up.

## Slices

### Slice 1 — A real client, against every tool

The transport bug is fixed; **the hole that hid it is not.** No gate
exercises the surface the way a client does, so a second transport
regression would be equally invisible.

- A conformance driver that behaves like a real MCP client — holds stdio
  open, sends one small line at a time, reads incrementally — and
  exercises **every** advertised tool, not a sample.
- Each tool's result classified: **served**, **refused with a reason**,
  or **failed**. A refusal with a reason is a pass; a silent failure or
  an "unavailable" from a healthy host is not.
- Run in CI-shaped conditions, so a tool that only works when a driver
  closes the pipe is caught immediately.

The known survivors of the first pass go in as fixtures: `now_text_get`
and `now_text_set` were proven reachable but a **completed text reading
has still never been taken through MCP**.

### Slice 2 — One implementation per question

The surface audit found the same question answered by different code in
several places, and the failure mode is not redundancy but
**disagreement**. Ranked by what a wrong answer costs:

- **F7 — `mirror_drive menuItem` skips the `titleLeft` identity check
  that `now_menu_act` requires.** That check was **earned by the 18/20
  hijack measurement**; skipping it means a driving agent can hit a
  different menu than the one it named. Safety, not tidiness. First.
- **F2 — two foreign window readers, two different rectangles**, already
  caught disagreeing on metal: `peek_read.c` returns the structure
  region, `axwalk.c` the content region, with separate offset tables and
  opposite failure policies. `windows[].rect` now has three derivations
  inside the scene plane alone. One reader returning both regions;
  failing that, publish `rectSource`.
- **F3 — five independent `GetNextProcess` walks**, with
  `modeOnlyBackground` classified in four copy-pasted places (one of
  which says so in a comment). Give the scene the process family's row
  with the anchor verdict as an extra column; that closes most of F5
  with it.
- **F6 — three fronting implementations making three different claims**
  about whether the switch happened.
- **F4** (two titles under one ref), **F5** (`observe` samples
  `GetFrontProcess` per row, so one reply can name two front processes),
  **F8** (`sw` live vs `software.list` cached), **F12** (eight
  hand-rolled frame codecs).

Rule for each: not "merge them" but **decide which answer is right and
make it the only one**. Where two paths must remain, publish which is
which, so a caller can tell.

### Slice 3 — Answers that survive the caller

Two defects the revival lane recorded rather than chased, both of which
bite an agent that behaves normally:

- **The anchor plane's lease lapses between calls.** A walk seconds
  after a `reveal` answered `bind: no-plane`, then `ok` on a later poll.
  **A caller that observes once will sometimes be told a bound process
  is unreachable** — an intermittent false negative, which is the worst
  kind because it teaches the caller to retry blindly.
- **Refusal vocabulary is inconsistent**: `now_text_set` carries
  `reach: notSent` where `now_text_get` carries `unknown`, for the same
  guest sentence about the same reference.

### Slice 4 — The surface says what it is

`docs/mcp-coverage.md` derives what a projection **declares**, and every
declaration was correct while seven tools were dead and 41 were
unreachable. That is not a bug in the file; it is the limit of what it
can see, and the limit should be stated in it.

- The coverage docs record **declared** versus **exercised**, and the
  conformance run from slice 1 is what fills the second column.
- Any capability with no path, or reachable only by a route that should
  not be normal, is named. The worked example is already in hand: no way
  to open the Mirror in a running host meant agents reached for macOS
  accessibility scripting, which then interrupted a person at her own
  desk. **A missing affordance became a documented bad habit.**

## What this plan does NOT do

- **The native file/proc server itself.** This is its foundation, not
  its first slice.
- **The render.** Plan 018 owns it; nothing here touches the ladder.
- **RE'ing the carbon-era Finder.** Named above only to record the rule
  that governs it.

## Rules carried from 018, because they were paid for

- **Drive it to prove it.** A green unit test proves the wiring, not the
  capability. The revival lane's standard is the bar: it did not claim
  `now_window_act` worked, it moved a window from (48,103) to exactly
  (60,120) and said so.
- **Gates must be structural, not enumerated.** A hand-kept list of what
  to check rots; the revival lane's forwarding gate derives both sets
  from source at test time and maintains no list.
- **A gate that cannot fail is not a gate.** Everything watched failing
  by mutation.
- **Derive, do not remember** — coverage numbers re-derived by running
  their own commands, and re-derived again at every merge.

---

# AMENDED 2026-08-07, after the accounting — the missing pieces, named

Appended, not edited: the body above is the record of what was planned,
and this is what an audit of the tree found was actually missing.

The authority for every claim here is
[`2026-08-07-020-accounting.md`](2026-08-07-020-accounting.md) and its
evidence file
[`2026-08-07-020-accounting-evidence.md`](2026-08-07-020-accounting-evidence.md).
Where a lane's report and those two disagree, **those two win** — that is
the whole reason they were derived from the tree rather than from
reports.

## The decision that was undecided is now made

**Charcoal: keep substituting Chicago, and DECLARE it.** Michelle,
2026-08-07: *"our fonts are ok at this stage, im happy enough with
them"*.

This is the one item the accounting classed as **dishonest-by-default**
rather than incomplete, and the distinction is the point. Charcoal ships
TrueType-only — no `bdat`/`bloc`, no NFNT strike — so we substitute
Chicago and mis-measure width. Substituting is now an accepted product
decision. **Saying nothing about it is not.**

So this slice is not a font slice. It is an honesty slice, and it is
done when a person reading a render can tell that a glyph is ours rather
than the machine's. A silent substitution is precisely the failure this
arc names everywhere else: a render drifting toward *plausible* rather
than *true*, each drift individually defensible.

## Why this list is ordered the way it is

The accounting's own verdict on the highest-value unfinished thing:
**authoritative control semantics for OS 9's own panels.** Everything
else in the arc changes how well the product is *described*; that one
changes what it can *do*, and it funds the native file/proc server too.
It goes first.

Second is the instrument, because an instrument that cannot see the
defect makes every measurement after it worthless — and this arc has now
paid for that eight separate times.

### Slice A — finish the CDEF route (Memory's radios)

`018-cdef-classify` reached **71 of 73** for Appearance and stops one
step short. Memory's radios come back **CDEF 0, variant 0** and draw as
bare labels.

`GetControlKind` is Mac OS X only; `GetControlData(kControlKindTag)`
answered 2 of 73 for Appearance and **0 of 21** for Date & Time. The
`GetResInfo`-against-`contrlDefProc` route is the one that works on OS 9
and it is already wired into the live walk. This finishes it.

**A control whose kind cannot be established stays `unknown`. It is
never inferred** — that rule does not bend for the last two.

### Slice B — the instrument must arm the plane it photographs

`tools/local-pair-capture.py` never issues `qdtrace start`, so every
`display` it captures is nil by construction and every window hatches.
Its warm-up comment claims the planes arm "as a RESULT" of a scene walk,
true of P1/P2/P4 and false of P3.

**Blast radius, corrected:** `fidelity-sweep.py` *does* arm (line 220),
so Sweeps A/B and round 5's LOOK stand. Only drive-loop observations are
artefactual.

Includes the pass nobody has taken: **attribute the existing hatching
findings to their instrument.** The accounting names this as the largest
thing it could not determine, and it is one pass away.

### Slice C — one interior at a time is a design decision, not a defect

`qdtrace start` takes ONE window. Three windows means three arms, three
censuses (~57 ms each) and three TTLs. **At best one interior can exist
at a time** without a contract change.

A screenshot with one live interior and the rest hatched may be the
product working exactly as built. Decide whether that is the product, and
if not, the contract changes first.

### Slice D — slice 9's live verb is wired into nothing

Guest-side `GetTheme`/`kThemeDesktopPatternTag` exists; the contract
carries a `desktop` gestalt verb; **`hasPattern` / `patternCarried` /
`patternBytes` return zero matches** across `now-host` and `mirror`. The
renderer reads only the offline asset-pack manifest — true solely for a
guest booted from that stage image and unchanged since.

Two producers of one answer, one of them unread. That is a seam by the
sweep spec's own definition.

### Slice E — slice 14's lazy delivery was never begun

Cap moved 48 → 96 and chain length is now reported. **Lazy delivery does
not exist**: no `notFetched`, no generation stamp, no contract field.
The pool sizing measurement was blocked behind the anchor plane, which
has since been fixed — so the measurement is now takeable.

`displayEpoch` is the precedent for the generation stamp; it is slice 1's
pattern applied to controls.

### Slice F — landed capabilities with nothing pinning them

`LiveMirror.cursor(for:)` has **no test coverage at all**. Carries the
Charcoal declaration above, and any other capability the accounting
found landed-without-a-test.

### Slice G — `arc-status` measures the corpus in the wrong tree

`tools/arc-status:174` reads the parent's working directory, which sits
on `main`, and reported *"nothing graduated to the corpus in 21h"* while
**26 findings sat on `claude/018-findings` across 7 commits.**

A real worry with a wrong shape — and a tool that reports arc state
being wrong about arc state is the same class of defect as the
instrument in slice B. Fix the measurement; keep the warning.

## Two things reserved for Michelle, not dispatched

- **`019-embed-mirror` did not wait for a pick.** Six candidate PNGs at
  03:23; at 03:34 it implemented a *fourth* shape. There is no record of
  a choice being made, and round 5 now calls it *"the accepted one"* — a
  reserved decision that has quietly read as resolved ever since.
- **Nothing in this arc is metal-verified.** Across all 975 commit
  bodies, every "metal-verified" hit is a negation or a correction. That
  is honest and it is also the gap between where this stands and where it
  is going.
