# Driving a classic Mac application, as Mirror left it

**Date:** 2026-07-31 · **Status:** recorded knowledge, carried from the
parked upstream project `timbottu/mirror`. Nothing on this page was
measured by NOW.

Source documents, now superseded by this one: `archive/mirror-standalone-2026-08-09/docs/PORTAL-PLAN.md`
(the act plane), `CONTROL-SURFACE.md` (the perceive/act map), and the
act-plane sections of `STATUS.md`, `HANDOFF.md` and `MIRRORKIT-PLAN.md`.

**Provenance.** Every measurement below was taken on a session-private
QEMU `mac99` clone of `os91-runner.qcow2` running Mac OS 9.1, unless a
row says otherwise. Upstream states plainly that **metal was never
touched** by the act plane. These numbers are evidence about a
mechanism; they are not NOW results and they do not transfer to
hardware.

## The one sentence

Every act-plane limitation upstream hit had a single cause: **being
outside the target process.** The fix was not better coordinates. It
was to run inside the target and **answer the question the application
was about to ask**.

## Two generations, and which one won

Upstream built the outside-the-process version first and then replaced
it. Both are recorded here because the first one's failure modes are
what justify the second.

| | Generation 1 — from outside | Generation 2 — the Portal |
|---|---|---|
| Mechanism | emulator QMP mouse injection + geometry calibrated against the guest framebuffer | an INIT whose hook runs in the target's own context and answers Toolbox traps |
| Menu items without a shortcut | open-loop drag down a drawn menu; **a miss selects the wrong row, it does not no-op** | answer `MenuSelect` with the packed result; no menu drawn, no tracking loop |
| Portability | **emulator only** — no QMP on real hardware | in-guest OS calls throughout; metal-*shaped*, though still unproven there |
| Determinism | mouse-acceleration-sensitive, connection-state-dependent | deterministic |

Where the two disagree, **generation 2 is the later and better
answer.** Generation 1's best remaining idea for shortcut-less menus — a
screendump-closed-loop that reads emulated VRAM while `MenuSelect`
starves the wire — was scoped and never built, because the Portal made
it unnecessary.

## Why "answer the question" and not "inject the input"

`PostEvent` cannot drive an application that has entered a tracking loop.
When an app takes a `mouseDown` and enters `DragWindow`, `TrackControl`
or `MenuSelect`, it spins reading `Button()` and `GetMouse()`, and
nothing on the wire gets CPU to move the mouse or release the button.
This is cooperative-multitasking starvation, and it is the whole reason
the Portal exists.

The normal path an application takes is:

```
GetNextEvent → mouseDown in the menu bar → MenuSelect → packed (menuID, item)
             → the app dispatches its own command handler
```

So patch `_MenuSelect`, post a `mouseDown` at the menu **title** (the
app only calls `MenuSelect` in response to one), return the packed
answer immediately, and the app runs its own real command handler. No
menu is drawn, nothing is timing- or motion-dependent.

## The primitive

| Piece | Shape |
|---|---|
| Publication | one INIT, one system-heap block, published via `Gestalt('TBpt')` |
| Coherence | seqlock — the same shape the semantic observer already used |
| Addressing | the host posts a request addressed to a target **A5 world**; a `GNEFilter` hook serves it the next time it finds itself running as that process |
| Wire addressing | the wire takes a PSN like every other verb; the agent resolves PSN → A5 through the observer's oracle |
| Hook discipline | allocation-free, touches only handles the Toolbox just handed it |

**Addressing is by A5 inside the hook** — one low-memory read — because
a PSN would require Process Manager calls that are not safe at
`GNEFilter` time.

**The caller must yield, not spin.** Under cooperative multitasking a
busy-wait holds the CPU inside the *caller's* process, so the target
never runs and never serves. A spin does not merely waste time; **it
guarantees its own timeout.**

## The operations

| Op | Mechanism | Upstream rate (mac99, N=20 independent trials) |
|---|---|---|
| `MENU_GEOMETRY` | real per-item rects from the app's own MDEF | done |
| `MENU_INVOKE` | guarded `_MenuSelect` patch, armed with `(menuID, item)` | 20/20 reply + 20/20 actuation |
| `CONTROL_INVOKE` | guarded `_TrackControl` patch, armed against a specific `ControlHandle`, calls the app's action procedure once | 20/20 + 20/20, both halves |
| `WINDOW_ACT` | see below — `move` is a direct call, the other three are patches | 20/20 answered on each of move / resize / zoom / close |
| `TEXT_GET` / `TEXT_SET` | **no patch at all** — the hook reads and writes the record directly | 20/20 read + 20/20 write, on each of three kinds |

