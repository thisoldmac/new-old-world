---
page_id: networking-module-reference
title: Networking module
description: Show connection, address, interface, and network-stack facts for the selected classic Mac.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/status.md, SECURITY.md]
module_ids: [networking]
source_dependencies: [now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/network, now-guest-68k/src/ui/health.c, SECURITY.md]
media_ids: [networking-host, networking-ppc]
last_verified: 2026-08-09
---

# Networking module

## What it does

Networking presents the guest's link state, address, network stack, and
available hardware facts separately from the host listener configuration.

![The macOS Networking module](../../../assets/screenshots/modules/networking/host.svg){ .now-placeholder }

## Availability

PowerPC has a full Workshop page. NOW-68K shows a bounded MacTCP health and
address summary in its main window.

## On the modern Mac

The module shows facts reported by the selected guest. The host's own listener
address remains in Connections.

## On the classic Mac

PowerPC reports Open Transport and interface facts. NOW-68K reports MacTCP
health appropriate to System 7.1; Open Transport advice does not apply.

![The PowerPC Networking page](../../../assets/screenshots/modules/networking/ppc.svg){ .now-placeholder }

## Common tasks

- Use [Configure a connection](../../how-to/configure-connection.md) to change
  endpoints.
- Use Networking to inspect the guest's reported link after connection.

## Safety, consent, and privacy

Addresses and adapter details can identify a private network. Scrub them from
public screenshots and support logs.

## Failure states

Stack unavailable, no address, link down, unsupported selector, stale session,
and disconnected are distinct states.

## Current limitations

This module does not encrypt or authenticate the wire. Use the trusted-network
boundary even when the link appears healthy.

## For developers

See [security reference](../../../developer-guide/reference/security.md) and
[wire architecture](../../../developer-guide/architecture/wire-contract.md).
