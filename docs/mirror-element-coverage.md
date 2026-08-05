# What the Mirror can and cannot see — the element gap ledger

**Status:** derived 2026-08-05 from a ten-panel corpus captured off a live
emulated Power Mac G4 (guest `a4a59d37d100`, resident
`67d5ef434db7def800d4ba35690c43b2434ccf32`). Slice 5 of
[the headless-Mirror plan](plans/2026-08-04-009-feat-now-headless-mirror-mcp-plan.md).
Re-derive it with `tools/mirror-corpus`; do not hand-edit a row from memory.

Every capture takes three independent reads of the same moment — the guest
framebuffer over QMP, the IR over `now_mirror_snapshot`, and the guest's own
structures over the harness — because the renderer and MCP both read the IR
and would be equally blind to anything the producer never captured. The
`ir`-versus-`guest` diff is what assigns a gap to a LAYER; without it an
enumeration is a list of complaints.

## What the corpus says

308 items across seven distinct panel windows.

| reading | count | what it means |
|---|---|---|
| `knowledge: unknown` | **190 of 308 (62%)** | the producer saw a control and could not determine its kind |
| `knowledge: known` | 118 | kind determined |
| addressable — controls | 96 of 122 | Control Manager items mostly carry a ref |
| addressable — dialog items | **75 of 186** | fewer than half of DITL items can be named |

Kinds actually determined, across the corpus: `staticText` 38, `userItem` 38,
`pushButton` 11, `icon` 10, `editText` 8, `checkBox` 6, `radioButton` 4,
`picture` 2, **`listBox` 1**.

## The rows

Layer: **producer** (the guest walk did not capture it) · **IR** (the model
cannot express it) · **client** (a face drops what it was given).
Class: **readable** (a documented structure exists) · **custom** (drawn, no
structure) · **art** (composited pixels).

| # | gap | layer | class | evidence | honest interim |
|---|---|---|---|---|---|
| 1 | **A list's cells are never read.** Monitors' resolution list is `kind: listBox, knowledge: known` with `text: "Selected value unavailable"` and no cells — the entire content of that panel is an empty rectangle. `Scene.Semantics.listCells` and `listTotalCount` exist and are unfilled. | producer | readable (`ListRec`) | `monitors/ir.json`, VGA Display | already honest — says the value is unavailable |
| 2 | **62% of items have no determined kind.** Not a few stragglers: 190 of 308, including items with real titles (`Show:`, `Resolution`). A control whose kind is unknown cannot be drawn as the right widget, which is the Date & Time "radios drawn as push buttons" red at its source. **Split and re-classed 2026-08-05 — see below; the class was wrong.** | producer (**throughput**) | readable (`kControlKindTag`) | corpus-wide | already honest — `knowledge: unknown`, `role: unknown` |
| 3 | **Extensions Manager's list is 24 `userItem`s.** The panel's whole purpose is a scrolling list of extensions; the IR carries no list at all. Whether these are List Manager lists behind a user item or fully custom drawing is **not yet known**, and that question decides whether row 1's fix reaches this panel. | producer | **needs discovery** | `extensions-manager/ir.json` | draws nothing; no false widget |
| 4 | **Fewer than half of dialog items are addressable** (75/186), against 96/122 for controls. An agent — and the act plane — can see items it cannot name. | producer | readable | corpus-wide | refuses by name (`now_mirror_drive`) |
| 5 | **Sound: 0 of 64 items addressable**, the worst window in the corpus, and 75 items truncated to 64. | producer | readable | `sound/ir.json` | refuses by name |
| 6 | **The harness reads window titles as binary garbage** — every window in every `guest.json` (`'\x192?\x1f!?…'`), where the IR has correct titles. The independent oracle is wrong here, not the thing it is checking. | client (oracle) | readable | corpus-wide | none — the oracle silently reports garbage |

## Splitting the 190 — row 2, opened up (2026-08-05)

Slice 6 opens by asking how much of row 2 is real work. The premise was
that the 190 is two populations wearing one coat: a **standard Toolbox
CDEF**, whose identity is documented and was simply dropped, and a
**genuinely app-owned CDEF**, where drawing is the only evidence there
will ever be. Reading the split was expected to be a lookup.

**The population split, derived from the corpus** — de-duplicated by
window title, first capture wins, exactly as the totals above are:

| | items | undetermined |
|---|---|---|
| Control Manager controls (`source: control`) | 122 | **121** |
| Dialog items (`source: dialogItem`) | 186 | **69** |
| | 308 | 190 |