**Op numbering gotcha.** Plan numbers are not wire numbers. `WINDOW_ACT`
and the text ops were developed in parallel and **both authored
themselves as op 5**. `WINDOW_ACT` landed first, so on the wire the text
ops are **6 and 7** while the plan document still calls them 4 and 5.
The shared header is the authority on what a request carries, not the
prose.

## Menu geometry — the 30 px error

Upstream's host had been assuming **uniform 16 px menu rows**. On mac99
the real values are **separators 6 px, items 16 px**, and that
discrepancy accumulated into a **30 px** error that made menu selection
land on the wrong item.

The honest fix is per-item rects **from the guest** — the Menu Manager
knows each item's height — rather than the host assuming a row height.

**NOW's ruling, 2026-07-31: neither. Delete the computation.** The
uniform-16 assumption survives in `ActionModel.menuRowHeight`, and its
only consumer is a release point for a menu drag `ActionModel.menuSelect`
no longer emits — every menu item now goes through `menuact`, which is
addressed by identity and computes no geometry at all. Porting
`menugeom` would mean calling a foreign MDEF, the riskiest call in
upstream's file, to make a dead computation accurate. The reasoning and
the re-open condition are in
[input-plane-decisions.md](input-plane-decisions.md).

## Control part codes — the constant that was wrong in a comment

`CONTROL_INVOKE` was reported broken. It was not; the caller was sending
the wrong part code, because the verb's **own doc comment** listed four
wrong constants.

| Part | Correct value |
|---|---|
| `inButton` / `kControlButtonPart` | 10 |
| `inCheckBox` / `kControlCheckBoxPart` | 11 |
| `inUpButton` | 20 |
| `inDownButton` | 21 |
| `inPageUp` | 22 |
| `inPageDown` | 23 |
| `inThumb` / `kControlIndicatorPart` | 129 |

So 10 and 11 are *button* parts, and **12 and 13 are not part codes at
all** — which is what the comment had claimed for two of the scroll-bar
parts. Source: Inside Macintosh / `ControlDefinitions.h`.

Confirmed by deliberate mutation: with the part forced to 12, the same
binary gives **reply 100%, actuation 0%** — exactly the originally
reported symptom.

Two things worth carrying beyond the numbers:

- A phantom constant in a **comment** propagates into every caller.
- *"Answered `true` but nothing happened"* was read as an accusation
  against the mechanism, when the honest reply was doing its job and the
  **caller's argument** was wrong.

**All four scroll-bar parts move the bar as named** (mac99, SimpleText's
scroll bar): `inUpButton` 618→602, `inPageUp` 602→106, `inDownButton`
106→122, `inPageDown` 122→618. This is what rules out "the injected
click did it" — one fixed click point cannot produce four different,
semantically correct answers.

**A retracted hypothesis worth not re-forming.** An earlier version
theorised that the action procedure consults live input (`StillDown`,
`GetMouse`, `TestControl`) and no-ops because the injected click is
already released, and proposed holding the button via the low-memory
`MBState`. **That was wrong.** Holding the button was never needed; a
single unheld action-proc call moves the bar.

**`sawActionProc` sentinel.** SimpleText's scroll bar passes a real
`ProcPtr`; the alert's Cancel button passes **`0xFFFFFFFF`** — the
Control Manager's "use the control's own" sentinel, **not a callable
address**. The patch declines it rather than jumping to it.

`inThumb` (129) is deliberately not driven: a thumb drag has no
single-call semantics.

### Which part codes can verify their own effect — the audit

Asked because sweep C found `ctlact part 0` reporting `click posted` over
a machine that had not moved, and named it as *"`part 0` has no
settlement check, where `part 11` has an exemplary one"*. The audit's
answer is that **the part code was never the axis**, and this table is
here so nobody re-derives that.

`ctlact` accepts any `part` in 0–255 and branches on the value exactly
**once**: `part == 0` or not. Every named part takes the identical path.

| `part` | Control Manager meaning | what the plane does | evidence it may be judged by |
|---|---|---|---|
| 0 | "no part" — let the application's own tracking decide | posts a real click at the point, and arms the patch with `part_code` 0 | **the control's own position**, watched for up to 120 ticks and stopped the moment it moves |
| 10 | `kControlButtonPart` — a push button's body | arms the patch to answer 10 | the patch firing (= the application called `TrackControl`); a button has **no range**, so its position proves nothing |
| 11 | `kControlCheckBoxPart` — checkbox / radio | same | the patch firing, **and** the value flipping |
| 20, 21 | `inUpButton`, `inDownButton` | same | the patch firing, and the bar's value |
| 22, 23 | `inPageUp`, `inPageDown` | same | the patch firing, and the bar's value |
| 129 | `inThumb` — the indicator | same, with the action proc suppressed | the patch firing, and the bar's value |
| everything else in 1–255 | not a documented part code | same generic path; the patch answers with whatever was named | the patch firing, which proves the application asked — **not** that the number meant anything (see the `part 12` mutation above) |

