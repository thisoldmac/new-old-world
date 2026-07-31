# Streaming a scene

**Date:** 2026-07-31 · **Status:** design note, nothing built · **Decides:**
whether a Mirror scene rides the streaming bracket M3 just landed

A snapshot of reasoning, not of code. Where this and the code disagree, the code
is right; where this and [open-issues.md](open-issues.md) disagree, the ledger is
right. The companion is
[the fold-in plan](plans/2026-07-31-007-feat-now-mirror-integration-plan.md),
whose M4 is the section this note exists to answer.

## The question, and why it is now specific

Until 2026-07-31 the question was "how does NOW carry something continuous",
which had no answer because NOW had no continuous mechanism. It has one now
(`claude/stream-projection`), and the answer it gave was deliberately narrow:

> **A frame IS a capture.** Between `stream.start` and `stream.stopped` the
> guest sends frames as ordinary capture transfers, reusing the capture types
> whole, because *"inventing a second picture type for the same bytes would be
> two vocabularies for one thing."*

That sentence generalises for **pictures**. It does not generalise at all for a
Mirror scene, which is semantic structure — windows, controls, menus — and never
bytes of a picture. So the open question is exact:

**Does a scene reuse the bracket, or does "a frame IS a capture" have to become
"a frame is one of two things"?**

The rest of this note argues that both of those are the wrong shape, that a
third one is better, and that the reason to prefer it is not elegance but the
fact that **nobody has measured anything this decision depends on**, so the
right choice is the one that survives being wrong.

## What is actually settled

Facts, with where they come from. Everything else in this note is marked.

| Fact | Source | Class |
|---|---|---|
| A frame is a capture transfer; `capture.begin`'s id is the stream id | `contract/asyncapi.yaml` `hostControlsStream`, `wire.c` | decided, in code |
| The lane is one wide; `capture.request` and `capture.offer` are refused while a stream runs | same | decided, in code |
| Ownership is a 5 s pid-liveness poll **and** a 60 s lease renewed by any stream call | `dda5615`, `55b6f3e` | decided, tested, never met a companion |
| Default `minIntervalMs` is 1000; absent is not offered on the agent row | `5733b5d`, `71d1adc` | decided; the number itself was argued, not measured |
| **Control frames cap at 4 KB** | `contract/wire_limits.h`, `asyncapi.yaml` (file listings paginate for this reason) | decided, enforced both sides |
| A capture costs **0.5–0.6 s** on the 1400c | `docs/metal-and-ux-review.md` §8 | measured, metal |
| Whether a frame off an open bracket is cheaper than that capture | — | **unmeasured, and it is the bracket's entire premise** |
| Mirror's semantic walk costs **~2.1 ms per poll**, a scene of **13980 B** | `mirror/docs/STATUS.md`, on a session-private mac99 clone | measured, **emulator**, **and it is upstream's guest, not NOW's** |
| Encoded scenes in upstream's fixture corpus run **1.9 KB – 23.7 KB** (raw guest replies to 70 KB) | `mirror/host/MirrorKit/Tests/.../Fixtures/*` | observed |
| Upstream's live mirror is built on **polling** (`ScenePoller`), not on a push stream | `mirror/host/MirrorKit/Sources/MirrorKit/ScenePoller.swift` | observed in shipped code |

Two of those rows do most of the work below and are easy to skim past: **a scene
does not fit in a control frame**, and **a scene has no expensive capture to
amortise**.

### About the moving IR

Per the plan's stop condition, nothing here is designed against upstream's
field-level schema. What is used is the **shape and size class** only: a scene
is a tree of a few kilobytes to a few tens of kilobytes, carrying its own
version stamp, a sequence number and a capture time. Upstream declared a v1
freeze on 2026-07-31 (`mirror/docs/IR-V1.md`, on `lane/h1-ir-freeze`) with an
additive-within-major discipline — which is a good sign but is not Michelle
saying it has landed, so this note still treats it as moving.

