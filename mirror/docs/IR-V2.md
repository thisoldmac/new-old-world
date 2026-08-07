# The scene IR, version 2

IR v2 makes semantic evidence explicit. It replaces v1's required `role`
guess with guest-authored facts that can remain unknown without becoming an
action. The scene remains data-driven: the guest reports state, the host
renders it, and mutations travel through normal guest contracts. No QEMU or
QMP facility is part of the implementation.

## Compatibility and the gate

The transfer envelope and body both carry major `2`. A consumer accepts the
envelope major before decoding the body, then requires the body major to match.
This build may decode v1 for differential display, but a v1 scene is approximate
and read-only: a v1 `role` never authorizes a mutation.

## Semantic evidence

`controls[].semantic` and `dialogItems[].semantic` carry independently optional
facts: semantic kind, advertised action, state, value, bounded list cells and
their true total count, text selection, focus, defaultness, provenance, and
completeness.

An element is actionable only when `knowledge` is `known`, `completeness` is
`complete`, an action is advertised, provenance is not
`presentation-inference`, and the guest supplied an addressable reference. The
host may draw an approximate fallback otherwise, but that fallback is
presentation only.

Structural Control Manager controls remain in `controls`. Dialog Manager items
remain in `dialogItems`, because static and edit text do not have Control
Manager identity and popup/edit acts do not share a button's execution path. A
renderer normally suppresses a structural control when a dialog item carries
the same reference, preventing one live dialog control from being drawn twice.
When that DITL row is only an unknown resource shell and P2 later proves the
same live ControlRecord's drawable semantics, the more specific guest fact
wins and the shell is suppressed instead. This is the Date & Time list case;
unconditional DITL precedence painted an unavailable hatch over real cells.

## Window widgets

`windows[].closeBox` and `windows[].zoomBox` are the WindowRecord's own
`goAwayFlag` and `spareFlag` — one byte each, beside `windowKind`. They say
which title-bar widgets the machine draws. `kind` cannot stand in for them:
Extensions Manager is `kind == 2` and has a zoom box, Memory is `kind == 2`
and has none.

Both are absent rather than false when the producer did not read the record.
Absent is unknown, not false, exactly as for semantics — a consumer that has
no answer falls back to what it did before rather than withholding a widget
from every producer that has not learned to send one. A consumer must not
draw a widget, or offer a hit target for one, on an absent-or-false `zoomBox`:
a click on a zoom box the machine does not draw lands in the racing stripes,
which the Window Manager reads as the start of a window drag.

There is no `growBox`. The WindowRecord carries no grow flag, and the
variation code in the high byte of `windowDefProc` is ambiguous without the
WDEF's resource id — `kWindowDocumentDefProcResID` 64 and
`kWindowDialogDefProcResID` 65 number their variants independently — which a
foreign walk cannot name from a Handle. That gap is stated, not guessed.

## Collection coverage and lifetime identity

IR v2 carries collection authority in `meta.coverage[]`. Each claim has a
machine-readable `scope`, optional process-incarnation `owner`, `status`, and
optional diagnostic `reason`. Status is one of `complete`, `partial`,
`retracted`, `failed`, `stale`, or `unavailable`.

Only a fresh `complete` claim authorizes a reducer to remove previously known
members that are absent from the new collection. Every other status retains
compatible same-session members as expected-stale and makes them
non-actionable. An empty array with complete coverage proves emptiness; an
empty or absent array under weaker coverage does not. `meta.errors` remains a
human diagnostic surface and must never be parsed to decide deletion.

`apps[].incarnation` and `processes[].incarnation` identify one Process Manager
lifetime as `process-<fingerprint>`. The fingerprint includes the PSN, creator,
launch tick, partition bounds, and process name. `windows[].incarnation`
combines that process incarnation with the exact WindowRecord address. It is
absent when the producer cannot prove that address. These are reducer keys,
not action capabilities: opaque `ref` values remain short-lived leases and are
revalidated on every mutation.

The deletion rule is normative:

| parent coverage | child absent | reducer result |
|---|---:|---|
| fresh `complete` for the exact scope and owner | yes | tombstone |
| `partial`, `retracted`, `failed`, `stale`, `unavailable`, or absent | yes | retain expected-stale and inert |
| any claim from another guest session | either | reject; never merge |
| no prior child and coverage is not complete | yes | remain unknown; invent nothing |

## Knowledge-state table

| State | JSON representation | Applies to | Decoder | Actionable | v1 mapping |
|---|---|---|---|---|---|
| Known | `knowledge="known"`, proven fields present, `completeness="complete"` | Element or semantic plane | Typed `Semantics` | Only with advertised action and ref | No equivalent; v1 role remains approximate |
| Unknown | `knowledge="unknown"`; unsupported facts absent | Element | Typed `Semantics` | No | Required or guessed role becomes unknown |
| Not reported | `semantic` or `dialogItems` key absent | Field or whole plane | Optional key | No | Existing absent-key behavior |
| Truncated | `knowledge="truncated"`, or plane retracted with `meta.errors` | Element or whole plane | Typed state plus error | No | v1 could only omit and annotate globally |
| Stale | `knowledge="stale"`; values may remain for display | Element | Typed state | No | v1 scene-level age only |

Absent booleans are unknown, not false. A dialog with no validated default item
omits `isDefault`; it does not mark every button false. A selection is a
half-open `{start,end}` byte range and appears only after validation against the
reported value.

## Initial vocabulary

Kinds are `pushButton`, `checkBox`, `radioButton`, `popupMenu`, `editText`,
`staticText`, `scrollBar`, `groupBox`, `progressIndicator`,
`disclosureTriangle`, `panel`, `placard`, `selectionBand`, `separator`,
`icon`, `picture`, `userItem`, `listBox`, and `unknown`. A P2 `listBox` may
carry `listCells[]` with `{row,column,text,selected}` and `listTotalCount`.
It is complete only when every guest cell reached the scene; a bounded prefix
remains explicitly partial and non-actionable while still rendering its real
rows. The structural kinds let an
application describe manually drawn layout as data: a renderer does not need
the guest framebuffer merely to reproduce a sidebar, header, divider, or
selection. `icon` and `picture` may carry geometry without bitmap content; the
host then draws an explicit bounded placeholder rather than either inventing
art or presenting an empty region as faithful.

Actions are `press`, `choose`, `edit`, and `scroll`. Advertising a capability
does not imply the host executor implements it; an unimplemented action is a
named refusal, never a fallback button press.

Initial provenance values are `guest-ditl`, `guest-control-manager`,
`guest-workshop-model`, and `presentation-inference`.
`guest-workshop-model` means the application that owns the custom-drawn surface
reported its own semantic layout. It is guest state, not a host reconstruction
and not captured pixels. New provenance strings are additive; consumers branch
on evidence fields, not on a closed provenance list.

## Bounds and failure

The guest validates the DialogRecord, item-list handle, item count, every
variable-length item record, referenced handles, and text selection before
emitting a fact. A malformed record retracts the dialog-item plane and adds a
specific `meta.errors` entry. A bounded prefix is never emitted as complete. An
unreadable control definition remains unknown and unactionable.
