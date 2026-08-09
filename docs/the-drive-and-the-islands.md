# The drive, and the islands underneath it

**2026-08-07.** Michelle drove the round-9 stack for about thirty-two
minutes — the first sustained human drive of this arc — and reported
fourteen symptoms. Correlating them against her own logs found four
mechanisms. Then tracing one of them found a fifth thing that calls a
large part of this arc's evidence into question.

This document exists to be referenced later. Her findings are recorded
verbatim first, because they are the primary source; the analysis is
mine and is marked as such.

---

## Part 1 — what she reported, in her words

- Sherlock doesn't fully render, at least not consistently; components
  were missing even after letting the machine settle. Came back after a
  few minutes and it had rendered more. Layout still messy. Double-click
  on search results fails. Text input works, but the I-beam cursor never
  renders over the text box.
- The TLS error box when opening MSIE is hatched over. Moving the modal
  shows the OK button briefly appear before being replaced by a hatched
  box. Clicking the hatched box does dismiss it.
- The button pressed state is not showing on the mirror. Should apply to
  all buttons, including title bar buttons.
- Closing some Finder windows takes far longer than it should for an idle
  machine.
- Switching a Finder window to list view prints icons in a list on top of
  the list. Persists across close/reopen and after the draw settles. List
  view items remain unselectable.
- Finder item icons draw their label twice. **Edit:** the icon is being
  selected *underneath* — the whole icon is drawn twice, not just the
  label. "no wonder its so slow."
- Icon drag fails on "nothing said where it is".
- Some Finder windows open with a hatched background and no info bar.
- Control panels' icons are missing.
- Set Time Zone list never renders (but the pending state on Cancel is
  visible).
- Icons inside Finder show no selected state; desktop icons do.
- Scrollbar buttons work; click-and-drag on the slider does not. Redraw
  on scrolling is brutal — the guest scrolls almost instantly, the mirror
  takes 10–30 s.
- Extensions Manager shows an empty list.
- Double-clicking a desktop text file opens SimpleText behind the Finder
  windows; bringing it forward takes an unreasonable time and it arrives
  completely hatched.

And her framing, which turned out to be the load-bearing question:

> We still have multiple planes competing for render. I thought we had
> settled this by having just one uniform set for interiors being passed
> into the mirror rather than it being fed planes as they arrive?

---

## Part 2 — what her logs say (measured)

Sources: `~/Library/Logs/now-logs/2026-08-07 183049.log` (her session, 91
lines) and `~/Library/Logs/NewOldWorld/acts.log` windowed to her guest
build `2af13c079980`.

**A measurement trap, recorded because it caught me first.** `acts.log`
spans days and its lines carry no date. A first pass windowed it by clock
time, pulled in decodes of 75–109 seconds, and attributed them to her.
They belong to an earlier session. **Window it by guest build.**

### The act plane has one request cell

> `ctlact part 20 … refused: another act is already in flight — this
> Mac's act plane has one request cell and it is taken. Nothing was
> written.`

Nine refusals in ninety seconds while she worked a scroll bar.
Interaction does not queue, it refuses. This is the sluggishness on
closing windows and fronting SimpleText — not a render problem.

A third outcome appears ~25 times, distinct from success and refusal:
**`the guest answered without a dispatch row`**, on parts 10, 20, 21.

### The scrollbar thumb was never dispatched

Parts 20 and 21 (arrows) appear ~25 times. Part **129**, the indicator,
appears **zero** times. `ctlact` is a click verb; a thumb needs
press-move-release. Nothing was ever sent for it.

### Nothing confirmed, all session

Every `winact` reads `settlement=dispatched-but-unconfirmed`. Zero
confirmations in thirty-two minutes. That is the KW-06 honesty fix
behaving correctly — and it means the host never learns an act landed, so
a press has nothing to settle on.

### The render tail, her session only

