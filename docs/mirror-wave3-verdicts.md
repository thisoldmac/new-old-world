<!-- now-doc-provenance: generated reviewed=false -->

# The last of Mirror's verb surface — seven verdicts

**Date:** 2026-07-31 · **Status:** decisions, with the evidence each was
made from. Closes the tail of
[mirror-foldin-inventory.md](mirror-foldin-inventory.md)'s wave 3.

The inventory deliberately deferred these: *"several may not want to
cross at all once the act plane and the reference layer exist. That is a
judgement to make with the ported code in front of us."* The act plane
and the reference layer are in, so here is the judgement.

**Two of seven crossed.** That is the point of the exercise, not a
shortfall: four of the five that did not are already answered by
something NOW serves under another name, and porting them would have
built a second system for a job one system already does.

| Verb | Verdict | Why |
|---|---|---|
| `portalselftest` | **ported, reshaped** → `actselftest` | The plane already SERVED the op and nothing could call it |
| `activate` | **ported, reshaped** | The host already SENDS this name; no guest answered it |
| `volumes` | **do not port** | `census volumes` is the same PBHGetVInfo walk |
| `fetch` | **do not port** | A second bytes-puller over a lane that is one-wide |
| `close` | **do not port** | It is not a window closer — see below |
| `menugeom` | **not now, and the reason it was left behind has changed** | A consumer exists; the op does not, and it is resident |
| `journalprobe` | **do not port** | The investigation it belonged to is closed |

## The two that crossed

### `actselftest` — the highest-value item on the list

**The plane has served this since it landed and nothing has ever called
it.** `kNowPeekActOpSelfTest` is implemented in `ext/src/now_ext_act.c`
(`act_serve_selftest`) and routed by `now_act_guard.c`
(`kNowActServeSelfTest`); there was no path to it from the wire.

Why that matters more than a missing verb usually does: a trap patch
whose result lands in the wrong slot **does not crash, it lies.** It
reports firing, every counter the plane owns says success, and the
application reads a value that was never the one we wrote and takes the
other branch. Every other instrument in the plane reads *our* side of the
call. This one reads the caller's — the hook makes a real `MenuSelect` at
a point outside the menu bar, answers its own call, and compares.

Reshaped in two ways, both deliberate:

- **The name.** Not `portalselftest`: what is being tested here is NOW's
  act plane, and naming a verb after a component this repository does not
  have would be the one misleading thing about the port.
- **The application fills in nothing but the op.** `menu_id`,
  `item_index`, `selftest_want` and the negative arm point are all
  written by the hook, in the target's own context. Supplying the
  expected answer from the caller would make the instrument agree with
  itself, which is the exact failure it exists to break.

An unproven convention answers `ok:false` with both numbers in the
message. "The ABI holds" is the only claim it will make on the good path.

### `activate` — the identity half of a job `front` does by name

`front` stays exactly as it is. This is not a second spelling of it:

- A **name** can be ambiguous, and `front` refuses rather than guessing.
- A **PSN** names one process. It is what an observation mints, and
  addressing what you observed is the same identity-not-position rule
  the act plane's references exist for.

And there is a live consumer: MirrorKit's `ActionDispatcher` answers a
click on an Application-menu row with a request literally named
`activate` carrying `serialHi`/`serialLo`
(`ActionModel.click` → `.activate(psn:)`). **No guest served that name**,
so the switcher path had nothing to talk to. The wire name and both
argument names here are the host's, unchanged, for that reason.

There is **one `SetFrontProcess` in this guest** and this verb does not
add another: it composes around `now_proc_bring_to_front()`, the same
function `front` reaches. Two addressing modes, one implementation — the
distinction that decides whether a second verb is a feature or the
two-minters defect.

## The four that are already answered here

### `volumes` → `census volumes`

Upstream's verb is an indexed `PBHGetVInfo` walk reporting name, vRefNum,
total and free blocks. `now-guest-ppc/src/census/census_probes.c` has
`gather_volumes` — the same indexed `PBHGetVInfo` walk, the same numbers,
already in the closed probe registry and already projected to agents.

Its one unique piece was `placed:false` — an honest refusal to invent
desktop icon positions the File Manager does not know. **Nothing in NOW
consumes desktop icon positions**; there is no desktop-items plane in the
scene at all. So the part that is not a duplicate has no reader.

### `fetch` → the transfer lane

