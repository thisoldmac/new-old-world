---
page_id: dev-workflow-sheepshaver-86
title: SheepShaver 8.6 UI oracle
description: Build and operate a reproducible Mac OS 8.6 plus CarbonLib 1.6 oracle for fast PowerPC Carbon UI iteration.
doc_type: how-to
audience: operator
lifecycle: current
authority: [AGENTS.md, docs/guest-ui-start-here.md]
source_dependencies: [scripts/sheepshaver-86, tools/sheepshaver-86-tests, .env.lab.example, now-guest-ppc]
media_ids: []
last_verified: 2026-08-11
---
# SheepShaver 8.6 UI oracle

Use this lane for fast UI iteration at NOW's minimum Carbon floor: PowerPC
CFM, Mac OS 8.6, and CarbonLib 1.6. It runs the real guest application and
the real classic Toolbox. It is therefore a substantially better UI oracle
than the host renderer, but it is still emulator-observed rather than
metal-verified.

Keep the roles distinct:

- SheepShaver 8.6 plus CarbonLib 1.6 is the default Carbon UI oracle.
- QEMU `mac99` remains the full-stack lane and the explicit Mac OS 9.1+
  reference.
- Basilisk II is the future profile-driven 68K UI lane. Apply the isolation,
  transfer, identity, and evidence patterns from this harness when it lands.

## What the repository owns

The repository owns only the harness and its tests. It does not fetch or
redistribute SheepShaver, a New World ROM, Mac OS, or CarbonLib. Put paths to
developer-supplied inputs in `.env.lab`; never add those inputs to the tree.

The first verified host build used the maintained
`kanjitalk755/macemu` tree at commit
`efefb991ecfff91e9f5b0e63a52cfecabfee3aae` (2026-08-09). On Xcode 27,
Autoconf selected GNU C23 by default and the bundled slirp K&R definitions
failed in `slirp/ip_output.c`. Pinning C17 was the required build seam:

```sh
cd SheepShaver/src/Unix
env CFLAGS=-std=gnu17 ./configure \
  --with-gtk=no --disable-jit --enable-ppc-emulator=yes \
  --enable-sdl-video --enable-sdl-audio
make -j8
make SheepShaver_app
```

That recipe produced a native arm64 app. Its Homebrew SDL compatibility and
VDE dynamic libraries make this a lab build, not a self-contained shipping
artifact.

## Profile contract

Use one dedicated `.sheepvm` directory containing:

```text
Mac OS 8.6.sheepvm/
  prefs
  Mac OS ROM
  Mac OS 8.6.hfv
  CarbonLib 1.6 Transfer.hfv
  Shared/
  Snapshots/
```

The verified profile uses a 2 GiB HFS+ boot disk, a 32 MiB HFS transfer
disk, 128 MiB RAM, an 800 by 600 software-rendered window, slirp networking,
and JIT disabled. Preserve a stopped, clean base-OS snapshot before installing
CarbonLib, then another after CarbonLib 1.6 is proven by the NOW guest.

Record ROM and installation-media hashes in the local run receipt. A filename
or a booting desktop does not prove which inputs produced the guest.

## Operate it

Configure `.env.lab`, then run:

```sh
scripts/sheepshaver-86 doctor
scripts/sheepshaver-86 stage "path/to/New Old World.bin"
scripts/sheepshaver-86 launch
scripts/sheepshaver-86 snapshot "Mac OS 8.6 + CarbonLib 1.6"
```

`stage` accepts a MacBinary artifact and passes it to `hcopy -m`, preserving
both forks plus Finder type and creator. It refuses while SheepShaver has the
transfer image open. Never host-mount or host-write an HFS image concurrently
with the guest.

Do not run classic applications or installers from SheepShaver's Unix shared
folder. The CarbonLib SMI wrapper reached the Finder through ExtFS but failed
with error `-8812`: the file system cannot carry the execution semantics it
requires. A real HFS transfer disk is the reusable boundary.

## CarbonLib installation has two layers

Opening `CarbonLib 1.6.smi` and accepting its license only mounts the
self-mounting image. Open the mounted `CarbonLib` disk and run
`Apple SW Install`; that second application performs the system update. The
decisive negative control was the NOW guest itself: before the second updater
ran, Finder refused it because `CarbonLib` could not be found.

After the updater finishes, shut the guest down cleanly, relaunch it, and open
the staged `New Old World`. Seeing the Workshop proves the application loaded
against CarbonLib in this profile. It does not prove hardware behavior.

## UI automation seams

The guest framebuffer exposes no useful macOS accessibility tree. Automation
is screenshot-and-coordinate driven and must re-observe after any human input.
At 800 by 600, these interactions were repeatable during bring-up:

- Open a Finder item by selecting it, refreshing observed state, then sending
  Command-O. Synthetic double-click and Return were unreliable.
- Stabilize text-field focus with a click and fresh observation before typing;
  otherwise the first characters can be dropped.
- Shut down from Finder by dragging from the Special menu title to Shut Down,
  then clicking the selected item immediately, without an observation between
  the drag and click. A state refresh dismisses the menu.

Coordinates are profile-specific evidence, not a durable API. The harness
should grow toward semantic guest-side controls or deterministic framebuffer
recognition before unattended installation is treated as reliable.

## Evidence status

Use the repository's verification vocabulary:

- A successful cross-build means the PowerPC guest **builds**.
- A visible Workshop in this profile is **emulator-observed on Mac OS 8.6 with
  CarbonLib 1.6**.
- Only a run on the PowerBook is **metal-verified**.

Capture the source revision, profile/input hashes, staged artifact build ID,
and a screenshot together. An attractive desktop without those identities is
reference material, not attributable verification.
