<!-- now-doc-provenance: generated reviewed=false -->

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
of this source tree. The inspected local artifact is a 633 MB MLX four-bit
LFM2 causal model. Its weight checksum on 2026-08-10 was
`50269b5612c0da2919e5d8f88f1a056bdd0ba67582c2efd66bc7632aef98bb9b`.
The preserved training report identifies it as the iter-800
LFM2.5-1.2B-Instruct student trained on 295 accepted page-to-plan pairs and
measured over the frozen 52-page held-out set.

NOW can use that artifact through `nowweb.model_planner`, checks the resulting
order against `now-web-layout-plan/1`, restores any block the model omitted,
and falls back deterministically. The artifact's own README currently names
only MLX and text generation; it does not state the base-model license,
training-data redistribution terms, or a complete model card. Therefore this
change enables explicit local use but does not copy or ship the weights.
Packaging still requires those provenance and license answers plus a versioned
manifest and checksums for the tokenizer and configuration.
