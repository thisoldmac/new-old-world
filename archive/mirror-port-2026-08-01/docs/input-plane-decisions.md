# Three input-plane decisions

Written 2026-07-31, on the branch that folded `key` in. Two of the three
are **rulings not to build something**, which is why they need a page:
a verb that was deliberately not written leaves no trace in the source,
and the next person to notice the gap re-argues it from nothing.

Each section says what was asked, what was decided, and what the thing
that wanted it should use instead.

---

## 1. `key` — landed, and it cannot carry a modifier

> **CORRECTED 2026-08-01, lane L7 — this section's title and its "What
> NOW can actually do about it" verdict are now wrong, and the "reach
> that does exist" this section said "was not built here" is exactly
> what got built the same day.** `now_input_run_key`
> (`now-guest-ppc/src/input/input_cmds.c`) now narrows the wall instead
> of standing behind it: `mods == 0` posts through the plain event queue
> as it always did, and a nonzero `mods` routes through the act plane's
> own key op (`kNowPeekActOpKey`), served by the NOW Extension's 68K
> resident filter reaching `PPostEvent` from ITS context — the same
> reach `winact` and `menuact` already use (`input_args.c`: "THE WALL,
> NARROWED rather than removed"; `contract/asyncapi.yaml:key`, "THE
> ROUTE, AS OF 2026-08-01"). `ActionModel.availability(.key)`
> (`now-host/Sources/MirrorKit/ActionModel.swift`) and
> `MirrorActionDriver`'s `.key` case both carry the same retraction,
> dated and cross-referenced in place: `key` is available regardless of
> `mods`, forwarded honestly, with the guest's own named refusal
> (`act-plane-absent`, `act-plane-stale`, `act-plane-dark`,
> `act-no-anchor`, …) surfaced rather than a blanket unavailability
> manufactured in advance. The MCP face
> (`AgentIntegrationKeyModifierPolicy`,
> `now-host/Sources/NOWAgentIntegration/Projection/KeyActProjection.swift`)
> validates only that `mods` stays inside the named modifier bits — a
> value outside that mask is still refused before a request is built —
> and otherwise forwards whatever the caller sent.
>
> What is UNCHANGED: whether the route is actually ARMED at the moment
> of a given call is a fact about the paired guest (extension present,
> current, target process pumping its event loop), not something any of
> these three layers can know in advance, so an unarmed guest still
> answers `unsupported` — never a lie of a bare character typed with the
> reply saying `ok`, the defect this whole design still refuses to make.
> The rest of this section (the wall as it stood 2026-07-31, and why an
> act-plane route was originally left unbuilt) is kept for the history —
> read it as "how this looked for one day," not as the current answer.
> **The correction owed to `now-host` at the bottom of this page (item 2)
> is also done**: `ActionModel.menuItem` still exists but is dead code by
> its own comment — `menuSelect` already routes every item, ⌘ or not,
> through `.menuInvoke`.

`textset` writes an addressed element's text **directly**, through the
Dialog Manager's or TextEdit's own setter. `key` posts an event. They
are different mechanisms with different reach, and the second is not an
improvement on the first: `textset` needs no focus and no frontmost
application, and `key` reaches a dialog that answers only keystrokes,
and Return, Escape and Tab, which have no text to set.

### The wall, stated once

| | |
|---|---|
| Where an event's modifiers live | on the Event Manager's **queue element**, not in the message |
| The call that hands that element back | `PPostEvent` |
| Its Carbon availability | **`CALL_NOT_IN_CARBON`** — `Events.h`: "CarbonLib: not available" |
| `PostEvent`'s | in CarbonLib, and it returns no queue element |
| What NOW's application is | Carbon (PowerPC, CarbonLib 1.6 range) |

So this guest can queue a keystroke and **cannot say what was held down
while it was typed.** That inverts the usual posture between the two
ISAs — the older, less capable-looking half of this project is the half
that can do it.

### What NOW can actually do about it

**Refuse.** `mods` with any non-zero value answers `unsupported` and
names the reason. `mods: 0` is accepted, because a caller saying "no
modifiers" is asking for what the verb does.

The alternative — post the keystroke without the modifier — is the
`act.key` defect upstream already paid for: a literal character went
into a document and the reply said success. A refusal is strictly more
information than a lie, and the refusal names `menuact`, which is what
the caller wanted in almost every real case.

### The reach that does exist, and where it is

The **resident half is 68K and not Carbon, and it does call
`PPostEvent`** — that is how the act plane posts its own press
(`ext/src/now_ext_act.c`, `docs/resident-components.md`). So a modified
keystroke is reachable *from NOW*, through the act plane's cell, an
armed extension and a named target A5. It is not reachable from the
application, and `key` lives in the application.

**That is a design worth having and it was not built here**, for two
reasons that should be re-examined before anyone builds it:

- Nothing needs it. The only demand for a command key in this tree is
  the menu shortcut, and `menuact` serves menu items — with or without a
  shortcut — by identity, which is strictly better than a keystroke that
  the Menu Manager matches by virtual key code.
- It costs a `peek_table.h` format bump, a resident op, and an act
  guard, and every one of those is a change to the plane that can write
  into another process. That is not a price to pay for a capability
  nothing has asked for.

If it is ever built: it is an act-plane op, addressed by target A5 like
every other one, and **not** a second `key`.

### The contract sentence this corrected

`menuact`'s own description used to say that a menu item which HAS a
keyboard shortcut "should still go through key: it is simpler and needs
no patch at all." That was upstream's advice about upstream's guest. On
this Mac it is false — the shortcut is a Command keystroke and `key`
cannot post one — so the description now says `menuact` is the route for
**both** kinds of menu item.

**`now-host` owes the same correction**, and it is not this branch's to
make: `ActionModel.menuItem` routes a ⌘ menu item to
`.key(code:, char:, mods: cmdKey)`. Against a NOW guest that is now a
loud `unsupported` rather than a literal character typed into a
document, which is the improvement — but the right shape is to route ⌘
items to `.menuInvoke` beside the shortcut-less ones, since `menuSelect`
already sends the second kind there. See "what is owed on the host"
below.

---

## 2. `click` — decided **no**, and the probes do not need one

### What was asked

NOW deliberately ships `mouseloc` with no companion: a guest-side
pointer mover would hand every no-hijack probe a way to fake its own
control. The cost is that `scripts/probes/h2-items-probe.py` — folder
items, upstream's 40/40 — wants a positional click.

### The decision

**No click verb.** Three findings, in the order that decides it.

**First: on the emulator the probe already has one.** `h2-items-probe.py`
requires `--qmp` and calls `qmp.click()`. Its own gate note says the
blocker is **metal-only**. So the verb would not unblock the probe; it
would unblock the probe *on real hardware*, which is a much narrower
claim than "the h2 lane cannot run".

**Second: metal is exactly where a click verb is least defensible.** The
premise of the no-hijack measurement is a click the guest cannot tell
from a person's, which is why it comes from **outside the guest CPU**.
A guest-side click makes that distinction unmakeable — and metal is also
where the act plane's blast radius has never been measured at all
(`docs/mirror-knowledge.md`: "Cross-process blast radius — the guard was
never reached"). Adding the one mechanism that can forge the evidence,
first, on the machine where the evidence has never been taken, is the
wrong order.

**Third — and this is the part that makes it a real answer rather than a
refusal: a coordinate is not what the probe is actually after.** The
question the h2 lane exists to answer splits cleanly in two, and NOW only
needs one half:

| The half | What it asks | What answers it in NOW |
|---|---|---|
| **Reporting fidelity** | does the Finder's reported item position match where the item is drawn? | a capture compared against the reported rect. No click, no actuation, no hijack surface |
| **Actuation** | can we select or open a named item? | `script` — the Finder's own `select item "X" of window "Y"`. Identity-addressed, metal-safe, no coordinate anywhere |

The second row is the one that matters for driving, and it is
**identity, which is the guard** — the same 18/20-versus-0/20 answer the
act plane already turns on. It is also the oracle the probe already
trusts: h2 reads the selection back through AppleScript, so an
AppleScript actuation is measured by the mechanism the probe already
believes.

### What `elements` cannot mint, and why that is not the gap

`observe` / `elements` walk the Window, Control and Menu lists. **A
Finder icon is none of those** — it has no `ControlHandle`, and the act
plane's six trap patches (`MenuSelect`, `TrackControl`, `FindWindow`,
`GrowWindow`, `TrackBox`, `TrackGoAway`) contain nothing that answers
"which item in this folder was clicked". So `elements` could not mint a
folder item without a new resident trap, and the Finder already exposes
the identity for free through its own scripting terminology.

**That is the recommendation for the h2 probes**: not a click verb, and
not a minted element reference either — the Finder's own item names,
through `script`, scoped to a named window as the lane's own hazard rule
already requires. (`scripts/probes/**` belongs to another lane; this is
the finding, not the edit.)

### If a click verb is ever built anyway

The one thing it must not be is a coordinate with nothing attached. It
would have to carry the identity of what it believes it is clicking —
the way `menuact` carries `titleLeft` and `ctlact` carries a
`ControlHandle` — and refuse when the live element under that point is
not the one named. A bare `click(x, y)` is the target-free form this
whole plane refuses on the strength of a measurement.

---

## 3. `menugeom` — decided **do not port**, delete the assumption instead

### The reason that expired

The act port left `menugeom` behind because it was "a geometry read, not
an act, nothing in NOW consumes item rects, and calling a foreign MDEF
is the riskiest thing in `portal.c`." The middle clause looked false:
`now-host/Sources/MirrorKit/ActionModel.swift` hardcodes
`menuRowHeight = 16` and computes a release point from it, and upstream
**measured** that assumption accumulating ~30 px of error once a menu
contains separators (items 16 px, separators 6 px, mac99).

So `ActionModel` does consume item rects — by assuming them.

### Why porting is still the wrong fix

**The consumer is already dead code.** `menuRowHeight` is read by
exactly one function, `ActionModel.menuItemPoint`, which is read by
exactly one action, `.menuDrag`, and **nothing in the model emits
`.menuDrag` any more.** `ActionModel.menuSelect` routes shortcut-less
items to `.menuInvoke` — the identity-addressed `menuact` — and says so
in its own comment: *"The menu-drag that used to serve this case aimed at
rows computed from a uniform-16px assumption the guest has since
disproved."* The only remaining references to `.menuDrag` are the enum
case, the dispatcher's switch arm, an availability row and one test.

So the choice is not "measure the rows or keep guessing". It is
**"measure the rows, or delete a computation nothing performs."**

**And the geometry has no second customer.** `menuact` names
`(menu, item, titleLeft)`. `titleLeft` is the x of a menu **title in the
menu bar** — which the scene reports directly and no MDEF is needed for
— and the item is an **index**, not a rect. Nothing downstream of
`menuact` computes a point inside a pulled-down menu, because no menu is
ever drawn. Once MirrorKit drives every menu item through the projection
rows, per-item rects have no consumer at all.

**Against that, the cost is the riskiest call in upstream's file.** A
menu definition procedure is foreign code, called with a message that
asks it to compute; it runs in the target application's context, and it
is application-supplied — an application with a custom MDEF is exactly
the case that would be interesting to measure and exactly the case that
can go wrong. There is no metal-safety review for the act plane at all
(`docs/mirror-knowledge.md`), and this would be the first op in it that
calls code the application wrote.

**A dangerous read to feed a computation nobody performs is not a
trade.**

### The ruling

`menugeom` stays unported. The reason on record is no longer "nothing
consumes item rects" — it is:

> The one consumer computes a release point for a drag the model no
> longer emits. `menuact` is identity-addressed and computes no geometry
> at all, so the correct repair is on the host: delete
> `menuRowHeight` / `menuItemPoint` / `.menuDrag` and let every menu item
> go through the projection row. Calling a foreign MDEF to make a dead
> computation accurate would be paying the plane's largest risk for
> nothing.

**Re-open it if, and only if, something needs a rect** — a mirror that
draws menus itself, or a hit test against a menu NOW did not open. Then
the argument is a real one and the MDEF risk has something to buy.

---

## 4. Modified keystrokes — Carbon Event Manager alternative (unverified)

> **NOTE 2026-08-01:** the route that got built (section 1's lane-L7
> correction) is this section's own table's SECOND row — "PPC act-plane
> cell" — not the Carbon Event Manager mechanism this section proposes.
> That table already called the act-plane route "yes / yes (ext calls
> PPostEvent) / yes"; nothing here needed to be discovered, because
> `docs/input-plane-decisions.md` §1 had already named the mechanism, and
> the only thing this section's own probe (`MacCreateEvent` +
> `SetEventParameter` + `PostEventToQueue`) would still be useful for is
> a route into a NON-NOW-aware application with no resident extension at
> all, which is a different problem than `key` addresses. This section's
> status stays UNVERIFIED for that narrower question; it is not evidence
> about the act-plane route, which is now built and tested by
> `KeyActProjectionTests.swift` / `AgentIntegrationKeyModels.swift`.

