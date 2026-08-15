<!-- now-doc-provenance: generated reviewed=false -->

# Adding a Workshop module

The guest is **one window**. Everything a person can do lives on a page
inside it, and a page is a *module*: a file that owns some controls and
some pixels, and nothing else. This is how to add one, and what the
contract expects of it.

Read [guest-ui-start-here.md](guest-ui-start-here.md) first — it is the
errata that will bite you regardless of what you are building.

## The contract

`now-guest-ppc/src/workshop/workshop_module.h` declares the static
`WorkshopModuleDefinition`, its runtime `WorkshopModuleInstance`, and
`WorkshopModuleOps`. A migrated module exposes its definition:

```c
const WorkshopModuleDefinition *my_module_definition(void);
```

That definition is the module's one composition record. It keeps the stable
product ID, visible copy, sidebar icon, `core` / `experimental` / `debug`
tier, future domain grouping, optional product-feature binding, and ops
factory beside the implementation. Do not copy any of those fields into the
Workshop window or sidebar.

The Workshop registry resolves all statically linked definitions before the
window can select a page. It asks the product feature policy whether each
definition is admitted, resolves its ops table, and pairs both with one
runtime instance. The implementation is still linked into the application;
feature admission controls reachability, not dynamic loading.

Every op may be NULL except `create`. What the Workshop guarantees:

| op | called | must |
|---|---|---|
| `create(owner, body)` | first time the page is selected | build controls **invisible** (`NewControl(..., false, ...)`) |
| `dispose()` | window close / quit | release only what you own (see below) |
| `show(visible)` | on every page switch | Show/Hide your controls |
| `layout(body)` | grow, zoom, disclosure changes | Move/Size your controls |
| `draw()` | update events | draw text and custom art; controls draw themselves |
| `click(event, local)` | content clicks | return true if you handled it |
| `key(event)` | key-down while selected | return true if you consumed it |
| `activate(active)` | window activate/suspend | Activate/DeactivateControl |
| `idle()` | **every event-loop pass** | be nearly free (see below) |
| `status_text(out, cap)` | placard repaint | one line, or leave empty |
| `describe_scene(writer)` | host observation | **required if `draw()` draws text** — emit the same strings and rects it does |

`describe_scene` is the only route by which anything a page draws by hand
reaches the host's observation plane. Controls do not need it: every one
of them is already a Control Manager fact that `control_kind.c` hands
over. Raw QuickDraw is different — it tells nobody anything, so a page
that draws a heading, a fact row or a scrollback line and leaves this
entry NULL is reported to the host as an **empty body**, which is
indistinguishable from a page with nothing on it.

That is not hypothetical: for most of this project's life exactly one
page implemented it and sixteen did not, so most of the Workshop looked
blank to the plane. `now-guest-shared/tests/module_describe_scene_source_test.py`
now fails any module whose source draws text while this entry is NULL.

The shape to copy is **one walk taken twice**, not a second function that
re-derives the same strings: write `<page>_content(writer)` (or per-piece
`emit_*` helpers) that draws when the writer is NULL and describes when it
is not, and have both `draw()` and `describe_scene()` call it. Two walks
are two chances to disagree, and a page that describes something other
than what it drew is worse than one that describes nothing. Keep
draw-only side effects — repaint caches, "this string is now shown"
bookkeeping — behind `if (writer == NULL)`: describing changes no pixels,
so marking a string shown would swallow an invalidation `idle` still owes
it.

Modules are created **lazily** and then hidden, never disposed, so a
page keeps its state — scrollback, listing, settings — for the whole
run. Do not put anything in `create` that assumes it runs once per
visit. Construction is a transaction: `created` becomes true only after
`create` succeeds. A failed attempt disposes the module's non-control state,
rolls back every control created since the transaction marker, and remains
eligible for a later retry.

### What you own, and what you do not

You own your child controls' *identity* (the `ControlRef`s) and any UPP
you construct. You do **not** own the window: `DisposeWindow` takes
every control with it, so `dispose()` should null your refs and release
UPPs — never `DisposeControl` them.

If you build a Data Browser, dispose its callback UPPs **after** the
window is gone, not before; `files_browser_view.c` shows the shape, and
the reason is `carbon-upp-is-not-a-cast-on-cfm` in the corpus.

## The bounded edits

Moving an existing page into the atomic shape should change ownership, not
behavior:

1. Add `my_module_definition.c` beside the implementation and declare its
   accessor in the module header. Keep `my_module_ops()` internal to that
   domain. The stable ID, tier, domains, and feature binding must match
   `docs/module-manifest.yaml`.
