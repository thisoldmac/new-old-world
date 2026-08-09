# Status — emulator gate, 2026-07-29

First end-to-end run of the extracted project: the child's own extension
and guest app, deployed and driven from the child's own rig, on a
session-private `mac99` / Mac OS 9.1 clone (`os91-runner.qcow2`).

Reproduce with `tools/spin-up.sh`; tear down with `tools/stop-mirror.sh`.

## Passing

| Gate | Result |
|---|---|
| Host build + tests | `swift build` clean, 37 tests green, fixture corpus intact |
| Extension build (68K) | `AXPeek.bin`, 51 KB |
| Guest app build (PPC) | `mirror-agent.bin`, 150 KB, **warning-free at -O2** |
| Deploy | Extension → Extensions, agent + `mirror.port` → `TimBotTu:mirror-dev`, all verified post-write |
| INIT survives cold reboot | yes (the staged-write-never-flushed trap) |
| Agent launches and answers | `hello` v0.1a with build stamp |
| Oracle reachable | `oracle=true status=ok v4` |
| `observe` | 9 processes, front app correctly identified (`SimpleText`) |
| `click` | **works**: cursor moved (15,15) → (400,300), verified by `mouseloc` |
| `axtree` scope=front | **real semantic tree**, `locator=axpeek-context`, `sampleFresh`, age 3 ticks, ~10 KB |
| Menus | real: Apple glyph, File, Edit, Font, Size, Style, Sound, Help |
| `quit` verb | clean self-reap over the wire |
| Hot redeploy | quit → push → relaunch, **no reboot needed** |

The `quit` verb is worth calling out: in the lab an anchor-launched
toolkit worker could not be reaped (no quit AE in its scope), which forced
deploying each new build on a fresh port. This agent handles the quit
Apple Event, so redeploy is quit-push-relaunch on the same port.

## The driving gap is CLOSED (2026-07-30)

"Done" was defined before measuring, then measured. On a fresh mac99 clone,
with `tests/trials.py` preconditions enforced and every oracle reading guest
state rather than the verb's own report:

| Criterion | Result |
|---|---|
| `click` has a measured rate | **20/20 replies, 20/20 actuations** |
| `key` has a measured rate | **20/20 replies, 20/20 actuations** (cmd+N) |
| `key` plain, no modifiers | **20/20 replies** |
| A click's *effect* on a real target | clicking the desktop **brought the Finder forward** |
| `key` drives a real app | cmd+N **created a folder on disk** |
| `axdo`'s success path | **returned ok**, resolved a point inside the control's rect |
| `axdo`'s *effect* | the scrollbar's **value changed 218 → 0** |
| Sustained sequence | **11/11 verified actions**, incl. **45 consecutive Returns, all landed** |

Reproduce: `python3 tests/drive-sequence.py --agent-port <p> --anchor-port <p>`.

### RETRACTED: the "~9 actuations per boot" ceiling was never real

The famous `A-AAAAAAAA----------` was an artifact of the oracle, not a defect
in the guest. The folder oracle **accumulated**: nine `untitled folder` entries
piled up on the Desktop over a run, and once they had, the Finder stopped
producing ones the oracle could see. Trials were never independent, so trial 12
was measured against a different machine state than trial 1 — and the sequence
could not distinguish "the verb stopped working" from "this scenario poisons
itself."

`trials.py` now **resets state between trials** (deletes what it created).
Under that, the same verb, same binary: `AAAAAAAAAAAAAAAAAAAA`, 20/20. And 45
consecutive Returns land in a row.

Two things died with it:
- The event-queue-exhaustion theory. `PPostEvent` returns `noErr` on every
  call, including deep into a run — a full queue is not how this fails, because
  it does not fail.
- The `WaitNextEvent` mask comparison (9/20 vs 0/20) was measured under the
  same broken oracle, so **that conclusion is void too**. `main.c` keeps
  `everyEvent`, which is measured good at 20/20; whether the narrow mask is
  actually worse is now **unverified** rather than known.

### One real bug was found and fixed on the way

`verb_key` ignored `PostEvent`'s return for the keyUp. Checking it revealed
`evtNotEnb` (1) on **every** call — keyUp is simply not enabled in the system
event mask, which is normal and is why the lab wrote `(void)PostEvent(...)`.
Briefly treating that as fatal made the verb error 20/20 while still actuating,
a regression caught and reverted the same session. The keyDown's return **is**
load-bearing and is now checked: a keystroke whose meaningful half never
reached the queue reports `post_failed` instead of `ok`.

## RETRACTED: `axdo` was never broken (2026-07-30)

Everything this document previously said about `axdo` starving the agent,
about tracking-loop starvation, and about `axdo` "poisoning the session" was
**wrong**. The guest was healthy throughout. Two bugs in the *test client*
manufactured the entire story.

**What `axdo` actually does.** It replies correctly, and with a precise error:

```
ok:false  not_actionable  "referenced control is hidden or inactive"
```

Which is the right answer. Graphing Calculator's window exposes 11 controls
and **10 report `visible:false`**; the one visible control, `Graph`, reports
`enabled:false` (it is disabled until there is an equation — visible as a gray
button in the committed render). `axdo` refused to act on hidden and disabled
controls and said exactly why.

**Bug 1 — a socket per request, with no retry.** The guest serves one
connection serially. A fresh socket per request races its accept, and the
transport refuses the new indication (`ot.c`, the `T_LISTEN` busy path, which
exists to reap crashed clients). The caller sees a bare connection reset. The
transport's contract is that the client reconnects; my client did not. Every
"reset" was this. It clustered around slow or large calls simply because those
leave less slack before the next connect.

`MirrorKit`'s own `WireClient.swift` had already solved this, deliberately,
with a comment warning about the exact failure — one persistent connection,
reused. The production client was right and the test client was wrong.

**Bug 2 — reading `["result"]` without checking `ok`.** That turned an honest
`not_actionable` into a `KeyError`, and then into a theory about wedges.

**Consequences for this document.** The section formerly titled "One mechanism
behind every reset" is withdrawn: there was no watchdog defect, the notifier's
watchdog never fired on a busy main loop in any measured case, and no
tracking-loop starvation was ever observed. `observe` and `axtree` work
normally after `axdo` when the client retries.

**What was done about it, so it cannot recur:**

- `tests/trials.py` now uses one persistent connection shaped like
  `WireClient`, treats `ok:false` as a *reply* rather than a failure, and
  retries a dropped connection.
