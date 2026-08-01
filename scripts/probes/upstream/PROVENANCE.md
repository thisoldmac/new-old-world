# Upstream's recorded results — copied verbatim, never regenerated

These are **measurements taken on a real machine by `timbottu/mirror`**, copied
byte-for-byte out of `mirror/tests/` on 2026-07-31 as part of Wave 2B of
[../../../docs/mirror-foldin-inventory.md](../../../docs/mirror-foldin-inventory.md).

They are here for one reason: **a future NOW run has to be comparable to
them.** The harnesses in the parent directory preserve upstream's methodology
so that comparison is legitimate; these files are the other half of it.

## Do not

- **Do not regenerate them.** Nothing in this repository can produce these
  numbers today, and nothing should ever overwrite them. A NOW run writes its
  own file with `--json`, next to these, under its own name.
- **Do not edit them to fit.** If a NOW run disagrees, that disagreement is
  the finding.
- **Do not read them as claims about NOW.** Every row below was measured
  against Mirror's guest and Mirror's verb implementations. NOW's act plane is
  a different implementation of the same idea; agreement is corroboration, not
  the same measurement.

## What each file records

All five `p2-*.json` files come from one agent build:
`0.1a`, build `f1d81f34b688 2026-07-31T21:19:14Z`, git rev `2deb4ef2`,
`machineType 406`, with `portal {present:true, enabled:true}`,
scene planes `observe`/`axtree`, action planes `activate`/`click`/`key`/`axdo`.

| file | case | recorded |
|---|---|---|
| `h2-trials-result.json` | folder items, unscrolled | **20/20 hit** |
| `h2-trials-result.json` | folder items, scrolled | **20/20 hit** |
| `p2-nohijack.json` | text cross-fire | **0 hijacks / 20**, 20 chained, 0 dropped |
| `p2-ditem.json` | `ditem` text ops | n=20, 0 dropped; read reply 20, read correct 20, read-outside 20; write reply 20, **write actuated 20**, write-outside 20 |
| `p2-dialogte.json` | `dialogte` text ops | the same 20s across all six columns |
| `p2-handle.json` | `te` (TEHandle) text ops | the same 20s across all six columns |
| `p2-saveas.json` | Save As | n=8, 8 retitled, **8 on disk** |

`readOutside` / `writeOutside` are the second, independent read path — the
foreign-memory walk, from outside the target process. That those columns match
`readCorrect` / `writeActuated` exactly is the evidence that the verbs were
not reporting their own private copy of a string. It is why the ported
`textops-probe.py` insists on two paths agreeing, and it is the column a
careless port would drop.

`h2-trials-result.json` carries **per-trial records**, not just totals: each
names the item aimed at, the item the Finder said was selected, and the
position the click point was computed from. That is the richest recorded
result in the set and it is what makes `h2-items-probe.py` worth checking in
unrunnable.

## The 18/20 that is NOT in this directory

The headline number — **18 in 20** for the request that merely disarmed after
one use, against **0 in 20** for the variant that had to name its exact target
— is quoted in NOW's own contract (`contract/asyncapi.yaml`, the
`winact`/`textget`/`textset` preamble) and in upstream's prose. The `18/20`
run's own JSON was not among the files in `mirror/tests/`; the surviving
machine-readable artifact of that lane is `p2-nohijack.json`, which is the
**0-hijack side** measured after the design changed.

Said plainly because it would be easy to imply otherwise: **this directory
holds the "after", not the "before".** The before is a claim in prose that
this repository has now inherited and cannot yet reproduce — which is exactly
what `../nohijack-probe.py` exists to fix.

## corpus_impact

`corpus_impact: none` — nothing here is a new measurement. These are copies of
another repository's recorded runs, preserved unchanged, with their provenance
and their limits stated. The evidence level of every row is whatever it was
upstream; crossing a repository boundary does not raise it.
