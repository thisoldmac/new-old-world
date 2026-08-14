---
page_id: logs-module-reference
title: Logs module
description: Read bounded host and guest diagnostic evidence without confusing a log line with authoritative settlement.
doc_type: reference
audience: operator
lifecycle: current
authority: [docs/architecture.md, docs/status.md]
module_ids: [logs]
source_dependencies: [now-host/Sources/Host/ModuleRegistry.swift, now-host/Sources/Host/LogsHostModule.swift, now-host/Sources/Host/HostLog.swift, now-host/Sources/Host/LogsModuleView.swift, now-host/Sources/Host/MirrorContinuityController.swift, now-guest-ppc/src/logs, now-guest-68k/src/core/log.c, docs/architecture.md]
media_ids: [logs-host, logs-ppc]
last_verified: 2026-08-14
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

The host shows its bounded 2,000-line in-memory scrollback and follows the
newest line. Invert changes the reading canvas; Log to disk adds a per-launch
file without turning off the in-memory ring. Lines carry a short subsystem tag,
but this page does not currently provide filtering.

An **Advanced Continuity diagnostics** disclosure owns the retained input
probes. These controls are normally left off: they increase evidence volume and
exist to diagnose a matched guest session, not to configure Mirror's normal
pointer behavior. Fast Pump changes cooperative scheduling cadence for a
bounded comparison. The deep-click probe can record every mouse event at the
guest jGNE boundary with click-relevant low-memory state. Product mechanisms
such as interrupt-time press delivery and idle cursor settlement default on
and remain with the Continuity controls as explicit regression opt-outs.

## On the classic Mac

The PowerPC page tails guest history. NOW-68K keeps a small log appropriate to
its partition and repeats critical state in the visible console.

![The PowerPC Logs page](../../../assets/screenshots/modules/logs/ppc.svg){ .now-placeholder }

## Common tasks

- Use the subsystem tag and timestamp to isolate a session before copying
  evidence; filtering is currently external (for example, in the saved file).
- Pair a log with the later authoritative state when diagnosing an action.

## Safety, consent, and privacy

Logs can contain machine names, file names, application names, addresses, and
failure text. Scrub them before publishing.

## Failure states

Log unavailable, rotated, truncated, stale session, and disconnected are
different from an operation failure described by a retained line.

## Current limitations

Logging is evidence, not authority. A line saying a request was sent does not
prove the target state changed. Advanced Continuity probes are default off and
can produce dense evidence; enable them only for a bounded reproduction and
turn them off before interpreting ordinary timing or log volume.

## For developers

See [architecture logging rules](../../../architecture.md#logging) and
[source authority](../../../developer-guide/reference/source-authority.md).
