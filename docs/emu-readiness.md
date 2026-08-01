# Emulator readiness

**Date:** 2026-07-31, revised 2026-08-01 · **Status:** an operator's
document. Written on a bench with no hardware and no VM. Nothing
described here has been run against a Macintosh, emulated or real.

The 2026-08-01 revision is section 5 and the rows it touches: the four
probe cases that were waiting on a menu bar now read one, from a scene,
and the paragraph explaining why that was not a small addition is now the
paragraph explaining what was built.

This is not a summary of what was built. It answers four questions an
operator has and nothing else does:

1. What can an emulator run exercise today, and with which harness?
2. What can it *not* exercise, and why?
3. In what order should it be run?
4. What must be true before the extension is installed at all?

Read the fifth section too. It is the list of harnesses that still
refuse and what each one needs, and a stale list there is worse than no
list.

## What "ready" means here, and what it does not

**A green build is not readiness.** As of this document every gate in the
repository passes, all three guests build, and the 65 native tests are
green — and that says only that the tree is consistent with itself.

Readiness, for this run, means three separate things:

- **Every verb that exists is reachable.** Six were not. `qdtrace`,
  `mouseloc`, `script`, `aesend`, `activate` and `actselftest` compiled
  into the guest and were dispatched by nothing; they are registered
  now, in all three halves the contract requires.
- **Every gate that fails is either fixed or explained.** Three were
  red. All three are fixed, and one of them turned out to be about a
  different verb than the one it named — see below.
- **What still cannot be tested is written down.** That is section 2 and
  section 5, and they are the parts of this document with a shelf life.

**Nothing below has been observed.** Where this document says a harness
"runs", it means its verb gate passes and its trial bodies have a
machine-shaped path to a number. It does not mean a number exists.

## 1. What an emulator run can exercise

The guest serves **32 of the contract's 35 verbs**
([contract-coverage.md](contract-coverage.md) has the full table and the
three it does not). The harnesses that can put a number on any of them
live in `scripts/probes/`, and every one of them refuses unless
`NOW_METAL=1` is set — running one is an attended decision, deliberately.

| Plane | Verbs | Harness | What a run would settle |
|---|---|---|---|
| Identity | `vers`, and `hello` itself | `g1-probe.py --case stamp` | that the transport reaches a **real Macintosh** and that its build stamp agrees with itself. Needs no verb at all. **Run this first** — see section 3 |
| Processes | `launch`, `ps`, `quit`, `front` | `g1-probe.py --case launch` | that an application opens and appears in the process list |
| Reference layer | `observe`, `axtree`, `elements`, `handle`, `axsnap` | every act harness, as their first step | that a walk mints references and that they resolve — the thing the whole act plane stands on |
| Act: windows | `winact` | `winact-probe.py` | move / resize / zoom / close against a minted window reference |
| Act: controls | `ctlact` | `ctlinvoke-probe.py` | that answering an application's own `TrackControl` actuates its real handler |
| Act: text | `textget`, `textset` | `textops-probe.py`, `textops-explore.py` | reading and replacing one addressed text element |
| Act: Apple Events | `aesend` | `apple-event-probe.py` | the four-event closed vocabulary, **and its refusal** of an event outside it |
| Act: the whole plane in order | `observe` + `winact` + `ctlact` + `launch` + `ps` | `drive-sequence.py` | all-or-nothing, in sequence, against one machine — the only harness that reports on the plane as a plane |
| No-hijack | `observe`, `mouseloc`, `ctlact`, `menuact` + `scene.request` | `nohijack-probe.py`, all six cases | the 18/20 → 0/19 measurement the contract's own act-plane preamble cites as the reason an act must name one element |
| Scene | `scene.request` (a transfer, not a verb) | `g1-probe.py --case menus`, and the four menu cases of `nohijack-probe.py` | that the guest walks and ships a menu bar, and that its menus carry the id / index / `left` that `menuact` addresses. The cheapest read is `--case menus`: one transfer, nothing armed, nothing changed |
| Finder geometry | `script`, `observe`, `mouseloc` + QMP | `h2-items-probe.py` | whether a click computed from an item's reported position selects that item. **Emulator-only** — it needs a QMP socket |
| Instrument | `mouseloc` | every closed-loop positioner in the above | that the cursor is where it was asked to be. It is the instrument the act plane is measured *with*, not part of it |

