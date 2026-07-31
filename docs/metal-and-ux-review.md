# The review this slice is waiting on

Everything built between 2026-07-29 and 2026-07-31 is **tested and not
metal-verified**, with two exceptions noted below. This file is the list of what
a person has to do to change that, and it exists because the alternative is
twenty agent reports and nobody's memory.

Two audiences, one pass:

- **UX review** — a person looks at something and judges it. No measurement
  substitutes.
- **Metal test** — an agent or a suite drives a real Macintosh and something
  either happens or does not.

Read [68k-metal-runbook.md](68k-metal-runbook.md) before any metal work. Its
rules are not ceremony: they were written after a run nobody could attribute.

## Three questions that are one experiment

Added 2026-07-31, once it became clear they had converged. Three separate pieces
of this slice each owe **a number from the same machine**, and none of them is a
yes/no:

| # | The question | What the answer decides |
|---|---|---|
| 12 | Does a process's `LMGetCurStackBase()` fall inside its partition? | If not, **every** process reports `MISMATCH` and the Windows row reads "stale anchor" everywhere — a silent, total, *polite* refusal rather than a fault |
| 8 | Is a frame off an open bracket cheaper than a 0.5–0.6 s capture? | The streaming row's entire premise. If it is not clearly cheaper, the row's reason for existing is wrong and should be reported as such |
| — | What does a **semantic scene walk** cost on the 1400c? | Whether Mirror scenes reuse the bracket or stay one-shot ([streaming-a-scene.md](streaming-a-scene.md)). Above roughly 200 ms the bracket earns its keep |

They want the same setup — one machine, one connected session, a stopwatch on
the wire — so running them separately would be three setups for one afternoon's
answers. **The whole slice is being held for a single unified pass** rather than
verified piecemeal, which is also why nothing below has been struck off yet.

## Before anything

**Ask before each pass.** Per-action, not per-session. The machines are shared
with other agent sessions and with your own work.

**The environment**, proven on 2026-07-29 against the PB1400c:

```
NOW_METAL=1 NOW_METAL_PORT=5251 NOW_METAL_MACHINE=<addr>
```

- The guest dials out on a **30-second retry**, so budget half a minute before
  reading a quiet listener as a failure.
- **One `swift test` at a time on this Mac.** `HostAppStateWiringTests` binds a
  fixed port 52981; `HostLogTests` and `LoggingSpecTests` share
  `~/Library/Logs/now-logs`. Exactly those three failing means contention, not
  a defect.
- **Do not trust the version string to tell you which build answered.**
  `PRODUCT_VERSION` is `"0.1.0"` in current source *and* was on the stale build
  deployed to the 1400c. That cost a wrong diagnosis on 2026-07-29. `hello` now
  carries a build stamp; use it, and assert a capability only the build under
  test has.

## Already metal-verified — do not redo

| Thing | When | Evidence |
|---|---|---|
| `now_capture_screen`, end to end | 2026-07-29, PB1400c | 800×600, 4–5 pages of 8 KiB, whole call 0.5–0.6 s, digest chain proven by flipping a page byte |
| Addressing: answered / not-connected / session-ended / unaddressed | 2026-07-29, PB1400c | `MetalAddressingTests` |

Everything else below is unexercised.

---

# Part one — UX review

These need eyes. None of them has been looked at by a person.

## 1. The Agent module's resting state

**The single most important thing in this document.** On most machines, for most
of their lives, no companion has ever attached — so this is the sentence the
pane spends its existence saying, and it is the state most likely to read as
*broken* rather than as *idle*.

Open **Agent** in the sidebar on a host that has never run a companion. It
should say `No agent has attached`, explain that nothing is driving this Mac but
you, say there is nothing to switch on, and describe what *would* appear here.
It should show **no counters at all** — deliberately, because "0 companions,
0 calls, last seen never" is the visual shape of a thing that failed to load.

Judge: does it read as *nothing has happened yet*, or as *something is wrong*?

Then, if a companion has ever run: does presence decay honestly from active to
idle **while you watch and do nothing**? It re-derives on a 5-second tick
because that transition has no event behind it.

## 2. The guest's icon on a real Finder

`now-icons.r` is adopted by the PPC guest. Everything asserted about it is
arithmetic on a resource fork — nobody has *seen* it.

Look at it in: the Finder's icon view, its list view (16×16), the application
menu, and the ⌘-Tab switcher. On a 1-bit or 4-bit display if you can reach one.

The pack's own README says the **1-bit checker** is the one whose read depends
on the actual display, and that an emulator screenshot does not fully stand in.

