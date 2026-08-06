---
title: Worlds hooked at birth - Plan
type: feat
date: 2026-08-06
---

# Worlds hooked at birth — Plan

Successor to [013](2026-08-06-013-feat-composing-interiors-host-side-plan.md),
whose join is control-green and Finder-proven, and whose slice D0 this
plan grows into its real shape. Subordinate, as 013 was, to
[001](2026-08-03-001-now-mirror-ux-completion-plan.md). Where this plan
and [open-issues.md](../open-issues.md) disagree, the ledger is right.

## Why this exists

Two applications drew the boundary on 2026-08-06, the same day the join
landed. **Appearance** builds a transient offscreen world per widget
blit; **Sherlock 2** builds one per full-window repaint (490×448, 7
sights, 7 misses, 0 hooks). Both are created, drawn, blitted and
disposed inside one event-loop pass, and the chase hooks one pass after
sighting — every hook arrives at a corpse. Their interiors (Sherlock's
list rows, radio labels and channel picker; Appearance's themed
everything) are therefore invisible to the join, and no scan budget
fixes a target that dies before the scanner's next turn.

The cure was named in 013 D0 and is now load-bearing: **hand the plane
every world at creation.** A patch on `NewGWorld` is not merely the
safer discovery mechanism — for transient worlds it is the only one.

## What is already known, so nobody re-derives it

The overnight toolbox/GWorld RE lane
([docs/toolbox-and-gworld.md](../toolbox-and-gworld.md),
docs/local/toolbox-re/prior-art.md and its ledger) did most of this
plan's homework before it was written:

- **A native PPC application never executes the A-trap itself** — its
  object code has no A-trap instructions; it calls import-library
  exports. **But InterfaceLib's glue reads the trap dispatch table at
  call time** (IM: PowerPC System Software, with Apple's own 15 µs
  mode-switch cost warning as corroboration), so a 68K patch installed
  in the table IS picked up by native callers routed through
  InterfaceLib.
- **Everything on `_QDExtensions` (`$AB1D`) is selector-dispatched and
  can carry only 68K patches** — which is what the resident is. So the
  documented machinery composes: 68K head/tail patch on `$AB1D`,
  reached by native callers via InterfaceLib glue. (`NewGWorld` is
  selector 0, 22 param bytes; `DisposeGWorld` is a sibling selector —
  read the header, never guess the number.)
- **The Finder imports its entire GWorld surface from InterfaceLib** —
  read statically from its own PEF import table with `tools/pef.py`. So
  for the Finder the patch is documented-predicted to fire. **The
  CarbonLib hole is real but is OURS, not the targets'**: 'New Old
  World' itself resolves QuickDraw against CarbonLib, whose trap-table
  behaviour under 9.1 is undocumented — irrelevant to hooking the
  Finder, worth one static check per new target (E0).
- **Split traps cannot be patched, but they are "very small utility
  routines"** (AddPt, SetRect per Apple); nothing suggests the
  QDOffscreen dispatch is one. No authoritative split-trap list exists —
  the live counter is still the proof.
