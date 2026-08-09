---
page_id: dev-workflow-docs-gates
title: Documentation and gates
description: Author, render, verify, and keep the public documentation synchronized with code.
doc_type: how-to
audience: developer
lifecycle: current
authority: [mkdocs.yml, tools/docs-gate, docs/module-manifest.yaml, docs/feature-catalog.yaml]
source_dependencies: [mkdocs.yml, tools/docs-gate, tools/docs-placeholders, tools/docs-contract-projector, scripts/test-docs, docs/module-manifest.yaml, docs/feature-catalog.yaml, docs/hooks/release_features.py]
media_ids: []
last_verified: 2026-08-09
---
# Documentation and gates

The public site uses MkDocs Material and the Diátaxis page types: tutorial, how-to, reference, and explanation. Each curated page declares its type, audience, lifecycle, authorities, source dependencies, media IDs, and verification date in YAML front matter.

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

## Bind documentation to release features

`docs/feature-catalog.yaml` declares the active release profile, stable feature
IDs, planned runtime flag keys, and the NOW Extension capability inventory.
Add `feature_ids` to a curated page to render its release-state notice. Use
`<!-- release-feature-table -->` or `<!-- extension-capability-table -->` only
on the owning reference pages; the MkDocs hook renders them from the catalog.

The catalog is documentation authority until runtime feature flags exist. A
future flag implementation must consume the same keys or replace the catalog
as authority; it must not create a second availability matrix. The docs gate
rejects unknown page feature IDs, incomplete profiles, missing primary pages,
and an extension capability list that differs from `contract/peek_table.h`.

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

It checks metadata, navigation, public links, image alt text and dimensions, module/source parity, AsyncAPI references, generated output, a strict site build, representative accessibility structure, and all declared derived documents. `NOW_DOCS_RELEASE=1` additionally refuses publication until the canonical origin, website repository, security contact, and RFC 9116 expiry are configured in `docs/site-integration.yaml`. A release build then writes `security.txt` and `robots.txt`; ordinary local builds never publish placeholder contact data.
