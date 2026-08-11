---
title: Development starter pack
type: reference
status: experimental
---

<!-- now-doc-provenance: generated reviewed=false -->

# Development starter pack

The starter pack is a portable, operator-supplied HFS image carried by the
onboarding setup image beside CodeKitten. It is not a machine-specific `Lab`
folder and it does not pre-register a toolchain. After copying or mounting the
pack on a classic Mac, a person selects its MPW folder in NOW; NOW qualifies
that directory on that machine and mints a fresh opaque toolchain identity.

Place these two files in the relocatable onboarding input's `Dependencies/`
folder:

- `Development Starter Pack.img.bin`
- `Development Starter Pack.manifest.json`

The manifest uses `now.development-starter-pack/1` and binds the artifact's
name, byte count and SHA-256. It also records supported guest OS versions and
architectures, every component's installed size, provenance and redistribution
status, and a closed qualification probe. The onboarding build refuses an
absent, mismatched or malformed pack before producing an image. The checked-in
manifest under `packaging/development-starter-pack/` is a template; its zero
artifact measurements are intentionally not shippable.

## Initial platform matrix

| Guest | Useful initial toolchain | What the pack may ship |
|---|---|---|
| System 7.1–7.6, 68K | MPW with 68K C/Rez/linker and matching Universal Interfaces | Operator-supplied only until exact Apple redistribution terms for every component are archived and reviewed. Qualify on a 68K guest; a PPC qualification is not evidence. |
| System 7.1.2–8.6, PowerPC | MPW with PPC C/Rez/PPCLink and matching interfaces/libraries | Operator-supplied only under the same license gate. This is the current NOW guest-native backend. |
| Mac OS 8.6–9.2.2, PowerPC/CarbonLib | MPW plus Universal Interfaces containing the intended CarbonLib surface | Operator-supplied only; qualify compiler, linker, ToolServer and target interfaces together. |
| Mac OS 8.1–9.2.2, PowerPC | CodeWarrior 6/7 can target classic and Carbon applications | Do not redistribute: contemporary releases were commercial per-seat products. CodeKitten may eventually drive a human-installed copy through a separate backend. |

Apple later made MPW available without purchase, but that does not by itself
establish a current right to redistribute every compiler, SDK, sample and
third-party component in a new bundle. The manifest therefore keeps
redistribution as `unknown` until the exact archived license for the exact
payload is recorded. CodeWarrior remains proprietary and is not a starter-pack
payload.

The matrix is intentionally about a useful baseline, not universal coverage.
One PPC MPW qualification does not establish that its tools target every 68K
system, and a System 7 build does not imply CarbonLib compatibility.

## Fixture provenance

Every VM or metal receipt using the pack records:

- base-image SHA-256;
- starter-pack manifest and artifact SHA-256;
- anchor-policy digest;
- guest build and resident fingerprint;
- independently qualified worker and toolchain identities.

No absolute host path, HFS directory ID, or registration from another machine
belongs in the manifest or receipt.

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
