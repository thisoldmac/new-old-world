# The Portal — plan

**Goal: full automation of a Mac OS 9 machine, driven identically by a human at
the mirror or an agent over MCP.** Not "a remote screen with a click-through",
and not a script that knows where things happen to be drawn. Every element
addressable by identity, every action performed as the application's own code
would have performed it.

Status: the read half works (2026-07-31). This plan covers the rest.

## The reframe

Everything the act plane could not do turned out to be hard for one reason: we
were outside the process.

| Wanted | Why it failed from outside |
|---|---|
| Menu items that line up | The guest reports no item geometry, and there is none to report from out there |
| Shortcut-less menu items | Needs a tracking loop we cannot enter |
| Drag | Same, and the workaround (QMP) is emulator-only |
| Journaling a foreign app | `JournalFlag` is per-process |
| Any control by identity | Coordinates guessed from chrome assumptions |

Every row is the same row. And AXPeek has been **inside every application since
last year** — a `GNEFilter` INIT runs in each app's context with its A5 world
current, which is the only reason per-process Toolbox roots are visible at all.
We built the window and only looked through it.

Inside the process, none of those problems exist. Per-process low memory is just
memory. The Menu Manager will say where its items are if asked. A tracking loop
is not an obstacle because we are already running underneath it.

## The primitive

One INIT, one system-heap block published via `Gestalt('TBpt')`, seqlock
coherence — the shape AXPeek already proved. The host posts a request addressed
to a target **A5 world**; the hook serves it the next time it finds itself
running as that process, and writes the reply back.

Two properties that are not incidental:

- **Addressing is by A5 inside the hook** (one low-memory read), because a PSN
  would need Process Manager calls that are not safe there. The *wire* still
  takes a PSN like every other AX verb; the agent resolves it through AXPeek's
  oracle, which exists for exactly this.
- **The caller must yield, not spin.** Cooperative multitasking means a busy-wait
  holds the CPU in our process, so the target never runs and never serves — a
  spin does not merely waste time, it guarantees its own timeout. Measured.

## Operation catalog

Ordered by value, with what each unlocks.

| # | Op | Unlocks | State |
|---|---|---|---|
| 1 | `MENU_GEOMETRY` | real per-item rects; menu selection stops missing | **done** |
| 2 | `MENU_INVOKE` | shortcut-less menu items — the largest hole in the act plane | next |
| 3 | `CONTROL_INVOKE` | controls by identity with no coordinate math | **done** (both halves, 20/20 each) |
| 4 | `WINDOW_ACT` | move/resize/zoom/close without a drag, so metal stops needing QMP | after |
| 5 | `TEXT_GET`/`TEXT_SET` | field contents read and written in-context | later |

### 2. `MENU_INVOKE` — the design

The app's own path is: `GetNextEvent` returns a `mouseDown` in the menu bar →
the app calls `MenuSelect` → it returns a packed `(menuID, item)` → the app
dispatches its own command handler. We want the app to run **its** handler, not
to simulate a user well enough to fool it.

So: **patch `MenuSelect` in the target, return the answer, skip the tracking
entirely.**

1. The Portal patches `_MenuSelect` once at INIT time. The trap table is
   system-wide, so the patch is guarded: it acts only when a request is pending
   *and* the current A5 matches the target. Otherwise it chains straight through.
2. A request arms `(menuID, item)`.
3. A `mouseDown` is posted at the menu title — whose position we *do* know, since
   menu bar titles carry `left` — because the app only calls `MenuSelect` in
   response to one.
4. The patch returns the packed result immediately. No menu is drawn, no tracking
   loop runs, nothing depends on mouse motion or timing.
5. The patch disarms after one use. **This was written as a safety property and
   it is not one — corrected 2026-07-31.** One use is the *guarantee*; the leak
   is that the one use may be the USER'S. Measured: 18/20. See below.

Why this is better than making the drag work: with real geometry (op 1) a
coordinate drag *would* now land correctly, but it would still be open-loop
motion through mouse acceleration, still emulator-only via QMP, and still
timing-dependent. Returning the answer is deterministic and works on metal.

### 3. `CONTROL_INVOKE` — done, both halves (2026-07-31)

A guarded `_TrackControl` patch, armed against a specific `ControlHandle`,
answering with a caller-supplied part code and calling the app's action
procedure once before it returns. Measured on mac99 with `tests/trials.py`,
N=20, independent trials, the oracle being guest state every time:

