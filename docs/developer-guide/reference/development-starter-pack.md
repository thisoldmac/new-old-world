---
page_id: dev-reference-development-starter-pack
title: MPW and the development starter pack
description: How NOW fetches, pins, and delivers MPW to a classic Mac as an optional onboarding dependency.
doc_type: reference
audience: developer
lifecycle: experimental
authority: [now-host/Sources/Host/OnboardingDependencies.swift, now-host/Sources/Host/OnboardingAssets.swift, packaging/development-starter-pack/Development Starter Pack.manifest.json]
source_dependencies: [now-host/Sources/Host/OnboardingAssets.swift, now-host/Sources/Host/OnboardingDependencies.swift, now-host/Sources/Host/ClassicSetupImageBuilder.swift, now-guest-ppc/src/development/development_toolchain_mac.c, packaging/development-starter-pack/Development Starter Pack.manifest.json, docs/development.md]
media_ids: []
last_verified: 2026-08-19
---

<!-- now-doc-provenance: generated reviewed=false -->

# MPW and the development starter pack

MPW is an **optional onboarding dependency**, handled exactly the way
CarbonLib is: the host fetches one checksum-pinned artifact on request,
saves it in the operator's Application Support drop, and builds it into the
personalized setup image. No MPW bytes live in this repository and no
release output carries them.

| | |
|---|---|
| Catalog id | `mpw-gm` |
| Download | `https://old.mac.gdn/apps/mpw-gm.img__0.bin` |
| Source page | [Macintosh Garden](https://macintoshgarden.org/apps/macintosh-programmers-workshop) |
| SHA-1 | `2a57aa9364a165ea0ddfa0611003ee1f13984715` |
| Saved as | `Dependencies/mpw-gm.img.bin` |
| Delivery | unchanged — the download is already a MacBinary NDIF image |
| On the setup image | `Dependencies/MPW-GM.img`, forks and `rohd`/`ddsk` intact |

Press **Get** beside MPW in the Onboarding window, or drop an equivalent
file into `~/Library/Application Support/New Old World/Onboarding/
Dependencies/` yourself. The checksum is verified before the file is
written; a mismatch refuses with both digests named. The classic download
page offers the same artifact, and lists the source page when the host does
not have it yet.

Nothing pre-registers a toolchain. On the classic Mac a person opens the
image, copies the MPW folder to the hard disk, and selects that folder in
NOW's Projects page; the guest qualifies it there and mints a fresh opaque
toolchain identity.

## A generic operator-supplied pack

`now.development-starter-pack/1` remains for a payload that is not the
pinned MPW image — a curated pack an operator assembles themselves. It is a
manifest plus a digest-pinned artifact in the same `Dependencies/` folder,
and the setup-image build refuses a missing artifact, a second manifest, a
byte-count or SHA-256 mismatch, or a qualification claim the product does
not implement. The checked-in template lives at
`packaging/development-starter-pack/Development Starter Pack.manifest.json`
and its zero artifact measurements are deliberately unshippable.

## Delivery to the guest

The setup image is the NDIF/PPC lane: MPW rides the image's `Dependencies`
folder under its classic name, and the Read Me gains registration
instructions whenever the image carries it. A starter-pack manifest is host
validation metadata and never crosses to the guest. The image is bounded at
128 MB; the MPW GM image is roughly 25 MB, so it fits beside the
application, Extension, and CarbonLib installer. MPW does not fit the
floppy-sized media a 68K bootstrap uses, so there is no 68K lane.

For an already-connected guest, the guest-files upload lane
(`now_guest_files_upload_begin` / `append` / `commit`) can carry the same
MacBinary image directly instead of rebuilding setup media.

**Copy the MPW folder to a writable disk before registering it.** Mounting
the image is not enough: a ToolServer launched from the read-only volume
cannot run its own tools, and the build fails on its first action with
status −1 and an empty transcript. The same tools copied to the hard disk
build normally. This was measured four ways on one emulator guest and the
matrix is in [open issues](../../open-issues.md); the setup image's Read Me
carries the same instruction whenever it carries MPW.

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
| System 7.1–7.6, 68K | MPW with 68K C/Rez/linker and matching Universal Interfaces | Not a lane yet: MPW does not fit 68K bootstrap media. Qualify on a 68K guest before claiming it; a PPC qualification is not evidence. |
| System 7.1.2–8.6, PowerPC | MPW with PPC C/Rez/PPCLink and matching interfaces/libraries | The pinned `mpw-gm` download covers this, and it is the current NOW guest-native backend. |
| Mac OS 8.6–9.2.2, PowerPC/CarbonLib | MPW plus Universal Interfaces containing the intended CarbonLib surface | Same download; qualify compiler, linker, ToolServer and target interfaces together. |
| Mac OS 8.1–9.2.2, PowerPC | CodeWarrior 6/7 can target classic and Carbon applications | Do not redistribute: contemporary releases were commercial per-seat products. CodeKitten may eventually drive a human-installed copy through a separate backend. |

Apple later made MPW available without purchase, which is why it can be
fetched the way CarbonLib is. That is not the same as a right to
redistribute it: nothing here is committed to Git or placed in a release
output, and a generic pack's manifest keeps `redistribution` as `unknown`
until the exact archived license for its exact payload is recorded.
CodeWarrior remains proprietary and is not a payload at all.

The matrix is intentionally about a useful baseline, not universal
coverage. One PPC MPW qualification does not establish that its tools
target every 68K system, and a System 7 build does not imply CarbonLib
compatibility.

## Fixture provenance

Every VM or metal receipt using the pack records:

- base-image SHA-256;
- the artifact SHA-1 the catalog pins, or a pack manifest's SHA-256;
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
