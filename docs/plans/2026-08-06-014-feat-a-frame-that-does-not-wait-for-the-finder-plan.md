---
title: A frame that does not wait for the Finder - Plan
type: feat
date: 2026-08-06
---

<!-- now-doc-provenance: generated reviewed=false -->

# A frame that does not wait for the Finder - Plan

Continues [013, A guest that notices instead of polling](2026-08-06-013-feat-a-guest-that-notices-instead-of-polling-plan.md),
which took the GUEST's cost apart. This one is the same thesis one layer
up: the HOST re-derives, every cycle, state that rarely changes — and it
asks a 1999 Macintosh to answer before it will draw a frame.
Subordinate to [001](2026-08-03-001-now-mirror-ux-completion-plan.md).

## Why this exists

Michelle, driving the Mirror on 2026-08-06: a modal she could not
dismiss, `Cancel` refusing five times, and `open "Date & Time"` refused
twice before succeeding. The acts were addressed correctly and the guest
refused them: `element-not-found: the anchor plane is absent or not
armed`, with `requested=15 active=8`.

**Nothing took the planes down. We stopped asking.** The guest's plane
lease is 10 s and is renewed by host traffic; the host's cycle had grown
to 12.6 s, so the lease expired between every cycle. An act arriving in
that window finds the plane it needs already dark.

### The cycle's cost is not ours, and it is not the scene's size

Measured across 43,448 cycles in `acts.log`:

| windows / elements | n | median `decode_ms` |
|---|---|---|
| 12 / 346 | 1914 | **714** |
| 6 / 170 | 442 | 1731 |
| 6 / 168 | 21 | **12824** |
| 3 / 60 | 3 | **12559** |

Twelve windows cost 714 ms; three cost 12,559 ms. The distribution is
**bimodal** — 95.7% under a second, then peaks at 5.5–6 s and 14–15 s
with near-empty gaps. Sharp modes with space between them are waits, not
work. Confirmed since: the same 6 windows / 177 elements that cost
12.4 s during the modal now cost 2.2–2.9 s with the Finder healthy. The
variable is the FINDER'S responsiveness, not the document.

**And `decode_ms` does not measure decoding.** It brackets
`publishedAt − deliveredAt`, and `finishCycle` is not called until the
JSON parse, the reducer, the projection, `joinContent` (1–2 guest
commands), the Finder icon roster (**AppleScript**, paged 8) and the
visibility census (**AppleScript**, paged 8, **every cycle**) have all
settled. Our own CPU work is **4 ms** for that six-window document, and
15 ms for the largest scene ever captured. A field named `decode`
containing an unbounded number of guest round-trips is why three people
in one night started at the JSON parser.

An Apple event on a cooperatively scheduled Macintosh is answered when
the Finder is next SCHEDULED, and nothing can make it sooner;
`FinderItems` already records 1–2 s per Finder Apple event on a healthy
guest. Page that eight at a time, two or three times a cycle, and twelve
seconds needs no slow code anywhere.

### The defect, named

**A priority inversion.** The structural scene is the product — it is
what a person sees and what every act's references depend on. The icon
roster and the visibility census are ENRICHMENT. Today the enrichment
can stall the frame for seconds, which lapses the guest's planes, which
makes acts refuse. An optional nicety is breaking the core feature.
`docs/resident-components.md` states the same rule for the extension: an
optional component must degrade honestly and must never be able to take
the product down with it. The host does not honour it.

## Goal Capsule

- **Objective:** a frame is published as soon as the scene is decoded.
  Enrichment that has not arrived is reported as absent, never waited
  for. The plane lease then stops lapsing as a CONSEQUENCE rather than
  by being lengthened.
- **Authority:** unchanged — `contract/asyncapi.yaml` for wire meaning,
  `MirrorStateEngine` for the single published state.
- **Non-goal:** making AppleScript faster. It is answered when the
  Finder is scheduled; that is the machine's nature, not a defect.
