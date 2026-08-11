# The Platinum asset pack: a dependency, not repository content

**Date:** 2026-08-06 · **Status:** decided and implemented

The mirror draws OS 9 with OS 9's own art — the System file's icons and
cursors, each application's `icl8`, the desktop `ppat`, and the NFNT
bitmap strikes that make text pixel-honest rather than merely similar.
That art is **Apple's bitmaps**. The rule it inherits from
[mirror-assets.md](mirror-assets.md) is unchanged:

> the extracted pack stays private, is never published, never ships as
> an artifact, never goes upstream, and is never shared externally.

On 2026-08-06 the pack was committed to this repository — 1,154 files
and 5.0 MB under
`now-host/Packages/MirrorKit/Sources/MirrorKitUI/Resources/`, 914 of them
per-application icons. It arrived as a **side effect of wiring the pack
up**, not as a decision: the offline extractor's default output
directory happened to be inside a SwiftPM target, and SwiftPM needs
resources in the source tree.

**The decision, taken deliberately afterwards: the pack is a dependency
of proper rendering, not repository content.** It lives outside git.

## Why this is workable at all

Because the pack is **regenerable**. `tools/extract-assets-offline`
rebuilds it byte-identically from a local OS 9 disk image, with no VM
in the loop — it converts the qcow2 with `qemu-img`, walks the Apple
Partition Map, carves the embedded HFS+ volume out of the HFS wrapper,
and reads resource forks as ordinary files. The route and its one
genuinely surprising step are in
[asset-extraction-offline.md](asset-extraction-offline.md).

Its default output is a new timestamped pack beneath the configurable
external store, so **"run the extractor" is the whole recovery procedure**.
Set `NOW_MIRROR_ASSET_STORE` or pass `--store` to choose another store; use
`--out` only for a deliberate one-off destination.

