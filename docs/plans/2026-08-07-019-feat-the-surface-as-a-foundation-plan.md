
## RESERVED — a human C pass before main

Michelle, 2026-08-07:

> i plan on a code simplification, cleanup and general pass (especially
> over the C, since its what im least experienced with and very picky
> about things like memory and pointers) before landing on main.
> No need to kick that off now, just worth knowing.

**Clean up your own work — that is not what this reserves.** Michelle,
correcting an earlier draft of this section that said no lane should:

> Lanes can and should do their own cleanup, i dont want you blocking
> them from doing that. But a global pass will be necessary anyway.

So: leave your slice in the state you would want to review. Simplify what
you wrote, delete what you replaced, name things properly, and fix the
memory and pointer handling in your own diff rather than shipping it
rough for somebody else. That is doing the work, not polishing it.

**What is reserved is the GLOBAL pass** — a sweep across code no single
slice owns, a repo-wide refactor, or a tidy-up of somebody else's diff on
the way past. Two reasons, and the second is the one that costs:

- Fifteen lanes reformatting shared C is a merge problem, and this arc
  has already lost work to keep-both resolutions three times.
- The global pass is a **reading** exercise as much as an editing one.
  Its value is that a person who is picky about memory and pointers has
  gone through it. Pre-tidying by an agent does not produce that, and can
  hide the thing worth finding.

What lanes SHOULD keep doing, because it is what makes that pass cheap:

- **Run the `classic-mac-carbon-ui` skill's `audit_source.py`** over
  `now-guest-ppc/src/**/*.c` after guest UI work. It is the existing
  automated half.
- **Say why, not what**, at the surrounding density. A comment explaining
  a pointer decision is worth more to that pass than the code being
  prettier.
- **Leave the deliberate ugliness declared.** Where something looks wrong
  and is right, the comment saying so is the difference between a review
  that keeps it and a review that "fixes" it.

### The C surface this arc grew, as a map for that pass

Not a claim that any of it is wrong — a list of where to look, because
the arc's C is new rather than settled:

- `now-guest-ppc/src/scene/` — the walk, `walk_verdict`, title/rect
  hygiene (`now_scene_title_is_publishable`, `now_scene_rect_is_sane`),
  `cdef_resolver.c`, `controlsState`.
- `now-guest-ppc/src/act/` — settlement marks, drag cells, the act
  deadline against the writer lease.
- `ext/src/` — `now_content.c`'s hook table and ring, the P6 liveness
  Time Manager vehicle, `now_ext_act.c`'s press path.
- `contract/peek_table.h` — the shared struct, its static asserts, and
  the new caps / `channel_state` / `rest_state` split.
- `now-guest-shared/`, `contract/guest_identity.h` — code compiled by
  three different compilers, which is where packing drift bites.

### Memory- and pointer-shaped findings from this arc, worth reading first

These are already understood and written down; they are the places where
an unexplained-looking decision has a reason:

- **`LockPixels` relocates the PixMap RECORD**, so offscreen worlds are
  matched by shape rather than pointer identity. Looks like a missed
  optimisation; is not.
- **The control pool is shared across the whole scene**, not per window —
  which is why a window walked after the pool fills publishes `[]`
  identically to one that genuinely has none. Measured: nine panels
  spanning 6–73 controls against a pool of 96.
- **Two 64 KB ceilings** — the control-frame cap and the agent transport
  — both of which have already shipped a defect by being stated in more
  than one place, or in a comment rather than where both sides read it.
- **A ring record's `port` is the window identity key**, and the blit
  join currently looks up with the *bits record's* generation rather than
  the generation the held ops were recorded under.
