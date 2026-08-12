---
page_id: agent-evidence-handoff
title: Evidence and handoff
description: Prove the intended guard, preserve authoritative artifacts, and report semantic impact and uncertainty at task completion.
doc_type: how-to
audience: agent
lifecycle: current
authority: [AGENTS.md]
source_dependencies: [AGENTS.md, docs/developer-guide/reference/verification-levels.md, docs/developer-guide/workflows/build-and-test.md, docs/open-issues.md]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Evidence and handoff

## Prove the intended behavior

Use the [verification levels](../developer-guide/reference/verification-levels.md)
without inventing a stronger adjective. A successful build is not a behavior
test; emulator evidence is not physical-hardware evidence.

For a new guard, mutate the exact condition named by the guard, prove the
mutation built and the test ran, observe the named failure, restore the source,
and observe the pass. A build failure, a different mutation, or a green test
that reached no machine is not mutation evidence.

For emulator or hardware work, preserve the build identity, machine identity,
lane/port, base image, staged artifacts, and guest-reported capabilities. The
stored artifact must prove an observation plane armed; an invocation log does
not.

## Close the task coherently

Before handing off:

1. run the relevant gate and record skips;
2. update the public behavior page and `docs/open-issues.md` when the arc changes
   what is known, broken, or unverified;
3. rederive every declared document whose source moved;
4. commit a coherent checkpoint on the task branch;
5. confirm the worktree contains no unreported task changes.

Report both the technical diff and the semantic result: what a person or
developer can do or understand now, why the boundary changed, what was tested,
what remains uncertain, and the next natural integration step. Do not use a
generic “works” closeout.
