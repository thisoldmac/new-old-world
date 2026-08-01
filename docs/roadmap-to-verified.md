# The road from *tested* to *verified*

**Date:** 2026-07-31, **revised 2026-08-01** · **Status:** phases 1 and 2
done; **phase 3 has not started**

The parity + Mirror fold-in slice landed on `main` at `495f7b1`. It is green —
1130 host tests, 48 native tests, three guest cross-builds — and **not one line
of it has run on a Macintosh.** This document is the route from here to a
product that has actually met the machines it claims to drive.

Four phases, in dependency order. Phase 2 can start now; the rest are sequenced
because each one's failures would invalidate work in the next.

## Where this stands, 2026-08-01

| Phase | State |
|---|---|
| 1 — the honest gaps | **done** 2026-07-31 |
| 2 — finish the MirrorKit port | **done** 2026-07-31, and it grew two things it did not plan for |
| 3 — the emulator pass | **not started.** The next thing to happen |
| 4 — the metal pass | not started |

**The sentence that has not changed since this document was written:**
*not one line of it has run on a Macintosh.* Over 400 commits later, that
is still exactly true. The only metal-verified things in this product —
`now_capture_screen` and the four addressing outcomes, both on the PB1400c
on **2026-07-29** — predate the whole arc.

**Gates as of this revision:** 3/3 guest cross-builds, **69 native tests**,
0 failures. Verified today by running them.

### Two things landed after Phase 2 closed

Neither was in the plan; both change what Phase 3 will see.

- **The act lane.** `MirrorActionDriver` plus
  `AgentIntegrationActControl` — the act rows go out to a guest instead of
  answering `now-act-lane-absent`, and an act does not queue behind an
  open stream bracket.
- **Scene references.** The guest emits `windows[].ref` and
  `windows[].controls[].ref`, minted by the observation layer, bounded by
  a registry epoch, valid for the guest session. A scene that named menus
  and controls and had nothing clickable in it now names what an act can
  address.

### What is still owed, and Phase 3 does not close it

**The pane.** The act path is built end to end and nothing joins a
person's click to it: hit-testing has no caller outside the tests, the
driver has no caller at all, and both host models discard
`windows[].ref`. So **an agent can drive a Macintosh through MCP and a
person cannot drive it by clicking the picture of it.**

This is deliberately *not* a Phase 3 item. Phase 3 asks whether the
mechanism works on a machine; the pane is the affordance on top of a
mechanism nobody has watched work. Building it first would be building an
interface to an unproven thing. Full write-up:
[open-issues.md](open-issues.md), "The last functional gap".

---

## Phase 1 — the honest gaps — **DONE 2026-07-31**

All six closed and on `main`. Kept in full because what each one *found* outlives
the fix, and three of them found something the gap description had wrong.

| # | Gap | Outcome |
|---|---|---|
| 1.1 | The guest's Stop button could not stop a pull | **Done.** `now_wire_get_cancel()` beside `get_cleanup`, and one registration line in `files_create()` — everything else had already been built and was inert for want of a canceller. |
| 1.2 | Three act rows built and unregistered | **Done.** Registered with `.mcp` reached; a call now returns `now-act-lane-absent` rather than a false "host is unavailable". |
| 1.3 | The ported walk had no caller | **Done.** `menubar`, `controls`, `text` and `kind` now cross the wire. |
| 1.4 | The P3 probe could not be observed | **Done.** `prototypes/qdreader/` — and it is Carbon/PPC, so armed at its own A5 the reader *is* the native caller the probe's question is about. |
| 1.5 | `conn_disconnect()` cleaned up no pull | **Done, and it was twice as wide as written** — see below. |
| 1.6 | The Software review section was misfiled | **Done.** Promoted out of the Files heading; three cross-references updated. |

### What Phase 1 found that Phase 1 did not predict

- **1.5 was wrong in this document.** It said `enter_backoff()` cleans five things
  where `conn_disconnect()` cleans none. True, and misleading: **none of those
  five was `g_get`**, so a dropped link leaked the same open temp fork and only
  the 30 s `service_get` timeout ever reached it. Both paths were broken. The fix
  is one shared teardown list, because two lists that must agree had already
  stopped agreeing — appending the pull to both would have rebuilt the defect one
  entry later.
