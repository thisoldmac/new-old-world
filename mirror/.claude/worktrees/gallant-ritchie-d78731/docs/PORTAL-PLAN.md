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
| 3 | `CONTROL_INVOKE` | controls by identity with no coordinate math | **built, NOT working — see below** |
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
5. The patch disarms after one use, so a real user click is never hijacked.

Why this is better than making the drag work: with real geometry (op 1) a
coordinate drag *would* now land correctly, but it would still be open-loop
motion through mouse acceleration, still emulator-only via QMP, and still
timing-dependent. Returning the answer is deterministic and works on metal.

### 3. `CONTROL_INVOKE` — built, and it does not work yet

Implemented exactly like `MENU_INVOKE`: a guarded `_TrackControl` patch, armed
against a specific `ControlHandle`, answering with a caller-supplied part code.
The ABI is right (`portalselftest` green), the patch fires, and the verb reports
`answered:true`. **The control does not move.**

What was learned on the way, and it is the substantive part:

**`TrackControl` has two halves, and the return value is the lesser one.** A push
button does its work *after* the call returns, from the part code — so answering
is enough. A scroll bar does its work *during* tracking, inside the action
procedure the Control Manager calls repeatedly while the button is held.
Answering the return value alone therefore drives buttons and does nothing at all
to a scrollbar. Measured: `answered:true`, value unmoved at 218.

So the patch now calls the action proc once before returning. Still unmoved. The
diagnostic that matters is recorded in the reply: SimpleText passes a **real
ProcPtr** (`0x1F168822`) — not `NULL`, and not the `-1` "use the control's own"
sentinel, both of which the patch handles.

**Next hypothesis, untested:** the action procedure consults live input — the
mouse position via `TestControl`/`GetMouse`, or `StillDown()` — and no-ops
because our injected click has already been released by the time it runs. That
would make this the same shape as everything else on this project: the thing
wants a *held* button, not an event. If so the fix is to hold the button
(low-memory `MBState`) across the answer, which is exactly the hybrid the
journaling work landed on for tracking loops.

Do not report this op as working until a control's own value changes.

### 4 — the same trick, once 3 is proved

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
  after one use. Nothing stays armed across a user's own interaction.
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
   still does what the user asked.
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
