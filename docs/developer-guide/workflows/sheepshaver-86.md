---
page_id: dev-workflow-sheepshaver-86
title: SheepShaver 8.6 UI oracle
description: Build and operate a reproducible Mac OS 8.6 plus CarbonLib 1.6 oracle for fast PowerPC Carbon UI iteration.
doc_type: how-to
audience: operator
lifecycle: current
authority: [AGENTS.md, docs/guest-ui-start-here.md]
source_dependencies: [scripts/sheepshaver-86, tools/sheepshaver-86-tests, docs/lab-setup.md, now-guest-ppc]
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
scripts/sheepshaver-86 install-apps \
  "path/to/New Old World.bin" "path/to/CodeKitten.bin"
scripts/sheepshaver-86 launch
scripts/sheepshaver-86 snapshot "Mac OS 8.6 + CarbonLib 1.6"
scripts/sheepshaver-86 rig
scripts/sheepshaver-86 seal "os86-carbon16-now020-codekitten-af521a5"
```

`stage` accepts a MacBinary artifact and passes it to `hcopy -m`, preserving
both forks plus Finder type and creator. It refuses while SheepShaver has the
transfer image open. Never host-mount or host-write an HFS image concurrently
with the guest.

`rig` also requires a stopped guest. It emits a versioned record containing
the NOW revision and SHA-256 identities for the emulator executable, profile
preferences, ROM, boot disk, and transfer disk. If
`NOW_SHEEPSHAVER_SOURCE` is configured, it includes the exact macemu revision.
Attach that output to captures rather than reconstructing the rig from memory.

`install-apps` writes both MacBinary applications into the configured
Applications folder while the guest is stopped. It refuses a live boot disk,
preserves both forks, and lists the resulting Finder identities before
unmounting. `seal` creates a copy-on-write, immutable-named boot image and a
matching `.rig` receipt; it refuses to replace either. A named snapshot without
its receipt is not a versioned oracle.

## Installed application set

The 8.6 oracle carries two project applications for different reasons:

- **New Old World** is the application under test. A visible Workshop after a
  clean reboot is the positive CarbonLib and minimum-floor UI assertion.
- **CodeKitten** is installed so the profile and transfer workflow preserve the
  complete development stack and Finder registration. Its own current platform
  authority requires Mac OS 9.1 or later with CarbonLib 1.6. Presence on this
  disk does not make it supported or expected to remain running on 8.6; launch
  compatibility belongs to `qemu-ppc` or metal on 9.1+.

Record both MacBinary SHA-256 values and source revisions in the sealed-version
receipt or companion evidence. Do not let a convenient old artifact silently
become the oracle's CodeKitten.

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

## The native automation seam

Source inspection identifies a narrow path for the next harness layer; it does
not require replacing SheepShaver's renderer:

- `main_unix.cpp` recognizes a `.sheepvm` directory as a first-class launch
  argument, changes into it, and reads that profile's preferences. The isolated
  profile convention is native behavior, not a launcher accident.
- `video_sdl2.cpp` already owns `guest_surface`, `host_surface`, and the exact
  dirty rectangle immediately before `SDL_RenderPresent`. A capture hook there
  can emit guest pixels before macOS window chrome, scaling, and the host cursor
  contaminate the oracle image.
- The same file drains SDL keyboard and mouse events into ADB calls. A local,
  profile-scoped control socket can inject events at this boundary and preserve
  the emulator's own key mapping.
- The existing `--gui-connection` RPC is not that control plane. It connects the
  emulator back to the settings UI and currently carries alerts and exit only.
- `nogui` suppresses the settings front end; it does not make video headless.

The smallest useful macemu-side experiment is therefore a loopback-only socket
with three operations: report profile identity, capture the pre-presentation
framebuffer, and enqueue one bounded input event. Keep it as a separately
reviewable fork patch until its licensing and redistribution posture are chosen.
The repository harness can then assert the profile and source revision before
accepting captures, just as the QEMU lanes assert which guest answered.

## Evidence status

Use the repository's verification vocabulary:

- A successful cross-build means the PowerPC guest **builds**.
- A visible Workshop in this profile is **emulator-observed on Mac OS 8.6 with
  CarbonLib 1.6**.
- Only a run on the PowerBook is **metal-verified**.

Capture the source revision, profile/input hashes, staged artifact build ID,
and a screenshot together. An attractive desktop without those identities is
reference material, not attributable verification.
