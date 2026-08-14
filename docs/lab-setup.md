<!-- now-doc-provenance: generated reviewed=false -->

# Lab setup

Everything in this project that knows about a *particular* machine reads
it from the environment. Nothing about your network is committed.

That is not only hygiene. A default address baked into a script is wrong
for everyone except the person who wrote it, while looking authoritative
— and the specific way it bites here is that a deploy silently goes to
whatever machine a stale default named, and the test run afterwards
measures a build that never moved.

## Getting started

```bash
cp .env.lab.example .env.lab
```

Fill in the values for your desk. `.env.lab` is gitignored. Scripts read
it from the repository root, and an explicit environment variable still
wins over it — so a one-off run against a different machine needs no
edit:

```bash
NOW68K_FTP_HOST=192.0.2.44 scripts/deploy-68k
```

A script that needs a value you have not set stops and names the key,
rather than guessing.

## The keys

### The vintage Mac

| Key | What it is |
|---|---|
| `NOW68K_FTP_HOST` | The 68K Mac's address. |
| `NOW68K_FTP_USER` | FTP account on it — NetPresenz or Rumpus. |
| `NOW68K_FTP_PASS` | That account's password. |
| `NOW68K_FTP_DIR` | Folder builds land in, relative to the FTP root. Defaults to `Lab/now-68k`. |

FTP is not a security decision, it is what these machines can speak. See
[SECURITY.md](../SECURITY.md) for the trust boundary this whole project
assumes.

### This Mac

| Key | What it is |
|---|---|
| `NOW68K_HARNESS_HOST` | This Mac's address **as the guest must dial it**. |

Not `localhost`, and not `10.0.2.2`. The guest is a separate machine on
the LAN. `10.0.2.2` is the QEMU user-mode gateway, which is right for an
emulated guest and never answers on real hardware — where it looks
exactly like a hang.

### Toolchains

| Key | What it is |
|---|---|
| `NOW_PPC_TOOLCHAIN` | Absolute path to the Retro68 **PowerPC RetroCarbon** CMake toolchain file. |
| `NOW68K_TOOLCHAIN` | Absolute path to the Retro68 **68K** CMake toolchain file. |

Both toolchain files are passed to `cmake` by `scripts/build-guests`; see the
build section of the [README](../README.md).

### SheepShaver Mac OS 8.6 oracle

| Key | What it is |
|---|---|
| `NOW_SHEEPSHAVER_APP` | Absolute path to a locally built or installed `SheepShaver.app`. |
| `NOW_SHEEPSHAVER_VM` | Absolute path to the isolated Mac OS 8.6 `.sheepvm` profile. |
| `NOW_SHEEPSHAVER_SOURCE` | Optional macemu source checkout; `rig` records its revision when set. |
| `NOW_CODEKITTEN_SOURCE` | Optional CodeKitten source checkout; `install-apps` records its revision. |
| `NOW_SHEEPSHAVER_DISK` | Optional boot-disk override. Defaults to `Mac OS 8.6.hfv` inside the profile. |
| `NOW_SHEEPSHAVER_TRANSFER` | Optional HFS transfer-disk override. Defaults to `CarbonLib 1.6 Transfer.hfv` inside the profile. |
| `NOW_SHEEPSHAVER_APPS_DIR` | Optional application-folder override. Defaults to `Applications (Mac OS 9)` on the installed 8.6 volume. |

The repository neither downloads nor redistributes SheepShaver, a ROM,
Mac OS, or CarbonLib. `scripts/sheepshaver-86` operates developer-supplied
inputs and refuses to alter a disk that the running emulator has open.
See [SheepShaver 8.6 UI oracle](developer-guide/workflows/sheepshaver-86.md)
for the reproducible profile and evidence procedure.

### Metal gates

Only read when `NOW_METAL` is set. Unset, the metal suites skip; set,
they **fail rather than skip**, because a gate that reads green having
never reached a machine is worse than no gate.

