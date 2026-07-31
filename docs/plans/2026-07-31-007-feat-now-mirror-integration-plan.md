# Folding Mirror into NOW

**Date:** 2026-07-31 · **Status:** intent, nothing built · **Namespace:** `claude/`

A snapshot of intent, per [README](README.md). Where this and the code disagree,
the code is right; where this and [open-issues.md](../open-issues.md) disagree,
the ledger is right.

## The upstream is still moving

**Mirror lives in its own repository** (`timbottu/mirror`) and is under active
work in another worktree. As of 2026-07-31 the churn is concentrated in
`host/MirrorKit` and `guest/app`, with a **third extension — `portal` —
mid-solution** (`CONTROL_INVOKE` built, the `TrackControl` ABI proved by effect
rather than by selftest). New `IR-V1.md` and `FANOUT.md` suggest the scene IR is
settling, which matters because that is the shape any wire work would carry.

**Michelle will say when it has landed fully.** Until then this plan sequences
around what is settled and explicitly defers what is not. Integrating a moving
target means integrating it twice.

## What Mirror is

A live **semantic** mirror of a Mac OS 9.1 desktop: windows, controls and menus
travel as structure rather than pixels, a native app draws them in Platinum, and
input goes back. *"A screenshot shows you what the screen looked like; Mirror
hands you the thing the screen was."*

Three pieces today: resident 68K `INIT`s (**AXPeek**, the A5-world address
oracle; **QDPeek**, the QuickDraw op stream; **portal**, in flight), a PPC guest
agent that walks validated regions and serves scene and action verbs, and a
Swift host split into a headless core, a Platinum renderer and an app.

Its agent surface already works end to end — `mirror.attach` / `find` /
`act.key` / `shot` / `wait` / `detach`, 7/7 against a live guest — and the act
was verified **in the guest filesystem**, not by the service's own report,
because `performed: true` means an event was dispatched and not that anything
happened.

## The three answers already given

Recorded here because they are the frame, and they were decided rather than
inferred:

1. **The extensions fold into the one NOW Extension.** NOW ships one file by
   charter ([resident-components.md](../resident-components.md)) — one installer
   checkbox, one restart story, one Gestalt probe, one version.
2. **Ride the wire NOW already establishes.** The guest dials out; once the
   connection is up it is bidirectional, and Mirror's traffic becomes families
   on the multiplexed wire that exists. Listening-for-connect and AppleTalk are
   a different slice's problem and nothing here forces them.
3. **Extend NOW's wire, do not transliterate Mirror's.** Mirror-shaped families
   in NOW's conventions, not a verbatim copy of its protocol.

## The closer-than-expected part

NOW's extension is **not** an empty shell waiting for its first plane. It ships
core P0 (a chained jGNE filter, the shared table, one Gestalt selector) **and an
anchor plane P1**: `find_anchor_slot(NowPeekU32 a5)`, `capture_anchor()`, armed
by the application, freshness-stamped per slot.

That plane captures **A5 per process**. AXPeek publishes `CurrentA5`,
`WindowList` and `MenuList` per application. **They are the same mechanism
against the same barrier** — per-process Toolbox roots being invisible from
another process — and NOW's already exists, with
[`contract/peek_table.h`](../../contract/peek_table.h) compiled by three
toolchains and static asserts pinning every offset.

So AXPeek is not an INIT to port. It is **two more roots in a table row that
already carries one**, which is exactly the accretive per-plane versioning that
header specifies.

## The blocker nobody has resolved

**Mirror is a continuous stream. NOW has one transfer lane across both
directions.**

Capture holds it. File transfer holds it. `now_transfer_cancel` exists precisely
because one thing can be in flight at a time. Mirror's scene poller is a
permanent, paced flow — the first thing NOW would carry that is not a bounded
call.

This is the **streaming decision deferred three times**: `stream.start` /
`.stop` / `.refresh` are the last three unnoticed gaps in
[mcp-coverage.md](../mcp-coverage.md), unprojected precisely because a
continuous host-owned bracket is a different shape from a bounded call.

**Mirror is what forces it, and no wire work should start before it is
answered** — the answer changes the shape of every scene family. Prior art
exists: NOW already learned that empty frames need a guest-side fps floor and
that a decimated capture must never leave as a keyframe.

## Sequencing

Ordered by what is settled upstream, not by what is interesting.

### M1 — AXPeek into the anchor plane

**First because it is settled, needs no wire and no host, and is additive to a
versioned struct with a defined absence reading.** Extend the anchor plane's
table row from one root to three. Bump that plane's format word; readers require
their plane's format and `length >=` what they read, which is the prefs-record
rule the header already applies.

