
## RESERVED — a human C pass before main

Michelle, 2026-08-07:

> i plan on a code simplification, cleanup and general pass (especially
> over the C, since its what im least experienced with and very picky
> about things like memory and pointers) before landing on main.
> No need to kick that off now, just worth knowing.

**No lane starts a cleanup pass.** Not a tidy-up, not a "while I'm here",
not a refactor justified by a slice. A competing cleanup would collide
with a review that has not happened yet, and the reviewer is the one who
needs to have read the code — a diff that arrives pre-tidied by an agent
is exactly the diff a careful reader cannot trust.

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