Two things the table makes visible that a per-part reading hides:

- **What decides verifiability is the CONTROL and the APPLICATION, not
  the number.** Whether an act can be confirmed turns on (a) whether the
  application routes that click through `TrackControl` at all — an
  Appearance-era tab does not, and no patch is ever consulted — and (b)
  whether the control has a live value range to re-read. A push button
  driven by `part 10` is *unverifiable by this guest* and always was;
  it now says `dispatched-but-unconfirmed` instead of `dispatched`.
- **`part 0` arms a patch that would suppress the very click it posts.**
  `now_act_control_answer` returns the armed `part_code`, so an
  application that *does* call `TrackControl` on that control is told
  **0** — the Control Manager's "released outside the control" — and
  does nothing. Part 0 is therefore self-defeating on exactly the
  controls a named part serves, and correct on the ones it does not.
  Unfixed: the arming lives in the resident and changing it is a bake.
  It is now at least *reported* honestly rather than as `click posted`.
  ([open-issues.md](open-issues.md))

## Window acts — where a prediction was wrong

The plan predicted `DragWindow` had `TrackControl`'s shape. **It does
not.** `DragWindow` is `pascal void`: it performs the move itself and
hands the application nothing, so there is no question for a patch to
answer and no application code that runs afterwards.

| Op | How it is served | Why |
|---|---|---|
| `move` | call `MoveWindow` in the target's own context — **no patch, no click** | the same call `DragWindow` would make, minus the tracking loop and the motion it needs |
| `resize` | answer `FindWindow`, then `GrowWindow` | the app calls `SizeWindow` itself and adjusts its own content afterwards |
| `zoom` | answer `FindWindow`, then `TrackBox` | the app calls `ZoomWindow` itself |
| `close` | answer `FindWindow`, then `TrackGoAway` | the app runs its own close path, dialogs and all |

**Resize, zoom and close must be patches, not direct calls, because the
application has work to do afterwards.** A window resized behind the
application's back keeps its scroll bars where they were.

**`FindWindow` is patched specifically to keep chrome geometry out of
the op.** Driving a grow box or close box otherwise means computing
where the window definition procedure drew them — a title-bar height and
a 15×15 corner that **no guest structure reports**. With `FindWindow`
answered, the synthetic click may land anywhere in the window and the
app is still told which part it hit.

**`close` promises the app was *asked*, not that the window closed.** An
unsaved document reports `windowGone: false` with `answered: true`, and
that is a correct outcome. Calling `CloseWindow` directly would close it
every time by throwing unsaved work away with no prompt.

### The Toolbox facts these ops rest on

| Fact | Detail |
|---|---|
| Trap numbers | `_FindWindow` `0xA92C`, `_GrowWindow` `0xA92B`, `_TrackBox` `0xA83B`, `_TrackGoAway` `0xA91E`, `_MoveWindow` `0xA91B` |
| Two similarly-named constant sets | `FindWindow` part codes live at `MacWindows.h:445-456`; the **WDEF message** codes (`wInDrag = 2` etc.) at `MacWindows.h:465-470`. Confusing them cost a day |
| `MoveWindow` arguments | h/v are the **content** region's top-left (verified: asked for (100,90), the guest's own `contRgn` reads `[100,90,…]`) |
| `contRgn` offset | `WindowRecord + 118` |
| `GrowWindow` packing | **height in the high word, width in the low word** (asked 300×180, measured 300×180 — which is why the probe never asks for a square) |

### The Pascal Boolean trap — the most expensive fact on this page

**A Pascal `Boolean` function result occupies a 2-byte stack slot, but
the value lives in the HIGH byte.** The compiler generates
`move.b (%sp),%d0`. So a patch that writes `move.w #1` into that slot
**writes FALSE** while believing it is reporting "I fired."

A `short` in the same-sized slot is a full word, which is why the two
look interchangeable and are not.

Verified two ways upstream: by compiling a call to each trap with the
68K toolchain and reading the generated caller, then by disassembling
the shims.

