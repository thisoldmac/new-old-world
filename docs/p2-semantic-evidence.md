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

## The envelope changed: a second cell for batched classification (2026-08-05)

The row above bounds control classification at "one exact-control
validation and one resource/definition classification. **No control-list
walk and no nested resolver.**" That bound was written to keep a
system-wide event filter cheap, and it did — but it was priced against
the wrong thing, and a measurement showed it.

Of 122 Control Manager controls in the ten-panel corpus, **exactly one
carried a determined kind**. The classifier was never the problem. The
transport was: one cell answers one question per scene, control
classification was its lowest-priority claimant, and only the front
process could spend it. A class fact lives ~128 scenes; a list fact
expires every ~4. So the cheap, long-lived, *prerequisite* fact lost the
cell permanently to the expensive, short-lived one that depends on it —
a list request cannot even be formed until its control is known to be a
list box.

**Why a batch is not a bounds increase.** Serving one class request
already walks up to 64 controls (`control_below`) to prove the requested
control is live and in the window, then discards the walk and classifies
one. The batch keeps that single walk and classifies up to 32 of the
controls it already enumerated. Per window the cost goes from 32 walks
plus 32 classifications to **one** walk plus 32 classifications. The
resolver's own bound — at most 32 classifications, at most 32 copied text
bytes each — is the bound already granted to the list-cell and menu-row
resolvers. Per fact, the cost falls.

What genuinely grows: the filter may now examine **two** pending requests
per armed pass rather than one, because the batch is a second cell with
its own lease. That is the deliberate cost, and it is what removes the
competition that starved the plane — the two cells no longer bid for one
lease. Worst-case resolver work per pass is two bounded resolvers, each
already envelope-approved.

**Why a second cell rather than a wider one.** `semantic` is not at the
table's tail; `act_v2` and `event_block` follow it and a static assert
pins `act_v2` to `semantic`'s end. Widening the record or cell would move
both and break an older reader silently — the same reason `act_v2` was
itself appended rather than grown. The batch cell is therefore accretive,
at the tail, gated by length plus its own format word. A resident that
predates it is shorter, and the application falls back to the
single-control op with no loss of correctness.

**Identity is echoed, never inferred.** Each 48-byte record carries the
exact `ControlRef` it describes. A walk ordinal would have required both
sides to derive the same traversal order, and would have attached a role
to the wrong control — silently — the day they diverged. The guard
refuses a reply that names one control twice, because the join is by
control word alone.

Bounds unchanged: at most 32 records per reply, at most 32 text bytes per
record, requests expire after 120 ticks, and the same publish-last
generation discipline and echoed-identity recheck apply to both cells.
A window with more controls than one reply carries is drained by
successive requests from `request_start`; `response_total_count` reports
how many the walk found in all.

Status: native-tested (the resolver, the guard, and the application-side
policy), PPC cross-build green, and the resolver's one-walk property and
the guard's duplicate refusal were both watched fail under mutation. **The
68K extension half has not been built** — no m68k toolchain is installed
on the machine this was written on, so `scripts/build-guests` skips `ext`
entirely. It adds no new Toolbox symbol, so the flat-INIT link surface is
unchanged, but that is an argument and not a build. Nothing here is
metal-verified.

## Frozen envelope

The paragraph below describes v1/v2's single cell and remains true of it;
the section above states what the second cell adds and what it costs.

P2 is one single-consumer cell. Format v2 keeps the v1 fixed layout while
giving a control-class record a typed Control Manager kind and an optional
bounded displayed value. It carries one request and at most 32
fixed 48-byte records (1536 bytes) per committed response. The filter examines
at most one pending request per event pass, and a resolver performs at most
32 item/cell operations and copies at most 1024 payload bytes. Requests
expire after 120 ticks; a response is usable only when its publish-last
generation is nonzero and even, two reads of that generation agree, the
writer/owner epoch still matches, the target A5 and every applicable object
identity echo the request, and the response age is no greater than 120 ticks.

The cell has no application-name or resource-ID guess path. Its operations are
exact control classification, exact standard-list cells, and exact system-menu
rows. Each
resolver is a separate entry point and may only fill
records of its own kind. Overflow is `truncated`, unfamiliar definitions are
`unsupported-custom`, invalid handles are `invalid`, a changed identity is
`wrong-target`, and an expired request/reply is `stale`. P1 remains useful
when P2 is absent, disabled, or refuses a request.

## Implementation checkpoint

As of 2026-08-03 the appended cell, portable exact-target request validation,
and application-side committed copy are implemented and native-tested. The
tests mutate stale/wrong identity, partial publication, overflow, record-kind
classification, clipped-text completeness, and freshness. That ABI-only
checkpoint did not advertise P2; the bounded partial implementation below now
does. Date & Time and the Apple menu are still not considered resolved merely
because the ABI and standard-list slice can represent their facts.

The bounded resolver policy and 68K adapter prove exact window/control
membership through the live Window Manager root and a 64-entry iterative
Appearance control hierarchy walk. A live 2026-08-04 sweep then showed why the
v1 classifier was too narrow: it asked every control for a list-box LDEF, so
ordinary standard controls and genuinely private controls both collapsed to
`unsupported-custom`; it also rejected Set Time Zone's public ListHandle
solely because its drawing LDEF was nonzero.

