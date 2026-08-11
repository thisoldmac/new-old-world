<!-- now-doc-provenance: generated reviewed=false -->

# Reading a classic Mac desktop, as Mirror left it

**Date:** 2026-07-31 · **Status:** recorded knowledge, carried from the
parked upstream project `timbottu/mirror`. Nothing on this page was
measured by NOW.

Source documents, now superseded by this one: the perceive half of
`archive/mirror-standalone-2026-08-09/docs/CONTROL-SURFACE.md`, `FOLDER-ITEMS.md`, `IR-V1.md`, the
scene-IR half of `MIRRORKIT-PLAN.md`, and the reading sections of
`PROTOTYPE-NOTES.md` and `STATUS.md`.

**Provenance.** Every measurement is upstream's, on a session-private
QEMU `mac99` clone of `os91-runner.qcow2` running Mac OS 9.1, unless the
row says otherwise. Two comparison numbers come from a real Quadra 950
over MacTCP and are labelled. These are evidence about mechanisms NOW
has ported, not NOW measurements.

## The plane, and what each layer needs

| Plane | Source | Requires | Gives | Upstream state |
|---|---|---|---|---|
| process | a process-list verb | any stable guest worker | which apps run, which is front | proven live, mac99 |
| window / menu | a full accessibility tree | the observer INIT | window rects, z-order, controls, menus, dialog text | proven live, mac99 |
| content | the QuickDraw op stream, plus pixel islands where an app composites offscreen | the QuickDraw INIT | window interiors | proven live, mac99, 2026-07-17 — see [mirror-content-plane.md](mirror-content-plane.md) |
| content, offscreen (2026-08-06) | the same op stream from a hooked GWorld, joined to the window by `blitsrc`; worlds hooked at CREATION by a `_QDExtensions` trap patch | the same resident | interiors of applications that composite offscreen — which is most of the ones a person cares about | emulator-verified on mac99/OS 9.1, **not metal**; the row above's "plus pixel islands" is now a fallback rather than the plan. See [render-composition.md](render-composition.md) |

**The limitation that forces the INIT.** A process-list verb tells you
*which* applications run and which is front, but **cannot draw foreign
windows or menus** — the Window Manager and Menu Manager keep their
roots in **per-process A5 globals**, invisible from outside. That is the
whole reason a `GNEFilter` INIT exists: the hook goes to the roots
because the roots will not come out. It returns full foreign trees with
**zero heap scanning**.

## What the tree exposes

| Element | Fields | Not exposed |
|---|---|---|
| Window | title, kind, visible, `rect[l,t,r,b]`, `z` (window-list chain index), controls, display ops, island | true cross-app z-order |
| Control | title, visible, enabled, ref, rect, `value`/`min`/`max`/`checked`, role (`scrollbar` when ranged) | precise **kind** — button vs checkbox vs radio; the CDEF procID is not in the record |
| Menu | id, title, left, enabled; items with index, title, enabled, command char, mark, icon, style | — |
| Dialog text | text (≤1024), length, selection, active, truncated — **only dialog-kind windows** | non-dialog document bodies; TextEdit not rooted in a public `DialogRecord` |
| Fleet | per-app tree *or* a per-app oracle error, with no focus change | faceless / never-pumped apps report an honest error |

**Control sub-state offsets** upstream read: `contrlValue` / min / max at
`+18` / `+20` / `+22`.

### Freshness, stated honestly

The observer samples an application's UI roots **only when that app
pumps its event loop** — immediately on an A5-world or window-list
change, otherwise at 10 Hz. A host read demands a sample no older than
2 s. **A never-pumped or faceless app has no sample and is reported as
an error, not guessed.**

Practical consequence: a freshly launched application shows an
oracle-not-found error until it first pumps. That is correct behaviour,
not a defect.

## References — identity, not coordinates

Upstream's element reference is
`<scheme>/<PSN-hi><PSN-lo>/window:<title>#<occ>/control:<title>#<occ>/node:<fnv32>`
— live PSN, session-time, **no pointer and no coordinate.**

It survives redraws and window moves (resolved by title, occurrence and
fingerprint) and **fails closed** on quit or relaunch (a new PSN), on a
front-app change, on the control disappearing, and on an identity
change. The node fingerprint is what makes reordered duplicate titles
fail as *stale* rather than silently retarget.

