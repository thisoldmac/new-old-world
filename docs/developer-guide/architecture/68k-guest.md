---
page_id: dev-arch-68k-guest
title: 68K guest architecture
description: The retained, initial-alpha-excluded MacTCP and Toolbox sibling guest for System 7.1-era machines.
doc_type: explanation
audience: developer
lifecycle: reference
authority: [now-guest-68k/src/main.c, docs/architecture.md]
source_dependencies: [now-guest-68k/src/main.c, now-guest-68k/src/commands/commands68.c, now-guest-68k/src/connection, now-guest-68k/src/core/wire68.c, docs/command-parity.md, docs/feature-catalog.yaml]
feature_ids: [classic.pre-carbon]
media_ids: []
last_verified: 2026-08-09
---
# 68K guest architecture

NOW-68K is a sibling of the Carbon guest, not a port. It is a non-Carbon Toolbox C application built by Retro68 for System 7.1-era machines and uses MacTCP. It implements an explicit subset of the same AsyncAPI contract without forcing early-machine constraints into the PowerPC tree.

The current build is stale and excluded from the initial alpha. Preserve this
architecture, its tests, and contract subset for later work, but do not use it
to broaden initial-release claims. The planned documentation/runtime binding is
the `classic.pre-carbon` feature flag; that runtime flag does not exist yet.

Commands converge in `commands68.c`: the local console and wire renderer consume one result model. Message families such as file and process listings similarly share their enumeration logic. The parity gate distinguishes a supported subset from accidental face drift.

The 68K guest has no resident extension dependency and no Workshop module architecture. Its smaller UI, networking buffers, and system capability probes must degrade explicitly. Consult `docs/contract-coverage.md` for served versus proven operations; the absence of a module page on the machine is not proof the wire verb is absent.
