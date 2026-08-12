<!-- now-doc-provenance: generated reviewed=false -->

# Known wrong, on purpose

Everything NOW knowingly ships that disagrees with the machine, or
knowingly does not do, **with the reason and what would close it**.

This is not a bug list. [`open-issues.md`](open-issues.md) is that, and it
is organised around *broken* versus *unverified* — what nobody has fixed
and what nobody has watched. This file is the third category and it is
organised around a different axis:

> **A defect nobody has noticed is an open issue. A defect we have
> measured, understood and chosen to keep is a decision** — and a
> decision with no visible justification is indistinguishable from an
> oversight.

Michelle met one on 2026-08-07 — the grow box, which was then row KW-01
— and had to ask why it was still there. The reason existed; it was in a
lane report. Nowhere a person looking at the product would find it. That
row is gone: `claude/019-kw01-kw06` withdrew the fabricated grow box the
same day, which is what a row on this list is for.

So every row here is something somebody **could argue with**. If you
think a row is the wrong call, the row tells you what closing it costs.

## Read this before quoting a row

- **This file is hand-maintained and therefore rots.** This repository
  has been bitten by exactly that three times in one day
  ([AGENTS.md](../AGENTS.md) > "Enumerated lists rot at merges"). The
  parts that could be gated are gated — see below — and the parts that
  could not are prose someone has to keep true.
- **What is gated:** `now-host/Tests/HostTests/KnownWrongRegisterTests.swift`
  reads this file. It checks every row's shape (all six fields present,
  ids unique and contiguous, `Owner` and `Status` from a closed
  vocabulary), and for the rows whose claim is checkable in code it
  checks the *claim itself* (KW-01 and KW-06). **When a
  lane fixes one of those, that test fails and names the row to
  close.** A register that
  keeps claiming a defect somebody already fixed is worse than no
  register.
- **Row ids are POSITIONAL, and they move.** Contiguity is gated, so
  closing a row renumbers every row below it — the grow box was KW-01
  and the ctlact false negative was KW-06, and closing the first shifted
  the second to KW-05 before it was closed in turn. The gate is right
  that a gap reads as a row somebody deleted without closing, and the
  cost is that **an id is not a permanent name**. So cite a row by its
  TITLE as well as its number, in a commit message or anywhere else that
  outlives this file's current shape, and treat a bare `KW-nn` from an
  older document as a pointer to a position rather than to a defect.
- **What is not gated:** everything else. Rows about the guest, the
  resident, the 68K side and the emulator are prose. Nothing checks that
  their measurements are still true.
- **Rows link rather than restate.** Where the full story is already in
  `open-issues.md` this file cites the heading and adds nothing but the
  decision — a claim in two places is a second place to be wrong.

## The fields, and what each one is for

Every row carries six, and the gate fails a row missing any of them:

- **What disagrees** — what the product does that the machine does not,
  or what it does not do at all. In product terms, not in code terms.
- **Measured** — the evidence that establishes it. A row with no
  measurement is an opinion and belongs in `open-issues.md` instead.
- **Why it is left** — the argument. This is the field the file exists
  for.
- **What would close it** — and what that costs. So the row can be
  argued with by someone who is not going to read the source.
- **Owner** — `Michelle` where she decided it, a `claude/…` lane where a
  lane decided it, `unassigned` where nobody has.
- **Status** — `decided` or `undecided`. `undecided` means measured,
  understood, still shipping, and nobody has said keep it. Those rows are
  here to be *closed*, not to be justified.

---

## KW-01 — no zoom box is drawn on any window, including the five that have one

- **What disagrees:** `WindowChrome.zoomBox` returns nil for every
  window. Of the nine windows in sweep D, five have a zoom box on the
  machine and none of them get one in the render.
