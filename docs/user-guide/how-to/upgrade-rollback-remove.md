---
page_id: lifecycle-how-to
title: Upgrade, roll back, or remove NOW
description: Install host-published guest or Extension builds, retain rollback artifacts, or remove NOW without leaving the optional extension behind.
doc_type: how-to
audience: operator
lifecycle: current
authority: [contract/asyncapi.yaml, contract/product_version.h, contract/resident_version.h, docs/naming.md, docs/resident-components.md]
source_dependencies: [contract/asyncapi.yaml, contract/product_version.h, contract/resident_version.h, docs/naming.md, docs/resident-components.md, docs/distribution-profile.yaml, scripts/assemble-release, scripts/build-continuity-stack, tools/continuity-stack-gate, now-host/Sources/Host/UpdateProvider.swift, now-guest-ppc/src/update, now-guest-ppc/src/core/prefs.c]
media_ids: []
last_verified: 2026-08-13
---

<!-- now-doc-provenance: generated reviewed=false -->

# Upgrade, roll back, or remove NOW

## Goal

Change versions without creating a host/guest contract mismatch or forgetting
the optional resident component.

## Update the PowerPC application

1. Install a release host or build the modern host together with the PowerPC
   artifact it should publish. A release host seals the exact guest assets
   inside its app before signing. A development handoff should contain
   `NOW-stack.json`; it proves the host, application, and Extension were
   assembled with one Continuity compatibility tuple.
2. Connect the PowerPC guest and select it in the host's **Connections** page.
3. Read the Guest application row under **Software Updates**. The row
   compares both release version and exact build identity, so a different
   scratch build of the same version is still shown.
4. Choose **Replace Guest App…**. Development artifacts currently have a SHA-256
   integrity check but no release signature; confirm the unsigned-build warning
   only if this is the host and build you intended to trust.
5. Let the transfer complete. The guest verifies the exact MacBinary stream,
   moves the running copy to the Trash, and puts the replacement at the exact
   canonical path. Quit the still-running guest app and launch **New Old
   World** again. The trashed application remains available for rollback.
6. After reconnection, verify the exact build shown by Connections and exercise
   one capability. A completed download alone is not behavioral verification.

## Update the NOW Extension

1. In the same host Connections page, read the Extension row. If the active
   Extension version differs from the application expectation, NOW shows a
   warning even before a replacement is installed.
2. Choose **Replace NOW Extension…** and, for a development build, confirm the
   unsigned-build warning.
3. After the guest reports installation, restart the classic Mac. An INIT is
   not active until boot; do not judge resident behavior before restarting.
4. Reopen NOW and confirm that the mismatch warning is gone and the resident
   capabilities you use are available.

If Continuity says the installed NOW Extension is incompatible or not active,
do not replace the guest application again. Replace the Extension from the
separate row and restart the classic Mac. The file on disk is not the active
resident until that cold activation boundary has passed.

The previous resident is moved to that volume's Trash before the replacement
takes its canonical name, so it cannot load alongside the replacement.

The Extension receipt is durable. Quitting or replacing the guest application
does not erase **restart required**; the receipt clears only after a later boot
reports the installed Extension build as the active resident. Application and
Extension remain separate actions. A release normally updates the application,
reconnects, updates the Extension, and then restarts; iterative development may
update the Extension first and perform one final restart after both transfers.

## Manual fallback and rollback

The in-app updater is host-owned publication, not internet update discovery.
If the host has no validated update sidecar, Connections honestly says there
is no update; use the setup portal or manual MacBinary deployment instead.

To roll back, quit NOW, remove the replacement, and restore the retained item
from the Trash under its canonical name and Finder type. Restart
after any Extension rollback. When the wire contract revision changes, restore
the host and guest as one rollback set rather than mixing revisions.

To remove NOW, delete the host and guest applications; also remove NOW
Extension from the System Folder and restart if it was installed.

## Expected result

The guest reports the exact host-published build, verifies it before replacing
anything, and either installs it or retains a precise refusal. Extension
activation always remains pending until restart.

## Recovery

If the classic Mac cannot boot after an extension change, start with Extensions
disabled, remove NOW Extension, and return to the non-resident product shape.

The updater never relaunches the guest automatically. After application
replacement, quit the old instance and launch the canonical **New Old World**
copy manually. The rollback file remains in the Trash.
