---
page_id: lifecycle-how-to
title: Upgrade, roll back, or remove NOW
description: Replace matching host and guest builds, retain rollback artifacts, or remove NOW without leaving the optional extension behind.
doc_type: how-to
audience: operator
lifecycle: current
authority: [docs/naming.md, docs/resident-components.md]
source_dependencies: [contract/asyncapi.yaml, docs/naming.md, docs/resident-components.md]
media_ids: []
last_verified: 2026-08-09
---

# Upgrade, roll back, or remove NOW

## Goal

Change versions without creating a host/guest contract mismatch or forgetting
the optional resident component.

## Steps

1. Keep the previous host app, both guest artifacts, and extension artifact as
   one rollback set.
2. Disconnect sessions and quit the host and guest applications.
3. Replace the host and the guest together when the contract revision changes.
4. If the release includes a new NOW Extension, replace it and restart the
   classic Mac before judging resident behavior.
5. Reconnect and verify the named session and one capability.
6. To roll back, restore the entire previous set rather than mixing revisions.
7. To remove NOW, delete the host and guest applications; also remove NOW
   Extension from the System Folder and restart if it was installed.

## Expected result

The machines either run a matching set or refuse the mismatch explicitly.

## Recovery

If the classic Mac cannot boot after an extension change, start with Extensions
disabled, remove NOW Extension, and return to the non-resident product shape.
