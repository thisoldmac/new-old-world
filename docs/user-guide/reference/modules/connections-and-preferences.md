---
page_id: settings-module-reference
title: Connections
description: Configure the listener and select named guest sessions without mixing machine identity with network reachability or application appearance.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/architecture.md, docs/naming.md, docs/onboarding.md, contract/asyncapi.yaml]
module_ids: [settings]
source_dependencies: [now-host/Sources/Host/ModuleRegistry.swift, now-host/Sources/Host/NavigationLayout.swift, now-host/Sources/Host/GuestListener.swift, now-host/Sources/Host/ConnectionsModel.swift, now-host/Sources/Host/ConnectionsModuleView.swift, now-host/Sources/Host/UpdateProvider.swift, now-host/Sources/Host/OnboardingPortal.swift, now-host/Sources/Host/OnboardingView.swift, now-host/Sources/Host/ClassicSetupImageBuilder.swift, now-host/Sources/Host/AppearancePreferences.swift, now-host/Sources/Host/SettingsWindowController.swift, now-host/Sources/Host/HostSettingsView.swift, now-host/Sources/Host/HostSettingsNavigation.swift, now-host/Sources/Host/ContinuityConnectionDefaults.swift, now-guest-ppc/src/connection, now-guest-ppc/src/update, now-guest-ppc/src/core/prefs.c, now-guest-68k/src/ui/window.c]
media_ids: [settings-host, settings-ppc]
last_verified: 2026-08-15
---

<!-- now-doc-provenance: generated reviewed=false -->

# Connections

## What it does

Connections owns the host listener, named sessions, and **Set Up a New Mac…**
portal. On the macOS host it is the landing page of the Connections shelf. The
PowerPC Workshop separately provides Preferences and Connection pages, and
NOW-68K keeps connection controls in its main window.

The macOS application's own appearance, and a set of preferences that used to
sit inside individual modules, no longer live in this module. Choose
**New Old World > Settings…** or press **Command-,** to open the separate
Settings window: a pill switcher over Appearance (System, Light, or Dark
theme; Off, Clear, or Regular Liquid Glass — the glass choices fall back to
native material on macOS 13–25 and when Reduce Transparency or Increase
Contrast is enabled), Sidebar (row density, icon collapse, reset layout), MCP
(whether each transport starts automatically), Web (page-compatibility mode
and the private-destinations safety toggle), Logs (whether the event log
also writes to disk), and Defaults for New Connections (what a Continuity
pairing with a Mac it has never seen before starts with). Several modules —
MCP, Web, Logs — carry their own **Settings…** button that opens this window
already on their tab. Files and Screenshots keep their own in-module settings
panes; Continuity and Mirror keep their per-machine controls in-module.

![The macOS Connections module](../../../assets/screenshots/modules/settings/host.svg){ .now-placeholder }

## Availability

All three applications expose the connection state they own. Preference depth
differs; NOW-68K intentionally keeps its compact connection UI rather than the
PowerPC preference model.

The host keeps the sidebar arrangement and selected module when a guest
disconnects. Host-owned pages remain available, pages with retained machine
information identify it as offline, and live-only pages route recovery here or
offer **Start Listening**.

## On the modern Mac

The host starts and stops the listener, names simultaneous guests, selects the
active session, and reports duplicate-name or capacity refusals. Its setup
sheet can generate preferences, assemble a fork-preserving setup disk from
selected packages, and serve it temporarily over old-browser-compatible HTTP.

## On the classic Mac

PowerPC carries separate Connection and Preferences pages. Its Connection page
also compares the running application and active Extension with the exact
artifacts published by the connected host. A different development build of
the same release version is visible rather than collapsed into “current.”
NOW-68K shows host, port, timeout, health, status, and retained console
information in one window; it does not implement the update family.

![The PowerPC Preferences and Connection surfaces](../../../assets/screenshots/modules/settings/ppc.svg){ .now-placeholder }

## Common tasks

- [Configure a connection](../../how-to/configure-connection.md).
- [Set up a new PowerPC Mac](../../how-to/set-up-new-mac.md).
- [Recover a connection](../../how-to/recover-a-connection.md).
- [Upgrade, roll back, or remove NOW](../../how-to/upgrade-rollback-remove.md).

## Safety, consent, and privacy

The listener is plaintext and unauthenticated. Bind and advertise it only on a
trusted LAN; never forward it through a router.

The setup portal is also plaintext. It exposes fixed download routes rather
than uploads or directory listings; stop it when onboarding is complete.

Update artifacts are currently **unsigned**. The host recomputes their SHA-256
before advertising them and the guest verifies the transferred bytes, but that
proves integrity against the host's manifest, not publisher authenticity. The
local Connection page requires an explicit confirmation; console and remote
command paths cannot bypass it.

## Failure states

Revision mismatch, duplicate machine name, host unreachable, timeout, listener
busy, capacity reached, and stale selected session retain exact reasons.
Setup also retains missing-package, checksum-refusal, stale-selection, image
build, archive-tool, and server-start failures instead of offering a partial
disk as complete.

Updates retain no-offer, busy-transfer, identity mismatch, checksum mismatch,
disk-space, Finder-identity, exchange, and relaunch/restart states rather than
presenting a downloaded file as installed.

Extension restart state survives an application relaunch and clears only when
a later boot reports the installed resident identity active. On launch,
PowerPC also warns when it detects CarbonLib below the supported 1.6 floor;
**Don't Warn Again** suppresses that advisory without changing CarbonLib.

## Current limitations

Guest display name is the current connection identity. Two live machines with
the same name collide intentionally rather than being guessed apart.

Classic update signing, internet discovery, and host self-update are not
implemented. The connected host is the only provider, and the flow is not yet
metal-verified.

## For developers

See [connection sequence](../../../developer-guide/architecture/wire-contract.md#connection-sequence)
and [network threat model](../../../developer-guide/reference/security.md).
