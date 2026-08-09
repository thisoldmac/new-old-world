---
page_id: dev-orientation
title: Developer orientation
description: The shortest path from a fresh checkout to the correct New Old World subsystem.
doc_type: tutorial
audience: developer
lifecycle: current
authority: [AGENTS.md, README.md]
source_dependencies: [AGENTS.md, README.md, scripts/test-all, contract/asyncapi.yaml]
media_ids: []
last_verified: 2026-08-09
---
# Developer orientation

## Before you begin

Use a branch and run `tools/setup-hooks` once per clone. This repository is commonly shared through worktrees; never assume an uncommitted change belongs to you.

## Read the boundaries

1. Read `AGENTS.md` for the full operating rules.
2. Read [system context](architecture/system-context.md) and [source authority](reference/source-authority.md).
3. Inspect `contract/asyncapi.yaml` before changing behavior that crosses the wire.
4. For PowerPC UI work, read `docs/guest-ui-start-here.md`. For 68K work, preserve its non-Carbon Toolbox boundary.

## Establish a baseline

```sh
scripts/test-all
```

The command orders the gates from cheap to expensive. A skip means the necessary toolchain is absent; it does not prove the skipped surface. Record the result as [builds, tested, or metal-verified](reference/verification-levels.md), never as a generic “works.”

## Find the owner

Use the [repository map](reference/repository-map.md). If the change affects both applications, begin with the contract rather than implementing one half first. If it affects how a person uses a feature, update the corresponding user module page in the same change.