This matters more than its size suggests because **its failure mode is
silent and self-consistent.** The patch compiles clean, runs clean, sets
its own "I fired" counters, logs success — and returns FALSE, so the
application takes the other branch and nothing visible happens. Every
instrument on your side says the patch worked. It sits directly under
`TrackGoAway`, `TrackBox` and `TrackControl`, which is exactly where any
classic-Mac automation must answer.

### SimpleText calls `FindWindow` twice per mouseDown

Measured: `target find = 2`, `fwAnswers = 1`. The patch originally
answered only the first call; the **real** `FindWindow` answered the
second with `inContent` — truthful for a centre click — and sent the
application down its content branch. The fix keeps the arm answerable
until the second-stage trap consumes it.

Upstream scoped this explicitly as **a fact about SimpleText, not about
Mac OS 9.** An app that calls `FindWindow` once, or three times, is
untested.

**The diagnostic technique that found it is reusable:** a `trapHits`
counter bumped at the **top** of each answer function, before any guard.
A guarded patch cannot otherwise tell you whether nothing happened
because the trap was never entered or because it was entered and
declined — *and those are opposite repairs.* It read `goaway = 0`.

Mutation control, for the shape of the evidence: with the fix removed,
`move` stays 5/5 (it uses no patch, so it is the control) while
`resize`, `zoom` and `close` all go **0/5**.

## Text ops — the shape that needed no patch

`MenuSelect` and `TrackControl` are questions an application is about to
ask, so the way to act is to answer them. **A TextEdit record and a
dialog's item list are not questions** — they are per-process roots,
unreachable from outside and ordinary memory from inside. So the hook
serves the request directly and **there is no armed window at all.**

| `kind` | Names | Mechanism |
|---|---|---|
| `ditem` | a dialog item, **1-based** | `GetDialogItem` → `GetDialogItemText` / `SetDialogItemText` |
| `dialogte` | the dialog's own live TERec (`DialogRecord.textH`) | `TEGetText`-equivalent / `TESetText` |
| `te` | a caller-supplied `TEHandle` | the same, on any TE the caller can name |

**The redraw obligation.** `TESetText` **does not display**, and a field
showing stale text is the screen lying about the document. So the TE
path calls `TECalText`, erases and `TEUpdate`s the view rect, and also
`InvalRect`s it so the application's own update pass agrees — **with the
port saved and restored**, since this runs inside the app's
`GetNextEvent`. (Inside Macintosh: Text, TextEdit.)

The dialog-item path needs none of that, because `SetDialogItemText`
draws the item itself — but it needs a different step: if the item is
the Dialog Manager's currently open edit field
(`DialogRecord.editField == item - 1`) it must be **re-selected**, so
the live TERec reloads from the item handle rather than resurrecting the
old string on the next keystroke.

### The wild read — a memory-safety fact with a body count

On a system with no memory protection, a caller-supplied `TEHandle` used
to be dereferenced **twice** — `(**te).inPort` — before anything
established that the integer addressed memory.

`textset {kind:"te", handle:1234}` **did not answer `bad_handle`. It
timed out and took SimpleText's open dialog with it** — the hook killed
somebody else's application.

The fix range-checks the handle *and its master pointer* against
`ApplZone`'s own limits before any dereference. Proven by mutation in
the honest direction: the same probe destroys the dialog on the pre-fix
binary and answers `bad_handle` **eight times over, dialog alive**, on
the fixed one.

Upstream is explicit that this is **a plausibility check, not a proof** —
an in-zone address that is not a `TEHandle` still gets past it, which is
why the identity guard below still matters.

### The identity guard for text

1. The caller names the window **twice** — by window-list **index** and
   by **title** — and the guest refuses unless both agree, *before
   anything is written*. An index alone goes stale the moment a window
   opens, and a stale index on a write edits the wrong document.
2. The hook independently requires that window to be in **its own**
   window list.
3. For `kind: "te"`, the TERec's **`inPort` must be that same window** —
   so a handle belonging to another process cannot be written through,
   because its `inPort` names none of our windows.

### Does the application actually agree?

Object-level oracles cannot detect an application keeping its own copy
of a field. So upstream wrote a name into SimpleText's Save As dialog
(`editText` item **10**) and pressed Return: **8/8 produced a real file
on disk**, in `Macintosh HD:Desktop Folder:`, under exactly the name
written. SimpleText reads the field.

### Not tested for text ops

