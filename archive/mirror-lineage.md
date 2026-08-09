# Mirror lineage

NOW's Mirror began as a copied standalone project. That import was valuable:
it supplied the semantic scene model, renderer, QuickDraw and GWorld research,
Finder experiments, A5-world investigation, input-driving work, fixtures, and
the evidence that shaped NOW's resident extension.

The standalone product boundary did not survive integration. NOW now owns the
guest wire, resident component, host lifecycle, semantic renderer, Finder
experiments, and agent surface directly. Keeping a second host app, second
guest, QMP oracle, and old build system active would make it unclear which
implementation was authoritative.

The lineage is therefore represented by three explicit homes:

| Material | Current home | Status |
|---|---|---|
| Production semantic model and renderer | `now-host/Packages/MirrorKit/` | Active and gated |
| Reusable asset parsers and offline extractor | `tools/asset-pack/`, `tools/extract-assets-offline` | Active tooling |
| Standalone app, oracle, guest, experiments, raw docs, imported asset bytes | `archive/mirror-standalone-2026-08-09/` | Historical only |

Git history remains the detailed provenance. The archive is intentionally
excluded from production source census and self-revert gates, but it remains
searchable when a future investigation needs the original measurement or
implementation.
