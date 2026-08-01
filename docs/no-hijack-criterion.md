# The no-hijack criterion, and the case upstream never needed

Status: **the code-reading finding below is settled. Every NUMBER in this
document is upstream's, measured on Mirror's guest, and NOT ours.** Nothing
in NOW's act plane has been watched on a Macintosh by this thread. The probe
this document gates (`scripts/probes/nohijack-probe.py`) has never been run
here — see "What is unrun" at the end, which says so in the specific.

Provenance: P-DOC (Universal Interfaces 3.4, Inside Macintosh) for the trap
and part-code constants it cites; the measurements attributed to upstream are
carried facts from `timbottu/mirror`, not results of ours.

---

## 1. The standing rule

**A new act op is not done until its no-hijack criterion has a NUMBER.**

Not a design argument, not a code comment, not a reviewer's confidence: a
count of trials, a count of hijacks, and a stated denominator. Upstream's leak
existed for weeks *precisely because* the criterion was written down and never
run. Writing it down again is what caused the bug; running it is what found it.

## 2. Why: disarming is not a guard

Mirror's plan said, in as many words, that the patch disarms after one use, so
a real user's click can never be hijacked. Measuring it **inverted the claim.**

Disarming says the patch fires **once**. It says nothing about **whose call it
fires on.**

The menu patch checked armed + op + A5. It answered whichever `MenuSelect`
arrived first. A user pressing a *different* menu ran the armed command
**18 times out of 20**.

The control patch additionally required the request to name **that exact
`ControlHandle`**. Under an identical test it hijacked **0 out of 20**.

> **IDENTITY IS THE GUARD. Self-disarming never was.**

Both numbers are upstream's, on upstream's guest. NOW's contract carries the
*shape* they imply (`contract/peek_table.h`, the P4 preamble) and explicitly
refuses to inherit the numbers.

### The menu case, where there is no handle to name

A menu press carries no handle, so there is nothing for the request to name —
which is exactly why the menu patch was the one that leaked. The fix is that
the identity checked is **the press itself**: the arming verb *synthesises*
the click, so it knows the exact point `MenuSelect` will receive. That point
rides in the cell (`arm_point_h` / `arm_point_v`) and a press outside ±2 px
chains through to the real trap.

The tolerance errs **loose** on purpose. A guard wrong in the strict direction
breaks the legitimate request while leaving the hijack it was written for
untouched — see `NOW_ACT_POINT_SLOP` in `now-guest-shared/src/now_act_guard.c`.

## 3. The six cases

`scripts/probes/nohijack-probe.py`, ported from
`timbottu/mirror/tests/nohijack-probe.py`.

| Case | What it asks | Oracle |
|---|---|---|
| `baseline` | does the stimulus itself work, with nothing armed? | the About window opens |
| `control` | armed on a decoy control, user clicks the LIVE one | the live bar's DIRECTION and distance |
| `menu` | armed on Finder File/New Folder, user presses the Apple menu | an `untitled folder` on the Desktop |
| `stale` | armed, no click during the window, click 10 s later | same two oracles |
| `window` | the disarm sweep: at what delay does hijacking stop? | same, at nine delays |
| `cross` | armed against a BACKGROUND process, click the FRONT one | a new window in the background app |

`text` rides alongside as a seventh: the text ops arm no patch, so their
hazard is the wrong *object* rather than the wrong *moment*.

**`cross` is absent from NOW's port** and is called out in §6 below rather
than quietly added, because it needs a second guest application and this
thread cannot start one.

## 4. The case upstream never needed: two cells armed

### Why the question is asked at all

Upstream is single-flight. Every no-hijack number it measured is for **one**
armed cell, so none of them transfers to a table where two requests can be in
flight. The two new questions:

1. With cells A and B both armed, can **B's press satisfy A's guard**?
2. Is the identity check evaluated **per cell**, or on the **first armed cell
   found**?

### What the code answers, at `now` main `7823df1`

**Neither question is reachable, because NOW's act plane is single-cell too.**
The premise that NOW has a multi-cell act table does not hold against the
source. The evidence, in order:

* `contract/peek_table.h` declares exactly one:
  `NowPeekActCell act;` — a **single struct member** of `NowPeekTable`, not an
  array. Its own comment: *"The act plane's one request/reply cell. ONE at a
  time by design: this is a single-consumer channel and the application is its
  only client."*
* `now_act_armed_cell()` (`now_act_guard.c:44`) returns `&table->act` — a
  **fixed address**. It takes no index, performs no search, and has no
  "first armed cell found" behaviour to have, because there is no set to
  search.
* Every guard — `now_act_menu_answer`, `now_act_control_answer`,
  `now_act_findwindow_answer`, `now_act_grow_answer`,
  `now_act_trackbox_answer`, `now_act_goaway_answer` — takes
  `NowPeekActCell *cell`, **one pointer supplied by the caller**, never a
  table plus an index. `armed_for()` (`now_act_guard.c:222`) is the shared
  clause and it dereferences that one pointer.
* The static asserts at the bottom of `contract/peek_table.h` pin
  `offsetof(NowPeekTable, act)` to a single scalar offset. An array would move
  them.

So the honest answer to "per-cell or first-armed?" is: **the code cannot
express the question.** There is one cell; the identity check is evaluated on
it; there is no second one to be confused with. A probe case that arms A and B
would have nothing to arm B into.

