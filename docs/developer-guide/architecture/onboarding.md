---
page_id: dev-arch-onboarding
title: Onboarding and setup media
description: How the host discovers packages, generates preferences, builds a classic disk image, and serves it to old browsers.
doc_type: explanation
audience: developer
lifecycle: current
authority: [docs/onboarding.md]
source_dependencies: [docs/onboarding.md, docs/distribution-profile.yaml, now-host/Sources/Host/OnboardingPortal.swift, now-host/Sources/Host/OnboardingPage.swift, now-host/Sources/Host/OnboardingAssets.swift, now-host/Sources/Host/OnboardingDependencies.swift, now-host/Sources/Host/OnboardingPreferences.swift, now-host/Sources/Host/ClassicSetupImageBuilder.swift, now-host/Sources/Host/NDIFImage.swift, now-host/Sources/Host/MacBinaryEncoder.swift]
media_ids: []
last_verified: 2026-08-13
---

<!-- now-doc-provenance: generated reviewed=false -->

# Onboarding and setup media

Onboarding is a host-owned bootstrap path that ends at the normal NOW wire; it
is not a second application protocol. The Connections UI chooses packages and
network settings, the builder produces classic-compatible media, and a narrow
temporary HTTP server makes that media reachable to old browsers.

```mermaid
flowchart LR
  UI["Connections setup UI"] --> CAT["Package catalog\nsealed bundle then local additions"]
  UI --> PREF["Generated New Old World Prefs"]
  CAT --> DEP["Dependency acquisition and checksum gate"]
  DEP --> IMG["HFS Plus setup volume"]
  PREF --> IMG
  IMG --> NDIF["Uncompressed NDIF image"]
  NDIF --> BIN["MacBinary envelope"]
  BIN --> HTTP["Temporary HTTP/1.0 portal"]
  HTTP --> BROWSER["Classic browser"]
  BROWSER --> DISK["Disk Copy 6.3.3"]
  DISK --> GUEST["New Old World guest"]
  GUEST --> HELLO["Normal NOW hello"]
```

Text equivalent: the setup UI uses the app bundle as the release baseline,
augments it with non-conflicting user-store dependencies, generates
preferences, and passes accepted assets through the HFS Plus, NDIF, and
MacBinary builders. The temporary HTTP portal serves the
result to a classic browser; Disk Copy mounts it, and the installed guest uses
the ordinary NOW connection handshake.

## Contracts and boundaries

- The portal accepts GET and HEAD on fixed `/now` setup routes. It has no
  upload, listing, or general file-server surface.
- The browser-facing page and response framing remain HTTP/1.0 compatible.
- `New Old World Prefs` uses the classic guest's existing binary preference
  format and byte order; the onboarding code does not invent a second config
  schema.
- The volume is tight HFS Plus inside an uncompressed NDIF image, optionally
  wrapped in MacBinary so transport can preserve its classic metadata.
- The sealed app bundle is the release baseline: a stale writable application
  or Extension cannot mask it. Application Support may add dependencies that
  the release does not contain. `NOW_ONBOARDING_ASSETS` remains a deliberate
  single-root development override.
- CarbonLib is admitted to a release only as the checksum-pinned Apple
  installer named by the distribution profile, with provenance and license
  material preserved. Source acquisition cannot silently turn another file
  into that release input. Archive extraction may still use a local `unar`
  prerequisite for operator-provided development dependencies.
- The Development starter pack is operator-supplied only: NOW never
  downloads or redistributes MPW. A pack is a manifest plus a
  digest-pinned artifact in the `Dependencies` drop; the setup-image build
  refuses a malformed, mismatched, or overclaiming pair, delivers only the
  artifact, and keeps the manifest on the host. See the
  [Development starter pack](../reference/development-starter-pack.md)
  reference.

## Verification boundary

Unit tests cover routes, asset precedence, preferences, dependency checks,
starter-pack validation and its qualification-probe binding, MacBinary,
NDIF, and image construction. The setup image has mounted in a Mac
OS 9.1 QEMU guest. Classic-browser download, automatic decoding, and the first
hello from physical hardware remain unverified and must be stated that way.