### The wall

**Status: UNVERIFIED.** The following is a discovered alternative that has not
been tested against a real guest. Before building it, a small probe is needed.

### What was found

The Carbon Event Manager (available in CarbonLib 1.1+, which is within the guest
window) offers a mechanical alternative to `PostEvent` for synthesizing keystroke
events with modifiers:

- `MacCreateEvent` — create an event descriptor
- `SetEventParameter(kEventParamKeyModifiers)` — attach the modifier state
- `PostEventToQueue` — post the event to the target application's event queue
- `GetMainEventQueue` — obtain that queue

**The open question:** Does a synthetic Carbon keyboard event created this way
and posted to a WNE-based front application's queue arrive as a classic
`EventRecord` with the modifier bits intact? If yes, this route avoids the
`PPostEvent` wall and would let `key` carry modifiers. If no, it is not a
working solution.

### Probe scope, if undertaken

Test whether:
1. An event created via `MacCreateEvent` + `SetEventParameter(kEventParamKeyModifiers)` + `PostEventToQueue`
2. Reaches the target application's WNE event loop as a classic `EventRecord`
3. With the modifier state readable in `EventRecord.modifiers`

### Why this matters, if the probe succeeds

This becomes the fourth mechanism in this family:

| Mechanism | Host reachable | Guest reachable | Modifiers carry |
|---|---|---|---|
| `key` verb to PPC app | yes | no (PostEvent is no-mod) | no |
| PPC act-plane cell | no (requires arm) | yes (ext calls PPostEvent) | yes |
| Carbon Event Manager (if it works) | yes (guest is Carbon) | unknown | unknown |
| `menuact` addressing a menu item's shortcut | yes | yes | not applicable (handled by Menu Manager) |

