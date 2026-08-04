# Mirror state engine

**Status:** pure reducer, first host shadow slice, render enrichment, evidence
export, and production/oracle isolation are built and focused-tested. Typed
producer completion, native cutover, direct-input parity, guest build, VM
staging, and metal proof remain open.

The Mirror is a client of a guest-authoritative replica. A scene is an
observation to reduce, not a replacement document to install wholesale. This
distinction is the guard against the repeated failure mode in which a
background application's temporarily unreadable tree erased windows, menus,
or content that the guest had already proved.

## Authority and identity

`MirrorGuestSession` is the outer isolation boundary. Reconnecting the same
named machine creates a successor incarnation; observations from another
session are rejected rather than merged. Within a session,
`MirrorProcessIdentity` uses the guest's process incarnation and
`MirrorWindowIdentity` adds the guest's window incarnation. Display names,
titles, PSNs, z-order occurrences, pointers by themselves, and act refs are
not entity keys.

Opaque act refs remain capability leases. A durable entity can survive a
refetch while its act ref changes, but no durable identity authorizes an act
without a current ref and complete applicable coverage.

## Reconciliation rule

The pure entry point is
`MirrorReplicaReducer.reduce(_:previous:)`. It rejects a different session or
a non-increasing scene sequence. For each typed collection claim:

| coverage | missing member | state |
|---|---:|---|
| fresh `complete` for the exact scope/owner | yes | tombstone |
| `partial`, `retracted`, `failed`, `stale`, `unavailable`, or absent | yes | retain expected-stale, force non-frontmost and non-actionable |
| any status | no | update the observed entity; actionability still requires the applicable complete claim and a current capability |

Process census and every enumerated process's window collection must all be
complete in one accepted scene before `baseComplete` becomes true. Process
activation authority remains separate from window-membership authority: an
incomplete window walk does not make a complete Process Manager row unknown,
but it does make window acts in that affected collection inert.

IR v1 rows remain displayable but never enter the durable entity maps and
cannot make the base complete, delete state, or authorize mutation.

## Progressive content

Optional structured content is independent of window membership. When a new
scene reports the same process/window incarnation and unchanged geometry, the
reducer retains compatible display ops, Finder items, dialog items, and text
that the structural scene did not refresh. A geometry change invalidates those
coordinate-bearing contributions. Pixel islands are not made load-bearing by
this rule; raw bitmap transport remains deferred.

The remaining host integration must replace this compatibility rule with
producer-specific content epochs and generations where those exist. A torn,
overwritten, or partial content drain may never replace the last settled
display.

## Host shadow boundary

`MirrorStateEngineRegistry` owns exactly one engine for one `GuestKey`, which
already includes the connection-session UUID. A successor connection therefore
gets a successor replica instead of inheriting state or capabilities under the
same human-readable Mac name. Each accepted engine projection is retained in a
bounded 32-snapshot, 15-minute store, and shadow comparison keeps a bounded
diagnostic list without patching either projection.

`NOWMirrorSource` pins its guest when the Mirror starts. Structural scene polls
are sent to that exact session even if the host's active picker later changes;
an addressed scene response is accepted only from the same key. There remains
one conservative host-wide pending scene slot, and a second caller is refused
rather than overwriting the first callback. This is coalescing, not yet the
final per-session observation scheduler.

The visible scene is still the C26 legacy path, including Apple-menu continuity
and its current content join. Every decoded structural scene is also reduced by
the shadow engine and compared with the scene the legacy path displays. Shadow
state never authorizes an action. While the pinned Mac is not the active Mac,
the Mirror may continue its addressed structural observations but pauses the
legacy active-only content and action paths. A gesture receives a named refusal
until the person selects that exact Mac. This prevents cross-guest mutation;
the later operation broker must replace the limitation with session-addressed
dispatch rather than weakening the check.

QuickDraw and Finder results now enter the shadow engine as same-sequence
enrichments after the structural observation is accepted. The enrichment
reducer may update only display ops, Finder items, dialog/text contributions,
and desktop items for an exact process/window incarnation with unchanged
geometry. It cannot change membership, coverage, actionability, structure, or
sequence. A result from an older sequence, a different identity, or different
geometry is ignored. A semantic no-op publishes nothing.

Published projections carry separate `sceneGeneration` and
`contentGeneration` counters. A transport-only scene sequence does not advance
the structural generation; a real accepted enrichment advances only content.
This gives the evidence stability sandwich values that can remain stable across
ordinary polls instead of treating cadence as change.

The QuickDraw producer's own `displayEpoch` and `generation` also govern
replacement after ring loss. A resync or nonzero overwritten-byte count clears
only the incomplete accumulator, not the last settled display. Records from
the damaged epoch/generation remain ineligible; a strictly newer guest-authored
epoch or generation starts the replacement, which publishes only after its
bounded pages are complete. Thus an overwritten Workshop repaint is visible as
expected-stale retained content rather than an invented empty window.

