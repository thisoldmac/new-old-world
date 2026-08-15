---
page_id: diagnostics-module-reference
title: Diagnostics module
description: Run explicit, cost-stated measurements against the selected classic Mac without treating an unarmed instrument as evidence.
doc_type: reference
audience: operator
lifecycle: experimental
authority: [docs/status.md, docs/emu-readiness.md]
module_ids: [diagnostics]
source_dependencies: [now-host/Sources/Host/ModuleRegistry.swift, now-host/Sources/Host/DiagnosticsModel.swift, now-guest-ppc/src/diagnostics, now-guest-ppc/src/commands/commands.c, now-guest-68k/src/commands/commands68.c, docs/emu-readiness.md]
media_ids: [diagnostics-host, diagnostics-ppc]
last_verified: 2026-08-14
---

<!-- now-doc-provenance: generated reviewed=false -->

# Diagnostics module

## What it does

Diagnostics runs measurements that are too costly, invasive, or specialized
for idle collection. Each diagnostic must state its cost before execution.

Wire timing is the one free instrument here. It reports how long the selected
machine takes to *notice* a request — the interval between its own wire
service passes, and the delay from the network stack announcing data to its
event loop reading it — as histograms rather than medians, because the tail is
what a person feels. The link's own timing (round trip, receive window, window
peak, quiet time) is read beside it; those rows describe the wire, not the
machine's networking, so they are not on the Networking page.

![The macOS Diagnostics module](../../../assets/screenshots/modules/diagnostics/host.svg){ .now-placeholder }

## Availability

PowerPC has the full page. NOW-68K exposes selected diagnostics such as VRAM
and screenshot-source probes through the console rather than a matching page.

## On the modern Mac

The host selects a named machine and records the request, status, and returned
evidence. It must not turn a timeout into a measurement.

## On the classic Mac

The PowerPC page states cost and progress. The 68K console's `vprobe` and
`shotdiag` commands use the same bounded diagnostic implementations as wire
calls.

![The PowerPC Diagnostics page](../../../assets/screenshots/modules/diagnostics/ppc.svg){ .now-placeholder }

## Common tasks

- Read the cost and required rig before running a diagnostic.
- Save the resulting build, machine, port, and artifact identity with numbers.

## Safety, consent, and privacy

Some diagnostics allocate scarce classic memory, read the display, or hold a
transfer lane. Do not run them during unrelated machine use.

## Failure states

Not armed, unsafe on this machine, unavailable manager, timed out, partial,
and result-buffer limit are different outcomes.

## Current limitations

An instrument that wrote no artifact cannot support an absence claim. A count
not derived from the stored result is not evidence.

Wire timing is read-only from the modern Mac. The same verb can also change
the classic Mac's idle sleep and turn its wake notifier off; those knobs stay
on that machine's own console, because they alter how it schedules every
application it is running. NOW-68K has nothing to answer here: the wake is an
Open Transport notifier and that guest speaks MacTCP.

## For developers

See [emulator and metal workflow](../../../developer-guide/workflows/emulator-and-metal.md)
and [emulator readiness](../../../emu-readiness.md).