| Key | What it is |
|---|---|
| `NOW_METAL` | Opt in to the metal suites at all. |
| `NOW_METAL_PORT` | Port the harness listens on and the guest dials. |
| `NOW_METAL_MACHINE` | The vintage machine's address. |
| `NOW_METAL_REPEATS` | Samples per rung for the baseline suite. |

**Set `NOW_METAL_MACHINE` for any run against real hardware.** Without
it `MetalMachineGuard` cannot check whether something else on this Mac is
already talking to that machine, and half the guard cannot run — it says
so rather than passing quietly.

Pick a port nothing else is dialling. Every QEMU guest on a Mac sees the
host as `10.0.2.2` under user-mode networking, so any session's VM
running any branch's build can answer your listener. This is not
theoretical — a refusal case once passed against another branch's guest,
because "unknown command" is also a refusal with a reason.

The full procedure, and how to tell contention from a defect, is
[68k-metal-runbook.md](68k-metal-runbook.md).

## Emulators

`scripts/q800-68k` boots a Quadra 800 for NOW-68K and takes its QEMU
binary and disk image from the environment; run it with `--help` for the
current list. Its session directory (`.q800/`) is a cloned disk image and
a build tree, disposable by construction and gitignored.

`scripts/sheepshaver-86` operates a persistent, isolated Mac OS 8.6 plus
CarbonLib 1.6 UI-oracle profile. Start with `doctor`; use `stage` for
MacBinary applications rather than launching them from the Unix shared
folder. After a clean shutdown, `rig` emits exact source and disk identities
for the evidence record.

Use `scripts/emulator matrix` as the front door when choosing a lane. It routes
to the existing QEMU PPC, SheepShaver 8.6, and QEMU 68K harnesses without
pretending their evidence is interchangeable.

## Running a second copy of the host app

The checkout is shared and several sessions work in it at once, so a
build launched to look at it must not write into the desk's real
preferences. `NOW_PREFS_SUFFIX` gives a run its own UserDefaults suite:

```sh
NOW_PREFS_SUFFIX=my-thread open -n "path/to/New Old World.app"
```

Two things to know. A suffixed run starts from **defaults**, so it takes
the default listening port with them - set another one in that suite
first (`defaults write dev.newoldworld.now.settings.my-thread listenPort
-int 5399`), or it will contend with the instance you were trying not to
disturb. And check what is already listening before you launch:

```sh
lsof -nP -iTCP -sTCP:LISTEN | grep "New"
```

Clean up the suite afterwards with `defaults delete
dev.newoldworld.now.settings.my-thread`.

## Signed release assembly

`scripts/release-dmg` assembles a signed development-channel DMG from
three desk facts in `.env.lab`, refusing by name when one is missing:

- `NOW_RELEASE_SIGN_IDENTITY` — the codesign identity string, exactly as
  `security find-identity -v -p codesigning` prints it.
- `NOW_RELEASE_CARBONLIB_DESCRIPTOR` — absolute path to the CarbonLib
  descriptor JSON, with the installer's license material beside it (the
  descriptor grammar is in the distribution standard reference).
- `NOW_RELEASE_PROVISION_PROFILE` — a **macOS** team provisioning
  profile to embed before signing. This one has a failure mode worth its
  own sentence: an identity-signed app carries restricted entitlements,
  and without an embedded profile authorizing them AMFI kills the
  process at spawn while the Finder reports only "can't be opened" —
  which is how the first signed DMG from this desk shipped unlaunchable
  with every gate green. Xcode's managed `Mac Team Provisioning
  Profile: *` (found inside any Xcode-built app of the same team as
  `Contents/embedded.provisionprofile`) is the right file; the assembler
  refuses wrong-platform, wrong-team, and expired profiles by name.
  Note the iOS wildcard profile in the same Xcode directory differs only
  in its Platform array and produces the identical unlaunchable app.

A real release (`--channel release`) is deliberately not wrapped: it is
a decision with more inputs than a desk file, and
`scripts/assemble-release`'s own refusals are its interface.