`MirrorEvidenceExporter` writes a Mirror PNG and the full decoded engine state
with one snapshot identity, guest/session, sequence, semantic digest, base
completeness, and both generations. The native window captures its own AppKit
content; the exporter refuses before writing anything when the visible legacy
scene differs from the engine projection or when the snapshot changes during
capture. Guest/QMP capture, input provenance, operations, settlement, and logs
remain independent required gate members; this exporter cannot green a row by
itself.

Stopping the Mirror releases the long-lived content claim only when the pinned
session is still active. A delayed release callback cannot clear a newly
started binding. If the picker has already moved, the source reports that it
could not perform the active-only release and relies on the other short leases
to expire honestly.

## Operations

`MirrorOperationReducer` keeps queued intent separate from canonical guest
state. Dispatch advances an operation only to `dispatched`. Later complete,
same-session evidence may confirm its typed postcondition. Missing-window and
missing-process postconditions require complete parent coverage; a partial
absence proves nothing. Timeout stays eligible for a later
`confirmedAfterTimeout`; refusal and session change are terminal.

The host-side FIFO, capability revalidation, journal bounds, and native UI
feedback are not implemented by the pure reducer. They belong to the shadow
engine and cutover units and must use these operation records rather than
inventing a parallel settlement model.

## Digest

Each accepted replica publishes a semantic digest over canonical entity order,
guest-authored fields, structured content, coverage, freshness, and
actionability. It excludes observation sequence, receive time, snapshot ID,
and operation/UI transient state. Thus the same semantic state at a later poll
has the same digest, while a changed label, geometry, content contribution,
coverage, or actionability changes it. The stability sandwich and MCP wait path
must use this same digest.

## Verification and limits

Focused reducer tests cover incomplete retention, complete scoped deletion,
process deletion, duplicate titles, v1 read-only projection, session and
sequence isolation, acquisition barrier, compatible content retention and
geometry invalidation, semantic digest behavior, dispatch-only settlement,
late confirmation, and terminal refusal/session change. The deletion guard was
mutation-watched by treating any process coverage claim as complete; the
expected-stale test failed immediately because the background application was
deleted.

The whole historical MirrorKit fixture suite currently has an unrelated known
version-expectation failure: its seven v1 golden scenes are rebuilt with the
current v2 stamp and compared against bodies stamped v1. Focused state-engine
tests pass; the full package is not green and must not be reported as such.

Open before visible cutover:

- exact guest-minted Finder-item and application-visibility capabilities;
- typed producer coverage beyond census/windows/menubar, especially Finder
  enrichment, content epochs, and global layer order;
- bounded tombstone/snapshot/journal retention tied to pending operations;
- a per-session observation scheduler beyond the conservative global pending
  slot, complete shadow parity, and content/evidence integration;
- guest-authored content epochs/generations and typed Finder/content coverage;
- native FIFO and direct keyboard/mouse acceptance campaign;
- guest cross-build, staged VM update, and clean saved shutdown.

## Development oracle boundary

`MirrorOracleKit` is a separate SwiftPM product containing `QmpClient`, the
QMP-capable dispatcher, and the legacy live controller that composes stale
windows. `MirrorApp` and oracle-facing tests opt into it. The production NOW
Host depends only on `MirrorKit` and `MirrorKitUI`; neither contains those
files, and the built Host binary contains none of the QMP handshake or
dispatcher markers. Host tests derive the package edge from the manifests and
source layout so moving either executable client back into a production target
fails the ordinary suite.

The vocabulary boundary is also explicit. `MirrorTarget` contains only the
guest wire and machine identity. Core `MirrorAction` and `ActionPlanes` name a
platform-neutral positioned input-device capability, and fail closed when a
driver lacks one. The development executable passes its optional socket only
to `MirrorOracleKit`; the production target cannot discover or configure it.
A source guard rejects QMP vocabulary in the two production model files and
was watched fail with a mutation sentinel before being restored.

This separation does not authorize QMP mutation in the new architecture. The
legacy `MirrorApp` retains that adapter only as isolated development tooling.
NOW's acceptance campaign uses QMP read-only for explicit-socket framebuffer
capture and identity checks; native Mirror keyboard/mouse input remains the
only mutation provenance eligible for a green row.

`tools/shot` no longer scans `run/*` or chooses a newest socket. It requires an
explicit QMP socket and a `now-mirror-oracle-identity/v1` artifact, verifies
the QEMU VM name, and emits a `now-mirror-oracle-capture/v1` sidecar carrying
the asserted guest, connection session, guest build, VM, socket, frame path,
and capture time. The UX evidence gate joins that artifact to the engine state
guest/session and the manifest's build/VM/socket. A mismatched or absent
identity is evidence refusal, not a warning.