- **Stop conditions:** any change that lets a stale enrichment be
  presented as current, and any fix that hides the wait behind a longer
  lease.

## The decisions, and their arguments

### A — the instrument comes first, AGAIN, and this time it must be watched working

`dc_own_ms` / `dc_content_ms` / `dc_icons_ms` / `dc_vis_ms` were added
to the cycle line to answer WHICH round-trip dominates. **They populate
in tests and are absent from every live cycle**, so the question is
still open and the instrument built to answer it does not.

This is the third time in two days that a number has been read as
measuring something it did not: the tick-quantised walk that could not
see under 17 ms, the per-point cost derived by dividing one estimate by
another, and now a bracket named `decode` containing guest round-trips.
So: fix the instrument, take ONE live run, and only then choose where
the work goes.

> **2026-08-06, and it is the fourth time rather than the third.** The
> bolded claim above is FALSE and was the misread number itself. The
> fields populated on the live path all along; the cycle lines that
> lacked them had been written by an earlier app instance. Left standing
> because the paragraph's own conclusion — take one live run before
> choosing — is what caught it.

### B — a watchdog is correct on its own terms, and is NOT the fix

`GuestListener.runCommand` arms no watchdog at all; the nearby comment
promising "the 15s a command.request gets" describes a different message
family. The only ceiling is the guest's own `kNowScriptDefaultMs`, which
the host never overrides.

An unbounded wait on a foreign machine is a defect independently of this
plan, so it lands regardless. But it cannot be the fix: three scripts at
a three-second bound is still nine seconds against a ten-second lease,
and a truncated conversation still blocks the frame.

### C — the frame must not depend on the enrichment, rather than depending on it faster