Every act verb addresses an **opaque, observation-minted reference**.
This is the same finding the act plane records from the other side: 18/20
versus 0/20 turns on naming the object rather than the place.

**Window ids are not stable across a raise.** The id embeds an
enumeration index, and that index **is** z-order — the guest walks the
window list front-first. Raising the back document of a multi-window app
renumbers ids, so a cache keyed on the id would miss on exactly the
event the cache exists for, leaking an entry per raise. Upstream keys on
`psn/title`, splitting same-titled windows in one app by their top-left
corner.

## The menu-list layout

This is the second thing NOW re-derived that upstream had already
answered. A NOW milestone was declared blocked because `LMGetMenuList()`
returns a structure that appears in no header available here. The
upstream menu walker had carried the offsets all along.

| Value | Meaning |
|---|---|
| 6 | first menu entry offset |
| 6 | per-entry stride to the title's left coordinate |
| 14 | menu-list entry size |

Read the ported walker (`now-guest-ppc/src/axwalk/axmenu.c`) as the
authority; the point of this row is that **the question was already
answered**, not that the numbers should be copied out of a document.

### The NUL-prefix observation

Measured on mac99: **all 16 Apple-menu entries below the separator, in
the Finder's menu bar, carry a two-NUL (`\0\0`) prefix before the
name**, and those 16 names are byte-for-byte the 16 files in
`System Folder:Apple Menu Items`, in the same order. The Finder's
**Window** menu carries `\0Desktop` — **one** NUL.

**The NULs are real, not a Pascal length-byte misread.** The same walk
parses File / Edit / View / Special correctly, reads `0x1b` hierarchical
command bytes, and stops on the item list's own zero-length sentinel. A
fixed off-by-N would corrupt every menu, and could not produce a prefix
of two *and* a prefix of one in the same pass.

**Who writes the prefix is unidentified.** Apple's published Menu
Manager documentation describes no NUL prefix, so upstream filed it as
an observation with an open provenance question — not as an explained
mechanism. Treat it the same way here.

Stripping the leading NULs took one tree frame from 33 NUL escapes and
17 unmatchable item titles to zero.

**The Apple menu's contents are per-application.** SimpleText's own menu
record holds only `About SimpleText…` and a separator; the Apple Menu
Items entries are walkable in the **Finder's** menu list only.

**Item heights are not uniform** — separators 6 px, items 16 px on
mac99. See [mirror-act-plane.md](mirror-act-plane.md) for the 30 px error
that assumption caused.

## Icons and positions — three different answers

This subject cost upstream three attempts and produced a clean rule at
the end. It is the clearest example on any of these pages of a *wrong
source* masquerading as an unanswerable question.

| Surface | Correct source | Wrong source that was tried |
|---|---|---|
| Desktop icons | `fdLocation` from the catalog — desktop items are hand-placed, so the saved position **is** the on-screen position | — |
| Mounted disks and Trash | ask the Finder; they are not Desktop Folder catalog entries | `fdLocation` — they have none |
| Items inside a Finder icon-view window | ask the Finder for the item's live `position` | `fdLocation`, and separately the QuickDraw op stream |
| Items in a list or column view | **unknown — nothing detects the view type** | — |

### `position` is not `fdLocation`

| | `fdLocation` (catalog) | the Finder's live `position` |
|---|---|---|
| What it is | the **saved** icon grid | where the Finder has laid the icon out **now** |
| Coordinate space | folder-local, saved | window-content-local, live |
| Follows a scroll? | **no** | **yes**, exactly |
| Good for | remembering a layout | clicking |

Measured on mac99, 2026-07-31, one folder in a window with content rect
(13,47)–(417,265): at rest the two differed by a constant **(52, 25)**;
after scrolling down 128 px, **every live `position` y moved by exactly
−128 and every `fdLocation` v did not move at all.**

So `fdLocation` is not "a few pixels off." It is a different quantity,
and it is wrong by an unbounded amount the moment a window scrolls.

Also measured: an item's `bounds` is `position … position + 32` — the
icon box is 32×32 with its top-left at `position`. So an item's screen
point is `window content origin + position + (16, 16)`.

**The result, and its oracle.** Clicking that computed point and then
asking the Finder which file is selected: **40/40 correct** (20 at rest,
20 after scrolling eight lines). The same code with positions taken from
`fdLocation` instead: **0/40.**