Upstream's `fetch` pages a handle at an offset, client-pull, and its
`close` frees the slot. NOW's transfer lane is push-framed and
one-at-a-time: `capture.begin` / frames / `capture.end`, and the same
bracket for scenes and files, with the one-transfer-at-a-time invariant
written into the contract and a cancel path of its own.

A handle-and-offset puller alongside that is a **second ownership rule
for one lane** — the shape the contract explicitly refuses for scenes
("no second ownership rule invented for scenes"). Not a close call.

### `close` — it is not a window closer

Worth stating plainly because the inventory groups it with `activate` as
an act verb, and the brief for this thread inherited that grouping:
**`verb_close` in `mirrorverbs.c` closes a TRANSFER SLOT.** It takes a
`handle`, and for a write slot it commits the file. Window closing
upstream is `winact`'s `op:"close"` — the same op NOW's `winact` already
carries as `kNowPeekActWinClose`.

So there was never a second window closer to reconcile. `close` belongs
with `fetch`, and it is refused for the same reason.

### `journalprobe` — the investigation is closed

[mirror-journaling.md](mirror-journaling.md) is a completed
investigation, and its conclusion is not "not yet": **`JournalFlag` is a
per-process low-memory global, so no application can arm journaling for
another from outside.** A foreign process read 0 across 10,722,892
samples while another held it at −1. NOW has no journaling plane, is not
going to have one, and **the act plane took the route that works** —
patching the traps.

What is left of the verb is two low-memory reads and an `OpenDriver` that
returns −43 on any stock system, which the same document records as the
*expected* state rather than a fault. A verb whose answer is known in
advance for the machine we run on, in service of a mechanism this project
has decided against, is not worth a row in the command table.

**If it is ever wanted, it is two census facts, not a verb.**
`JournalFlag` (`0x08DE`) and `JournalRef` (`0x08E8`) belong beside the
other low-memory readings in the census probe registry, where they cost
nothing and are read by something that already exists. That is the
recommendation, not a port.

## `menugeom` — the reason it was left behind has changed

The act-plane port left this out with a reason, and it was a good one:
*"a geometry read, not an act; nothing in NOW consumes item rects; and
calling a foreign MDEF is the riskiest thing in `portal.c`."*

**One clause of that is no longer true.** Something does consume item
geometry, and it computes it by assuming what upstream measured to be
wrong:

```
now-host/Sources/MirrorKit/ActionModel.swift:88
/// OS 9 standard menu rows are 16 px tall, drawn directly below the
/// 20 px menubar. Item i (1-based) centers at menubarBottom + (i-1)*16 + 8.
public static let menuRowHeight = 16
```

`ActionDispatcher`'s `.menuDrag` uses `menuItemPoint()` to decide where to
release the button. [mirror-act-plane.md](mirror-act-plane.md) records
the measurement it contradicts: **menu rows are not a uniform height —
separators are 6 px and items 16 px on mac99, and assuming 16
accumulated a 30 px error**, which selects the wrong command.

Two things keep this from being a port today, and neither is the old
reason:

- **Scope.** `menugeom` needs a new op in the resident plane — the
  answer has to come from the target's own MDEF via `mCalcItemMsg`, in
  the target's context. That is `contract/peek_table.h` plus
  `ext/src/now_ext_act.c` plus the guard. It is not a verb you can add
  beside one.
- **Blast radius.** The menu-drag path it would fix is emulator-only
  (it needs QMP). The **metal-safe** way to pick a menu item is
  `menuact`, which answers the application's own `MenuSelect` by
  identity and needs no geometry at all.

**So the standing recommendation is: prefer `menuact`, and treat
`ActionModel.menuRowHeight` as a known-wrong constant on the QMP path**
until either that path is retired or a resident geometry op is scoped
deliberately. A hardcoded 16 that disagrees with a measurement we already
have is worth an open-issues row on its own.

## What this thread did not do

**Registered nothing.** The command table, the contract and the help
table are owned elsewhere; `now-guest-ppc/src/machine/mach_verbs.h`
carries the exact edits both verbs need, and until those land the guest
compiles them and serves neither.

**Ran nothing on a machine.** Both verbs are compiled by all three guest
builds and their decision halves are natively tested (61 native tests,
was 59). Nothing here has been observed on an emulator or on metal, and
`actselftest` in particular is an instrument whose whole value is what it
says about a real machine — so its own first run is the interesting one.
