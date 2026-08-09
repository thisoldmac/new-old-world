---
page_id: first-connection-tutorial
title: Connect your first classic Mac
description: A guided first run from the pre-alpha artifacts to a named, verified NOW session.
doc_type: tutorial
audience: user
lifecycle: current
authority: [README.md, docs/naming.md, SECURITY.md]
source_dependencies: [scripts/build-host-app, now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, docs/naming.md]
media_ids: [setup-artifacts, setup-host-listener, setup-guest-connection, setup-connected]
last_verified: 2026-08-09
---

# Connect your first classic Mac

This tutorial gets one modern Mac and one classic Mac to the first named
session. It uses the normal applications and does not require the optional NOW
Extension.

## What you need

- A Mac running macOS 13 or later.
- Either a PowerPC Mac running Mac OS 8.6–9.2.2 with CarbonLib 1.6, or the
  currently targeted 68K System 7.1/MacTCP environment.
- Both machines on a local network you control.
- The host app and the guest matching the classic Mac.

![The four pre-alpha artifacts identified by destination and optional status](../../assets/screenshots/getting-started/artifacts.svg){ .now-placeholder }

## 1. Put each application on its machine

Install **New Old World.app** on the modern Mac. On a PowerPC Mac, transfer the
MacBinary artifact **New Old World.bin** and let the transfer tool restore its
forks. On the 68K target, transfer **now-guest-68k.bin** the same way.

If you are unsure which guest belongs on the classic Mac, stop and use
[Choose the right guest](../how-to/choose-a-guest.md).

## 2. Start the host listener

Launch New Old World on macOS. Open **Connections**, confirm the listener port,
and note an address the classic Mac can reach. Keep the window open for this
first connection.

![The macOS listener ready with an address and port visible](../../assets/screenshots/getting-started/host-listener.svg){ .now-placeholder }

## 3. Point the classic guest at the host

Launch the guest on the classic Mac. On PowerPC, use the Workshop's
**Connection** page. On NOW-68K, use the host and port fields in the main
window. Enter the host's reachable address and the same port, then connect.

![The classic guest connection settings before the first dial](../../assets/screenshots/getting-started/guest-connection.svg){ .now-placeholder }

## 4. Prove the session

The host should show the classic Mac by name, not merely say that a socket is
open. Open **Hardware** and request the overview, or open **Processes** and
refresh. A typed answer from the selected machine proves more than a green
connection light.

![A named connected session with its capability state visible](../../assets/screenshots/getting-started/connected.svg){ .now-placeholder }

## Result

You now have a normal NOW session without a resident extension. Continue with
[Transfer a file](../how-to/transfer-a-file.md), browse the
[module reference](../reference/modules/index.md), or read
[what the optional extension adds](../explanation/optional-extension.md).

If the dial is refused or never settles, use
[Recover a connection](../how-to/recover-a-connection.md). Do not weaken the
network boundary to make a first run easier.
