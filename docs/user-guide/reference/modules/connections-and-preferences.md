---
page_id: settings-module-reference
title: Connections and preferences
description: Configure the listener, select named guest sessions, and manage host or guest preferences without mixing machine identity with network reachability.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/architecture.md, docs/naming.md]
module_ids: [settings]
source_dependencies: [now-host/Sources/Host/ModuleRegistry.swift, now-host/Sources/Host/GuestListener.swift, now-guest-ppc/src/connection, now-guest-ppc/src/core/prefs.c, now-guest-68k/src/ui/window.c]
media_ids: [settings-host, settings-ppc]
last_verified: 2026-08-09
---

# Connections and preferences

## What it does

Connections owns the host listener and named sessions. Preferences owns local
application choices. The PowerPC Workshop separates Preferences and Connection;
the host presents one settings module, and NOW-68K uses its main window.

![The macOS Connections module](../../../assets/screenshots/modules/settings/host.svg){ .now-placeholder }

## Availability

All three applications expose the connection state they own. Preference depth
differs; NOW-68K intentionally keeps its compact connection UI rather than the
PowerPC preference model.

## On the modern Mac

The host starts and stops the listener, names simultaneous guests, selects the
active session, and reports duplicate-name or capacity refusals.

## On the classic Mac

PowerPC carries separate Connection and Preferences pages. NOW-68K shows host,
port, timeout, health, status, and retained console information in one window.

![The PowerPC Preferences and Connection surfaces](../../../assets/screenshots/modules/settings/ppc.svg){ .now-placeholder }

## Common tasks

- [Configure a connection](../../how-to/configure-connection.md).
- [Recover a connection](../../how-to/recover-a-connection.md).

## Safety, consent, and privacy

The listener is plaintext and unauthenticated. Bind and advertise it only on a
trusted LAN; never forward it through a router.

## Failure states

Revision mismatch, duplicate machine name, host unreachable, timeout, listener
busy, capacity reached, and stale selected session retain exact reasons.

## Current limitations

Guest display name is the current connection identity. Two live machines with
the same name collide intentionally rather than being guessed apart.

## For developers

See [connection sequence](../../../developer-guide/architecture/wire-contract.md#connection-sequence)
and [network threat model](../../../developer-guide/reference/security.md).
