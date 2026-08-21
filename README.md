<!-- now-doc-provenance: generated reviewed=false -->

# New Old World (NOW)

Use a classic Macintosh from a modern Mac without turning either interface into a web replica. New Old World is a native macOS host and a PowerPC Carbon guest for Mac OS 8.6–9.2.2. The alpha centers that pair and includes the NOW Extension in the bundle as an optional installation. A pre-Carbon 68K sibling remains in source, but its current build is stale and excluded from the alpha.

> **Alpha:** useful paths exist, compatibility is deliberately narrow, and several features are tested or emulator-verified rather than proven on physical hardware. The guided setup flow is not yet end-to-end hardware verified. Read [current limitations](docs/user-guide/reference/limitations.md) before relying on it.

![Placeholder for the macOS host overview](docs/assets/screenshots/overview/host.svg)

![Placeholder for the PowerPC Workshop overview](docs/assets/screenshots/overview/workshop.svg)

## Start here

- [Connect your first classic Mac](docs/user-guide/tutorials/first-connection.md)
- [Set up a new PowerPC Mac](docs/user-guide/how-to/set-up-new-mac.md)
- [Install or update the two guest components](docs/user-guide/how-to/upgrade-rollback-remove.md)
- [Compare core features and NOW Extension coverage](docs/user-guide/explanation/core-features.md)
- [Review the alpha feature profile](docs/user-guide/reference/release-profile.md)
- [Browse every module](docs/user-guide/reference/modules/index.md)
- [Read the developer orientation](docs/developer-guide/orientation.md)
- [Use the `now` command line](docs/user-guide/how-to/use-now-cli.md)
- [Build an application with NOW API v1](docs/developer-guide/reference/now-api.md)
- [See the generated protocol reference](docs/generated/asyncapi.md)

The web documentation is built from `mkdocs.yml` at the `/docs/` base path. Run `scripts/docs-serve` for a local preview.
Release branches, immutable numbered candidates, and promotion are defined in
[RELEASING.md](RELEASING.md).

The release DMG carries a finalized host app with its classic setup assets
sealed inside it, so copying the app to Applications does not break those
assets. The same release also publishes a generic classic setup `.img.bin`
and loose MacBinary app and Extension downloads. NOW assumes the classic Mac
already has IP connectivity to the trusted local network; getting an old Mac
online is a separate prerequisite, not a feature of the bundle.

## Product shape

```text
PowerPC Carbon guest ─ guest-initiated TCP, framed control + bulk ─ macOS host

bundled, optional NOW Extension ─ versioned memory table ─ PowerPC guest

pre-Carbon NOW-68K ─ retained in source; excluded from alpha
```

- The host accepts several named guest sessions and drives one selected machine.
- The PowerPC guest is one Workshop window with native module pages.
- The bundled, optional NOW Extension adds deeper Mirror observation and interaction,
  including live interface structure, guarded controls, modal-loop reachability,
  drag sessions, and visible cursor following; ordinary NOW features remain
  available without it.
- NOW-68K implements an explicit subset of the same contract without shaping the PowerPC codebase, but is not an alpha release artifact.
- NOW API v1 is the public loopback application contract; the official `now`
  CLI is its first power-user client. MCP renders a bounded child surface for
  agents through a sibling adapter, not a second set of product meanings.

## Capability summary

