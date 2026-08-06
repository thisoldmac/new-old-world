# Scene deltas

**Date:** 2026-08-06 · **Authority:** `contract/asyncapi.yaml` (`SceneRequest.since`,
`SceneBegin.digest`/`delta`/`baseline`/`wholeBytes`, `SceneSame`). Where this
file and the contract disagree, the contract is right; where either and the
code disagree, the code is right and one of these is a defect.

Slice 5 of
[013, a guest that notices instead of polling](plans/2026-08-06-013-feat-a-guest-that-notices-instead-of-polling-plan.md).

## Why the wire became the cost

Three numbers, all measured on 2026-08-06 on a clean clone with current
builds:

| what | number | where from |
|---|---|---|
| the guest's whole scene walk | **3 – 8.5 ms** | `meta.phases`, microsecond-measured |
| the host's `transfer` clock for the same scene | **111 – 710 ms** | `Session.finishScene`, `transferMs` |
| the document | **15 KB idle, 26 – 28 KB with windows and a menu bar** | real scenes off the emulated G4 |
| the encoder's sizing pass | **589 µs** | `meta.phases.us.encode` |

So several times a second the guest serialised the entire machine and shipped
~27 KB describing a Macintosh that mostly had not changed, and the serialiser
was not the expense — the bytes were.

**Why this is only now affordable, which is the design's keystone.** A delta
requires the guest to diff against what it last sent, and diffing requires
walking. Walking cost ~950 ms until the control cache landed the same night
(plan 013 § "the fix taken"). At 3–8 ms the guest can walk, diff, and send only
what moved. Before that, deltas would have been all of the cost and none of the
benefit — which is exactly what plan 013 § D said, and why this is slice 5 and
not slice 1.

## The three answers

A `scene.request` has always had one answer: a transfer carrying a whole IR
document. It now has three, and **which one arrives is the guest's choice, not
a negotiation.** A host that quotes a baseline must be able to accept any of
them; there is no "delta declined" outcome to handle.

| the host asked | the machine | the answer | costs |
|---|---|---|---|
| no `since` | anything | whole document | scene.begin + bulk + scene.end |
| `since` matches, nothing moved | unchanged | **`scene.same`** | one control frame, no transfer |
| `since` matches, something moved | changed | scene.begin `delta:true` + bulk + scene.end | the changed entities only |
| `since` matches, but `full:true` | anything | whole document | as before |
| `since` does not match the guest's baseline | anything | whole document | as before |
| 65th consecutive delta | anything | whole document | as before |
| the delta would be no smaller | anything | whole document | as before |

The last three rows are why a consumer never needs a recovery protocol: **the
recovery path is the ordinary path.** An asker whose baseline the guest cannot
serve is served the truth instead, in the same round trip it already spent.

## The unit is a whole entity

Nothing smaller than one of these crosses the wire:

- one `apps[]` row
- one `processes[]` row
- one `windows[]` element — **including** its `controls`, `dialogItems`, `text`
- the whole `menubar`

`meta` (coverage, errors, phases) and the scalar head (`version`, `seq`,
`capturedAt`, `source`, `screen`) are always restated whole.

This is the property everything else rests on:

> **A delta can lose an entity. It can never corrupt one.**

A window that changed arrives byte-for-byte as it would in a whole document. A
window that did not is named and not sent. There is no field-level patching to
get wrong, no ordering question inside an entity, and no meaning to assign to a
half-applied one.

It also means the fidelity of a delta-carried entity is *exactly* the fidelity
of a whole-scene entity — the same bytes through the same decoder. Whatever a
delta can do to the mirror, it does at the granularity of membership, identity
and order. Which is the granularity the digest covers.

## The document

`SceneDelta`, on the bulk lane, announced by `scene.begin` with `delta:true`:

```json
{
  "version": 2,
  "kind": "delta",
  "seq": 412,
  "baseline": "9f1c2ad0",
  "capturedAt": 1786000123.4,
  "source": "peek",
  "screen": {"w": 1024, "h": 768},
  "apps":      [{"k":"process-1a2b3c4d"}, {"k":"process-55667788","v":{ ...whole row... }}],
  "processes": [{"k":"process-1a2b3c4d"}, {"k":"process-55667788","v":{ ... }}],
  "menubar":   {"same": true},
  "windows":   [{"k":"process-55667788/window-0034ab10","v":{ ...whole window... }},
                {"k":"process-1a2b3c4d/window-00120040"}],
  "meta": { "coverage": [ ... ], "errors": [ ... ], "phases": { ... } }
}
```

- An entry with **`k` alone** means *"the entity you already hold under this
  key, unchanged, in this position"*.
- An entry with **`k` and `v`** means *"replace it, or add it; here it is
  whole"*.
- A key you hold that appears in **no entry** is absent from this scene.
- `menubar` is `{"same":true}`, or `{"v": {...}}`, or `{"absent":true}`.

**Order is carried, not inferred.** Two reasons, and the first is the one that
would bite: the consumer has to rebuild the producer's *exact bytes*, so it
must know exactly where each entity goes. The second is that scene order is
meaning — the front process is first.

### Keys

| entity | key |
|---|---|
| app / process | `incarnation` (`process-<8 hex>`) |
| window | `incarnation` (`process-<8 hex>/window-<8 hex>`) |
| menubar | not keyed; there is one |

