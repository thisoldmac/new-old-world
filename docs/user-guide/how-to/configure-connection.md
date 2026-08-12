---
page_id: configure-connection-how-to
title: Configure a connection
description: Start the host listener, configure the selected classic guest, and verify the named session.
doc_type: how-to
audience: user
lifecycle: current
authority: [docs/architecture.md, SECURITY.md]
source_dependencies: [now-host/Sources/Host/GuestListener.swift, now-guest-ppc/src/connection, now-guest-68k/src/core/wire68.c]
media_ids: [setup-host-listener, setup-guest-connection, setup-connected]
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Configure a connection

## Goal

Create one named session over a trusted local network.

## Steps

1. In the macOS host, open **Connections** and start the listener.
2. Record a host address reachable from the classic Mac and the listener port.
3. Enter both values on the classic guest's Connection surface.
4. Connect and wait for the `hello` exchange to settle.
5. Confirm the host names the intended classic Mac, then request one hardware
   or process read from that selected session.

![The host listener address and port](../../assets/screenshots/getting-started/host-listener.svg){ .now-placeholder }

![The guest connection fields](../../assets/screenshots/getting-started/guest-connection.svg){ .now-placeholder }

![A named session after a successful handshake](../../assets/screenshots/getting-started/connected.svg){ .now-placeholder }

## Expected result

Both sides agree on contract revision and the host can identify which guest
answered. A socket alone is not the acceptance condition.

## Recovery

Use [Recover a connection](recover-a-connection.md) and retain any typed
refusal. Do not expose or forward the port to bypass LAN routing.
