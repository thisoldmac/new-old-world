# What Mirror actually contains, and what has crossed

**Date:** 2026-07-31 · **Status:** audit, current as of `main` today

Written after Michelle said *"make sure you're not cutting corners — there was a
lot of work done in mirror and its new home is gonna be New Old World."* She was
right to push twice. This is the honest accounting, done by enumerating both
repositories rather than by recalling what felt done.

**Roughly a fifth of Mirror has crossed.** The parts that crossed are real and
tested; the parts that have not are most of the product.

## The number that reframes it

`guest/app/src/mirrorverbs.c` is **5,386 lines serving 31 verbs.** The guest walk
port took the *parsers that file calls* — `axwalk`, `axmenu`, `axtext`, `axref`,
`axresolve`, `axbinding`, about 35 KB — and left the verb layer behind. That was
described at the time as "porting the archaeology", which was true and
incomplete: the archaeology is what the verbs *use*, not what they *are*.

## Verb surfaces, side by side

| | |
|---|---|
| **NOW's guest serves (22)** | `catsearch` `census` `clear` `front` `gestalt` `help` `launch` `ls` `mkdir` `mv` `ps` `put` `putstat` `quit` `reveal` `screenshot` `sw` `tail` `trash` `untrash` `vers` `vprobe` |
| **Mirror's guest serves (31)** | `activate` `apple_event` `axdo` `axsnap` `axtree` `capture` `click` `close` `ctlinvoke` `fetch` `handle` `hello` `journalprobe` `key` `launch` `list` `menugeom` `menuinvoke` `mouseloc` `observe` `ping` `portal` `portalselftest` `qdtrace` `quit` `script` `stat` `textget` `textset` `volumes` `winact` |
| **Literally shared today** | `launch`, `quit` |

They are two different products. NOW is remote control, files and census; Mirror
is a semantic mirror you can act through. So this is not "NOW is missing 21
verbs it should have had" — it is **the Mirror capability costs about 21 verbs
and two of them exist.**

## What has crossed

| Piece | Where it landed | State |
|---|---|---|
| `axwalk` / `axmenu` / `axtext` / `axref` / `axresolve` / `axbinding` | `now-guest-ppc/src/axwalk/` | ported, natively tested (first coverage this archaeology ever had) |
| `MirrorKit` + `MirrorKitUI` | `now-host/Sources/` | ported whole with both test targets and the golden fixtures |
| The IR contract | `contract/`, guest encoder, host decoder, adapter | NOW's own, IR v1-conformant |
| Oracle *answers* (five verdicts) | `peek_oracle.c` | reimplemented, then V3 added `CurApName` from upstream's |

**In flight as of this writing:** `portal` → the act plane (all five ops);
`qdpeek` → the content plane; the `GuestListener` scene caller.

## What has NOT crossed

### 1. The verb layer — the largest single gap

~21 verbs. `axtree` `axsnap` `axdo` `observe` `fetch` `handle` `ctlinvoke`
`menuinvoke` `menugeom` `mouseloc` `portal` `portalselftest` `qdtrace` `textget`
`textset` `winact` `volumes` `activate` `close` `apple_event` `journalprobe`.

The three the host's act rows require (`winact`, `textget`, `textset`) are in
flight. **The other eighteen are not scheduled.** `observe` and `handle` matter
disproportionately: they mint and resolve the element references every act verb
addresses, so nothing can be driven by identity without them.

### 2. The test harnesses — and these ARE Phase 3

`mirror/tests/` holds ~25 probe scripts against a live guest. `nohijack-probe.py`
is **50 KB** and is the harness that produced 18/20 → 0/19. Also
`textops-probe.py`, `ctlinvoke-probe.py`, `apple-event-probe.py`, `g1-probe.py`,
the `h2-*` folder-item set with its recorded trial results, `mirror-service-e2e.py`,
`drive-sequence.py`, `agent-session.py`.

**This is the most under-valued item in the list.** The roadmap's Phase 3 says
"validate against an emulator" as though the harness needs writing. It does not —
it exists, it has run, and its results are recorded. Porting these is
cheaper than authoring an emulator pass and gives directly comparable numbers.

### 3. Tooling

`tools/spin-up.sh`, `stage-agent.py`, `stage-mirror.py`, `stop-mirror.sh`, and
`extract-assets/`. NOW has its own deploy path, so these need judgement rather
than transcription — but `extract-assets` produced the Platinum assets
`MirrorKitUI` renders with, and `assets/` itself has not been examined.

