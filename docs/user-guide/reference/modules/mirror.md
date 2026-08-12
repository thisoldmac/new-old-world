---
page_id: mirror-module-reference
title: Mirror module
description: Observe a PowerPC desktop semantically, render host-native projections, and drive bounded actions with settlement evidence.
doc_type: reference
audience: user
lifecycle: experimental
authority: [docs/mirror-knowledge.md, docs/mirror-drive-loop.md]
module_ids: [mirror]
source_dependencies: [docs/mirror-knowledge.md, docs/mirror-drive-loop.md, now-host/Packages/MirrorKit, now-host/Sources/Host/GuestWorkScheduler.swift, now-host/Sources/Host/MirrorStateProjectionService.swift, now-guest-ppc/src/mirror, contract/asyncapi.yaml, contract/peek_table.h]
media_ids: [mirror-host, mirror-ppc, mirror-detail]
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Mirror module

## What it does

Mirror combines guest-observed window and interface information, optional
structured content, and host-native rendering. Actions drive the guest and
settle by rereading guest state.

![The macOS Mirror module with provenance visible](../../../assets/screenshots/modules/mirror/host.svg){ .now-placeholder }

## Availability

Mirror is PowerPC-only and experimental. Its ordinary shell can work without
the optional Extension; live application structure, drawing activity, and
other deeper features may require it. The [feature coverage
matrix](../../explanation/core-features.md#feature-coverage) states which
user outcomes require the Extension. NOW-68K has no Mirror subsystem.

## On the modern Mac

The host joins scene identity, content, Finder semantics, references, and act
settlement. Human requests take priority over queued ambient reads at the next
safe boundary. Change notices combine redundant refreshes, and the host avoids
publishing a view that mixes older and newer state. A host-rendered interior
never becomes authority for guest state.

## On the classic Mac

The PowerPC page reports which Extension features are available and active.
The guest app remains the wire owner even when the Extension observes another
application.

![The PowerPC Mirror page](../../../assets/screenshots/modules/mirror/ppc.svg){ .now-placeholder }

## Common tasks

- Observe before enabling act controls.
- Read provenance and Extension status before interpreting an empty interior.

![A settled Mirror action followed by an authoritative reread](../../../assets/screenshots/modules/mirror/detail.svg){ .now-placeholder }

## Safety, consent, and privacy

Mirror can expose window titles, text, file rosters, and screen content. Agent
actions remain bounded by the machine's consent ceiling and visible host state.

## Failure states

Missing Extension feature, no writer, stale reference, not addressed,
timed-out settlement, invalidation gap, stale generation, and authoritative
refusal are not interchangeable. Gap or unknown hints trigger a repair read;
cadence polling remains available when no hint arrives.

## Current limitations

Finder and application interiors retain known incomplete behaviors. An
observation feature that was requested but produced no artifact cannot support
a rendering claim.

Queued human work does not preempt a guest traversal already running. The new
scheduler and coherent publication path are tested locally, but the PowerBook
1400c ambient-wait target is not metal-verified.

## For developers

See [Mirror architecture](../../../developer-guide/architecture/mirror.md) and
[the measured knowledge index](../../../mirror-knowledge.md).