- The harness **enforces preconditions**. `key-cmd-n` is meaningless unless
  the Finder is frontmost, and running it against Graphing Calculator produced
  a confident, meaningless 0%. It now refuses to publish a number when its own
  premise is unverified.
- The transport logs refusals. A refused `T_LISTEN` was invisible on the guest
  side (the notifier cannot log safely), so a reset had no explanation
  anywhere. `ot.c` now counts refusals in the notifier and reports them from
  `ot_idle`: `refused N connection(s) on a busy slot - client must reconnect`.
- `ot.c` also reports a handler that returns no reply, and any dispatch that
  holds the main loop over ~1 s. Silence was doing real damage.

## `WINDOW_ACT` removes QMP from the act plane (2026-07-31, lane P1)

`winact` moves, resizes, zooms and closes a window with **no simulated mouse
motion anywhere in the path**. That is the whole point of the op rather than a
side benefit: dragging a window by coordinates needs injected motion, injected
motion is QMP, and QMP exists only on the emulator — so for as long as moving a
window meant dragging one, the act plane could not work on a real PowerBook.

Measured on a session-private mac99 clone, `tests/winact-probe.py`, N=20,
independent trials, oracle = the window's own rect re-read out of the guest:

| Op | Mechanism | Oracle | Rate |
|---|---|---|---|
| `move` | `MoveWindow` in the target's context — no patch, no click | the content rect's top-left is the point asked for | **20/20 answered, 20/20 actuated** |
| `resize` | `FindWindow`→`inGrow`, then `GrowWindow`→the packed size | the content rect's width and height | **20/20, 20/20** |
| `zoom` | `FindWindow`→`inZoomIn`/`inZoomOut`, then `TrackBox`→true | out changes the rect, in restores exactly the rect before | **20/20, 20/20** |
| `close` | `FindWindow`→`inGoAway`, then `TrackGoAway`→true | the window's absence from the guest's own window list | **20/20 answered, 20/20 gone** |

Reproduce: `python3 tests/winact-probe.py --agent-port <p> --anchor-port <p>
--case all -n 20`.

### `move` is the one that does not use a patch, and the reason is a signature

`DragWindow` is `pascal void`. It performs the move itself and hands the
application nothing back, so there is no question for a patch to answer and no
application code that runs after it — which makes "answer the question the app
asks" inapplicable rather than merely unnecessary. `MoveWindow`, called in the
target's own context from the GNEFilter hook, is what `DragWindow` would have
done minus the tracking loop and the motion that loop needs.

The other three are patches precisely because the application *does* have work
to do afterwards: it calls `SizeWindow` or `ZoomWindow` itself and then adjusts
its own content. A window resized behind the application's back keeps its
scroll bars where they were.

### `close` promises the app was ASKED, not that the window closed

Stated in the verb rather than left to be inferred, because this op can destroy
a document. `winact close` answers the application's own `TrackGoAway` with
true and the application's own close path runs from there — save-changes dialog
and all. An unsaved document answers with a dialog and the window stays open,
which is reported as `windowGone:false` with `answered:true`: a correct
outcome, not a failure. Calling `CloseWindow` ourselves would close it every
time by throwing unsaved work away with no prompt. Measured on a fresh, empty
untitled window per trial, so the close path had nothing to lose.

### `FindWindow` is patched too, and that is what keeps geometry out of the op

Driving a grow box or a close box otherwise means computing where the WDEF drew
them — a title-bar height and a 15×15 corner that no guest structure reports.
That is a phantom constant by another name. With `FindWindow` answered, the
click may land anywhere in the window (the probe uses the content centre) and
the application is still told which part it hit.

### The bug, found by counter rather than by argument

First run: `move` 3/3, and `resize`, `zoom` and `close` **all 0**, identically,
with `answered` false and `findWindowFired` true. One systematic cause, not
three.

A guarded patch cannot answer, about itself, whether nothing happened because
the trap was never called or because it was called and declined — and those are
opposite repairs. So `trapHits` was added, bumped at the **top** of each answer
function before any guard. It said: `goaway=0`. The trap was never entered.

The cause was upstream. **The application calls `FindWindow` twice per
mouseDown** (`target find=2`, `fwAnswers=1`), and the patch answered only the
first; the *real* `FindWindow` answered the second with `inContent` — a
truthful answer for a click at the window's centre — and sent the application
down its content branch instead of its close branch. The fix is that the arm
stays answerable until the second-stage trap consumes it. Nothing else in the
guard widened: still the exact point we posted, still the target's A5 world,
still an armed window request.

Proven by mutation, on the restored binary with the fix taken back out:

| | `move` | `resize` | `zoom` | `close` |
|---|---|---|---|---|
| Answer at either stage (shipped) | 20/20 | 20/20 | 20/20 | 20/20 |
| Answer only the first `FindWindow` | 5/5 | **0/5** | **0/5** | **0/5** |

`move` is unmoved by the mutation, which is the control: it uses no patch.

### Two documented constants, now also measured

- **`MoveWindow`'s h/v are the content region's top-left** (Inside Macintosh:
  Macintosh Toolbox Essentials, the Window Manager). Asked for (100,90), the
  guest's own `contRgn` — which is what `ax_read_window` reads, at
  `WindowRecord+118` — reads `[100,90,…]`. Request and oracle name the same
  corner.
- **`GrowWindow` packs HEIGHT in the high word, WIDTH in the low word.** Asked
  for 300×180, measured 300×180. Swapped it would have been 180×300, which is
  why the probe never asks for a square.

Trap numbers and part codes are cited twice over: the `ONEWORDINLINE` on each
declaration in `MacWindows.h`, cross-checked against `Traps.h`
(`_FindWindow` 0xA92C, `_GrowWindow` 0xA92B, `_TrackBox` 0xA83B,
`_TrackGoAway` 0xA91E, `_MoveWindow` 0xA91B). The `FindWindow` part codes are
`MacWindows.h:445-456` and are named as `PT_IN_*` rather than spelled inline,
because a second similarly-named set exists — the WDEF message codes
`wInDrag=2` etc at `MacWindows.h:465-470` — and confusing the two is exactly
the shape of the bug that cost `CONTROL_INVOKE` a day.

Every Pascal stack frame was verified against the **compiler**, by compiling a
call to each trap with the 68K toolchain and reading the generated caller, then
checked again by disassembling the shims. The one that would otherwise have
been a silent lie: a Pascal `Boolean` result is a 2-byte slot whose value lives
in the **high** byte (`move.b (%sp),%d0`), so `move.w #1` writes FALSE from a
patch that reports firing. A `short` in the same-sized slot is a full word.

### What this does NOT claim