Only SimpleText (its Find and Save As dialogs) — no Finder, no control
panel. No application **document** TextEdit view: `kind: "te"` is the
door, but **discovering an app's private `TEHandle` is not implemented
and no documented route to it was found.** The Dialog Manager publishes
`DialogRecord.textH`; an application publishes nothing equivalent.
Also untested: pixels (the redraw path runs and the record agrees, but
nothing compared the screen), text longer than 255 bytes (the buffer is
`Str255`-shaped because `GetDialogItemText` takes one; a longer TE
reports `truncated: true` with its true length), non-ASCII MacRoman, and
two targets at once.

## Identity, not position — the hardest-won finding

**Self-disarming is not a guard.** A patch that fires once says nothing
about *whose* call it fires on.

Upstream wrote "nothing stays armed across a user's own interaction"
down as a safety property, never ran the acceptance criterion, and the
defect lived for weeks. When they finally measured it (2026-07-31,
mac99, N=20):

| Case | Hijacked the user's own action | The user's own click still worked |
|---|---|---|
| Control cross-fire — arm a control, click a *different* control | **0/20** | 18/20 |
| Menu cross-fire — arm a menu item, press a *different* menu | **18/20** | **0/20** |
| Stale arm | 0/18 | — |
| Baseline | 0/5 | 5/5 |

The difference is one line of guard. `pt_trackcontrol_answer` tests four
things — armed, the op, the A5 world, **and that the request names THIS
`ControlHandle`**. `pt_menuselect_answer` tested only the first three. A
menu press carries no handle to name, and the patch had no idea where
the click was; the verb's own `titleLeft` was the only place that
information existed and it was never carried into the shared block.

**The hijack consumed the user's click** — before the fix the user's own
menu never opened at all. That second column is what distinguishes a
guard from a wall.

After the fix: hijack **18/20 → 0/19**, the user's own click **0/20 →
19/19**, the legitimate request still **20/20**, control cross-fire
unchanged at 0/20. *Both* numbers are required — a guard that also
blocks the real request is not a fix.

**The fix:** carry the synthesised click point into the armed request;
the trampoline hands `MenuSelect`'s `Point` down to the guard; a press
anywhere else chains through. **Tolerance is ±2 px, not exact**, because
an application may hand `MenuSelect` an adjusted point, and a strict
guard breaks the legitimate request instead of the hijack.

Upstream recorded a caveat on its own evidence: the before-numbers came
from an earlier run against a different binary with the identical probe,
which is a **build-to-build comparison, not a same-session mutation**,
and therefore weaker.

**The exposure window**, one trial per delay: hijack at +0.5 s, +1 s,
+2 s, +3 s, +4 s; clean at +5 s, +6 s, +8 s, +12 s. The boundary is the
verb's own **300-tick wait** timing out and clearing the arm.

## Safety posture — the parts worth inheriting

- **Two extensions, two postures.** The observer INIT stays observe-only;
  the acting INIT is separate, so the observer's contract is not quietly
  rewritten.
- **The guest never ages a request out.** Nothing in the INIT expires an
  arm; it is cleared only by the host verb on its way out, or by the
  bypass switch. **An agent that dies mid-verb leaves the patch armed
  indefinitely.** A safety property should not depend on the caller
  surviving. (Stated as following from the code, not measured.)
- **The bypass switch is a plain word the host writes, not a request the
  hook serves** — so turning it off is immediate and does not require the
  target process to be alive, frontmost, or pumping. *"A kill switch that
  depends on the cooperation of the thing it protects you from is not a
  kill switch."*
- **The patches are never removed.** The extension stays installed and
  the trap patch stays installed; disabling makes the hook return before
  looking at anything. **A trap patch that vanishes while a caller is
  inside it is a worse hazard than one that stays and does nothing.**
- **Shared-header versioning refuses rather than reinterprets.** Writing
  a field into a block that has no room for it is silent corruption, not
  an error; an older INIT refuses a newer request rather than reading
  garbage.
- **Both arming verbs warp the user's pointer.** They write the
  low-memory mouse globals before posting, so an act teleports the
  cursor. Harmless to an agent, rude to a human — and it *corrupts
  measurements*: it made the first version of the no-hijack probe click
  the wrong thing and report a confident 0/2.

### The cross-process guard has never been reached

Upstream tried to test whether driving one application can fire a
command in another, and got **6/6 timeouts** — **a background
application does not arm.** The hook only serves when it runs, and a
suspended app does not run.

That is a hard negative result and it does two things: it answers the
plan's "suspended targets" question, and it means **the blast-radius
question remains open.** The route to it is a target alive and pumping
while something else is frontmost.

## Input verbs, and where each one runs

The act plane was not the only way upstream drove the guest. The input
verbs below are what was reachable before it, and several stay useful.

