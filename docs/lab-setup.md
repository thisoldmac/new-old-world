<!-- now-doc-provenance: generated reviewed=false -->

# Lab setup

Everything in this project that knows about a *particular* machine reads
it from a file you write and nobody commits. Two kinds of file, split by
what the facts are *about*:

- **`.lab/machines/<id>.machine`** — one file per vintage Mac, carrying
  that machine's address, FTP account, deploy folder and metal facts.
- **`.env.lab`** — this desk: toolchain paths, emulator images, signing
  identity. One of each, so flat keys are right.

That is not only hygiene. A default address baked into a script is wrong
for everyone except the person who wrote it, while looking authoritative
— and the specific way it bites here is that a deploy silently goes to
whatever machine a stale default named, and the test run afterwards
measures a build that never moved.

## Getting started

```bash
cp .env.lab.example .env.lab
```

```bash
cp .lab/machines/pb180c.machine.example .lab/machines/pb180c.machine
```

Fill in the values for your desk. Both are gitignored. A worktree with
neither reads the **main worktree's** — a worktree is the same desk and
the same machines, and a copy made inside one dies with it.

A script that needs a value you have not set stops and names the key and
the file it belongs in, rather than guessing.

## Machine profiles

A machine profile is keyed by the id the host already calls that Mac —
its `GuestID` slug, the same one a person types at the machine picker and
an agent types in a tool call (`pb180c`, `pb1400c`). The file name **is**
the id.

```
# .lab/machines/pb180c.machine
name = PowerBook 180c
guest = 68k
address = 192.0.2.180
ftp_user = lab
ftp_pass = ••••••
ftp_dir = Lab/now-68k
```

| Key | What it is |
|---|---|
| `name` | How a message should refer to it. |
| `guest` | Which guest it runs: `68k` or `ppc`. `scripts/deploy-68k` refuses a machine that runs the other one. |
| `address` | Its address on the LAN. |
| `ftp_user` | FTP account on it — NetPresenz or Rumpus. |
| `ftp_pass` | That account's password. |
| `ftp_dir` | Folder builds land in, relative to the FTP root. Defaults to `Lab/now-68k`. |
| `metal_port` | Port this machine's metal runs use. Optional; `tools/lane-ports` derives one per lane. |
| `harness_host` | This Mac's address **as this machine must dial it**, when it differs from the desk-wide `NOW68K_HARNESS_HOST`. |

An unknown key is **refused by name** rather than ignored: a typo in
`ftp_pas` would otherwise leave the value unset and the run would fall
back to whatever a stale flat key still named, which is the failure this
whole scheme exists to end.

`address` is one fact and everything that needs it reads it here — the
FTP deploy and the metal machine-busy guard both. They used to be
`NOW68K_FTP_HOST` and `NOW_METAL_MACHINE`, set separately, with nothing
checking they agreed.

### Choosing a machine

```bash
scripts/deploy-68k --machine pb180c
```

With one profile there is nothing to ask and `--machine` is optional.
With several, a deploy **refuses and names them** — a deploy that went to
a machine nobody chose is the same failure as one that went to a stale
default. `scripts/deploy-68k --which` resolves and stops, touching
nothing, when you want to know where a command would land.

```bash
tools/lab-machine list          # every profile, with its address
tools/lab-machine show pb180c   # one profile, resolved
```

The Swift metal suites read the environment and know nothing about this
directory, so `tools/lab-machine env` hands them the values the way
`tools/lane-ports --env` hands a shell its ports:

```bash
eval "$(tools/lab-machine env pb180c)"
```

FTP is not a security decision, it is what these machines can speak. See
[SECURITY.md](../SECURITY.md) for the trust boundary this whole project
assumes. The FTP password is deliberately **not** exported by
`lab-machine env` — `eval` would put it in shell history and scrollback,
and the one thing that needs it reads the profile itself.

### Precedence

Explicit environment variable → machine profile → `.env.lab`.

An explicit variable still wins, so a one-off run against a machine with
no profile needs no edit:

```bash
NOW68K_FTP_HOST=192.0.2.44 scripts/deploy-68k
```

A desk that has written no profile keeps working on the old flat keys. A
desk mid-migration gets told out loud when `.env.lab` still carries a key
a profile now answers and the two disagree — silence there would leave a
plausible wrong address in a file nobody re-reads.

## The desk keys

### This Mac

| Key | What it is |
|---|---|
| `NOW68K_HARNESS_HOST` | This Mac's address **as the guest must dial it**. A machine that needs a different one sets `harness_host` in its profile. |

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
| `NOW_METAL_PORT` | Port the harness listens on and the guest dials. A machine's `metal_port` sets it. |
| `NOW_METAL_MACHINE` | The vintage machine's address. A machine's `address` sets it. |
| `NOW_METAL_REPEATS` | Samples per rung for the baseline suite. |

**Set `NOW_METAL_MACHINE` for any run against real hardware.** Without
it `MetalMachineGuard` cannot check whether something else on this Mac is
already talking to that machine, and half the guard cannot run — it says
so rather than passing quietly.

`scripts/deploy-68k --test` sets both from the profile. A suite run on
its own gets them from `eval "$(tools/lab-machine env <id>)"` — the
suites read the environment and are not taught about profiles, so this is
the seam.

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