- **Measured:** sweep D's zoom column, per rectangle: **121/121 agreeing
  pixels on the four windows with no zoom box, 1/121 on the five that
  have one**. The guest shows nine colours in that box, the render three.
  Before the change, seven of eleven corpus windows were drawn a zoom box
  the machine does not draw, and `HitTester` reported it as a target — so
  a zoom act sent a click into the racing stripes, which the Window
  Manager reads as the start of a **drag**.
- **Why it is left:** an affordance the machine does not offer is worse
  than a missing one — a fabricated one moves windows. Sweep D scored the
  trade as right and the cost as real: *"a majority of windows now MISS a
  widget they have, where before a minority had one invented."* This row
  exists so nobody reads "the render is exact on chrome" without the
  qualifier: that is true only of windows without a zoom box.
- **What would close it:** the answer is already in the WindowRecord —
  `spareFlag` is the zoom flag, one byte, sitting beside the `windowKind`
  the walk already reads (`now-guest-ppc/src/scene/scene_walk.c`). Cost:
  **a contract field first, then the guest read, then both guests**, in
  that order. Small, and unlike the grow box that used to sit above this
  row it is a READ rather than an act — which is why that one was closed
  by withdrawal and this one can be closed by answering it.
- **Owner:** `claude/019-titlebar-fidelity`
- **Status:** `decided`

## KW-02 — Chicago is drawn where the machine draws Charcoal

- **What disagrees:** font id 0 is "the system font", which under
  Appearance on this project's whole guest range is Charcoal. Where the
  asset pack carries no Charcoal strike at a size, the renderer draws
  Chicago. Chicago is wider, so a run the application clips loses its
  last glyph.
- **Measured:** it cost a day before anyone named it — group-box frames
  appeared to cross their own labels and three people read it as a chrome
  defect. It is also the residual in the title band: sweep D's Appearance
  row is 23/24 rather than 24/24, and the disagreeing row is in the band
  where the title sits. See `open-issues.md` > "FIXED: the font
  substitution was silent…" (`claude/019-honest-substitution`).
- **Why it is left:** Michelle, 2026-08-07: *"our fonts are ok at this
  stage, im happy enough with them."* The substitution is accepted; the
  **silence** was the defect, and that is what got fixed —
  `MirrorKitUI/FontSubstitution.swift` makes the substitution answerable
  (what was asked for, what was served, whether the width came from the
  machine or from us) and derives it live rather than stating it as a
  constant.
- **What would close it:** a Charcoal strike per size in the asset pack,
  plus a guest-supplied font *name* for the dynamically-assigned ids the
  contract does not carry today (font id 2002 draws the menu-bar clock,
  Appearance's "Current Theme:" line and all 102 Key Caps labels — almost
  certainly Charcoal, and not stable across machines, so mapping the
  number would be a guess dressed as a fact).
- **Owner:** `Michelle`
- **Status:** `decided`

## KW-03 — one window interior at a time; every other window renders a hatch

- **What disagrees:** the content plane (P3) is a per-window, TTL-bounded
  spotlight, not a plane. One window's interior is live; every other
  window in the scene renders "Interior not captured — one window at a
  time". And **a background process never arms at all**, so no shape here
  can serve more than the front process's windows.
- **Measured:** `tools/local-multiwindow-cost.py`, 2026-08-07,
  lane-private clone. Arming the front window: 203 ms. Retargeting to the
  same process's other window: 117 ms — the handshake was never the cost.
  Round-robin over two windows at a 2 s dwell: **4,011 ring bytes/s and
  10 forced repaints** against a control of one standing arm at **33
  bytes/s and 0 repaints** — 122× the ring traffic, because every arm
  issues an `InvalWindowRect` at the newly armed window. The ceiling was
  reproduced with a control: NOW's own window, targeted while the Finder
  is front, never arms in 10 s while `wrongContext` climbs ~56/s, and
  arms 204 ms after being brought forward with no re-request.
- **Why it is left:** Michelle, 2026-08-07 — leave it, and circle back if
  it causes friction. Round-robin is refused **on the measurement**: it
  forces a repaint of a live application's window at the rotation rate,
  and each rotation discards the leaving window's composite lineage.