**[What changes if the IR changes](#what-would-change-my-mind)** is a section
rather than a caveat, because for this decision it is short and specific.

## The options

### A — reuse the bracket, make the frame a union

A frame becomes "a capture **or** a scene", discriminated per message. One
bracket, one lease, one ownership model, one lane, one thing to explain.

The cost is not the union itself, it is where the union sits. Every consumer of
a frame — the host's listener, the projection, the live view, the tests — has to
branch on every frame. And the bracket's own vocabulary is pixel-shaped:
`stream.start` **requires** `depth`, and carries `pack`, `predictive`,
`interlace`; `stream.refresh` means *send the next frame whole rather than as a
delta*. On a scene stream those are between meaningless and actively wrong, and
a required `depth` on a scene stream is a field the sender must invent a value
for. Fields that must be filled in with a lie are the defect class this project
already named (`two-halves-never-met-in-a-test`, from the other direction).

### B — a second continuous mechanism

`scene.start` / `scene.stop` / `scene.refresh`, its own id space, its own
ownership rule, its own lane policy.

This is the thing M3 existed to avoid having two of, and the objection is not
aesthetic. Ownership is the hard part of a bracket and it took a mutation audit
to get right once — the two guards that answer at different moments, the lease
renewal that had to move above the stage guard because *"the lease is about
presence, not success"*. A second mechanism means either re-deriving that or
sharing it, and if it shares it, it was never a second mechanism; it was option
C with extra message names.

### C — one bracket, subject chosen at `stream.start`

The union moves off the frame and onto the **bracket**: `stream.start` gains a
subject (`screen` by default, `scene`), immutable for that bracket's life.
Everything that made the bracket hard is shared unchanged — the id, the lease,
the pid liveness, the lane, `stream.stop`/`stream.stopped`, host ownership,
one-at-a-time. What differs is only what the guest sends between start and
stopped.

The vocabulary rule survives intact rather than being reinterpreted: it narrows
honestly to **"a picture frame IS a capture"**, and a scene frame is a scene,
with one vocabulary per thing still true. A receiver knows from `stream.start`
what will arrive and never branches per frame. Pixel tuning stays on the picture
subject and a `scene` start carrying `depth` is an error **at start**, which is
where an error can still be reported to the caller, rather than a field silently
ignored 400 frames in.

### D — no bracket for scenes at all: a bounded call, polled

`mirror.scene` as an ordinary request/response verb. No bracket, no lease, no
ownership rule, no continuous mechanism, no mode.

This deserves more respect than it usually gets, because **it is what upstream
actually built**: `ScenePoller` is a poll, and the live Platinum mirror a human
watches is driven by it. It is also the shape the agent surface already assumes
— the 1000 ms default pace exists precisely because *"an agent reads one frame
per call"*.

Its problem is the 4 KB control-frame cap. A bounded call can answer with a
scene only by paginating it (the file-listing pattern, `cursor` + 16 rows) or by
sending it as a transfer. Paginating a **tree** is materially worse than
paginating a flat listing: the consumer reassembles, and the scene can change
between pages, so a reassembled scene is a picture of no single moment — the
exact defect `seq` and `capturedAt` exist to make visible. Sending it as a
transfer means it takes the lane, briefly, exactly as `capture.request` does.

So D is not "the free option". D is "the scene is a transfer, initiated by a
bounded call."

### The shape that was hiding

Once D is stated that way, C and D stop competing, because **capture already has
both of them**: a bounded `capture.request` for one picture, and a bracket for
many, delivering the same bytes over the same lane under the same
one-at-a-time invariant. Two paths, one payload vocabulary, one lane.

A scene wanting the same pair is not a new mechanism. It is the existing pattern
applied to a second subject — which is what *"Mirror-shaped families in NOW's
conventions"* asks for.

## Recommendation

**Give a scene the same pair capture already has: a bounded one-shot scene
request, and — only if measurement says it is needed — the same bracket with its
subject chosen at `stream.start`. Build the one-shot first and ship nothing
continuous for scenes until a number justifies it.**

Do not make a frame a per-message union (A). Do not build a second bracket (B).

The reasoning, in the order it actually matters:

**1. The bracket's premise does not transfer to scenes, and that is the whole
argument.** A picture bracket exists so that a frame is *waiting* rather than
*starting*, against a capture measured at 0.5–0.6 s. There is no equivalent cost
for a scene: upstream measures the semantic walk at ~2.1 ms. Even allowing that
2.1 ms is emulated PPC, upstream's guest and not NOW's, and that NOW's walk (M5)
does not exist yet, the gap is two to three orders of magnitude. A bracket that
amortises nothing is a mode with no payoff, and *"this is a mode, not a cheaper
capture"* — the sentence in the stream row's own tool description — is exactly
the thing that would be untrue in the other direction here.

**2. A scene stream is mostly empty frames by nature, and NOW has already been
bitten by that.** The guest-side fps floor exists because an unchanged screen
produced a ~150-byte control pair that nothing throttled, and the guest flooded
the wire. A scene is worse: structure changes when a window moves or a menu
opens, and an idle desktop produces an *identical* scene indefinitely. A picture
stream at least has a cheap "nothing changed" answer. A scene stream's honest
one is to send nothing, at which point it is a subscription with no traffic —
and a subscription with no traffic is a poll the guest is paying for.

**3. The lease cadence mismatch dissolves under the pair and does not under
reuse-alone.** The 60 s lease is renewed by any stream call. A picture-watching
agent calls constantly; an agent *reading* a scene acts on it — click, wait,
read again — and a 90-second gap is ordinary, not idle. Under a shared 60 s
lease that bracket dies mid-session and the next call fails on an unknown id,
which reads as a bug to the caller and is a correct guard doing its job. The
tempting fix is a different lease for scenes, which is a second ownership policy
wearing the first one's name. The pair fixes it for free: the sparse agent uses
the one-shot and holds nothing; the bracket is left to the continuous consumer
(the human live mirror) whose cadence renews it naturally.

**4. The lane cost is real but is bursty, not saturating — and the one-shot is
what keeps it that way.** *No file transfer while a scene streams* is a much
heavier product statement for a mirror session than for a screenshot: a mirror
is minutes to hours, a screenshot is a second. Under the recommendation, an
agent reading scenes never holds the lane for more than the tens of milliseconds
a 2–24 KB transfer takes, so the statement applies only to a **human watching a
live mirror**, where it is defensible for the same reason the greyed-out Capture
button is: it is a mode, and the UI says so. Note for later, and **not** a
change to make now: a scene stream is idle on the lane between frames, so a
future policy could let a file transfer interleave. That would break the
one-transfer-at-a-time invariant, which has held everywhere and is load-bearing
in both guests. It needs its own argument, not a footnote in this one.

**5. Choose the shape that is cheapest to be wrong about.** Every number this
decision wants is missing: no measurement of NOW's scene walk on any machine, no
measurement of the picture bracket's own premise, and a default pace that was
argued rather than measured. In that state the correct move is not the shape
that would be best if the guesses are right, it is the one whose reversal is
cheap. Adding a subject to an existing bracket is one field and a start-time
validation; removing it later is the same. A per-frame union is a branch in
every consumer that never fully comes back out, and a second bracket is a second
ownership rule to maintain forever, including the parts nobody remembers are
subtle until the mutation audit finds them again.

### What the recommendation does not decide

- **Whether a scene is served by NOW's guest app or by a guest module.** Open in
  the plan; nothing here forces it.
- **How a scene is chunked as a transfer.** It is a transfer because of the 4 KB
  cap, and that is all this note claims.
- **Whether the MCP surface is one row or two.** That is a projection choice.
  The projection may address, authorise, bound and render; it does not get to
  decide this, and it must not be where the wire shape is settled.

### Two carried rules, restated for scenes

NOW's prior art transfers with one substitution each, and both should be written
into whatever implements this:

- **Empty frames need a floor.** For a scene the floor is not fps, it is
  *identity*: an unchanged scene must not be re-sent whole. Upstream already
  carries `seq` and `capturedAt`, which is the material for saying "same scene,
  newer moment" cheaply.
- **A decimated capture must never leave as a keyframe.** The scene analogue is
  sharper and more dangerous: **a partial or failed walk must never be delivered
  as a complete scene.** A missing app is not an absent app, and a process whose
  anchor was stale is not a process with no windows. Upstream reached the same
  conclusion independently — `apps[].error` and `meta.errors` exist for it, and
  `AMBIGUOUS` in NOW's own oracle is the same instinct: absence is not a value.

## What would change my mind

Named specifically, because a recommendation without them is a preference.

| If this turns out to be true | The answer becomes |
|---|---|
| NOW's own scene walk on a 1400c costs on the order of a capture (say >200 ms), **and** the guest can walk ahead of demand | **C** — the bracket earns its keep for scenes exactly as it does for pictures. Build the subject field; the one-shot stays as the sparse path. |
| The picture bracket's own premise fails on metal — a frame is *not* meaningfully cheaper than a 0.5–0.6 s capture | The bracket's reason for existing is wrong for pictures too. Nothing should be added to it until that is resolved, and this note's answer is unchanged only by accident. |
| The IR reliably encodes **under 4 KB** for realistic desktops | **D in its pure form** — a scene becomes an ordinary control message, no transfer, no lane, no bracket, and the lane statement disappears entirely. This is the single largest simplification available and it is decided by a number nobody has produced. Upstream's own corpus says no (1.9–23.7 KB), but that corpus is seven fixtures. |
| The IR grows a pixel-bearing plane on the wire (islands, content-plane ops) | More transfer-shaped, not less; **C** gets stronger and the "scene is not a picture" framing weakens, because some of it would be. Upstream deliberately excluded island pixels from the wire as of 2026-07-31; if that reverses, revisit. |
| A structural **change signal** becomes available on the guest (a hook that says "something moved") | Push beats polling on latency, and the bracket becomes the natural home for it. Nothing like it is built; NOW's jGNE filter is the position from which it is conceivable. This is the strongest future argument for **C** and it should not be pre-built. |
| Michelle wants a human live mirror before an agent scene read | Order flips, not shape: the continuous consumer is the one that wants the bracket, so **C** lands first with the one-shot following. The recommendation's *shape* is unchanged either way, which is a point in its favour. |

**What would not change it:** the IR's field set moving. Nothing above depends
on which fields a scene carries, only on how large it is, that it stamps its own
version and moment, and that it is structure rather than pixels.

## The honest confidence statement

The picture bracket rests on an unmeasured premise, and this note's argument for
scenes rests on **that same missing measurement plus one emulator number from a
different codebase**. It is not a stronger position than M3's; it is a weaker one
argued from a wider gap. What makes the recommendation safe is not confidence in
the numbers, it is that the recommended shape is the cheapest to reverse when
they arrive — which is the reason to state it that way rather than to claim more.

Nothing in this note has been built, run, or seen by a Macintosh.

## Corpus impact

`corpus_impact: none` — **no new measurement was taken.** This is a design note
that argues from facts already recorded: NOW's own metal capture cost and the
control-frame cap are in this repository, the streaming decisions are in
`docs/open-issues.md` and in the contract, and Mirror's ~2.1 ms poll and its
fixture size class are measurements belonging to upstream's repository, cited
here rather than restated as ours.

The claim that *would* be a finding — how much a semantic scene walk costs on a
PowerBook 1400c, which is what decides whether a scene ever wants a bracket — is
**unmeasured**, by us and by upstream on metal. A finding is owed the moment
that number exists, and it belongs beside the one M3 already owes
(`metal-and-ux-review.md` §8): the two are the same experiment run against two
subjects, and running them together would cost one session rather than two.