| | median | p99 | max |
|---|--:|--:|--:|
| host decode | 23 ms | 3,152 ms | **7,527 ms** |
| guest round-trip | 16 ms | 2,100 ms | **14,743 ms** |

~22 s worst case, matching her "10–30 s". **7.5 s to decode 3 windows and
49 elements** is the structurally wrong number; the guest's own phase
counters are in microseconds.

### The Finder item roster does not arbitrate against the machine's ink

`SceneRenderer` arbitrates the display list against **controls**
(`semanticOwnsDisplay`) and **dialog items** (`dialogItemOwnsDisplay`),
and carries the comment *"P3 owns unstructured content, while P2 owns
concrete drawing wholly."*

**There is no equivalent for `win.items`.** The only exclusion involving
`items` is against the pixel island. So a window holding both the
machine's ink and our icon roster draws both — icons twice, labels twice,
icons over list rows, and the cost.

---

## Part 3 — the islands (analysis; mine, not measured by her)

Tracing that one exclusion found `PixelIsland`. The archaeology:

- **31 July, `918aa853`** — an agent ported MirrorKit *into* NOW's host
  app, "verbatim first". That port put `PixelIsland.swift` at
  `now-host/Sources/MirrorKit/`.
- **1 August, `0443ab2b`** — that port was thrown away, for stated
  reasons: *"an empty menu bar, menus that drop but do nothing, nothing
  launchable, clickable, movable or resizable"*. Mirror arrived **whole
  as a vendored subproject** instead. That commit added **twelve** copies
  of `PixelIsland.swift` — one real, plus one in each of five nested
  agent worktrees that came along as passengers.
- **1 August, `bcc00f7d`** — the port's ~250 files were deleted. The
  abandoned copy is genuinely gone.

So the live island at `now-host/Packages/MirrorKit/` is **Mirror's own
implementation**, arriving by the route that was chosen deliberately —
not a survivor of the abandoned port. Nobody decided to cross NOW's gate
on over-the-wire pixels. **The gate was bypassed by the shape of the
import**: vendoring a sibling whole imports its decisions, including ones
this project had explicitly deferred.

Michelle's ruling, 2026-08-07: **the pixel islands lie.** They are to be
referenced as prior art only, for a later deliberate re-implementation.

### Why this is worse than one unwanted feature

`ScenePoller` populates `window.island` from `wire.captureRegion(...)` —
**real framebuffer bytes fetched over the wire and composited into the
render.**

That is the reason the gate existed. And it means:

> **Wherever an island was covering a window, a comparison of "our
> render" against "the guest's pixels" was comparing the guest's pixels
> against themselves.**

The measurement and its subject were the same bytes. That is the
thirteenth instance of this arc's most-repeated pattern — *the
instrument's normal mode of operation is the one condition under which
the defect cannot appear* — and it is the most expensive one, because it
does not corrupt a single gate. It potentially inflates **every render
score this arc has produced**.

### What is and is not at risk — to be derived, not assumed

**This must be established, not guessed.** The island is gated behind
`if win.items == nil`, so it never applies to a window carrying a named
item roster. Sweep D's title-bar work measured chrome the island does not
cover. So the correct claim is *some* evidence, not all of it — and
nobody yet knows which.

The honest questions, in order:

1. Which captures in the corpus have a non-nil `island`?
2. Which scored rows rest on those captures?
3. What do those windows look like with the island gone?

The third is the one that matters, and it is why Michelle's instruction
is to rip them out first and spin a fresh stack: **the point is not to
fix the render, it is to find out what the render actually was.**

Her framing, which is the reason for the gate in the first place:

> how much of our supposed progress (and issues for that matter) have
> just been pixels literally plastering over the work we're trying to do

### The durable rule

*"Verbatim first"* is a reasonable way to move a subproject and its risk
is exactly this: **a gated feature arrives as a passenger.** A wholesale
vendoring wants an inventory — what came with it, and what of that this
project had already decided against. That check would have cost minutes
on 1 August and would have caught this before it touched a single score.

