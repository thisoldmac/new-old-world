---
page_id: dev-reference-distribution-standard
title: Distribution and bundle standard
description: The authority for release outputs, licensed inputs, component composition, and guest deployment policy.
doc_type: reference
audience: developer
lifecycle: current
authority: [docs/feature-catalog.yaml, docs/distribution-profile.yaml]
source_dependencies: [docs/feature-catalog.yaml, docs/distribution-profile.yaml, docs/developer-guide/architecture/updating.md, docs/resident-components.md, tools/docs-gate, tools/write-update-manifest.py]
media_ids: []
last_verified: 2026-08-13
---

# Distribution and bundle standard

This page defines one bundle as a recorded set of product components, external
licensed inputs, containers, and evidence. It is the distribution authority;
it does not make product-feature or protocol decisions.

## Authority boundaries

`docs/feature-catalog.yaml` owns which product features the active release
includes, bundles as optional, or excludes. `docs/distribution-profile.yaml`
maps those feature IDs into concrete release outputs and adds non-product
inputs such as CarbonLib. The documentation gate requires every catalog
feature to have exactly one component row and derives its state from the
catalog. The distribution profile therefore does not carry a second copy of
the feature state.

The wire contract and component version headers remain authoritative for
compatibility and identity. This standard owns only what the release contains,
how its exact bytes are recorded, and which deployment choices are supported.

## Terms

- A **product release** is the exact source revision, toolchain identity,
  component builds, licensed inputs, outputs, manifest, and checksums recorded
  together.
- A **DMG** is the modern-Mac delivery container. Its host application is final
  only after embedded resources are assembled and the application is signed.
- The **embedded app resources** are the sealed onboarding catalog inside the
  host application. They are the release baseline for setup and update.
- A **generic classic image** is a MacBinary-wrapped disk image with no
  machine-specific preferences. A host-created personalized image is a derived
  onboarding artifact, not a generic release output.
- A **loose component** is one canonical MacBinary plus its adjacent
  `.now-update.json` sidecar. The pair is the update publication unit.
- The **release manifest** records identities, composition, provenance, and
  exact digests. `SHA256SUMS` is the transport-friendly checksum projection of
  the public outputs.

## Required outputs

Every alpha distribution produces these surfaces from the same recorded
component bytes:

| Output | Contract |
| --- | --- |
| macOS DMG | Contains the finalized New Old World host application and its embedded onboarding resources. |
| Embedded app resources | Contains the PPC application, NOW Extension, their update metadata, and the approved CarbonLib installer package. |
| Generic classic `.img.bin` | Contains the PPC application, optional NOW Extension, and the approved CarbonLib installer package; contains no personalized preferences. |
| Loose application + sidecar | `New Old World.bin` and `New Old World.bin.now-update.json`. |
| Loose Extension + sidecar | `NOW Extension.bin` and `NOW Extension.bin.now-update.json`. |
| Release evidence | `release-manifest.json` and `SHA256SUMS`. |

The embedded catalog and generic image must resolve the same PPC application,
Extension, and CarbonLib input identities as the release manifest. Repacking a
MacBinary may change artifact bytes without changing the component build; the
manifest records both identities rather than treating filenames as proof.

## Component and licensed-input policy

The active feature catalog is the only place to read each product feature's
release state. The gate refuses a distribution profile that keeps shipping an
artifact after its feature becomes excluded, or that fails to place an
included or optional feature in any output. Under the current catalog, the PPC
application and Extension rows carry outputs while the retained NOW-68K row
does not. CodeKitten is an explicit excluded input and is not admitted by
convenience or directory discovery.

CarbonLib 1.6 is an approved external licensed release input. It stays outside
Git. Release assembly may admit only the configured, checksum-pinned Apple
installer with its original bytes, provenance, installer agreement, and license
material intact. The installer remains a separate user-run package; NOW does
not extract CarbonLib into its own application or silently install it. A person
accepts Apple's installer license on the classic Mac.

CarbonLib 1.6 is the supported and tested runtime floor. That product support
statement must not be rewritten as a claim that every current binary import
requires 1.6 merely to load; lower-runtime behavior remains experimental until
verified on those exact systems.

## Guest deployment policy

Application and Extension replacement are independent actions with separate
controls and results. The documented release order is application first,
reconnect and verify, then Extension and reboot. Ordering is not enforced:
Extension first, application second, and one final reboot is a supported
iterative-development sequence.

An older bundled component is reported as older and cannot be installed as an
implicit downgrade. Explicit downgrade and rollback policy is separate future
work. Host self-update is also deferred until canonical deployed releases have
a trust and channel policy; the current host may warn that it is stale but does
not fetch or replace itself.

Installing the Extension never claims activation before reboot. Installing the
application requires the replacement to relaunch and identify itself before
the host treats that action as complete. The detailed transfer, consent,
identity, and exchange rules live in [Host-owned updates](../architecture/updating.md).

## Evidence and refusal

The future release assembler must fail closed on unknown inputs, unexpected
files, stale or mismatched sidecars, altered licensed bytes, missing license
material, mixed source revisions, and mutation after signing. The manifest
must make each input's source class, filename, version/build identity, artifact
digest, provenance, and license-acceptance requirement inspectable.

This standard defines that acceptance contract. It does not claim the release
assembler, static classic image, signing pipeline, or host self-updater already
exists.