The mutation's *failure mode* is worth as much as the number. The
mutated build did not click the wrong file — it **refused**, reporting
that the item was at a position the Finder had scrolled out of view. A
clipping check and a re-hit-test caught a wrong position before it
became a wrong click.

### Two dead ends, so they are not retried

1. **The QuickDraw op stream does not carry window icon positions.** The
   Finder composites icon views offscreen and blits the result — see
   [mirror-content-plane.md](mirror-content-plane.md). Confirmed three
   ways.
2. **AppleScript `position` errors for items inside a window** — until
   you ask it the right way. The earlier attempt concluded the Finder
   "does not expose live window-item positions"; it does, via the generic
   window class.

### Finder scripting terminology, verified live on OS 9.1

| Works | Fails |
|---|---|
| `window` (the generic class) | `Finder window` (the class) |
| `item of window i` | `target of window` |
| `count windows` | `count Finder windows` |

The argument key is `source`; the output is source-form **with outer
quotes**.

**A standing hazard travels with this.** Every script must be scoped to
a window the Finder is already showing. **None of them may search.** A
whole-disk Finder search wedged a real machine for about twelve minutes
(a lab finding from 2026-07-05). This is one of the few upstream hazards
that is *about metal*.

### Design notes that are load-bearing

- **Chrome insets are derived, not written down.** The clickable icon
  field is bounded by the window's own scrollbar rects — the info bar
  ends where the vertical scrollbar begins. No phantom constants, and it
  tracks a guest whose chrome metrics were never measured.
- **An invisible item has no click point.** An icon scrolled out of the
  field reports itself as not actionable and the act path refuses.
  Inventing a point for an icon the Finder is not showing is precisely
  how a click lands on the wrong file.
- **The directory model is cached; scrolling is a projection.** One script
  round trip through the Finder costs **1–2 s** (measured, mac99) — far too
  much per scroll. The cache key includes container identity, viewport size,
  and non-value control geometry (so list headers invalidate icon geometry),
  but excludes window position and scrollbar values. Cached item boxes are
  translated by the live scroll-value delta; the host also applies the
  pending delta immediately while the guest act settles. Resize or a view
  change refreshes the roster; moving or scrolling does not.
- **A list row is a semantic target.** `bounds of every item` supplies a
  16-pixel glyph in name view, but the host-owned list presents each visible
  row as the named item. Clicking the label or the rest of that row resolves
  to the same named item, never to an invented coordinate in empty content.
  Renderer and hit tester share one view inference path, including old guests
  that report an unknown view word; a row can therefore never be painted as a
  list and handled as generic window content.
- **Selection is a host-owned exact set with guest settlement.** Click,
  control/right-click, shift-click and rubber-band gestures update the set
  synchronously. Command-A, Command-O, inline rename and Escape operate on that
  same set. The guest then receives a bulk Finder script naming the exact
  container and items; stale names refuse before the script is sent.
- **A thumb drag is one resident gesture.** Press, motion and release share a
  lane that buffers motion or release arriving before `dragpress` has settled,
  so a fast local drag cannot produce `no drag held` or strand the guest mouse
  button. Wheel input is bounded to three line-control acts per captured event
  and previews the same delta locally.
- **Two windows with the same title get no items** rather than each other's.
  AppleScript addresses them by title even though the host joins the answer
  to an exact WindowRecord identity.
- **A failure the cache could hold.** One busy-Finder script timeout
  marked a layout resolved anyway, and that window then served **no items
  at all** for the rest of the process's life. The layout signature is
  now recorded only when the Finder actually answered.

### Icon art

Icons come from each application's own resource-fork bundle, keyed by
`(creator, type)`; a generic bitmap by kind is the fallback. See
[mirror-assets.md](mirror-assets.md).

- **Control panels are type `APPC`, not `cdev`.**
- The hard-disk icon **lives in ROM / Icon Services — there is no file** —
  so it is drawn procedurally.
- True per-application icons via the Desktop database were **not
  possible as built**: the call is not in the Retro68 headers and would
  need the Desktop Manager traps declared. The resource-fork route covers
  the ordinary set; the database would additionally catch custom alias
  icons, which today collide on a generic glyph.

## The scene contract