- **Measured on SimpleText only.** Every rate above is one application. That
  the application calls `FindWindow` twice per mouseDown is now a fact about
  SimpleText, not about Mac OS 9 — and an application that calls it once, or
  three times, is untested. `move` is the least exposed (no patch, no click,
  no dependence on the app's dispatch at all).
- **No-hijack for these ops is argued, not measured.** The `FindWindow` guard
  requires the *exact point the verb posted*, which is structurally the
  `ControlHandle` test that holds at 0/20 rather than the `MenuSelect` guard
  that leaks at 18/20. The supporting number is weak but real: with a request
  armed, `fwAnswers` was 1 while the global `FindWindow` entry count rose by
  4–6 per trial, so every other `FindWindow` in the system chained through.
  Nobody has armed a `winact` and then clicked somewhere else.
- **Re-measured after merging main, not carried over.** The numbers above were
  first taken before main landed the `MenuSelect` click guard and folded the
  agent's copy of `ptshared.h` into a one-line include of the extension's. Both
  change the shared block's layout, so the merged build was re-run on a fresh
  clone and reproduces **20/20 on all four ops**. `winact` refuses a resident
  INIT older than `PT_VERSION` 3 for the same reason `menuinvoke` refuses one
  older than 2: writing a field into a block that has
  no room for it is silent corruption, not an error.
- **The `MENU_INVOKE` leak was fixed on main while this lane ran**, by the same
  identity-check shape. `winact` never had it — its `FindWindow` guard requires
  the exact point the verb posted — but it is worth saying that all three
  Portal ops now guard on identity rather than on self-disarming alone.
- **Emulator only.** No QMP in the path — `PostEvent` for the click and
  Toolbox calls for everything else — which is what "metal-shaped" means, and
  is not the same as a metal-safety review.

## The Portal's `CONTROL_INVOKE` drives both halves of `TrackControl` (2026-07-31)

`ctlinvoke` acts on a control by identity — the app's own `TrackControl` returns
the part code we name, and the app runs its own handler. No coordinate math, no
QMP, no drag. Measured on a fresh mac99 clone, `tests/trials.py`, N=20,
independent trials, oracle = guest state:

| Half | Case | Rate |
|---|---|---|
| Tracking (the app's action procedure, during the call) | `ctlinvoke-scroll` — `inUpButton` on SimpleText's scroll bar; oracle is the control's own `value` | **20/20 reply, 20/20 actuation** |
| Return value (the app's own mouse-down handler, after it) | `ctlinvoke-button` — `inButton` on the save-changes alert's Cancel; oracle is the alert window disappearing | **20/20 reply, 20/20 actuation** |

All four scroll bar parts move the bar the way they are named — `inUpButton`
618→602, `inPageUp` 602→106, `inDownButton` 106→122, `inPageDown` 122→618 —
which is what rules out the injected click having done it: one fixed click point
cannot produce four different, correct answers.

The reply now carries the evidence rather than only its own say-so:
`valueBefore` / `valueAfter` / `valueChanged`, re-read out of the guest after the
patch fires, for controls with a live range. A push button has no range and gets
`hasRange:false` instead — `valueChanged:false` about a button would read as a
failure when it is the wrong question. `answered` still means only that the
app's `TrackControl` returned our part code.

### RETRACTED: "`CONTROL_INVOKE` is built and does not work"

It worked. The scroll bar was unmoved because of **the part code the caller
sent**: `ctlinvoke`'s own doc comment listed 10/11/12/13 for the four scroll bar
parts, and Inside Macintosh / `ControlDefinitions.h` say 20 (`inUpButton`), 21
(`inDownButton`), 22 (`inPageUp`), 23 (`inPageDown`) — 10 and 11 are `inButton`
and `inCheckBox`, and 12 and 13 are not part codes at all. The app's action
procedure was handed a part its scroll bar has no meaning for and correctly did
nothing, while the patch answered truthfully. Reproduced by mutation: force the
part to 12 and the same binary gives reply 100%, actuation 0% — the exact
reported symptom.

Died with it: **the held-button hypothesis**. The idea that the action procedure
consults live input (`StillDown`/`GetMouse`) and no-ops against an
already-released click, and that the fix was to hold `MBState` across the answer,
was never needed. A single unheld action-proc call moves the bar. Whether some
*other* app's action procedure wants a held button is untested, not disproved.

Not claimed: no-hijack (the guard is written and 40 trials produced no stray
actuation, but nobody has armed a request and then clicked a different control),
`inThumb` (129, deliberately not driven — a thumb drag has no single-call
semantics), and metal (untouched; the path has no QMP in it, which is what
"metal-shaped" means, but that is not the same as a safety review).

## All four content planes are live (2026-07-30)

"Windows are all empty" turned out to be three missing verbs, not a design
limit. Only the QuickDraw *op stream* was ever unsourced by design, and it is
now carried too.

| Plane | Verb | What it gives | State |
|---|---|---|---|
| Chrome, controls, menus | `axtree` | windows, titles, refs, values, hit-testing | live |
| Desktop icons | `list` | 17 items with guest-accurate `loc`, type/creator for the icon atlas | live, semantic |
| Window interior | `capture`/`fetch`/`close` | the front window's real pixels (613x538 measured) | live |
| Repaint signal | `qdtrace` | the QuickDraw op stream — what tells the host to re-capture | live |

Measured on a fresh clone with both INITs installed: `qdtrace status` reports
`present:true`, a 64 KB ring, `dropped:0`; record mode on the Finder produced 73
ops immediately, and a live `MirrorApp --display --islands` run saw the stream
grow 79 → 84 → 85 ops across three polls with `bits:9` among them. `bits` is
exactly what `island()` keys on, so interiors are no longer frozen at first
capture — a repaint re-captures.

### Interiors are per-window "last known state"

A window that loses focus **holds its last captured interior** instead of going
blank. An app's pixels only change while it is drawing, which under cooperative
multitasking means while it is frontmost — so capture on launch, on raise, and
while focused, then hold. Only the front window re-captures; background windows
are attached from pixels already held.

Two things that fell out of building it, both worth keeping:

- **Window ids are not stable across a raise.** `win.id` is `psn/title#idx` and
  `idx` *is* z-order (`mirrorverbs.c` walks the WindowList front-first writing
  `z = window_count`; `SceneBuilder` reuses that enumeration index). So raising
  the back document of a multi-window app renumbers ids, and a cache keyed on
  `win.id` would miss on exactly the event this feature exists for, leaking an
  entry per raise. Keys are `psn/title`, with same-titled windows in one app
  split by top-left corner.
- **Stale geometry is attached anyway**, unscaled, anchored at the content
  origin, clipped by the renderer. A resize changes how much is visible, not the
  pixels the guest drew: clipping is truthful on shrink and merely incomplete on
  grow, while scaling invents pixels (1-bit Platinum resamples to mush) and
  dropping regresses to blank. The next raise re-captures.

Eviction carries a 60-poll grace rather than evicting on first miss, because an
app whose AXPeek sample errors drops out of `axtree` for a frame.

Cost, measured rather than assumed — and `ScenePoller`'s "~1 s per full-window
capture" comment is pessimistic for this bench:

| Measurement | Result |
|---|---|
| Semantic planes alone (`axtree`) | ~2 ms per poll |
| A 613x538 front-window capture in the poll | ~150 ms per poll |
| A 402x220 capture plus 2 polls | 0.23 s total |
| 6 polls, front window unchanged | 0.6 s — one capture, the rest reused |

Capture cost scales with area, and in steady state only the front window
captures and only when it repaints, so the retention change makes the common
case cheaper rather than more expensive.

The guest now needs **two** INITs — AXPeek (the address oracle) and QDPeek (the
op stream) — so `guest/extension/` became `guest/extensions/{axpeek,qdpeek}/`
and the rig stages and reboot-verifies both.

## The agent-facing surface works (2026-07-30, extended 2026-07-31)

Since the first pass: `mirror.scene` carries `irVersion` beside the scene (a
compatibility gate has to be readable without decoding the payload it guards),
`mirror.app` gained `op:"list"` returning directly-actionable rows
`{psn, name, front, background, windows, error?}`, and background processes are
excluded by default — a list containing the mirror's own agent invites an agent
to quit the process it is talking through.

Two bugs surfaced while doing it:

- **`mirror.app` never enforced the `semantic` plane it declares.** With
  `planes: []` granted, `activate` still performed while `mirror.act.key`
  correctly refused, because these ops call the wire directly instead of going
  through the shared act path where the check lives. Fixed.
- ~~**`mirror.app {op:"launch"}` is BROKEN and always has been**~~ — it was:
  the guest agent had no `launch` verb, so it returned `unknown_verb` while the
  contract had specified the op since day one. **FIXED 2026-07-31**, see "Three
  guest truths closed" above.
- ~~**`mirror.app {op:"quit"}` is BROKEN in the same way**~~ — the host sends the
  wire verb `apple-event` and the guest had no such verb either. **FIXED
  2026-07-31**, see "`mirror.app {op:"quit"}` works now" below.

`MirrorApp --serve <socket>` came along in the extraction and had never been run
here. It has now, end to end, against a live guest — 7/7 in
`tests/agent-session.py`:

| Step | Result |
|---|---|
| `mirror.attach` | both planes granted, `irVersion 0` (measured 2026-07-31, before the v1 freeze; now `1`), screen 800x600 |
| `mirror.status` | worker healthy, `actAvailability {semantic, tracking}` |
| `mirror.find` | 17 desktopItems, 1 window, 2 controls — element-first, no coordinates |
| `mirror.act.key` cmd+N | `mechanism=keystroke availability=metal-safe`, and **the folder appeared on disk** |
| `mirror.shot` | an 800x600 render of the mirror's own canvas, 53 KB |
| `mirror.wait` | predicate met in 4 ms |
| `mirror.detach` | clean release |

The act was verified in the guest **filesystem**, not by the service's own
report: `performed: true` means the event was dispatched, which is not the same
as something happening — the distinction that cost four retracted findings
earlier this week.

Two things worth knowing about this surface. It is **element-first by contract**
— no method takes screen coordinates, so chrome geometry and QMP motion stay
inside the service as calibration rather than API. And every act reports its
`mechanism` and `availability` class, which is how an emulator-only path can
degrade honestly instead of silently.

The service is also the **one wire client**, which is what resolves
single-connection contention: agents and any human window both go through it.
So do not run `--window` against the same guest port while `--serve` is up.

Evidence: [render-2026-07-30-agent-shot.png](render-2026-07-30-agent-shot.png)
— what the agent sees.

## The renderer works end to end

`MirrorApp --snapshot` against the live agent produced
[render-2026-07-29-graphcalc.png](render-2026-07-29-graphcalc.png): live
`axtree` (13980 B, 2.1 ms, 1 window, 11 controls, 8 menus) → scene → Platinum
render. The menu bar carries Graphing Calculator's real menus, the window has
correct title-bar widgets and grow box, and the `Graph` button is drawn at its
true position. **Window interiors are blank by design** — the content plane is
deliberately unsourced.

One cosmetic wart: SwiftUI logs `Unable to update Font Descriptor's weight`
for Charcoal 14 on every run. Harmless, noisy, unfixed.

## Three guest truths closed (2026-07-31, lane G1)

All three measured on a session-private mac99 clone, oracle = guest state.

### `mirror.app {op:"launch"}` works now

The guest gained a `launch` verb, so the op the contract has specified since
day one no longer answers `unknown_verb`.

**Mechanism: `LaunchApplication`, not the Finder Apple Event.** An `AESend` to
the Finder needs the Finder scheduled and pumping; a Finder in a tracking loop,
showing a modal, or simply not given time answers late or never, and a timed-out
`AESend` is indistinguishable from an app that failed to start.
`LaunchApplication` is a Process Manager call in our own context with a
synchronous `OSErr` — and it is the call the lab worker already uses to launch
this agent during spin-up.

Takes `path`, or `name` resolved by a bounded catalog walk from the boot volume
root (`FindFolder(kOnSystemDisk)`, never a hardcoded `Macintosh HD`), capped in
ticks, directories and depth, with every cap reported so a miss cannot be
mistaken for an exhausted budget. Two matches is `ambiguous`, not a guess.

| Case | Result |
|---|---|
| by path, N=5 independent trials | **5/5 reply, 5/5 actuation** — SimpleText's `untitled` window in `axtree` |
| by name, N=5 independent trials | **5/5 reply, 5/5 actuation** |
| by name, first call cost | 327 directories, complete, 0.45 s on the wire |
| four different apps, cold | SimpleText, Graphing Calculator, Network Browser, Sherlock 2 — window each time |
| refusals | absent app `not_found` (+ dirs searched), bad path segment `not_found` (-120), neither arg `bad_request` |

Trials are independent: each starts by quitting the target (activate + cmd-Q)
and confirming it left `observe`. Launching an app that is already running is a
different act — the Process Manager just brings it to the front — so a trial
without the reset measures nothing.

`launched:true` means `LaunchApplication` returned `noErr` and handed back a
PSN. It is not a claim that a window exists; that is the caller's to verify,
and this project has four retracted findings from taking the weaker report as
the stronger one.

### Apple-menu items are addressable by title

Measured on the Finder's menu bar: all 16 Apple-menu entries below the
separator read `\0\0` + a name, and those 16 names are byte-for-byte the 16
files in `System Folder:Apple Menu Items`, in the same order. The Finder's
Window menu carries `\0Desktop` — **one** NUL.

The NULs are the system's, not a Pascal length-byte misread: the same walk
parses File/Edit/View/Special correctly, reads `0x1b` hierarchical command
bytes, and stops on the item list's own zero-length sentinel. A fixed off-by-N
would corrupt every menu, and could not produce a prefix of two *and* a prefix
of one in the same pass.

`ax_menu_next` now drops **leading** NULs and reports how many as
`titleNulPrefix` (only when non-zero — this frame is budgeted); an embedded NUL
stays visible. One `axtree` frame went from **33 `\u0000` escapes and 17
unmatchable item titles to 0**.

Two things NOT claimed. The **writer** of the prefix is unidentified — Apple's
published Menu Manager documentation describes no NUL prefix, so it is P-OBS
with a `TODO(provenance)` in the source, not an explained mechanism. And the
Apple menu's *contents* are per-application: SimpleText's own `MenuInfo` holds
only `About SimpleText…` and a separator, so the Apple Menu Items entries are
walkable in the **Finder's** menu list and not in every app's.

### A build stamp can confirm a deploy

`kBuildStamp` is now a SHA-1 over every `src/*.{c,h,r}`, name-sorted,
regenerated on every build by `guest/app/cmake/buildstamp.cmake`. It is content,
not clock: any source change moves it, and an unchanged tree reproduces it.

Proven both ways, by mutation:

| | stamp before a `main.c`-only edit | after |
|---|---|---|
| Old code (`__DATE__ " " __TIME__`) | `Jul 31 2026 15:55:09` | `Jul 31 2026 15:55:09` — **unmoved** |
| New code | `573b1e5f8654` | `980e371165bc` — **moved** |

And on the guest, read back from the running binary: a `main.c`-only change
took `hello`'s stamp from `573b1e5f8654` to `8655ea1fac9e`.

## An unread parameter was doing something else, quietly (2026-07-31)

Lane G1 reported this as a suspected key-mapping bug. It is not a mapping bug —
it is a **fail-open surface**, and it is the most dangerous shape a defect can
have on a plane an agent drives blind.

`mirror.act.key {key: "q", modifiers: ["command"]}` — the contract's name for
that field is `mods`. `modifiers` was never read, and **an unread parameter is
indistinguishable from an absent one**, so the service pressed an unmodified
`q`: a literal character went into an open document, dirtied it, raised a
save-changes alert, and the reply said `performed: true`. ⌘Q became typing `q`.

The asymmetry is the lesson. A misspelled *value* was already caught
(`unknown mod command`). A misspelled *key* was not — and that is the worse
half, because the failure mode of a dropped modifier is not "nothing happens",
it is "a different thing happens, silently, and the reply says it worked."

**All seven mutating methods now refuse a parameter they do not know**, naming
both what they got and what they accept — a bare "unknown parameter" leaves the
caller guessing which spelling is real, which is the whole failure. `mods` as a
bare string rather than a list is refused too, for the same reason. Read-only
methods are not gated yet and the contract says so.

The accepted sets are derived from **what each method's code actually reads**,
not from the contract prose, and that immediately paid for itself:
`settleTimeoutMs` is consumed by `performAct` *after* a method returns, so it
appears in no method's signature. A set written from the prose would have
rejected a parameter that has always worked — the same class of bug running in
the other direction.

Writing the sets down exposed three parameters the contract promised and the
service never honoured: `mirror.scene`'s `scope` (a launch-time poller flag,
never read per call), `mirror.act.menu`'s `allowDrag` (withdrawn with the drag
mechanism it gated), and `mirror.act.open`'s `windowItem` (specified, never
implemented). All three are corrected in `mcp/mirror-service-ipc.toml`. A
contract that lists a parameter nobody reads is worse than one that omits it:
it is a promise a caller can act on.