Two verbs registered this week appear in no harness: `activate` and
`actselftest`. `activate` is exercised incidentally by anything that
switches processes. `actselftest` should be run by hand, first, on any
machine that is about to be driven — section 4 says why.

## 2. What an emulator run cannot exercise

### Timings are metal-only

No number from a QEMU `mac99` guest is a statement about a Macintosh's
speed. The emulated machine does not run at 33 MHz, its memory system is
not a PowerBook's, and its disk is a file on an SSD. Every latency,
throughput and per-op cost in this project that means anything was taken
on metal, and that is not a convention — a timing taken here and quoted
later is a fabricated hardware fact.

What an emulator settles is **mechanism**: did the trap fire, did the
reference resolve, did the application take the branch. What it never
settles is **cost**.

### The act plane has never run anywhere

Not on an emulator, not on metal, not upstream in this shape. The
measurements in [mirror-act-plane.md](mirror-act-plane.md) are
`timbottu/mirror`'s, taken on that project's own guest, and that document
says on its first page that they are not NOW results.

So the first emulator run of the act plane is a **first run**, with
everything that implies. It is also the run that decides whether the
extension's trap ABI is right, and that is the one failure this plane has
that does not announce itself — see section 4.

### The content plane's writer has never run

`qdtrace` is reachable now and its reader is tested natively, in full,
against fabricated rings. The **writer** — `ext/src/now_content.c`, the
resident code that fills the ring at draw time — has never executed on
any Macintosh. On every machine that exists today `qdtrace status`
answers `content-plane-absent`, correctly.

That is a true answer and it is the whole of what this verb has been
seen to do. A run that gets it is not a failure; a run that gets
anything else is news.

### The `cis`-class hazard, and why "it is an OS API" is not enough

The parent project's `cis` verb passed on an emulator and then **hard-froze
a real PowerBook 1400c**, requiring a physical reboot; `sertx` soft-wedged
a harness by writing synchronously to a CTS-held port. Both are
above-the-line OS calls. AGENTS.md's ruling stands: *"It's an OS API" is
necessary but not sufficient for metal safety.*

Nothing in NOW's verb set is known to be `cis`-class. What matters is the
inference rule: **an emulator pass is not evidence of metal safety.** The
act plane in particular patches six system-wide traps in another
process's context, and an emulator that survives that says nothing about
a machine whose Toolbox is in ROM.

### Anything MirrorKit drives

`now-host/Sources/MirrorKit` does not speak NOW's contract. Its
`WireClient` sends `{"proto":1,"id":n,"verb":…}` and reads a `result`
object — the TimBotTu toolkit worker's protocol — while a NOW guest
speaks `command.request` and answers `output`. `MirrorTarget`'s own
documentation says so: *"it assumes AXPeek + a toolkit worker are already
live at host:port."*

One verb name in it was wrong on top of that (`menuinvoke`/`menuID`
where the contract declares `menuact`/`menu`) and is fixed, with a gate.
**Fixing the name does not make this module reach a NOW guest.** An
emulator run cannot exercise MirrorKit against NOW until the transport
question is answered, and that is a design decision nobody has made.

## 3. The order to run things in

Each step assumes the one before it passed. The first two change nothing
on the machine.

**Step 0 — a disposable clone, and recovery in place.** Section 4.

**Step 1 — prove the transport reaches a real Macintosh.**

```
NOW_METAL=1 python3 scripts/probes/g1-probe.py --port <p> --case stamp
```

A previous agent nominated this and the nomination is **confirmed**. It
is the right first step for reasons that are checkable rather than
stylistic:

- **It changes nothing.** It reads the `hello` the guest sent unasked and
  asks `vers`. No process is launched, no window is touched, nothing is
  armed.
