# The drawn cursor follows what we act on (P8)

Until 2026-08-07 the guest's **sprite** sat wherever it had last really
been drawn while every act and every drag happened somewhere else. This
is what changed, why the obvious explanation was wrong, and what is still
unknown.

It matters more than it sounds. A screendump was evidence of what the
machine looked like and never evidence of *where we acted*; software that
draws relative to the pointer was a permanent special case; and a person
at the machine watched a Macintosh click on things with the arrow parked
somewhere else, which does not read as a machine being operated.

## What was wrong

P4 (`ext/src/now_ext_act.c`) and P7 (`ext/src/now_ext_drag.c`) both moved
the pointer the documented Inside Macintosh way:

| Global | Address | What reads it |
|---|---|---|
| `MTemp` | 0x0828 | the cursor VBL task's staging point |
| `RawMouse` | 0x082C | the cursor's own position |
| `MouseLocation` | 0x0830 | `GetMouse()` |
| `CrsrNew` ← `CrsrCouple` | 0x08CE ← 0x08CF | asks the task to redraw |

Everything the Toolbox **reads** followed those writes exactly — the
guest's own `mouseloc` reported each point it was given — and the sprite
never moved. Five resident moves, five screendump pairs, **zero pixels
changed each time** (`tools/local-cursor-sprite.py`, emulated
mac99/OS 9.1).

## The obvious explanation was wrong, and that is the useful half

The suspicion was the rig: an emulated pointing device reporting absolute
position over the top of our writes, which would mean the documented
technique was fine and **metal was the easy case and the emulator the
hard one** — the opposite of the usual assumption, and worth being
definite about before anybody concludes the approach is unsound.

It is not the rig. Read from **outside** the guest through QMP, with
nothing touching the host pointer:

- all three globals held our value unchanged across seconds — nothing
  overwrites them;
- the machine profile carries **no pointing device at all** beyond the
  machine's default ADB mouse (`-M mac99,via=pmu -device usb-kbd`; no
  tablet), and it reports nothing when nobody moves it;
- every precondition the recipe needs was met: `CrsrCouple` 0xff
  (coupled), `CrsrState` 0 (drawable), `CrsrObscure` 0, `CrsrBusy` 0;
- and `CrsrNew` read back **0x00**, so our request had been *consumed*.
  The cursor task ran. It did not draw.

What the emulated **device** did instead says why. After a device move
the Cursor Device Manager's own `CursorData` record held *fractional*
coordinates (419.63, 333.25 — acceleration), and the changed pixels boxed
the old sprite together with the new one. Our writes reach that record
too: it followed every resident move exactly, to the integer.

So the manager knows where the cursor is and is simply not the thing
`CrsrNew` asks. **On Mac OS 8/9 the Cursor Device Manager owns the
pointer's position, and the low-memory globals are downstream of it
rather than upstream.** That is an operating-system fact, not an emulator
one, so metal is not expected to differ — and nothing below is a rig
workaround.

It is also not the whole answer, and the next section is the rest of it:
calling the manager was necessary and was *not sufficient*.

### How low memory was found, which is not a detail

Physical `0x828` on a Power Mac is **not** `MTemp` — it holds PowerPC
exception code. Mac OS's 68K low-memory globals live at a logical address
the nanokernel maps elsewhere, so the diagnostic **finds** the window
rather than assuming one: it drives the pointer to a point only that run
chose, dumps physical memory, and looks for the three adjacent copies of
that `Point` that `MTemp` / `RawMouse` / `MouseLocation` are. On this rig
the base is `0x4000`; the script refuses to read anything if more than
one candidate matches, because "I found several and chose" is the shape
of a wrong answer nobody can audit.

## What P8 is

`ext/src/now_ext_cursor.c`, plus two Cursor Device Manager calls in
assembly (`now_ext_cursor_cdm.S`) because `CursorDevices.h` declares the
whole manager as `TWOWORDINLINE` traps GCC ignores — a C call links
against a symbol that does not exist, and the Pascal frame is the part
that fails *quietly* if you get it backwards.

One entry point does both halves:

```c
int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, unsigned flags);
```

- **The low-memory writes stay, unchanged and unconditional.** They are
  what a tracking loop reads and what makes an act's click land where the
  act says. That half was never broken and P8 does not gate it on
  anything.
- **`CursorDeviceMoveTo` is added beside them**, which is the call a
  mouse driver's own interrupt handler makes sixty times a second — which
  is why it is safe from P7's Time Manager task, and why it is an
  absolute move with no acceleration applied, which is what an act needs.
- **and the redraw, which is the part the next section is about.**

`flags` carries two facts that are the CALLER's and cannot be worked out
here: `kNowCursorPlaceOwned` (I am holding the pointer for a gesture and
must not yield) and `kNowCursorPlaceInterrupt` (no Toolbox beyond
low-memory accessors). P4's `act_post_click` passes neither; P7's
`drag_place` passes both. The first version inferred the second from the
first, because the drag happened to be the only interrupt-time caller —
an accidental coupling waiting for a second caller.

`now_ext_drag.c` no longer spells `0x08CE` at all: one plane owns the
cursor, and two files spelling the same two addresses is how a pair
drifts.

## Three routes, and only the third draws

This is the part worth reading before anyone "simplifies" the plane.

| Route | What it does | Does the sprite move? |
|---|---|---|
| low memory | `MTemp`/`RawMouse`/`MouseLocation`, then `CrsrNew` ← `CrsrCouple` | **no** |
| device | `CursorDeviceMoveTo`, then the cursor task through `JCrsrTask` | **no** |
| QuickDraw | `HideCursor()` then `ShowCursor()` | **yes** |