And the number that reframes the whole row — **of 122 Control Manager
controls in the corpus, exactly ONE carries a determined kind.** It is
Monitors' resolution list (`listBox`). Every one of the other 117
determined items came from the **DITL item-type byte**, which names
`btnCtrl`/`chkCtrl`/`radCtrl`/`statText`/`editText`/`iconItem`/`picItem`
directly; those never needed a CDEF at all. The 69 undetermined dialog
items are the one DITL type that carries no kind — `resCtrl`, whose row
says only that a `ControlRecord` exists.

Derive both tables from a corpus root with:

```sh
python3 - "$CORPUS" <<'PY'
import json, sys, collections; from pathlib import Path
R = Path(sys.argv[1]); seen = {}
for slug in sorted(p.name for p in R.iterdir() if p.is_dir()):
    f = R / slug / "ir.json"
    if not f.exists(): continue
    snap = json.load(open(f))["mirrorReadResult"]["value"]["snapshot"]
    for s in snap.get("surfaces", []): seen.setdefault(s.get("title", ""), s)
n = collections.Counter()
for s in seen.values():
    for it in s.get("items", []):
        n[(it.get("source"), it.get("knowledge"))] += 1
print(sorted(n.items()))
PY
```

### The premise was wrong, and the mechanism already exists