## `mirror.app {op:"quit"}` works now (2026-07-31, lane G1)

The same hole as `launch`, one op over: `Serve.swift` sends the wire verb
`apple-event` with `{event:"quit", serialHi, serialLo}` and the guest's dispatch
table had no `apple-event` verb, so every quit answered `unknown_verb`. The
guest now has one, ported from the lab's `verb_apple_event` as a **fact, not a
function** — same `quit`/`oapp`/`odoc`/`pdoc` whitelist, same PSN addressing
through `AECreateDesc(typeProcessSerialNumber)`, our own code.

Unlike `launch` there was no second mechanism to weigh. The Process Manager has
no "ask this application to quit"; the alternatives are the Apple Event or a
cmd-Q keystroke, and the keystroke is input injection on a different plane that
also requires stealing focus first.

The send is fire-and-forget (`kAENoReply`) — waiting for a reply would block the
agent's single-threaded loop on a foreign application's event loop — so the
result says **`sent`, never `performed`**, and the oracle is the target leaving
`observe`. `kAECanInteract` is deliberate: it is what lets a target with an
unsaved document put up its save-changes alert instead of the send failing.

All measured on a session-private mac99 clone, agent build `4df0b3552b04`:

| Case | Result |
|---|---|
| SimpleText, clean document, N=3 independent trials | **3/3 reply, 3/3 actuation** — left `observe` in 1.2 s each |
| through `mirror.app {op:"quit", name:"SimpleText"}` over the service socket | left the scene in 1.2 s — the product path, not just the wire |
| SimpleText with an **unsaved** document | **stays running**, behind a `Save` / `Don't Save` / `Cancel` alert that `axtree` reports with all three controls addressable |
| refusals | event outside the whitelist, missing serials, missing event, `odoc` with no path → `bad_request`; `odoc` path that names nothing → `not_found` (-120); a PSN naming no process → `not_found` (`AESend` -600) |

