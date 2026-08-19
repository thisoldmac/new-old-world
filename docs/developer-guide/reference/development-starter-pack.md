---
page_id: dev-reference-development-starter-pack
title: Development starter pack
description: How an operator supplies an MPW payload that NOW pins, delivers, and qualifies without redistributing Apple software.
doc_type: reference
audience: developer
lifecycle: experimental
authority: [now-host/Sources/Host/OnboardingAssets.swift, packaging/development-starter-pack/Development Starter Pack.manifest.json]
source_dependencies: [now-host/Sources/Host/OnboardingAssets.swift, now-host/Sources/Host/OnboardingDependencies.swift, now-host/Sources/Host/ClassicSetupImageBuilder.swift, now-guest-ppc/src/development/development_toolchain_mac.c, packaging/development-starter-pack/Development Starter Pack.manifest.json, docs/development.md]
media_ids: []
last_verified: 2026-08-18
---

<!-- now-doc-provenance: generated reviewed=false -->

# Development starter pack

The starter pack is a portable, **operator-supplied** HFS image carried by
the onboarding setup image beside CodeKitten. NOW never bundles, downloads,
or redistributes MPW or any other Apple software: the operator places their
own copy in the host's Application Support drop, and NOW pins its exact
bytes, delivers it to the PowerPC guest, and qualifies the result. This is
the same boundary the CarbonLib release input draws — the artifact and its
license stay outside Git, and the manifest records what the operator
supplied and where it came from.

The pack is not a machine-specific `Lab` folder and it does not
pre-register a toolchain. After copying or mounting the pack on a classic
Mac, a person selects its MPW folder in NOW's Projects page; NOW qualifies
that directory on that machine and mints a fresh opaque toolchain identity.

## Supply your own MPW

Apple later distributed MPW as a free download, so an operator can hold a
legitimately obtained copy — the archived Apple tools page is the
provenance URL the template records. Free availability is not a
redistribution right, so the manifest's `license.redistribution` stays
`unknown` and NOW refuses to ship the payload in any release output.

1. Wrap or keep your MPW disk image as one MacBinary file, for example
   `Development Starter Pack.img.bin` containing a mountable HFS image
   with the MPW folder inside.
2. Copy the template from
   `packaging/development-starter-pack/Development Starter Pack.manifest.json`
   and fill in the two artifact measurements from your own file:

    ```bash
    stat -f %z "Development Starter Pack.img.bin"
    ```

    ```bash
    shasum -a 256 "Development Starter Pack.img.bin"
    ```

    Put the byte count in `artifactBytes` and the lowercase digest in
    `artifactSHA256`. The checked-in template's zero measurements are
    deliberately unshippable.
3. Place both files in the host's onboarding drop, in
   `~/Library/Application Support/New Old World/Onboarding/Dependencies/`
   (the Onboarding window opens this folder).

The setup-image build validates the pair before producing an image: a
missing artifact, a second manifest, a byte-count or SHA-256 mismatch, or a
qualification claim the product does not implement all refuse the build
with a named reason.

## Delivery to the guest

The setup image is the NDIF/PPC lane: the pack rides the image's
`Dependencies` folder, decoded to its classic name, and the Read Me gains a
registration instruction when a validated pack is present. The manifest
itself is host validation metadata and never crosses to the guest. The
image is bounded at 128 MB; Apple's MPW GM image is roughly 25 MB, so a
full pack fits beside the application, Extension, and CarbonLib installer.
MPW does not fit the floppy-sized media a 68K bootstrap uses, so there is
no 68K starter-pack lane.

For an already-connected guest, the guest-files upload lane
(`now_guest_files_upload_begin` / `append` / `commit`) can carry the same
MacBinary image directly instead of rebuilding setup media.

**Copy the MPW folder to a writable disk before registering it.** Mounting
the pack is not enough: a ToolServer launched from the read-only pack
volume cannot run its own tools, and the build fails on its first action
with status −1 and an empty transcript. The same tools copied to the hard
disk build normally. This was measured four ways on one emulator guest and
the matrix is in [open issues](../../open-issues.md); the setup image's
Read Me carries the same instruction whenever a validated pack is present.

## Qualification is the guest's, and the manifest may not overclaim

The manifest's `qualification.probe` must name a probe the product
implements, and `requiredItems` must be exactly the items that probe
measures. Today that set is one entry:

| Probe | Measured items | Where |
|---|---|---|
| `structural-1` | `ToolServer` (file) and `Tools:MrC` (file inside the `Tools` folder), immediate children of the registered folder | `now-guest-ppc/src/development/development_toolchain_mac.c` |

A manifest naming any other probe, or claiming items `structural-1` never
checks, is refused. This keeps `now_development_environment` honest: the
rows it relays — toolchain identity, qualification verdict, ToolServer and
MrC presence — are the same measurements the manifest promised, performed
by the guest on the human-registered folder. `not found` there means "not
measured in the registered folder"; the guest never scans volumes for MPW
and delivery of a pack does not register anything by itself.

## Initial platform matrix

| Guest | Useful initial toolchain | What the pack may ship |
|---|---|---|
| System 7.1–7.6, 68K | MPW with 68K C/Rez/linker and matching Universal Interfaces | Operator-supplied only until exact Apple redistribution terms for every component are archived and reviewed. Qualify on a 68K guest; a PPC qualification is not evidence. |
| System 7.1.2–8.6, PowerPC | MPW with PPC C/Rez/PPCLink and matching interfaces/libraries | Operator-supplied only under the same license gate. This is the current NOW guest-native backend. |
| Mac OS 8.6–9.2.2, PowerPC/CarbonLib | MPW plus Universal Interfaces containing the intended CarbonLib surface | Operator-supplied only; qualify compiler, linker, ToolServer and target interfaces together. |
| Mac OS 8.1–9.2.2, PowerPC | CodeWarrior 6/7 can target classic and Carbon applications | Do not redistribute: contemporary releases were commercial per-seat products. CodeKitten may eventually drive a human-installed copy through a separate backend. |

Apple later made MPW available without purchase, but that does not by
itself establish a current right to redistribute every compiler, SDK,
sample and third-party component in a new bundle. The manifest therefore
keeps redistribution as `unknown` until the exact archived license for the
exact payload is recorded. CodeWarrior remains proprietary and is not a
starter-pack payload.

The matrix is intentionally about a useful baseline, not universal
coverage. One PPC MPW qualification does not establish that its tools
target every 68K system, and a System 7 build does not imply CarbonLib
compatibility.

## Fixture provenance

Every VM or metal receipt using the pack records:

- base-image SHA-256;
- starter-pack manifest and artifact SHA-256;
- anchor-policy digest;
- guest build and resident fingerprint;
- independently qualified worker and toolchain identities.

No absolute host path, HFS directory ID, or registration from another
machine belongs in the manifest or receipt.

## Research sources

- Apple's archived Carbon Porting Guide documents CarbonLib availability and
  CodeWarrior 8's Mac OS 9 target support:
  <https://leopard-adc.pepas.com/documentation/Carbon/Conceptual/carbon_porting_guide/carbonporting.pdf>.
- Metrowerks' CodeWarrior 7 release was sold per license and targeted classic
  Mac OS, Carbon and Mac OS X:
  <https://www.macworld.com/article/162846/metrowerks-3.html>.
- MPW's last release and later free-download history are summarized at
  <https://en.wikipedia.org/wiki/Macintosh_Programmer%27s_Workshop>; this is
  historical availability evidence, not a redistribution license.
