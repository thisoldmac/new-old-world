---
title: Live composition in the Mirror - Plan
type: feat
date: 2026-08-06
---

# Live composition in the Mirror — Plan

Successor to [014](2026-08-06-014-feat-worlds-hooked-at-birth-plan.md)
(complete: worlds hook at birth, the join nests, the mechanism runs in
record mode). Subordinate to [001](2026-08-03-001-now-mirror-ux-completion-plan.md).
The composition rule this integrates against is
[docs/render-composition.md](../render-composition.md); where this plan
and [open-issues.md](../open-issues.md) disagree, the ledger is right.

## Why this exists

Every mechanism is now proven separately and none of it is USABLE yet:
the live Mirror still shows a hatch for most interiors, because the
pieces meet only in test fixtures. The gap between "proven on captures"
and "a person opens the Mirror and window interiors are simply there"
is this plan. It is written while a sibling thread
(`mirror-build-out`) churns on perf and cadence, so every seam with
that work is named explicitly rather than discovered by collision.

## What is already true, so integration starts from facts

- The resident hooks every world at creation in RECORD mode (014,
  graduated), emits `worldborn`/`worlddied`/`blitsrc`, and the host
  join nests. **Watched working only via wire harnesses; never through
  the live app.**
- The live app's content plane already arms the front window in record
  mode per scene cycle and retains composed displays as expected-stale
  across retargets. So the FLOW exists; what fails is pacing and
  verification.
- Measured, on Sherlock under active repaint: ~12 KB/s into a 64 KiB
  ring (~5 s of headroom), against one drain per ~2.2 s structural
  cycle — fine when idle, loss under load (`lostBytes` 114018 and
  343204 on the two E3 runs).
- Two late findings were VOID for want of a build-under-test assertion
  in the harnesses. Nothing in this plan may be verified through a
  harness that cannot say who answered.

## The slices

### G0 — the harness says who answered (precondition, small)

`tools/gwprobe.py` and any driver used for verification gain the
`requireTheBuildUnderTest()` equivalent: `--expect-build` compared
against the guest hello's build stamp, refusing to proceed on mismatch,
with the expected stamp read from the build products rather than typed.
The void-findings entry is the reason; AGENTS.md's metal-gate rule is
the precedent. Nothing else in this plan is believable until this
exists.

### G1 — the drain keeps up while armed (the perf seam)

The content plane gets its own bounded drain pacing while armed, so the
ring stops being the limit:

- The **scene cycle stays the cadence owner** for arming, retargeting
  and publishing — that is the sibling thread's territory and this plan
  does not move it.
- Between cycles, while the armed window's application is front, the
  plane runs a small drain loop (start ~300 ms, tuned by the measured
  12 KB/s) that only chases the cursor; records accumulate exactly as
  today and still publish on the structural cycle. One knob, stated in
  one place.
- The ring itself stays 64 KiB for now: growing it costs system-heap
  bytes on metal 68K machines that cannot spare them, and the measured
  rate says pacing is sufficient. If a future application beats the
  paced drain, the ring decision reopens WITH numbers.

Seam risk: the sibling thread is reworking cycle cost and deltas. The
integration point is deliberately additive — a timer the content plane
owns, not a change to the cycle — and lands AFTER the next merge from
that thread, not before.

### G2 — watched working, through the live app

Not a harness: the actual host application, against a VM booted on a
verified-free port with a build-stamp check, showing a Finder window
and Sherlock composed in the Mirror while a screendump of the guest
sits beside the render. "The two halves never met in a test" is this
project's costliest defect class; the live app and the graduated
resident have not yet met at all. Render-screenshot for the record;
Michelle judges fidelity.

### G3 — the panels' values (the Appearance question)

Date & Time and Memory compose their structure and none of their
values; the values are drawn by CopyBits, plausibly into worlds
AppearanceLib itself creates. One clean re-run (G0 discipline) answers
whether the graduated resident already catches them. If yes: the
panels' data crosses and the placeholder story finishes itself. If no:
the values live in a path the bottlenecks cannot see, and the honest
render stays a plate until someone measures where the text goes —
named, not assumed.

### G4 — icon identity via the same mechanism that just worked

The deferred icon-identity item (013 item 1) is now a small experiment
rather than a research question: `_IconDispatch` (`$ABC9`) is
selector-dispatched exactly like `$AB1D`, the resident already has the
install pattern, the shim template, and the record vocabulary. A
counting patch first (E1's shape: which selectors fire when the Finder
stamps an icon), then, if the arguments carry a resource ID or IconRef
the way the header says, an `iconstamp` record beside the bits op — and
the host renders the REAL icon from the extracted pack instead of a
generic stub. Same graduation rule: counting patch proves it, then it
earns record mode.

## Explicit non-goals

- **Multi-process simultaneous arming.** One armed process with
  expected-stale retention for the rest is the design, and it already
  reads correctly on screen. Widening the arm is a contract change
  with resident cost, and nothing measured yet demands it.
- **Appearance-manager theming of the host renderer** (the "true
  emulator" polish direction). Real, discussed, and not this plan:
  composition must be correct before it is pretty.
- **Metal.** Everything here is emulator-scoped; the PowerBook has seen
  none of this plane.

## Stop conditions

- Any verification result whose harness cannot name the build that
  answered is void on arrival (G0 is the gate).
- If the paced drain still loses bytes against a real application, stop
  and reopen the ring decision with the new numbers rather than tuning
  the knob past its design.
- If the next `mirror-build-out` merge moves the cycle machinery under
  G1, G1 rebases on their cadence owner rather than fighting it.