**The unsaved-document case is a correct outcome, not a defect.** A well-behaved
application answers a quit Apple Event by asking about its document, and the
verb's job ends at delivery. `tests/apple-event-probe.py` reports which of the
two happened and passes either way — forcing it would mean discarding a
document, and the alert is addressable by ref if a caller wants to resolve it.

Watched to fail: with `kAEQuitApplication` swapped for `kAEOpenApplication` and
the mutant redeployed, the verb still answered `sent:true` and the probe failed
on guest state — the target stayed running and grew a second `untitled` window.
That is exactly the reply-versus-actuation gap the oracle exists to catch.

Two departures from the lab's copy, both deliberate: `reply` is initialised to a
null descriptor before `AESend` (an early error may not write it, and disposing
stack garbage is a crash we would have to reproduce on metal to believe), and
`procNotFound` (-600) reports `not_found` rather than `ae_error`, because a
stale PSN from an older `observe` is not a broken guest.

## Open defects

0. ~~**The `MENU_INVOKE` guard leaks.**~~ **FIXED 2026-07-31** — 18/20 → 0/19
   with the legitimate rate intact; see "The menu hijack is CLOSED" above.

   Two findings from that measurement are still open, and neither is fixed by
   the guard:
   - **The guest never ages a request out.** Only the host verb's exit path or
     `portal {enabled:false}` clears `armed`, so an agent that dies mid-verb
     leaves a patch armed indefinitely. A safety property should not depend on
     the caller surviving. (Narrower now — an abandoned arm can only be taken by
     a press within ±2px of the point the dead verb intended — but still real.)
   - **Both arming verbs warp the user's pointer** (`post_click_at` writes
     `MouseTemp`/`RawMouseLocation`/`MouseLocation`). Rude to a human at the
     mirror, and it corrupts measurements.

