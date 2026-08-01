# QD Reader — the other half of a throwaway, still not NOW

**Date:** 2026-07-31 · **Status:** builds and packages, ladder not run ·
**Disposition:** delete with QD Probe

[QD Probe](../qdprobe/README.md) publishes its counters through Gestalt
`'QDpr'` and **nothing read them**, which is why its ladder stopped at
*packages*: with no reader, "loaded at boot" cannot be told from "did not
load", and `rect_calls` — the answer the probe exists to produce — is
unobservable. This is Phase 1.4 of
[the roadmap](../../docs/roadmap-to-verified.md), and it is the reader.

It is a **throwaway too**, on the probe's own terms:

| | QD Probe | QD Reader | NOW |
| --- | --- | --- | --- |
| file | `QD Probe` | `QD Reader` | `NOW` / `NOW Extension` |
| creator | `QDpr` | `QDrd` | `NOWx` |
| Gestalt | `'QDpr'` | *(none — it publishes nothing)* | `'NWex'` |
| lifetime | delete it | delete it | ships |

**It is deliberately not inside the NOW guest.** Putting it there would
couple the shipping product to the spike the charter insulates it from,
which is the same call a previous agent made and made correctly. It reads
one Gestalt selector that is not NOW's, links against nothing of NOW's,
and knows nothing about NOW's table.

## Why Carbon/PPC and not 68K

The reader had the choice — an INIT must be 68K, an application need not
be — and Carbon/PPC is the answer for a reason stronger than "it runs
beside NOW on a 9.x machine" (it does).

The probe's one question is whether a **native PowerPC** caller reaches a
bare 68K bottleneck pointer. Armed at its own A5, this application *is*
the caller: the rectangles it draws are drawn by native PowerPC QuickDraw
under CarbonLib, into a port the probe patched. So the reader is the
experiment, not a report of somebody else's experiment. A 68K reader
would display the same counters and, armed at itself, would only ever
prove 68K → 68K — an answer to a question nobody asked.

## How it gates

`magic` **and** `version`, as one check, and only after the pointer looks
like a pointer at all:

| what it finds | verdict | what it does |
| --- | --- | --- |
| Gestalt refuses the selector | `NOT INSTALLED` | nothing; INITs load at boot only |
| answer is NULL or odd | `BAD POINTER` | nothing |
| `magic != 'QDpr'` | `NOT A QD PROBE` | shows the magic it found, nothing else |
| `version < 2` | `STALE INIT — COLD BOOT` | **no writes, no counters shown** |
| `version > 2` | `READER TOO OLD` | **no writes, no counters shown** |
| both exact | ok | full panel; arming enabled |

**A version mismatch is a refusal, not a warning, and the instruction on
a low version is a cold boot.** The probe's README spells out why and it
is not hygiene: a version-2 request written into a version-1 block puts
`arm_a5` where `armed_ports` lives and `arm_expiry` where `rect_calls`
lives, then sets `arm` — and a version-1 probe seeing a bare `arm`
patches **every port it meets**, silently, while the reader believes it
named one target. An INIT makes that the *likely* accident, not an
unlucky one: rebuild the reader, forget the cold boot, and the stale copy
is still the resident one.

So on any mismatch the panel shows exactly two words — the magic and the
version actually found — and every write path is closed. Reading a
counter out of a block whose layout we do not have would be a guess
printed as a number.

(The probe's v1 did carry a version word, so `version < 2` is the literal
case. A block with no version word at all reads as garbage at that offset
and lands in `READER TOO OLD`, which refuses just as hard — the rule is
*exact match or nothing*, not *not lower*.)

## How it names an arm target

Arming is keyed on A5, and the honest answer to "where does a small
application get an A5" has two halves, one of which is "the user types
it":

- **`S` — arm self.** The reader's own A5, read in its own context at the
  moment it arms. This is the default, the only self-sufficient mode, and
  the one that makes this application the experiment.
- **hex digits, then RETURN — arm a typed foreign A5.** Obtained out of
  band: NOW's anchor plane (`contract/peek_table.h`), AXPeek, anything
  that enumerates processes. **Nothing in this application can discover
  another process's A5** and it does not pretend to — reading low memory
  in *our* context yields *our* A5 and never theirs. Enumerating foreign
  anchors is NOW's plane, and reaching for it here is precisely the
  coupling this file exists to avoid.

