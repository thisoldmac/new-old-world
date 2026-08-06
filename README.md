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
| Two Macs on one port, with a picker for which one you are driving | yes | yes | tested; **never run against real hardware** |
| iCloud: the host's Drive, Photos and Contacts served to the guest's iCloud page — drive browser with history and breadcrumbs, live filter-as-you-type, photo preview and download at chosen resolution, contact cards | yes | no | metal-verified (PPC) for Drive and the granted services; the newest layout pass is tested only — [docs/icloud.md](docs/icloud.md) |

The cells that say "no" are not oversights.
[docs/contract-coverage.md](docs/contract-coverage.md) is the inventory
of who serves what, message by message, with *served* and *proven* kept
as separate columns.

**The headline gaps:** **a dialog on the Macintosh no longer ends the
session — demonstrated on an emulator, not argued from the code.** The machine
is cooperatively scheduled, so an application that blocks starves every
other one — a Finder alert was measured on 2026-08-05 starving the whole
guest for over 90 seconds, past the silence window after which the host
declares a guest gone. Both halves now know better: the guest stops
counting time it was not scheduled against its own dead-link clock, and
with the optional NOW Extension installed the machine holds a second
connection that answers for itself while every application is starved.
On 2026-08-06 an application starved for 108 seconds kept its session,
with the resident pinging three times through the gap. **Still open:**
**without the extension a starvation past the host's window still ends
the session** — watched, by mutation, on the same 110-second wedge; the
guest-side fix keeps the guest from tearing the link down but nothing
answers for the machine while it is away. Nor can anything on either
side dismiss the dialog: the machine is legible and survivable while
wedged, not serviceable. And the resident channel has been watched on an
emulator only — never on real hardware, and never on 68K/System 7.1. Beyond that: resume-by-offset hangs; one large transfer in
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

**The Mirror got much cheaper on 2026-08-06, and the cost that is left
is on the modern side.** Measured on an emulated Power Mac with the
guest's own microsecond clock, which the scene now carries permanently
as `meta.phases` — before that it reported one tick-quantised number
that could not see anything under 17 ms, and reasoning from it produced
two confidently wrong answers in one day. A scene walk with NOW
frontmost cost ~1.1 s and now costs 0.7–1.0 ms in the steady state; the
focus-change scene fell from 886 ms to 0.7 ms. Almost all of it was a
`FindControl` grid sweep of NOW's own window, and an application does
not have to DISCOVER controls it made — the registry that already
recorded each control's kind now says which exist. A separate lie died
alongside it: `FindControl` refuses an *inactive* window, so with
another application in front the sweep probed 3,724 points, found
nothing, and the mirror reported the window as EMPTY — an absence it had
never observed. The registry cannot speak for a window this application
did not make, so a foreign window now **retracts** the control plane
rather than claiming an empty one — that retraction path is built and
has not itself been watched run. Idle wire traffic fell about 90% with
scene deltas, whose baseline is named by a digest of what the consumer
actually holds rather than by a sequence number, so a drifted host
repairs itself on the next round trip instead of quietly diverging.

**The waiting was fixed too, and that moved the bottleneck to the
host.** A round trip took ~115 ms even when the answer was a zero-byte
"nothing changed", because the guest's event loop slept up to 100 ms
before noticing a request. An Open Transport notifier now wakes the
process when its socket has something to say, taking the round trip to
~10 ms while **keeping** the idle sleep, so the rest of the Macintosh is
not starved to make NOW quick. That is tested here and **has not run on
metal**; `wirestat wake off` disables it if it misbehaves there. What it
exposes is the host's own cycle: `decode_ms` never measured decoding — it
brackets publish-minus-deliver, and inside that bracket the host waits
on content joining plus **two paged AppleScript round trips into the
guest's Finder, run every cycle**. Our own CPU work in there is 4 ms; 12
windows measured 714 ms and 3 windows measured 12,559 ms, because the
variable is the Finder's responsiveness, not the window count. It is a
priority inversion — optional enrichment stalls the frame, and a stalled
frame lapses the act plane's lease. Being fixed now, in
[plan 014](docs/plans/2026-08-06-014-feat-a-frame-that-does-not-wait-for-the-finder-plan.md).

**Acts stop binding when the host's cycle runs long.** The anchor
plane's OWNER lease is 10 seconds and only a `scene.request` renewed it,
so a cycle longer than the lease disarmed the planes with nothing said.
That is the whole of two symptoms that looked like guest bugs: a
quit-time modal that appeared to be missing, and a Cancel button that
appeared to refuse. Nothing was taking the planes down; the host had
stopped asking inside the lease. Renewal now rides any inbound host
frame, and a scene waits briefly for the arm echo instead of walking
blind and reporting the blindness as an empty screen.

**The guest's console reported its own successes as failures.** Its
fallback renderer understood only a reply shape that no verb emits on
success, so six working verbs printed "command failed"; twelve more
render correctly but cannot take arguments from the console at all.
`CommandParityTests` could not catch it, and that is a stated limit of
the gate: a parity table says a verb is PRESENT, never that it WORKS.
Two more from the same pass: Apple menu items did nothing, because the
act dispatched correctly and then fell off the end of a switch with no
Apple case; and Windows ▸ Workshop timed out for a hidden application,
because hiding NOW does not move the front process and `SelectWindow`
shows nothing for a hidden app.

Two things measured the same day and **not** fixed: a background
application cannot be armed for content capture AT ALL (nothing can make
a process pump that is not being scheduled), and every number above is
from an emulator — a PowerBook 1400c is far slower, and for the wire the
emulator likely understates the win rather than flattering it.

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
system notifications need a real one — `now-host/NewOldWorld.xcodeproj`
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
swift build --package-path now-host --product NOWAgentCompanion
```

Build products stay outside the repository, and the bundling script
enforces it.

## Layout

| Path | What lives there |
|---|---|
| `contract/asyncapi.yaml` | **The source of truth.** Every message, the frame header, connection rules, `x-commands`. A behaviour change starts here. |
| `now-guest-ppc/` | PowerPC Carbon guest. `src/` is split by domain: `core/` (wire, JSON, prefs, logging), `workshop/` for the one-window shell, then one directory per Workshop page — `console/`, `files/`, `cloud/`, `processes/`, `screenshots/`, `software/`, `census/`, `network/`, `logs/`, `connection/`, `mirror/`, `preferences/`, plus `commands/` and `peek/`. |
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
