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

## Verdicts (research complete, 2026-08-15 overnight)

- **C1 LOCKED — Michelle was right; the Web module has never worked on
  any guest.** OT loopback delivers, but OTListen reports the peer as
  the machine's PRIMARY address (observed 10.0.2.15), and
  `web_proxy_ot.c:138` refuses any peer ≠ 127.0.0.1 — so every browser
  request is refused, indistinguishable from "nothing listening".
  Emulator-proven end to end with three patched builds; the BIND is the
  security boundary (curl through a hostfwd fails against the 127.0.0.1
  bind with no filter). Fix: delete the peer condition, real TBind
  readback into the page's endpoint line, record last-refused in status,
  pure `should_accept` seam + native test with a non-loopback peer.
  Metal remains the final word on other Macs' TCP/IP configs. The 034
  autostart toggle DID ship (Settings ▸ Web ▸ Service — moved by G-5);
  guest proxy already auto-starts.
- **C2 LOCKED, three mechanisms, footer is IN the drop system:** (M1)
  the canvas fallback's lower half prepends (index 0) while the upper
  half appends — footer chrome shoves Connections down before the
  pointer arrives; (M2) wave-1 suppressed eager previews for `.insert`
  only — `.move` still reflows live, and the row physically moving is a
  real draggingExited that resets AppKit's dwell; (M3) targets index the
  preview layout, commands resolve against the baseline. Tab drops:
  accepted, then silently reverted by `enforceSpecialHeroes` on save
  (Settings pill is the leftmost, undraggable, natural aim point) and
  swallowed by the no-op guard. "Connections stays in the footer" is
  NOT design — two green tests assert the opposite. Fix wave: F2
  (.move previews baseline; insertion line says where it lands), F1
  (footer drop geometry appends), refuse-before-hero drops up front
  (cursor says no — option 1; option 2 "hero becomes movable" is
  Michelle's product call, deferred), + the six tests T1–T6.
- **C3 CLOSED — stale binary.** Emulator with this tree's guest:
  Storage "4.0 GB, 3.2 GB free", Processor "PowerPC G3 (750) @ 900 MHz",
  console/identity/overview agree. Install bundle 3bccd505's guest.
  One new unscoped gap found live: the Volumes probe (and the
  code-identical ata drive line) still prints raw MB — locked small fix.
- **S4 LOCKED, four causes:** (a) `getFile` has no busy-guard and no
  request-id correlation — a single unkeyed pendingFile slot shared by
  four callers; a race orphans AppKit's promise completion (the "ghost"
  is Finder's own placeholder) and wedges every later drag-out; (b/c)
  promise metadata: 7-entry classic-type switch falling to generic
  .data + extension-less promised filename — Finder accepts anything,
  real apps validate and refuse; (d) the same stalled mutex blocks
  uploads silently, plus promise-only drag sources (Photos etc.) show a
  copy cursor and silently fail — no NSFilePromiseReceiver handling.
- **S1 LOCKED:** toggle lives in the leading pane's header; Files puts
  it in the trailing pane's own header. ~15-line move.
- **S3 DISCUSSION (morning):** recommendation is guest-only multi-root
  union, no contract schema change — but the prefs-array shape and root
  cap are one-way decisions Michelle should confirm first.
- **N1–N6:** briefs complete → GitHub issues (not implemented, per the
  overnight contract). N4's ticket builds on the sibling's log work.

## Overnight wave

L-web (C1, emulator re-verify), L-footer (C2 + T1–T6), L-files (S4,
sibling-check first), L-smalls (S1 + volumes/ata units). S3 waits.
- 2026-08-15 (overnight): idea tickets filed — N1 → #29, N2 → #30,
  N4 → #31 (builds on the sibling's log work), N6 → #32, N5 → #33,
  N3 → #34. The two arcs (#33, #34) carry their option sets and the
  deciding questions; nothing implemented, per the overnight contract.
- 2026-08-15 (overnight close): fix wave merged, split re-merged
  @79468368, gate green end to end. C1/C2/S4/S1/V3-gap fixed; C3 closed
  as stale binary; S3 waits on Michelle (prefs shape + root cap); ideas
  are #29-#34. Session.swift activeFileGetID gap handed to the sibling
  session directly. Morning calls: shelf heroes movable? footer Debug-row
  drop feedback (live check)? plus the standing pre-PR list (hooks,
  round-2 bake, rename, QA statuses). PR-ready branch staged as
  feat/034-host-guest-assessments; draft description in
  docs/local/pr-draft-034-035.md.
- 2026-08-15 (Michelle, morning): (1) shelf heroes become MOVABLE — the
  user decides tab order; delete fixedModuleHeroID/enforceSpecialHeroes,
  hero = moduleIDs.first, and retire the overnight refuse-up-front guard
  with it. (2) Footer drop feedback confirmed live: it lands then
  immediately reverts — i.e. the footer IS hit-tested and the symptom is
  the accept-then-sanitise revert the fix wave already removed; no
  deeper hit-testing work needed. Her observation was against the
  pre-fix bundle; top of the live checklist is re-testing drag on the
  new build.
