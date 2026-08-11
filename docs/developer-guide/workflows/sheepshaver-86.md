---
page_id: dev-workflow-sheepshaver-86
title: SheepShaver 8.6 UI oracle
description: Build and operate a reproducible Mac OS 8.6 plus CarbonLib 1.6 oracle for fast PowerPC Carbon UI iteration.
doc_type: how-to
audience: operator
lifecycle: current
authority: [AGENTS.md, docs/guest-ui-start-here.md]
source_dependencies: [scripts/sheepshaver-86, scripts/package-sheepshaver-86, tools/mirror-oracle, tools/mirror_oracle, tools/mirror_oracle_data, tools/extract-assets-offline, tools/macbinary-identity.py, tools/sheepshaver-86-tests, tools/sheepshaver-package-tests, tools/mirror-oracle-tests.py, now-host/Packages/MirrorKit/Sources/MirrorRenderCLI, now-host/Packages/MirrorKit/Sources/MirrorKitUI/PlatinumMenuBar.swift, docs/lab-setup.md, now-guest-ppc]
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
scripts/package-sheepshaver-86 \
  "path/to/SheepShaver.app" "path/to/SheepShaver-8.6-Oracle.app"
```

That recipe produces a native arm64 app initially linked to Homebrew's SDL
compatibility and VDE libraries. `package-sheepshaver-86` copies the complete
dependency closure into `Contents/Frameworks`, rewrites Mach-O load paths,
embeds the SheepShaver license and source revision, fixes the bundle identifier,
ad-hoc signs the result, and refuses a package whose final load commands still
name Homebrew or `/usr/local`. It publishes atomically so a late failure cannot
leave a partial app at the destination.

Homebrew's SDL2 may be `sdl2-compat`, which opens SDL3 at runtime rather than
recording it in Mach-O load commands. The packager detects that loader marker,
bundles `libSDL3.dylib` explicitly, and refuses the package if the runtime SDL3
is absent. An `otool -L`-only closure is not sufficient for this dependency.

This makes the local oracle host app self-contained. It does not turn the ROM,
Mac OS, CarbonLib, or the profile into redistributable inputs, and it does not
settle whether a modified GPL emulator should become a shipped product
dependency. Those remain separate decisions.

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
scripts/sheepshaver-86 capture "path/to/evidence/frame.bmp"
scripts/sheepshaver-86 input "move 200 120" "down 0" "up 0"
scripts/sheepshaver-86 snapshot "Mac OS 8.6 + CarbonLib 1.6"
scripts/sheepshaver-86 rig
scripts/sheepshaver-86 seal "os86-carbon16-now020-codekitten-5d404f7"
scripts/sheepshaver-86 clone \
  "os86-carbon16-now020-codekitten-5d404f7" \
  "/absolute/path/to/finder-run.sheepvm"
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

`clone` makes an isolated run profile from a named sealed image. It verifies
the image against the sealed receipt before copying, uses copy-on-write clones
where the filesystem supports them, gives the run its own boot and transfer
images, and records the source receipt as `Oracle Parent.rig`. Run visual
experiments in that clone rather than changing the sealed profile. The command
refuses a relative destination, an existing destination, a live source image,
or source image, preferences, ROM, transfer disk, or installed-app manifest
whose bytes no longer match its receipt.

`install-apps` writes both MacBinary applications into the configured
Applications folder while the guest is stopped. It refuses a live boot disk,
preserves both forks, and lists the resulting Finder identities before
unmounting. `seal` creates a copy-on-write, immutable-named boot image and a
matching `.rig` receipt; it refuses to replace either. A named snapshot without
its receipt is not a versioned oracle.

Before the boot disk is opened, the installer verifies the MacBinary header
CRC, fork lengths, and internal Finder identity. NOW must be `New Old
World/APPL/NOWo`; CodeKitten must be `codekitten/APPL/O9ID`. A plausible
filename cannot substitute another build or a truncated fork envelope.

## Installed application set

The 8.6 oracle carries two project applications for different reasons:

- **New Old World** is the application under test. A visible Workshop after a
  clean reboot is the positive CarbonLib and minimum-floor UI assertion.
- **CodeKitten** is a second application under test. Its IDE shell supports Mac
  OS 8.6 through 9.2.2 with CarbonLib 1.6, although an individual toolchain or
  package may declare a higher floor. It must launch and remain responsive in
  this profile. Failure is a CodeKitten compatibility bug to capture with the
  exact artifact and rig identities; it must not be reclassified as an expected
  limit of the 8.6 oracle.

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
against CarbonLib in this profile. Then launch CodeKitten and exercise its
initial window and one menu. A failure to launch or remain responsive is a bug
in the supported 8.6 runtime, not a reason to move the declared floor. Neither
observation proves hardware behavior.

The first acceptance on 2026-08-11 reached the NOW Workshop. CodeKitten did
not reach its initial window, so the menu step is blocked by a product bug. The
first artifact imported MLTE from a standalone `Textension` fragment that is
absent from the installed CarbonLib 1.6. A repaired artifact imports the 32
MLTE symbols from CarbonLib's embedded `Textension_CL` fragment, but the Mac OS
8.6 CFM loader still reports that `CarbonLib` cannot be found. Read-only disk
inspection proved that the installed data/resource forks exactly match that
artifact and that the system file is CarbonLib Update 1.6; static import-name
comparison found no missing strong or weak symbol in CarbonLib's main
fragment. The remaining cause is unresolved CFM load/dependency behavior, not
a stale application, a skipped updater, or an unsupported runtime. See
`docs/open-issues.md` for the live bug record.

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

## Native framebuffer capture and input

The versioned local macemu branch `codex/now-oracle-capture` adds bounded,
profile-local request seams. `scripts/sheepshaver-86 capture` creates a sentinel
in the active `.sheepvm`; the SDL renderer answers with a BMP of its native
guest surface, writes the exact `NOW_ORACLE_CAPTURE_NATIVE_RGB_V2` response,
then removes the request. The versioned response is part of the contract: the
launcher refuses an older capture build that publishes a BMP without the RGB
receipt, because the original implementation preserved framebuffer geometry
but exchanged the red and blue channels. `scripts/sheepshaver-86 input` publishes
validated native-pixel mouse actions or raw ADB key transitions atomically and
requires the renderer's completion receipt. Both commands time out rather than
accepting stale state. Captures exclude macOS window chrome, scaling, and the
host cursor.

An input receipt proves that the renderer dispatched the ADB transitions; it
does not prove that the cooperative guest event loop consumed them. Immediate
follow-up input during bring-up retained mouse-button or modifier state and
caused Finder drags and multi-selection. The harness therefore waits one
second after a successful renderer receipt by default. Override that with
`NOW_SHEEPSHAVER_INPUT_SETTLE` only for a measured profile, and use a capture
after the settle interval as the behavioral observation.

The seam deliberately does not replace SheepShaver's renderer:

- `main_unix.cpp` recognizes a `.sheepvm` directory as a first-class launch
  argument, changes into it, and reads that profile's preferences. The isolated
  profile convention is native behavior, not a launcher accident.
- `video_sdl2.cpp` already owns `guest_surface`, `host_surface`, and the exact
  dirty rectangle immediately before `SDL_RenderPresent`; the hook reads that
  existing surface only after an explicit profile-local request.
- The same file drains SDL keyboard and mouse events into ADB calls. The input
  seam invokes those ADB calls on the renderer thread, using native guest
  coordinates and explicit key transitions rather than the macOS pointer.
- The existing `--gui-connection` RPC is not that control plane. It connects the
  emulator back to the settings UI and currently carries alerts and exit only.
- `nogui` suppresses the settings front end; it does not make video headless.

The next useful macemu-side experiment is a loopback-only socket for profile
identity and longer-lived control. Keep that as a separately reviewable fork
patch until its licensing and redistribution posture are chosen. The current
capture/input patch is likewise not an upstream or product dependency; the
sealed rig records its exact source and executable identities.

## Mirror visual-oracle loop

`tools/mirror-oracle` turns the native framebuffer seam into a repeatable
reference loop. It consumes both existing renderers: SheepShaver produces the
target's real pixels, and `mirror-render` calls MirrorKitUI's production
`RenderShot`. There is no third UI implementation in the comparison tool.

List the current profile and cases, prepare a disposable run profile, then
capture or compare:

```sh
tools/mirror-oracle list
tools/mirror-oracle prepare \
  os86-carbon16-now020-codekitten-5d404f7 \
  /absolute/path/to/finder-run.sheepvm