- **What would close it:** option (a) in `open-issues.md` > "RESERVED FOR
  A DECISION, with the numbers attached: one window interior at a time" —
  `arm_window` becomes a bounded array and the capture gate a membership
  test. Cost: an **in-memory contract change** (`contract/content_table.h`)
  and therefore an ext bake, a verb change and its parity seam, and ≤N
  extra compares in the resident's hottest path. Front process only under
  every option; multi-process interiors are closed, not expensive.
- **Owner:** `Michelle`
- **Status:** `decided`

## KW-04 — the title-bar geometry has a residual on windows flush to the top of the screen

- **What disagrees:** after the `contentTop` 22 → 20 correction, six of
  sweep D's nine windows agree on every sampled row. Two do not, by one
  row, and one by a single pixel. Windows sitting at `t = 20` — directly
  under the 20-pixel menu bar — have their `t-2` and `t-1` rows *inside
  the menu bar*: the guest reports its black row at `-1` and the render
  puts it at `0`.
- **Measured:** sweep D, per rectangle. Apple System Profiler 19/24 rows,
  SimpleText 21/24, both at `t = 20`; Appearance 23/24, and that row is
  KW-02's. Separately, one pixel at `(432, t+19)` on an inactive window —
  where the content ring meets the bar's last row — renders `696969`
  against the machine's `555555`; its four neighbours are exact.
- **Why it is left:** the correction that landed took the whole corpus
  from a systematic two-row offset to a one-row disagreement confined to
  the two rows the menu bar owns. The remainder is a blend at a junction
  of two integer fills. The pixel gate **excludes exactly that pixel and
  says so**, rather than widening a tolerance that would hide the next
  real defect.
- **What would close it:** deciding who owns the two rows where a
  window's frame and the menu bar overlap, and drawing the junction as a
  blend rather than as two fills. Cost: small and fiddly, with a real
  risk of trading one exact-pixel row for another — which is why nobody
  has spent it on 1 row in 24 and 1 pixel in 4.
- **Owner:** `claude/019-titlebar-fidelity`
- **Status:** `decided`

## KW-05 — check boxes and radio buttons render as bare labels

- **What disagrees:** the guest declines to name any control from CDEF 0
  or CDEF 23 — the classic and Appearance **button families** — because
  push button, check box and radio button share one id and are told apart
  only by the variation code. With the pills correctly withheld, and the
  machine's own mark not reaching the replay either, Memory's radios
  render as a bare label where the machine draws a filled circle.
- **Measured:** `now-guest-ppc/src/scene/control_cdef.c` — CDEF 0 and 23
  return no role by name, with the reason in the comment. Sweep D's CDEF
  column: Memory 33 → 23 classified of 44 and `pushButton` 10 → 0; Date &
  Time 19 → 10 of 21 and 10 → 1. Control and reference totals unchanged
  on every row — nothing was lost; the identical set of controls stopped
  being called push buttons.
- **Why it is left:** returning "button" for a check box **authorises the
  wrong act**. Before the change every check box and radio button in OS
  9's own control panels was named a push button at knowledge `derived`,
  and drawn as a Platinum pill — a confident wrong answer rather than a
  better one. Withholding the name is the correct trade even though it
  visibly costs the mark.
- **What would close it:** two separable things. The classification needs
  the variation code, which cannot be read from a control this
  application does not own. The **mark** is a capture gap and is the
  cheaper half: the machine draws it, and the content plane does not
  bring it back.
- **Owner:** `claude/018-control-semantics`
- **Status:** `decided`

## KW-06 — menu item geometry assumes uniform 16-pixel rows

- **What disagrees:** `ActionModel.menuRowHeight = 16` and
  `menuItemPoint` computes a release point from it. Rows are not uniform
  once a menu has separators, so the computed point drifts down the menu.
