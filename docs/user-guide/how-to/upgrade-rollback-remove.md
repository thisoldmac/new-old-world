---
page_id: lifecycle-how-to
title: Upgrade, roll back, or remove NOW
description: Install host-published guest or Extension builds, retain rollback artifacts, or remove NOW without leaving the optional extension behind.
doc_type: how-to
audience: operator
lifecycle: current
authority: [contract/asyncapi.yaml, contract/product_version.h, contract/resident_version.h, docs/naming.md, docs/resident-components.md]
source_dependencies: [contract/asyncapi.yaml, contract/product_version.h, contract/resident_version.h, docs/naming.md, docs/resident-components.md, docs/distribution-profile.yaml, now-host/Sources/Host/UpdateProvider.swift, now-guest-ppc/src/update, now-guest-ppc/src/core/prefs.c]
media_ids: []
last_verified: 2026-08-13
---

# Upgrade, roll back, or remove NOW

## Goal

Change versions without creating a host/guest contract mismatch or forgetting
the optional resident component.

## Update the PowerPC application

1. Install a release host or build the modern host together with the PowerPC
   artifact it should publish. A release host uses the exact guest assets
   embedded inside its app before signing; a development override is explicit.
2. Connect the PowerPC guest and open its **Connection** page.
3. Read the Application row under **Updates from the other Mac**. The row
   compares both release version and exact build identity, so a different
   scratch build of the same version is still shown.
4. Choose **Install App**. Development artifacts currently have a SHA-256
   integrity check but no release signature; confirm the unsigned-build warning
   only if this is the host and build you intended to trust.
5. Let the transfer complete. The guest verifies the exact MacBinary stream,
   exchanges the new application with the running copy, quits cleanly, and asks
   Process Manager to launch the replacement. The old application bytes remain
   beside it as **New Old World Update** for rollback.
6. After reconnection, verify the exact build shown by Connections and exercise
   one capability. A completed download alone is not behavioral verification.

## Update the NOW Extension

1. In the same Connection page, read the Extension row. If the active Extension
   version differs from the application expectation, NOW shows a warning even
   before a replacement is installed.
2. Choose **Install Extension** and, for a development build, confirm the
   unsigned-build warning.
3. After the guest reports installation, restart the classic Mac. An INIT is
   not active until boot; do not judge resident behavior before restarting.
4. Reopen NOW and confirm that the mismatch warning is gone and the resident
   capabilities you use are available.

The Extension receipt is durable. Quitting or replacing the guest application
does not erase **restart required**; the receipt clears only after a later boot
reports the installed Extension build as the active resident.

Application and Extension are separate buttons and separate results. For a
release, update the application first, let it relaunch and reconnect, then
update the Extension and restart. During iterative development you may update
the Extension first, update the application second, and perform one final
restart. NOW does not enforce either order or combine the actions.

The previous resident bytes are retained under the staging name and changed
to a non-INIT Finder type, so they cannot load alongside the replacement.

## Manual fallback and rollback

The in-app updater is host-owned publication, not internet update discovery.
If the host has no validated update sidecar, Connections honestly says there
is no update; use the setup portal or manual MacBinary deployment instead.
If the connected host carries an older component than the one installed, NOW
reports it as older and leaves its Install button unavailable. It never treats
that condition as permission to downgrade. Host self-update remains future
work until canonical deployed releases have a trust and channel policy.

To roll back, quit NOW, remove the replacement, and restore the retained
application or Extension under its canonical name and Finder type. Restart
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

If application relaunch does not complete, launch the canonical **New Old
World** copy manually. The exchanged rollback file remains in the same folder.
