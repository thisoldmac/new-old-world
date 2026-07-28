# New Old World ("NOW")

**Use a 1993 Macintosh from a 2026 one.** NOW is two polished
applications — one on each machine — joined by a single versioned
contract over one multiplexed wire. Browse the old Mac's disk, pull and
push files that arrive intact, watch its screen live, see what it is
running, and drive it from a console. Both halves are meant to feel
native to their own machine: not to each other, and not to the web.

There are two guests. The **PowerPC Carbon guest** runs on Mac OS 8.6
through 9.2.2. **NOW-68K** speaks a subset of the same contract from a
68K Macintosh under System 7.1 over MacTCP — for machines Carbon cannot
reach at all.

> **Status: rough around the edges, and specific about which edges.**
> This is a working project, not a release. The table below is the short
> version; [docs/status.md](docs/status.md) is the long one, and it is
> written to be read *before* you rely on anything.

## Screenshots

**None yet — and for a project about two Macintosh interfaces, that is
the largest gap in this document.** It is tracked as one, in
[docs/open-issues.md](docs/open-issues.md), rather than left to be
noticed. Adding them: see [docs/images/README.md](docs/images/README.md).

## What you get

| Capability | PowerPC guest | NOW-68K | Best evidence |
|---|---|---|---|
| Persistent connection, heartbeat, reconnect | yes | yes | metal-verified |
| Console — one command table, both faces | yes | yes | tested; 68K's own console metal-verified |
| Files: browse, pull, push, rename, move, trash | yes | browse, pull, push | metal-verified (PPC) |
| Screenshots, one-shot, either direction | yes | capture only; pixels do not cross | metal-verified (PPC) |
| Live screen streaming, with recording | yes | no | metal-verified |
| Processes: list, launch, quit, front | yes | yes | emulator-verified |
| Hardware census (14 probes) | yes | none | tested |

The cells that say "no" are not oversights.
[docs/contract-coverage.md](docs/contract-coverage.md) is the inventory
of who serves what, message by message, with *served* and *proven* kept
as separate columns.

**The headline gaps:** resume-by-offset hangs; one large transfer in
about six degrades badly; an unreachable host presents as a hang rather
than naming the address it cannot reach; NOW-68K cannot report its own
CPU, RAM or ROM; and NOW-68K's file family has never run on the
PowerBook 180c it is actually for. [docs/status.md](docs/status.md)
carries the rest, and [docs/open-issues.md](docs/open-issues.md) is the
ledger.

## Try the modern half

The host application needs no vintage hardware, and most of this
repository can be worked on without any:

```bash
scripts/test-all
```

That runs the guests' native logic tests, both guest cross-builds
(skipped if you have no Retro68), then the host suites and both Xcode
configurations — cheapest first, stopping at the first failure. To build
and launch the host app itself:

```bash
./scripts/build-host-app /private/tmp/now-host-product
```

```bash
open "/private/tmp/now-host-product/New Old World.app"
```

The ad-hoc signature that script produces is fine for development, but
system notifications need a real one — `host/NewOldWorld.xcodeproj`
builds the same sources as an app target. Open it in Xcode, pick a
signing team, and build.

## Build the guests

Both need [Retro68](https://github.com/autc04/Retro68). Point `.env.lab`
at your toolchains (copy `.env.lab.example`; see
[docs/lab-setup.md](docs/lab-setup.md)), then:

```bash
scripts/build-guests
```

The PowerPC guest requires **CarbonLib 1.6** on OS 9.1 — stock 1.2
exports no Open Transport. It resolves OT at runtime and says so kindly
when it is missing, rather than failing to launch.

The optional agent companion is a separate executable with no
checked-in client configuration:

```bash
swift build --package-path host --product NOWAgentCompanion
```

Build products stay outside the repository, and the bundling script
enforces it.

## Layout

| Path | What lives there |
|---|---|
| `contract/asyncapi.yaml` | **The source of truth.** Every message, the frame header, connection rules, `x-commands`. A behaviour change starts here. |
| `guest/` | PowerPC Carbon guest. `wire.c` is the connection manager, `capture`/`pixels` the capture engines; the human surface is the Workshop — `workshop_*` plus one `*_module.c` per page. |
| `guest68k/` | NOW-68K. A *sibling* of the Carbon guest, not a port of it. |
| `host/` | Swift package (`GuestListener` + modules) and `NewOldWorld.xcodeproj` for signed builds. |
| `ext/` | The optional resident 68K component. Always optional — the product degrades honestly without it. |
| `docs/` | Architecture, measurements, and the ledgers. `docs/local/` is gitignored scratch. |
| `spikes/` | Throwaway feasibility probes, kept for their findings. |

## Where to read next

- [docs/status.md](docs/status.md) — what works and what does not, in full.
- [docs/architecture.md](docs/architecture.md) — the design and its rules.
- [docs/naming.md](docs/naming.md) — the guest naming scheme, and the one question still open.
- [docs/open-issues.md](docs/open-issues.md) — the ledger: broken versus unverified.
- [CONTRIBUTING.md](CONTRIBUTING.md) — including what you can do with no vintage hardware.
- [AGENTS.md](AGENTS.md) — the full working conventions, for humans and agents alike.
- [SECURITY.md](SECURITY.md) — the threat model, stated rather than implied.

## Licence

MIT — see [LICENSE](LICENSE).
