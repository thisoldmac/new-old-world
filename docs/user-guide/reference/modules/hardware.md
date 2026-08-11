---
page_id: hardware-module-reference
title: Hardware module
description: Request bounded passive census probes from the selected classic Mac and retain the probe's own absent, partial, or refused outcome.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/contract-coverage.md, contract/asyncapi.yaml]
module_ids: [census]
source_dependencies: [contract/asyncapi.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/census, now-guest-68k/src/census]
media_ids: [hardware-host, hardware-ppc]
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Hardware module

## What it does

Hardware asks the selected classic Mac to describe itself through one bounded
probe at a time.

![The macOS Hardware module](../../../assets/screenshots/modules/hardware/host.svg){ .now-placeholder }

## Availability

Both guests serve a census, but probe coverage differs. PowerPC exposes the
full Workshop page; NOW-68K serves the subset its System 7.1 managers and
hardware can answer.

## On the modern Mac

The host pages results without rewriting absent, partial, refused, or failed
into empty rows. The selected machine remains part of the result.

## On the classic Mac

The PowerPC Hardware page selects probes and renders their rows. NOW-68K offers
the same probe registry through its wire and console at its smaller bounds.

![The PowerPC Hardware page](../../../assets/screenshots/modules/hardware/ppc.svg){ .now-placeholder }

## Common tasks

- Run the overview before choosing a specialized probe.
- Record the machine, build, probe, and verification rung with any result.

## Safety, consent, and privacy

The census is passive, but machine names, network addresses, volumes, and
hardware inventory may still be private when screenshots or logs are shared.

## Failure states

Unknown probe, absent manager, partial read, unsafe probe refusal, page limit,
and disconnect remain distinct.

## Current limitations

A probe listed in the contract is not automatically implemented or proven on
both guests. Consult the live capability and coverage table.

## For developers

See [contract coverage](../../../contract-coverage.md) and
[verification levels](../../../developer-guide/reference/verification-levels.md).
