---
page_id: limitations-reference
title: Current limitations
description: The short, release-facing list of NOW alpha limitations and narrower verification boundaries.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/status.md, docs/known-wrong.md, docs/open-issues.md, SECURITY.md]
source_dependencies: [RELEASING.md, docs/status.md, docs/known-wrong.md, docs/open-issues.md, SECURITY.md, docs/feature-catalog.yaml, docs/onboarding.md, docs/development.md]
media_ids: []
last_verified: 2026-08-10
---

# Current limitations

- **Trusted network only.** The classic wire is plaintext and unauthenticated;
  the host listener must not be internet-facing.
- **Alpha packaging.** The repository does not yet have one command that
  assembles, provenance-checks, and inventories the complete downloadable
  alpha bundle. Do not describe a hand-built folder as reproducible. The
  connected host can publish validated guest and Extension artifacts, but they
  remain unsigned and the flow is not an internet updater, notarization flow,
  or download service. See [the release procedure](../../../RELEASING.md).
- **Guided setup is not yet metal-verified.** Its routes and media builders are
  tested and the image mounts in Mac OS 9.1 QEMU, but a classic-browser
  download, automatic decoding, and first physical-hardware hello have not
  completed as one verified path.
- **PowerPC-only alpha.** The NOW-68K/pre-Carbon build is currently stale and
  excluded from the alpha. Its source and contributor
  documentation remain, but are not a support or packaging promise.
- **Optional Extension.** The NOW Extension is required only for the deeper
  Mirror features listed in the [feature coverage
  matrix](../explanation/core-features.md#feature-coverage), including
  live interface structure, guarded interaction, modal-loop reachability,
  remote drag sessions, and cursor following. Ordinary modules remain
  available without it at their declared levels.
- **Mirror remains experimental.** Finder and application-window interiors
  have narrower evidence and known incomplete behaviors. An unavailable
  Extension feature is not evidence that a window has no content.
  Human requests now outrank queued ambient reads at safe boundaries and
  invalidation hints trigger coalesced refresh, but running guest work is not
  preempted and the PowerBook latency target remains unverified.
- **File resume remains narrower than basic transfer.** The repository records
  resume-by-offset hangs even where ordinary transfers are proven.
- **Development is not yet a fully autonomous loop.** A host-owned project can
  build and launch through MPW on the PowerBook, but guest-home promotion,
  typed test receipts, CodeKitten document acceptance, and reliable semantic
  UI settlement after launch remain incomplete or unverified.
- **Hardware evidence is specific.** A result on the PowerBook 1400c does not
  prove the PowerBook 180c path, and emulator evidence is not metal evidence.
- **Classic platform recovery matters.** The optional extension must remain
  removable by booting with Extensions disabled.

For the exhaustive current account, read [status](../../status.md),
[known-wrong behavior](../../known-wrong.md), and the
[open-issues ledger](../../open-issues.md).
