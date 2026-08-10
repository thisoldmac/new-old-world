---
page_id: transfer-file-how-to
title: Transfer a file
description: Send one file between the modern and classic Macs while preserving the declared destination and transfer outcome.
doc_type: how-to
audience: user
lifecycle: current
authority: [docs/files.md, contract/asyncapi.yaml]
source_dependencies: [contract/asyncapi.yaml, now-host/Sources/Host, now-guest-ppc/src/files, now-guest-68k/src/files]
media_ids: [setup-transfer, files-detail]
last_verified: 2026-08-09
---

# Transfer a file

## Goal

Move one known file through the Files module and verify the receiver completed
it.

## Steps

1. Open **Files** for the intended named classic Mac.
2. Choose the destination inside the receiver's published share.
3. Start the transfer from the sender's Files surface.
4. Keep the session connected until the receiver reports completion; sender
   progress alone does not prove the file was written and stamped.
5. Refresh the destination and verify the expected name and fork/container
   posture.

![A transfer showing its source, destination, and receiver-backed progress](../../assets/screenshots/getting-started/file-transfer.svg){ .now-placeholder }

![Safe file actions for the selected item](../../assets/screenshots/modules/files/detail.svg){ .now-placeholder }

## Expected result

The destination listing contains the file and the transfer has a terminal
receiver result.

## Recovery

Cancel from either face if the transfer is no longer wanted. For an interrupted
transfer, keep any partial/resume state until the next offer proves it refers
to the same source; do not manually rename a partial file into place.