Both remaining options remove the dependency; they differ in how far.
Taking the complements out of the cycle is the smaller one and is
already built and mutation-tested (recoverable from
`claude/host-decode-perf`'s reflog). A properly asynchronous content
plane is the end state and deserves its own plan rather than being
smuggled in at four in the morning.

**The IR already has the vocabulary for the honest report.**
`meta.coverage[]` carries typed status with a reason, the reducer
deletes only under a `complete` claim, and the status line now says
`5 windows, 3 expected-stale`. Absent enrichment has somewhere true to
go; it does not need inventing.

### D — do not ask for what cannot arrive

The visibility census runs **every cycle** for state that rarely
changes. That is 013's thesis exactly, one layer up: the fix for the
guest was to stop re-deriving what had not changed, and the same
question should be asked here before any of it is made asynchronous.

## The work

### 1 · Make the instrument tell the truth · ~~**START HERE**~~ · **DONE (`1bb7fdcf`, answered in `bde9ee9f`). See "Picking this up cold" below for the answer.**

The per-stage fields must populate on the LIVE path. Watched, on a real
cycle, not in a test. Then one run with the Finder healthy and one with
it loaded, and the answer written down: which round-trip dominates, and
by how much.

**Done when** a live `NOWBASE cycle` line carries all four stage
numbers, they sum to about `decode_ms`, and the dominant stage is named
from data rather than argued.

### 2 · Bound the wait · **DONE** (`bde9ee9f`)

A watchdog on `runCommand`, with the existing wrong comment corrected in
the same commit. Choose the bound from § 1's data rather than by taste,
and make a timeout a REPORTED outcome — a cycle that gave up must say so
on the line, or this becomes another silent truncation.

### 3 · Take the complements out of the cycle · **DONE** (`bb5e58e0`, honesty half in `bde9ee9f`)

Publish the frame on decode. Fold the icon roster and the visibility
census in when they arrive, and mark what has not arrived using the
coverage vocabulary rather than omitting it silently. The layout-key
recheck is what the cycle-hold was really protecting; preserve it.

**The risk to design against** is a frame that presents stale enrichment
as current. The reducer's retention rules already distinguish these, and
the status line already has the words.

### 4 · Ask less often · **DONE** (`bb5e58e0`)

Whether the visibility census needs to run every cycle at all. Cheapest
of the four and possibly the largest win; it is § D's question and it
may make § 3 smaller.

### 5 · The asynchronous content plane — NOT THIS PLAN, and now DEFERRED WITH A REASON

Scoped in `docs/open-issues.md` against the state engine, acts, the
status line and serialisation. It earns its own plan once § 1–4 have
shown what is left.

## Picking this up cold

**§§ 1–4 are DONE.** Landed on `claude/frame-no-finder-wait` and merged
into `claude/mirror-thread-content` on 2026-08-06 (`1bb7fdcf`,
`bb5e58e0`, `bde9ee9f`, `75ac752f`). **§ 5 is DEFERRED with a reason,
not open** — see below. There is nothing here to start. If this section
and the code disagree, the code is right; if it and
[open-issues.md](../open-issues.md) disagree, the ledger is right, and
the ledger's four dated sections under the `decode_ms` entry are the
full account with every number in it.

*(This section previously read "IN PROGRESS. Do not start § 1", written
while the work was live under another session's hand. It was accurate
for about three hours.)*

**Tier: TESTED and EMULATOR-VERIFIED. Nothing here is metal-verified.**
A 1400c's Finder is slower than an emulated G4's, so every number below
is the optimistic one.

### What each section did

- **§ 1 — answered, and the instrument was never broken.** All four
  `dc_*` stage fields populated on the live path all along. The report
  that they were "absent from every live cycle" came from reading
  `acts.log` lines written by the PREVIOUS app instance — last line
  13:58:19, the build that added them started 13:58:24 with no cycle
  yet run. That misreading is now
  [measurement rule 19](../mirror-measurement-method.md): the end of a
  shared append-only log is not your run. **The answer** (n=85, Finder
  healthy, one window): `dc_own_ms` 9, `dc_content_ms` 5, `dc_icons_ms`
  0, `dc_vis_ms` **338**, summing to `decode_ms` 353. The visibility
  census is **~96% of the bracket on every steady-state cycle**; the
  icon roster is 0 while the layout holds and 1349–1565 ms when it
  changes — 4× the census, but only on change, where the census was paid
  forever. § 4 was therefore done beside § 3 rather than after it.
- **§ 2 — done.** `runCommand` arms a watchdog at **20 s**, chosen
  against the guest's own `kNowScriptDefaultMs` (15 s) so a typed
  refusal always beats a bare host timeout; the 3 s this plan's ledger
  entry proposed now FAILS a test that explains why. The wrong "the 15s
  a command.request gets" comment is corrected — that 15 s belongs to
  `file.list` / `process.list` / `process.drive`, which merely share an
  id sequence. Timeouts are reported as `timeouts=N` on the cycle line,
  omitted at zero.
- **§ 3 — done, including the honesty half.** The cycle publishes on
  decode; a frame published before its roster carries a `finder-items`
  `meta.coverage` claim with typed status and reason, and the status
  line says `awaiting icons`.
- **§ 4 — done.** The census is keyed on the process roster with a 3 s
  floor, invalidated explicitly by the hide act. It fired 17 times in 62
  cycles instead of 62.
- **The result**, 258 cycles on a fresh clone, every one `outcome=ok`:
  `decode_ms` median 353 → **16**, `total_ms` 364 → **25**, a
  layout-change cycle 1936 → **26**, planes 15/15 on 257 of 258 samples.
  The complements still cost what they cost — `NOWBASE finder
  containers=2 complete=yes ms=1478` sits beside a 26 ms cycle — which
  is the POINT of the plan, not a caveat against it.

### § 5 is a decision, not a to-do

The asynchronous content plane was scoped and **argued against on § 1's
own numbers**: the content join is 5–12 ms, three orders below the
census, so it buys nothing measurable on a healthy guest; and in the
starved case the guest never answered `scene.request` either, so the
cycle was already lost upstream of P3. Do not write a plan from the
argument in § 5 above. What would reopen it is one specific measurement
— a guest answering `scene.request` promptly while the content join does
not — and no such case has been observed. The scope, if it is ever
wanted, is Option 3's four bullets in the ledger.

### What is still UNVERIFIED

- **Michelle's own act was never driven.** "A dialog act that settles
  rather than refusing" is the symptom this plan started from, and it is
  verified only down to its cause: `tools/now-agent` reaches ONE host
  per user and her packaged app holds the socket, so taking it would
  have disturbed a live session. **The first thing a drive should
  re-test.**

  **Corrected, later on 2026-08-06 — the CAUSE is no longer open, and
  this plan was not the whole of it.** The tooling limitation above is
  why the case was never *driven*; it is not the cause of the symptom.
  The cause was found the same day and is **NOW's own act client**: its
  wait did not pump the wire, so an act nobody takes held `conn_service`
  off for ~10 s and every scene request in that window reported the
  act's duration as its own. Fixed in `afe5cbd2` — and it cost the
  no-hijack argument's single-cell protection, which Michelle
  authorised. See [open-issues.md](../open-issues.md)'s two entries
  *"LIVE RISK, deliberately taken"* and *"the twelve seconds under a
  modal is NOT starvation"*. What remains true here is the last
  sentence: **her case has still not been reproduced**, and on a fresh
  clone it cannot be, because foreign processes read `not-observed`
  (the anchor-bind defect). A drive should still re-test it, now to
  confirm the act-pump fix rather than to find a missing cause.
- **The watchdog has never been watched FIRING.** Its bound and its
  reporting are guarded by tests; the expiry settling a stored
  completion is not, because the suite would have to wait 20 s for it.
- **Two defects were found in § 2's watchdog AFTER it landed, and
  neither is fixed** (2026-08-06). `armWatchdog` keys its map on a
  request id while three id sequences each start at 1, so a command and
  an exec sharing a number collide; and `requestCensus` — which is
  precisely what § 4 rescheduled — arms **no watchdog at all**. Ledger:
  *"BROKEN, latent, found in passing: two request families draw ids from
  separate counters and share one watchdog map"*.
- **The 20 s bound's stated argument does not cover the act path.** It
  was chosen against the guest's 15 s *script* ceiling. The act path
  spends 5 s per phase with nothing naming that ceiling in the same
  place, so the bound survives on arithmetic nobody wrote down.
  [nested-loops.md](../nested-loops.md) carries the row; stating the act
  ceiling once, where both sides read it, is the open piece.
- **A Finder-OWNED modal is not repaired by any of this** and cannot be
  — it starves NOW too. See the ledger's dated 2026-08-06 line under
  *"one modal wedges the whole Mirror"*.

## What would make this wrong

- **Hiding the wait behind a longer lease.** The lease is a symptom
  detector; lengthening it deletes the detector and keeps the disease.
- **Presenting stale enrichment as current.** The product's entire claim
  is a faithful mirror; a fast lie is worse than a slow truth.
- **Optimising AppleScript.** It answers when the Finder is scheduled.
- **Choosing where the work goes before § 1 reports.** Three numbers
  have already been misread in two days, each of them convincingly.

## Verification

- **Host** (`scripts/test-host`): the watchdog by mutation, the
  publish-on-decode path, and a regression bound on cycle time using the
  captured fixtures (`now-scene-*.json`, `scene-quit-modal.json`), which
  decode in 4 ms and will name a return of this defect.
- **Emulator**: cycle time and `requested`/`active` before and after,
  with the Finder healthy AND loaded — the loaded case is the one that
  bit, and a fix measured only on a quiet machine has not met the
  defect. Then Michelle's own case: a dialog act that settles rather
  than refusing.
- **Metal**: none of this has run on a PowerBook, and a 1400c's Finder
  is slower than an emulated G4's — so the numbers here are the
  OPTIMISTIC ones.
