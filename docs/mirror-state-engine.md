# Mirror state engine

**Status:** pure reducer built and focused-tested; host shadow integration,
native cutover, direct-input proof, and metal proof remain open.

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
- one per-session poll owner, shadow parity, content/evidence integration;
- native FIFO and direct keyboard/mouse acceptance campaign;
- guest cross-build, staged VM update, and clean saved shutdown.