| Area | PowerPC alpha | Bundled, optional NOW Extension | Pre-Carbon/NOW-68K |
|---|---|---|---|
| Connection, console, files, processes, software, hardware facts | included | not required | excluded from release |
| Public loopback API v1 and bundled `now` CLI | tested; not emulator- or metal-verified | not required | host-side surface |
| Screenshots and streaming | included with stated limitations | not required | excluded from release |
| [Web compatibility bridge](docs/user-guide/reference/modules/web.md): guest-loopback proxy over NOW's wire, host-side TLS/JS handling, classic HTML profiles, Reader and optional local AI layout | included; tested, not classic-browser verified | not required | unavailable |
| [Projects and Development](docs/user-guide/reference/modules/development.md): host-owned project history, guest-native MPW builds, verified candidates, and exact-product launch | included; host-home loop metal-verified, varied autonomous loops emulator-verified | not required | unavailable |
| [Chat](docs/user-guide/reference/modules/chat.md): saved conversations, projects and modes on both faces, the classic-Mac skill tree, and an optional coding-agent workspace on the modern Mac | experimental; emulator-verified, not metal-verified | not required | unavailable |
| Deeper Mirror observation and interaction | experimental | provides the required classic-process access | unavailable |
| In-context interaction, transitions, modal-safe liveness, drag, and cursor following | experimental | provides resident vehicles | unavailable |
| [Guided PowerPC setup portal](docs/user-guide/how-to/set-up-new-mac.md) and fork-preserving HFS install image | included; tested, not metal-verified | bundled optional package selection | unavailable |
| Host-published in-app updates | tested; not metal-verified | installs separately and requires restart | unavailable |

The short table is navigation, not a claim of parity. The [module reference](docs/user-guide/reference/modules/index.md) states availability, safety, data movement, and failures per module. `docs/contract-coverage.md` keeps **served** separate from **proven**.

## Important limitations

- The listener is for a trusted local network; secure transport is not available yet.
- The public developer API is loopback-only, uses one `X-API-Key`, and has no
  OAuth or scopes in v1. The host does not yet have a dedicated developer-key
  bootstrap control. Its credential is distinct from the MCP bearer token; the
  bundled CLI can read the private API credential itself, while third-party
  clients currently need an explicitly supplied key.
- Each remembered machine can be given its own listening port, which is how
  the host tells two emulated Macs apart when they all reach it from the same
  loopback address. Assigning one opens the socket but does not repoint a
  running guest — download that machine's settings to move it. Tested; not yet
  exercised with two emulated guests, and never on metal.
- The macOS app can be signed as part of release assembly, but classic in-app
  updates are still explicitly unsigned. They verify SHA-256, require local
  confirmation on the classic Mac, and still require fork-preserving transfer.
- Resume-by-offset and some large-transfer behavior remain unreliable.
- The guest-loopback Web relay has not yet been exercised by Classilla on an
  emulator or physical Mac. Its parser, wire codec, host routing and both
  builds are tested; the Open Transport listener remains runtime-unverified.
  Optional model weights are not distributed.
- Development is PowerPC-only. The host-owned MPW build/run loop is metal-verified; guest-home promotion, typed tests, positive CodeKitten handoff receipts, semantic settlement, and authenticated HTTP MCP loops are tested or emulator-verified but have not been repeated together on metal. MPW is an optional onboarding dependency on CarbonLib's terms — one checksum-pinned download the host fetches and builds into a personalized setup image, never into a release output; the guest qualifies whatever a person registers, and it must be the copy on the hard disk rather than the mounted image.
- Chat's workspace lane is a coding agent on the MODERN Mac, and it is the one
  power this app does not audit. With it on — the default, reversible in
  Settings > Chat — a turn typed at the classic machine's Chat page runs a
  Claude runtime with its own file and command tools inside New Old World's own
  workspace folder here, governed by that folder's policy rather than by this
  app's per-capability consent. The New Old World half of such a turn is
  audited exactly as before; the file-and-shell half is not. Emulator-verified,
  never metal-verified.
- Pre-Carbon/NOW-68K support is excluded from the alpha; its source and contributor documentation remain for later feature-flagged work.
- Mirror is experimental. Drawing-content tracing remains off by default and has caused Finder instability on a PowerBook 1400c.
- The documentation currently contains clearly labeled screenshot placeholders; captures must be privacy-reviewed and replace them at the declared dimensions.

See [current limitations](docs/user-guide/reference/limitations.md), [known wrong](docs/known-wrong.md), and the [open issues ledger](docs/open-issues.md) for the full, non-promotional record.

## Build and test

### Dependencies

