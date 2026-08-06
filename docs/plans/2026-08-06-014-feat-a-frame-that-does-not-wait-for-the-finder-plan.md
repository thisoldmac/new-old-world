---
title: A frame that does not wait for the Finder - Plan
type: feat
date: 2026-08-06
---

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

### 1 · Make the instrument tell the truth · **START HERE**

The per-stage fields must populate on the LIVE path. Watched, on a real
cycle, not in a test. Then one run with the Finder healthy and one with
it loaded, and the answer written down: which round-trip dominates, and
by how much.

**Done when** a live `NOWBASE cycle` line carries all four stage
numbers, they sum to about `decode_ms`, and the dominant stage is named
from data rather than argued.

### 2 · Bound the wait

A watchdog on `runCommand`, with the existing wrong comment corrected in
the same commit. Choose the bound from § 1's data rather than by taste,
and make a timeout a REPORTED outcome — a cycle that gave up must say so
on the line, or this becomes another silent truncation.

### 3 · Take the complements out of the cycle

Publish the frame on decode. Fold the icon roster and the visibility
census in when they arrive, and mark what has not arrived using the
coverage vocabulary rather than omitting it silently. The layout-key
recheck is what the cycle-hold was really protecting; preserve it.

**The risk to design against** is a frame that presents stale enrichment
as current. The reducer's retention rules already distinguish these, and
the status line already has the words.

### 4 · Ask less often

Whether the visibility census needs to run every cycle at all. Cheapest
of the four and possibly the largest win; it is § D's question and it
may make § 3 smaller.

### 5 · The asynchronous content plane — NOT THIS PLAN

Scoped in `docs/open-issues.md` against the state engine, acts, the
status line and serialisation. It earns its own plan once § 1–4 have
shown what is left.

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