**`contrlDefProc` does not hold a resource ID.** `Controls.h` declares it
`Handle contrlDefProc;` at offset 24 and marks it *"not supported in
Carbon"* — there is no accessor. Recovering an ID from a Handle means
`GetResInfo`, which can only name a resource in the **caller's** chain,
and `GetControlKind` — the Control Manager's own answer — **is not
exported by CarbonLib 1.6**; the link fails (recorded already at
`now-guest-ppc/src/scene/scene_self.c`, and the reason
`now-guest-ppc/src/workshop/control_kind.c` remembers a `procID` at
creation time for NOW's own controls). So the ID is not sitting in the
record waiting to be read.

**But a complete classifier already ships, and it is better than the one
the plan imagined.** `ext/src/now_semantic.c :: classify()` calls
`GetControlData(control, kControlEntireControl, kControlKindTag, …)` —
the Appearance Manager's public tag — from inside the target process's
own context, via the resident's jGNE patch. It yields the full kind for
fourteen control families, and its `signature != kControlKindSignatureApple`
branch **is** the standard-versus-custom split, decided authoritatively
rather than inferred: a non-Apple signature returns
`kNowPeekSemanticControlCustom` / `StatusUnsupportedCustom`.

So row 2's class was wrong. It read `readable (defProc)`; the working
evidence is `kControlKindTag`, and no resource ID participates.

### Why 121 of 122 came back unknown anyway

Not a missing capability — **a starved one**. The plane was armed and
serving during the capture (`capabilities: 15`, `requested: 7`,
`active: 7` in every `manifest.json`, bit 1 being `CapTree`). It
classified one control across nine panels because of the transport:

- `contract/peek_table.h` carries a **single** `NowPeekSemanticCell
  semantic;` — one request per scene, for one control.
- Control classification is the **lowest-priority** claimant on that
  cell: `offer(10, …ControlClass)` in `semantic_client.c` loses to
  `offer(20, …ListCells)` and `offer(30, …SystemMenu)`, and list facts
  expire far sooner than class facts, so the cheap request preempts the
  important one on a duty cycle.
- Only the **front** process may spend the cell, so background panels can
  never be filled in.

Date & Time's window carries 21 controls and was front for one scene.
Best case it could have classified one of twenty-one.

**This shrinks slice 6 and moves it.** The control half is not a drawing
problem and does not need op replay; it needs a batched or multi-control
request op and a priority that reflects what the answer is worth. What
remains genuinely custom is bounded by the `UnsupportedCustom` branch —
and nobody has measured how large that is, because the classifier has
been asked 1/122 times.

### What was added here, and what it is not

`Scene.Semantics.definition` (`system` / `application` / `indeterminate`,
IR v2 additive) now carries a **resident-free** answer to the same split,
read straight from the walk: the System file's CDEFs carry `sysheap` and
load once into the system heap where every process shares them, while an
application's own CDEF loads into its own partition — and `axwalk`
already knows both bounds (`GetProcessInformation` and `LMGetSysZone`).
So the zone the `contrlDefProc` handle sits in separates the two for the
cost of a compare, with no CDEF ever dereferenced.

It is **deliberately weaker than a kind** and must never be promoted into
one: `system` says a documented answer exists somewhere, not that this is
a push button. Its value is that it has **no per-scene budget** — it
classifies every control in one walk, where the resident manages one —
and that it still answers when no resident is installed at all.

`indeterminate` is expected to be non-empty and is diagnostic: the
classic Control Manager keeps a variation code per control, and if it
rides in this field's high byte the raw longword lands in neither zone
and lands there. Nothing is masked on a guess, because a 24-bit mask on a
32-bit-clean machine would turn a layout question into a confidently
wrong histogram. `axdefproc_test` pins that case.

### The histogram is OWED

**Not measured.** The recorded corpus predates this field, so it carries
no `definition` for any of the 190, and the resident's own verdict exists
for 1 of 122. Producing it needs one live guest scene with a
`definition`-bearing build; no VM was stood up for this measurement (the
cold boot cannot complete unattended today). Until then the honest
statement is: **the 190 splits 121/69 by source, and how it splits by
definition origin is unknown.**

## One panel, both sides, 2026-08-05

The aggregate above is easy to nod at. This is the same finding on a single
window, captured in one moment, and it is the shape every row here takes.

**What the machine drew** (guest framebuffer): `8/ 5/2026`, `4:22:39 AM`,
"The time zone has not been specified.", "Time server: Apple Americas/…",
"Clock has not been synchronized.", an On/Off radio pair, two checkboxes,
five push buttons, engraved group boxes. A completely ordinary control panel.

**What the IR carried for that window**: 41 items, and

- **every single one has `text: null`.** Not one field value crossed. The
  date and the time — the entire point of the panel — are absent.
- **27 of the 29 inspected have no determined kind.** The On/Off radios are
  `UNKNOWN`, so nothing tells a renderer to draw a radio.
- several titles are garbage bytes (`\x17p`, `\uf8ffC`, `\x13Ï`).

Labels and button titles DO cross. So the Mirror has enough to draw a
plausible-looking panel and nothing to draw a correct one, which is exactly
the failure mode "the controls rendered" was coined for.

A note on method, because it is easy to get wrong: comparing the guest
framebuffer against itself proves nothing — of course the Mac looks right,
it is the Mac. The only useful comparison is the framebuffer against what
the IR carries, because the IR is what the Mirror draws from. That is what
the three-way capture exists for.

## Three claims of mine the corpus falsified

Recorded because being wrong in a stated direction is the useful half.

- **"`knowledge`/`completeness` exist but are unused, so honest emission is
  the cheapest fix in the arc."** False. The producer already emits
  `knowledge: unknown` and `role: unknown` for all 190 undetermined items.
  The honesty is there; the *coverage* is not, and there is no cheap fix.
- **"the standard CDEF's resource ID sits in the control record and is
  documented, so reading it is a lookup rather than an inference"**
  ([the 010 plan](plans/2026-08-05-010-feat-closing-the-headless-mirror-plan.md)
  § B). False twice over. The field is a `Handle`, not an ID, and the
  Control Manager's own `GetControlKind` is absent from CarbonLib 1.6 —
  so there is no lookup. And the split it was meant to produce was
  already obtainable, more precisely, by a mechanism that had shipped:
  the resident's `kControlKindTag` read. The plan sized slice 6 against a
  capability gap that does not exist; the real gap is one request cell.
- **"6 of 54 items carry an addressable ref"**
  ([mirror-mcp-parity.md](mirror-mcp-parity.md)), measured against NOW's own
  Workshop window and written as a general finding. Foreign panels do far
  better — Date & Time 41/41, VGA Display 33/33, Keyboard 36/37. The ref gap
  is **specific to NOW observing itself**, plus dialog items generally. The
  parity ledger's row is corrected accordingly.

## What this corpus is not

- **Captures are cumulative.** Panels were opened and left open, so a later
  capture's scene contains the earlier panels. Per-window rows above are
  de-duplicated by title; the per-capture totals in `mirror-corpus ledger`
  are not, and should not be read as one panel's cost.
- **`items ir/guest` compares unlike things.** The IR count includes dialog
  items; the harness count is Control Manager controls only. Use it to spot
  order-of-magnitude divergence, never as a diff.
- **No memory-discovery pass has run.** Row 3 is the one that needs it, and
  it is exactly the "does a structure exist here at all" question the QEMU
  oracle is for — the answer decides between a walk and an honest refusal.
- **Not metal-verified.** One emulated G4, one moment each.
