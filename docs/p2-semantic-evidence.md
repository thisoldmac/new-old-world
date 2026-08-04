# P2 semantic-assist evidence and bounds

This is the R11 review gate for the resident semantic-assist plane. It is an
ABI input, not a list of desired UI features. A fact belongs in P2 only when
the existing P1 anchors plus New Old World's bounded normal-context memory
reader cannot prove it safely. P2 is an exact-target request/reply service;
it is not another tree builder.

The current structural walk already proves window and control geometry,
visibility, enablement, live control value/range/title, Dialog Manager item
kind/title/rect/default/focus, dialog TextEdit contents, and application-owned
packed menu titles/items/marks/commands. Those facts are explicitly rejected
from P2. Duplicating them resident-side would add a second authority without
adding evidence.

## Capability review

| Proposed fact | Why P1 plus normal-context reads are insufficient | Required in-context source | Fixed result bound | Resident work bound | Exact identity and freshness | Refusal/result |
| --- | --- | --- | --- | --- | --- | --- |
| Control definition/resource classification | A `ControlRecord` exposes handles, but a foreign reader cannot safely ask Resource Manager which CDEF/CNTL created a custom or resource control. Treating every DITL `resCtrl` as a popup is already known false for Date & Time. | The target context's Control and Resource Managers; exact `WindowPtr` plus `ControlHandle`. | One 48-byte fact; no variable payload. | One exact-control validation and one resource/definition classification. No control-list walk and no nested resolver. | Request names writer epoch, target A5, window, control, and the structural scene generation that supplied them. Reply echoes all five and commits last. | `unsupported-custom`, `invalid`, `wrong-target`, `stale`, or the exact standard/resource/custom class. Unknown CDEFs remain unknown. |
| Standard List Manager state and visible cells | A control's `contrlData` is definition-private. A foreign reader cannot safely assume it is a `ListHandle`, lock it, or call `LGetCell`/`LGetSelect`; geometry alone does not reveal Date & Time's city/list labels or selection. | List Manager in the target context, reached only after exact-control classification proves the standard list definition. | At most 32 records, each with at most 32 text bytes: 1536 response bytes. The true visible/selected count is returned separately. | At most 32 `LGetSelect`/`LGetCell` attempts and 1024 copied bytes. No scrolling, allocation, or cross-resolver call. | Same control identity tuple; each cell record also carries row/column. One reply generation covers the batch. | `truncated` when more than 32 cells or a cell exceeds 32 bytes; `unsupported-custom` for nonstandard LDEF/CDEF; `invalid`, `wrong-target`, or `stale` otherwise. A clipped string is never reported as complete. |
| Non-dialog TextEdit roots — **rejected/deferred** | A plain `WindowRecord` has no public TE root. Guessing an offset beyond it can interpret adjacent memory as a handle. Dialog text is already proven by the normal reader. No documented standard root or explicit registration exists in the current evidence. | None justified. | No P2 v1 operation or record. | None. | None. | Structurally unknown. A future explicit registration contract requires a new evidence review and an accretive operation. |
| System-owned menu rows (Apple/system menus) | P1 exposes the process `MenuList`, and the normal reader can parse application-owned menu bytes. System-populated Apple rows can instead be owned/resolved by Menu/Resource Manager state and may not be represented by the same application heap bytes. Geometry/title inference is not evidence. The existing Finder fixture has 16 Apple rows below its separator, so a 12-row envelope is known insufficient before the ABI is written. | Menu Manager in the target context; exact `MenuHandle` and menu ID already observed structurally. | At most 32 records with 32 text bytes each: 1536 response bytes. True item count returned separately. | At most 32 exact menu-item reads and 1024 copied bytes. No menu tracking, insertion, command dispatch, or other resolver. | Writer epoch, target A5, menu handle, menu ID, and structural scene generation are echoed. Reply commits last. | `truncated`, `unsupported`, `invalid`, `wrong-target`, or `stale`. A handle/ID mismatch is `wrong-target`, never a lookup by ID alone. |

## Frozen envelope

P2 v1 is one single-consumer cell. It carries one request and at most 32
fixed 48-byte records (1536 bytes) per committed response. The filter examines
at most one pending request per event pass, and a resolver performs at most
32 item/cell operations and copies at most 1024 payload bytes. Requests
expire after 120 ticks; a response is usable only when its publish-last
generation is nonzero and even, two reads of that generation agree, the
writer/owner epoch still matches, the target A5 and every applicable object
identity echo the request, and the response age is no greater than 120 ticks.

The cell has no generic `kind -> guess` path. Its operations are exact control
classification, exact standard-list cells, and exact system-menu rows. Each
resolver is a separate entry point and may only fill
records of its own kind. Overflow is `truncated`, unfamiliar definitions are
`unsupported-custom`, invalid handles are `invalid`, a changed identity is
`wrong-target`, and an expired request/reply is `stale`. P1 remains useful
when P2 is absent, disabled, or refuses a request.

## Implementation checkpoint

As of 2026-08-03 the appended cell, portable exact-target request validation,
and application-side committed copy are implemented and native-tested. The
tests mutate stale/wrong identity, partial publication, overflow, record-kind
classification, clipped-text completeness, and freshness. The 68K extension
deliberately does **not** advertise or arm P2 yet: its Toolbox resolvers and the
normal-context scene join are not implemented, so Date & Time and the Apple
menu are not considered resolved merely because the ABI can represent their
facts.

The next implementation must add three separate resident entry points, first
with invalid-handle and custom-definition fixtures: exact control
classification, exact standard-list cells, and exact system-menu rows. It must
then copy through `now_semantic_copy_response` and join only matching guest
facts into the existing structural scene. P1-only output must remain intact
when the extension refuses, truncates, or has P2 disabled.
