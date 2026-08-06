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
`mirror/host/MirrorKit/Sources/MirrorKitUI/Resources/`, 914 of them
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

Its default `--out` is exactly where the renderer looks in a working
checkout, so **"run the extractor" is the whole recovery procedure**.
Anyone with their own image can produce their own pack; nobody has to
be given Apple's bitmaps to build or run this.

## Where the renderer looks

`MirrorKitUI/AssetPack.swift` resolves the pack once, at run time, in
this order:

| # | Source | Notes |
|---|---|---|
| 1 | `$NOW_MIRROR_ASSETS` | An explicit directory. Wins over everything. `NOW_MIRROR_ASSETS=none` forces the absent path — see below. |
| 2 | `~/Lab/Assets/now-mirror-assets/pack-*/Resources` | The documented store, newest `pack-` first, beside the qcow2 images. A path on a desk rather than a fact about the software, which is why it is not first. |
| 3 | the checkout's own `Resources/` | `tools/extract-assets-offline`'s default output. For a developer who has just run it and is building from the same tree. |
| — | absent | A first-class state. Not an error, and not silent. |

A directory only counts as a pack if it holds `manifest.json`, which
the extractor writes last — so a killed extraction does not resolve as
a present pack with most of its art missing.

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
- The live mirror shows `AssetPack.bannerText` above its status line
  for as long as the pack is absent. A picture of another machine drawn
  from art that machine does not own is a claim, and an unmarked claim
  is the problem. The banner is deliberately **not** in `SceneView`:
  the render screenshots must stay pixel-comparable.
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
- **The pack is in git in four other places**, none of them touched
  here, and all of them the same question:

  | Path | Files | Size |
  |---|---|---|
  | `mirror/assets/platinum-pack/` | 385 | 1.9 MB |
  | `mirror/.claude/worktrees/*/host/MirrorKit/Sources/MirrorKitUI/Resources/` | ×5 copies | part of 25 MB |
  | `mirror/.claude/worktrees/*/assets/platinum-pack/` | ×5 copies | part of 25 MB |

  The five vendored `mirror/.claude/worktrees/` trees are 3,789 tracked
  files and 25 MB — whole checkouts of another project's agent
  worktrees, carried in by `vendor: Mirror whole as a subproject`. They
  are a larger and separate decision than the pack, and they hold five
  more copies of the same Apple bitmaps.

## The reference copy

The pack that was removed from the index was verified file-for-file,
by sha256, against a copy taken first:

    ~/Lab/Assets/now-mirror-assets/pack-2026-08-06/Resources/
    ~/Lab/Assets/now-mirror-assets/pack-2026-08-06.sha256   (1,154 lines)

1,154 files, 0 missing, 0 mismatched, 0 extra. Nothing left git that
does not demonstrably exist somewhere durable with hashes.
