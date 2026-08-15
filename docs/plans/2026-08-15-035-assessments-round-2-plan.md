<!-- now-doc-provenance: generated reviewed=false -->

# 035 — Assessments round 2: plan and tracker

Status: **research/investigation in progress** (2026-08-15). Round 2 of
plan 034's list, from Michelle's testing of bundle 3bccd505. Three
classes: **contradicted** (034 claimed fixed, Michelle observes broken —
these get emulator/live verification, not code reads), **new features**,
and **smaller fixes**. Notes land in `docs/local/assessments-035/`.

Standing hypothesis to confirm or kill first: the guest-side 034 fixes
(H13 formatting among them) are invisible until the new guest binary is
installed on the observed Mac — bundle 3bccd505's `New Old World.bin`
must actually land on the guest before its fixes can show.

## Contradicted (live-verify, then fix at the root)

| ID | Item | Unit | Class |
|----|------|------|-------|
| C1 | Web proxy: "127.0.0.1 not loopback on classic macs" — does OT loopback actually work on OS 9? The shipped design depends on it. Also: start-automatically toggle (host one shipped in 034 — present? or is the ask guest-side?) | V1 | |
| C2 | Spring-load into connections shelf still fails; NEW: can't drop into its tabs, can't move it out of the footer — footer-pinned shelves may be outside the drop system entirely | V2 | |
| C3 | Guest overview storage/CPU formatting still raw (H13 shipped guest-side; suspect stale guest binary — verify on emulator with the fresh build) | V3 | |

## New features

| ID | Item | Unit | Class |
|----|------|------|-------|
| N1 | Warn when starting Continuity with Mirror running | V6 | |
| N2 | First-launch screen | V6 | |
| N3 | Proper emulator support | V7 | |
| N4 | Logs: levels, formatting, export, clipboard | V6 | |
| N5 | now-api + now-cli | V7 | |
| N6 | Accessibility notifications / dynamic warns with dismiss | V6 | |

## Smaller

| ID | Item | Unit | Class |
|----|------|------|-------|
| S1 | Connections sidebar needs to own its own toggle | V5 | |
| S2 | Guest proxy needs host-status visibility | V1 | |
| S3 | Projects: addable, not one root folder | V5 | |
| S4 | Files drag-out glitchy: filename ghost printed at drop location until NOW exits, blocks further drag-outs; file-promise metadata incorrect; drops work to desktop but not most apps; drag-in also has issues | V4 | |

## Units

| Unit | Scope | Tier | Mode |
|------|-------|------|------|
| V1 | Web proxy loopback truth on OT (emulator), host-status visibility, autostart audit | opus | investigate |
| V2 | Footer shelf drag/drop system (connections pinning) | opus | investigate |
| V3 | H13 on the emulator with the fresh guest | sonnet | verify |
| V4 | Host Files drag-out/promise defects | sonnet/high | investigate |
| V5 | Connections toggle + Projects multi-root | sonnet | research+fix plan |
| V6 | Feature briefs: continuity/mirror warn, first-launch, logs, a11y notifications | sonnet | research |
| V7 | now-api/now-cli + emulator-support identity | opus | research |

## Decisions log

(Empty.)

- 2026-08-15 (Michelle, heading to bed): priorities — fix jank/breakage
  to get the PR open; the "new" section is mostly ideas: write thoughts,
  open tracking tickets, do not implement (emulator support and
  now-api/cli are arcs of their own). The sibling session in worktree
  fable-continuity-accessibility-24b8bf is actively working cross-screen
  drag + logging + adjacent pieces; its branch currently holds nothing
  we lack (tip b464b284, clean tree — the new work is uncommitted).
  RULE for this arc: before implementing V4 (files drag) or acting on
  V6's logs brief, re-check that worktree's branch and any fresh
  fix/feat continuity branches; prefer cherry-pick/coordination over
  re-implementation where they've touched the same symptom. The two
  threads merge eventually.
- 2026-08-15 (sibling status via screenshot): the split branch is live
  again — their lanes land on refactor/mirror-continuity-split
  (658d77e9: guest-log-retrieval, guest-mirror-log-gate; grab /
  cross-release / AX / schema lanes still in flight). Queued here, in
  order: (1) after the V-unit research completes (its emulator lanes
  stage THIS checkout's build — no mid-run merges), merge split's
  current head again to keep drift small; expect a REAL conflict in
  guest mirror code — their log-gate was written against the four-gate
  policy my G-7 replaced with one master consent, and the consent shape
  is decided (G-7 stands), so their gate adapts at merge. (2) V6's N4
  logs ticket must build on their log work (paged now_log_tail
  retirement, host log-tail codec), not duplicate it.
