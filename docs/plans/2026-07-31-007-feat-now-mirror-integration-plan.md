# Folding Mirror into NOW

**Date:** 2026-07-31 · **Status:** M1 built, M2 spiked to *packages*, M3 built,
M4 analysed — all TESTED, none metal-verified; M5–M6 intent ·
**Namespace:** `claude/`

**Upstream landed 2026-07-31** — all four lanes on Mirror's `main`, IR frozen at
v1 and declared. M4's blocker is gone; see the section immediately below. What
remains held is **verification**, not work: the whole slice is waiting on one
unified metal pass rather than being struck off piecemeal
([metal-and-ux-review.md](../metal-and-ux-review.md)).

A snapshot of intent, per [README](README.md). Where this and the code disagree,
the code is right; where this and [open-issues.md](../open-issues.md) disagree,
the ledger is right.

## The upstream has landed — 2026-07-31

**Superseded, and the section below is kept because its caution was the right
call and its reasons still explain the sequencing.** All four lanes are merged
to Mirror's `main`, and the thing this plan was actually waiting on has
happened: **the scene IR is frozen at v1 and *declared*.**

That was the gate, stated as a stop condition — *"the scene IR is designed
against upstream's moving copy rather than against a version it has declared."*
It now has a version it has declared:

- `irVersion` is a **top-level key of the result**, beside the payload, so a
  consumer reads the gate without decoding the thing it guards. The scene body
  carries the same number as its self-stamp and the two cannot diverge without
  editing source.
- The **consumer duty is written down in order**: read `irVersion`, refuse an
  unknown major, *then* decode. NOW's families should say the same thing the
  same way rather than inventing a second discipline.
- Frozen / additive-within-v1 / breaking are each defined, with the additive
  case explicitly *not* bumping the version — the same accretive rule
  `peek_table.h` already applies to the in-memory seam.

**The act plane is now metal-shaped end to end**, which is the single most
important consequence for us. `WINDOW_ACT` moves, resizes, zooms and closes by
answering the application's own `FindWindow` call — guarded and armed like
`MenuSelect` and `TrackControl` — with **no simulated mouse motion anywhere**,
and QMP is out of the act plane entirely. 20/20 on each of four ops, re-verified
on the *merged* build rather than the branch build. That removes the last
emulator-only mechanism, so M6's act projections do not inherit an emulator
dependency and do not collide with this project's no-host-side-cheating rule.