### 4. Documents that are findings, not prose

`CONTROL-SURFACE.md` (18 KB), `FOLDER-ITEMS.md`, `JOURNALING.md` (16 KB),
`QUICKDRAW-CONTENT-PLANE.md`, `TIMBUKTU-QD-FINDINGS.md`, `TIMBUKTU-TEARDOWN.md`,
`ASSET-EXTRACTION.md`, `PROTOTYPE-NOTES.md`, `HANDOFF.md`, and `STATUS.md` at
**55 KB**. These carry measurements NOW will otherwise re-derive — which has
already happened twice today.

### 5. The rendered evidence

Nine PNGs of actual rendered scenes — GraphCalc, desktop icons, a pixel island, a
menu hover, the app switcher, folder items, volumes. They are the only record of
what "working" looks like, and the UX review has nothing to compare against
without them.

## The pattern this audit exists to stop

Twice today NOW re-derived something Mirror had already answered:

- **The menu-list layout.** M5 was declared blocked because `LMGetMenuList()`'s
  structure is in no header we have. `axmenu.c` had carried `6` / `6` / `14` all
  along.
- **The QuickDraw bottleneck question.** A from-scratch INIT (`qdprobe`) plus a
  reader were built to ask whether a 68K bottleneck can be called by PowerPC
  QuickDraw. `QDPEEK-SPEC.md` records **M0–M3 done, M4 emulator gate passed**, and
  answers it in the opposite direction from what the spike braced for: *Mixed Mode
  works with `NewQDxxxUPP` alone, no RoutineDescriptors.*

Both cost real effort and produced nothing upstream did not have. **The rule
going forward: check Mirror before deriving anything.** Its new home is this
repository, and everything in it was paid for once already.

## Completing the fold-in

Sequenced by what blocks what, not by size. Wave 1 is in flight; waves 2 and 3
are dispatched against this document.

### Wave 1 — in flight

| | |
|---|---|
| `portal` → the act plane | all five ops: `CONTROL_INVOKE`, `MENU_INVOKE`, `TEXT_GET`, `TEXT_SET`, `WINDOW_ACT` |
| `qdpeek` → the content plane | P3, charter-designated, M0–M3 done upstream with the M4 emulator gate passed |
| the `GuestListener` scene caller | the one missing piece of an otherwise complete scene path |

### Wave 2 — the keystone, and the thing that makes Phase 3 cheap

**2A — the reference layer: `observe`, `handle`, `axtree`, `axsnap`.**
Every act verb addresses an **opaque, observation-minted reference**, and
identity-not-position is upstream's hardest-won finding — 18/20 versus 0/20.
Without `observe` to mint references and `handle` to resolve one back to a live
`WindowPtr`/`ControlHandle`, the act plane has nothing to address and the scene
has no way to say *this* window. **This blocks the value of Wave 1**, which is
why it is first here rather than filed with the other verbs.

**2B — the probe harnesses.** `mirror/tests/`, ~25 scripts that drive a live
guest. This is Phase 3 of the roadmap, already written and already run. Porting
them is cheaper than authoring an emulator pass and yields numbers directly
comparable to upstream's. `nohijack-probe.py` alone is the 50 KB harness behind
18/20 → 0/19.

**2C — the recorded knowledge.** Ten documents and nine rendered PNGs. Cheap,
and it is the direct fix for the failure this audit exists to stop: NOW has twice
re-derived an answer Mirror already had. The renders are also the only thing a UX
review can compare against.

### Wave 3 — the rest of the verb surface

`volumes` `activate` `close` `menugeom` `mouseloc` `apple_event` `ctlinvoke`
`menuinvoke` `qdtrace` `portal` `portalselftest` `journalprobe` `fetch`, and
NOW-equivalent decisions for `capture` / `list` / `stat` / `script` / `key` /
`click` / `ping` / `hello` where NOW already has its own spelling.

Deliberately last: each is bounded, none blocks another, and several may not want
to cross at all once the act plane and the reference layer exist. **That is a
judgement to make with the ported code in front of us, not now** — the one
corner-cut this document forbids is deciding a verb is unnecessary before its
dependencies are in.

### The standing rule

**Check Mirror before deriving anything.** Its new home is this repository. If a
piece of work here begins with "we need to find out whether…", the first place to
look is upstream, and the second is upstream's docs.

## Corpus impact

`corpus_impact: none` — an audit of two checkouts, no new measurement. Every
number here is a file count or a line count taken today and reproducible by
running the same commands.
