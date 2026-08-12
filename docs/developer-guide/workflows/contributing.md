---
page_id: dev-workflow-contributing
title: Contributing
description: Contributor workflow from a focused change through tests and review.
doc_type: how-to
audience: developer
lifecycle: current
authority: [CONTRIBUTING.md]
source_dependencies: [CONTRIBUTING.md, scripts/test-all, scripts/test-docs]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Contributing

## Choose a focused change

Start with a user-visible behavior, defect, or documented maintenance task that
has a clear owner. Read the relevant architecture page and nearby tests before
editing. If the change crosses the wire or resident-memory boundary, begin with
that contract.

## Work through normal review

Create a topic branch from the current project base. Keep unrelated cleanup
out of the patch, commit coherent checkpoints, and open a review that explains
both the code change and its effect on the product. `CONTRIBUTING.md` carries
the current repository mechanics.

## Keep boundaries together

A wire behavior change starts in `contract/asyncapi.yaml` and updates both receivers or records a deliberate capability posture. A user-visible capability updates its module page. A new module updates the live registry, `docs/module-manifest.yaml`, navigation, and media slots in the same branch.

## Verify and explain

Run the smallest relevant gate while iterating, then `scripts/test-all`. Report which stages built, tested, skipped, or were metal-verified. Include uncertainty and current limitations rather than converting them into release claims.

In the review description, include the behavior before and after, the owning
contract or model, the tests run, any skipped toolchain or hardware stage, and
remaining uncertainty. See the repository-root `CONTRIBUTING.md` for the
complete contribution path. Coding agents use the separate [agent
guide](../../agent-guide/index.md) for their additional operating protocol.