- **The probe silently replaced all rect drawing while armed.** `qdprobe_rect`
  tail-called the previous chain only when `saved_procs != 0`, but
  `patch_current_port` only ever claims a port whose `grafProcs` was `NULL`, so
  that branch never matched a port we had legitimately patched. Every rectangle,
  erases included, fell through to "draw nothing" — while the file's header
  claimed it "never replaces the drawing, only observes it". Fixed with
  `StdRect`, verified as trap `0xA8A0` in the object file. **Nobody read this out
  of the source:** the reader had to be *built to tolerate* it before it was
  obvious the behaviour was a bug. A spike that works around its own subject is
  telling you something.
- **A plane has three states, not two** — absent, empty, populated. The scene
  test builds all three in one document, because an encoder that emits the same
  thing everywhere satisfies any single case alone.
- **Truncation must be attributable or retracted.** `meta.errors` can say
  "windows truncated" because there is one `windows` array; it cannot say *which*
  window's controls stopped early, and a short list reads as a complete one. So a
  control chain that hits its bound drops that window's `controls` key entirely,
  and always records the drop.
- **Window rows needed an address.** Counting along both chains would have
  misfiled every control after the first window skipped for insane bounds —
  quiet, plausible, permanently wrong.
- **A registered row made a true sentence false.** The act clients returned
  "New Old World host is unavailable", correct while only stubs could reach them
  and a lie the moment a real client could. Registration changes what a stub is
  allowed to say.

### Gates at close

**1132 host tests** / 54 skipped / 0 failures · **50 native tests** · 3/3 guest
cross-builds. Nothing has run on a Macintosh.

### Small debts opened by Phase 1

- ~~`wire.c`'s comment still calls the scene "~11 KB of struct"~~ — closed: the
  comment now says ~27 KB and names the failure path as a realistic one.
- The probe's `saved_procs` is structurally always 0, so the chaining branch is
  dead code kept for the day the probe learns to patch an already-patched port.

## Phase 2 — finish the MirrorKit port — **DONE 2026-07-31**

All of it on `main`. What it changed about the *shape* of the fold-in matters more
than the file count.

| | Outcome |
|---|---|
| **2.1** MirrorKit + MirrorKitUI as NOW targets | **Done.** 29 files plus the golden fixture corpus and both upstream test targets. `MirrorApp` did not cross — NOW's host app is the app. |
| **2.2** the `controls` decode defect | **Done, and it was six fields, not one.** Fixed in *our* copy — see below. |
| **2.3** the oracle's missing discriminator | **Done.** Anchor format **V3** carries `cur_ap_name`; a recycled partition stops winning. |
| **2.4** the adapter and the pane | **Done.** `MirrorSceneAdapter` + a **Mirror** module with eight resting states. |

### The upstream repo was never touched, and did not need to be

The roadmap listed the `controls` relaxation as a change owed in `timbottu/mirror`.
Porting made that moot: the fix belongs in **our** copy, which is better, because
NOW's guest omits four planes *conditionally* and only one of them was `controls`.
The port relaxed **six** non-optional collections — `apps`, `windows`,
`menubar.menus`, menu items, `controls`, `meta.errors` — five of which were the
same defect waiting for the next plane our guest learns to omit.

### Absence now survives three boundaries

The three-state rule — **absent** (this producer does not report it) / **empty**
(walked, found none) / **populated** — began as a producer discipline in Phase 1.3.
It now holds at every hand-off:

| Boundary | How |
|---|---|
| guest encoder | omits the key; a test fails if certain names appear at all |
| host decode | `value` + a `…Present` sibling, because `decodeIfPresent ?? []` launders *nobody looked* into *looked, found none* |
| adapter | one primitive returning a **tuple**, so dropping the presence bit is deliberate rather than a `?? []` away |

Each boundary has a mutation that collapses it and goes red. That is the same
claim defended three times by three different mechanisms, which is what it takes
for a distinction to survive a codebase.

### Findings worth carrying

- **A width can be right for a reason the size assert cannot see.** V3's name
  field is 32 bytes because `Str31` fits whole. Mutating it to 30 **still built
  and still satisfied the size assert — the compiler silently padded the slot
  back to 60.** Only the alignment check caught it.
- **Ordering is the argument.** The name check sits last because A5 decides
  candidacy and `stack_base` bounds the same address space from the other end —
  and *both can be satisfied by a partition that was recycled.* The name cannot.
- **`-Warray-bounds` refuses low-memory address constants** under `-Werror`
  (`0x0910`, `0x904`), twice today. Route through a `volatile`. Anyone writing a
  resident that reads a low-memory array will hit it.
- **A resting state needs four fields, not three**: glyph, headline, what is true,
  and **what would change it**. The fourth is the difference between idle and
  broken.

### Gates at close