`X` clears the typed value; an odd A5 is refused as a typo (an A5 is a
pointer); an empty one is refused because **a bare arm names nothing**,
which the probe would refuse and count as `unscoped` anyway. Catching it
here just means a typo does not have to travel to resident code to be
caught.

Two limits inherited from the probe and worth repeating where a person
will hit them: **A5 names an A5 world, not a process** (re-arm per
launch), and **a backgrounded target never arms at all**, because our
hook only runs when the target pumps.

### `LMGetCurrentA5()`, for us and for anyone else

We cannot call it. This toolchain's `LowMem.h` marks it
`CALL_NOT_IN_CARBON` — *"CarbonLib: not available"* — so a Carbon build
has no such entry point at all. The reader reads low memory `0x904`
directly instead, which is exactly what that accessor's inline does
(`0x2EB8 0x0904`), and is the same class of fixed-address read
`spikes/census-metal` already performs on OS 9.

That read is valid **only for our own context** and only on classic Mac
OS. It is never a way to learn a foreign process's A5, which is the whole
reason the foreign path is typed rather than discovered. The probe, being
a non-Carbon 68K INIT, keeps the real `LMGetCurrentA5()`; only the reader
pays this tax.

## Arming is a commit protocol

Three fields, and the order is the protocol:

```
to arm     arm_a5, then arm_expiry, then arm LAST
to disarm  arm FIRST
```

A jGNE pass can land between any two stores, and that order is the only
thing stopping a live `arm` from pairing with the previous request's
target. The block pointer is `volatile` so the compiler may not reorder
or coalesce the stores; **the object file was checked rather than
trusted** — see below.

The request's life is 1800 ticks (30 s). Short on purpose: the expiry
bounds *duration, not scope*, and its real job is retiring a request if
this application dies mid-experiment. Re-arm rather than raise it.

On quit — and on the close box — the reader **disarms and then keeps
pumping until `armed_ports` reaches 0**, bounded at 180 ticks. Quitting
with our port still patched leaves an entry pointing into a heap that is
about to go away; that is the leaked-entry case the probe accepts on
purpose, and draining is the one thing the reader can do to not cause it.
If the drain times out it says so rather than hanging.

## What a person would now see, on a machine with the probe installed

Cold-booted with `QD Probe` in Extensions, then this application launched:

1. **Installed and running.** `magic ok`, `version 2 ok`, and a heartbeat
   whose age is a tick or two — because our own `WaitNextEvent` is what
   moves it. A heartbeat frozen far behind `TickCount()` is *loaded but
   not pumping*: the INIT is resident and its jGNE chain is not running.
   Absent Gestalt is *did not load at all*. Those three states were
   indistinguishable before this file existed.
2. **Press `S`.** `arm 1`, `arm_a5` = our own A5. On the next event-loop
   pass the probe sees its target and patches our window's port:
   `patches` and `armed_ports` go to 1. (`skipped` climbing instead means
   the port was refused — not a colour port, or it already had
   `grafProcs`.)
3. **`rect_calls` climbs — the answer.** Nonzero means a native PowerPC
   caller reached a bare 68K bottleneck pointer with no routine
   descriptor in between. Zero while `armed_ports` is 1 is *also* an
   answer, and the next thing to try is the hand-built `M68K` routine
   descriptor plus `RTS` thunk that unfroze the `cis` verb.
4. **Rectangles vanish while armed — expected, and a second signal.**
   The probe only ever patches ports whose `grafProcs` was `NULL`, so
   `saved_procs` is always 0, so its proc's "no chain to tail-call" path
   is taken on *every* patched port: every rect operation in our window,
   erases included, silently draws nothing. That is the probe's stated
   "visible as a missing rectangle" behaviour, reached universally rather
   than exceptionally. The reader is built for it — it never calls
   `EraseRect` and draws its panel with `srcCopy` text so the text stays
   legible either way — and the `T` key draws a rectangle on demand so
   the effect can be produced deliberately. **Left as-is, not fixed:** it
   makes the patch's reach visible to the eye as well as to a counter,
   and changing the probe's drawing behaviour to find out whether its
   drawing behaviour works is not an experiment. If it ever needs
   fixing, the fix is one line — call `StdRect` when there is no saved
   chain.
