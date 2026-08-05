---
title: Closing the headless Mirror — the remaining scope - Plan
type: feat
date: 2026-08-05
---

# Closing the headless Mirror — the remaining scope - Plan

Continues [the headless-Mirror plan](2026-08-04-009-feat-now-headless-mirror-mcp-plan.md),
which carries the invariant, the reasoning behind the slice ordering, and
slices 0–5. **That document keeps its history; this one owns what is
left.** Where they disagree about status, this one is newer and
[open-issues.md](../open-issues.md) beats both.

## Goal Capsule

- **Objective:** Finish the arc — close the debt slices 1–3 left behind,
  make the settlement and lane defects of 5c actually correct rather than
  merely quiet, deliver 5b's event tail, and get slice 6 from a ledger of
  gaps into a measurement that says how much of it is real work.
- **Authority:** unchanged from 009. `MirrorStateEngine` is the single
  source of published state; `MirrorActionExecutor` and the mutation broker
  are the single mutation path. `contract/asyncapi.yaml` owns guest-wire
  meaning, and **two items here need it to move first** (5b's delivery, and
  any process-visibility verb).
- **Execution profile:** additive projections and guest/resident work behind
  existing contracts. The one new mechanism is 5b's delivery half, which was
  already designed in 009 and is contract-first.
- **Stop conditions:** the four from 009 still stand. Two more, both earned
  on 2026-08-05: **stop if a fix cannot be driven live** — three fixes
  landed that day and only one was proven, and the unproven ones are now
  debt in this document; and **stop if a route is being built on an
  unchecked API floor.**

  That second one was written citing `ShowHideProcess` as absent from the
  toolchain, which is **wrong** — see § C. The sweep that "checked" it read
  one of two CarbonLib archives. The rule survives its own example, and is
  sharper for it: an API floor is not checked by one grep that agrees with
  your expectation. It is checked by enumerating what could answer the
  question and looking at all of it, and the header search agreeing is not
  independent evidence when the headers ship in the same version pair as
  the archive.
- **Tail ownership:** with MCP present or absent the Mirror window behaves
  identically. Nothing here gives MCP its own route to the guest.

## Where this actually stands

Honest inventory, because the 009 status line reads better than the system
is. Slices 0–5 are done. What is NOT:

| # | owed | from | state |
|---|---|---|---|
| 1 | a field-by-field DIFF of the operation record between faces | 009 § Verification, narrowed 2026-08-05 | **DONE (tested).** `MirrorFaceParityTests` drives one interaction through `perform` twice against one engine and diffs the records by reflection, so a field added later cannot escape it. Watched failing on both 2026-08-05 defects and on a synthetic third |
| 2 | slice 1's page-versus-reply check | slice 1 | compared against a log sharing the same source; testing one half twice. **This is the part that needs the screen** |
| 3 | `window.display` — per-window QuickDraw ops in the snapshot | slice 2 | **projected 2026-08-05** (workstream D), with `kind`, `ref` and `text` — three more of the same omission, found by writing the roster guard. TESTED, not driven live: no VM today |
| 4 | does the MCP drive path hold an engine? | 2026-08-05 | **ANSWERED: yes, always.** `shadowEngine` and `pinnedGuestKey` are set and cleared together, and a nil pin is refused BEFORE the engine is read — so a nil engine cannot produce `id: "direct"`. The cause was the deferred branch reporting a HELD act as the direct path. Fixed. **No measurement needs re-reading** |
| 5 | source attribution through a held act | 2026-08-05 | **DONE (tested).** The harness needed the content join left OPEN — that is the deferred case. Green, and watched failing by reverting the argument |
| 6 | `finderDeselect`; a `dialogItem` that does something | slice 4 | never driven live (the one exercised was a separator) |
| 7 | item 1's control-panel half | 5c | fixed and unit-tested; **never exercised live** — `desktopItems` was nil for the whole 2026-08-05 drive |
| 8 | the lane amplifier | 5c item 2 | untouched |
| 9 | **Hide does not work at all** | 5c item 3 | half done: it no longer blocks the lane. It still does nothing |
| 10 | modal alerts refuse interaction | 5c item 4 | untouched |
| 11 | the event tail's delivery half | 5b | **guest half DONE 2026-08-05** (`claude/p5-transitions-delivery`): contract verb, both faces, native test, cross-build green. Host consumer deliberately deferred to a later slice. **Nothing observed live** — no record from this ring has crossed the wire on any machine, and no guest has been stood up since the verb landed |
| 12 | all of slice 6 | 6 | not started |

