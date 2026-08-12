<!-- now-doc-provenance: generated reviewed=false -->

# The capture fixtures: 720,000 lines, and where they went

**Date:** 2026-08-06 · **Status:** measured and acted on

One day's work put **741,514 insertions across 1,164 files** into this
repository. **720,258 of them were `.json`** — 97%. Everything else the
session produced, Swift and C and docs and tools together, was about
20,000 lines. The six worst files were all capture fixtures:

| file | insertions |
|---|---|
| `qdtrace-drain-sweep-date-and-time.json` | 109,860 |
| `qdtrace-drain-sweep-key-caps.json` | 105,199 |
| `qdtrace-drain-sweep-memory.json` | 81,362 |
| `qdtrace-drain-sweep-appearance.json` | 80,808 |
| `qdtrace-drain-sweep-general-controls.json` | 72,905 |
| `qdtrace-drain-sweep-sound.json` | 61,036 |

`now-host/Tests/HostTests/Fixtures` was 9.5 MB.

## What these are, and why deleting them was never on the table

Each is a **live QuickDraw drain off a mac99 guest**: every op an
application drew, in order, with the ports and offscreen worlds it drew
them into. They are this project's best gates — the two halves meeting
on real bytes, which is the failure class
[`two-halves-never-met-in-a-test`](../AGENTS.md) exists for — and they
are not reproducible on demand: each one is a particular build, on a
particular VM, on a particular day.

## What was actually wrong: 94% of it was whitespace

`tools/fidelity-sweep.py` wrote `json.dump(fixture, handle, indent=1)`.
A 3,509-op capture therefore spent **61,036 lines** saying what fits on
3,509. The line count was not measuring capture; it was measuring
formatting.

`tools/fixture-store compact` re-emits each drain with the envelope
readable and **one compact op per line**. One op per line rather than
one giant line on purpose: a 1 MB single line is not greppable, not
diffable and not reviewable, and a fixture nobody can read is a fixture
nobody will notice going wrong. The line count now follows the op
count, which is the honest measure.

    lines   697,828 -> 39,715   (94%)
    bytes 9,613,685 -> 6,462,330 (33%)

It is lossless by construction, and the tool refuses to write unless it
is: `json.load` of the before and the after must compare equal. Scene
fixtures are not drains and are left byte-identical rather than made
bigger. The sweep now normalises through the same tool, so the next
capture lands in the format instead of re-earning the problem, and
`scripts/test-host` runs `compact --check` so it cannot drift back.

## The trimming question, and the measurement that settled it

The instinct was to trim each fixture to the minimal slice its test
needs, mechanically, with the raw captures moved to a store. Three
things were true about that and the third was only discoverable by
measuring.

**First, trimming to assertions is the wrong rule.** A fixture cut down
to what its `XCTAssert` lines touch stops being a capture and becomes a
mock — and a mock cannot exhibit the defect it was recorded for. It is
also wrong about what these fixtures are *for*: `testEverySweepCapture-
Composes` is the weak half of the sweep gate. The strong half is the
render survey (`NOW_RENDER_DIR`), which draws each capture as a whole
panel for a person to judge. "The ops the test needs" for
`qdtrace-drain-sweep-sound` is the entire panel, three times over.

**Second, there is a rule that is provable rather than lucky.** An op
can only affect what the mirror composes if it draws into a port that
reaches the window under test — directly, or through a chain of
`blitsrc` joins into a world that is later blitted in. Ports that never
reach it are dead by construction. `tools/fixture-store prune` computes
exactly that, reading the window address out of the Swift suite rather
than restating it.

**Third — and this is the answer — there is nothing to prune.**

    39,017 ops in, 38,983 out.  0.09%.

| capture | distinct ports | reachable | unreachable ops |
|---|---|---|---|
| `sweep-date-and-time` | 2 | 2 | 0 |
| `sweep-sound` | 3 | 3 | 0 |
| `sweep-key-caps` | 1 | 1 | 0 |
| `sweep-finder` | 2 | 1 | 17 |

The sweep arms per application, so the ring buffer holds only that
application's drawing. The captures were already tight. The bulk is not
junk — it is **repaint passes**: the same panel drawn two or three
times, because `displayEpoch` advances once per ARM and never per pass.
That flattening is itself the finding `qdtrace-drain-sweep-sound`
exists to pin (`testFlattenedPassesPutAWindowBlitOverTheSoundList`), so
collapsing the passes would delete the gate, not shrink it.

`prune` stays in the tool as a **guard**, not a cleanup. A capture taken
with more of the machine awake would not be this tight, and this says so
before it lands.

## So the fixtures stay in git, and that is deliberate

Moving them to a local store with a manifest was the other option, and
its cost is the one that decides it: **a fresh clone could then no
longer run the gate.** AGENTS.md is unambiguous that a gate a
contributor cannot run is worthless, and a gate that reads green having
skipped is the defect class this project has been bitten by most. 6.5 MB
of the best tests in the repository is a good trade for that not being
true.

What is committed instead is `Fixtures/MANIFEST.json`: path, sha256,
byte count, op count and the identifying block for every fixture. It is
derived — `tools/fixture-store manifest --apply`, never hand-edited —
and `scripts/test-host` checks it. Two things it makes true:

- **A capture without provenance fails the gate.** A drain must carry
  its `provenance` block (build hash, VM, run, guest); a scene fixture
  must at least carry `source` and `capturedAt`. Neither, and the gate
  stops naming the file.
- **Nine fixtures are flagged `provenanceIsWeak`, honestly.** The scene
  fixtures say `source: peek` and a unix timestamp. That names a capture
  *shape*, not a build or a VM — a thinner claim than the drains make,
  and now visible as one rather than counted as provenance.

## Proving the compaction did not blunt anything

A reformat is only as trustworthy as the gates that read it, and a test
nobody has watched fail proves nothing. Each of these reintroduced the
condition a gate exists to catch, on the compacted fixtures, and each
gate named it:

| mutation | what fired |
|---|---|
| Add one `verb: 3` (invert) op to `sweep-finder-selected` | `testTheFindersSelectionNeverReachesTheCapture`: *"the Finder's selection now REACHES the capture (1 invert ops) — the baseline has moved"* |
| Rename the selected item's label `System Folder` → `Sysbem Folder` | same gate: *"the selected item's own label stopped crossing"* |
| Drop the window-spanning ops after the last list row in `sweep-sound` | `testFlattenedPassesPutAWindowBlitOverTheSoundList`: *"the three-pass capture no longer paints over its list"* |
| Remove one op from `sweep-memory` without adjusting `records` | `recordCountAgrees`: *"qdtrace-drain-sweep-memory decodes whole"* |

Every mutation was reverted. The last is the one that covers the
reformat directly: if compaction had lost a single op, that is where it
would have shown, on every drain, on the first run.

The tool's own guards were verified the same way — re-indenting one
fixture failed `compact --check`, and deleting one `provenance` block
failed `manifest --check`.
