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
| Hardware census (14 probes) | yes | 14 probes, 5 of them honestly `absent`/`partial` on this hardware. **Until 2026-08-07 the `pccard` probe killed the guest on any Mac without a PC Card Manager** — the trap dispatch checked that its route was open and never that the trap existed. Gated now: `tools/census-survives.py` sweeps all 14 against a real guest inside every bake. | metal-verified (PPC, PB1400c); emulator-verified on mac99/OS 9.1 after the fix; **68K's probes have never run at all** |
| Two Macs on one port, with a picker for which one you are driving | yes | yes | tested; **never run against real hardware** |
| iCloud: the host's Drive, Photos and Contacts served to the guest's iCloud page — drive browser with history and breadcrumbs, live filter-as-you-type, photo preview and download at chosen resolution, contact cards | yes | no | metal-verified (PPC) for Drive and the granted services; the newest layout pass is tested only — [docs/icloud.md](docs/icloud.md) |
| Window **interiors** — application QuickDraw records plus semantic Finder rendering | yes, with the optional NOW Extension for application drawing; Finder never uses it | no — no resident for System 7.1 | **tested:** Finder windows always keep their guest-observed shell. Optional **Emulate Finder Window Interiors** replaces only the item layer with a host-native Finder model; position, size, stacking and lifecycle still follow the guest when synchronization is enabled. **Emulate Desktop** is a separate switch: off preserves Finder's live desktop roster and positions, while on lays out a host-owned Desktop Folder catalog. Application P3 remains emulator-verified only. These Finder corrections have not yet been re-run on metal |
| Offscreen worlds joined to the window they land in — including a world created, drawn and disposed inside one event pass | yes | no | emulator-verified (guest side); the host's composition is tested against committed captures — **the live host app has never been watched composing** |
| Rendering that interior: measured Platinum accent ramps, real per-application icons, inverted selection, scrollbar arrows, derived cell grids, and placeholders graded to the evidence | host-side | host-side | tested against committed captures; judged by eye in [docs/fidelity-sweep-2026-08-06.md](docs/fidelity-sweep-2026-08-06.md), which is a baseline taken **before** the icon pack could resolve — the after-picture has not been measured |
| Showing the Mirror in an already-running host — from the host's Window menu, from an agent over the socket, and from a button on the guest's own Mirror page | asks (button + `showmirror`) | no — out of scope for the arc, not a limit of the machine | emulator-verified (2026-08-06), against the WINDOW-only lifecycle this predates; since 019 the same faces start the poll and then show it wherever the person left it. Original run: against a host launched **without** `--open-mirror` and a guest on mac99/OS 9.1, the Mirror was opened by the guest's own button and, on a second run, by `now_mirror_open` over the agent socket — each time going from "no published Mirror snapshot" to a live polling engine. The console verb answered too. **The menu item is tested only** — driving it means scripting macOS, which is the habit this row exists to make unnecessary |
| The Mirror as a module in the host app, detachable into its own window, with zoom stops at 50/100/200/400% and fit | n/a | n/a | **tested**; one `LiveMirrorView` over one `NOWMirrorSource` in both containers, so an attached and a detached view cannot disagree. Running and where-it-is-shown are separate persisted axes: backgrounding the module does NOT stop the poll, because `now_mirror_drive` and the fidelity sweep read the same source with no window in the picture. Every bitmap is sampled nearest-neighbour, so each power-of-two stop is pixel-exact — that one is defended by a gate that reads the source, because no similarity score can see a blurred hairline |
| Per-application icons and the Platinum theme's own colours, extracted from a real System | host-side | host-side | tested; the pack is a run-time dependency outside git. The host discovers valid packs, defaults to the newest one, and exposes a persisted picker rather than compiling one desk's pack path or identity. The suite runs a second time without it — [docs/asset-pack.md](docs/asset-pack.md) |

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

The classic Mac's Mirror page now separates four guest-owned safety domains:
passive structure observation, Finder enrichment, drawing-content tracing,
and foreground discovery. Only passive structure is enabled by default while
the PB1400 Finder crash is investigated. The guest enforces each setting and
the host consumes it; disabling Finder enrichment therefore prevents the
automatic AppleScripts rather than merely hiding their results. Metal testing
has now isolated the crash to drawing-content tracing: P3 remains experimental,
off by default, and has crashed/restarted Finder on the PowerBook 1400c. Finder
is now permanently excluded at both host and guest command boundaries; raw-A5
arming is refused because it cannot enforce process identity. Finder interiors
instead use bounded, current-container semantic reads carrying the guest HFS
path, view, order, live bounds and selection. The host owns Finder interaction
too, including desktop icons: icon and list selections update immediately, control/right-click toggles,
shift-click and rubber-band gestures extend the selection, the wheel and thumb
scroll locally while their guest acts settle, and Return/Enter, Escape and
Command-O drive rename, cancel/deselect and open. That path is **tested, not yet
metal-verified**. View switches reuse retained directory state while bounded
icon-art pages fill in, rather than blocking the presentation on a new full
Finder draw. The right-aligned application menu is synthesized from the live
process roster when Finder omits its rows, including Hide, Hide Others, Show
All, and application switching. A **Rebuild State** button now invalidates the
in-flight observation generation, retained scene engine/history, content and
Finder catalogs, blanks the old projection, and starts a fresh read while
preserving the operation journal. P3 remains available to every
non-Finder application, but the host's ordinary `record` arm now touches only
the exact requested window. The QDExtensions patch, heap census, and offscreen
GWorld hooks are one explicit `probe` diagnostic tier after that tier correlated
twice with Sherlock 2 Type 1 crashes on a PB1400c.