- **It requires no verb.** `REQUIRED["stamp"]` is empty, so it cannot
  fail for the one reason that would tell you nothing about the machine.
- **It distinguishes a real guest from `tools/fakeguest.py` decisively.**
  The fake sends a `hello` with no `build` field and answers
  `unknown-command` to everything except `launch` and `quit` — so against
  it this case prints `build None` and its `vers` request is refused.
  Against a real guest both are populated, from two independent sources.
- **It catches the failure that looks like success.** It compares the
  build stamp in `hello` against `vers`, and a machine where those
  disagree has been half-updated — a deploy failure that otherwise
  presents as a working Macintosh answering confidently out of an old
  binary.

No replacement is proposed. Nothing else in the tree both changes nothing
and proves the far end is real.

**Step 2 — prove the machine will hold still.** `g1-probe.py --case
launch`: an application opens and appears in `ps`. Still no act plane, no
extension arming.

**Step 3 — prove the reference layer mints and resolves.** `observe`
followed by `handle`, by hand or as the first step of any act harness.
Every act verb takes a reference nothing else can produce; if this step
is unreliable, every number after it is measuring the wrong thing.

**Step 4 — the ABI, before any act.** `actselftest`. Section 4.

**Step 5 — the act plane, one verb at a time.** `winact-probe.py`, then
`ctlinvoke-probe.py`, then `textops-probe.py`, then
`apple-event-probe.py`. One at a time and in that order: window acts are
the most recoverable, text acts change a document, and `aesend` can quit
an application.

**Step 6 — the plane as a plane.** `drive-sequence.py`. All-or-nothing by
design, so it is meaningless before step 5 and worth a great deal after
it.

**Step 7 — the measurement this whole directory exists for.**
`nohijack-probe.py --case baseline`, then `--case control`, then `--case
text`, then `--case menu` and `--case stale`. The menu cases need the
Finder frontmost with its own menu bar and they read a scene to find it;
`g1-probe.py --case menus` is the cheap way to see that the bar is
readable on this machine before spending twenty trials on it. `--case
window` is a calibration sweep, not a finding, and is worth running last.

**Step 8 — geometry, if there is a QMP socket.** `h2-items-probe.py`.

## 4. Before the extension is installed at all

The NOW Extension is now **four planes**: core (P0), anchors (P1),
content (P3) and act (P4). The act plane is the first that can **write
into another process**, and it patches **six system-wide traps** —
`MenuSelect`, `TrackControl`, `FindWindow`, `GrowWindow`, `TrackBox`,
`TrackGoAway` (`ext/src/now_ext_act.c`; the trap numbers are `P-DOC`,
from the `ONEWORDINLINE` on each). They go in on the first *armed* pass
rather than at boot, so a machine that never opens the mirror never has a
patched `MenuSelect` — and **they are never removed**, because a patch
that vanishes while a caller is inside it is a jump into freed code.
Disarming makes every trampoline's guard decline instead.

All four of these must be true before the file goes into the Extensions
folder:

**1. Shift-boot recovery is in place and has been rehearsed.** Holding
shift at startup disables extensions across this whole OS range. It is
the only recovery for an INIT that wedges the boot, and it is worth
knowing it works on *this* machine before it is the thing standing
between you and a reinstall.

**2. The target is a disposable clone.** On an emulator this is free and
non-negotiable: clone the base image and boot the clone, never the shared
base. On metal there is no clone, which is exactly why the emulator run
comes first.

**3. `actselftest` before any act — and read what it means.** A wrong
trap ABI **does not crash. It lies.** The patch reports firing, every
counter the plane owns says success, and the application reads a value
that was never the one we wrote and takes the other branch. Every other
instrument on this plane reads *our* side of the call; `actselftest` is
the only one that reads the caller's — it makes a real `MenuSelect` at a
point outside the menu bar, answers its own call, and compares.

