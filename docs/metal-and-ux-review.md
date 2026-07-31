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

## 6. Platinum fidelity — deferred

Named here so it is not lost, but it belongs to the Mirror fold-in rather than
this slice. Whether the rendered desktop *looks* right is a human call and the
one thing no measurement replaces.

---

# Part two — metal test

## 7. The eleven capabilities that have never crossed a wire

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

**Two known hazards while doing this:**

- **`guest_file_mutation` has a 2-second local receive window against a
  20-second guest-side change watchdog.** A slow `PBCatMove` can time out
  locally on a call the machine then completes. If you see that, it is this,
  not the machine.
- **A pre-`file.begin` download cannot be cancelled on the wire at all.** The
  host frees its lane while the guest may keep sending, holding its own. That is
  the exact wedge `cancel` exists to prevent, and the app's own Cancel button
  has it too.

## 8. Guest consent, which has never met a machine

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

## 9. The fifth addressing case

`now-guest-not-addressed` means *connected but not driven*, which **one machine
cannot be**. It needs a second guest live on the same listener — a second real
Mac, or a QEMU guest dialling the same port. Everything else in that family is
already verified.

## 10. The agent audit line has never been read on a real run

Rule 3's whole point is that a person can see what an agent did. Drive one tool
against a real machine and then **read the line out of `~/Library/Logs/now-logs`
and out of the Agent module**. Nobody has done this end to end.

## 11. Two machine-specific facts worth confirming

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

**`capture.request` and the census families read `unproven` in the capability
ledger by construction**, because the listener records no observation for them.
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
