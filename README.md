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
| Persistent connection, heartbeat, reconnect | yes | yes | metal-verified — but **surviving a starved machine is emulator-only**, see below |
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
exposed was the host's own cycle: `decode_ms` never measured decoding —
it brackets publish-minus-deliver, and inside that bracket the host
waited on content joining plus **two paged AppleScript round trips into
the guest's Finder, run every cycle**. Our own CPU work in there is 4 ms;
12 windows measured 714 ms and 3 windows measured 12,559 ms, because the
variable is the Finder's responsiveness, not the window count. It was a
priority inversion — optional enrichment stalled the frame, and a
stalled frame lapsed the act plane's lease.

**That is fixed** ([plan 014](docs/plans/2026-08-06-014-feat-a-frame-that-does-not-wait-for-the-finder-plan.md),
2026-08-06). Splitting the bracket named the culprit: the visibility
census, ~96% of it, paid every cycle for state that changes only when a
process starts, quits, hides or shows. The frame now publishes on decode
and the Finder complements fold in beside it, saying so honestly when
they have not arrived yet. Measured on an emulator across 258 cycles,
every one `outcome=ok`: `decode_ms` median **353 ms → 16 ms**, whole
cycle **364 ms → 25 ms**, and a cycle in which a Finder window opened
**1,936 ms → 26 ms**. The Finder still takes 1.5 s to read a roster —
that has not changed and cannot be — but a 1.5 s roster read now sits
beside a 26 ms cycle instead of becoming one. **Emulator only; no part
of this has run on metal.** One Macintosh case is beyond any host-side
repair: a modal owned by the *Finder itself* starves the whole
cooperative machine, NOW included, and nothing here helps it. A modal
owned by a *foreign* application turns out to be far less than that —
measured, a **20× tax and no starvation at all** (scene median 21 ms
idle → 413 ms), and acts work straight through it.

**But the slow loops are NOT closed, and the cause is now named.** The
9–12 second Mirror loops have a second cause, on our own side, and it is
still there. The guest's act client waits for a target to take an armed
act in two phases of 5 s each, spinning in a nested loop that **does not
pump the wire** — so an act nobody takes holds the connection off for
~10 s, and every scene request in that window reports the act's duration
as its own. Measured: an act refused after 6.6 s and a scene request
issued in the same instant answered in 6634 ms, the same number twice.
The two 12-second numbers in Michelle's log are therefore **one event
seen from both ends**, not two problems — and because the anchor plane's
ten-second lease is renewed by the traffic that wait holds off, a long
act lapses the lease the paragraph below repaired, and the next act
refuses. Investigated 2026-08-06, **not fixed**: pumping inside an armed
window is exactly the re-entrancy the no-hijack work exists to prevent,
so it is a decision rather than a patch. See
[docs/status.md](docs/status.md) and
[docs/nested-loops.md](docs/nested-loops.md).

**Acts stop binding when the host's cycle runs long.** The anchor
plane's OWNER lease is 10 seconds and only a `scene.request` renewed it,
so a cycle longer than the lease disarmed the planes with nothing said.
That accounts for two symptoms that looked like guest bugs: a
quit-time modal that appeared to be missing, and a Cancel button that
appeared to refuse. Nothing was taking the planes down; the host had
stopped asking inside the lease. Renewal now rides any inbound host
frame, and a scene waits briefly for the arm echo instead of walking
blind and reporting the blindness as an empty screen. It is not the
*whole* of them, as this once claimed: the act wait above lapses the
same lease from the guest's side, so the fix removed one way in and left
another.

**An alert rendered the wrong buttons, and they did nothing.** Recorded
as "the wrong default button" — it was wrong buttons, dead clicks and a
missing message, and it is the alert path generally rather than one
application. The guest was right about everything but the text: the
Dialog Manager's default-outline slots are `userItem`s, one of which
*wraps* the OK button's rect, and the host drew a placeholder for every
item kind it could not draw — so a hatched box sat on top of the real
button, and clicks resolved to the placeholder, which has nothing to
answer with. The message text was a second bug: a DITL holds the
resource template, while an application writes its message into the
item's own handle. Fixed both halves 2026-08-06; **tested and rendered,
but no drive has watched the repaired alert in the Mirror window**, and
the alert's icon is still a placeholder.

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

Three things measured the same day and **not** fixed: a background
application cannot be armed for content capture AT ALL (nothing can make
a process pump that is not being scheduled); the act wait above still
blocks the wire for up to ten seconds, which is the named and open cause
of the slow loops; and every number above is
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