2. Change the one case in `workshop_registry.c` to return the module-owned
   definition, then remove that page's compatibility definition from the
   registry. The registry keeps only the composition list; it does not regain
   copy, icons, policy, or construction details.
3. Add the definition source to `now-guest-ppc/CMakeLists.txt`, and run the
   guest build plus the documentation gate. The gate compares every live PPC
   definition with the manifest.

A genuinely new page additionally needs an explicit `WorkshopModuleID`, its
View-menu command, rail geometry or pinned-row behavior, public module page,
manifest row, media slots, 68K posture, and — if it draws any text of its
own — a `describe_scene` (the gate above) and, where "the whole page as
text" is a sensible thing to hand someone, a `copy_text` for Edit▸Copy. Existing numeric IDs are persisted
and **must never be renumbered**. The current rail stores the non-pinned pages
as a contiguous prefix and pins Preferences, Logs, and Connection at 15–17;
adding another page therefore requires an intentional rail/prefs migration,
not an enum insertion disguised as a small module edit.

`nav_rows[i]` is the i-th visible slot, not the i-th module. The rail maps a
slot through the person's saved order and scroll offset, and `row_rect()`
returns `NULL` when that row is off screen. Every caller must accept that as
ordinary state. Every rail row is one line — the title — so the title must
identify the page by itself; the subtitle is what the hover tag shows when
the pointer rests on the row, and a non-core `tier` also draws a short
right-aligned mark that the title truncates around. A new page joins the
rail's curated default order in `now-guest-ppc/src/workshop/workshop_order.c`,
which carries the adjacency argument in prose beside the table.

Add a 16×16 `ics#` in `now-guest-ppc/resources/app.r` for a new sidebar icon.
**Do not** plot it with `PlotIconID`: the System file can outrank your
resource at a colliding ID and draw something else entirely. Use
`plot_small_icon()` in the sidebar, which blits your own bytes. That is
the finding `ploticon-suite-loses-to-system-family`.

## The rules that are not negotiable

These are the ones that have already cost this project time. The full
list is in [guest-ui-start-here.md](guest-ui-start-here.md); these are
the ones a *module* trips over.

**Idle work must be free.** `idle()` runs every pass, and during a
transfer the loop runs with no sleep at all. Read no files. Call no
`HiliteControl` unconditionally — it redraws whatever it is passed, so
an unconditional call is a flicker loop. Cache the last value you drew
and repaint only the rectangle that changed. Every module here keeps
`g_shown_*` caches for exactly this.

**Pump the wire inside every tracking loop.** `TrackControl` takes
`now_pump_action()`. The exceptions are real and narrow: popup CDEFs
need `(ControlActionUPP)-1L` (their own action), and a scroll bar's
indicator part takes NULL because the Control Manager does not call an
action proc for the thumb. Nested loops are audited in
[nested-loops.md](nested-loops.md); anything new that stalls belongs in
that table.

**Never open a dialog from pumped code.** A modal opened from a network
callback nests inside whatever loop is already running. Wire code sets
status strings; modules read them.

**Drawable strings are ASCII or MacRoman.** A UTF-8 dash in a C literal
is mojibake through `DrawString`. Comments are free; strings are not.

**Format dates with the Long variants.** `DateString` takes a signed
long and classic seconds passed 2^31 in 1972, so every modern date
renders as one identical wrong date. `LongDateString` is correct
(`classic-datestring-clamps-past-1972`).

## Layout and testing

Put the page's geometry in a function that takes the body rect and fills
a struct of rects — `compute_rects` in every module here. Click and draw
then read the same numbers and cannot disagree.

If the geometry is worth a test, make it a **pure unit** with no Toolbox
calls and test it with the host `cc`, the way `workshop_layout.c` and
`conn_fields.c` are tested. That is the only kind of guest test that
runs here rather than on the machine:

```sh
cd now-guest-ppc/tests
cc -Wall -Wextra -Werror -I ../src workshop_layout_test.c \
   ../src/workshop_layout.c -o /tmp/t && /tmp/t
```

Watch a new test fail before you trust it — reintroduce the bug and see
it named. And remember what the levels mean: *builds* proves nothing,
*tested* means the suites pass here, **metal-verified** means someone
watched it on the PowerBook. Most of the surprises in this project came
from code that looked obviously correct and had never run there.

## Persistence

If the page has settings worth keeping, add fields to `NowPrefs` and a
new `PrefsRecordV<n>` that embeds the previous one, then read them
gated on both `format >=` n **and** `count >=` the size. The record is
accretive: old files must still load, which is why the dead v3
window-session slots are still in the layout even though the windows
they described are gone.