## 3. The menu bar glyph

Five states — empty, dot, half filled, filled, filled behind a bang — as an
18 pt template glyph.

Check it on a **light and a dark** menu bar, and **with the menu open** (macOS
inverts templates then). Check that the states are distinguishable at a glance
at real size, which is the only size that matters.

Also worth confirming: rename or remove the asset and the old text should come
back rather than the item disappearing.

## 4. The Diagnostics module

Three probes with different ISA availability — `vprobe` both, `shotdiag` 68K
only, `putstat` PPC only. Judge what a card says when the connected machine does
**not** serve that probe: it must not imply the machine is broken, and it must
not present a button that silently does nothing.

## 5. The Files page's new verbs

Move, trash, restore, mkdir, and download. The confirmation sheet and the
fifty-deep Undo are the human half of a destructive capability an agent can also
reach. Judge whether the wording makes it clear what will happen and to what.

## 5a. The Software page's sweep budget and its duplicate groups

Added 2026-07-31. The page used to re-run the guest's whole Applications sweep
every time it was opened, and again on every domain-picker flip. It now sweeps
**once per machine per domain per connection**, and the only thing that re-asks
a domain the Mac has already answered is the **Rescan** button. Duplicates
gather under a container row, by the guest's own `compute_groups` rule.

Tested on the host only — a scripted guest over loopback. **Nothing here has
met a real Mac**, and three of the four things worth judging are things a build
cannot answer:

- **Is once-per-connection the right budget on real hardware?** The saving is
  real (a ~4 s disk crawl per open, on a machine doing nothing else while it
  runs), but a listing now survives every visit to the page for the life of the
  connection. If a person installs something on the guest and comes back, the
  page is wrong until they press Rescan. Judge whether the footer's "as of
  14:02:11 (23 minutes ago)" is enough of a prompt, or whether the page should
  volunteer a rescan past some age.
- **Does the age phrase read as stale, or as broken?** The relative age is
  computed as the page draws, so it sharpens on the next interaction rather
  than ticking. Sitting on the page for ten minutes shows an age that does not
  move. The absolute time beside it is always right; the question is whether
  the frozen phrase reads as a bug.
- **The disclosure triangle is hand-drawn.** `Table` cannot draw a real outline
  before macOS 14 and this app ships to 13, so a group's chevron is a plain
  button in the Name cell and members are indented by a spacer. On a real disk
  with several SimpleTexts, judge whether it reads as an outline or as a row
  with a stray button — and whether clicking the chevron feels like disclosure
  when the row deliberately refuses to select (the guest refuses too).
- **The two surfaces have never been compared side by side.** The grouping rule
  is ported from the guest's source and pinned by tests, but nobody has put the
  host's Software page and the guest's Workshop Software page next to each
  other on the same disk and checked that they gather the same items into the
  same groups. That comparison is the only thing that proves the port, and it
  needs one real Mac with real duplicates on it.

One known divergence, stated rather than smoothed over: two names differing
only in the case of a **non-ASCII** Mac Roman letter (`é`/`É`) may group on the
guest and not here. Both surfaces sort under an ASCII fold, which does not
bring such a pair adjacent, so the guest only groups them when nothing sorts
between them. Not expected to occur on a real disk; worth a glance if one ever
does.

## 6. Contention, which nobody has ever seen happen

Added 2026-07-31 with `now_stream_screen`. **Two sentences a person reads only
when an agent is doing something to their Mac**, and neither has been in front
of anybody.

Drive it: open **Screenshots**, then have an agent call `now_stream_screen`
with `intention: start` while you watch.

- The live view turns on **without you clicking anything**, the Capture button
  greys out, and a line under the buttons should say an agent is streaming and
  that Stop Streaming ends it. Judge whether that reads as *somebody else is
  using this* or as *the app has done something odd*. Before the line existed,
  this state was indistinguishable from a fault.
- **Stop Streaming should end it**, and that is the whole of the person-wins
  decision: it is one explicit click, and Capture was deliberately NOT made to
  end an agent's stream as a side effect of being pressed. Judge whether one
  click is enough, or whether being unable to just take a screenshot is
  annoying enough to want the other design.
- The **Agent** page should carry the same fact as a standing state — an
  orange card naming the held lane — for someone who came to that page to ask
  what an agent is doing. Judge whether the two sentences say the same thing
  in the two places without contradicting each other.

Then the reverse: start a stream yourself and have an agent call `start`. It
should be refused with a sentence naming *you*, not a bare "busy". You cannot
see that one — it goes to the agent — but the wording is worth reading in the
tool's answer.