The host has independently controllable Finder ownership boundaries. Enabling
**Emulate Finder Window Interiors** keeps each guest-observed Finder window and
replaces only its interior with host-native icon, list or small-icon content
over the existing `file.list`, `file.move`, `launch`, and script operations.
Selection, marquee, rename, scrolling, sorting and folder navigation settle
locally. The guest remains authoritative for the window title, chrome,
frontness and visibility. The synchronization controls couple open/close and
position/size to that same guest window; acts are optimistic, then a later
guest scene confirms or reconciles them. Enabling the mode never invents or
opens a root window. Geometry acts made before the guest names its window are
held and dispatched once that exact reference arrives. The root is the guest's configured file share—normally
the whole boot volume when **Share entire boot volume** is enabled—not an
authority bypass. This mode is Tested and still needs its first metal run. The
guest-follow mode remains available when the toggle is off.

Desktop ownership is independent. With **Emulate Desktop** off, Finder's live
desktop roster—including explicitly queried mounted disks and Trash—is drawn
at the guest's reported positions. With it on, a bounded `Desktop Folder`
listing is laid out locally while guest-observed system objects remain present.
Switching this control clears only the desktop projection, so the next frame
cannot reuse the other mode's positions. Opening an emulated desktop folder
fills the host interior first, then optionally couples the matching open to the
guest. When the guest-follow Finder roster
cannot provide an open window's items but has named its directory, the same
bounded file-list catalog supplies a semantic icon fallback. No path recursively
walks the disk. The host itself always launches with Mirror stopped; reconnects
can resume only an intent established during that same host process.

The final host build has been emulator-verified against OS 9.1 for the Finder
read boundary: the live desktop roster contained the mounted `Macintosh HD`
volume and correctly classified Trash, and the open disk window retained all
13 visible semantic items. The equivalent Wallstreet/PB1400c pass remains due.

**The slow loops had a second cause on our own side, and it is now
fixed — by spending a safety argument.** The guest's act client waits for
a target to take an armed act in two phases of 5 s each, and that wait
**did not pump the wire**, so an act nobody takes held the connection off
for ~10 s and every scene request in that window reported the act's
duration as its own. Measured: an act refused after 6.6 s and a scene
request issued in the same instant answered in 6634 ms, the same number
twice — **one event seen from both ends**, not two problems. It also
lapsed the anchor plane's ten-second lease, because renewal rides the
traffic that wait held off, so the next act refused.

The wait now pumps. Re-measured on the same shape: the act still costs
its whole deadline (5.07 s — the machine still will not take it) and
**80 scene requests were answered during it, median 65 ms**, where there
used to be one at 6634 ms. A taken act is unchanged at 0.08–0.20 s.

**What it cost is written down rather than buried.** Pumping inside an
armed window is exactly the re-entrancy the no-hijack work exists to
prevent: NOW's act plane is a single cell, and until now the only thing
keeping a second request out of it was that this wait did not service the
wire. That protection was traded away deliberately, with Michelle's
approval, for the latency above. What stands in its place is narrower —
a one-act-at-a-time interlock that refuses a second act with `act-busy`
before it can write a field, watched firing on a machine. It guards the
act cell and nothing else; scene walks, census and file transfers now all
run while a trap patch is live in every process, and nothing has measured
whether that is safe. See
[docs/no-hijack-criterion.md](docs/no-hijack-criterion.md) (the box at
the top), [docs/nested-loops.md](docs/nested-loops.md) and
[docs/open-issues.md](docs/open-issues.md). Emulator only; no metal.

**Acts stop binding when the host's cycle runs long.** The anchor
plane's OWNER lease is 10 seconds and only a `scene.request` renewed it,
so a cycle longer than the lease disarmed the planes with nothing said.
That accounts for two symptoms that looked like guest bugs: a
quit-time modal that appeared to be missing, and a Cancel button that
appeared to refuse. Nothing was taking the planes down; the host had
stopped asking inside the lease. Renewal now rides any inbound host
frame, and a scene waits briefly for the arm echo instead of walking
blind and reporting the blindness as an empty screen. It is not the
*whole* of them, as this once claimed: the act wait above lapsed the
same lease from the guest's side. That second way in is closed too, since
the wait now pumps and the traffic that renews the lease runs during it.

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

Two things measured the same day and **not** fixed: a background
application cannot be armed for content capture AT ALL (nothing can make
a process pump that is not being scheduled); and every number above is
from an emulator — a PowerBook 1400c is far slower, and for the wire the
emulator likely understates the win rather than flattering it.

