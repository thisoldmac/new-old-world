---
page_id: limitations-reference
title: Current limitations
description: The short, release-facing list of NOW alpha limitations and narrower verification boundaries.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/status.md, docs/known-wrong.md, docs/open-issues.md, SECURITY.md]
source_dependencies: [docs/status.md, docs/known-wrong.md, docs/open-issues.md, SECURITY.md, product/features.yaml, docs/distribution-profile.yaml, docs/onboarding.md, docs/development.md]
media_ids: []
last_verified: 2026-08-13
---

<!-- now-doc-provenance: generated reviewed=false -->

# Current limitations

- **Trusted network only.** The classic wire is plaintext and unauthenticated;
  the host listener must not be internet-facing.
- **Alpha packaging.** A fail-closed assembler now produces the signed host
  DMG, embedded classic catalog, generic `.img.bin`, loose update pairs,
  release manifest, and checksums from one recorded component set. A real
  release still needs its licensed CarbonLib descriptor, signing identity, and
  release-commit review. Classic updates remain unsigned, and website
  integration, notarization, internet update discovery, and host self-update
  are not implemented.
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
- **MPW is fetched, not shipped.** No release output contains Apple's
  developer tools; the host downloads one checksum-pinned image on request
  and a personalized setup image carries it. Registration on the classic Mac
  stays a human act, and it must name the copy on the hard disk — a
  toolchain registered on the mounted image cannot build.
- **Chat's workspace lane is the one power this app does not audit.** On by
  default and reversible in Settings > Chat, it lets a turn typed at the
  classic machine spawn a Claude runtime with its own file and command tools
  in New Old World's own folder on the modern Mac. That folder's own policy
  governs those tools, not this app's per-capability consent; the New Old
  World half of the same turn is audited as before. Emulator-verified only.
- **Hardware evidence is specific.** A result on the PowerBook 1400c does not
  prove the PowerBook 180c path, and emulator evidence is not metal evidence.
- **Classic platform recovery matters.** The optional extension must remain
  removable by booting with Extensions disabled.

For the exhaustive current account, read [status](../../status.md),
[known-wrong behavior](../../known-wrong.md), and the
[open-issues ledger](../../open-issues.md).