## 7. Platinum fidelity — deferred

Named here so it is not lost, but it belongs to the Mirror fold-in rather than
this slice. Whether the rendered desktop *looks* right is a human call and the
one thing no measurement replaces.

---

# Part two — metal test

## 8. The eleven capabilities that have never crossed a wire

**Exactly one capability has met a Macintosh: capture.** Addressing is verified
too, but addressing is a property of every call rather than a capability of its
own. Everything else in the twelve is unrun — including the three diagnostics
rows, which an earlier draft of this file left out of its own count.

Note the axis, because two documents look like they disagree and do not: a
**guest verb** being metal-verified is not its **host projection row** being
metal-verified. `vprobe` has run on the 180c; `now_framebuffer_probe` has never
crossed a wire. The verb is the machine's; the row is the surface's.

| Capability | Watch for |
|---|---|
| `now_hardware_census` | fourteen probes, both guests. A probe's own outcome must stay distinct from the call's — `absent` on a pre-PCI Mac is a **completed call carrying a finding**, not a failure |
| `now_machine_facts` | PPC only. Every group in one call, in the contract's order, snapshot first |
| `now_software_inventory` | the `apps` sweep is ~4 s. The 48-item ceiling and the `PBCatSearch` root-only fallback must reach you in the guest's own `note` |
| `now_catalog_search` | ~20 s per pass, and the second pass rides the first's cache. The 16-row bound is the guest's own |
| `now_guest_log_tail` | **the count travels on `line`, not `args`** — see the defect note below |
| `now_bring_to_front` | does a real switch land inside one round trip (`fronted`) or usually read `unconfirmed`? That number decides whether the answer is useful or merely honest |
| `now_reveal_item` | reports `asked`, never `revealed`. Confirm the Finder actually comes forward — the host cannot tell you |
| `now_guest_files_download` | 4 MiB ceiling refused *before* the wire, re-checked on arrival |
| `now_guest_files_mutate` | the `PBCatMove` rename-first path on a real volume; a Trash that must be created; whether `trashedAs` comes back |
| `now_transfer_cancel` | cancelling nothing must answer, not error |
| `now_framebuffer_probe` | both guests. The verb is metal-verified; this row is not |
| `now_capture_diagnostics` | 68K only — so the 180c, not the 1400c |
| `now_transfer_diagnostics` | PPC only. Three rows rather than one because these three do not co-occur on any guest, which is the thing to confirm on metal: each machine offers exactly the ones it serves |
| `now_stream_screen` | PPC only, and the one row whose metal question is not "does it work" — see below |

**`now_stream_screen` needs its own paragraph, because the question is a
number rather than a yes.** The row is built on the assumption that a frame
off an open bracket is *cheaper than a capture* — a capture measured 0.5–0.6 s
on the 1400c, and a stream has the machine capturing continuously, so a frame
should be waiting rather than starting. Nothing has measured that. Ask for
`intention: frame` several times over an open bracket and record the wall
time; if it is not clearly under a capture's, **the row's whole reason for
existing is wrong** and it should be reported as such rather than shipped as a
capability with an unmeasured premise.

Three more things only metal answers here:

- **What one frame costs the machine at the default 1000 ms pace**, in wire
  bytes and in how much slower everything else on that Mac gets. The default
  was chosen by argument, not measurement.
- **Whether `stream.refresh` actually produces a whole frame promptly** on a
  real 603e, or whether the guest's self-pacing makes the wait longer than the
  capture it replaces.
- **That the bracket ends.** Open one, kill the companion process, and confirm
  the PowerBook stops capturing within about five seconds — the liveness half
  of the ownership rule has only ever been exercised against an injected
  predicate. The lease half needs a minute of doing nothing and is the more
  likely of the two to be wrong in practice.

**Two known hazards while doing this:**

- **`guest_file_mutation` has a 2-second local receive window against a
  20-second guest-side change watchdog.** A slow `PBCatMove` can time out
  locally on a call the machine then completes. If you see that, it is this,
  not the machine.
- **A pre-`file.begin` download cannot be cancelled on the wire at all.** The
  host frees its lane while the guest may keep sending, holding its own. That is
  the exact wedge `cancel` exists to prevent, and the app's own Cancel button
  has it too.

## 9. Guest consent, which has never met a machine

The PPC guest sends a hardcoded `full` from `now_agent_access()`. To test the
ceiling you need a build that answers otherwise.

