# The road from *tested* to *verified*

**Date:** 2026-07-31 · **Status:** plan, nothing built against it yet

The parity + Mirror fold-in slice landed on `main` at `495f7b1`. It is green —
1130 host tests, 48 native tests, three guest cross-builds — and **not one line
of it has run on a Macintosh.** This document is the route from here to a
product that has actually met the machines it claims to drive.

Four phases, in dependency order. Phase 2 can start now; the rest are sequenced
because each one's failures would invalidate work in the next.

---

## Phase 1 — the honest gaps

Things this slice deliberately left incomplete, each recorded at its own site.
None is research; all are known-shape work. **Do these before any validation
pass**, because a pass that trips over a known hole wastes the setup.

| # | Gap | Size | Where it is written down |
|---|---|---|---|
| 1.1 | **The guest's Stop button cannot stop a pull.** Needs `now_wire_get_cancel()` inside `wire.c`'s private `g_get`, plus one registration. `now_pull_can_stop()` is false without it, so the pane looks unchanged — no regression, no fix. | ~15 lines, specified | `docs/guest-transfer-cancel.md` |
| 1.2 | **Three act rows are built and unregistered.** NOW's contract declares no act plane; registering one today fails the coverage test with the sentence describing a permanently-unavailable tool. | contract + 5 mechanical steps | `MirrorActProjections.swift` |
| 1.3 | **The ported walk has no caller.** `src/axwalk/` compiles and is tested; `scene_build.c` does not use it, and `now_peek_menu_titles` is still the declared stub. | wiring | `axprocess.h` has the exact API |
| 1.4 | **The P3 probe cannot advance past *packages*.** Its counters publish through Gestalt `'QDpr'` and nothing reads them, so "loaded at boot" cannot be told from "did not load". | a ~100-line throwaway reader | `prototypes/qdprobe/README.md` |
| 1.5 | **`conn_disconnect()` cleans up no pull** where `enter_backoff()` cleans five — disconnecting mid-pull leaks an open temp fork. | small | found by the transfer-cancel agent |
| 1.6 | **The Software review section is misfiled** under the Files heading in the review doc. | trivial | `metal-and-ux-review.md` |

**1.3 is the one that unlocks the most.** The menu walk was blocked on a citation
for most of this slice; the port brought the layout across (`6` / `6` / `14`,
mutation-killed by value). Wiring it turns `menus[]` from an absent key into a
produced plane, which is the largest single increase in what a scene can say.

---

## Phase 2 — finish the MirrorKit port

M6's other half, and the last of the fold-in. **Startable immediately** — it
does not depend on Phase 1.

### 2.1 MirrorKit as a NOW module

`MirrorKit` (headless core) and `MirrorKitUI` (Platinum renderer) become a NOW
module. The host split maps cleanly: `NOWAgentIntegration` is already a local
package product and the module pattern now has several precedents. This is Swift
against a settled IR — the cheapest remaining piece of the whole fold-in
relative to its value, because it is the half a person *sees*.

Open question the module must answer, and it was the hardest thing to get right
last time: **what it shows when the extension is absent or its planes are
unarmed.** Four states, and the Agent module's resting state took three attempts.

### 2.2 Two changes that belong upstream, in `timbottu/mirror`

- **`Scene.Window.controls` must decode-if-present.** It is a non-optional
  `[Control]` with no custom `init(from:)`, so a scene that legitimately omits
  the key **fails to decode**. IR v1 froze the field set and defined how a
  consumer ignores keys it does not know — but nothing for a producer reporting
  *fewer*. NOW's guest cannot be a MirrorKit source until this changes. Two
  lines. NOW's own decoder already does the right thing and a mutation proves it.
- Consider whether the same shape bites any other non-optional collection.

### 2.3 The oracle's missing discriminator

The walk port surfaced a real capability gap rather than a defect.
Upstream's `ax_oracle` captures the process's **`CurApName` in the same context
as A5** and checks it against the Process Manager's name before accepting a
match. That is an independent discriminator: **a recycled slot whose A5 *and*
stack base both land inside a live partition still carries the dead
application's name.** Ours refuses that case as `AMBIGUOUS` where upstream
resolves it — the safe direction, and a genuine loss of resolution.

Closing it means a name field in `contract/peek_table.h` — an anchor format
**V3**, additive, with the same accretive discipline V2 used. It is the
extension owner's call, which is why the port did not smuggle it in.

---

## Phase 3 — the emulator pass

**What it is for:** structure, not truth. It catches the things that are broken
everywhere before a scarce machine is booked, and it is free.

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
   wrong (review §12).
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

- **The stack-base measurement failing.** It invalidates part of M1 and the
  Processes page's Windows row.
- **The bracket premise failing.** It removes the streaming row and simplifies
  M4 to one-shot only, permanently.
- **A `cis`-class wedge from the extension.** It would put P3 back behind a much
  higher bar, and the probe exists precisely so that finding out is cheap.

## Corpus impact

`corpus_impact: none` — a plan, and no new measurement. Every number cited here
is already recorded (`docs/metal-and-ux-review.md`, `docs/streaming-a-scene.md`,
plan 007, and Mirror's own findings in its repository). The three measurements
in 4.2 each owe a finding **the moment they exist**.
