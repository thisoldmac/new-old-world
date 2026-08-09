---
page_id: docs-home
title: New Old World documentation
description: Start using New Old World or trace its host, classic guests, wire contract, and verification model.
doc_type: tutorial
audience: user
lifecycle: current
authority: [README.md, docs/status.md]
source_dependencies: [README.md, docs/status.md, docs/module-manifest.yaml]
media_ids: [overview-host, overview-workshop]
last_verified: 2026-08-09
---

# New Old World documentation

New Old World connects a modern macOS host to a classic Macintosh. The modern
Mac supplies native browsing, services, and agent integration; the classic Mac
supplies its own files, processes, screen, software inventory, and human-facing
Workshop. They meet through one versioned contract.

The first alpha targets the PowerPC Carbon guest. The optional **NOW
Extension** is a first-class part of that story: install it when you need
process-local UI structure, semantic controls, structured drawing content,
in-context interaction, transition observation, modal-safe liveness, drag, or
cursor following. Ordinary files, processes, screenshots, console, hardware,
and software features remain usable without it. [See every extension
capability and its current posture](user-guide/explanation/optional-extension.md).

The pre-Carbon NOW-68K source remains in the repository, but its current build
is stale and is not planned for the initial alpha. The
[initial-alpha feature profile](user-guide/reference/release-profile.md) is the
authoritative release-facing statement.

![The modern macOS host showing a connected classic Mac and its modules](assets/screenshots/overview/host.svg){ .now-placeholder }

![The PowerPC Workshop showing the classic-side pages](assets/screenshots/overview/workshop.svg){ .now-placeholder }

## Start here

- [Connect your first classic Mac](user-guide/tutorials/first-connection.md)
  for the guided path from artifacts to a named session.
- [Understand the NOW Extension](user-guide/explanation/optional-extension.md)
  before deciding whether to install the optional resident.
- [Review initial-alpha features](user-guide/reference/release-profile.md) for
  what is included, optional, and excluded.
- [Browse the module reference](user-guide/reference/modules/index.md) when
  you already have a connection and want to understand one surface.
- [Read the developer orientation](developer-guide/orientation.md) before
  changing source, contracts, guests, resident components, or gates.

## Pre-alpha posture

The documentation uses the same evidence vocabulary as the repository:
**Builds**, **Tested**, **Emulator-verified**, and **Metal-verified** are
different claims. A feature described here may still be experimental or
unverified on one guest. Read [current limitations](user-guide/reference/limitations.md)
before putting irreplaceable data or an untrusted network in the loop.

## Documentation map

- The **user guide** contains one tutorial, outcome-oriented how-to guides,
  explanations, and reference pages.
- The **developer guide** traces ownership, contracts, build/test workflows,
  Mirror, the optional resident, and agent boundaries.
- **Engineering records** preserve status, measurements, known-wrong behavior,
  and the append-only issue ledger. They are evidence, not first-run prose.
