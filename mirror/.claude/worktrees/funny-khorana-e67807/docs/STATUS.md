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

1. **`push_stream` reports `catalog dates err -43`** on every push to this
   image while the bytes land correctly (resource-fork size and timestamps both
   right afterwards). Tolerated explicitly in `tools/stage-agent.py`, and only
   ever with the post-write verify still required. A *lab instrument* quirk in
   the baked anchor worker's put channel, not a defect here.

2. **Drag and command-key-less menus are still unreachable.** `PostEvent` cannot
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

## Not yet done

- **Platinum fidelity has not been judged.** The renderer runs live against the
  guest with all four planes, but whether it *looks* right is a human call and
  the one thing here no measurement replaces.
- **Metal is untouched.** Everything is mac99. The emulator gate comes first and
  a real machine is attended.
- **Finder folder windows render as pixels, not icons.** The semantic route
  needs the `script` verb to resolve a window title to an HFS path, and
  `ScenePoller` gates it behind `includeWindowItems` because the item positions
  are not guest-accurate yet.
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