1. **`push_stream` reports `catalog dates err -43`** on every push to this
   image while the bytes land correctly (resource-fork size and timestamps both
   right afterwards). Tolerated explicitly in `tools/stage-agent.py`, and only
   ever with the post-write verify still required. A *lab instrument* quirk in
   the baked anchor worker's put channel, not a defect here.

2. ~~**Drag and command-key-less menus are still unreachable.**~~ **CLOSED
   2026-07-31 for menus and controls** — the Portal invokes both by identity
   (`MENU_INVOKE`, `CONTROL_INVOKE`), so no tracking loop has to be entered and
   no QMP is in the path. **Drag itself is still open** and is `WINDOW_ACT`'s
   job. The original text is kept below because its diagnosis is still the
   reason the Portal exists.

   `PostEvent` cannot
   drive an app that has entered a tracking loop, and the lab's answer — QMP
   `input-send-event` — is emulator-only, which MIRRORKIT-PLAN forbids as a
   load-bearing mechanism. Journaling **reaches inside a live `TrackControl`
   loop** — the thing `PostEvent` cannot do — but `JournalFlag` is a per-process
   low-memory global and cannot be armed for a foreign process *from outside*.
   Whether it can be armed *from inside*, by a hook running in the target's
   context the way AXPeek already does, is **untested and open**
   ([JOURNALING.md](JOURNALING.md)).
   The remaining honest route is **per-item geometry from the guest**: the Menu
   Manager knows each item's height, so a verb could report item rects instead
   of the host assuming uniform 16 px rows — which is the assumption that made
   menu selection hit the wrong row in the first place.

3. ~~**A build stamp cannot confirm a deploy.**~~ **FIXED 2026-07-31** — the
   stamp is a hash over the sources; see "Three guest truths closed" above.

**Withdrawn, kept as the record:**

- ~~`key` actuates ~9 times per boot~~ — the oracle accumulated; 20/20 with
  independent trials, and 45 consecutive keystrokes land.
- ~~The watchdog resets a connection when our own main loop is busy~~ — no such
  defect; it was a non-retrying test client.
- ~~`axdo` starves the agent / poisons the session~~ — `axdo` scrolls a real
  scrollbar; the story was two bugs in the test client.
- ~~The `WaitNextEvent` mask comparison~~ — measured under the broken oracle, so
  void rather than known. `main.c` keeps `everyEvent` because it measures good.

## Text, in the application's own context (Portal ops 6 and 7) — 2026-07-31

`textget` / `textset` read and write a text field from **inside** the target
process. Built as op 5 in lane P2 and renumbered at merge, because
`WINDOW_ACT` — developed in parallel — took 5 first and was already deployed.
The merged header is `PT_VERSION` **4**: two struct layouts both calling
themselves 3 is exactly what the version field exists to prevent, so the text
verbs refuse a resident INIT below 4. Measured on a session-private mac99 clone, N=20 independent trials per
kind, dialog closed and reopened each trial, a value unique to each trial.

| Kind | What it names | read | write | independent oracle agrees |
|---|---|---|---|---|
| `ditem` | a dialog item, 1-based | 20/20 | 20/20 | 20/20 |
| `dialogte` | the dialog's live TERec (`DialogRecord.textH`) | 20/20 | 20/20 | 20/20 |
| `te` | a `TEHandle` the caller supplies | 20/20 | 20/20 | 20/20 |

The independent oracle is `axtree`'s per-window `textEdit.text`, which
`axtext.c` reads from **outside** the process over the `ax_memory` seam — no
shared code, call or moment with the Portal. `textset`'s own read-back is real
evidence but it cannot rule out a verb reporting its own copy of a string.

**And the application agrees**, which is the claim a shadow copy would break:
SimpleText's Save As filename is `editText` item 10, so writing a name and
pressing Return produces **a file on disk** — 8/8, in
`Macintosh HD:Desktop Folder:`, under exactly the name written.

**No hijack: 0/20.** These ops install no trap patch — a TE record is not a
question the app is about to ask — so there is no armed window and no
user's-call-answered hijack to have. The question takes the form that can lose
data instead: with a `textset` aimed at the `statText` label, the user's own
typing in the `editText` field beside it survived 20/20, and a request naming a
window outside the target's window list was refused 20/20.

Reproduce (a guest must be up, e.g. `tools/spin-up.sh`):

```
python3 tests/textops-probe.py --agent-port <p> --anchor-port <p> --n 20
python3 tests/textops-probe.py ... --case saveas --n 8
python3 tests/nohijack-probe.py ... --case text --n 20
```

### One real defect, found by measuring and fixed

A caller-supplied `TEHandle` was dereferenced **twice** — `(**te).inPort` — before
anything established that the integer addressed memory. `handle:1234` did not
answer `bad_handle`: it timed out and **took SimpleText's open dialog with it**.
On a system with no memory protection that is our mistake killing somebody
else's application, which is exactly what the hook is supposed never to do.
`pt_handle_in_heap()` now range-checks the handle and its master pointer against
`ApplZone`'s limits before any dereference — the discipline `pt_shared` and
`qd_shared` already use for the system heap. The mutation evidence is the
before/after itself: the same probe destroys the dialog on the pre-fix binary
and answers `bad_handle` eight times over, dialog alive, on the fixed one.