**Headers to cite when documenting the probe:**
- `CarbonCore/Events.h` (MacCreateEvent, SetEventParameter, PostEventToQueue, GetMainEventQueue)
- Offset lines would be from the Retro68 build of Universal Interfaces, which the guest compiles against

---

## What is owed on the host

Neither of these is this branch's to make (`now-host/**` has another
writer today); both are one-liners in shape.

**CORRECTED 2026-08-01: items 1 and 2 are done** — see the lane L7 note
at the top of section 1. Item 1 is not re-verified by this pass (it is
about a test file's own classification, not the input plane); item 2 is
confirmed by reading `ActionModel.menuSelect` and `.menuItem`'s own
comments, which now state the same thing this list asked for.

1. **`DispatchedVerbNameTests.sent`** classifies `"key"` as `toolkit`,
   and asserts a toolkit verb is *not* declared in the contract. NOW now
   declares `key`, so that row moves to `"contract"` — which is the
   outcome the assertion's own failure message asks for ("That is good
   news… move it to `contract`").
2. **`ActionModel.menuItem`** should route a ⌘ menu item to
   `.menuInvoke` rather than `.key(…, mods: cmdKey)`. NOW's `key`
   refuses a modifier by design; `menuact` serves both kinds of menu
   item.
3. **`ActionModel.menuRowHeight`, `menuItemPoint` and `.menuDrag`**
   should go, per section 3.