**1317 tests** across all bundles / 0 failures · **51 native tests** · 3/3 guest
cross-builds. Nothing has run on a Macintosh. (The scene caller took this to
**1332 / 0** on 2026-07-31; the guest cross-builds were not re-run — no
toolchain in that worktree — so 3/3 is Phase 2's number, not a fresh one.)

### The open question Phase 2 asked, answered 2026-07-31

`GuestListener` had **no scene path**. It has one now: `requestScene` sends
`scene.request`, collects the transfer the guest answers with, and hands the
undecoded bytes plus the envelope's `irVersion` to the pane's one door. A
person presses *Look Now* — and, since 2026-08-01, the page also keeps itself up
to date: a control-message probe (`axsnap`) about twice a second, a bulk
transfer only when it reports a change or the drawing has aged past its ceiling,
and a visible Live/Paused switch. The lane argument survived as the *shape* of
that loop rather than as a veto on it. Two resting states were added
(*Looking*, *Not This Time*) and three changed meaning. Nothing has fetched a
scene from a Macintosh — the whole path is exercised against a fake guest on
loopback.

## Phase 3 — the emulator pass — **not started, and next**

**What it is for:** structure, not truth. It catches the things that are broken
everywhere before a scarce machine is booked, and it is free.

> **[emu-readiness.md](emu-readiness.md) is the operator's page and it
> wins.** It was written after this section, against the harnesses that
> now exist, and it carries the runnable order (eight steps, with the
> commands), which harness settles what, and the four preconditions before
> the extension is installed anywhere. The six rungs below are the
> *what-each-one-decides* view and are kept for that. **If the two orders
> ever disagree, follow the operator page** — two orders for one pass is
> the drift this repository refuses elsewhere, and this note is the fence
> until one of them is deleted.
>
> Three things that page knows and this section predates:
> - **The harnesses already exist and are ported** — nine of them, in
>   `scripts/probes/`. This section was written as though the pass needed
>   authoring.
> - **Every one of them is PowerPC-only.** NOW-68K serves 13 verbs and has
>   no act plane, no reference layer and no scene plane, so exactly two
>   cases can be pointed at it.
> - **`actselftest` exists and must run before any act**, because a wrong
>   trap ABI does not crash — it lies.

**Order matters** — each rung's failure invalidates the next:

1. **Both guests launch and dial out.** The 68K guest and the PPC guest, against
   a host on a known port. Nothing else is testable until this holds.
2. **The four addressing outcomes**, now that a second guest can be run: two
   emulated guests on one listener is the only cheap way to exercise
   `notAddressed` / `notConnected` / `sessionEnded` / answered *and* the
   Connections page's two-Mac case.
3. **The capability gate on a real 68K guest** — streaming should be live until
   the first press, then dark with a readable reason. That sequence is the
   honest one and only a machine produces it.
4. **The anchor oracle and the Windows row.** The single most informative
   screen in the pass. *Some* processes reading "stale anchor" is the good
   outcome; **every** process reading it means the stack-base assumption is
   wrong (review §13).
5. **A scene end to end** — request, transfer, decode — once 1.3 is wired.
6. **The NOW Extension at boot**, on a disposable clone, with a shift-boot
   ready before the install rather than after the problem.

**What an emulator cannot settle, and must not be reported as settled:**

- **Any timing.** mac99 does not run at 33 MHz. All three of the measurements
  below are metal-only by nature.
- **Anything about the PB1400c's own hardware** — the PC Card, the display, the
  real MacTCP stack under load.
- **`cis`-class hazards.** The precedent is exact: `cis` passed on the emulator
  and hard-froze the 1400c. An emulator pass is evidence, not proof, for
  anything that touches the machine below the Toolbox.

---

## Phase 4 — the metal pass

Two audiences, one booking. `docs/metal-and-ux-review.md` is the checklist;
this is the shape of the session.

### 4.1 The rules, which are not ceremony

- **Ask before each pass. Per action, not per session.** The machines are shared
  with other sessions and with Michelle's own work.
- **Never reboot, shut down or power-cycle a physical machine without asking.**
  Stage everything, then wait for an explicit acknowledgement.
- **The tiered do-not-touch list** in `docs/22-metal-safety-line.md` binds. `cis`
  is emulator-only — it hard-froze the 1400c and needed a physical reboot.
  `sertx` soft-wedged the harness and its fix is still un-retested on metal.
- **Quit the host app before running the suite** — it holds the per-user agent
  socket and a `now-logs` file. This cost a wrong diagnosis today; the
  symptom is socket-bound tests timing out with a port number that is never
  the problem.
- **Do not trust `PRODUCT_VERSION` to say which build answered.** `hello`
  carries a build stamp; use it, and assert a capability only the build under
  test has.

### 4.2 The agent's half — three measurements that are one experiment

Each is **a number, not a yes**, and each decides whether something already
built deserves to exist. One machine, one connected session, a stopwatch on the
wire.

| Measurement | What it decides |
|---|---|
| Does `LMGetCurStackBase()` fall inside its process's partition? | If not, **every** process reports `MISMATCH` — a silent, total, *polite* refusal rather than a fault. The check was written loose on purpose; tightening it wants this observation first. |
| Is a frame off an open bracket cheaper than a 0.5–0.6 s capture? | The streaming row's whole premise. If it is not clearly cheaper, say so and the row is wrong. |
| What does a semantic scene walk cost on the 1400c? | Whether Mirror scenes reuse the bracket or stay one-shot. Upstream measures ~2.1 ms on an emulated machine; above roughly 200 ms here, the bracket earns its keep. |

Then the eleven capabilities that have never crossed a wire, and the agent audit
line, which nobody has read off a real run.

**Report a refutation as a result.** If a measurement says a design is wrong,
that is the pass working. The bracket's premise is the most likely to fall.

### 4.3 The human's half

Everything in Part One of the review doc, and the ones that cannot be delegated:

- The **MCP module's resting state** — the sentence the pane spends its life
  saying, and the state most likely to read as *broken* rather than *idle*.
- The **Connections page**, which no eye has met: one Mac must not read as a
  fleet, and the three identities must read as three different things.
- The **guest's icon** on a real Finder, at 16×16 and on a 1-bit display.
- **Contention**: an agent's stream turning your live view on and greying out
  Capture, which is two sentences a person only ever reads while somebody else
  is using their Mac.

---

## What would change this plan

Kept honest by adding rather than editing. The first three are as written
2026-07-31; the rest were added 2026-08-01 when the act plane and the
reference layer landed and gave the plan new ways to be wrong.

- **The stack-base measurement failing.** It invalidates part of M1 and the
  Processes page's Windows row.
- **The bracket premise failing.** It removes the streaming row and simplifies
  M4 to one-shot only, permanently.
- **A `cis`-class wedge from the extension.** It would put P3 back behind a much
  higher bar, and the probe exists precisely so that finding out is cheap.
- **`actselftest` returning `Abi`.** The single highest-leverage failure
  available. It would mean the trap patches answer in the wrong slot —
  every counter reporting success while the application takes the other
  branch — and it invalidates the whole act plane, both generations of
  upstream's work on it, and everything Phase 4 planned to measure with
  it. It is also the one failure that is *cheap* to find, which is why it
  is step 4 and not step 8.
- **The reference layer proving unreliable on a machine.** Every act verb
  takes a reference nothing else can produce. If `observe` mints
  references that `handle` cannot resolve, or resolves stale ones as live,
  then every number taken after step 3 is measuring the wrong thing and
  none of the act harnesses mean anything. Upstream's 18/20 → 0/19 is the
  measurement that says identity beats position; it has not been
  reproduced here.
- **A window reference that resolves but names the wrong window.** The
  worse cousin of the above, and the one no counter catches: a plausible
  answer for the wrong element. The mutation report in
  [scene-producer.md](scene-producer.md) covers the encoder's half; the
  machine's half is unexercised.
- **The content plane's writer wedging a machine.** Its reader is tested
  and its writer has never executed anywhere. `content-plane-absent` is
  the expected answer on every machine that exists; the first time it is
  *not*, everything about P3's risk profile becomes a live question.

**What would NOT change this plan, and is worth saying:** a harness that
refuses. Six of them read as blocked on a verb that had been served for a
week. **A refusal is a claim about the guest, and a stale claim looks
exactly like a real one** — check it against the dispatch table before
treating it as a finding.

## Corpus impact

`corpus_impact: none` — a plan, and no new measurement. Every number cited here
is already recorded (`docs/metal-and-ux-review.md`, `docs/streaming-a-scene.md`,
plan 007, and Mirror's own findings in its repository). The three measurements
in 4.2 each owe a finding **the moment they exist**.

**2026-08-01 revision: still `none`, and the list of what owes a finding
is longer.** The revision is phase states and cross-references; the two
numbers it adds (69 native tests, 3/3 cross-builds) are gate counts taken
by running them, not measurements of a machine. Owing a finding the moment
it produces a number, in addition to 4.2's three: `actselftest`'s verdict
on any machine, the reference layer's mint-and-resolve rate, and the first
`qdtrace status` that does not answer `content-plane-absent`.
