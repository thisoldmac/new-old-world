---
page_id: agent-operating-protocol
title: Coding agent operating protocol
description: Authority, scope, branch, shared-worktree, checkpoint, and public-information rules for coding agents.
doc_type: reference
audience: agent
lifecycle: current
authority: [AGENTS.md]
source_dependencies: [AGENTS.md, CONTRIBUTING.md, docs/developer-guide/reference/source-authority.md]
media_ids: []
last_verified: 2026-08-09
---

# Coding agent operating protocol

## Authority order

Apply instructions in this order:

1. current user request;
2. repository-local `AGENTS.md` and narrower directory instructions;
3. the owning contract, registry, source, and tests;
4. maintained developer documentation and ledgers;
5. historical plans, session notes, or remembered context.

Use [Source authority](../developer-guide/reference/source-authority.md) to
resolve technical claims. Stored context is orientation until current source or
runtime evidence confirms it.

## Scope discipline

- Audits, reviews, explanations, diagnosis, and planning are read-only unless
  implementation is explicitly requested.
- Once implementation is authorized, make the smallest coherent change that
  satisfies the request. Do not silently decide product scope, architecture,
  security, privacy, or data contracts.
- Ask only when a missing choice materially changes risk, irreversible work,
  or product behavior. Otherwise state the smallest safe assumption.
- Never place private machine configuration, credentials, raw user context, or
  lab identity in a public artifact.

## Shared repository discipline

- Inspect branch, ancestry, worktree status, and foreign changes before the
  first mutation.
- Work on a topic branch, not `main`. Continue from the actual parent branch,
  not an assumed one.
- Preserve unknown modifications. Do not reset, delete, or absorb another
  task's files.
- Stage explicit paths and commit coherent checkpoints early. Label an
  unverified checkpoint as unverified.
- Treat derived tables and generated projections as stale after their sources
  move, even when a textual merge is clean.

## Public documentation discipline

Published `docs/` pages are deliberate user or developer material unless
they live under `docs/agent-guide/`. Investigation logs, raw output, and
session handoffs stay in ignored `docs/local/` until a durable finding is
graduated to its owning page or ledger.