Two rig facts bound everything below: `scripts/spin-up-ppc` cannot complete
its cold boot unattended (dispatched as its own task), and the interaction
plane has never published a generation.

## Ordering, and why it is not the obvious one

The obvious order is top-to-bottom. It is wrong twice.

**#4 comes first and is not negotiable.** It is a question, not a build, and
it is cheap. If the MCP drive path holds no engine, then every headless
measurement taken in this arc — including the ones that made slices 3 and 4
look finished — describes the direct path rather than the shared one. That
would not be a bug to fix later; it would mean the numbers already recorded
need re-reading. Everything else in this document is measured through that
path, so nothing measured after it is worth more than the answer to it.

> **Answered 2026-08-05, and the feared outcome did not happen.** The
> engine is always bound on the MCP path — see A below. The recorded
> numbers stand: an act reported `id: "direct"` still went through the
> executor, the broker and its typed postcondition, so what was wrong
> was the reply to the caller and not the path the act took. Read the
> rest of this ordering with that settled; it was written when it was
> not.

**`window.display` (#3) is a slice 6 prerequisite, not a loose end.** Slice
6's own rule is *to render a custom control, do not classify it — replay its
ops*. That replay is only possible for a face that can SEE the ops. The
Mirror window can; MCP cannot. So an agent cannot do slice 6's render half at
all until #3 lands, and slice 6 is the work that most needs an agent's
patience. It is listed as slice-2 debt and it is really slice 6 rung zero.

**Slice 6 opens with a measurement.** Splitting the 190 undetermined items
decides how much of slice 6 exists. Do it before building anything.

> **Ran 2026-08-05, and it reframed the slice rather than sizing it.** Two
> corrections, both load-bearing.
>
> **The premise was wrong twice.** "A lookup rather than an inference" is
> false: `contrlDefProc` is a `Handle` that `Controls.h` marks *not
> supported in Carbon* with no accessor, and `GetControlKind` — the
> Control Manager's own answer — **is not exported by CarbonLib 1.6**, a
> bill this repo had already paid once (`scene_self.c`: "the link fails").
>
> **And the number was not measuring what it looked like.** The 190 is
> **121 Control Manager controls + 69 dialog items** (the 69 all `resCtrl`,
> the one DITL type whose row names no kind). Of 122 controls in the
> corpus, **exactly one carries a determined kind** — and not because 121
> classifications failed. A complete classifier already ships and is better
> than the one this plan imagined: `now_semantic.c :: classify()` reads
> `kControlKindTag` from inside the target process through the resident,
> resolves fourteen families, and its `signature != kControlKindSignature`
> branch IS the standard-versus-custom split, decided rather than inferred.
> **121 controls were never asked.** `peek_table.h` carries a SINGLE
> semantic cell, control classification is its lowest-priority claimant
> (`offer(10…)` against 20 for list cells and 30 for menus), and only the
> front process may spend it.
>
> **So slice 6's control half is a transport problem, not a drawing one.**
> It shrinks and it MOVES: op replay is not what it needs, and neither is
> classification work. Dispatched as its own task. What survives of the
> original framing is the dialog-item half and the genuinely custom-drawn
> remainder — which is what #3 is for, and #3 keeps its justification.
>
> The histogram this measurement was supposed to produce is **owed**: the
> recorded corpus predates the field that would carry it, and the
> resident's verdict exists for 1 of 122. It needs one live scene.

## Who is doing what (2026-08-05)

Five workstreams were fanned out in parallel, each in its own worktree and
branch, because they touch disjoint file sets. The ordering argument above
still holds — A gates the INTERPRETATION of live measurements, not the
other work, so nothing had to wait on it.

| | workstream | branch | touches |
|---|---|---|---|
| A | the executor question, the record-diff gate, the owed attribution test | `claude/mirror-executor-parity` | `NOWMirrorSource`, `MirrorDriveService`, `HostAppState` |
| B | slice 6 rung zero — split the 190 | `claude/slice6-split-the-190` | guest `src/scene/`, the gap ledger |
| C | the Process Manager selector, for Hide | *(read-only research, no branch)* | nothing |
| D | `window.display`, and the omission-class test | `claude/mirror-window-display` | `MirrorStateProjectionService` |
| F | 5b's delivery half, guest side only | `claude/p5-transitions-delivery` | `contract/`, guest `src/peek/`, `commands.c` |

Two deliberate splits. **C is research with no code**: the selector number
it is looking for is the one thing the whole Hide route rests on, and a
phantom constant shipped into a resident that runs in every application's
context is not a mistake this project can afford — so finding it and using
it are separate acts. **F stops at the guest's wire and console faces**:
the host consumer would collide with A and D, and it is a later slice.

Known collision risk to watch when landing: B and F may both edit
`scripts/test-native`'s manifest, and both add a native test.

Not fanned out, and why: the lane amplifier (#8) and modal alerts (#10)
both need a live guest to measure before they can be designed, and the VM
stand-up cannot complete its cold boot unattended — that is its own task,
in flight. Designing either against the old numbers would be guessing.

### All six landed, and what they cost each other (2026-08-05)

Every workstream merged, full gate green. Three things the fan-out itself
taught, which are about running agents in parallel rather than about the
Mirror:

- **A worktree's HEAD is not the branch you are continuing.** All five
  code agents were handed worktrees parked on a commit up to 292 behind
  the arc's head — one that contained neither the plan nor the files
  named in the brief. **All five noticed and re-cut** off the parent,
  citing the AGENTS.md rule. That the rule held five times out of five is
  the good news; that every agent had to spend its opening moves on it is
  the cost. **Name the fork point in the brief.**
- **A derived number is only true at the moment it is derived.** Two
  workstreams each re-derived `contract-coverage.md` while the other's
  verb did not yet exist, so both were honest and both were stale on
  arrival — 40/37/13 against 38/35/13. Re-derived at the merge: **41
  declared, 38 PPC, 13 68K.** That file's "derive it, do not remember it"
  rule needs a companion: **re-derive at the MERGE**, not only at the
  edit. This is a new failure mode for it — not drift, concurrency.
- **A brief's premise is worth stating as a premise.** Two of the six
  briefs carried a claim that turned out false (the CDEF lookup, and
  `ShowHideProcess` being absent). Both agents tested the premise instead
  of building on it, and both said so first. Briefs that assert are
  cheaper to write and more expensive to be wrong in; the ones here that
  said "settle this with evidence, do not assume it either way" got the
  better answers.

### The live queue

Nothing in this document has been driven against a machine. Five things
now wait on one boot, which is why the cold-boot task mattered more than
its size suggested:

1. **`desktopItems`** — nil for the whole 2026-08-05 drive, which is why
   item 1's control-panel half has never been exercised.
2. **The split-the-190 histogram** — the corpus predates the field that
   would carry it.
3. **`window.display` content** — the shape is proven, the content is not.
4. **P5's ring** — the reader and the writer have never met, on any
   machine.
5. **Hide** — it compiles, which is not one of the three levels.

## The work

### A — Settle whether both faces really share one executor · **DONE (tested), 2026-08-05**

`now_mirror_drive` answered `id: "direct"` on 2026-08-05 while the Mirror
page was cycling normally against the same guest, and a harnessed
`NOWMirrorSource` never produced a broker record for the same gesture. The
direct path is what runs when `shadowEngine` is nil.

Three candidates were named: (1) the drive service is handed a source with
a nil `shadowEngine`; (2) it binds only after a guest key is selected and
the drive arrived first; (3) something else, the two observations not
sharing a cause.

**The answer is (3) in form and better than any of them in substance: the
engine is ALWAYS bound on this path, and the two observations DO share a
cause — the deferred branch.** `shadowEngine` and `pinnedGuestKey` are
written together in `start()` and cleared together in both of `stop()`'s
branches, and `pinnedActionRefusal()` refuses by name whenever the pin is
nil, before the engine is read. A nil engine therefore produces a
refusal with a sentence and can never produce `id: "direct"`. (1) and (2)
are structurally impossible rather than merely absent.

The live evidence had already refuted them and nobody had put the two
halves together: the act that answered `id: "direct"` settled `confirmed`
on a typed `windowNamedPresent` postcondition — a nil engine cannot mint
one — and recorded `source: human`, which only the deferred branch
produces. Same act, both facts.

What produces the answer is that a HELD act returns without enqueuing, so
no record exists yet, and the service read that absence as the direct
path. It is the third instance of one defect, not a new one: **the drive
service reconstructing a distinction it was never given.** `perform` now
answers `MirrorPerformDisposition` and the service reports what it is
told.

**The consequence for this document's Ordering section: the feared
outcome did not happen.** No headless measurement recorded in this arc
needs re-reading. Every act reported `id: "direct"` still went through
`MirrorActionExecutor`, the broker and the typed postcondition — the
REPLY was wrong, not the path. Slice 3's claim stands and now has a gate.

**Done:** `MirrorFaceParityTests` (the record diff, the executor-level
total diff, the held-act reply, and the owed attribution regression with
its human twin) and three new `MirrorDriveServiceTests` cases. Each
watched failing by mutation. **Not driven live** — no VM was stood up,
so the reply an agent now gets for a held act has never been seen by a
real MCP client.

### B — Slice 6 rung zero: split the 190 · **the measurement that sizes slice 6**

62% of corpus items carry no determined kind. That single number is two
populations wearing one coat:

- a **standard Toolbox CDEF** — button family, scrollbar, popup — whose
  resource ID sits in the control record and is documented. A known ID means
  the answer was there and got dropped: a producer bug fixed by reading a
  field, no drawing involved.
- a **genuinely app-owned CDEF**, where nothing static says anything and the
  drawing is the only evidence there will ever be.

Read the `contrlDefProc` resource ID for every undetermined control and
report the histogram. Nothing is built from it yet.

**Done when:** the ledger carries the split, and the follow-up work in D and
E is sized against real numbers rather than 190.

**Why first:** it is a lookup, it is small, and it probably collapses a large
fraction — which decides how much of D and E is needed at all.

### C — Hide, both halves · **user-called-out**

Two separate defects have been wearing one name, and only one is fixed.

**C1 — it must not block.** Done 2026-08-05: a refused Hide releases the
lane instead of holding it 15 s awaiting evidence of an effect that never
happened, and only Hide can prove that (one `set`; Hide Others is a loop,
Show All's plural specifier has unmeasured atomicity).

**C2 — it must WORK, and it does not.** Hiding an application is ordinary on
a Macintosh; a person does it from the Application menu. NOW has no route
that reproduces it. Every route tried, with what is actually known:

| route | state | evidence |
|---|---|---|
| AppleScript `set visible` through the Finder's object model | **dead** | refused `-10000`, `-10006`, `osaErr -1753`. Read-only there |
| `menuact` on menu `-16489` | **dead** | dispatches, changes nothing. The Application menu is SYSTEM-owned, not served by the front application's own `MenuSelect` — which is why the act plane's trap patch, that drives the Finder 8/8, cannot reach it |
| a real positional click | **not possible today** | the guest has no positional click verb. `mouseloc` is a READ (`input_cmds.c`), and the act plane delivers menu choices by arming a patch, not by moving a pointer |
| **`ShowHideProcess`** — the Process Manager's own call | **OPEN, and it is the answer** | present in CarbonLib as a weak import; see below |

**I got this wrong first, and the way I got it wrong is the lesson.** I
swept for the symbol, found it absent, and wrote "closed for the app" into
this plan and the ledger. The sweep checked
`toolchain/universal/libppc/libCarbonLib.a` and two `CarbonFrameworkLib`
archives — and never `toolchain/multiversal/libppc/libCarbonLib.a`, which
has it. **There are two CarbonLib archives of different vintages in this
toolchain and I checked one of them.** Verified since:

| archive | `ShowHideProcess` |
|---|---|
| `Retro68/ImportLibraries/libCarbonLib.a` | **present** (3 syms, with `IsProcessVisible`) |
| `Retro68-build/toolchain/multiversal/libppc/libCarbonLib.a` | **present** |
| `Retro68-build/toolchain/universal/libppc/libCarbonLib.a` | absent |
| `powerpc-apple-macos/lib/libCarbonLib.a` | → symlink to the `universal` one |

The cause is a version split: the headers on the include path are
Universal Interfaces **3.4**, and `ShowHideProcess` did not exist until
**3.4.1** (checked against 3.2, 3.3.2, 3.4 — zero occurrences in each).
The richer archives are 3.4.1-derived. **The linker currently resolves the
symlink to the 3.4 archive, so the search path has to change.**

**The declaration, cited from two independent Apple distributions**
(UI 3.4.1 `Processes.h` ll. 542–545; QuickTime 7.3 SDK `CIncludes`,
byte-identical selector; and Apple's *Process Manager Reference*
2007-12-04 p.19, whose revision history dates the entry to 2003-04-01):

```c
pascal OSErr ShowHideProcess(const ProcessSerialNumber *psn, Boolean visible)
                                    THREEWORDINLINE(0x3F3C, 0x0060, 0xA88F);
```

Availability, verbatim: `Non-Carbon CFM: not available` /
**`CarbonLib: in CarbonLib 1.5 and later`** / `Mac OS X: in 10.1 and
later`. Our floor is CarbonLib 1.6, so on the whole target range the call
exists. It is in `CarbonLib__weak.o` — a **weak** import, which is exactly
right for a 1.5+ symbol: the app loads under an older CarbonLib and tests
the address before calling.

Its companion read is **`IsProcessVisible`** (selector `0x005F`), and it
settles a worry this plan previously recorded. `ProcessInfoRec` has **no
visibility field at all**, so `GetProcessInformation` cannot disagree with
the menu — the underlying state is the LAYER's `visible` flag, and Mac OS
8's own `AdjustApplicationMenu` decides the Hide/Hide Others/Show All
enablement by testing exactly that flag. One flag drives both the menu and
the read; the divergence I feared would require them to be separate, and
they are not.

**And it explains the dead end properly.** For a system-owned menu,
`MenuSelect` calls `SystemMenu` (trap `$A9B5`) and returns **0** in the
high word to the application. The Process Manager's patch on `_SystemMenu`
is what performs the hide. So arming a trap patch on the front
application's `MenuSelect` skips the only code that acts on the choice.
Not a flaky route — **the wrong trap.**

**Ordering, and the one route not to take.** Route 1 is the weak-linked
Carbon call, and it removes the need for a resident entirely. Route 2, if
that fails, is `SystemMenu` from the 68K resident (public, in
`libInterfaceLib`, declared in the 68K toolchain already; hides the FRONT
application, which is what a person's click does). Route 3 — reaching
selector `0x0060` by raw `_OSDispatch` — is **last and is dangerous**:
Apple's own dispatcher does no bounds check on the selector, so an
unimplemented one does not return an error, it reads past the table and
`rts`es into whatever that longword happens to be. In a resident, in every
application's context, that is an unrecoverable crash rather than a
`paramErr`, and there is no way to probe for it first.

**Still unproven, and it is the thing to measure:** whether the classic
68K Process Manager in 8.6–9.x implements 0x0060 itself, or whether
CarbonLib 1.5 implements it above the trap. Route 1 does not care; routes
2 and 3 do.

Only then: a contract verb, the host projection, and the typed postcondition
(`processVisibility` already exists and already cannot settle — see the
census defect, which is its own dispatched task).

**Done when:** an application is watched hiding, from a NOW-driven act, and
`now_mirror_journal` records it `confirmed` rather than `dispatched`. Until
something is watched working, Hide stays **unbuilt** in the ledger — not
broken, not impossible.

**Stop condition specific to this:** if the resident route also fails,
STOP and write down which four routes failed and why. Four measured dead
ends is a finding; a fifth improvised route is how this item has already
consumed two sessions.

### D — `window.display`, and the render half it unblocks

Project the per-window QuickDraw ops MCP cannot currently see. The content
plane is live and busy, so this is a projection, not a capture.

Then slice 6's render rule becomes available to both faces: **to render a
custom control, do not classify it — replay its ops.** A faithful replay
cannot be wrong about what a thing looks like, where a classification can.

Same omission shape three times in slice 2 (`window.items`, twice; now
`window.display`): the projection carries what a reader remembered rather
than what the model holds. **Worth fixing the shape, not just the field** —
a test that walks `Scene.Window`'s stored properties and fails on one the
projection does not carry would end the class.

**Landed 2026-08-05.** Three things worth carrying forward:

- **The roster found three more omissions immediately.** `kind` (which
  decides how the window FRAME is drawn), `ref` (whether the window can be
  addressed at all) and `text` (a dialog's own content) were all missing
  for the same reason `display` was. Rostering them as declined-with-a-TODO
  would have made the guard a rubber stamp, so they are projected too. Only
  `psn`, `addr` and `island` are declined, each with a checkable reason.
- **The guard needed its own guard.** A roster check that asks whether a
  key EXISTS passes for a field that arrives empty, which is coverage the
  roster does not have. Every `.carried` check is therefore also run
  against a window whose fields are all present and all empty, and must
  fail there.
- **The bound had to be measured, and the measurement was the finding.**
  The item projection alone already encoded **54.6 KB of the 64 KB
  ceiling** in its worst case, so an independently-bounded addition of any
  size overflowed it — and overflow is not a truncated reply here, it is
  the writer throwing and the connection closing with no reply. Item and
  content families now hold separate stated byte shares of one ceiling.
  Anything further added to this payload must take a share, not assume
  headroom: there is none.

**Not verified live.** No snapshot has been read off a real guest with ops
in it, so the shape is proven and the content is not.

### E — Slice 6 proper, split by GOAL

Only after B. The split is load-bearing and mixing the two is where this
turns dishonest:

- **To RENDER**, replay the ops (needs D).
- **To DRIVE**, classification is unavoidable — this is a checkbox, its hit
  region is here — and it is heuristic pattern-matching over draw ops. A
  widget guessed from a `FrameRect` and a `DrawString` is the plausible lie
  the honesty bar forbids. **Drawing a control correctly and declining to
  click it is a coherent product state; drawing a guess is not.**

So classification is owed only where drivability is owed, which is a far
smaller set than 190 — and B says how much smaller.

Rows, from [the gap ledger](../mirror-element-coverage.md):

- **Readable structures the producer does not walk** — `ListRec` cells,
  `TERec` bodies, popup menu contents. Ordinary work: read a documented
  structure, fill a field the IR already has.
- **Ledger row 3 needs discovery first.** Extensions Manager's 24
  `userItem`s: whether those are List Manager lists behind a user item or
  fully custom drawing is not known, and that answer decides whether the
  `ListRec` fix reaches the panel at all. This is the QEMU oracle's
  highest-value question — *does a structure exist here* — and it is one-off.
- **Ledger row 6 is an instrument defect and comes before anything it
  measures.** The harness oracle reads window titles as binary garbage where
  the IR has them correct. The oracle is the first suspect, always; a
  two-byte width error in a probe once produced two opposite wrong
  conclusions in this project.
- **Unclassifiable by any static read** — refuse to drive, by name, and
  render from replayed ops.
- **Custom-drawn and composited art** — deferred as PIXELS, and stays
  deferred.

### F — Slice 5b's delivery half

The mechanism exists and publishes nothing: contract header, ring, resident
writer, guest reader, fifth plane reported end to end — and **nothing arms
it, no contract message carries records, and the host consumes none**.
Confirmed live 2026-08-05: `transitions`, format 1, generation 0.

Its argument is the sampling one, and it stands on its own: **a ~2.2 s poll
cannot see anything shorter than 2.2 s.** An alert raised and dismissed
between walks is invisible in a way better memory reading cannot fix. That
is the likely explanation for the recurring symptom of an act that worked
while the Mirror never showed it — and it is the same symptom C2's Hide
work will have to rule out.

Contract-first, and the constraints from 009 are unchanged: ring buffer,
ARMED rather than always-on, **overflow reported rather than silently
dropped**, and it lives in the resident.

**Done 2026-08-05, guest side, on `claude/p5-transitions-delivery`.** The
contract declares `transitions` — four subcommands behind one `op`,
shaped after `qdtrace` because they are the same kind of thing, and
simpler in three stated ways (fixed-width records mean no torn, no
resync, no `maxBytes`; one thing to record means no `mode`). The PowerPC
guest answers it on both faces off one implementation, and the console's
route to a target is a process NAME because nothing that guest prints
carries a ProcessSerialNumber. Overflow reaches the caller twice, as this
cursor's `lost` and the resident's `dropped`; arming carries a deadline;
and every word written claims "faster sampling", never "every event".

Three things were extracted rather than copied while doing it, each
because a second copy would have been a second decision: the arm-time A5
trust gate (P3 and P5 ask the same question of the same oracle), the
wide-form JSON argument parsers, and one process-by-name lookup. `qdtrace`
now calls all three.

**What it did not do, and what nobody should read into it.** No guest was
stood up — the cold boot could not run unattended — so nothing here has
been seen working. No record from this ring has ever crossed the wire.
The host consumer was left out on purpose (it would have collided with A
and D) and is declared as a deferred gap in `docs/mcp-coverage.md` rather
than left implicit.

### G — The debt that is just owed

Small, and none of it is optional:

- **The record diff** (#1), and 009 asked for the wrong shape of it.
  "Drive the same mutation both ways and see that both settle" is a
  ceremony, and it has effectively been performed many times: slice 4
  logged an MCP `activate` settling `source=mcp outcome=confirmed`, and
  Michelle's hand drives settle confirmed routinely. Both faces work. That
  is not in doubt and re-performing it proves nothing new.

  **What has never been done is comparing the two records field by field**,
  and that is precisely where both 2026-08-05 defects lived: an MCP-driven
  act recorded `source: human`, and MCP received `outcome: dispatched` for
  an act whose refusal the human face was shown on its status line. Neither
  is visible from driving each face and checking it works; both are visible
  in one diff.

  So 009's claim that this "cannot be automated away" is **wrong**, and the
  correction matters because it is what turns a ritual into a gate: drive
  the same interaction through `perform(.human)` and `perform(.mcp)`
  against one engine and assert the records match on every field except
  `source` and `id`. That is a host test. It fails today on the second
  defect and would have failed yesterday on the first.

  The residue that genuinely needs a person is #2 alone.
- **Slice 1's page-versus-reply check** (#2): needs the screen, and is the
  only item here that does. Comparing against `acts.log` is comparing
  against the same records.
- **`finderDeselect`, and a `dialogItem` that does something** (#6).
- **Item 1's control-panel half, live** (#7): the classifier's positive
  branch has never fired against a real machine, because `desktopItems`
  stayed nil for the whole drive. Find out why that read produced nothing
  before concluding anything about the fix.
- **The lane amplifier** (#8): re-measure first. Item 1 removed most of its
  fuel, and the question — one lane, or one lane per target — should be
  answered against new numbers rather than the 51.8 s ones.
- **Modal alerts** (#10): rung 4 of the drive loop, unchanged, and it blocks
  the application while it is up, so it is also a queue problem.

## Verification

Unchanged in kind, sharpened by what 2026-08-05 cost:

- Focused host tests, **watched fail by mutation**, committed before the
  mutation so it cannot ride along.
- **One headless call proving the row answers live.** Three fixes landed
  that day; one was driven live and two were not, and the two are debt in
  this document. A fix that has not been driven is TESTED, and this arc's
  whole subject is the difference.
- **Check the port before believing any host gate**, red or green:
  `lsof -nP -iTCP:5250 -sTCP:LISTEN`. A red gate cost a session's diagnosis
  and was another worktree's `xctest`.
- **`acts.log` is shared across host instances with no instance marker.**
  Its lines cannot be attributed by timestamp when two sessions are driving.
  `mirror_read --intention journal` is per-instance; trust that.

## What would make this wrong

The four from 009 still hold. Two more:

- **Building on an unchecked API floor.** C's `ShowHideProcess` row is what
  this looks like when it goes right: the obvious answer was checked in ten
  minutes and found closed, before any code was written against it.
- **Treating a quiet defect as a fixed one.** C1 made Hide stop costing 15 s
  and changed nothing about whether Hide works. Both were real; only one was
  done; and the plan said "item 3" for both.
