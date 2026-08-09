# Standalone Mirror archive

This directory preserves the complete standalone Mirror project imported into
NOW during the July-August 2026 integration campaign: its host executable,
QMP oracle, guest and resident components, tests, experiments, raw research,
asset copy, and original project instructions.

It is historical evidence, not production code. Nothing under this directory
is built, linked, staged, deployed, or searched for runtime assets by NOW.

The production pieces extracted from it are owned elsewhere:

- `now-host/Packages/MirrorKit/` owns the active `MirrorKit` and `MirrorKitUI`
  libraries and their tests.
- `tools/asset-pack/` owns the reusable resource-fork parsers.
- `tools/extract-assets-offline` owns the supported read-only extraction route
  into an external, configurable asset-pack store.
- `docs/research/mirror/` and the live Mirror documentation retain conclusions
  that remain useful after this source tree stopped being active.

The tracked `assets/platinum-pack/` is retained solely to preserve the imported
project exactly enough to audit its lineage. Those Apple-owned bytes must not
be copied into production packages, shipped artifacts, or new repositories.

Archive boundary: 2026-08-09, after production extraction commits `09cb22be`
and `39db2814`. The pre-consolidation refs
`archive/mirror-premerge-code-d979c6ee` and
`archive/mirror-premerge-plan-d3d61867` preserve the source state before this
move.
