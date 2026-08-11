# New Old World (NOW)

New Old World connects a native macOS host to a PowerPC Carbon application on
Mac OS 8.6–9.2.2. It provides files, console, screenshots, processes, hardware
facts, development tools, and an experimental native Mirror without turning
either machine into a web replica. The optional NOW Extension enables deeper
observation and interaction. A 68K sibling remains in source but is not part of
the initial release profile.

> **Pre-alpha:** the repository is tested and substantial paths have emulator
> or targeted hardware evidence, but the complete release candidate has not
> passed its physical-hardware matrix. The wire is plaintext and unauthenticated
> for use on a trusted LAN only.

Start with the [published documentation](https://docs.newoldworldmac.com/),
[developer orientation](https://docs.newoldworldmac.com/developer-guide/orientation/),
or [current limitations](https://docs.newoldworldmac.com/user-guide/reference/limitations/). Release
branches, immutable numbered candidates, and promotion are defined in
[RELEASING.md](RELEASING.md).

## Build and test

The modern host builds on macOS 13 or later. A complete development setup uses:

- Xcode and its command-line tools, with Swift 6 support;
- Python 3 and [uv](https://docs.astral.sh/uv/);
- CMake and Ninja;
- a host C compiler, supplied by the Xcode command-line tools; and
- [Retro68](https://github.com/autc04/Retro68) PowerPC RetroCarbon and 68K
  toolchains when building the classic applications and Extension.

Install the pinned documentation environment, configure repository hooks, and
run the integrated gate:

```sh
uv venv .docs-venv
uv pip install --python .docs-venv/bin/python -r docs/requirements.txt
tools/setup-hooks
scripts/test-all
```

`scripts/test-all` runs documentation and policy checks, native C sanitizer
tests, MirrorKit, both classic cross-builds, Swift package tests, and Debug and
Release Xcode builds. Metal tests are opt-in. Green means **tested**, not
metal-verified. Ordinary test builds are unsigned so a contributor or CI runner
does not need the owner's Apple credential. Release qualification separately
runs `NOW_HOST_SIGNING=release scripts/test-host`, which requires and verifies
the selected Apple team, application identifier, and Keychain access group.

Retro68 is optional for host-only contribution, but the guest build stage will
report **SKIPPED** without it. To run that stage, copy the local configuration
template and set the two toolchain-file paths:

```sh
cp .env.lab.example .env.lab

# In .env.lab:
NOW_PPC_TOOLCHAIN=/path/to/Retro68-build/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake
NOW68K_TOOLCHAIN=/path/to/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake

scripts/build-guests
```

CarbonLib is a target-Mac runtime dependency, not a source-build dependency.
The repository and GitHub releases do not redistribute it; see
[CarbonLib 1.6.1 on Macintosh Repository](https://www.macintoshrepository.org/17069-carbonlib)
and the [PowerPC installation guide](docs/user-guide/how-to/install-ppc.md).

Focused commands and emulator/metal setup are documented in
[Build and test](docs/developer-guide/workflows/build-and-test.md),
[Lab setup](docs/lab-setup.md), and [CONTRIBUTING.md](CONTRIBUTING.md).

## Repository shape

- `contract/` — wire and resident-memory authorities
- `now-host/` — macOS host and Swift packages
- `now-guest-ppc/` — PowerPC CarbonLib guest
- `now-guest-68k/` — experimental 68K Toolbox/MacTCP guest
- `ext/` — optional resident NOW Extension
- `docs/` — user, developer, agent, protocol, and evidence documentation

The complete protocol is [contract/asyncapi.yaml](contract/asyncapi.yaml). See
the [repository map](docs/developer-guide/reference/repository-map.md) and
[generated protocol reference](docs/generated/asyncapi.md) for the detailed
tour.

## Security and project status

Read [SECURITY.md](SECURITY.md) before connecting a machine. Do not expose the
listener to the internet or an untrusted LAN. Availability, proof level, known
wrong behavior, and deferred work live in the
[release profile](docs/user-guide/reference/release-profile.md),
[status](docs/status.md), [known-wrong ledger](docs/known-wrong.md), and
[open-issues ledger](docs/open-issues.md).
