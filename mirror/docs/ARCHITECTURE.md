# Mirror — the architecture, in the project's own words

**Date:** 2026-08-01 · **Status:** current at `9536ca2` (all Phase-1/2 lanes
merged). This is the front door for a reader who was not here: what Mirror is,
how each mechanism works, and why each rule exists. The living state is
[STATUS.md](STATUS.md); the act-plane design history is
[PORTAL-PLAN.md](PORTAL-PLAN.md); the full capability list is
[CAPABILITIES.md](CAPABILITIES.md).

One sentence: **a semantic mirror of a Mac OS 9 desktop that a human or agent
drives by identity, never by pixels or coordinates.** Everything else follows
from refusing to let either of those leak into the contract.

## The pieces

| Piece | What | Where |
|---|---|---|
| Guest agent (PPC/CFM) | 33 verbs over JSON/TCP, one connection at a time | `guest/app/src/mirrorverbs.c` (~5,400 lines) |
| AXPeek (68K INIT) | **observe-only** address oracle: CurrentA5, WindowList, MenuList per process, via `GNEFilter` + `Gestalt('TBax')` | `guest/extensions/axpeek/` |
| QDPeek (68K INIT) | QuickDraw op stream (`Gestalt('TBqd')`) — the repaint signal and content plane | `guest/extensions/qdpeek/` |
| The Portal (68K INIT) | the **act** half: in-process trap answering, `Gestalt('TBpt')` | `guest/extensions/portal/` |
| Host (Swift) | `MirrorKit` (scene, hit-test, actions), `MirrorKitUI` (Platinum renderer), `MirrorApp` (`--window` for the human, `--serve` for the agent) | `host/MirrorKit/` |

AXPeek and the Portal are **two INITs on purpose**: one contract says
"observe-only", the other says "acts". Merging them would quietly rewrite the
first. The human window and the agent socket drive the **same** MirrorKit core
— full automation for an agent and a working remote UI for a human are one
mechanism, not two products.

## The four content planes

| Plane | Verb(s) | Carries |
|---|---|---|
| Chrome | `axtree` | windows, titles, controls, menus, refs, values |
| Desktop | `list`, `volumes` | named desktop items and mounted disks |
| Pixels | `capture`/`fetch`/`close` | islands — the fallback for what has no semantic source |
| Repaint | `qdtrace` | the QuickDraw signal that drives island re-capture |

Folder windows graduated from islands to model items on 2026-07-31
([FOLDER-ITEMS.md](FOLDER-ITEMS.md)); the island is now a fallback, not the
plan.

## The Portal, precisely

- A `GNEFilter` INIT runs inside **every** application's context with that A5
  world current. The host writes a request into a system-heap block addressed
  to a target A5; the hook serves it the next time it finds itself running as
  that process. Seqlock coherence, allocation-free in the hook, touch only
  what the Toolbox just handed you.
- **Addressing is by A5** (one low-memory read inside the hook, where Process
  Manager calls are not safe); the wire takes a PSN and resolves it through
  AXPeek's oracle.
- **The caller must yield, not spin.** Cooperative multitasking means a
  busy-wait holds the CPU in our process, so the target never runs — a spin
  *guarantees* its own timeout. `WaitNextEvent(0, &ev, 2L, NULL)`. Measured.
- The trap patches **answer the question the app asks** instead of simulating
  a user well enough to make it ask: `MenuSelect` returns the armed
  `(menuID<<16|item)`, `TrackControl` the armed part code, the `FindWindow`
  family the armed window op. The app then runs *its own* handler. No menu
  drawn, no tracking loop, no mouse motion, no QMP — which is what makes the
  whole act plane metal-shaped.
- Ops as of `PT_VERSION 4`: MENU_GEOMETRY=1, MENU_INVOKE=2, SELFTEST=3,
  CONTROL_INVOKE=4, WINDOW_ACT=5, TEXT_GET=6, TEXT_SET=7.
  **`ptshared.h` is the wire authority**; the plan doc's op numbering is
  narrative.

## The safety design, and the one time it was wrong

**The identity check is the guard. Self-disarming never was.** The plan said
"the patch disarms after one use, so a real user click is never hijacked" —
and measuring that claim inverted it: disarming says the patch fires *once*,
not *whose* call it fires on. The menu patch checked armed+op+A5 and answered
whichever `MenuSelect` arrived first; a user's press on a different menu ran
the armed command **18/20**. The control patch, which additionally requires
the request to name that exact `ControlHandle`, hijacked **0/20** under the
identical test.

The fix: a menu press has no handle, so the identity checked is **the press
itself** — the verb synthesizes the click, so it knows the exact point
`MenuSelect` will receive; that point rides in the shared block
(`armPointH/V`), and a press outside ±2px chains through. After: 0/19
hijacks, 19/19 user clicks doing their own thing, legitimate invoke still
20/20.

The standing rule that came out of it: **a new op is not done until the
no-hijack criterion has a number.** The leak existed for weeks precisely
because acceptance criterion 3 was written down and never run.

Still open (tracked in [STATUS.md](STATUS.md)):

1. **The guest never ages a request out** — an agent that dies mid-verb
   leaves a patch armed indefinitely. A safety property should not depend on
   the caller surviving.
2. **Arming verbs warp the user's pointer** (`post_click_at` writes
   `MouseTemp`/`RawMouseLocation`/`MouseLocation`).
3. **The A5 cross-process guard has never been reached** — a background
   target never arms, so no test has exercised the clause. Whether driving
   one app can fire a command in *another* is the open blast-radius question.