- **Measured:** ~30 px of accumulated error, compounding with item index
  (`open-issues.md` > "`menuRowHeight` is a known-wrong constant
  (2026-07-31)").
- **Why it is left:** the original reason — *nothing in NOW consumes item
  rects* — has **expired**: `MirrorOracleKit/ActionDispatcher.swift` calls
  `menuItemPoint`. The live mitigation is that `menuact` addresses a menu
  item **by identity** and computes no geometry at all, so the correct
  route does not touch this constant. The constant is kept because the
  geometric route is the fallback where identity is unavailable, and a
  drifting point is more useful than no point.
- **What would close it:** porting Mirror's `MENU_GEOMETRY`, which needs
  a new resident op to read the real row heights. Cost: an ext change and
  therefore a bake, plus its contract.
- **Owner:** `unassigned`
- **Status:** `undecided`

## KW-07 — the classic-side file browser cannot rename, delete, move or make a folder

- **What disagrees:** the guest's Files page lists, navigates and pulls.
  It offers no rename, no delete, no new folder and no move.
- **Measured:** `file.move`, `file.trash`, `file.restore` and `file.mkdir`
  already exist in the contract, **the guest already serves all four**,
  and `HostShare` learned to serve them on 2026-07-20 with 13 tests. The
  wire and both servers are done; the only missing piece is guest UI, plus
  a decision about undo.
- **Why it is left:** Michelle punted it 2026-07-20 — write and overwrite
  were the goals of the slice and both work.
- **What would close it:** a Workshop module edit (six edits, per
  [`adding-a-workshop-module.md`](adding-a-workshop-module.md)) and an
  undo decision. **Worth knowing before auditing for dead weight:** the
  host-side implementation currently has no client. It is tested,
  symmetric and unused, and it was built deliberately rather than left
  over.
- **Owner:** `Michelle`
- **Status:** `decided`

## KW-08 — the Mirror keeps polling the guest when it is not on screen

- **What disagrees:** backgrounding the Mirror module does nothing to the
  poll. Clicking Console does not stop NOW asking the guest for scenes.
- **Measured:** `MirrorContainerTests` fails the build if any view on that
  path grows an `onDisappear`, so the absence is enforced rather than
  incidental.
- **Why it is left:** stopping the poll sounds thrifty and is not. Every
  `now_mirror_*` projection and the fidelity sweep read the same source,
  and they refuse while it is stopped — so an agent's drive would start
  refusing **because a person clicked another tab**. `open-issues.md`
  flags this as the decision most likely to be revisited by somebody who
  has not read it.
- **What would close it:** a poll that idles on visibility but wakes for
  any projection read — which means the projections and the view share a
  demand count rather than a lifecycle. Cost: real, and it buys a poll
  the guest was already cheap enough to serve.
- **Owner:** `claude/019-embed-mirror`
- **Status:** `decided`

## KW-09 — modal alert chrome is drawn from the old, unmeasured procedure

- **What disagrees:** every window with a title bar was re-derived from
  the machine's own pixels in August. The `isDialog` path — `kind == 2`
  with an empty title — was not, and keeps its July drawing.
- **Measured:** nothing. That is the row: it is unmeasured, and the one
  alert in the corpus does not agree with a document frame either
  (`open-issues.md` > "STILL BROKEN, and named rather than worked
  around", item 6).
- **Why it is left:** the titlebar lane derived what it could observe on
  eleven front windows and declined to extend a measured procedure to a
  class it had not measured. Guessing there would have produced the same
  kind of confident-wrong drawing the zoom box was removed for.
- **What would close it:** one alert, photographed on a lane-private
  guest, and the same rung-4 derivation the title bar got. Cheap; nobody
  has posed an alert.
- **Owner:** `claude/019-titlebar-fidelity`
- **Status:** `decided`

## KW-10 — arcs and polygons are not drawn

- **What disagrees:** `DisplayReplay` has no case for the `arc` or `poly`
  display ops. A polygon arrives as a bounding box and is never drawn as
  the shape.
- **Measured:** zero instances of either in the whole op corpus. The
  deferred-op inventory went 73 → 39 ops without either of them being
  needed.
- **Why it is left:** nothing was built for ops with no corpus instance.
  Both stay **named whole** in the deferred inventory and `polySize` rides
  in `ext1` as honesty telemetry, because a counter that fell silent would
  read as coverage.
- **What would close it:** a renderer case each, once something in the
  corpus draws one. The telemetry is what will say when.
- **Owner:** `unassigned`
- **Status:** `decided`

## KW-11 — two of the fourteen 68K census probes refuse by design

- **What disagrees:** on NOW-68K, `scsi` reports the bus as present and
  **not scanned**, and `selectors` is not served. Twelve of fourteen
  probes answer.
- **Measured:** `now-guest-68k/src/census/census68.c` — even the gate is
  reported, because "there is a bus and we did not scan it" is a
  different sentence from "there is no bus". The `selectors` table is
  **32 KB of names against a 384 KB partition**.
- **Why it is left:** an INQUIRY bus scan is active bus I/O, the 180c's
  internal disk is on that bus, and a wedged target on a cooperatively
  scheduled 68030 is a power cycle. Doing it properly means somebody in
  front of the machine — which is the whole reason that machine is parked
  ([`180c is physically fragile`](68k-metal-runbook.md)).
- **What would close it:** a supervised metal session for `scsi`; for
  `selectors`, a partition that can afford 32 KB, or serving the table
  from the host instead of the guest.
- **Owner:** `unassigned`
- **Status:** `decided`

## KW-12 — the Screenshots page's status line is correct by timing, not by structure

- **What disagrees:** a previous "Failed: …" note can sit over a
  successful send. In practice it is overwritten shortly after by
  `conn_set_shot_note`, so the window in which it is wrong is small.
- **Measured:** the correctness is a race that happens to be won
  (`open-issues.md` > "A refusal that outlives the thing it was about
  (2026-08-07)" > "Not fixed, and deliberately").
- **Why it is left:** it was found while fixing something unrelated, and
  folding it in would have widened that diff. Named here so it is a
  decision instead of an oversight — which is this whole file's argument
  in one row.
- **What would close it:** clearing the note on the success path rather
  than relying on a later write. One edit.
- **Owner:** `unassigned`
- **Status:** `undecided`

---

## What this sweep could not reach

Stated plainly, because a register that looks complete and is not is
worse than a short one:

- **`docs/local/` holds almost nothing.** It is gitignored scratch and
  this checkout has two files in it. Any deliberate deviation recorded
  only in a session's working notes, on a branch that has not merged, or
  in an agent's report that was never graduated, is **not in this file
  and cannot be found from here**. That is the same hole
  [`docs/local/README.md`](local/README.md) exists to name.
- **Lane reports on unmerged branches were not read.** There are ~40
  `claude/019-*` branches. This register was derived from
  `claude/019-integration-7` plus `claude/019-sweep-d`, so a decision
  taken on a lane that has not landed is missing.
- **The 68K guest is under-represented.** One row. Its asymmetries are
  declared in [`command-parity.md`](command-parity.md) and gated by
  `CommandParityTests`, which is a better place for them than here — but
  the ones that are product-visible rather than verb-level have not been
  swept.
- **Nothing here is metal-verified.** Every measurement quoted is from an
  emulated guest or a host test.

## Adding a row

1. Confirm the deviation is **deliberate**. If nobody has argued for it,
   it is an `open-issues.md` entry, not a row here — unless it is
   measured and understood and still shipping, in which case it is a row
   with `Status: undecided` and it is here to be closed.
2. Copy the six fields exactly. The gate fails a row missing any.
3. Give it the next `KW-nn`. Ids are contiguous; the gate checks.
4. If the claim is checkable in host-testable code, **add the check** to
   `KnownWrongRegisterTests` so the row cannot outlive its own defect.
5. Link to `open-issues.md` rather than restating it.