- **An application-installed trap patch is process-local.** Measured by
  `tools/guest-gworld/src/trapwatch.c`: a fresh 68K process's startup
  `NewGWorld` never crossed an applet's patch. This voids the applet as
  an instrument and is simultaneously the scoping story for the
  resident: installed at the armed pass, in the armed process's own
  context (the act plane's `install_patch` pattern), it exists only
  where it was asked for.
- **The join, the record vocabulary, and the host pipeline are done**
  (013 A–D): ops keyed by a hooked port cross, blitsrc names the source
  at blit time, the host re-homes and renders. This plan only has to
  deliver ports to that machinery earlier.

## The slices

### E0 — which library do the targets link? (static, minutes)

`tools/pef.py` over Sherlock 2 and Appearance (pulled once via the
anchor): do their QDOffscreen imports resolve to InterfaceLib, like the
Finder's, or to CarbonLib? InterfaceLib → the documented glue applies
and E1 is confirmation. CarbonLib → E1 is a genuine experiment and the
CarbonLib hole gets its first data point either way.

### E1 — the counting patch (one boot, decides everything)

A resident-installed `$AB1D` patch that counts, and hooks nothing:
total calls, selector-0 calls, last selector — the trap-watch cells,
moved into the content block as accretive appended fields so the wire
reports them (`status`'s probe object). Installed at the armed pass in
the armed context, exactly like the act plane's six. Assembly shim from
the start (`now_ext_act_patch.S` is the template; the
register-callback-as-C cold-boot hang is the scar that mandates it).

Arm Sherlock in probe mode, force a repaint, read the counters.

- Selector-0 count moves → the approach exists; build E2.
- It does not move → **the scan is NOT the fallback here** (it cannot
  catch transient worlds either). The escalations, in order of pain:
  patch at the **CFM level** — and the RE arc has already charted that
  road: routine descriptors are reachable from a running guest
  (`SetStdCProcs` → descriptor+20 → transition vector → PPC entry
  point, dumped and disassembled), so redirecting an export's TVector
  is measured territory rather than folklore, though it means a PPC
  shim and per-fragment work. Or: pixel islands for composite-locked
  windows (surrenders "no pixels" for exactly those windows, honestly
  typed as such). Choose deliberately, in a plan revision, not by
  drift. The RE lane stands ready to dig deeper on either road.

### E2 — hook at birth, drop at death

The wrap becomes head+tail: preserve the caller's arguments, call the
old dispatch, and on return from selector 0 read `*offscreenGWorld`.
In the shim's tail, in the armed process's own context:

- verify armed && `LMGetCurrentA5()` is the armed world (the same gate
  every hook asks);
- install `grafProcs` on the newborn port and add its port-table row —
  stores only, no allocation, the block was handed to us this instant;
- ring-put `worldBorn {port, pixmap, bounds}` (new accretive op,
  013-option-2 style: an old reader steps over it whole).

On `DisposeGWorld`: match the argument against the table, drop the row,
ring-put `worldDied {port}`. Never dereference the port after the old
dispatch runs.

The sight→scan→chase stays as the fallback for arms whose patch never
fired; for a patched process it goes quiet — creation hands over every
port, which is also the world-replacement signal slice C currently
infers from ops going stale.

Native tests: the row add/drop and the born/died record layouts are
pure decisions (`now_content_logic.c`); the shim itself is 68K assembly
and is verified by E3.

### E3 — the control, then Sherlock

`loop.c`'s startup `NewGWorld` predates every arm — so under E2, arming
the ALREADY-RUNNING control must still work via the old chase (nothing
regressed), and a control launched AFTER arming gets hooked at birth,
meaning its FIRST `BuildWorld` — today always missed — is recorded.
That asymmetry is the test.

Then Sherlock: arm, repaint, and the drain should carry its list rows
('Macintosh HD', 'Volume indexed …'), its radio labels ('File Names',
'Contents') and its channel wells as text/rrect/bits under transient
ports, each followed by blitsrc+bits pairs the existing join places.
Fixture and gate join `NOWMirrorContentCoverageTests`, replacing the
boundary-pinning test's negative claims one by one.

### F — host lifecycle for born/died

`worldDied` gives the host its real drop signal: held ops for that
source are released the moment the world goes, replacing bounded-
retention guesswork. `worldBorn` may open the bucket eagerly. Decode
plumbing mirrors blitsrc's (record-level, off the render IR).

## Pressure points, named before they bite

- **Ring pressure is now acute** (013 deferred item 4). Sherlock
  redraws its whole interior per repaint; a hooked Sherlock will feed
  the 64 KiB ring much faster than the Finder did. Either the drain
  keeps up (host cadence), the arm stays short, or the ring grows — the
  decision belongs to whoever watches the first hooked-Sherlock drain,
  with numbers.
- **Port-table pressure** (013 deferred item 7): 16 rows, and a
  widget-per-world application can burn them in one pass.
  `worldDied` must recycle rows aggressively; `skipped_ports` stays the
  honesty counter and E3 must look at it.
- **The patch is never removed** (act plane rule) but must be strictly
  pass-through when disarmed, and its counters must make a stale patch
  visible rather than mysterious.
- **`ext/` is gated.** Every slice here is resident code; each commit
  defers in writing or bakes deliberately. The probe must still never
  ship armed.

## Stop conditions

- E1 negative → stop and choose an escalation in writing.
- Any cold-boot hang attributable to the shim → stop, symbolicate,
  re-read the ABI lesson before touching the assembly again.
- Ring loss during a hooked-Sherlock drain that the host cannot pace
  away → stop and take the ring decision explicitly.