| Verb | Mechanism | Emulator | Real hardware |
|---|---|---|---|
| `click` | `PPostEvent(mouseDown/Up)` + set the mouse-location globals | yes | yes, identically |
| `key` | `PostEvent`/`PPostEvent(keyDown/Up)` + modifier stamp | yes | yes |
| `type` | `PostEvent` per character | yes | yes |
| `launch` | `LaunchApplication` → PSN | yes | yes |
| `activate` | `SetFrontProcess` (PSN, not name) | yes | yes |
| Apple Event quit | `AESend` with `kAEQuitApplication` | yes | yes |
| `script` | `OSADoScript` | yes | yes, time-capped |
| QMP mouse injection | the emulator moves the mouse from outside the guest CPU | yes | **no — none exists** |

### `PostEvent` facts

- **`PostEvent` returns `evtNotEnb` (1) on every `keyUp` call.** keyUp is
  simply not enabled in the system event mask. This is normal. Briefly
  treating it as fatal made a verb report an error **20/20 while still
  actuating**. The **keyDown** return is load-bearing and should be
  checked.
- **`PPostEvent` returns `noErr` on every call**, including deep into a
  long run. **Event-queue exhaustion is not a failure mode here.**
- **`PostEvent` cannot reach inside a tracking loop.** That is the wall
  the Portal exists to get past.

### Menu shortcuts need the keycode, not the character

`key {char: 'n', mods: cmd}` opened New in SimpleText but **silently
no-op'd in the Finder** — the Finder's `MenuEvent` matches on the
virtual **keycode**, not the character. Sending the real keycode (45 for
`n`) fixes it. A char→keycode map is required.

This was also the real cause of an earlier "activate doesn't raise
windows" symptom: the Finder *was* front; only the key match was wrong.

### Launch and quit

- **`LaunchApplication`, not an Apple Event to the Finder.** An `AESend`
  needs the Finder scheduled and pumping; a Finder in a tracking loop,
  showing a modal, or simply not given time answers late or never — and
  **a timed-out `AESend` is indistinguishable from an app that failed to
  start.** `LaunchApplication` is a Process Manager call in our own
  context with a synchronous `OSErr`.
- Launch-by-name walks the catalog from the boot volume root via
  `FindFolder(kOnSystemDisk)` — **never a hardcoded `Macintosh HD`** —
  capped in ticks, directories and depth, with every cap reported so a
  miss cannot be mistaken for an exhausted budget. Two matches is
  `ambiguous`, never a guess. First-call cost measured at **327
  directories, 0.45 s on the wire** (mac99).
- **`launched: true` means only that `LaunchApplication` returned
  `noErr` and handed back a PSN.** It is not a claim that a window
  exists.
- **There is no Process Manager "ask this application to quit."** The
  Apple Event is the mechanism; the alternative is a ⌘-Q keystroke, which
  is input injection on a different plane and needs focus stolen first.
- The quit path sends `kAENoReply` — fire-and-forget — because waiting
  would block a single-threaded agent on a foreign app's event loop. So
  the result says **`sent`, never `performed`**. `kAECanInteract` is
  deliberate: it is what lets a target with an unsaved document put up
  its save-changes alert instead of the send failing.
- **A guest application that does not handle `kAEQuitApplication` cannot
  be reaped**, which forces every new build onto a fresh port. Handling
  it makes redeploy quit → push → relaunch on the same port, no reboot.
- `AESend` returning **-600 (`procNotFound`)** is reported as
  `not_found`, not as a wire error: a stale PSN from an older observation
  is not a broken guest.
- Initialise the reply descriptor to null before `AESend` — an early
  error may not write it, and disposing stack garbage is a crash you
  would have to reproduce on hardware to believe.

### Measured input rates (mac99, upstream)

| Act | Trials | Reply | Actuation, verified in guest state |
|---|---|---|---|
| `click` | 20 | 20/20 | 20/20 — clicking the desktop brought the Finder forward |
| `key` ⌘N | 20 | 20/20 | 20/20 — a folder appeared on disk |
| `key` plain | 20 | 20/20 | 45 consecutive Returns all landed |
| launch by path | 5 | 5/5 | 5/5 |
| launch by name | 5 | 5/5 | 5/5 |
| quit (clean document) | 3 | 3/3 | 3/3, gone from the scene in 1.2 s each |

Trial independence for launch requires quitting the target first:
launching an already-running app is a **different act** — the Process
Manager merely brings it to the front — so an unreset trial measures
nothing.