**An entity with no incarnation is never delta-eligible** and is always sent
whole. This is not a compromise — `MirrorReplicaReducer` already skips
incarnation-less rows before they reach its durable maps, so a row the reducer
will not key is a row a delta must not key either. The two rules agree because
they are the same rule.

## Deletion, and why no new coverage vocabulary was needed

A deletion in a delta is *an absence from the ordered array*, and it carries **no
authority of its own.**

The consumer reconstructs the whole document and hands it to the same reducer a
whole scene goes to. That reducer applies the rule `mirror/docs/IR-V2.md`
already states normatively: a member missing from the collection is deleted only
under a fresh `complete` claim for its exact scope and owner, and is otherwise
retained expected-stale and inert. Because `meta.coverage` is restated in full
on every delta, and because the reconstruction *is* a whole document, **a delta
is structurally incapable of becoming a second, contradictory way to remove
state.**

This is why `meta.coverage[]` gained no new status. The brief for this slice
anticipated extending that vocabulary — `unchanged`, say — and the honest
finding is that the extension is unnecessary *given this shape*, and would have
been necessary given a different one. A design that patched the consumer's
replica directly would have had to say what authority an unmentioned member has,
and would then have had two rules for deletion in two places. Reconstructing the
document instead means there is one rule, in one place, unchanged, and
`MirrorReplicaReducer` and `MirrorStateEngine` did not have to learn that deltas
exist.

## The digest, and how drift is detected

`scene.begin` carries `digest`: FNV-1a/32, eight lowercase hex digits, over the
concatenation **in this fixed order** of the document's own emitted bytes for

```
screen · source · apps · processes · menubar · windows · meta.coverage · meta.errors
```

each being the exact byte range of that value as it appears in the document —
nothing re-serialised, nothing canonicalised. When `menubar` is absent the
single byte `-` stands in its place.

**Excluded, deliberately:** `seq`, `capturedAt`, `latencyMs`, `walkMs`,
`sendMs`, `meta.phases`. Those move on every walk of a machine that did not
change, so a digest including them could never say "nothing changed" — and
saying that is the entire point. The exclusion is also what keeps `capturedAt`
meaning what `SceneBegin` already said it means: *same scene, newer moment*.

### The detection claim, stated precisely

After applying a delta the consumer holds a reconstructed body. It hashes that
body. If the number equals `digest`, the consumer holds **byte for byte the
document the guest would have sent whole**. Not "probably in sync" — the same
bytes.

That is a strictly stronger statement than a per-entity checksum scheme would
give, and it is cheap on both sides because neither side ever re-serialises:
the guest hashes as it encodes (a tap on the encoder's sink, no extra pass), and
the consumer hashes the byte slices it received and the byte slices it kept.

### And the baseline is named by digest, not by sequence

`scene.request.since` quotes the **digest** of the last scene the host *fully
applied*, never a sequence number.

A sequence number says which document the producer *thinks* the consumer has. A
digest says which one it *actually holds*. Those two differ in exactly one
situation — a consumer that mis-applied a delta — which is precisely the failure
a delta stream must survive. **A scheme that cannot tell them apart cannot
detect its own drift.**

The consequence is that drift is not merely detectable, it is *self-healing*: a
host that has drifted quotes a `since` no guest baseline matches, and gets a
whole document by the ordinary path, with no extra round trip and no repair
logic.

### What a consumer does when it cannot apply a delta

Fixed, and there is only one answer:

1. **Discard the reconstruction.** Do not publish, do not partially apply, do
   not repair in place.
2. **Publish nothing** from it — the previously published state stands, and it
   is honest, because it is the last state that was proven.
3. **Send the next `scene.request` with no `since`.**
4. **Say so** on the host's diagnostic surface, with the baseline and the two
   digests. A resync that happens silently is a resync nobody will ever tune.

The cases that reach step 1: digest mismatch after reconstruction; a delta whose
`baseline` is not the `since` that was sent; a `k`-only entry naming a key the
consumer does not hold; a delta arriving when the consumer has no baseline; a
malformed delta document.

Note the third: a `k`-only entry for an unheld key is a *provable* producer or
transport fault, caught before any hashing, and it is the cheapest of these to
detect.

## The bounds

Three, each written because "unlikely" is not a guarantee:

- **A chain is at most 64 deltas.** The 65th answer is whole, whatever the host
  asked. An unbounded chain is a bet that no consumer will ever have a bug, and
  a product whose claim is a faithful mirror cannot take that bet.
- **A delta is sent only when it is smaller** than the whole document would have
  been. The guest knows both numbers before it must choose.
- **`full:true`** lets a host re-prove the mirror on its own schedule.

## What this does not do

- **It does not make the walk cheaper.** Walk time is unchanged; the guest still
  walks the whole machine every poll. Plan 013's slices 3 and 4 are about that,
  and this slice is not them.
- **It does not touch `MirrorReplicaReducer` or `MirrorStateEngine`.** Both were
  left exactly as they were, on purpose. See "Deletion" above.
- **NOW-68K does not serve it**, because NOW-68K serves no scene at all — see
  [contract-coverage.md](contract-coverage.md). This is a declared asymmetry of
  the whole scene family, not a new one introduced here. The design is
  nevertheless sized for that machine: the guest's per-scene delta state is a
  key/hash table of a few kilobytes, the hash is 32-bit, and the encoder tap is
  one exclusive-or and one multiply per byte.

## Measurements

See [scene-delta-measurements.md](scene-delta-measurements.md) — bytes on the
wire and transfer milliseconds, idle and while driving, before and after, with
the build and port beside every number.