| Half | What runs | Case | Rate |
|---|---|---|---|
| Tracking | the app's **action procedure**, during the call | `ctlinvoke-scroll` — `inUpButton` on SimpleText's scroll bar, oracle = the control's own `value` | **20/20 reply, 20/20 actuation** |
| Return value | the app's **own mouse-down handler**, after the call | `ctlinvoke-button` — `inButton` on the save-changes alert's Cancel, oracle = the alert window disappearing | **20/20 reply, 20/20 actuation** |

All four scroll bar parts drive the bar in the direction they name, which is
what rules out "the click did it": `inUpButton` 618→602 (one line), `inPageUp`
602→106, `inDownButton` 106→122, `inPageDown` 122→618. A click at a fixed point
cannot produce four different, semantically correct answers.

`sawActionProc` distinguishes the two halves in the reply, which is the reason
it is recorded: SimpleText's scroll bar passes a **real ProcPtr**, and the
alert's Cancel button passes `0xFFFFFFFF` — the Control Manager's "use the
control's own" sentinel, which is not a callable address and which the patch
declines rather than jumping to.

Reproduce: `python3 tests/ctlinvoke-probe.py --agent-port <p> --anchor-port <p>`
(add `--case button`), then the two `trials.py` cases for the rate.

#### RETRACTED: the action-procedure hypothesis, and what it actually was

This section previously said the op did not work, and named a next hypothesis:
that the action procedure consults live input (`StillDown`, `GetMouse`,
`TestControl`) and no-ops because the injected click is already released, so the
fix would be to hold the button via low-memory `MBState`. **That is not what was
wrong, and holding the button was never needed.** A single, unheld action-proc
call moves the bar.