**What is multi-cell in NOW is the ANCHOR plane** (`anchors[kNowPeekMaxAnchors]`
— one slot per process), and it is a **read** plane. Multiplicity there names
which A5 worlds *exist*; it does not create a second place to put a request.

### But the single cell has its own version of the hazard, and it is real

The question does not evaporate — it changes shape. Two requests cannot occupy
two cells; they **collide in the one cell**, and nothing in the code refuses
the collision.

`now-guest-ppc/src/act/act_client.c:140` `now_act_submit()` writes
`target_a5`, clears `armed`/`fired`/the per-request counters, and commits
`status = Pending` — **without ever reading `cell->status` or `cell->armed`
first.** There is no interlock. A submit issued while an earlier request is
armed-but-unfired silently replaces that request's identity fields
(`arm_point_h/v`, `control_handle`, `window_ptr`, `target_a5`) underneath a
patch that is already live.

Two consequences, and they are *different* from each other:

1. **The guard still holds against the user.** The patches read the cell's
   *current* contents, so after B overwrites, a press matching **B's** arm
   point answers **B's** menu id. A user's unrelated press still matches
   neither and still chains through. The 0/20-shaped property is not lost.
2. **A's own synthesised click becomes an unguarded real click.** A posted a
   press at A's point expecting its patch to answer it. After B overwrites,
   that press is checked against **B's** point, misses, and chains through to
   the real trap — where it actuates whatever the live UI has at those
   coordinates. That is not a hijack *of* the user; it is the caller's own
   stimulus escaping into the interface. It is the failure mode a single-cell
   channel has *instead of* the two-cells one.

**How reachable is (2)?** `now_act_submit` blocks in `act_yield()`, which is
`WaitNextEvent(0, &ev, 2L, NULL)` — it **pumps the calling application's own
event loop** while waiting. Whether a second act request can be dispatched
from inside that pump is a property of the guest app's command dispatcher, not
of the guard, and **this thread did not establish it.** Stated as an open
question, not as a defect:

> **OPEN — no evidence either way.** Can the NOW guest application dispatch a
> second act command from inside the `WaitNextEvent` in `act_yield()`? If yes,
> the cell can be overwritten mid-flight by ordinary single-user traffic and
> `now_act_submit` needs a busy refusal. If no, the collision needs two
> clients, which the contract says do not exist. Settle it by reading the
> dispatcher, not by reasoning about it.

### The probe case that follows from this

`--case collide` in `scripts/probes/nohijack-probe.py` is written to the
**single-cell** shape, because that is the shape the code has. It arms request
A against a decoy, submits request B while A is still armed, and asks the two
questions the single cell can actually be asked:

* does A's stimulus, arriving after B's submit, actuate anything? (consequence
  2 above — the oracle is A's target, watched for an effect nobody asked for)
* does a real user press still chain through with B armed? (consequence 1 —
  the same oracle the `menu` case uses)

It is **not** the "two cells armed" case. Writing that case against a
single-cell contract would have produced a probe that measures a table which
does not exist, and a green number from it would have been worse than no
number. That refusal is recorded in the probe's own docstring.

## 5. Measurement discipline

Non-negotiable, and every one of these is a way a previous number was wrong:

1. **Guest state is the oracle, never the verb's reply.** `ok:true` is
   recorded because a reply that disagrees with the guest is itself a finding,
   but the verdict is the guest's. The strongest oracle in this project is a
   folder on disk.
2. **Reset state between trials.** Desktop folders swept, About closed, the
   scroll bar returned to the middle, Finder brought front.
3. **N = 20 wherever a rate is claimed.** Upstream's `0/19` is 19 because one
   click missed — the denominator is trials minus dropped, and it stays that
   way.
4. **Enforce the precondition or refuse to publish the number.** A missing
   verb exits 2 by name. A guest that will not answer `scene.request` exits 2
   by name. Connect-and-report-0/0 would read as a guard holding and would be
   a lie.
5. **Discriminate by direction where you can.** The control case's hijack and
   its honest chain-through move the same control opposite ways by different
   amounts, so no single reading can be read both ways.

## 6. What is unrun, and what is refused

**Unrun.** This thread has no emulator and no Macintosh. `nohijack-probe.py`
including the new `collide` case **has never executed against a guest.** It
compiles, imports, and its argument surface answers `--help`; that is the
entire extent of what has been shown. No number in NOW's act plane is
measured. Any statement here that reads like a result is upstream's, on
upstream's guest, and labelled.

**Refused, with the reason.**

* *The two-cells-armed case as briefed.* Refused: `contract/peek_table.h`
  declares one act cell and `now_act_guard.c` addresses it by a fixed
  reference. There is no second cell to arm, so the case is unwritable
  against this contract. `collide` is written instead and is a different
  question. If the act plane ever grows an array, this case comes back and
  §4's two questions are the right ones to ask of it.
* *`case_cross`, the cross-process attempt.* Not ported. Upstream's version
  arms SimpleText's File → New from the Finder and needs a second guest
  application running with a known PSN, plus a window-count oracle inside it.
  Both are runtime facts, not code. Left as a named gap rather than a stub
  that would exit 2 for a reason it does not have.
* *Any claim that NOW's guard holds.* Refused outright. The code has the
  identity clause in the right place; that is evidence about the code, and
  "builds" is the strongest word available until a machine has been watched.