It is side-effect free by construction: point (0,0) is outside the menu
bar, so an unanswered call returns 0 immediately having drawn and tracked
nothing, and the arm point is negative — the one op on this plane that
rides no user click.

**Until 2026-07-31 there was no way to call it.** The op had been served
by the extension since the plane landed and nothing reached it; the one
instrument that catches a lying ABI from inside was unreachable from the
wire. It is a verb now.

**4. One deliberate boot beside era-typical third-party residents**
before the word "verified" is used about coexistence
([resident-components.md](resident-components.md)).

## 5. Which harnesses still refuse, and what each needs

Re-derived 2026-07-31 against the guest's registered verb set, revised
2026-08-01. **No harness in `scripts/probes/` is blocked on a missing
verb** — that was true of six of them until this week and every "refuses
on `observe`" verdict in that directory's README was stale. **And no
probe case is blocked on the menu bar any more**: the four that wanted
one read a scene.

| Harness | State | What it needs |
|---|---|---|
| `g1-probe.py` | 3 of 3 cases have a path to a number | nothing missing. `menus` reads a scene; it refuses by name if this guest does not serve one |
| `nohijack-probe.py` | 6 of 6 cases have a path to a number | nothing missing. `menu`, `stale`, `window` and `baseline` read the same scene, and gate on the scene plane |
| `h2-items-probe.py` | emulator only | a QMP socket. On metal it needs a click at a computed point, which NOW has no mechanism for — no click verb, no host-side positional dispatcher |
| `apple-event-probe.py` | runs, less one case | its `dirty` case has no way to dirty a document and says so |
| `winact-probe.py`, `ctlinvoke-probe.py`, `textops-probe.py`, `textops-explore.py`, `drive-sequence.py` | run | nothing |

### The menu bar: a ruling, and what was built because of it

Four cases across two harnesses wanted a menu bar out of `observe`, and
`observe` emits none — there is no `menus` key in `observe.c`. It looked
like an omission. It is a ruling.

- **The menu bar is already walked.** `src/axwalk/axmenu.c` carries the
  layout, measured against a live Mac OS 9.1 Finder and natively tested,
  and `src/scene/scene_walk.c :: now_scene_walk_menubar` walks it — menu
  id, title, `left`, and per item the index, title, enabled state — and
  ships it over `scene.request`.
- **It is shipped as a transfer on purpose.**
  [streaming-a-scene.md](streaming-a-scene.md) settled that a tree whose
  parts mean something only when reassembled is a transfer, not a bounded
  control answer. A Finder's menu bar behind `observe`'s reply budget
  either truncates or reopens that ruling.
- **A second walk would be a second producer of one fact**, which is the
  defect [command-parity.md](command-parity.md) exists to refuse.

So the four cases needed a **scene read in the harness**, not a wider
`observe` — a different piece of work from the one it looked like, since
`nowwire.py` was a control-plane listener and a scene arrives as
`scene.begin`, bulk frames, `scene.end`.

**That read exists as of 2026-08-01** (`scripts/probes/scene.py`,
`nowwire.GuestLink.scene()`). Four things an operator should know about
it:

- **Where the fetch sits.** Once per case, in the case's setup while
  nothing is armed; re-read at the *top* of a trial, before the act goes
  out, only when the cached bar has stopped describing the machine — the
  front process changed, the bar's own `menubar.app` disagrees with it,
  or it aged past two minutes. **Never inside an armed window.** A scene
  is ~21.5 KB on the one-wide transfer lane plus a walk inside the
  guest's cooperative event loop; upstream's probes could ask for a menu
  bar in a bounded reply and this port cannot.
- **The counting did not change.** No trial is dropped or scored on
  account of a scene. Same drop reasons, same denominator, `tally.py`
  untouched. Three bookkeeping keys (`sceneSeq`, `sceneRefetched`,
  `sceneBar`) are additive.
- **A new refusal exists.** `scene.request` is a typed control message,
  so it is in no verb list and `require_verbs` structurally cannot check
  it. A guest that does not serve the scene plane answers *nothing*, and
  silence is not a refusal — so the harnesses ask once and exit 2 by name
  (`MissingScenePlane`) rather than hanging or reporting an empty
  machine. A NOW-68K guest is exactly this case: it serves neither scene
  nor act.