- `disabled` → every tool refused, as a JSON-RPC error with code `-32010`, not
  as a capability being unavailable. **A caller must be able to tell those
  apart** — that distinction is the whole design.
- `read-only` → read rows allowed, the rest refused.
- An unrecognised token → everything refused.
- Silence → everything allowed (a recorded decision, revisited when the
  installer lands).

Confirm a refusal **emits an audit event** and appears in the Agent module.

## 10. The fifth addressing case

`now-guest-not-addressed` means *connected but not driven*, which **one machine
cannot be**. It needs a second guest live on the same listener — a second real
Mac, or a QEMU guest dialling the same port. Everything else in that family is
already verified.

## 11. The agent audit line has never been read on a real run

Rule 3's whole point is that a person can see what an agent did. Drive one tool
against a real machine and then **read the line out of `~/Library/Logs/now-logs`
and out of the Agent module**. Nobody has done this end to end.

## 12. The anchor oracle's one unmeasured assumption

Added 2026-07-31 with the oracle (M1b). This is the highest-value single
observation in the metal half, because it is the one place in this slice where a
wrong guess degrades *silently into a refusal* rather than into an error.

The oracle decides an anchor slot is this process's by checking two roots
against the partition: `a5` and the new `stack_base`. The A5 half is unchanged
and proven. The stack-base half rests on one claim nothing here has measured:
**that `LMGetCurStackBase()` for a process falls inside `[processLocation,
processLocation + processSize]`**, the stack growing down from the top.

If that is wrong on real hardware, **every process reports Mismatch and the
Windows row reads "stale anchor" for all of them** — the feature does not error,
it politely declines, everywhere.

**What to do:** open the Processes module, select several apps in turn — a
foreground app, a background one, the Finder — and read the Windows row.

| What you see | What it means |
| --- | --- |
| Counts and titles, as before | The assumption holds. Say so; it becomes a measurement. |
| "stale anchor" on **every** process | The geometry claim is wrong. Not a crash — a false refusal. |
| "stale anchor" on **some** | More interesting than either: the check is working and those slots are genuinely debris. |
| "unclear (two matches)" | Two slots survived both checks. Worth capturing which app, since it is the case the oracle was written for and nobody has seen one. |

The check was written **loose on purpose** — it rejects only addresses outside
the partition entirely, and accepts `loc+size` exactly, because that is the
normal value and the strict readability test would reject it. Tightening it
(that the stack base sits above A5, say) wants this observation first; until
then it stays out as a phantom constraint.

## 13. Two machine-specific facts worth confirming

- **`vprobe` reported `CopyBits failed` on the 1400c**, and that failure does
  **not** reproduce through `capture.request` — two clean captures. The paths
  differ. Do not let one be read as evidence about the other.
- The 68K guest's `NOW68K_APP_VERSION` is hand-bumped with no build stamp, so
  on that machine you still cannot tell two builds apart.

---

# Part three — what a green pass would not prove

Stated so a clean run is not over-read.

**Six source-scanning gates were found not to prove what they claimed**
([source-text-gates.md](source-text-gates.md)) — including one where deleting a
view's Refresh button leaves the face-parity gate green, and one where an audit
sink that records nothing passes. Those are fixed or documented, but the lesson
generalises: **mutation-proving is only as strong as the mutation someone
thought to try**, and an author testing their own gate is the worst-placed
person to imagine the one that defeats it.

**The stream row's ownership rule has never met a real companion.** Both
halves are mutation-proven against injected values: the liveness check against
a set of pids a test controls, the lease against a clock a test moves. What
neither proves is that a real MCP companion's pid behaves the way the design
assumes — that it outlives a single call and dies with its client. If that
assumption is wrong, the liveness half is dead weight and the lease is doing
all the work. Section 8 says how to find out.

**`capture.request`, the census families and the three stream families read
`unproven` in the capability ledger by construction**, because the listener records no observation for them.
A guest that has served a capture will still report it unproven. That is honest
and it is not evidence of a problem.

**The Agent module's audit stream is per-launch and in memory.** The log
persists; the pane does not. Someone looking for last week's activity needs the
log.

## Recording what you find

A metal measurement is recorded rather than narrated — `NOWBASE` lines carry
build, machine and port beside every number
([68k-metal-baseline.md](68k-metal-baseline.md)). A UX judgement belongs in
[open-issues.md](open-issues.md) under *unverified* becoming *verified*, or as
its own entry when the answer is "this reads wrong".

And per AGENTS.md: **builds / tested / metal-verified**, and never "works" for
the first two.
