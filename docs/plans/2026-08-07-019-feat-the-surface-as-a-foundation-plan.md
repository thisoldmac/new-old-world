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
