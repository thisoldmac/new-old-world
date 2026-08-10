# New Old World (NOW)

Use a classic Macintosh from a modern Mac without turning either interface into a web replica. New Old World is a native macOS host and a PowerPC Carbon guest for Mac OS 8.6–9.2.2. The alpha centers that pair and includes the NOW Extension in the bundle as an optional installation. A pre-Carbon 68K sibling remains in source, but its current build is stale and excluded from the alpha.

> **Alpha:** useful paths exist, compatibility is deliberately narrow, and several features are tested or emulator-verified rather than proven on physical hardware. The guided setup flow is not yet end-to-end hardware verified. Read [current limitations](docs/user-guide/reference/limitations.md) before relying on it.

![Placeholder for the macOS host overview](docs/assets/screenshots/overview/host.svg)

![Placeholder for the PowerPC Workshop overview](docs/assets/screenshots/overview/workshop.svg)

## Start here

- [Connect your first classic Mac](docs/user-guide/tutorials/first-connection.md)
- [Set up a new PowerPC Mac](docs/user-guide/how-to/set-up-new-mac.md)
- [Compare core features and NOW Extension coverage](docs/user-guide/explanation/core-features.md)
- [Review the alpha feature profile](docs/user-guide/reference/release-profile.md)
- [Browse every module](docs/user-guide/reference/modules/index.md)
- [Read the developer orientation](docs/developer-guide/orientation.md)
- [See the generated protocol reference](docs/generated/asyncapi.md)

The web documentation is built from `mkdocs.yml` at the `/docs/` base path. Run `scripts/docs-serve` for a local preview.

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
- Agent access is a bounded projection of host capabilities, not a second route to the guest socket.

## Capability summary

| Area | PowerPC alpha | Bundled, optional NOW Extension | Pre-Carbon/NOW-68K |
|---|---|---|---|
| Connection, console, files, processes, software, hardware facts | included | not required | excluded from release |
| Screenshots and streaming | included with stated limitations | not required | excluded from release |
| [Projects and Development](docs/user-guide/reference/modules/development.md): host-owned project history, guest-native MPW builds, verified candidates, and exact-product launch | included; host-home loop metal-verified, varied autonomous loops emulator-verified | not required | unavailable |
| Deeper Mirror observation and interaction | experimental | provides the required classic-process access | unavailable |
| In-context interaction, transitions, modal-safe liveness, drag, and cursor following | experimental | provides resident vehicles | unavailable |
| [Guided PowerPC setup portal](docs/user-guide/how-to/set-up-new-mac.md) and fork-preserving HFS install image | included; tested, not metal-verified | bundled optional package selection | unavailable |

The short table is navigation, not a claim of parity. The [module reference](docs/user-guide/reference/modules/index.md) states availability, safety, data movement, and failures per module. `docs/contract-coverage.md` keeps **served** separate from **proven**.

## Important limitations

- The listener is for a trusted local network; secure transport is not available yet.
- Distribution is not a signed installer flow. Classic artifacts require fork-preserving transfer.
- Resume-by-offset and some large-transfer behavior remain unreliable.
- Development is PowerPC-only. The host-owned MPW build/run loop is metal-verified; guest-home promotion, typed tests, positive CodeKitten handoff receipts, semantic settlement, and authenticated HTTP MCP loops are tested or emulator-verified but have not been repeated together on metal. A redistributable MPW starter payload remains blocked on license/provenance.
- Pre-Carbon/NOW-68K support is excluded from the alpha; its source and contributor documentation remain for later feature-flagged work.
- Mirror is experimental. Drawing-content tracing remains off by default and has caused Finder instability on a PowerBook 1400c.
- The documentation currently contains clearly labeled screenshot placeholders; captures must be privacy-reviewed and replace them at the declared dimensions.

See [current limitations](docs/user-guide/reference/limitations.md), [known wrong](docs/known-wrong.md), and the [open issues ledger](docs/open-issues.md) for the full, non-promotional record.

## Build and test

```sh
tools/setup-hooks
scripts/test-all
```

`scripts/test-all` is the repository gate. It runs host-only checks first, the documentation gate, both guest cross-builds when Retro68 is installed, the host suites and app builds, and an optional live-guest stage. Green means **tested**, not metal-verified.

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