**A menu item's `enabled` bit is not authoritative.** Classic
applications disable menus at rest and only adjust them at menu-down
time, so a passive read sees SimpleText's whole File menu — New, Save
As, Quit, all of it — as disabled, while the system-managed Apple and
Help menus read true. Gating actuation on that bit silently refused
every File item **including the reliable ⌘-keystroke path**. The guest's
own dispatch is the authority; verify by re-reading.

## What is genuinely open

- **Metal.** Nothing in this plane ran on real hardware, and no per-op
  metal-safety review exists.
- **Cross-process blast radius** — see above; the test never reached the
  guard.
- **Reentrancy per op.** Serving at `GNEFilter` time is safe-ish because
  the app is in its event loop, but not everything is callable there.
  Each new op needs the question asked again.
- **Multiple targets.** Single-flight is fine for one mirror; driving two
  applications needs a queue keyed by A5.
- **The window-act no-hijack case is argued, not measured.** Its
  `FindWindow` guard requires the exact point the verb posted —
  structurally the control test that held at 0/20, not the menu guard
  that leaked at 18/20 — and a supporting observation is that with a
  request armed, only 1 of 4–6 `FindWindow` entries per trial was
  answered. But **nobody has armed a window act and then clicked
  elsewhere.**

## Drag: the vehicle, and why it is a Time Manager task

Assessed 2026-08-07 (below), then built the same day. **P4 cannot hold
the mouse button and P7 can.** What follows is the assessment, kept
because it is still the argument, then what was built against it.

### The assessment

`ext/src/now_ext_act.c :: act_post_click` is P4's whole input vehicle,
and it queues a `mouseDown` and its matching `mouseUp` in one call, from
inside the target's context, before it returns. Every op that needs a
click — control, dialog item, menu — goes through it. There is no op that
presses without releasing, no motion between the two, and no separate
release.

**And the gap is not a missing op.** P4 serves everything from the jGNE
filter, which runs inside the application's own `GetNextEvent`. The
instant the button goes down the application enters its own tracking
loop — the Finder's is `DragGrayRgn`, reading `StillDown`, `GetMouse`
and `WaitMouseUp`; a scroll bar's is `TrackControl` — and **none of them
calls `GetNextEvent`**. So from the press until the release the filter is
never entered, and any design that delivers motion or a release through
it delivers neither. That is the finding, and it is what makes a drag a
new plane rather than a ninth op.

### What was built

`ext/src/now_ext_drag.c`, a **Time Manager task** — the only vehicle in
this component that fires regardless of who is being scheduled, which is
the same argument P6's liveness task makes. It has **no trap patches at
all**, so its blast radius is far smaller than P4's six. Everything the
tracking loops read is a mouse low-memory global, so the whole vehicle is
four writes:

| Global | Address | What reads it |
|---|---|---|
| `MBState` | 0x0172 | `Button()`, and therefore `StillDown()` |
| `MouseLocation` | 0x0830 | `GetMouse()` |
| `RawMouseLocation` | 0x082C | the cursor's own position |
| `MTemp` | 0x0828 | the cursor VBL's staging point |

Plus `CrsrNew`/`CrsrCouple` (0x08CE/0x08CF), which make the cursor
actually redraw. Without them a drag moves what `GetMouse` reports and
not what a person sees — and a gesture nobody can watch is a gesture
nobody can verify. They are past where this toolchain's `LowMem.h` stops
and are reached through **volatile pointer variables**, because GCC folds
a cast constant and rejects it under `-Werror=array-bounds` as "likely at
address zero" — a diagnostic correct about every C program except one
running in a Macintosh's low memory.

**One new act op, `kNowPeekActOpDragPress`, and deliberately no others.**
The press needs the target's context, its identity check and its A5, so
it is a request. Everything after is a **session**, in `NowPeekDragCell`,
written at both ends and consumed by the task.

### The dead-man

A guest left with the button down sits in that tracking loop forever, and
the host cannot rescue it: the host's only channel is the same cell the
wedged application has stopped reading. So the release cannot be
something the host is trusted to send.

- **Two clocks, either of which fires.** `idle_deadline` catches a dead
  host. `max_ticks` is refreshed by **nothing** and catches a live host
  with a wedged idea of what it is doing. One timer the measured thing
  can refresh measures nothing — the finding
  `instrument-feeds-the-clock`, paid for once already here.
- **Both clamped by the RESIDENT.** A host that writes 0, or
  0xFFFFFFFF, or forgets the field must not be able to switch the
  dead-man off. The clamped values are reported back
  (`idle_in_force` / `cap_in_force`), because a clamp nobody can observe
  is indistinguishable from a caller being right.