- **Xcode** (not just the Command Line Tools) for the macOS host app.
- **[CMake](https://cmake.org)** and **[Ninja](https://ninja-build.org)** for the guest builds.
- **[Retro68](https://github.com/autc04/Retro68)** to cross-compile the classic-Mac halves — two separate build trees, not two flags on one install: a PowerPC build (whose `retrocarbon.toolchain.cmake` targets CarbonLib) and a 68K build (`retro68.toolchain.cmake`). Without them the host still builds; only the guest targets need them.
- **python3**, which stamps the canonical `New Old World.bin` and writes update manifests.

### Configure

```sh
cp .env.example .env
```

Fill in the two Retro68 toolchain paths; everything else in the file configures deploying to real hardware, the emulator rigs, and release signing, and can wait. `.env` is gitignored — every value describes one desk — and an explicit environment variable always wins over it. See [lab setup](docs/lab-setup.md).

### Build

```sh
make host    # macOS app            -> build/host/New Old World.app
make ppc     # PowerPC Carbon guest -> build/ppc/New Old World.bin
make 68k     # 68K guest            -> build/68k/
make ext     # NOW Extension INIT   -> build/ext/NOW Extension.bin
```

`make guests` builds the three classic targets; `scripts/build-all` builds everything this machine has toolchains for, skipping (loudly) what it cannot. Everything lands in the gitignored `build/`.

```sh
scripts/build-bundle
```

builds all of it and produces an installable DMG under `build/bundle/`, with the guest components staged inside the app for in-app deployment. It signs with your Apple Development identity when `NOW_HOST_TEAM_ID` is set in `.env` — which keeps macOS permission grants across rebuilds — and ad-hoc otherwise.

A build proves the code compiles, nothing more. This project's verification levels are **builds**, **tested**, and **metal-verified**, and they are not adjectives — see [AGENTS.md](AGENTS.md).

### Test

```sh
tools/setup-hooks
scripts/test-all
```

`scripts/test-all` is the repository gate. It runs host-only checks first, the documentation gate, both guest cross-builds when Retro68 is installed, the host suites and app builds, and an optional live-guest stage. Green means **tested**, not metal-verified.

CarbonLib is a runtime dependency on the classic Mac, not a source dependency
of the macOS build. The repository does not check Apple's installer into Git.
Source builds must arrange CarbonLib 1.6 on the target Mac themselves; the
guest warns at launch when it detects an older version and can remember a
person's choice not to warn again. Release assembly may bundle the exact
checksum-pinned Apple installer and its license material through an external
descriptor; see the [distribution standard](docs/developer-guide/reference/distribution-standard.md#assemble-a-release).

For docs only:

```sh
uv venv .docs-venv
uv pip install --python .docs-venv/bin/python -r docs/requirements.txt
scripts/test-docs
```

The docs gate validates structure, links, source dependencies, images, live module inventories, AsyncAPI references, generated pages, rendered accessibility landmarks, and declared derivations. Its mutation self-test proves each named failure class is refused for the reason it claims.

## Repository map

| Path | Purpose |
|---|---|
| `contract/` | Wire and resident-memory authorities |
| `now-host/` | Native macOS application |
| `now-cli/` | Official API-only power-user command and completions |
| `now-guest-ppc/` | PowerPC CarbonLib guest |
| `now-guest-68k/` | 68K Toolbox/MacTCP guest |
| `ext/` | Optional resident extension |
| `docs/user-guide/` | Public task and module documentation |
| `docs/developer-guide/` | Architecture, code-reading, debugging, and contribution guide |
| `docs/agent-guide/` | Coding-agent operating, routing, evidence, and handoff guide |

Contributors start with [CONTRIBUTING.md](CONTRIBUTING.md). Coding agents start
with [the agent guide](docs/agent-guide/index.md), with `AGENTS.md` as the
complete repository instruction. Technical architecture is explained once in
the developer guide and linked from the agent path.

## Security

Read [SECURITY.md](SECURITY.md). Do not expose the listener directly to an untrusted network. The release documentation gate will refuse publication until the canonical website origin, website repository, and vulnerability-reporting contact are configured; those values are intentionally not guessed in this branch.