- **Absent is not empty.** `menubar` absent means the producer retracted
  the whole plane (its `meta.errors` says why); `menubar` present with an
  empty `menus` means the front process genuinely has none. The harness
  refuses the first as a precondition failure instead of reporting a
  machine with no menus. Both halves are tested and both tests have been
  watched to fail — `scripts/probes/tests/scene_test.py` and
  `scenewire_test.py`, in `scripts/test-native` (65 → 67).

The other half of the mismatch *was* a plain bug and is fixed: `menuact`
declares `menu` as an integer id — "as the scene reports it" — and
`nohijack-probe.py` passed a reference, because that is the shape
upstream's `menuinvoke` took. **The contract was right and the probe was
wrong**; the id now comes from the producer the contract names.

## What changed on the way to this document

Recorded because two of the five were not what their symptom said.

| Symptom | What it actually was |
|---|---|
| `GuestWireConformanceTests` said the host could not decode `qdtrace`'s reply | **Not qdtrace's.** `CommandResult.output` was `[String: [[String]]]?`, and the contract has declared object outputs since the reference layer landed — `observe`, `axtree`, `elements`, `handle` and `axsnap` were all undecodable, and a host that cannot decode a frame drops the connection. Their emitters are piecemeal, so the scanner never saw them; `qdtrace` was simply the first object-shaped reply written as one template |
| `CommandParityTests` said a dispatch site was unlisted | Two files match its `strcmp(name,` heuristic and dispatch nothing — they map an argument's *value* onto an enum. Recorded as such rather than given an invented face |
| `CommandParityTests` listed sixteen verbs with no console face | Not one fact. Nine cannot be typed and the contract already says so; seven take numbers a person has and are a console face the guest owes. Two maps, two claims |
| `ActionDispatcher` sent `menuinvoke` with `menuID` | A request no guest would answer, in ported code, on `main`, with every test green. The probes had been reconciled to the contract's spelling the same week; this module had not |
| `observe` emits no menu bar | A ruling, not an omission. Above |
| Four probe cases "blocked on a menu bar" (2026-08-01) | Blocked on a **transfer reader**, which nothing in `scripts/probes/` had. The bar was already walked and shipped; what was missing was a client that could read `scene.begin` → bulk → `scene.end`, and a decision about where a 20 KB read belongs in a trial loop. Both exist now |
| `nohijack-probe.py` said `winact` was "served by no guest" (2026-08-01) | Stale in the same way the six `observe` verdicts were. `cmd_help.c` registers it and `commands.c` dispatches it |

## Is this ready for an emulator run?

Yes for the transport and the reference layer, qualified for the act
plane, and no for the content plane.

Every verb the guest carries is now reachable, every gate is green, and
the harness ledger is honest for the first time — six harnesses that read
as blocked on `observe` were not blocked on anything, which means an
operator who trusted that list would have concluded there was nothing to
run. There is: steps 1 through 3 are low-risk, change nothing or almost
nothing, and would settle whether the transport, the process plane and
the reference layer work against a real Macintosh, which no one knows.
The act plane is a genuine first run in any environment, and it patches
six system-wide traps whose ABI, if wrong, reports success while the
application takes the other branch — which is why `actselftest` exists,
why it must be called before anything is driven, and why the extension
must not be installed anywhere but a disposable clone with shift-boot
rehearsed. The content plane is not ready and should not be expected to
be: its writer has never run, `qdtrace` will answer
`content-plane-absent` on every machine that exists, and that is the
correct answer rather than a fault to chase. And four probe cases and the
whole of MirrorKit remain out of reach for reasons that are now written
down rather than discovered mid-run.

*(2026-08-01: four of those five are no longer out of reach — the probe
cases read a scene now. MirrorKit still is, and for the unchanged reason:
it does not speak NOW's contract.)*
