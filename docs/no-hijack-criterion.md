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

**How reachable is (2)? Settled by reading, and the answer is: not from one
guest application's wire.** `now_act_submit` blocks in `act_yield()`, which is
`WaitNextEvent(0, &ev, 2L, NULL)` — **event mask zero**, so it dequeues
nothing, and the wire is not serviced there either: `conn_service()` is called
only from the top of the main loop in `now-guest-ppc/src/main.c:412`, which
`now_act_submit` has not returned to. A second act command therefore waits in
the socket until the first verb has completed and the cell is idle. The guest
app is cooperatively single-threaded and every act command runs
submit-and-wait inside one dispatch, so **two requests cannot overlap.**

That is worth stating precisely because of what it means: **the single cell is
protected by the guest app's threading model, not by an interlock.** The
protection is incidental. Nothing in `contract/peek_table.h`, `now_act_guard.c`
or `act_client.c` enforces it, and two ordinary changes would remove it:

* a **second application** on the same Mac linking `act_client` — the table
  lives in the system heap and the extension does not authenticate its writer,
  so "single-consumer channel" is an assumption about the *machine*, not a
  property the code has;
* the guest app ever servicing the wire from inside the act wait, which is a
  plausible thing to want (a 5-second act currently freezes the app's UI).

If either lands, `now_act_submit` needs a busy refusal before it writes, and
this paragraph is the reason why.

**2026-08-06: the second one stopped being hypothetical.** That wait was
measured, and it does not merely freeze the app's UI — it holds
`conn_service` off for up to **ten seconds** (two 5 s phases), which is
the named cause of the Mirror's 9–12 second loops and lapses the anchor
plane's own ten-second lease. The recommended repair is exactly the
change this section says would remove the protection: make `act_yield`
pump via `pump.h`. **So the busy refusal is now a prerequisite, not a
contingency.** Whoever implements the pump implements the interlock in
the same commit, or the single-cell channel loses the only thing
defending it — and it loses it silently, because nothing in the code
asserts the property today. Neither has been done;
[nested-loops.md](nested-loops.md) and [open-issues.md](open-issues.md)
carry the measurement, and the call site in `act_client.c` carries the
note.

### So the collision the code DOES admit is a press, not a cell

Two requests cannot collide. A request and **a press it did not queue** can,
and that is the same question — *can something that belongs to somebody else
satisfy this guard?* — asked of the shape the code has.

The menu guard's identity is a **point**, and a point is not unique. Three
facts, each read out of the source:

1. `now_act_menu_answer` (`now_act_guard.c:237`) compares `MenuSelect`'s own
   point against `arm_point_h/v` with ±2 px and examines **nothing else**.
   There is no serial in the cell and nothing on the Event Manager's queue
   element that says which request queued a press. Two presses at the same
   coordinates are, to this code, the same press.
2. The resident half queues the request's own press from **inside the target's
   context at the moment of arming** (`ext/src/now_ext_act.c`, `act_post_click`
   via `PPostEvent`). Its own comment says why: *"there is no window between
   'armed' and 'pressed' during which a user's own click could arrive first."*
   That holds for a press made **after** arming.
3. Arming happens in the jGNE filter — `now_ext_gne_apply` → `now_ext_act_apply`
   (`ext/src/now_ext.c:238`) — i.e. **inside the target's own
   `GetNextEvent`/`WaitNextEvent`**, the same call that is about to hand it
   whatever was already queued.

Put together: a press **already in the queue** when the request arms is
*older* than the request's own, so the Event Manager hands it over first, and
the guard accepts it if the coordinates match. `menuact` arms at
`(titleLeft + 4, 10)` (`act_cmds.c:735`), so the coordinates that match are
**the menu title the request named** — exactly where a user reaching for that
menu would press.

**The prediction from the code is therefore a hijack**, deterministic rather
than racy once a press is pending: the request fires, `MenuSelect` returns
without drawing anything, and the user gets an item they never dragged to.
Upstream never saw it because upstream's menu case pressed a **different**
menu; the same-title press was never in any trial on either side.

It is not the ±2 px slop's fault. The slop errs loose to avoid breaking a
legitimate request, and this failure is in the other direction entirely.

### The probe case that follows from this

`--case collide` in `scripts/probes/nohijack-probe.py` measures exactly that:
press the File menu's title for real, **first**, then send `menuact` naming
that menu while the button is still down.

* **The discriminator is menu-tracking starvation, not the Desktop folder.**
  Both a hijack and an honest chain-through end with one folder — in the
  honest case the request's own press makes it — so the folder alone cannot
  separate them and `tally.hijacked` would call every trial a hijack. What
  separates them is whether the Finder entered `MenuSelect`'s tracking loop
  while the button was held: a tracking loop starves the responder, so an
  unanswered round trip *is* the tracking. Prompt answer ⇒ `MenuSelect`
  returned instantly ⇒ the patch answered a press nobody's request queued.
  This is the one place in the probe where `hijacked` is not
  `tally.hijacked()`; both of that helper's inputs are still recorded.
* **The precondition is enforced.** The press must land within the guard's own
  ±2 px of `(titleLeft + 4, 10)`. Positioning is closed-loop and the landing
  is checked; a miss is a **dropped trial**, never a quiet zero.
* It is **not** the "two cells armed" case, and the probe's own docstring says
  so in writing.

The premise is pinned on the host compiler as well:
`test_menu_press_is_anonymous` in `now-guest-shared/tests/now_act_guard_test.c`
asserts that a press at the arm point is answered whoever queued it, and that
the *second* press at that point is not — the exposure is one press wide, not
"until the request is withdrawn". It is a **characterisation** test: if a
future guard learns to tell its own press from a stranger's, those two checks
flip and must be rewritten rather than deleted. Watched failing under a
mutation that removes the disarm (3 of its checks fail), so it is not vacuous.

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

* *The pending-press hijack as a RESULT.* §4 predicts it from the code and
  the prediction is strong, but a prediction is not a number and this document
  does not get to claim one. Until `--case collide` has run, the honest
  statement is "the guard has no clause that would prevent this", not "the
  guard leaks here".
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