5. **Press `D`.** `arm` drops to 0; the next pass in our context restores
   the port, `restores` goes to 1, `armed_ports` to 0, and rectangles
   come back. Disarm reaching *our* ports promptly is a property of us
   being the target and still pumping — it is not a general guarantee.
6. **A misaddressed request is loud.** Arm a typed A5 that belongs to
   nobody and watch `foreign` climb once per pass, in whatever process is
   pumping, forever until the expiry retires it and `expiries` moves.
   That is the refusal being counted rather than silent, and it is
   observable now.

## The ladder

The pair's, since neither half moves alone.

| rung | probe | reader |
| --- | --- | --- |
| compiles | done | done |
| links | done | done |
| packages | done (`QDProbe.bin`) | done (`QDReader.bin`) |
| loads at boot / launches | **not run** | **not run** |
| installed-vs-wedged distinguishable | — | **not run** |
| callbacks run (`rect_calls` moves) | **not run — the actual question** | **not run** |
| arm / disarm round-trips | **not run** | **not run** |
| refusals counted (`foreign`, `expiries`) | **not run** | **not run** |
| survives boot / shift-disable / removal | **not run** | — |
| per-op cost measured | not run | not run |
| PowerBook 1400c, attended | not run — emulator first, and not without asking | not run |

**The pair sits at *packages*.** Nothing here has run on a Macintosh,
emulated or real. What changed is that every rung above *packages* is now
*observable* — before this file, the ones below "loads at boot" could not
have been reported either way.

## Build

```
cmake -B build -DCMAKE_TOOLCHAIN_FILE=$NOW_PPC_TOOLCHAIN prototypes/qdreader
cmake --build build
```

Build outputs stay outside the repository. Deploy `QDReader.bin` beside
`QDProbe.bin` on a **disposable clone**; the probe needs a cold boot, the
reader does not. A shift-boot is the recovery and belongs in place before
the install.

## What the object file said, rather than what the build said

A clean compile proves nothing here — this file family has already
shipped two defects that compiled clean on the first attempt. Checked
with `powerpc-apple-macos-nm` / `-objdump`:

- **The commit order survives `-Os`.** In `.arm_at` the three stores are
  `stw r31,16(r9)` (`arm_a5`), `stw r3,20(r9)` (`arm_expiry`), and last
  `stw r10,12(r9)` with `r10 = 1` (`arm`). The scheduler interleaved
  register restores between them and did **not** move the commit word.
  The wrap guard is there too (`addic.` then `li r3,1`), so an expiry
  that computes to 0 — "expired on sight" — cannot be published.
- **The low-memory read was not folded into a constant.** `0x00000904`
  is a word in `.data` (at `_main.rw_+0x14`), and the code reads it and
  then dereferences it: `lwz r9,20(r9)` followed by `lwz r4,0(r9)`. That
  matters because the literal form does not survive this compiler at all
  — GCC 14 rejects `*(volatile unsigned long *)0x904UL` under
  `-Werror=array-bounds` ("source object is likely at address zero"),
  which is right about C and wrong about this machine. Routing the
  address through a volatile is the narrow fix; the check confirms it
  bought a real indirect load rather than a comment.
- **No QuickDraw-globals reference.** The probe's first draft read
  `qd.thePort` from resident code that has none. Nothing named `qd`
  appears in this object file's symbols — Carbon would not have offered
  it — and the only drawing state the reader touches is the port it sets
  itself.
- **Imports are all Toolbox plus `memcpy`/`strlen`/`vsnprintf`.** No
  fragment loading, no NOW symbol, nothing of the probe's but one
  Gestalt selector.

## Corpus impact

`corpus_impact: none` — nothing has been measured. This file makes a
measurement *possible*; the first run that produces a `rect_calls` value,
zero or not, owes a finding, because that number is the P3 go/no-go.
