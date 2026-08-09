---
page_id: dev-ref-documentation-standard
title: Documentation standard
description: The content, schema, accessibility, metadata, and publication standards used by NOW.
doc_type: reference
audience: developer
lifecycle: current
authority: [mkdocs.yml, tools/docs-gate, docs/feature-catalog.yaml]
source_dependencies: [mkdocs.yml, tools/docs-gate, docs/requirements.txt, contract/asyncapi.yaml, docs/site-integration.yaml, docs/feature-catalog.yaml]
media_ids: []
last_verified: 2026-08-09
---
# Documentation standard

| Concern | Standard or convention | NOW integration |
|---|---|---|
| Content purpose | Diátaxis | Every curated page is one tutorial, how-to, explanation, or reference page |
| Authoring | CommonMark-compatible Markdown with MkDocs extensions | Source remains readable in the repository and renders through MkDocs Material |
| Protocol reference | AsyncAPI 3.0 | `contract/asyncapi.yaml` is authoritative; a deterministic Markdown projection is committed |
| Architecture diagrams | Mermaid | Diagrams are source-controlled and always followed by a text equivalent |
| Accessibility | WCAG 2.2 AA target | Semantic landmarks, heading rules, alt text, keyboard skip link, contrast-aware theme, responsive tables, and reduced-motion CSS are gated |
| Vulnerability discovery | RFC 9116 | Release builds generate `/.well-known/security.txt` only from configured contact data |
| Search metadata | Schema.org `TechArticle` | Curated pages emit JSON-LD from front matter |
| Release availability | Stable feature IDs and profiles | `docs/feature-catalog.yaml` drives page notices and generated availability tables; planned runtime flag keys are explicit but not claimed as implemented |
| Publication | NOW website `/docs/` subpath | Canonical origin and repository handoff are release-gated in `docs/site-integration.yaml` |

The gate checks the properties that can be derived locally. Human review still owns clarity, task success, visual accuracy, meaningful alternative text, and whether a captured screenshot discloses private information.