Upstream froze its scene IR at **version 1** on 2026-07-31. The shape of
that freeze is more useful to NOW than the field list.

| | |
|---|---|
| **Frozen** | the encoded field set, enumerated twice — as wire key paths *and* as declared type/property pairs |
| **Additive within v1** | a new field is recorded in an additions list; the version stays 1; old consumers ignore keys they do not know |
| **Breaking** | removing or renaming a field moves the major, and the new major needs its own manifest |
| **Consumer duty** | read the version, refuse an unknown major, *then* decode — in that order |

**Two enumerations rather than one, because each covers the other's
blind spot.** The wire-path list is the contract a consumer sees, but it
can only observe a field the probe scene actually populates; the
property-derived list still sees a field that was added and never filled
in.

**The version number lives in two places on purpose:** beside the
payload in the envelope, so a consumer can read the gate **without
decoding the thing it guards**, and inside the body as the IR's
self-stamp, which is what the fixture corpus pins. They are the same
number, copied from one source.

### The rule worth carrying: do not freeze a field whose values are wrong

Upstream **dropped** the folder-items field from its freeze because the
positions it carried were known to be wrong. *Freezing a field whose
values are known wrong is the expensive half of a contract — it obliges
you to keep serving the wrong number.*

It came back the same day, once the right source was found, and it came
back **additively**: recorded in the additions list, still absent from
the frozen set, major unchanged.

Two other fields were dropped for a cleaner reason: they had never been
on the wire at all. Island pixels ride their own pager, not the scene,
so freezing that field would put a base64 blob into an interchange
contract no consumer had ever received.

### Rect-order calibration

A genuine cross-plane trap:

| Source | Order |
|---|---|
| the accessibility tree | `[l, t, r, b]` — and the window rect is the **content** port; the title bar sits *above* it |
| the process-list plane | Mac-native `[t, l, b, r]` |

Controls arrive **global** and are converted to content-local. Upstream's
renderer used a fixed 20 px title-bar height, **not read from the
wire** — an approximation it flagged as such.

### `windows[].rect` is a join key, and that is why the title-bar constant stays

Read this before "fixing" `kNowSceneIRTitleBarHeight`
(`now-guest-ppc/src/scene/scene.h`) into a real measurement. It looks
exactly like the kind of guess this project deletes on sight, and on
2026-08-07 an audit of the surface recommended deleting it. It was kept
deliberately, and here is the argument, so the next person does not have
to reconstruct it from a diff.

**What the field is.** IR v1's `windows[].rect` is not a rectangle the
machine has. It is a **box both sides construct and decompose the same
way**: the producer sends the content region grown upward by the
constant, and the consumer recovers the content origin at
`rect.t + titleBarHeight` before it compares a click to a control's
content-local rect (`MirrorKit`'s `HitTester`, `FinderItems`,
`InteractionPolicy`). Its value is that the two spellings match — which
is what a join key is for, and what a measurement cannot be.

**Why the true structure region is the wrong answer here.** It is the
more faithful rectangle and it is *undecomposable*: a consumer holding
one cannot recover the content origin from it, because the difference
between the two regions is not a constant. Title bars are not one height
across window kinds and the Appearance Manager draws them procedurally —
which is precisely the objection to the constant, and it applies with
equal force to any consumer trying to undo it. A producer that started
sending the structure region alone would be sending something no
consumer on the other side can use, and IR v1's key set is frozen, so it
cannot send both under this name either. **That is a version's work, not
a producer's.**

**What DID change on 2026-08-07**, and this is the part worth keeping:
the constant used to be a *substitute for reading the region*. Three
branches of the scene's window walk each answered `rect` differently —
content grown by the constant for a bound foreign process, `peek_read`'s
structure region raw for an unbound one, Carbon's structure region for
NOW's own — because the two window readers each returned one region and
a different one. Both readers now return **both** regions from the
machine, and every branch derives `rect` the one way. So the constant is
now an approximation that sits **beside** the measurement and can be
checked against it, rather than a third answer competing with two.

**What that was worth, measured.** NOW's own window reported
`{l:22, t:48, r:779, b:555}` — the true structure region — while its
content top was 70. A consumer decomposing that got 68. **The render was
two pixels out on every control in that window**, on every frame, and
nothing could see it, because both halves were internally consistent and
neither was wrong about anything it could state. The same window now
reports `{l:28, t:50, r:772, b:548}` and decomposes exactly.

