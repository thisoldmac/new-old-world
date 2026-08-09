---
page_id: limitations-reference
title: Current limitations
description: The short, release-facing list of NOW pre-alpha limitations and narrower verification boundaries.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/status.md, docs/known-wrong.md, docs/open-issues.md, SECURITY.md]
source_dependencies: [docs/status.md, docs/known-wrong.md, SECURITY.md, docs/feature-catalog.yaml]
media_ids: []
last_verified: 2026-08-09
---

# Current limitations

- **Trusted network only.** The classic wire is plaintext and unauthenticated;
  the host listener must not be internet-facing.
- **Pre-alpha packaging.** The exact release bundle and website integration
  must be reviewed at the release commit. Do not infer an installer, updater,
  notarization flow, or download URL from source-build scripts.
- **PowerPC-only initial alpha.** The NOW-68K/pre-Carbon build is currently
  stale and excluded from the initial release. Its source and contributor
  documentation remain, but are not a support or packaging promise.
- **Optional resident.** The NOW Extension is required for its process-local
  structure, semantic, content, interaction, transition, liveness, drag, and
  cursor planes. Ordinary application-level modules remain available without
  it at their declared levels.
- **Mirror remains experimental.** Finder and application-window interiors
  have narrower evidence and known incomplete behaviors. Absence of a resident
  plane is not evidence that a window has no content.
- **File resume remains narrower than basic transfer.** The repository records
  resume-by-offset hangs even where ordinary transfers are proven.
- **Hardware evidence is specific.** A result on the PowerBook 1400c does not
  prove the PowerBook 180c path, and emulator evidence is not metal evidence.
- **Classic platform recovery matters.** The optional extension must remain
  removable by booting with Extensions disabled.

For the exhaustive current account, read [status](../../status.md),
[known-wrong behavior](../../known-wrong.md), and the
[open-issues ledger](../../open-issues.md).
