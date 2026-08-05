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
| 2 | **62% of items have no determined kind.** Not a few stragglers: 190 of 308, including items with real titles (`Show:`, `Resolution`). A control whose kind is unknown cannot be drawn as the right widget, which is the Date & Time "radios drawn as push buttons" red at its source. | producer | readable (defProc) | corpus-wide | already honest — `knowledge: unknown`, `role: unknown` |
| 3 | **Extensions Manager's list is 24 `userItem`s.** The panel's whole purpose is a scrolling list of extensions; the IR carries no list at all. Whether these are List Manager lists behind a user item or fully custom drawing is **not yet known**, and that question decides whether row 1's fix reaches this panel. | producer | **needs discovery** | `extensions-manager/ir.json` | draws nothing; no false widget |
| 4 | **Fewer than half of dialog items are addressable** (75/186), against 96/122 for controls. An agent — and the act plane — can see items it cannot name. | producer | readable | corpus-wide | refuses by name (`now_mirror_drive`) |
| 5 | **Sound: 0 of 64 items addressable**, the worst window in the corpus, and 75 items truncated to 64. | producer | readable | `sound/ir.json` | refuses by name |
| 6 | **The harness reads window titles as binary garbage** — every window in every `guest.json` (`'\x192?\x1f!?…'`), where the IR has correct titles. The independent oracle is wrong here, not the thing it is checking. | client (oracle) | readable | corpus-wide | none — the oracle silently reports garbage |

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

## Two claims of mine the corpus falsified

Recorded because being wrong in a stated direction is the useful half.

- **"`knowledge`/`completeness` exist but are unused, so honest emission is
  the cheapest fix in the arc."** False. The producer already emits
  `knowledge: unknown` and `role: unknown` for all 190 undetermined items.
  The honesty is there; the *coverage* is not, and there is no cheap fix.
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
