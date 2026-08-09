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
| Remote console (`exec`) — drive either guest's console from the host | yes | yes | emulator-verified (68K); PPC half untested live |
| Files: browse, pull, push, rename, move, trash | yes | browse, pull, push | metal-verified (PPC) |
| Screenshots, one-shot, either direction | yes | capture only; pixels do not cross | metal-verified (PPC); 68K's raw read fixed for 24-bit addressing but unrun on metal |
| Live screen streaming, with recording | yes | no | metal-verified |
| Processes: list, launch, quit, front | yes | yes | emulator-verified |
| Installed software: applications, extensions, control panels | yes | yes, without versions or a running flag | metal-verified (PPC); 68K tested only |
| Hardware census (14 probes) | yes | 14 probes, 4 of them honestly `absent`/`refused` on this hardware | metal-verified (PPC); **68K's probes have never run at all** |
| Two Macs on one port, with a live-guest menu for which one every host module drives | yes | yes | tested; **never run against real hardware** |
| iCloud: the host's Drive, Photos and Contacts served to the guest's iCloud page — drive browser with history and breadcrumbs, live filter-as-you-type, photo preview and download at chosen resolution, contact cards | yes | no | metal-verified (PPC) for Drive and the granted services; the newest layout pass is tested only — [docs/icloud.md](docs/icloud.md) |

The cells that say "no" are not oversights.
[docs/contract-coverage.md](docs/contract-coverage.md) is the inventory
of who serves what, message by message, with *served* and *proven* kept
as separate columns.

**The headline gaps:** resume-by-offset hangs; one large transfer in
about six degrades badly; an unreachable host presents as a hang rather
than naming the address it cannot reach; NOW-68K's census can now report
its own CPU, RAM and ROM but not one of its probes has run on a
Macintosh; NOW-68K's file family has never run on the
PowerBook 180c it is actually for; and NOW-68K's capture-across-the-wire
read a 24-bit-truncated address on that machine until 2026-07-28 — fixed
by switching to 32-bit addressing around the read, and not yet re-run
there. [docs/status.md](docs/status.md)
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

That command uses the Xcode target and the repository's configured
Developer team. Its stable identity is required for Chat's saved
credentials, and its entitlements are required for Photos and Contacts.
The first build may ask Xcode to refresh its managed provisioning profile.

For scratch work on pages that need neither Keychain nor privacy
entitlements, an ad-hoc build remains available:

```bash
./scripts/build-host-app --adhoc /private/tmp/now-host-scratch
```

An ad-hoc build deliberately cannot read Chat credentials saved by the
Developer-signed app. Re-signing it produces a new identity, so using it
for Chat would recreate the repeated Keychain authorization problem this
split exists to prevent.

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
swift build --package-path now-host --product NOWAgentCompanion
```

Build products stay outside the repository, and the bundling script
enforces it.

## Layout

| Path | What lives there |
|---|---|
| `contract/asyncapi.yaml` | **The source of truth.** Every message, the frame header, connection rules, `x-commands`. A behaviour change starts here. |
| `now-guest-ppc/` | PowerPC Carbon guest. `src/` is split by domain: `core/` (wire, JSON, prefs, logging), `workshop/` for the one-window shell, then one directory per Workshop page — `console/`, `files/`, `cloud/`, `processes/`, `screenshots/`, `software/`, `census/`, `network/`, `logs/`, `connection/`, `preferences/`, plus `commands/` and `peek/`. |
| `now-guest-68k/` | NOW-68K. A *sibling* of the Carbon guest, not a port of it, and filed the same way: `core/`, `ui/`, `commands/`, `console/`, `connection/`, `files/`, `processes/`, `screenshots/`, `census/`. |
| `now-guest-shared/` | Source compiled by **both** guests, one file per unit rather than a copy each. Only for logic that is genuinely identical on both machines — see docs/naming.md for the bar. |
| `now-host/` | Swift package (`GuestListener` + modules) and `NewOldWorld.xcodeproj` for signed builds. |
| `ext/` | The optional resident 68K component. Always optional — the product degrades honestly without it. |
| `assets/` | Art the product ships, each pack with the generator that draws it. `assets/icons/classic/` is the guests' icon as a classic family (`ICN#`/`icl4`/`icl8`/`ics#`/`ics4`/`ics8`), drawn at 32×32 and 16×16 rather than scaled down, and not wired into a build yet. `assets/icons/macos/` is the host app icon, which generates the asset catalog the Xcode target builds. |
| `docs/` | Architecture, measurements, and the ledgers. `docs/local/` is gitignored scratch. |
| `spikes/` | Throwaway feasibility probes, kept for their findings. |

## Where to read next

- [docs/status.md](docs/status.md) — what works and what does not, in full.
- [docs/architecture.md](docs/architecture.md) — the design and its rules.
- [docs/naming.md](docs/naming.md) — the naming scheme and the `src/` domain split, and why the host has no architecture suffix.
- [docs/open-issues.md](docs/open-issues.md) — the ledger: broken versus unverified.
- [CONTRIBUTING.md](CONTRIBUTING.md) — including what you can do with no vintage hardware.
- [AGENTS.md](AGENTS.md) — the full working conventions, for humans and agents alike.
- [SECURITY.md](SECURITY.md) — the threat model, stated rather than implied.

## Licence

MIT — see [LICENSE](LICENSE).
