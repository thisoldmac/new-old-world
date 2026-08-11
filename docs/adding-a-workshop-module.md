# Adding a Workshop module

The guest is **one window**. Everything a person can do lives on a page
inside it, and a page is a *module*: a file that owns some controls and
some pixels, and nothing else. This is how to add one, and what the
contract expects of it.

Read [guest-ui-start-here.md](guest-ui-start-here.md) first — it is the
errata that will bite you regardless of what you are building.

## The contract

`now-guest-ppc/src/workshop/workshop_module.h` declares `WorkshopModuleOps`. A module
exposes exactly one symbol:

```c
const WorkshopModuleOps *my_module_ops(void);
```

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

Modules are created **lazily** and then hidden, never disposed, so a
page keeps its state — scrollback, listing, settings — for the whole
run. Do not put anything in `create` that assumes it runs once per
visit.

### What you own, and what you do not

You own your child controls' *identity* (the `ControlRef`s) and any UPP
you construct. You do **not** own the window: `DisposeWindow` takes
every control with it, so `dispose()` should null your refs and release
UPPs — never `DisposeControl` them.

If you build a Data Browser, dispose its callback UPPs **after** the
window is gone, not before; `files_browser_view.c` shows the shape, and
the reason is `carbon-upp-is-not-a-cast-on-cfm` in the corpus.

## The six edits

Adding a page touches six places. Miss one and it either does not
appear or does not switch.

1. **`workshop_module.h`** — add the ID to `WorkshopModuleID` and bump
   `kWorkshopModuleCount`. The enum order **is** the View menu order and
   the sidebar's DEFAULT order; the menu item number is the module ID.

   The nav ids must stay the contiguous prefix `1..kWorkshopNavRows`,
   with the pinned group after them — `kWorkshopIsNavModule` and the
   saved sidebar order both depend on it, and a static assert fails the
   build if a page lands between `Chat` and `Preferences`. So a nav page
   goes in **before** `Preferences`, and a pinned one **after**
   `Connection`.
2. **`workshop_layout.h` / `.c`** — `nav_rows[]` is sized for the
   non-pinned modules via `kWorkshopNavRows` (11 today — the enum in
   `workshop_module.h` is the truth when this list rots, as it has
   before). Grow that constant; the loop in `workshop_layout_compute` is
   already generic. `Preferences`, `Logs` and `Connection` are special:
   all three are pinned below the divider (`prefs_row`, `logs_row`,
   `conn_row`) and are not in `nav_rows`. A module placed above
   `Connection` renumbers it, which bumps the prefs format — Logs took it
   to 12, its Invert switch to 13, the Preferences page to 19; see
   `now_prefs_load`. To pin a new page in the footer instead of the
   scrolling list, add its own row rect the way `logs_row` does and map
   it in `row_rect()`.

   **`nav_rows[i]` is the i-th visible SLOT, not the i-th module.** It
   was indexed by module ID until the rail learned to scroll and to be
   rearranged; both make "row 3" and "module 3" different things. The
   rail maps a slot to a module through the person's saved order plus
   the scroll offset, and `row_rect()` returns **NULL** for a nav row
   that is currently off screen — every caller has to handle that, and
   it is an ordinary state rather than an error. Slots past
   `nav_visible` are zeroed, so walking the whole array draws nothing
   for them instead of painting a stale row over a live one.
3. **`workshop_sidebar.c`** — add a `k_rows` entry (title, subtitle,
   icon ID) and, if it IS pinned, map it in `row_rect()` and add it to
   the pinned lists in `workshop_sidebar_draw`, `workshop_sidebar_click`
   and `module_at_visual`. A nav page needs none of that: it arrives
   through the order table automatically, including at the foot of an
   arrangement someone already saved.

   The subtitle is what the **compact** density drops, so it must be
   genuinely secondary — a row whose title alone does not say what the
   page is will be unreadable for anyone running compact.
4. **`workshop_window.c`** — add a `k_module_info` entry (title, blurb,
   and the placeholder line shown until the module registers) and
   register the ops in `workshop_open()`.
5. **`main.c`** — add the View menu item with its Cmd-key. The item
   number must BE the module ID: Networking once landed without an item
   and every entry below it selected its neighbour.
6. **`now-guest-ppc/CMakeLists.txt`** — add the source file(s).

Plus a 16×16 `ics#` in `now-guest-ppc/resources/app.r` for the sidebar icon.
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