**The windows gained interiors on 2026-08-06, and the honest word for
all of it is emulator-verified.** Until then a mirrored window was a
frame with a title: the host knew a window existed and what controls it
declared, not what the application had *drawn* inside it. The content
plane now carries that — a ring of QuickDraw records, drained and
replayed — and the hard case is solved rather than deferred: an
application that composes its picture in an offscreen world and blits
the finished thing in used to present as one opaque rectangle. Diagnostic
`probe` mode patches the QDExtensions dispatch in the target's own context
and hooks each world **at creation**, before anything is drawn into it.
A world created, drawn, blitted and disposed inside a single event pass
— which is how the emulator captures of Sherlock 2 and Appearance draw, and which no
after-the-fact search can reach — is joined to the window it lands in,
nested worlds included.

**What that costs, stated plainly.** It needs the optional NOW
Extension: without the resident there is no interior at all, and the
verb says so rather than answering emptily. The records were watched crossing
the wire from Sherlock 2 on an emulated Mac OS 9.1. On a PB1400c the full
offscreen tier becoming active was followed by Sherlock's Type 1 crash twice.
Applications are not blacklisted: ordinary `record` now keeps only the exact-
window hook, while `probe` names and contains the metal-unsafe mechanisms. A
reboot is required after using `probe`, because the QDExtensions trap patch
cannot safely be removed while code may be inside it. The ring is 64 KiB
and the host drains twelve pages a cycle, so a busy application can
still outrun it — the drain reports what it lost rather than presenting
a gap as a picture. And a render is not a photograph: where the host has
no art for something it draws a graded placeholder, and how close the
whole picture actually comes was judged by eye for the first time in
[docs/fidelity-sweep-2026-08-06.md](docs/fidelity-sweep-2026-08-06.md),
whose red list is open work. Three fixes aimed at that list — region
fidelity and `INVERT`, and a file-type mangling that currently defeats
the per-application icon lookup — are **in flight as this is written**
and are not described here as done.

## Try the modern half

The host application needs no vintage hardware, and most of this
repository can be worked on without any:

```bash
scripts/test-all
```

That runs four gates, cheapest first, stopping at the first failure and
naming it: the guests' native logic tests, MirrorKit's own suite, both
guest cross-builds (skipped if you have no Retro68), then the host
suites and both Xcode configurations. Green there means **tested** — not
metal-verified, and the guest stage means only that the guests compile.
To build and launch the host app itself:

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
| `ext/` | The optional resident 68K component — the anchor, transition and content planes, including the QDExtensions trap patch that hooks an offscreen world at creation. Always optional: the product degrades honestly without it. |
| `mirror/` | Vendored into this tree as tracked files: **MirrorKit**, its own SwiftPM package, which turns drained records into scenes and renders them. It has its own suite, and `scripts/test-all` runs it (stage 2). The Platinum asset pack is **not** in this directory and not in git at all — it is a dependency resolved at run time from `~/Lab/Assets/now-mirror-assets/pack-*/Resources`, and both gates run their suite a second time with `NOW_MIRROR_ASSETS=none` so the absent-pack path is watched rather than assumed ([docs/asset-pack.md](docs/asset-pack.md)). |
| `assets/` | Art the product ships, each pack with the generator that draws it. `assets/icons/classic/` is the guests' icon as a classic family (`ICN#`/`icl4`/`icl8`/`ics#`/`ics4`/`ics8`), drawn at 32×32 and 16×16 rather than scaled down, and not wired into a build yet. `assets/icons/macos/` is the host app icon, which generates the asset catalog the Xcode target builds. |
| `docs/` | Architecture, measurements, and the ledgers. `docs/local/` is gitignored scratch. |
| `spikes/` | Throwaway feasibility probes, kept for their findings. |

## Where to read next

- [docs/status.md](docs/status.md) — what works and what does not, in full.
- [docs/architecture.md](docs/architecture.md) — the design and its rules.
- [docs/naming.md](docs/naming.md) — the naming scheme and the `src/` domain split, and why the host has no architecture suffix.
- [docs/open-issues.md](docs/open-issues.md) — the ledger: broken versus unverified. It opens with a dated pointer list of the biggest open items.
- [docs/known-wrong.md](docs/known-wrong.md) — the third category: what NOW knowingly ships that disagrees with the real Mac, or knowingly does not do, each with the measurement, the reason it is left, and what closing it would cost. A defect nobody has noticed is an open issue; one we measured and chose to keep is a decision, and it belongs somewhere a reader can argue with it.
- [docs/mirror-state-of-play-2026-08-06.md](docs/mirror-state-of-play-2026-08-06.md) — the Mirror specifically: what a person driving it experiences today, good and bad.
- [CONTRIBUTING.md](CONTRIBUTING.md) — including what you can do with no vintage hardware.
- [AGENTS.md](AGENTS.md) — the full working conventions, for humans and agents alike.
- [SECURITY.md](SECURITY.md) — the threat model, stated rather than implied.

## Licence

MIT — see [LICENSE](LICENSE).