That sentence was not true when it was written, and 2026-08-07 made it
true. The offline extractor produced no `fonts/` at all, so a recovered
pack had every icon and no text: `FontBook` names `chicago-12` and
`geneva-9/10/12`, got nil for each, and drew a fallback face with
different metrics — a pack that looks complete in a directory listing
and is wrong on screen. It now extracts the `NFNT` strikes from
`System Folder:Fonts:` (9 sheets; the 8 the store's pack already held
come out **byte-identical** to the wire route's) and carries each
suitcase's `sfnt` verbatim as `fonts/ttf/<face>.ttf`. **Charcoal, the
system font, has no bitmap strike on the image to extract** — it is
TrueType-only, and Mac OS rasterises it at run time. Since 2026-08-07 so
does the extractor: 16 strikes at ppem 9–24, one per row of Apple's own
`hdmx` device-metrics table, which is where their advances come from.
Before that the render substituted Chicago and every menu, title, button
and group-box label was drawn in the wrong face. See
[charcoal-strike.md](charcoal-strike.md) for the measured deltas and
[asset-extraction-offline.md](asset-extraction-offline.md) for the
route.
Anyone with their own image can produce their own pack; nobody has to
be given Apple's bitmaps to build or run this.

## One asset domain, three acquisition adapters

The pack contract is the domain boundary. Acquisition route is provenance,
not a different kind of asset or a licence to invent a second manifest:

| Adapter | Source | Current state |
|---|---|---|
| **Stopped-volume** | Read-only HFS/HFS+ image and resource forks through `tools/extract-assets-offline` | Implemented; fastest deterministic bulk/reference route. |
| **Connected guest** | Read-only fork-bearing `file.*` pulls from the machine NOW is connected to | Pull transport and the earlier wire extraction are proven; product integration remains the work in [plan 017](plans/2026-08-06-017-feat-assets-from-the-connected-guest-plan.md) and [plan 021](plans/2026-08-07-021-feat-asset-packs-plan.md). |
| **Visual oracle derivation** | Receipt-bound SheepShaver/QEMU framebuffer regions declared by an explicit visual profile | Implemented for bounded, static marks and framebuffer proof; it is not a general screenshot-atlas path. |

All three publish into the same external versioned pack shape and obey the
same rules: immutable source identities, per-asset provenance, atomic
`manifest.json` publication last, private/non-shipping Apple bytes, and loud
absence. The connected route should add a machine/session acquisition receipt,
not a second runtime cache format; its progressive system/fonts/appearance/
applications domains remain the cost model already designed in plan 021.

The renderer is a consumer, not a fourth acquisition route. MirrorKit composes
semantic scenes locally from pack assets plus procedural furniture. Native
framebuffers never enter the NOW semantic protocol, and a pixel comparison is
evidence about a render rather than data used by that render.

## Where the renderer looks

`MirrorKitUI/AssetPack.swift` resolves the pack once, at run time, in
this order:

| # | Source | Notes |
|---|---|---|
| 1 | `$NOW_MIRROR_ASSETS` | An explicit directory. Wins over everything. `NOW_MIRROR_ASSETS=none` forces the absent path — see below. |
| 2 | the persisted selection among valid packs in `$NOW_MIRROR_ASSET_STORE` | The host's **Asset Packs** picker stores only the discovered pack identity. It never compiles one extracted pack's name or absolute path into the app. The environment defaults to `~/Lab/Assets/now-mirror-assets`. |
| 3 | newest valid `pack-*/Resources` in that store | The default when no selection exists, or when the selected pack was removed. This targets the existing emulator extraction without hard-coding which extraction that is. |
| — | absent | A first-class state. Not an error, and not silent. |

A directory only counts as a pack if it holds `manifest.json`, which
the extractor writes last — so a killed extraction does not resolve as
a present pack with most of its art missing.

The picker is deliberately a minimal scaffold for custom pack selection,
not the extraction UI itself. It enumerates only complete packs from the
documented store, persists the chosen directory identity, and offers an
Automatic choice that returns to newest-valid-pack resolution. An explicit
`NOW_MIRROR_ASSETS` still owns the process and disables the picker. Because
decoded art and the pack root are cached for the process lifetime, a picker
change applies on the next host launch; the UI says so rather than pretending
an already-rendering process changed provenance underneath its caches.

**The pack is never bundled into the build.** `Package.swift` declares
no resources for `MirrorKitUI` at all. That is not an oversight: a
`.copy("Resources/…")` declaration makes the build fail outright on a
checkout with no pack, which is precisely the state a fresh clone is
in, and it would also mean a shipped `.app` carrying Apple's bitmaps —
the thing the rule above forbids.

## Absent is loud

A missing dependency that looks like working software is the failure
this project keeps paying for. Without a pack:

- `AssetPack` writes a named warning to stderr the first time anything
  asks, saying what is missing, what the drawing is instead, and both
  ways to fix it.
- `AssetPack.status` is readable as `.absent(searched:)`, carrying the
  list of places it looked — so the message can say where to put it.
- The Mirror inspector's **Asset Packs** card names the selected pack or the
  absent state. Pack management belongs beside the other development controls;
  it is not painted over the Macintosh surface itself.
- `IconAtlas`, `BitmapFont` and `DesktopPattern` return nil, which is
  the path they already took for "this application has no extracted
  icon" — so callers draw their procedural fallbacks through code that
  was always exercised, not a new branch nobody runs.

## What happens to the gates

Some tests need the pack's actual bytes: that a reported creator
signature reaches that application's own icon, that the 16×16 art is
its own drawing rather than the 32×32 resampled, that the real
`creator__type` join lands. They cannot be deleted and they cannot pass
on a machine with no pack. So:

- Without a pack they **skip by name**, printing the whole banner. A
  skip is visible in the run; a test quietly rewritten to pass is not.
- With a pack, `scripts/test-host` and `scripts/test-mirrorkit` set
  `NOW_REQUIRE_ASSET_PACK=1` automatically, which turns those skips
  back into failures. A gate that quietly declines to run is how this
  kind of hole opens.
- **Both gates run their suite twice**: once as configured, once with
  `NOW_MIRROR_ASSETS=none`. The build is cached, so it costs the test
  run only. A suite that passes only on a machine which happens to have
  the dependency says nothing about a fresh clone.

That second pass earned its keep immediately. It caught
`IslandRenderTests.testAProvenCheckboxIsNotRenderedAsAPushButton`,
which samples a pixel 100pt into a control: with the pack that point is
past the end of "Reveal system files" in Geneva, and without it the
fallback face is wider, the label reaches the sample, and the test
reports a pill border that is not there. Nobody would have found that
by reading it.

## What is NOT settled

- **History still holds the pack.** This removed it from HEAD and
  gitignored it — the reversible move. The 5.0 MB is still in every
  clone's object store, and taking it out means rewriting history,
  which is a different and much heavier decision (every worktree and
  branch off this repository has to be rebased or re-cut). That is
  Michelle's call, another day. Nothing here forecloses it.
- **The pack is still in git in one other place**, untouched here:

  | Path | Files | Size |
  |---|---|---|
  | `mirror/assets/platinum-pack/` | 385 | 1.9 MB |

  It held five more copies until 2026-08-07, inside the vendored
  `mirror/.claude/worktrees/*` trees — whole checkouts of another
  project's agent worktrees, carried in by `vendor: Mirror whole as a
  subproject`. Those were removed from the index (and `.claude/worktrees/`
  gitignored at any depth) as a separate decision from the pack;
  [open-issues.md](open-issues.md) records what was checked first. As
  with the pack, history still holds them.

## The reference copy

The pack that was removed from the index was verified file-for-file,
by sha256, against a copy taken first:

    ~/Lab/Assets/now-mirror-assets/pack-2026-08-06/Resources/
    ~/Lab/Assets/now-mirror-assets/pack-2026-08-06.sha256   (1,154 lines)

1,154 files, 0 missing, 0 mismatched, 0 extra. Nothing left git that
does not demonstrably exist somewhere durable with hashes.

## What the store holds now

`AssetPack` resolves `pack-*` newest-name-first, so the latest is the one
a build sees. Each has its own `.sha256` beside it.

| pack | files | what changed |
|---|---|---|
| `pack-2026-08-06` | 1,154 | the first offline extraction; no fonts |
| `pack-2026-08-07` | 1,203 | the `NFNT` strikes and the three `.ttf`s |
| `pack-2026-08-07b` | 1,242 | **Charcoal**, 16 strikes rasterised from its own `sfnt` at ppem 9–24 ([charcoal-strike.md](charcoal-strike.md)) |

None of them is in git, and regenerating any of them is still one
command.

### It has been superseded — read the newest `pack-`, not this one

    ~/Lab/Assets/now-mirror-assets/pack-2026-08-07/Resources/
    ~/Lab/Assets/now-mirror-assets/pack-2026-08-07.sha256   (1,210 lines)

Regenerated 2026-08-07 by plan 018's slice 5, from the same stage image
by the same read-only route. The 56-file difference is entirely the two
asset classes that run added — **fonts** (9 NFNT sheets, 3 verbatim
TrueType faces) and the **desktop** (44 named Appearance patterns, the
current picture, and the `desktop` manifest key). Everything the older
pack held came out byte-identical except two app icons whose names
differ only in case (`ddsk__dimg` → `ddsk__dImg`), which a
case-insensitive volume had folded together.

`AssetPack` resolves the newest `pack-` directory first, so a machine
with both picks this one up with no configuration. **The older list is
kept rather than replaced** — it is the receipt for the removal from
git, and a receipt for one thing is not a description of another.