Unblocked today. Mirror's `guest/extensions/axpeek` has not moved since
2026-07-30.

### M2 — QDPeek as its own plane

Genuinely new, dormant until armed, and the plane model exists for this. Per the
charter: developed as a **throwaway INIT under an honest name** on a QEMU clone
(`tools/mb_rename.py`), folded into the NOW Extension only after its ladder
passes. Planes talk only through the core; no cross-plane calls.

Also settled upstream since 2026-07-30.

### M3 — the streaming decision

**A decision, not an implementation.** Does NOW grow a continuous bracket
alongside its bounded calls, and if so, how does it share one transfer lane with
capture and file transfer? Everything downstream of here is shaped by the
answer.

### M4 — scene families on the wire

Mirror-shaped, NOW-conventioned. The IR is the thing being carried; read
`IR-V1.md` upstream when it settles rather than designing against a moving
target.

### M5 — the guest's walk

NOW's guest app gains what Mirror's guest agent does: map an AXPeek sample to
the live Process Manager partition, walk **only** validated regions, serve the
scene. The largest piece, and it depends on M1 and M4.

### M6 — the host module and its projections

`MirrorKit` (headless core) and `MirrorKitUI` (Platinum renderer) become a NOW
module; the act verbs become projection rows. The host split maps cleanly —
`NOWAgentIntegration` is already a local package product, and the module pattern
now has two precedents.

### Deferred until it lands

**`portal`.** Mid-solution upstream. Folding a mechanism while its author is
still proving it means integrating a moving target and re-doing it.

Note the adjacency, though: portal is attacking **drag and command-key-less
menus**, which `PostEvent` cannot reach because it cannot drive an app already
inside a tracking loop. Journaling *does* reach inside a live `TrackControl`,
but `JournalFlag` is a per-process low-memory global that cannot be armed for a
foreign process **from outside**. Whether it can be armed **from inside**, by a
hook running in the target's context, is the open question — and NOW's frozen
core already chains a jGNE filter that runs in exactly that position. That is
the same door NOW's own `PostEvent` finding pointed at
(`postevent-modifiers-need-ppostevent`), so the two projects are converging on
one mechanism from opposite sides.

## What already agrees, and should not be renegotiated

Mirror arrived at several of NOW's rules independently, which is the best
possible sign for a fold-in:

- **Element-first by contract** — no method takes screen coordinates, so chrome
  geometry stays inside the service as calibration rather than API. That is
  rule 2, in different words.
- **Every act reports its `mechanism` and `availability`**, so an emulator-only
  path degrades honestly instead of silently. That is rule 4 and typed
  unavailability.
- **PPC-only on purpose** — one target, so the guest's Open Transport path
  avoids the 68K ASLM blocker. NOW already has vocabulary for a capability one
  guest does not serve.
- **The renderer never sees the wire**; one client owns it. NOW solved the same
  contention differently, with the host owning the connection, but the
  instinct is the same.

## Portable in the other direction

Two things NOW fixed this week that Mirror still has:

- **A build stamp cannot confirm a deploy** — `kBuildStamp` is
  `__DATE__ __TIME__` in one file, so changing another ships an unchanged
  stamp. NOW solved this on 2026-07-30 with an optional `build` on `hello`
  sourced from a function rather than a `#define`, so a constant cannot be
  inlined and close the seam.
- **Source-scanning gates that read their own comments.** Mirror has its own
  gates; [source-text-gates.md](../source-text-gates.md) and the shared
  comment-stripping reader apply directly.

## Stop conditions

- **Any wire work begins before the streaming decision.** It will be reshaped.
- **A second extension appears**, or a second inbound connection. Both are
  charter violations with reasons attached.
- **`portal` gets folded while still in flight.**
- **The scene IR is designed against upstream's moving copy** rather than
  against a version it has declared.
- **A Mirror mechanism is copied rather than fitted.** The instruction is
  Mirror-shaped families in NOW's conventions; a transliteration passes review
  and rots at the first divergence.

## Open questions

- Does the guest app's walk live in NOW's guest, or does NOW's guest gain a
  Mirror *module*? The guest already has modules; this may be one.
- Does the Mirror module's agent surface reuse the twenty-six-row projection
  registry, or does a scene need something the row model cannot express? The
  act verbs look like ordinary rows; the scene stream does not.
- What does the host module show when the extension is absent or its planes are
  unarmed? The Agent module's resting state was the hardest thing to get right
  in the last slice, and this one has four states to say.

## Corpus impact

`corpus_impact: none` — intent only. The measurements this rests on are already
recorded (`postevent-modifiers-need-ppostevent`,
`now-four-face-capability-cost`), and Mirror's own findings live in its
repository.