### Not tested, stated as clearly as the rates

- **Only SimpleText**, and only its Find and Save As dialogs. No other
  application was driven at all.
- **No application *document* TextEdit view.** `kind:"te"` is the door to one
  and is verified end to end on a handle the guest reported — but **discovering**
  an app's private `TEHandle` is not implemented, and we found no documented
  route to it from here. The Dialog Manager publishes `DialogRecord.textH`; an
  application publishes nothing.
- **Pixels.** The redraw path runs (`TECalText` / `EraseRect` / `TEUpdate` /
  `InvalRect`, port saved and restored) and the TERec agrees, but nothing
  compared the screen.
- **Text over 255 bytes, and non-ASCII MacRoman.** The buffer is Str255-shaped
  because `GetDialogItemText` takes a `Str255`; a longer record reports
  `truncated:true` with its true `length`, and that path is untested.
- **Reentrancy** is the same open question every op has: Dialog Manager and
  TextEdit calls at `GNEFilter` time were fine here, and that is not a proof.

### Found and left alone

Staging a fresh clone died on `mirror.port` already existing in the base image
(`write` needs `overwrite:true`) — fixed in `tools/stage-agent.py`, because it
blocked every spin-up. Separately: **only the agent has a build stamp.** A
changed Portal INIT ships with the agent reporting an unchanged
`build=`, so `hello` cannot tell you which extension is loaded. Behaviour proved
the new INIT was live here; nothing in the wire did.

## Not yet done

- ~~**`mirror.app {op:"quit"}` is broken exactly the way `launch` was**~~
  **CLOSED 2026-07-31** — the guest has an `apple-event` verb now; see
  "`mirror.app {op:"quit"}` works now" above.
- ~~**`WINDOW_ACT` and `TEXT_GET`/`TEXT_SET`**~~ **BOTH CLOSED 2026-07-31** —
  `WINDOW_ACT` was what removed QMP from the act plane, and with it the last
  emulator-only mechanism the plan forbids as load-bearing; see "`WINDOW_ACT`
  removes QMP from the act plane" and "Text, in the application's own context".
  The two lanes ran in parallel and both authored themselves as Portal op 5;
  `WINDOW_ACT` landed first and kept it, so the text ops are **wire ops 6 and
  7**. `PORTAL-PLAN.md`'s catalog still numbers them 4 and 5 as *plan* entries.
- **The Portal is still default-ON.** The flip to default-off is part of the 0.1
  checklist: one constant plus wiring the enable into `tools/spin-up.sh`.
- **No per-op metal-safety review exists.** Everything is mac99 by the standing
  rule, and the review is a prerequisite for a real machine, not a formality.
- **The A5 cross-process guard has never been reached**, because a background
  target does not arm. Whether driving one application can fire a command in
  another is open — the blast-radius question.
- **`irVersion` agreeing in flight is inferred, not observed.** The freeze lane
  ran no VM: that the envelope key and the body stamp match rests on reading
  `Serve.sceneMethod`, not on a captured live reply. One `mirror.scene` call
  against a live guest closes it.
- **Platinum fidelity has not been judged.** The renderer runs live against the
  guest with all four planes, but whether it *looks* right is a human call and
  the one thing here no measurement replaces.
- **Metal is untouched.** Everything is mac99. The emulator gate comes first and
  a real machine is attended.
- ~~**Finder folder windows render as pixels, not icons.**~~ — **done
  2026-07-31** (lane `lane/h2-folder-icons`). The guest gained the `script`
  verb the host had been calling all along, and the positions came from the
  Finder's own live `position of` rather than the saved `fdLocation` grid —
  those are different quantities, and the saved one is wrong by an unbounded
  amount once a window scrolls. `includeWindowItems` is ON, `windows[].items`
  re-entered the IR additively, and folder icons are addressable at last
  (`mirror.act.open {windowItem}`, `mirror.find {kind:"windowItem"}`).
  Measured **40/40** — a click computed from an item's reported position
  selected that item, at rest and after scrolling — against **0/40** for the
  same code reading `fdLocation`. [FOLDER-ITEMS.md](FOLDER-ITEMS.md); what was
  not tested is listed there, and list-view windows are the notable gap.
- **Only the front window captures.** Background windows show their held
  interior, which is the intended behaviour, not a gap — but a window never
  focused since launch has no interior to hold.
- `axtree scope=all`, dialog/TextEdit reads, and the control-value plane are
  carried but unexercised here.
- ~~**IR v1 freeze / the parity gate**~~ — **done 2026-07-31**
  (lane `lane/h1-ir-freeze`). `irVersion` is `1`, the fixture corpus is pinned
  to it, `MirrorScene.decode` refuses an unknown major before decoding, and
  `IRFreezeTests` goes red when the shape drifts. Field-by-field calls and the
  two fields deliberately left OUT of v1: [IR-V1.md](IR-V1.md).

## The menu hijack is CLOSED (2026-07-31)

Measured on a fresh mac99 clone with the same `tests/nohijack-probe.py` that
found it, and it had to clear **two** bars: block the hijack *and* leave the
legitimate request working. A guard that refuses everything scores perfectly on
the first and is worthless.

| | before (main) | after |
|---|---|---|
| armed request fires on the user's click | **18/20** | **0/19** |
| the user's own click does what they asked | 0/20 | **19/19** |
| legitimate `menuinvoke` (File → New Folder) | 20/20 | **20/20** |
| control cross-fire (unchanged path) | 0/20 | **0/20** |
| stale arm | 0/18 | **0/20** |

The second row is what shows this is a guard and not a wall: before, the hijack
*consumed* the user's click, so their menu never opened at all.

**The fix.** A menu press carries no handle to name, so the identity checked is
the press itself — the verb synthesises the click, so it already knows the exact
point `MenuSelect` will receive. The point is now part of the armed request
(`armPointH`/`armPointV`), the trampoline hands `MenuSelect`'s `Point` down to
the C guard, and a press anywhere else chains through. Tolerance ±2px rather
than exact, because an application may hand `MenuSelect` an adjusted point and a
guard that errs strict breaks the legitimate request instead of the hijack.

Two hazards closed on the way, both of the "would have failed silently" kind:

- **`PT_VERSION` 1 → 2, and `verb_menuinvoke` refuses version < 2**
  (`portal_stale`). A resident INIT from an older install has no `armPointH`
  field, so arming it would leave the guard off while the caller believed it on.
