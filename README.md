# New Old World (NOW)

Use a classic Macintosh from a modern Mac without turning either interface into a web replica. New Old World is a native macOS host, a PowerPC Carbon guest for Mac OS 8.6–9.2.2, and a 68K Toolbox guest for System 7.1-era machines. Both guests speak one versioned contract and initiate the connection to the host.

> **Pre-alpha:** useful paths exist, but installation is still manual, compatibility is deliberately narrow, and several features are tested or emulator-verified rather than proven on physical hardware. Read [current limitations](docs/user-guide/reference/limitations.md) before relying on it.

![Placeholder for the macOS host overview](docs/assets/screenshots/overview/host.svg)

![Placeholder for the PowerPC Workshop overview](docs/assets/screenshots/overview/workshop.svg)

## Start here

- [Connect your first classic Mac](docs/user-guide/tutorials/first-connection.md)
- [Choose the PowerPC or 68K guest](docs/user-guide/how-to/choose-a-guest.md)
- [Browse every module](docs/user-guide/reference/modules/index.md)
- [Read the developer orientation](docs/developer-guide/orientation.md)
- [See the generated protocol reference](docs/generated/asyncapi.md)

The web documentation is built from `mkdocs.yml` at the `/docs/` base path. Run `scripts/docs-serve` for a local preview.

## Product shape

```text
PowerPC Carbon guest ─┐
                      ├─ guest-initiated TCP, framed control + bulk ─ macOS host
68K Toolbox guest ────┘

optional NOW Extension ─ versioned memory table ─ PowerPC guest
```

- The host accepts several named guest sessions and drives one selected machine.
- The PowerPC guest is one Workshop window with native module pages.
- NOW-68K implements an explicit subset of the same contract without shaping the PowerPC codebase.
- The optional resident extension adds bounded observation and act planes; the rest of the product must degrade honestly without it.
- Agent access is a bounded projection of host capabilities, not a second route to the guest socket.

## Capability summary

| Area | PowerPC | 68K | Current evidence |
|---|---|---|---|
| Connection, console, files, processes, software, hardware facts | broad support | supported subset | mixed tested, emulator, and metal evidence |
| Screenshots and streaming | capture and live stream | capture subset | PowerPC metal evidence; 68K gaps remain |
| iCloud, Chat, MCP companion | host + PowerPC surfaces | unavailable | feature-specific evidence |
| Mirror and resident observation | experimental | unavailable | tested/emulator evidence; some metal risks remain |

The short table is navigation, not a claim of parity. The [module reference](docs/user-guide/reference/modules/index.md) states availability, safety, data movement, and failures per module. `docs/contract-coverage.md` keeps **served** separate from **proven**.

## Important limitations

- The listener is for a trusted local network; secure transport is not available yet.
- Distribution is not a signed installer flow. Classic artifacts require fork-preserving transfer.
- Resume-by-offset and some large-transfer behavior remain unreliable.
- NOW-68K has a smaller surface and less physical-machine verification.
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

The docs gate validates structure, links, source dependencies, images, live module inventories, AsyncAPI references, generated pages, rendered accessibility landmarks, and declared derivations. Its mutation self-test proves nine representative failures are refused by name.

## Repository map

| Path | Purpose |
|---|---|
| `contract/` | Wire and resident-memory authorities |
| `now-host/` | Native macOS application |
| `now-guest-ppc/` | PowerPC CarbonLib guest |
| `now-guest-68k/` | 68K Toolbox/MacTCP guest |
| `ext/` | Optional resident extension |
| `docs/user-guide/` | Public task and module documentation |
| `docs/developer-guide/` | Architecture, workflows, and reference |

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing the tree. `AGENTS.md` is the full working convention for human and automated contributors.

## Security

Read [SECURITY.md](SECURITY.md). Do not expose the listener directly to an untrusted network. The release documentation gate will refuse publication until the canonical website origin, website repository, and vulnerability-reporting contact are configured; those values are intentionally not guessed in this branch.
