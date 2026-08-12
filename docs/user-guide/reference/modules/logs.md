---
page_id: logs-module-reference
title: Logs module
description: Read bounded host and guest diagnostic evidence without confusing a log line with authoritative settlement.
doc_type: reference
audience: operator
lifecycle: current
authority: [docs/architecture.md, docs/status.md]
module_ids: [logs]
source_dependencies: [now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/logs, now-guest-68k/src/core/log.c, docs/architecture.md]
media_ids: [logs-host, logs-ppc]
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Logs module

## What it does

Logs exposes bounded diagnostic history from the host and selected guest so a
failure can retain time, machine, operation, and reason.

![The macOS Logs module](../../../assets/screenshots/modules/logs/host.svg){ .now-placeholder }

## Availability

PowerPC has a Workshop Logs page. NOW-68K records bounded logs and surfaces
important evidence through its console rather than a matching page.

## On the modern Mac

The host can filter by session and subsystem. A useful line identifies which
machine and operation it describes.

## On the classic Mac

The PowerPC page tails guest history. NOW-68K keeps a small log appropriate to
its partition and repeats critical state in the visible console.

![The PowerPC Logs page](../../../assets/screenshots/modules/logs/ppc.svg){ .now-placeholder }

## Common tasks

- Filter to the named session and time window before copying evidence.
- Pair a log with the later authoritative state when diagnosing an action.

## Safety, consent, and privacy

Logs can contain machine names, file names, application names, addresses, and
failure text. Scrub them before publishing.

## Failure states

Log unavailable, rotated, truncated, stale session, and disconnected are
different from an operation failure described by a retained line.

## Current limitations

Logging is evidence, not authority. A line saying a request was sent does not
prove the target state changed.

## For developers

See [architecture logging rules](../../../architecture.md#logging) and
[source authority](../../../developer-guide/reference/source-authority.md).