- **`guest/app/src/ptshared.h` was a byte-identical COPY** of the extension's
  header; it is now a one-line include. Two copies of a shared-memory ABI do not
  fail to build when they drift, they fail to *agree*, and a struct-offset
  disagreement across a shared block is silent corruption. It surfaced only
  because the new fields broke the agent's build first — the lucky ordering.

**A precondition failure nearly cost the fix.** The first legitimate-rate run
came back **0/20 with `answered: true`** — the exact CONTROL_INVOKE shape — and
for a moment the guard looked like it was blocking the real request. It was not:
the hijack probe had just opened *About This Computer* nineteen times, and with
that window frontmost the Finder's File → New Folder is inapplicable, so the
Finder received the command and correctly ignored it. Closing the leftover
windows gave 20/20 on the same binary. This is the same lesson `key-cmd-n`
against Graphing Calculator taught once already: **a rate measured without its
premise enforced is a confident, meaningless number.**

**What this does not say.** The before-numbers are the earlier lane's run
against main's binary with the identical probe — a build-to-build comparison,
not a same-session mutation with the bug put back, which is weaker and is
recorded as such. The chain-through columns stay stimulus-limited (17/20 and
19/20 here) for the reasons below, not Portal-limited. The A5 cross-process
guard is still unreached. Emulator only.

## How it was found: no hijack (Portal acceptance 3) — measured 2026-07-31

**The `CONTROL_INVOKE` guard holds. The `MENU_INVOKE` guard does not.** With a
menu request armed, a real user's press on a *different* menu executes the
armed command — 18 out of 18 times that the press reached the application's
`MenuSelect`. This gates the later Portal ops, so it is stated first.

Measured on a session-private mac99 clone with
`tests/nohijack-probe.py`, N=20 per case, independent trials, oracles in guest
state:

| Case | Armed | The real click | Hijacks | The click's own effect |
|---|---|---|---|---|
| Baseline | nothing | Apple menu → About This Computer | 0/5 | 5/5 |
| Control cross-fire | `ctlinvoke inPageUp` on a hidden control | the live scroll bar's **down arrow**, same window, same process | **0/20** | 18/20 |
| Menu cross-fire | `menuinvoke` Finder **File → New Folder** | Apple menu → About This Computer | **18/20** | 0/20 |
| Stale arm | the same menu request, clicked 10 s after it timed out | the same | **0/18** | 12/18 |

Reproduce (a guest must be up, e.g. `tools/spin-up.sh`):

```
python3 tests/nohijack-probe.py --agent-port <p> --anchor-port <p> \
    --case baseline --case control --case menu --case stale --n 20
python3 tests/nohijack-probe.py ... --case window     # the disarm sweep
```

### The leak, and why the other patch does not have it

`pt_trackcontrol_answer` tests four things: armed, the op, the A5 world, **and
that the request names THIS `ControlHandle`**. `pt_menuselect_answer` tests the
first three and stops. Nothing in it looks at *which menu the user pressed* —
`MenuSelect` is answered with the armed `(menuID, item)` whatever the click
was, because the patch has no idea where the click was. The verb's own
`titleLeft` is the only place that information exists, and it is not carried
into the shared block.

So the control op is safe for the reason the plan hoped, and the menu op is not
safe for a reason the plan did not name: `docs/PORTAL-PLAN.md` says "the patch
disarms after one use, so a real user click is never hijacked". One use is the
guarantee — and the leak is that the ONE use is whichever `MenuSelect` comes
first, ours or the user's.

**Exposure window, measured rather than assumed** (`--case window`, one trial
per delay, click at T+delay after the request was sent):

| +0.5s | +1s | +2s | +3s | +4s | +5s | +6s | +8s | +12s |
|---|---|---|---|---|---|---|---|---|
| hijack | hijack | hijack | hijack | hijack | clean | clean | clean | clean |

Between 4 and 5 seconds — which is the verb's own 300-tick wait timing out and
clearing the arm (`verb_menuinvoke`, `verb_ctlinvoke`). **The guest never
disarms on its own.** Nothing in the INIT ages a request out; `armed` is
cleared by the host verb on its way out, or by `portal {enabled:false}`. An
agent that dies mid-verb therefore leaves the patch armed indefinitely — not
measured, but it follows from the code and is worth naming.

The stale case is the reassuring half: a request that timed out is genuinely
gone. 0/18, with the folder oracle watching disk.

### What this does NOT say

- **The A5 guard is still untested, and could not be tested this way.** Both
  controls in the control case are in one process, deliberately, because that
  is where only the `ControlHandle` test can save you. The cross-process case
  (`--case cross`: arm SimpleText's File → New in the background, then click
  the Finder's Apple menu) never got as far as the guard: **6/6
  `portal_timeout` — a background application does not arm.** Its hook only
  serves when it runs, and a suspended app does not run, which is
  `PORTAL-PLAN.md`'s "suspended targets" question answering itself. So the
  blast-radius question — can driving one application fire a command in
  another — remains open, and the route to it is a target that is alive and
  pumping while something else is frontmost.
- The chain-through columns are limited by the *stimulus*, not by the Portal.
  Positioning inside an armed window is open-loop (the wire is busy), so the
  press lands within about ±10px, and the Apple menu's title is only ~20px
  wide with padding either side: a press in the padding is still `inMenuBar`,
  so it still triggers a hijack, but it opens no menu and can select nothing.
  That is why the menu case reads 18/20 hijacked and 0/20 selected while the
  baseline — whose hop is learned moments before, with feedback — selects 5/5.
  A trial that selected nothing also created no folder, so it is silent about
  hijacking, not evidence for it.
- Menu tracking does **not** reliably starve the agent, so "the app was in its
  tracking loop" was tried as an oracle and abandoned; it is recorded in the
  JSON as `tracked` and not scored.
- Emulator only. No metal.

### Two things the next lane should know

1. **A fix for the menu leak exists and is cheap**: the patch already receives
   `MenuSelect`'s `startPt`. Carrying the `titleLeft` the verb posts into the
   shared block and requiring the press to be on that title (and in the menu
   bar) would make a click on any *other* menu chain through — the same shape
   as the `ControlHandle` test that already works. Not implemented here: this
   lane does not own `guest/**`.
2. **Both arming verbs move the user's pointer.** `post_click_at` writes
   `MouseTemp`/`RawMouseLocation`/`MouseLocation` before posting, so a Portal
   call warps the cursor to the target's centre. Harmless for an agent, visible
   to a human at the mirror — and it is what made the first version of this
   probe click the wrong thing and report a confident 0/2.
