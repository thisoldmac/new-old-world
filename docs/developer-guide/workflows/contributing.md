---
page_id: dev-workflow-contributing
title: Contributing
description: The reviewable branch, contract-first, testing, and documentation workflow for contributors.
doc_type: how-to
audience: developer
lifecycle: current
authority: [CONTRIBUTING.md, AGENTS.md]
source_dependencies: [CONTRIBUTING.md, AGENTS.md, scripts/test-all, scripts/test-docs]
media_ids: []
last_verified: 2026-08-09
---
# Contributing

## Work on a branch

Start from the branch you are continuing, never type changes on `main`, and stage explicit paths. Preserve unknown work in shared checkouts. Commit coherent checkpoints early and label unverified ones plainly.

## Keep boundaries together

A wire behavior change starts in `contract/asyncapi.yaml` and updates both receivers or records a deliberate capability posture. A user-visible capability updates its module page. A new module updates the live registry, `docs/module-manifest.yaml`, navigation, and media slots in the same branch.

## Verify and report

Run the smallest relevant gate while iterating, then `scripts/test-all`. Report which stages built, tested, skipped, or were metal-verified. Include uncertainty and current limitations rather than converting them into release claims.

See the repository-root `CONTRIBUTING.md` and `AGENTS.md` for the complete operational rules.