Related: every commit in this repository is authored as the human, with
the agent as co-author. Attribution in the log is therefore not evidence
of who made a decision — the commit *body* is, and in this case it was
honest and complete. That is worth preserving.

---

## Part 4 — what the islands actually touched (derived 2026-08-07)

Part 3 asked three questions and said they must be established rather than
guessed. Here are the answers, and the first one is not the one the
analysis expected.

### 1. Which captures in the corpus carry a non-nil `island`?

**None. Not one, and none could have.**

Two facts settle it, and each is derivable rather than remembered:

- **`island` was populated only by `ScenePoller.attachIslands`.** Every
  construction of a `ScenePoller` in this tree is in Mirror's own
  development tooling — `MirrorApp/main.swift` (×2), `MirrorApp/Serve.swift`,
  `MirrorApp/Battery.swift`, `MirrorOracleKit/LiveMirrorController.swift`.
  **`now-host` constructs none.** (`grep -rn 'ScenePoller(' now-host/Sources`
  is empty; `GuestScreenIsOneAnswerGateTests` already asserts the pairing
  over the same set.)
- **NOW's host builds its scenes from NOW's own wire**, not from
  `ScenePoller`, and `island` was never encoded — so a scene decoded from a
  guest reply always had `island == nil`.

Measured against the corpus itself (`~/Lab/Assets/now-mirror-assets/`):
**107 scene JSONs, 148 scene records, every one `"source": "peek"`.** Not a
single `axtree` or `observe` scene — those are the two planes `ScenePoller`
produces. `grep -rl island --include='*.json'` over the whole corpus
returns nothing.

### 2. Which scored rows rest on those captures?

**None.** Sweeps A, B, C and D and the integration rounds all ran
`spin-up-ppc` plus the NOW host app (their `provenance.json` files record
it), so every scored row was taken over a render that had no island in it
to begin with.

| Claim | Capture | Islanded | Status |
|---|---|---|---|
| Sweep A rows | `sweep-2026-08-07-a/agent/*.json` | no — `source: peek` | **unchanged** |
| Sweep B rows | `sweep-2026-08-07-b/**` | no | **unchanged** |
| Sweep C rows | `sweep-2026-08-07-c/**` | no | **unchanged** |
| Sweep D (title-bar chrome) | `sweep-2026-08-07-d/**` | no — and the island never drew chrome anyway | **unchanged** |
| Integration rounds 1–9 LOOKs | `019-integration*`, `018-integration` | no | **unchanged** |
| Michelle's 32-minute drive | host build `2af13c079980` | no | **unchanged** |
| Mirror's own `MirrorApp --islands` / `serve` `shot` renders | not in this corpus | **yes** | **void, and none of it was ever cited here** |

**So the fear in Part 3 was larger than the fact, and saying so is the
point of deriving it.** The pixel islands were live in the *sibling
project's own development oracle*, not in NOW's product. What they voided
was Mirror's own tooling output, which this arc never scored against.

That is still worth the removal, and for two reasons that have nothing to
do with rescuing old scores: the code was in the product's render path one
`ScenePoller` away from being used, and a rule that is not enforced is a
rule that gets crossed by the next import. It is now gated
(`GuestPixelsGateTests`).

### 3. What do those windows look like with the island gone?

Unchanged in NOW's host, necessarily — see above. The visible difference
is confined to Mirror's own dev tool, where a window with no item roster
now draws the honest "content unavailable" hatch instead of a photograph.

### The correction to Part 3, stated plainly

Part 3 said the islands "potentially inflate every render score this arc
has produced". **They did not inflate any of them.** The reasoning was
sound and the conclusion was wrong, because it reasoned from the code
without checking which binary ran. That is worth keeping visible: the
analysis and the derivation disagreed, and the derivation won.