- **The deadlines are checked BEFORE the release the host asked for**, so
  a tick where both are true ends as a *deadline* and says which. It is
  the same button either way and a different fact; reporting the
  friendlier of the two would be exactly the plausible wrong answer this
  arc exists to stop.
- **The heartbeat is the HOST's liveness relayed**, never the guest
  application's own idle pump. An application that got that wrong would
  keep a dead host's drag alive forever and the dead-man would be
  decoration.

### A release is two halves with different owners

Writing `MBState` up is what every tracking loop actually reads, and it
happens **at interrupt time, where nothing can refuse it**. Queueing the
`mouseUp` EVENT needs `PPostEvent` and the target's own context, so it is
left owed (`pending_mouseup`) and settled by the next jGNE pass in the
drag's own A5 world — which arrives the moment the tracking loop, now
seeing the button up, hands the application back to `GetNextEvent`.

The split is the safety property: the part that must never fail runs
where it cannot, and the part that needs a context waits for one. Posting
the event from the task would put an Event Manager call at interrupt time
on the critical path of the one rule that must not have a critical path.

### Where the decisions live, and why

`now-guest-shared/src/now_drag_logic.c`. Toolbox-free, compiled by the
host `cc`, driven by `now-guest-shared/tests/now_drag_logic_test.c`.

**You cannot watch a dead-man work by driving a guest**: to see it fire
you must *not* release, and "did not release" and "the test hung" are the
same observation until something separates them. Five mutations were
watched failing, each naming a distinct case — removing either clock,
unclamping the caller's deadline, checking the release before the
deadlines, and writing `elapsed` as `now >= then + limit` (which is wrong
across the `TickCount` wrap, and whose symptom is a drag that never times
out once every 2.3 years of uptime).

### What is NOT proven

**Everything above the native gate.** The vehicle cross-compiles and has
never fired. Nobody has pressed, moved or released on a guest; the
`CrsrNew` redraw is reasoned from Inside Macintosh and has not been seen;
whether the Finder's `DragGrayRgn` actually tracks these writes is the
question the whole design rests on and is **unanswered**. Live proof
needs a private bake and three wire verbs the contract does not declare —
see [docs/open-issues.md](open-issues.md).

### The presentation half, built — and with nothing to drive it

Independent of the vehicle and honest without it: show the dragged item
moving with the pointer immediately, marked as PROVISIONAL until a select
confirms, and snap it home on release-before-confirm or on a failed
select. Built 2026-08-07 (slice 10.5), host-side, gate-green, and **not
one gesture has reached a guest** — `dragpress` / `dragmove` /
`dragrelease` are still undeclared, so `ItemDragDriver` has no conformer
and the live view answers an item drag with "this mirror cannot hold the
mouse button down".

**Snap-back needed a defensible "home", and that was the blocker.**
`placed` was three provenances wearing one boolean: the Finder's own
drawn box (`FinderItems.merge`, folder windows only), the saved
`fdLocation` grid (`SceneBuilder.desktopItems`), and a top-right stack
`ScenePoller.placeVolumes` **invented**. "Refuse rather than guess" would
have refused every desktop drag.

Closed by carrying the provenance —
`Scene.DesktopItem.origin` is `drawn` / `saved` / `unknown`, and
`homeIsTrustworthy` is `drawn` alone — and by asking the desktop the same
question every other surface is asked: a desktop clause in
`FinderItems.windowsScript` reads `bounds of` every item of the desktop
and every disk, inside the script call the folder windows already pay
for. Emulator-verified; see [docs/open-issues.md](open-issues.md) for
what the run said, including a guest that served no `list` at all.

The four pieces, and where each lives:

| Piece | Where | What it owns |
|---|---|---|
| provenance | `Scene.DesktopItem.origin` | may an item be returned here |
| targeting | `DragTargeting` | subject, destination, intent, refusals |
| the contract's rules | `ItemDragSession` | move / confirm / release / refused |
| the marking | `ProvisionalVisual` | how "not yet real" looks |

`ProvisionalVisual` sits in `UnknownVisual.swift`, one file, because they
are one idea in two tenses. **The anchoring is the one place they
differ and it is deliberate**: the marked unknown's stipple is anchored
to the CONTEXT so a static rectangle's texture does not crawl; a
provisional item moves with the pointer, so its lattice is anchored to
the RECTANGLE or the texture would flow through the object. One rule
underneath both — the texture belongs to whatever the reader perceives as
holding still. `ProvisionalDragRenderTests` asserts the pair, because a
later edit unifying them "for consistency" would otherwise show up
nowhere.