**What is still owed.** A caller holding a rectangle cannot ask which
region it is. `elements`/`axtree` publish the raw **content** rect under
`bounds` while the scene publishes the **box**, and nothing distinguishes
them. That wants a provenance field, and it should land once, in the same
vocabulary as the other rectangle provenance rather than as a second
scheme of its own.

Two more stated approximations, both hypotheses upstream never closed:

- **Cross-app z-order is reconstructed**, not read — and there are no
  cross-links to find. `WindowList` is a per-process low-memory global,
  so no application's chain reaches another's. Since 2026-08-07 the
  reconstruction is the order applications were last watched coming to
  the front (`now-guest-ppc/src/scene/front_order.h`), which on a machine
  that layers by application IS the layer order, rather than Process
  Manager enumeration, which is launch order. A process never watched
  coming forward has no rank and the scene's `depth` coverage claim says
  so.
- **Default button** — the wire does not carry defaultness, so the first
  button in a dialog is assumed to be it.

## The wire

**The guest serves exactly one connection, serially.** A fresh socket per
request races its own accept, and the transport refuses the new
indication — the busy path that exists to reap crashed clients. The
caller sees **a bare connection reset with no explanation on either
side**, and the contract is that the client reconnects.

This single mechanism manufactured an entire retracted narrative about a
verb starving the agent and a watchdog resetting connections. It bit
again, separately, when a second scripting client was opened while the
mirror held its own, and a round of results was wrongly blamed on the
act path.

Rules upstream ended up with:

- **One wire client per worker per process.** The poller and the act
  dispatcher share one connection.
- **One host process per guest worker.** You cannot poke the guest from a
  side script while the mirror holds it.
- A refused listen was **invisible on the guest side** because the
  transport notifier cannot log safely. The fix counts refusals in the
  notifier and reports from the idle path — along with a handler that
  returns no reply, and any dispatch that holds the main loop over about
  a second.

### Wire-stress measurements

Emulator, `mac99`, upstream's process plane and tree plane:

| Plane | Poll rate | Polls | Errors | Latency mean / min / max | Payload |
|---|---|---|---|---|---|
| process list | 0.5 s | 69 | 0 | 1.2 / 0.96 / 7.3 ms | ~1.4 KB |
| process list | 0.2 s | 147 | 0 | 1.2 / 0.90 / 9.1 ms | ~1.4 KB |
| full tree (2 windows, 9 apps) | 0.5 s | 383 | 0 | 4.9 / 3.0 / 346 ms | ~12 KB |
| full tree (2 windows, 9 apps) | 0.2 s | 123 | 0 | 4.6 / 4.1 / 16.8 ms | ~12 KB |

**Real hardware, for contrast — a Quadra 950 over MacTCP** pays about
**32 ms per request**, and the same tree measured **307 ms median** at
front scope there. Payloads stay small on both. This is the one place
upstream's perceive numbers touch metal, and the ratio is the useful
part: the mechanism is not the cost, the transport is.

Other measured samples (mac99): a front-scope tree of one window, 11
controls and 8 menus was **13,980 bytes in 2.1 ms**; a front-scope tree
generally around 10 KB.

### An optimisation upstream designed and did not build

The observer's shared table already carries a seqlock counter and a tick
stamp. A verb returning just those turns 5 Hz of full trees into 5 Hz of
**8-byte reads** plus the occasional tree. Stated as a hypothesis with a
plausible path, never measured.

## What is genuinely open

- **List and column Finder views.** Nothing detects the view type, and
  the live-position question was never measured there.
- **Precise control kind** — button versus checkbox versus radio. The
  CDEF procID is not in the record.
- **True cross-app z-order** (above).
- **A freshness field on the element-search surface.** Upstream's search
  answered from whatever scene it happened to hold, with **no age in the
  reply** — it once reported a pre-open window list and made a successful
  open look like a failure. Everything else in that contract is careful
  about staleness; this was not.
- **A fixture for the content plane** — see
  [mirror-content-plane.md](mirror-content-plane.md).
- Scale: all forty folder-item trials used **one folder in one window**.
  Hundreds of items, two windows at once, a live window move, and the
  per-window truncation cap were never exercised against a guest.