Also landed: `TEXT_GET`/`TEXT_SET` (20/20, no-hijack 0/20), folder windows as *a
model rather than a photograph* (40/40 against the Finder's own oracle), and an
`apple-event` verb.

**One gap upstream states about itself, and it is ours too:** no fixture
exercises the content plane (`windows[].display[]`). That is the same
QuickDraw-op territory our P3 probe (M2) exists to reach, so the two meet there
rather than in the parts already covered.

## The upstream was still moving — kept for its reasoning

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

So AXPeek is not an INIT to port.

**And it is smaller than even that — checked 2026-07-31, against the source
rather than the READMEs.** `NowPeekAnchorSlot` already carries `a5`,
`window_list` **and** `menu_list`, and `capture_anchor()` already fills all
three from the jGNE filter, with a commit protocol that invalidates the stamp
first and writes it last. The claim that this plan made a paragraph earlier —
"two more roots in a row that already carries one" — was wrong: the row already
carries all three, and the comment beside it cites the same
`observe-process-local-ui` finding AXPeek was built from.

The actual delta is **one field and one absent layer**:

- **`stack_base`.** AXPeek samples `LMGetCurStackBase()` alongside the three
  NOW already has. NOW's slot has no equivalent.
- **The oracle.** AXPeek pairs its capture with a matching layer
  (`ax_oracle_match`) that validates a sample against the live Process Manager
  partition — bounds-checking `currentA5` against the partition's range — and
  answers **OK / AMBIGUOUS / MISMATCH / STALE / NOT_FOUND** rather than a
  pointer. NOW has nothing equivalent, deliberately: its slot comment says *"the
  extension never fills PSN; the app correlates A5 to PSN."*

That second point is the same split both projects arrived at independently, and
NOW's charter states it as a rule: **foreign-memory reads live in the
application.** The extension publishes addresses; *following* them is
application code, "where a bug is fixed by copying a file instead of a reboot."

So M1 splits accordingly, and the halves land in different places.

## The blocker nobody has resolved — **resolved 2026-07-31**, see M3

Kept as written because the reasoning still holds and the answer is easier to
judge beside the question. The bracket landed on `claude/stream-projection`; what
it decided, and how that reshapes M4, is in the sequencing below.

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

### M1a — `stack_base` in the anchor slot — **built 2026-07-31** (`40f2b1f`)

**First because it is settled, needs no wire and no host, and is additive to a
versioned struct with a defined absence reading.** One field: sample
`LMGetCurStackBase()` beside the three roots the filter already captures.

The slot grows 24 → 28 bytes, so `kNowPeekAnchorFormatV1` becomes `V2` and the
static asserts that pin every offset move with it. Readers require their plane's
format and `length >=` what they read — the prefs-record rule the header already
applies — so a V1 reader against a V2 table is a defined case rather than a
crash. Three toolchains compile that header, which is the safety net: an offset
mistake fails loudly at compile time rather than quietly on a PowerBook.

Unblocked today. Mirror's `guest/extensions/axpeek` has not moved since
2026-07-30.

**As built:** the slot grew to 28 bytes at format `V2`, `capture_anchor()` fills
`stack_base` **before** committing the stamp (its position after the stamp in
the struct says nothing about write order — the stamp is the seqlock's commit),
and the static asserts moved with it. Building it also turned up that
`scripts/build-guests` **had never compiled `ext/` at all**: the one piece of
code here that runs at boot, in every process's context, and whose failure needs
a shift-boot to recover was the one piece no gate ever built. It builds now.

### M1b — the oracle, in the application — **built 2026-07-31** (`4d8bba6`)

Map an anchor to the live Process Manager partition and answer **OK /
AMBIGUOUS / MISMATCH / STALE / NOT_FOUND** rather than a pointer. Application
code by charter, not resident code.

Worth taking Mirror's *answers* rather than its implementation. The five
outcomes are the interesting part — particularly that `AMBIGUOUS` exists at
all, which says two processes can present as one match and the honest response
is to refuse rather than pick. That is the same instinct as everything the last
slice landed: absence is not a value, and a guess is not an answer.

**As built** — `now-guest-ppc/src/peek/peek_oracle.{c,h}`, with the mapping to
the reader's vocabulary in `peek_read.c`:

- **Toolbox-free**, taking the partition bounds as arguments rather than calling
  the Process Manager. That was not tidiness: it is what makes all five verdicts
  reachable from a native host test. `AMBIGUOUS` on a real machine needs a dead
  process whose partition was reused, which no test can arrange.
- **`STALE` is reported, never refused**, and `peek_read.c` passes no age gate at
  all — preserving the rule that reader already followed. Window state is only
  ever as fresh as the target's last pump; a clock cannot improve on that, so
  the age is rendered beside the answer instead of suppressing it.
- **`MISMATCH` is unreachable on a V1 table**, gated on the format word rather
  than on `stack_base` being nonzero. One root cannot disagree with itself, and
  the honest reading of an absent second root is "cannot tell", not "wrong".
- The two new states **render as their own words** ("unclear (two matches)",
  "stale anchor") rather than falling through the Processes module's switch
  default to `-`, which claims no plane and would have been a third wrong answer
  in the same path.

**One assumption is unmeasured** and it is now item 11 of
[metal-and-ux-review.md](../metal-and-ux-review.md): that a process's
`LMGetCurStackBase()` lies within its partition. If that is wrong on metal every
process reports `MISMATCH` — a silent, total, *polite* failure rather than a
loud one. The containment check is deliberately loose so that only a value
outside the partition entirely is rejected.

### M2 — QDPeek as its own plane — **probe built 2026-07-31** (`6a054ae`)

Genuinely new, dormant until armed, and the plane model exists for this. Per the
charter: developed as a **throwaway INIT under an honest name** on a QEMU clone
(`tools/mb_rename.py`), folded into the NOW Extension only after its ladder
passes. Planes talk only through the core; no cross-plane calls.

Also settled upstream since 2026-07-30.

**Correction worth making explicit:** this is **P3**, not P2. The charter's plane
list has P2 as *semantic assist* — "may be empty" — and P3 as content: *"QuickDraw
bottleneck hooks, the full Timbuktu move. The riskiest class we would ever ship."*
The existing `kNowPeekTableCapTree` bit is P2's and must not be spent on this.

**As built:** [`prototypes/qdprobe`](../../prototypes/qdprobe/README.md) — a
throwaway INIT with its own name, creator and Gestalt selector, holding no
reference to NOW's table in either direction. Nothing in the shipping extension
changed, which is the point: the charter's "separate failure domain in everything
but the file" costs a directory when taken literally.

M0 answers **one** question — can a 68K INIT's drawing bottleneck be called by a
PowerPC application's QuickDraw? — and everything else about P3 is downstream of
that yes or no. Rung reached: **packages**. Loads, callbacks-run and
survives-cycles are unrun.

**The ladder is blocked on a reader, and the reader should also be throwaway.**
The counters publish through Gestalt `'QDpr'` and nothing reads them, so
"loads at boot" cannot yet be told from "did not load". The guest app is the
wrong place for it: NOW has no verb that reads an address behind a Gestalt
selector, and adding one would couple the shipping app to a spike it is
supposed to be insulated from. A ~100-line standalone app that Gestalts `'QDpr'`
and draws the counters keeps the whole spike in one disposable place.

### M3 — the streaming decision — **answered and built** (`claude/stream-projection`)

**A decision, not an implementation** — it turned out to be both. The bracket
exists: `stream.start` / `stream.stop` / `stream.refresh`, three capability names
rather than one, because *"a bracket you can open and cannot close is not a
capability to hand anybody."* The projection row requires all three.

What it settled, and what each answer costs this fold-in:

- **A frame IS a capture.** Between `stream.start` and `stream.stopped` the guest
  sends frames as ordinary capture transfers, reusing the capture types whole
  rather than inventing a second picture type for the same bytes.
- **The lane stays one wide, and the exclusivity is shown rather than hidden.**
  An agent's stream turns the person's live view on and **greys out their Capture
  button**. So the contention question this plan raised has an answer: nothing
  shares the lane, and the UI says so.
- **Ownership is two mechanisms, because neither subsumes the other** — a 5 s pid
  liveness poll for the companion that died, and a 60 s lease renewed by any
  stream call for the client that lived and lost interest. Pid recycling is the
  seam; the lease closes it.
- **No maximum duration**, deliberately, with the cost stated rather than hidden.
- **`refresh` always sends and waits.** Handing back the newest frame in hand
  would be free and would also be a picture of an unknown moment.

**The premise is unmeasured, and it decides whether the row should exist at
all:** nobody has measured whether a frame off an open bracket is actually
cheaper than a 0.5–0.6 s capture. If it is not clearly cheaper, the row's reason
for existing is wrong.

### M4 — scene families on the wire

Mirror-shaped, NOW-conventioned. The IR is the thing being carried; read
`IR-V1.md` upstream when it settles rather than designing against a moving
target.

**M3 reshaped this rather than merely unblocking it.** The bracket generalises
for *pictures* — its frame type is a capture, by decision. A Mirror scene frame
is semantic structure, not a picture, so the M4 question is now specific: **does
a scene reuse the bracket, or does "a frame IS a capture" have to become "a frame
is one of two things"?** Reusing it means one bracket, one ownership model, one
lease, and a second frame kind. Not reusing it means a second continuous
mechanism, which is the thing M3 was written to avoid having two of.

The exclusivity answer bites here too: a Mirror session holds the one lane, so
**no file transfer while a scene streams**. That is now a known constraint to
design around rather than an open question — but it is a product statement, and
it should be said out loud before it is discovered.

**Analysed 2026-07-31 in [streaming-a-scene.md](../streaming-a-scene.md), and
the answer is neither of the two options above.** The recommendation is to give a
scene the pair capture already has — a bounded one-shot, plus (only if a
measurement demands it) the *same* bracket with its subject fixed at
`stream.start` — and to build the one-shot first. A per-frame union fails because
the bracket's vocabulary is pixel-shaped: `stream.start` *requires* `depth`, and
`pack` / `predictive` / `interlace` are meaningless for structure, so a scene
start would have to fill a required field with a lie. A second bracket fails
because ownership is the hard part, and it is either shared — in which case it
was never a second mechanism — or re-derived.

Two findings underneath it, both checked against the sources:

- **The bracket's premise does not transfer.** A picture bracket exists so a
  frame is *waiting* rather than *starting*, against a capture measured at
  0.5–0.6 s. Upstream measures its semantic walk at **~2.1 ms**. A bracket that
  amortises nothing is a mode with no payoff.
- **A scene is a transfer, not a control message.** The control cap is 4096
  bytes; upstream's own trace reads `axtree (13980 B, 2.1 ms, 1 window, 11
  controls, 8 menus)`. Fourteen kilobytes for a **one-window** scene, three and a
  half times the cap, at the small end of what a real desktop presents. The doc
  lists "do realistic scenes fit in a control frame" as an open question that
  would dissolve the whole problem; that same measured line answers it **no** with
  room to spare, and the question should be treated as closed rather than open.

The non-obvious argument is **the lease**. An agent reading a scene acts on it —
click, wait, read again — so a 90 s gap is ordinary, and the shared 60 s lease
would kill the bracket mid-session. The tempting fix, a longer lease for scenes,
is a second ownership policy wearing the first's name. The pair avoids it: the
sparse agent uses the one-shot, the continuous consumer (a human watching a live
mirror) renews naturally.

**What would change it:** one metal number — what a semantic walk costs on the
1400c. Above roughly 200 ms with the guest able to walk ahead of demand, the
bracket earns its keep and becomes primary rather than conditional. That is the
same experiment M3's own unmeasured premise already owes, with two subjects
instead of one.

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

**`portal`.** Mid-solution upstream, and **actively being worked as of
2026-07-31** — `MENU_INVOKE` is upstream's defect 0. Do not touch it here.

Two of its measured findings already apply to us, though, and neither waits on
the fold-in:

- **Self-disarming is not the guard; identity is.** Measured, and it inverted the
  plan's own assertion: disarming after one use says the patch fires once and
  says nothing about *whose* call it fires on. An armed menu request rode the
  user's own press **18/20**; the control patch, which additionally requires the
  request to name that exact `ControlHandle`, hijacked **0/20**. A bound on time
  or count is not a bound on scope. This lands on **P3**, whose probe currently
  patches whichever port happens to be current while armed — see
  [prototypes/qdprobe](../../prototypes/qdprobe/README.md).
- **A background target never arms** (6/6 timeouts): a suspended process never
  pumps, so anything keyed to a target's own context can only reach a process
  running its event loop. NOW inherits this directly — anchors are captured at
  `jGNE` — and it bounds what identity-scoped arming can ever address. Folding a mechanism while its author is
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

`corpus_impact: none` — **no new measurement**, which is the reason rather than
an omission. M1 is built and tested, but every claim it rests on was already
recorded (`observe-process-local-ui`, `postevent-modifiers-need-ppostevent`,
`now-four-face-capability-cost`), and Mirror's own findings live in its
repository.

The one claim that *would* be a finding — that a process's `LMGetCurStackBase()`
lies within its Process Manager partition, which is what makes a second root
worth carrying — is **assumed, not measured**. It is routed to
[metal-and-ux-review.md](../metal-and-ux-review.md) item 11 with the exact
observation that would settle it, and a finding is owed once that pass runs. A
green build is not evidence about a machine.
