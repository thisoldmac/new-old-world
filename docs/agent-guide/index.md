---
page_id: agent-guide-home
title: Coding agent guide
description: Start here when an automated coding agent is inspecting or changing the New Old World repository.
doc_type: tutorial
audience: agent
lifecycle: current
authority: [AGENTS.md]
source_dependencies: [AGENTS.md, docs/developer-guide/orientation.md, docs/developer-guide/reference/source-authority.md, scripts/test-all]
media_ids: []
last_verified: 2026-08-09
---

# Coding agent guide

This guide is an operational overlay for coding agents. It does not teach the
architecture twice. Use the human [developer guide](../developer-guide/index.md)
to understand the system and this path to decide how to operate on it.

`AGENTS.md` remains the complete repository instruction and outranks this
projection. Current user instructions outrank both.

## Begin every task

1. Read the applicable `AGENTS.md` before acting.
2. Inspect the current branch, worktree status, remotes needed by the task, and
   nearby repository instructions.
3. Classify the request as read-only analysis, diagnosis, planning, or
   authorized implementation. Do not turn the first three into edits.
4. Use the human [codebase orientation](../developer-guide/orientation.md) to
   identify the owning subsystem and source authority.
5. Choose the platform route before touching classic Mac code.

## Continue by task shape

- [Operating protocol](operating-protocol.md) covers shared worktrees,
  branches, checkpoints, scope, and authority.
- [Platform routing](platform-routing.md) selects the correct application
  model, skill, and verification surface.
- [Change routing](change-routing.md) maps a requested change to its contract,
  implementation, documentation, and gates.
- [Evidence and handoff](evidence-and-handoff.md) defines what must be proven
  and reported before the task is complete.

When this guide links to a developer architecture or workflow page, that page
owns the technical explanation. Do not copy its enumeration into an agent note
or prompt; link to it and add only task-specific evidence.
