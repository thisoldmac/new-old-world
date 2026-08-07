# Fidelity sweep D, 2026-08-07 — scoring the composed result of rounds 6 and 7

**STATUS: IN PROGRESS. This file is a live checkpoint, not a finished
sweep.** Everything below is recorded as it is measured, so that a session
that ends without warning still leaves the measurements behind. Rows
without evidence beside them have not been taken.

Sweep C (`docs/fidelity-sweep-2026-08-07-c.md`) is the most recent
finished word; nothing here edits it.

## Why this sweep exists

Two integration rounds have landed since sweep C — round 6 (16 lanes) and
round 7 (15 lanes), roughly 157 commits — and **nothing has scored the
composed result.** Round 7 reports `GATE_EXIT=0` with the host gate run
twice and no flake. This sweep asks whether the composition is what the
lanes each claimed.

## WHICH RIG THIS DESCRIBES — read before quoting anything

| | |
|---|---|
| **Sweep tree** | `claude/019-sweep-d`, forked from `claude/019-integration-7` at `1a35e96f` ("docs(open-issues): four things round 7's merge could see and no gate could"). |
| **Spec** | `docs/fidelity-sweep-spec.md` at version **3.1** (the version-history row is present in the copy on this branch; it is byte-identical to the copy on `claude/019-sweep-c`). |
| **Lane block** | **982** via `tools/lane-ports` — anchor **19856**, wire **19857**. The human's reserved block 590 / ports 16728–16729 was never dialled. |
| **Base image** | `~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`, named explicitly (it is also what `tools/base-image` designates for `ppc-work`). |
| **Guest build** | `scripts/build-guests` green for all six targets on this tree before any capture. |

## Method changes from sweep C

- (to be filled in as they are made)

## Claims under test — what changed since sweep C

Each is a rectangle to look at, not a vibe.

1. **Title-bar widgets, per window class.** `WindowChrome.widgetBox`
   previously opened `guard win.kind != 2`, so every Dialog-Manager-owned
   window got no widgets. Claimed now at 100% agreement on close box,
   collapse box, stripes, frame row and the bar's bottom edge. The band's
   residual (Chicago standing in for Charcoal) is known and out of scope.
2. **`Platinum.contentTop` 22 → 20.** If the claim holds, every window's
   interior has been two pixels low and one right in every render this
   project has taken. Check that every window moved, and that nothing else
   moved with it.
3. **The zoom box is drawn nowhere.** IR v1 cannot say whether a window
   has one and `kind` cannot stand in. Confirm the absence is honest
   rather than a new gap.
4. **Render stability.** `ImageRenderer.cgImage` now renders into our own
   bitmap context; 1,471 of 57,600 fixture pixels changed. Confirm against
   the machine, not against the old render.
5. **CDEF classification counts went DOWN deliberately** (Memory 33→23 of
   44; Date & Time 19→10 of 21). A lower number is the fix.
6. **`controlsState`** now distinguishes `complete` / `empty` / `unknown` /
   `notFetched`.
7. **The desktop reports who answered** — `machine` / `assetPack` / `none`
   — and a substituted desktop draws a corner plate. An unmarked desktop
   now means the machine named it.

## Live defects to report, never to fix

- **Mail's modal has unclickable buttons** — correct labels, no action,
  "the guest did not provide complete, authoritative semantics." A lane
  owns it. Note what a wedged modal blocks.
- **One interior at a time** is the built behaviour; a screenshot with one
  live interior and the rest hatched is not a defect.

## Measurements taken so far

Nothing yet. The rig was being brought up when this checkpoint was
written.

## Targets reached / not reached

| Target | Captured | Scored | Note |
|---|---|---|---|
| — | — | — | rig bring-up only |

## Rotated new target

Not yet chosen.