The first two are not decoration and are not dead code: they are what
makes the machine *agree* about where the pointer is. `CursorDeviceMoveTo`
answers `noErr` and the manager's own `CursorData.where` reads back
exactly the requested point — verified from outside the guest, `where`
was 760,520 — while the drawn arrow sat at 419,333 where the emulated
device had last left it. Calling the cursor task directly through
`JCrsrTask` (0x08EE), the vector the pointing device's own interrupt
handler uses, changed nothing either.

So on Mac OS 9 the **blit** lives somewhere in the device interrupt path
that neither the manager's state nor the compatibility vector reaches.
`HideCursor` erases the sprite from wherever it really is; `ShowCursor`
draws it at the current mouse position, which is the one we just wrote.
The pair is a nesting counter rather than a cursor setter, so the SHAPE
is preserved and an application's own `SetCursor` still decides what is
drawn.

### Two consequences that are not obvious

**The redraw is owed, not performed.** QuickDraw needs a real context and
the drag vehicle runs at interrupt time. So an interrupt-time placement
records a debt and the next jGNE pass settles it — the same split P7 uses
for its owed `mouseUp`. It is deliberately *not* gated on the act plane
being armed: the debt is a picture that disagrees with the machine, and
disarming a plane does not make the arrow correct again. The yield rule
is re-checked at settlement rather than trusted from the placement,
because time has passed and a person may have taken the mouse in exactly
that window.

**`CrsrObscure` must be cleared, because we ARE the mouse moving.**
`ObscureCursor` is what every text application calls on every keystroke —
hide the arrow, the person is typing, keep it hidden *until the mouse
moves*. The pointing device's driver clears the flag on its next report.
Without the resident doing the same, P8 draws faithfully into an
invisible cursor: `route` correct, `by_device` climbing, zero pixels
changed, indistinguishable from the plane not working — and it would have
worked perfectly in an empty Finder and vanished in every application
anybody actually drives.

## The cursor's SHAPE already tracks our position

**Answered, and the answer is yes.** SimpleText launched, its text area
at 4,20–619,581; the resident placed the pointer at 311,100, inside it.
The sprite drawn there is an **I-beam**, not an arrow
(`S-inside-text.ppm`).

Nothing in this plane knows what an I-beam is. SimpleText picks its
cursor from its own event loop — read `GetMouse`, decide, `SetCursor` —
and `GetMouse` follows the resident's writes, as it always has. So
**shape mirroring needs nothing from the guest beyond what P8 already
does**: an application asked where the pointer was, was told our point,
and chose the cursor for it.

That is the load-bearing part for the deferred "mirror the guest's own
cursor" feature. The remaining work is on the HOST — reading the current
`Cursor` and drawing it — not on the guest, and not on this plane.

## Optional, in the charter's sense

`kNowPeekTableCapCursor` (bit 8) is published **only** if
`_CursorDeviceDispatch` is implemented *and* the manager answered with a
device. Without it every act and every drag behaves exactly as before and
the picture is the only thing missing —
[docs/resident-components.md](resident-components.md)'s rule.

A fallback to the old `CrsrNew`/`CrsrCouple` recipe still runs, and is
**reported as its own route**. That is deliberate and is the failure this
plane is most likely to reintroduce: a cursor plane that is present,
armed and silently taking the low-memory route looks *identical* to one
that is working — both report a position, neither errors — and only one
of them moves the picture.

## It does not fight a human

Before every placement the resident asks whether the pointer is still
where **it** last put it. If it is not, somebody else is driving, and for
`kNowPeekCursorYieldTicks` (60 ticks — one second) afterwards the sprite
is left alone.

Two things about that rule are load-bearing:

- **Only the picture yields.** The position writes still happen, so an
  act still lands exactly where it says it does. A person's pointer and
  our click are not competing for the same thing.
- **A drag never yields.** Mid-gesture this plane *is* what is driving
  the pointer, so "it moved since we placed it" is not evidence of a
  person, and yielding would strand the sprite halfway through a gesture
  the application is already tracking.

The declines are counted (`yielded`), because a courtesy nobody can
observe is indistinguishable from a bug. One second is small on purpose:
this is a courtesy, not a lock, and a long one would make the cursor stop
following for reasons nobody watching could explain.

## Reading it from the outside

`mouseloc` gains rows when P8 is present — route, device, last point, and
the four counters. It is there rather than in a verb of its own because
`mouseloc` is where the pointer *is*, P8 is the reason the pointer's
*picture* is anywhere in particular, and until it landed the two answers
could differ by hundreds of pixels with nothing on either face able to
say so. Absent resident, absent plane and a too-short table all add
**nothing** rather than zeros: a row saying `asked 0` would claim a plane
that is not there.

## Diagnostics

- `tools/local-cursor-mechanism.py` — finds the low-memory window, reads
  the cursor globals from outside, and answers whether anything
  overwrites the resident's writes.
- `tools/local-cursor-sprite.py` — the screendump pairs, with the
  low-memory globals, the Cursor Device Manager's record and the pixels
  read at every step, because a cursor that does not move has three
  separable places to stop and a screendump alone cannot tell them apart.

Both report the **bounding box** of the changed pixels and not just the
count. "22 pixels changed" is compatible with a sprite that moved, a
clock that ticked and a caret that blinked; where they changed is what
distinguishes them.
