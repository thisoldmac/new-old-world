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
facts: semantic kind, advertised action, state, value, selection, focus,
defaultness, provenance, and completeness.

An element is actionable only when `knowledge` is `known`, `completeness` is
`complete`, an action is advertised, provenance is not
`presentation-inference`, and the guest supplied an addressable reference. The
host may draw an approximate fallback otherwise, but that fallback is
presentation only.

Structural Control Manager controls remain in `controls`. Dialog Manager items
remain in `dialogItems`, because static and edit text do not have Control
Manager identity and popup/edit acts do not share a button's execution path. A
renderer suppresses a structural control when a dialog item carries the same
reference, preventing one live dialog control from being drawn twice.

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
`icon`, `picture`, `userItem`, and `unknown`. The structural kinds let an
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