Format v2 instead reads the public `kControlKindTag` in the target process,
accepts only Apple-owned kinds, and maps list boxes, clocks, groups, text,
buttons, choices, popups, scroll bars, data browsers, user panes, image wells,
and other system controls into compact shared kinds. Clock and text controls
may return bounded values through their public data tags. List traversal
requires an Apple list-box kind and a valid public
`kControlListBoxListHandleTag`; the drawing LDEF is no longer treated as proof
that the List Manager record is private. Unknown signatures still refuse
explicitly. Native fixtures cover a Date & Time-shaped list, typed/value
classification, custom refusal, overflow, and an 18-row Finder Apple menu.

The system-menu adapter is blocked at the flat-INIT ABI boundary. Universal
Interfaces declares `AcquireRootMenu`, `GetMenuItemHierarchicalMenu`, and
`ReleaseMenu`, but the actual `--mac-flat` Retro68 link reports unresolved
CarbonLib/CFM symbols for all three. The same is true of
`IsMenuItemEnabled`; the adapter can derive ordinary menu enable flags from
validated Menu Manager data, but it cannot reach the system-owned root child
behind Mac OS 9's empty Apple shell. An undocumented trap selector or an
unproven Mixed Mode bridge is not an acceptable resident dependency. The
adapter therefore reports an empty exact shell as `unsupported`. P2 is
advertised as a partial plane because the exact standard-list and ordinary
nonempty-menu paths are real; support remains a per-operation result.

The scene collector copies one prior committed response, joins only an exact
identity match, and publishes at most one cache miss for the next target event
pass. The walk now offers every live control, not only DITL resource controls,
so Sherlock's ordinary window controls reach P2. Its bounded cross-scene
policy retains two terminal menus, 64 compact control-class facts for 128
scenes, and four separate bounded list facts, resetting on writer-owner epoch
change or scene regression. The split prevents 35-control windows from either
thrashing an eight-entry cache or multiplying the 32-record list payload by
every control. A list fact retains every
bounded row/column/text/selection record plus the true total count; it does not
collapse the response to one selected string. Terminal
menu results suppress only that exact menu; standard classification advances
to list cells only for a typed list box, and a completed list advances to the
next control. Unknown custom controls remain visible with an unsupported
placeholder; typed data browsers, user panes, image wells, and other
not-yet-decoded system controls render a bounded unavailable placeholder rather
than a blank shell. An unsupported empty system shell gains a disabled
placeholder row instead of becoming an empty menu. P1-only output remains
intact when P2 is off. Resolving
the root-menu ABI boundary is still prerequisite to Apple-menu acceptance and
direct Date & Time/Apple-menu proof.

The scene IR carries those records as `semantic.listCells[]`, preserving the
List Manager's 1-based row and 0-based column, plus `listTotalCount`. A result
is complete only when status is `ok`, every record says its text is complete,
and the bounded record count equals the total. Otherwise the retained prefix is
explicitly partial and presentation-only. Mirror groups the reported cells by
row and column inside the real control rectangle; it does not invent missing
rows. When an older guest supplies only the selected value, the existing
recessed partial placeholder remains the honest fallback.

This v2 checkpoint passes the native semantic/scene tests, the focused Mirror
renderer tests, and real Retro68 PPC, 68K, and flat-INIT cross-builds. The new
Sherlock placeholder regression guard was watched fail under mutation and pass
after restoration. It is not emulator-verified until the rebuilt extension is
cold-loaded and Date & Time, Set Time Zone, Sherlock, and Key Caps are driven
through the Mirror against paired guest captures.

The cold-load sweep did not verify that hypothesis. Set Time Zone remained a
bitmap-unavailable region, and Sherlock's latest settled content generation
contained only its final CopyBits geometry. A read-only `NWpt` sample showed
the single semantic request repeatedly naming a background Finder control
while Date & Time was front; its last completed response was an older
`UnsupportedCustom` Date & Time base control, not the list. The extension has
therefore not yet produced live list cells, and the public kind path remains
unverified. The renderer now treats unavailable CopyBits destinations as a
background annotation and suppresses an unknown DITL resource shell once P2
has typed the same control; both guards were mutation-watched. Those changes
preserve structured evidence when it exists, but the UX rows remain red until
P2 settles the front modal's exact list request and returns its data.

The next bounded producer experiment is staged but not resident. When
`kControlKindTag` is absent or non-Apple, the extension now asks the exact
control for the public `kControlListBoxListHandleTag`. Only `noErr`, the exact
handle width, and a non-null result classify the control as a list; Apple-owned
non-list kinds are refused before this fallback and a custom control that
declines the tag remains `UnsupportedCustom`. The ordinary Apple list path is
unchanged. This uses no private `contrlData`, resource ID, or emulator-only
state. The native semantic slice and real flat-INIT/68K cross-build pass, and
removing the fallback made its source guard fail under mutation. A clean cold
reboot and direct Mirror/guest comparison are still required.