The scroll bar was unmoved because of the **part code the caller sent**.
`ctlinvoke`'s own doc comment listed `10 (inUpButton), 11 (inDownButton), 12
(inPageUp), 13 (inPageDown)`. Inside Macintosh and `ControlDefinitions.h` say:

| Part | Value |
|---|---|
| `inButton` / `kControlButtonPart` | 10 |
| `inCheckBox` / `kControlCheckBoxPart` | 11 |
| `inUpButton` | 20 |
| `inDownButton` | 21 |
| `inPageUp` | 22 |
| `inPageDown` | 23 |
| `inThumb` / `kControlIndicatorPart` | 129 |

So 10 and 11 are the *button* parts, and 12 and 13 are not part codes at all.
The app's action procedure was handed a part its scroll bar has no meaning for
and correctly did nothing, while the patch answered truthfully. Confirmed by
mutation rather than by argument: with the part forced to 12, the same binary
gives **reply 100%, actuation 0%** — precisely the reported symptom.

Two lessons, both already in this repo's rules and both bitten anyway. Phantom
constants are not only a hazard in device models: a wrong number in a *comment*
propagated into every caller. And "`answered:true` but nothing happened" pointed
at the mechanism when the caller's argument was wrong — the honest reply was
doing its job and was read as an accusation against the patch.

Still open, and not claimed:

- **No-hijack (acceptance 3) is untested here.** The guard is written (armed +
  matching A5 + matching `ControlHandle`, self-disarming) and 40 trials produced
  no stray actuation, but nobody has armed a request and then clicked a
  *different* control to watch it chain through.
- **`inThumb` (129) is deliberately not driven.** The patch skips the action
  proc for it; a thumb drag has no single-call semantics.
- **Metal is untouched.** The mechanism is in-guest Toolbox calls and there is
  no QMP in the path, which is what "metal-shaped" means — but "can" is not
  "may" until the safety review.
- **Whether some other application's action procedure wants a held button** is
  untested, not disproved. SimpleText's does not.

### 4 — the same trick, now that 3 is proved

`TrackControl` and `DragWindow` have the identical shape: the app calls them and
acts on what they return. A guarded patch that returns the intended part code or
the intended new rect makes the app do what it would have done, with no motion at
all. That is what removes QMP from the act plane and, with it, the last
emulator-only mechanism the plan forbids as load-bearing.

## Safety and robustness

The posture is deliberate, not incidental. This runs in other applications'
contexts on a system with no memory protection: our mistake takes their app or
the machine down. On a disposable clone that is a reboot, which is the right
price for what it buys — and it is exactly why the rules below are rules.

- **AXPeek stays observe-only.** The Portal is a separate INIT so that contract
  is not quietly rewritten. Two extensions, two postures, both legible.
- **Guarded patches, always.** A trap patch acts only for an armed request in the
  matching A5 world, and chains through otherwise. A patch that fires for a real
  user is a bug, not a side effect.
- **Single-flight, and self-disarming.** One request in flight; every op disarms
  after one use.

  **"Nothing stays armed across a user's own interaction" used to follow that
  sentence. It was false, and measuring it is how we found out (2026-07-31).**
  Self-disarming says only that the patch fires once — it says nothing about
  *whose* call it fires on. `pt_menuselect_answer` checks armed + op + A5 and
  stops, so it answers whichever `MenuSelect` arrives first, ours or the user's:
  with a request armed, a real press on a DIFFERENT menu ran the armed command
  18/20. `pt_trackcontrol_answer` additionally requires the request to name that
  exact `ControlHandle`, and hijacked 0/20 under the same test. **The identity
  check is the guard; disarming is not.** Every patch gets one, and every patch
  gets a no-hijack case in `tests/nohijack-probe.py` — this sat undetected
  because acceptance 3 was written down and never run.

  Two smaller facts from the same measurement: the **guest never ages a request
  out** (only the host verb's exit path or `portal {enabled:false}` clears
  `armed`), so an agent that dies mid-verb leaves a patch armed indefinitely —
  a safety property should not depend on the caller surviving. And both arming
  verbs **warp the user's pointer**, which corrupts measurements as well as
  being rude to a human at the machine.
- **Bounded waits with an honest timeout.** A frontmost app answers in a couple
  of ticks; a suspended one may never. Say so rather than hang the wire.
- **Allocation-free in the hook**, and touch only handles the Toolbox just
  handed us.
- **A bypass switch, in the shared block.** `portal {enabled:false}` and the
  Portal does nothing: the hook returns before it looks at anything and the
  MenuSelect patch chains straight to the real trap. The extension stays
  installed and the patch stays installed — we never unpatch, because a trap
  patch that vanishes while a caller is inside it is a worse hazard than one
  that stays and does nothing. The switch is a plain word the host writes, NOT
  a request the hook serves, so turning it off is immediate and does not need
  the target process to be alive, frontmost, or pumping. A kill switch that
  depends on the cooperation of the thing it protects you from is not a kill
  switch. Disabling also clears any armed request.

  **Decided 2026-07-31 (Michelle): on for now, flipped at a stable 0.1.** It
  suits a disposable clone and keeps the current tests honest, and the flip is
  one constant plus wiring the enable into `tools/spin-up.sh`. Treat it as part
  of the 0.1 checklist rather than a loose end: an extension that is inert until
  asked is the posture that makes installing this on a real machine a decision
  rather than a side effect.
- **Emulator only** until each op has a metal-safety review. The mechanism is
  in-guest OS calls, so it *can* work on metal — that is the point — but "can"
  is not "may".

## What it does to the contract

`mcp/mirror-service-ipc.toml` already says the surface is element-first and that
no method takes screen coordinates. Today that is aspiration held up by
calibration hidden inside the service. The Portal makes it true: identity goes in,
the app's own code runs, and coordinates never enter the contract at all.

That serves both drivers from one mechanism — the mirror's act plane and the MCP
act plane resolve the same identity to the same in-context call. Full automation
for an agent and a working remote UI for a human stop being two problems.

## Acceptance

Per op, and measured the way everything else here is measured — against guest
state, never the verb's own report:

1. **Geometry** — item rects from the app's own MDEF. *Done: separators 6px vs
   items 16px, which is the 30px error that made selection miss.*
2. **Invoke** — a shortcut-less item performs its command, verified by the
   command's effect (a window opens, a file appears), not by the verb returning ok.
3. **No hijack** — with a request armed, a real user click on a different menu
   still does what the user asked. *Run 2026-07-31: control 0/20, **menu 18/20
   hijacked**. Open; fix is to carry the verb's `titleLeft` into the shared
   block and require the press to land on that title, the same shape as the
   `ControlHandle` test that holds.*
4. **Rate** — `tests/trials.py`, N=20, independent trials, 100% or the number is
   the finding.
5. **Metal-shaped** — no QMP anywhere in the path.

## Open questions, named rather than assumed

- **Reentrancy.** Serving at `GNEFilter` time is safe-ish because the app is in
  its event loop, but not everything is callable there. The MDEF call was fine;
  each new op needs the same question asked again.
- **Suspended targets.** An app that never pumps never serves. Whether to
  activate it first (changing what we are observing) or to fail honestly is a
  policy decision, and right now it fails honestly.
- **Patch lifetime.** Trap patches are system-wide and survive our INIT. If the
  Portal is removed while a patch is installed, the patch must still chain safely.
- **Multiple targets.** Single-flight is fine for one mirror; an agent driving
  two apps at once would need a queue keyed by A5.
