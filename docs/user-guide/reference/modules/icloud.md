---
page_id: icloud-module-reference
title: iCloud module
description: Serve explicitly granted iCloud Drive, Photos, and Contacts data from the modern Mac to the PowerPC guest.
doc_type: reference
audience: user
lifecycle: experimental
authority: [docs/icloud.md, contract/asyncapi.yaml]
module_ids: [icloud]
source_dependencies: [docs/icloud.md, contract/asyncapi.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/cloud]
media_ids: [icloud-host, icloud-ppc, icloud-detail]
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# iCloud module

## What it does

iCloud projects selected modern-Mac services to the PowerPC Workshop: Drive
listings and downloads, Photos listings and previews, and Contacts cards.

![The macOS iCloud service and grant surface](../../../assets/screenshots/modules/icloud/host.svg){ .now-placeholder }

## Availability

The host serves this family and the PowerPC iCloud page asks for it. NOW-68K
does not expose iCloud.

## On the modern Mac

The host owns platform permissions, service availability, paging, preview
conversion, and explicit refusal when a service is not granted.

## On the classic Mac

The PowerPC page browses one service at a time and requests detail only after a
selection. It never receives the host library wholesale.

![The PowerPC iCloud page](../../../assets/screenshots/modules/icloud/ppc.svg){ .now-placeholder }

## Common tasks

- Grant only the service needed on the host.
- Select a Drive item, photo, or contact before asking for detail or download.

![A selected contact card or photo preview](../../../assets/screenshots/modules/icloud/detail.svg){ .now-placeholder }

## Safety, consent, and privacy

Drive paths, photos, and contacts are private data. Host permission is a real
boundary; an unavailable or ungranted service must refuse, not appear empty.

## Failure states

Permission denied, service disabled, item stale, preview unavailable, page
expired, and transfer busy retain different explanations.

## Current limitations

Messages is designed but not shipped. Real-library proof differs by service;
read the detailed verification section in the engineering record.

## For developers

See [iCloud design and verification](../../../icloud.md) and
[host architecture](../../../developer-guide/architecture/host.md).
