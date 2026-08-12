---
page_id: dev-workflow-docs-gates
title: Documentation and gates
description: Author, render, verify, and keep the public documentation synchronized with code.
doc_type: how-to
audience: developer
lifecycle: current
authority: [mkdocs.yml, tools/docs-gate, tools/docs-provenance, tools/product-features, docs/module-manifest.yaml, product/features.yaml]
source_dependencies: [mkdocs.yml, tools/docs-gate, tools/docs-provenance, tools/product-features, tools/docs-placeholders, tools/docs-contract-projector, scripts/test-docs, docs/module-manifest.yaml, product/features.yaml, docs/hooks/provenance.py, docs/hooks/release_features.py, docs/developer-guide/index.md, docs/agent-guide/index.md]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Documentation and gates

The public site uses MkDocs Material and the Diátaxis page types: tutorial, how-to, reference, and explanation. Each curated page declares its type, audience, lifecycle, authorities, source dependencies, media IDs, and verification date in YAML front matter.

## Choose the owning audience before writing

- `docs/user-guide/` explains how a person installs, operates, understands, and
  evaluates the product.
- `docs/developer-guide/` is for developers reading the code. It owns
  architecture, code tracing, debugging rationale, implementation workflows,
  and technical reference.
- `docs/agent-guide/` is for coding agents. It owns imperative repository
  protocol, scope control, platform/skill routing, evidence rules, and handoff.

Do not publish the same technical explanation in both the developer and agent
guides. Put it in the developer guide; link to it from the agent page and
add only the operational instruction the agent needs. Likewise, branch and
checkpoint protocol does not belong in the codebase tour. The docs gate
checks folder/audience ownership; review still checks that the prose actually
serves its declared reader.

## Install the pinned toolchain

```sh
uv venv .docs-venv
uv pip install --python .docs-venv/bin/python -r docs/requirements.txt
```

## Author and preview

```sh
scripts/docs-serve
```

Use Mermaid for source-controlled diagrams and provide a text equivalent immediately after each diagram. Screenshot slots are listed in `docs/assets/screenshots/manifest.yaml`; regenerate deterministic stubs with `tools/docs-placeholders` and replace them in place with the same final dimensions.

## Preserve authorship and review provenance

Every tracked Markdown file carries exactly one provenance comment. Existing
material begins as generated and pending human review:

```markdown
<!-- now-doc-provenance: generated reviewed=false -->
```

When a person substantially rewrites the page, remove only the `generated`
presence marker. Set `reviewed=true` only after a human has reviewed the
result; authorship and review are separate claims. The other valid states are
therefore `reviewed=false`, `reviewed=true`, and
`generated reviewed=true`. Never write `generated=false` or add a second
authorship category.

Published pages render the marker as a small provenance notice. Repository
records and `docs/local/` scratch notes are not published, but tracked records
still carry the source comment. Generated projections and pages with a
`derived-doc` block must retain `generated`; their generators or rederive
tools own their contents.

```sh
tools/docs-provenance check
```

Before a corpus-wide provenance or rewrite pass, create the planned annotated
`archive/docs-pre-rewrite-YYYY-MM-DD` tag on the exact integration commit. It
is an archive point, not a release.

## Bind documentation to release features

`product/features.yaml` declares the active release profile, stable feature
IDs, runtime flag keys and defaults, and the NOW Extension capability inventory.
Add `feature_ids` to bind a curated page to that authority. Included alpha
features are the default and render no availability banner; optional or
excluded features render a notice. Use `<!-- release-feature-table -->` or
`<!-- extension-feature-matrix -->` only on the owning pages; the MkDocs hook
renders them from the catalog.

The catalog is product authority. `tools/product-features` projects it into
bounded host and PowerPC definitions, while the documentation hook renders the
same release states and defaults. The docs gate rejects stale projections,
unknown page feature IDs, incomplete profiles, missing primary pages, and an
extension capability list that differs from `contract/peek_table.h`.

## Update derived pages

```sh
scripts/docs-contract
tools/derived-doc-gate rederive docs/user-guide/reference/modules/index.md
```

Use the rederive command for every page carrying a `derived-doc` block. Do not hand-edit its answers or hashes.

The official AsyncAPI Generator remains a compatibility probe, not a required dependency. On 2026-08-09, its current CLI successfully parsed this contract after the missing `file.progress` channel registration was fixed, but installing it brought 1,732 packages and reported 33 dependency vulnerabilities, including seven critical. NOW's bounded projector reads the same AsyncAPI authority, includes the custom `x-commands` registry the stock Markdown template omitted, and keeps the landing gate small enough to run on every change.

## Run the landing gate

```sh
scripts/test-docs
```

It checks provenance, metadata, navigation, audience-folder ownership, public links, image
alt text and dimensions, module/source parity, AsyncAPI references, generated
output, a strict site build, representative accessibility structure, and all
declared derived documents. `NOW_DOCS_RELEASE=1` additionally refuses
publication until the canonical origin, website repository, security contact,
and RFC 9116 expiry are configured in `docs/site-integration.yaml`. A release
build then writes `security.txt` and `robots.txt`; ordinary local builds never
publish placeholder contact data.