4. **The bypass switch** (`enabled` in the shared block) is written directly
   by the host on purpose: a kill switch that needs the target's event loop
   is not a kill switch. Never unpatch a trap — a patch that vanishes while a
   caller is inside it is worse than one that stays inert. Default-on today;
   flips to default-off at 0.1.

## The ABI facts (each bought with a silent failure)

- Pascal: caller pushes the **result slot first**, callee **pops the
  arguments**. Getting it wrong is quiet: the first MenuSelect patch wrote
  the result over the argument slot, reported `fired`, and the app did
  nothing. `PT_OP_SELFTEST` exists because a wrong ABI **lies** rather than
  crashes — and it covers **MenuSelect only**; a 2-byte result is exactly
  what a 4-byte selftest cannot speak for. Effect is the proof for the
  others.
- A Pascal `Boolean` is a 2-byte slot whose value is the **high byte**:
  `move.w #0x0100,(%sp)`, never `#1`. A `short` is read as a full word. Both
  verified by compiling a caller with the 68K toolchain and reading the
  generated code — "ask the compiler, not memory" is the method.
- Part codes: `inUpButton/inDownButton/inPageUp/inPageDown` = **20/21/22/23**
  (`inButton`=10, `inCheckBox`=11; 12–13 are not part codes). CONTROL_INVOKE
  looked broken for a day because a doc comment invented 10–13. Hence the
  provenance rule: **every constant cites Inside Macintosh, a header, or a
  measurement — or is marked a guess.** Retro68 `CIncludes` are grep-blind
  (ISO-8859 + CR line endings); use `grep -a`.
- `TrackControl` has **two halves**: buttons act on the *return value* after
  the call; scroll bars act *during* tracking via the action proc. One
  unheld action-proc call moves SimpleText's bar; whether another app's
  action proc wants a held button is untested, not disproved.
  `sawActionProc` distinguishes NULL / real ProcPtr / `0xFFFFFFFF` ("use the
  control's own" — decline it).
- The shared block is a **memory ABI, versioned**. Both failure modes hit in
  one day: a second copy of the header drifting (now a one-line include —
  two copies fail to *agree*, not to build), and a resident INIT older than
  the agent (verbs refuse `version < N` with `portal_stale`; a stale
  extension is a reboot, an unguarded patch is invisible). Any layout change
  is a version bump plus a refusal floor in every verb touching new fields.

## Guest facts a new reader will hit

- **`LaunchApplication`, not the Finder AE**, for launch: an `AESend` needs
  the Finder scheduled and pumping; a timed-out AE is indistinguishable from
  a failed launch. Names resolve from `FindFolder(kOnSystemDisk)`; every
  search cap is reported; two matches return `ambiguous`.
- **Quit's interesting case is the dirty document**: the app raises its
  save-changes alert instead of quitting, so "verb ok" and "app gone" are
  different claims. Both are measured.
- **Apple-menu titles carry leading NULs** (all 16 items `\0\0`+name,
  matching the Apple Menu Items folder; Window menu `\0Desktop`). Not a
  length-byte misread — one pass cannot produce prefixes of two *and* one.
  The walk strips leading NULs and reports `titleNulPrefix`; the *writer* is
  unidentified (P-OBS).
- **`PostEvent` keyUp returns `evtNotEnb` on every call** — keyUp is not in
  the system event mask; only the keyDown's return is load-bearing.
- **The build stamp is a hash over the sources** — a `__DATE__ __TIME__`
  stamp once shipped an unchanged stamp for a changed binary, and the old
  binary was measured with confidence.
- **One connection, one client.** The guest serves one connection serially;
  the transport refuses a racing accept (`T_LISTEN` busy path) and the
  contract is that the client reconnects. A socket-per-request client once
  manufactured an entire false theory of wedges.
- **Finder item positions: `position of` (live, content-local, follows
  scroll), never `fdLocation` (the saved grid).** 40/40 with the right
  source, 0/40 with the wrong one, same code. Cache to draw,
  **force-refresh to aim**; an invisible item has no click point — refuse
  rather than invent one.

## The measurement discipline

The four rules that decided outcomes, each bought with a retraction:

1. **The oracle is guest state, never the verb's reply.** `answered:true`
   over an unmoved scrollbar is the shape of every false positive this
   project has had.
2. **Reset state between trials.** The "~9 actuations per boot" ceiling was
   an accumulating oracle, not a defect.
3. **Prove a fix by mutation.** Force the bug back and watch the number
   collapse — the only reason the part-code root cause was certain.
4. **Enforce the precondition or refuse to publish the number.** Twice a
   healthy verb measured 0/20 because the *scenario* was inapplicable
   (cmd-N against Graphing Calculator; File → New Folder with About This
   Computer frontmost — the Finder receives the command and correctly
   ignores it).

## Host-side rules

- **An unread parameter is indistinguishable from an absent one.**
  `{key:"q", modifiers:["command"]}` — the contract says `mods` — typed a
  literal `q` into a document and reported `performed:true`. Every mutating
  method refuses unknown parameters, naming what it got *and* what it
  accepts. Accepted sets are derived from **what the code reads**, not the
  contract prose — which immediately caught `settleTimeoutMs`, read after
  the method returns and therefore in no method's signature.
- `mirror.find` answers from whatever scene it holds and **carries no age**
  — the oracle for an act's effect is `mirror.scene` with `maxAgeMs: 0`.
  (Open defect.)
- IR discipline: `irVersion` rides **beside** the payload (a gate must be
  readable without decoding what it guards); the freeze is per-field with
  known-wrong fields **excluded** (`windows[].items` re-entered additively
  via `v1Additions` only once positions were true); the freeze test goes red
  on silent drift via two shape enumerations that cover each other's blind
  spots ([IR-V1.md](IR-V1.md)).
