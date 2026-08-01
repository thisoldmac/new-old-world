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
- **`mirror.app {op:"launch"}` is BROKEN and always has been** — the guest agent
  has no `launch` verb, so it returns `unknown_verb` while the contract has
  specified the op since day one. Not yet fixed: it needs a guest-side verb.

`MirrorApp --serve <socket>` came along in the extraction and had never been run
here. It has now, end to end, against a live guest — 7/7 in
`tests/agent-session.py`:

| Step | Result |
|---|---|
| `mirror.attach` | both planes granted, `irVersion 0`, screen 800x600 |
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

3. **A build stamp cannot confirm a deploy.** `kBuildStamp` is `__DATE__
   __TIME__` in `mirrorverbs.c`, so a change to `main.c` alone ships a binary
   whose reported stamp is unchanged. Bit me once; still unfixed.

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
- **IR v1 freeze / the parity gate** — MIRRORKIT-PLAN's maturity ritual, not
  started. The scene IR is still version 0 and explicitly unstable.
