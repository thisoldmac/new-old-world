# NOW Web Bridge provenance

This is a NOW-owned graduation of the TimBotTu browser bridge, not a runtime
dependency on TimBotTu.

The first NOW implementation was derived on 2026-08-10 from:

- TimBotTu repository revision `d32cd4ea0d42bf5422379d7620389e3523ab8b18`,
  especially `web/proxy/tbtweb/` and `docs/browser-bridge.md`;
- the separately preserved 68K Web worktree revision
  `b08374f0c5b66e096eadc30430611c361e975db0`, especially
  `proxy/tbtweb/{profile,blocks,emit,paginate,htmlparse,handlers}.py` and
  `docs/spec.md`.

The NOW implementation keeps the proven design rather than source-copying the
old package wholesale: named browser-cost profiles, one semantic block tree,
browser-dialect emitters, bounded pagination, handler fallback, gateway and
HTTP proxy request forms, and an AI plan that may only reorder original
blocks.

The 361-URL collection manifest and frozen held-out captures remain evaluation
inputs in the preserved 68K worktree. They are not copied into the product or
asserted redistributable here.

The optional model at `~/Lab/Assets/tbtweb/layout-lfm-v1` is likewise not part
of this source tree. NOW accepts an explicitly configured plan command, checks
its output against `now-web-layout-plan/1`, and falls back deterministically.
Packaging the model requires a model card, base-model and training-data
provenance, redistribution review, version and checksum.

