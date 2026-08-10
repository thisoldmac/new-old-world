---
page_id: install-host-how-to
title: Install the macOS host
description: Place and launch the alpha New Old World host on macOS 13 or later.
doc_type: how-to
audience: user
lifecycle: current
authority: [README.md, docs/naming.md]
source_dependencies: [scripts/build-host-app, scripts/verify-host-signature, now-host/Package.swift]
media_ids: [setup-host-install]
last_verified: 2026-08-09
---

# Install the macOS host

## Goal

Install the host app without mixing it with a source-build staging directory.

## Prerequisites

- macOS 13 or later.
- A `New Old World.app` artifact from the alpha release bundle.

## Steps

1. Quit any older copy of New Old World.
2. Move `New Old World.app` to Applications or another stable local folder.
3. Launch that copy and open **Connections**.
4. If macOS refuses the build, retain the exact Gatekeeper message and verify
   the artifact source. Do not strip signatures or quarantine attributes as a
   routine installation step.

![New Old World placed in Applications on the modern Mac](../../assets/screenshots/getting-started/host-install.svg){ .now-placeholder }

## Expected result

The host opens its native window and can start a listener. No classic Mac is
required merely to launch the host.

## Related reference

[Requirements](../reference/requirements.md) and
[Connections and preferences](../reference/modules/connections-and-preferences.md).