tools/mirror-oracle capture finder-desktop \
  --vm /absolute/path/to/finder-run.sheepvm \
  --state-proof /absolute/path/to/observed-state.json \
  --out /absolute/path/to/evidence/finder-desktop

tools/mirror-oracle run finder-front-icon-view \
  --vm /absolute/path/to/finder-run.sheepvm \
  --state-proof /absolute/path/to/observed-state.json \
  --scene /absolute/path/to/scene.json \
  --out /absolute/path/to/evidence/finder-icon-view \
  --report-only
```

Build the private OS 8.6 asset pack directly from the stopped SheepShaver
volume, then derive the capture-attributed menu-bar art into a new pack:

```sh
tools/extract-assets-offline \
  --image /absolute/path/to/Mac\ OS\ 8.6.hfv \
  --out /absolute/path/to/os86-base/Resources

tools/mirror-oracle extract-chrome platinum.macos-8.6.default \
  --guest /absolute/path/to/stable-guest.bmp \
  --base-assets /absolute/path/to/os86-base/Resources \
  --out /absolute/path/to/os86-oracle/Resources
```

The first command recognizes a raw HFS/HFS+ `.hfv` as well as an APM qcow2
disk. The second clones the whole base pack, writes transparent crops declared
by the visual profile, and publishes `manifest.json` only after the derived
pack and its provenance receipt are complete. It never edits the sealed base
pack. The BMP decoder must ignore its zero alpha plane: SheepShaver's native
32-bit framebuffer stores visible RGB with every alpha byte zero.

A capture is accepted only after two consecutive native framebuffer reads have
the same SHA-256 after case-declared volatile masks are applied. All attempts
remain in `samples/`; success writes `capture.json`, and a refusal writes
`capture-failure.json`. The receipt includes the case, visual profile, NOW
revision, backend doctor output, run-profile identities, exact input actions,
and optional state-proof identity. A capture without `--state-proof` is
explicitly `reference-only`; one with a proof is `state-proof-attached`, not
silently promoted to verified. A required-state sentence is not proof that the
machine was in that state.

Comparisons are exact and region-specific. They write `comparison.json`, a
same-scale `pair.png`, and a red-pixel `diff.png`; a mismatch exits nonzero
unless `run --report-only` was requested. Whole-screen similarity is not an
acceptance measure. Cases that depend on window geometry resolve their region
from the same scene JSON rendered by MirrorKit.

The first profile is `platinum.macos-8.6.default`, with six Finder/menu-bar
cases: resting desktop, front icon-view window, inactive Finder window, list
selection, File menu, and Apple menu. Their `inputActions` remain empty until
each coordinate sequence is validated against the sealed profile. This makes
setup manual today but prevents an unmeasured coordinate from silently
becoming the durable state contract. If case input is later enabled, cleanup is
armed before the first transition and releases every mouse button and common
modifier even when capture fails. The SheepShaver backend sends one action per
renderer receipt: the guest must receive the harness's settlement interval
between a menu-title press, a drag, and a release. Batching those transitions
dispatches them all but lets the cooperative event loop miss the gesture.

The QEMU backend remains available with `--backend qemu --qmp-socket ...` for
the full-stack and Mac OS 9.1+ lanes. QEMU input is intentionally refused here;
drive QEMU through its existing semantic harness. A future visual version gets
another profile and evidence-backed deltas rather than conditionals scattered
through the comparison code.

The first color-correct reference-only calibration uses the stable 800×600
Finder capture whose SHA-256 is
`cdddab6c4e1de1d43b57580f2c2ccd2e2c0a54d8898ca91910b91e893e2bc09a`.
It is not an accepted resting-desktop case: a transfer window remained open
and no state proof was attached. Its unobscured 20-row menu-bar region is still
a valid named visual reference. Against a pack extracted from the same 8.6
boot disk, the production renderer differs in 35 of 13,500 unmasked pixels
(0.259%); all residual pixels are inside the word “View”. The desktop region
that the profile declares as unobscured proves all 69,160 background pixels
exactly against the extracted, origin-zero `Mac OS Default` tile. This proves
the background asset and tiling rule, not the resting-desktop case: the source
still contains a transfer window and Finder icons while the calibration scene
intentionally contains no semantic windows or desktop items.

The earlier stable BMP beginning `db968889...` is invalid as color evidence.
Its source build saved an SDL intermediate surface with masks that did not
describe the host bytes, exchanging red and blue. Any crop or comparison made
from that capture must be regenerated from a V2-receipted framebuffer.

## Evidence status

Use the repository's verification vocabulary:

- A successful cross-build means the PowerPC guest **builds**.
- A visible Workshop in this profile is **emulator-observed on Mac OS 8.6 with
  CarbonLib 1.6**.
- CodeKitten revision `5d404f7` is **installed and emulator-observed failing to
  launch** with a CFM `CarbonLib` error. It is a supported-runtime bug, not a
  passed launch or menu acceptance.
- Only a run on the PowerBook is **metal-verified**.

Capture the source revision, profile/input hashes, staged artifact build ID,
and a screenshot together. An attractive desktop without those identities is
reference material, not attributable verification.
