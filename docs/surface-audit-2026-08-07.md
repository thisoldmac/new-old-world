# One capability, how many roads? — a surface audit

**Read-only audit, taken 2026-08-07 03:44 UTC** against
`claude/gworld-interior-host-render-98ddd5` at `f030d741`, plus a snapshot
of seventeen in-flight `claude/018-*` branches. Nothing here was
implemented. Every finding ends in a recommendation and nothing else.

It exists because of a question worth asking out loud:

> in fact, might be worth taking a once over of our broader now mcp and
> surfaces against the work we've been doing in mirror. kinda silly if we
> have multiple paths to do the same thing.

The suspicion is right, and sharper than it sounds. **Fourteen findings
below are cases where two paths can return different answers to the same
question, and one of them has already been watched doing it on a real
Macintosh.** The MCP surface, by contrast, turns out to be a clean facade
over a single lane — its problem is not duplication but that seven of its
forty-one tools cannot reach the machine at all.

---

## Read this first: two faces is not duplication

[command-parity.md](command-parity.md) requires every guest capability to
be reachable from the console a person types at *and* from the wire the
host drives, **with one implementation behind them**.
`CommandParityTests` fails the build otherwise. That is a rule, not a
smell, written because `process.list` shipped wire-only and nothing
noticed for a day.

So a capability appearing as a console verb *and* a wire verb *and* an MCP
tool is **one road with three doors** — as long as one function produces
the answer. This report calls something duplication only when **two
implementations can disagree**.

The four shapes that count, ordered by how much they mislead a reader:

1. Two paths answering the same question from **separate code**.
2. A capability a surface **advertises and cannot deliver**.
3. Two ways to ask that return **differently-shaped answers**, so a
   caller must know which one it used.
4. A capability with **no path at all**, or one reachable only by a road
   that should not be the normal one.

---

## How these numbers were derived

Every count was produced by running the derivation commands
`contract-coverage.md` and `mcp-coverage.md` publish, on **2026-08-07**.
None was copied from either document. A derived number is true at the
moment it is derived; **sibling branches will move all of these**, and the
last section says which.

```
grep -oE 'json_type_is\([a-z_]+, *"[a-z.]+"\)' now-guest-ppc/src/core/wire.c \
  | grep -oE '"[a-z.]+"' | tr -d '"' | sort -u                       # PPC inbound
grep -o 'strcmp(type, "[a-z.]*")' now-guest-68k/src/core/wire68.c \
  | grep -oE '"[a-z.]+"' | tr -d '"' | sort -u                       # 68K inbound
grep -oE 'strcmp\(name, *"[a-z0-9]+"\)' now-guest-ppc/src/commands/commands.c \
  | grep -oE '"[a-z0-9]+"' | tr -d '"' | sort -u                     # PPC verbs
grep -oE '\{ *"[a-z0-9]+"' now-guest-68k/src/commands/commands68.c \
  | grep -oE '"[a-z0-9]+"' | tr -d '"' | sort -u                     # 68K verbs
grep -rhoE '"now_[a-z_]+"' now-host/Sources/NOWAgentIntegration/ \
  | tr -d '"' | sort -u                                              # MCP tools
```

| Derived 2026-08-07 | |
|---|---|
| `x-commands` declared | **42** |
| PPC serves | **39** (absent: `put`, `cancel`, `shotdiag` — all argued) |
| NOW-68K serves | **13** |
| PPC inbound message types | **48** |
| NOW-68K inbound message types | **23** |
| Census probes, per guest | **14** |
| MCP tools in `HostProjectionCatalog` | **41** |
| Agent-socket operations | **33** |
| Distinct guest capabilities any MCP row *exposes* | **34** |

These match what `contract-coverage.md` publishes today (42 / 39 / 13 and
48 / 23), so its tables are accurate as of this morning. Its prose is not
— see F14. `mcp-coverage.md` records a last-derived date of 2026-07-30;
its tables are gated by `MCPCoverageTests`, its prose is not.

---

## The map: capability → every path that reaches it

### The planes, and where each one's data actually comes from

| Plane | Question | Carrier | Origin |
|---|---|---|---|
| **process** | what runs, what is front, what is faceless | `process.list`, `process.front/quit/shot` | app-side Toolbox — no resident needed |
| **scene** | the whole desktop as IR v2 | `scene.request` → `scene.begin`/frames/`scene.end` | app-side foreign-memory reads following resident anchors |
| **perceive** | one process's tree, and the opaque refs the act plane needs | `observe`, `axtree`, `elements`, `axsnap`, `handle` | the same anchors, **its own walk** |
| **act** | drive it | `winact`, `ctlact`, `ditemact`, `menuact`, `textget/set`, `activate` | resident foreign-context execution; addresses only refs `observe` minted |
| **content** | what an application actually *drew* | `qdtrace` | resident QuickDraw `grafProcs` ring, joined host-side by GrafPort address |
| **census** | 14 hardware probes | `census`, `vprobe` | app-side Gestalt / GDevice walks |
| **host-derived** | desktop icons, per-process visibility | AppleScript over `script` | `NOWMirrorSource`, merged host-side |

### Observation

| Capability | Console | Wire | Agent socket | MCP tool | One implementation? |
|---|---|---|---|---|---|
| list processes | `ps` | `process.list` | `list_processes` | `now_list_processes` | **No** — five walks (F3) |
| software inventory | `sw` | `software.list` | `software_inventory` | `now_software_inventory` | **No** — live sweep vs cache (F8) |
| directory listing | `ls` | `file.list` | `guest_files_list` | `now_guest_files_list` | Yes — `now_files_list` |
| screen capture | `screenshot` | `capture.request` | `capture` | `now_capture_screen` | **No** — two paths, duplicated tuning |
| hardware census | `census` | `census.request` | `census` | `now_hardware_census` | Per probe yes; overlaps `gestalt`/`vprobe` (F10) |
| machine facts | `gestalt` | `gestalt` | `machine_facts` | `now_machine_facts` | Overlaps census (F10) |
| framebuffer probe | `vprobe` | `vprobe` | `diagnostics` | `now_framebuffer_probe` | Overlaps census video (F10) |
| element walk | — *(not typeable)* | `elements`/`observe`/`axtree` | — | `now_observe_elements` | One walk internally; **separate from the scene's** (F2) |
| scene | — | `scene.request` | `mirror_read` | `now_mirror_*` (7) | Yes — one lane, seven thin wrappers |
| log tail | `tail` | `tail` | `guest_log_tail` | `now_guest_log_tail` | **Advertised, dead on MCP** (F1) |
| resident/plane facts | `mirror` | `mirror` | `mirror_read --intention lifecycle` | `now_mirror_lifecycle` | One table, **two derivations** (F11) |
| network facts | `net` | `net` | — | — | Overlaps `gestalt`'s OT row (F10) |

### Acting

| Capability | Console | Wire | Agent socket | MCP tool | One implementation? |
|---|---|---|---|---|---|
| bring an app forward | `front` (by name, **confirmed**) | `process.front` (by PSN, **accepted**) | `bring_to_front` | `now_bring_to_front` | Shared primitive, **different claim** (F6) |
| ask an app to quit | `quit` | `process.quit` | `request_quit` | `now_request_quit` | Shared primitive, different policy |
| window act | — | `winact` | `window_act` | `now_window_act` | Also `mirror_drive close/zoom` (F7) |
| control act | — | `ctlact` | `control_act` | `now_control_act` | Also `mirror_drive dialogItem` (F7) |
| menu act | — | `menuact` | `menu_act` | `now_menu_act` | Also `mirror_drive menuItem`, **without the identity check** (F7) |
| set text | — | `textset` | `text_set` | `now_text_set` | Also `mirror_drive type` (F7) |
| drive the Mirror | — | — | `mirror_drive` (16 gestures) | `now_mirror_drive` | **Advertised, dead on MCP** (F1) |
| open the Mirror | `showmirror` *(in flight)* | `host.show` *(in flight)* | `mirror_open` *(in flight)* | `now_mirror_open` *(in flight)* | Yes — `NOWMirrorWindow.show` (F13) |
| cycle apps for anchors | `cycle` *(in flight)* | `cycle` *(in flight)* | — | — | **Third fronting implementation** (F6) |

### With no path at all

| Capability | Reachable from |
|---|---|
| set Mirror plane policy (P1–P4) | the host's own window only |
| Mirror scale | the host's own window only |
| `exec.request` (guest shell) | the host's Console page only — **deliberate**, argued in `mcp-coverage.md` |
| `scene.request` as an agent ask | nothing — **planned**, M6 |
| menus in the perceive plane | nothing — `observe` reports only `hasMenus` (F5) |
| guest console verbatim replies | `tools/askguest.py` only (F12) |

---

# Findings

## The class that has bitten this project before: two paths, two answers

### F1 — Seven MCP tools are advertised and dead. `tools/now-agent` is not.

**Fix this first.** `SocketAgentIntegrationClient` — the client every MCP
call travels through — implements 36 protocol methods and **not**
`observeElements`, `mirrorDrive`, or `tailGuestLog`. Each lands on the
protocol default in
`now-host/Sources/NOWAgentIntegration/Projection/AgentIntegrationClient.swift`:

- `observeElements` → `.unavailable(.noObservationLane(…))` (`:449-453`)
- `mirrorDrive` → `now-mirror-state-lane-absent`, *"This client cannot
  drive the host Mirror"* (`:462-468`)
- `tailGuestLog` → `.hostUnavailable` (`:334-338`)

The socket serves all three (`now-host/Sources/Host/App.swift:847-858`,
`:764-772`) and `AgentIntegrationLocalClient` has all three (`:497`,
`:437`). Only the companion's forwarder is missing.

The blast radius is larger than three rows. `ObserveElementsProjection` is
the **only** producer of the `now-element-…` references
`now_window_act`, `now_control_act`, `now_text_get` and `now_text_set`
require. With the producer dead those four are unreachable for want of an
argument. **Seven of 41 tools cannot do their job from the MCP face**, and
each fails with a message that reads like a missing host lane rather than
a missing four-line forwarder.

All of it works through `tools/now-agent`. So the normal road is broken
and the developer road is fine — the exact shape that produced the
accessibility-scripting habit the `018-open-mirror` lane documents in
`HostSurfaceService.swift`: *"a sweep that could not open the Mirror from
the agent socket fell back to macOS accessibility scripting to click the
button, and later sessions copied that as a rig fact."* A missing
affordance became a documented bad habit once. This is the same gap one
layer over.

Nothing catches it. `HostProjectionRegistryTests` asserts the catalog is
registered, `NOWAgentCompanionTests` that tools are listed and bounded,
`MCPCoverageTests` that the catalog matches the contract. **No test
asserts that a registered projection's client method is overridden.**

**Recommend:** add the three forwarders, and add the gate — for every row
in `HostProjectionCatalog`, assert the concrete socket client does not
fall through to the protocol default. As a reflection over the catalog it
is one test, in the shape `MCPCoverageTests` already uses.

### F2 — Two foreign window readers, two different rectangles — already caught disagreeing on metal

This is the strongest evidence in the report, and it is the project's own.
`now-guest-ppc/src/scene/scene_collect.c:129-139`, verbatim:

> Measured 2026-08-02, Finder in front: `axsnap` reported the Finder
> bind=ok with hasWindows=true, `observe` returned its Desktop window with
> a minted ref, and the scene of the same machine at the same moment
> contained one window - NOW's own. Two readers in one binary disagreeing
> about one process, with the scene taking the answer from the reader that
> could not see it.

The two readers:

| | `peek/peek_read.c` | `axwalk/axwalk.c` |
|---|---|---|
| entry | `now_peek_windows_for_psn` `:270-314` | `now_ax_read_window` `:204-270` |
| offsets | `:24-29` (`kOffStrucRgn = 114`) | `:28-35` (`kNowAxWinContRgn = 118`) |
| **rect** | **structure** region — the frame a person sees | **content** region |
| failure | skips the window, keeps walking (`:301`) | refuses the whole window (`:236,249,261`) |
| bounds check | its own `ReadableZones`/`in_readable` | `now_peek_range_in_partition` (`:72-88`) |
| consumers | scene fallback, `process.shot`, the Processes page | scene primary, `observe`/`axtree`/`elements` |

A **third** variant, `now_peek_window_count` (`peek_read.c:316-352`),
counts the chain without reading bounds, so its count disagrees with
`now_peek_windows_for_psn`'s whenever a bbox fails the sanity check — and
the scene consumes both (`scene_collect.c:377`, `:241`).

The 2026-08-02 fix made the bind authoritative rather than peek_read's
verdict. **It did not merge the readers**, so the two rectangles remain.
Worse, `windows[].rect` now has three derivations *inside the scene
plane alone*:

- foreign, bound — axwalk's **content** region shifted up by a constant
  (`scene_collect.c:214-218`, `kNowSceneIRTitleBarHeight`);
- foreign, unbound fallback — peek_read's **structure** region,
  unadjusted (`:256-257`);
- self — Carbon `GetWindowBounds(kWindowStructureRgn)`
  (`scene_self.c:653-657`, whose comment claims it matches peek_read "so
  the two agree", which is true of the fallback branch and not of the
  primary one).

Meanwhile `elements`/`axtree` publish the **raw content** rect under
`bounds` (`observe.c:648-655`). Same window, same moment, different
rectangle depending on which plane you ask — and the constant reconciling
two of them is an approximation, as `docs/mirror-perceive-plane.md:284-292`
already warns.

**Recommend:** the highest-value merge in this report. One foreign window
reader, returning **both** regions with the offsets stated once, and every
consumer choosing explicitly. Failing that, publish `rectSource` on every
window so a disagreement is legible rather than silent. The title-bar
constant should not survive either fix.

### F3 — The scene re-derives what the processes family already ships, and slice 13 is about to make it a sixth copy

This is the direct answer to the question that prompted the audit.

Five independent `GetNextProcess` enumerations exist in the PowerPC guest
today, plus two more for other purposes:

| Code | Serves | Reads `modeOnlyBackground`? |
|---|---|---|
| `wire.c:5088-5202` `serve_process_list` | `process.list` | **yes** `:5161` |
| `commands.c:320-377` `now_process_gather` | `ps` **and** the guest console | **yes** `:357` |
| `processes_module.c:193-237` | the Processes page | **yes**, via `kind_of` `:180-191` |
| `scene/scene_collect.c:341-405` | the **scene plane** | **no** |
| `observe/observe.c:798-828` | `observe`/`axtree`/`elements` | **no** |

(plus `proc_actions.c:180` and `software.c:775,798`.)

The classification is copy-pasted and the source says so —
`commands.c:322-324`: *"These classify a process's kind, the same test
`serve_process_list` makes."* A claim of *parallel* code, which is what
parity rule 2 forbids. Three verbatim copies of
`kTypeFinder`/`kSigFinder` + `modeOnlyBackground` live at
`wire.c:5098-5099,5158-5165`, `commands.c:325-326,354-361` and
`processes_module.c:183-190`; `mach_activate.c:96` reads the bit a fourth
time. NOW-68K's `proc68.c:318-325` is a legitimate sibling.

**The scene does not read it at all** — no `modeOnlyBackground`, no
`processMode`, no background field anywhere in `now-guest-ppc/src/scene/`.
So for a faceless process, at one moment:

- `process.list` says *kind: background*;
- the scene says *`ax_oracle_not_found`* — an error word for a normal
  condition.

`docs/plans/2026-08-06-018-…-plan.md:566-573,650-654` concludes correctly
that the discriminator must be `processMode & modeOnlyBackground` — **the
bit four other walks already read** — and `claude/018-headless` implements
it as a fifth private `if` in `scene_collect.c`. To be fair to that lane,
its comment argues correctly that inferring facelessness from "we saw no
windows" is what made six healthy processes read as errors. The source is
right; the copy is the problem. And the shapes still differ:
`process.list` reports a kind enum (`finder`/`background`/`application`),
the scene a boolean with no notion of the Finder.

The scene also emits the same per-process facts **twice within one scene**
— `apps[]` and `processes[]` (`scene.h:15-16`, `scene_json.c:207-208`,
`:253-254`) — and both are a subset of `process.listing`'s
`{name, kind, code, creator, sizeKB, front, psnHigh, psnLow, isSelf}`.
`observe` publishes a third copy (`emit_process_head`, `observe.c:454-474`).

Three ways they can disagree at one moment: **different sampling moments**
(nothing shares a sample); **different caps** — 16 rows with a byte margin
for `process.list`, `kSceneCollectMaxPsns` for the scene, `kObsMaxProcs`
for observe, three truncation vocabularies; and **different admission
rules** — `process.list` skips an unreadable row and does not count it
(`:5140-5142`), the scene skips it and downgrades coverage to `partial`
(`:357-359,407-410`).

**Recommend, and this is the recommendation with the most leverage in the
report:** give the scene the **process family's row** rather than a
parallel walk. One enumeration, one front sample, one `kind`, and the
anchor verdict as an *additional column* on that row. It closes F3 and
most of F5 together, and it turns `ax_oracle_not_found` into "headless by
declaration" without adding a sixth read of the same bit. If the plan's
slice 13 lands first, the merge should be scheduled immediately after
rather than deferred — a fifth copy that ships is harder to remove than a
fifth copy that is still a diff.

### F4 — Two titles under one reference, in the same scene document

The contradiction seen earlier today is structural, and it is **not**
`ctlact`/`ditemact` — neither reports a title. It is inside
`now-guest-ppc/src/scene/scene_walk.c`:

- a control's `title` comes from the live `ControlRecord` via
  `now_ax_read_control`;
- a dialog item's `title` comes from the **DITL resource** via
  `now_ax_dialog_next` (`axwalk/axwalk.c:395`);
- and the control's ref is copied onto the dialog item —
  `strcpy(item->ref, control->ref)` (`scene_walk.c:296-298`).

Reconciliation is deliberately partial (`:290-303`): `enabled`,
`definition` and `ref` come from the live control, but the title is
overwritten **only** for popup menus or an empty DITL title. A control
whose live title differs from its DITL text is therefore emitted twice,
under one ref, with two names, in one document (`scene_json.c:392/401`,
`:689-706`).

Both are honest about a different moment. A consumer has no way to know
which it got. Note also that `ditemact` accepts a caller-supplied item
number that is **not** validated against the DITL (`act_cmds.c:920-936`),
so the ref and the item index are independent inputs.

**Recommend:** carry `titleSource` on each, or do not carry two. Naming
the source is smaller and more honest — the DITL text and the live title
are different facts. Do **not** silently prefer one; that converts a
visible contradiction into an invisible one.

### F5 — `observe` samples the front process once per row, so one reply can name two front processes

Everything else samples front once before its loop — `wire.c:5106`,
`scene_collect.c:338`. `observe.c` samples it **inside** `bind_target`
(`:127`), per process, and again for the scope filter (`:794`). A
`Cmd-Tab` mid-walk yields a reply where two rows carry `front: true`, or
none does, while a scene taken at the same instant is internally
consistent by construction.

The act plane already knows this is dangerous and says so
(`act_cmds.c:1031-1035`): *"menuact requires serialHi and serialLo from
the scene's front process. A menu bar belongs to that exact process;
falling back to whichever app is front now can invoke a different
application's item."* `menuact` correctly refuses to read front itself.
`elements` (`observe.c:902`) still resolves "the front process"
implicitly, from its own per-row read.

`GetFrontProcess` has 13 call sites in the guest, two of which
(`proc_actions.c:389-401` and `mach_activate.c:33-43`) are byte-identical
`is_frontmost` helpers. Most of those are fine — it is a cheap local
Toolbox call over one source of truth. **The defect is the sampling
moment, not the call count.**

**Recommend:** hoist `observe`'s read out of the loop, so one reply
describes one moment. Deduplicate the two `is_frontmost` copies while you
are there.

### F6 — Three ways to bring an application forward, making three different claims

1. **Console `front`** — `now_proc_front_by_name` resolves by name, calls
   `SetFrontProcess`, then **yields and re-reads `GetFrontProcess`**,
   reporting one of seven outcomes including `kProcFrontUnconfirmed`.
   `proc_actions.h:100-140` is explicit: noErr means the switch was
   *scheduled*.
2. **Wire `process.front`** — `serve_process_act` (`wire.c:5313`)
   re-validates the PSN, calls `now_proc_bring_to_front`, answers
   `ok:true` on noErr. **No confirm.** `now_bring_to_front` over MCP
   rides this path, so an agent gets the weaker claim and cannot tell.
3. **In flight — `cycle`** (`claude/018-anchor-acquisition`,
   `peek/anchor_cycle.c:266`, `:305`, `:314`) calls `SetFrontProcess` raw
   and derives `fronted` and `restored` from its return code. Its report
   — the evidence that slice exists to produce — therefore counts
   **accepted requests, not confirmed switches**, which is precisely the
   distinction its counters are trying to draw.

`processes_module.c:455-497` is a fourth raw call site, for capture.

**Recommend:** `serve_process_act` should use the same confirm-wait and
carry an `unconfirmed` outcome into `process.result` — contract first.
`anchor_cycle.c` should call `now_proc_bring_to_front` plus the confirm.

### F7 — `mirror_drive` and the act lane reach the same effects with different safety checks

Two addressing worlds, already named in
[mirror-mcp-parity.md](mirror-mcp-parity.md) — snapshot entity ids through
`MirrorActionExecutor` with typed settlement, versus opaque
`now-element-…` refs straight to guest command dispatch. **That file is
dated 2026-08-04 against `7b3eceb` and says of itself that most of its
"missing" rows are now served through `mirror_drive`; re-derive it before
quoting any row.**

Four effects are now reachable both ways with materially different
validation:

| Effect | `mirror_drive` | act lane |
|---|---|---|
| close / zoom a window | `close`/`zoom` + `entityID` | `now_window_act`, also carries geometry `mirror_drive` has no gesture for |
| pick a menu item | `menuItem` + `menuID` + `itemIndex` | `now_menu_act` — **requires `titleLeft`**, the identity check that exists so this act's `MenuSelect` can be told from a human's press (`MenuActProjection.swift:40-43`, "the measured 18/20 hijack in its menu-shaped form") |
| type text | `type` + `text`, at focus | `now_text_set` — element ref, replaces one element's contents |
| press a dialog item | `dialogItem` + `entityID` + `itemIndex` | `now_control_act` — Control Manager part code |

The menu row is the sharp one: the no-hijack criterion was earned with a
check one of the two doors does not ask for. Neither surface is a superset
— `mirror_drive` alone offers `hide`/`hideOthers`/`showAll`/`finderOpen`/
`finderSelect`/`finderDeselect`/`appleMenuItem`/`cancel`; the act lane
alone offers geometry, part codes and `now_text_get`.

**Recommend:** do not merge the surfaces — the addressing difference is
real and both are wanted. Do give `mirror_drive menuItem` the same
identity check, or state in the contract why a scene-addressed pick does
not need one. A safety check only one of two doors performs is worse than
one nobody performs, because the failure gets attributed to the wrong
cause.

### F8 — `sw` reads a live sweep; `software.list` serves a cache

`run_sw` calls `now_software_overview` / `now_software_gather`
(`software/software.c:182`, `:484`), which sweep the disk on every call.
`serve_software_list` calls `now_software_page` (`:708`), which pages
`g_sw_cache`, rebuilt only when the cursor is 1 (`:723`).

**The wire can serve an inventory the console would not.** Same file, two
data paths, invisible until something is installed or removed mid-session.
`now_software_inventory` and `now_launch_software` ride the cached path; a
person at the machine sees the fresh one.

**Recommend:** one path. If the cache is right on a 56 MB machine, the
console should read it too — and both should report its age. A cached
inventory that cannot say how old it is cannot be reasoned about.

### F9 — Menus: three live readers, one dead, and a doc that overstates the plane

| Reader | Source | Consumer |
|---|---|---|
| `scene/scene_walk.c:421-460,525-545` | foreign MenuList through the anchor | scene `menubar`, front process only |
| `scene/scene_self.c:482` `current_live_menu_list` | low memory `0x0A1C`, then Carbon `GetMenuTitle`/`CountMenuItems` | scene `menubar` when NOW itself is front |
| `peek/peek_read.c:354-400` `now_peek_menu_titles` | the same axmenu primitives, its own bind | **nobody** — grep across `now-guest-ppc/` and `contract/` finds only the definition and its prototype |
| `act/act_cmds.c:990-1129` `menuact` | does not walk; takes the scene's numbers | the act |

`observe`/`axtree` report no menus at all, only a boolean `hasMenus`
(`observe.c:933`) — while `docs/mirror-perceive-plane.md:41` says the tree
exposes menus. `menuact` is the good pattern: it refuses to be a second
source of truth.

**Recommend:** delete `now_peek_menu_titles`; correct
`mirror-perceive-plane.md:41`; leave the foreign/self split, which is a
real distinction between reading another process's memory and asking your
own Toolbox.

### F10 — One machine fact, up to five reads and three decoders

| Fact | Paths |
|---|---|
| Screen geometry / depth | `scene_collect.c:81-93` (`gdRect`, **no depth**), `census overview` (`:266-283`, `gdRect` + `pixelSize`), `census video` (`:325-360`, walks `GetDeviceList`), `vprobe` (`census/vprobe.c:146-166`, PixMap `bounds` + `pixelSize`), `screenshots/capture.c:31-39` (PixMap `bounds`) — `gdRect` and the PixMap's `bounds` are the same rectangle only for the main device on a single-monitor machine |
| CPU | `gestalt` with a local `cpu_name()` table (`commands.c:57-70`) vs `census identity` decoded through `census_selectors.h` — **two independent name tables** |
| OS version | `gestalt` via `bcd_version()` (`commands.c:44`) vs census via `census_summarize` — **two BCD decoders** |
| Physical RAM | `gestalt` (`:226`), `census overview` (`:237`), `census identity` (`:185`) — one selector, three formatters |
| CarbonLib version | `gestalt` (`:224`), `census overview` (`:256`) |
| ROM size | `gestalt` in **KB** (`:307`), `census overview` in **MB** (`:232`) |
| Open Transport present | `gestalt` from `Gestalt(gestaltOpenTpt)` (`:230`) vs `net` from **runtime symbol resolution** of the OT fragment (`network/net_probe.c:242-249`) |

The last can disagree *honestly and usefully*: Gestalt can say OT is
installed while the fragment will not resolve. That is a real distinction
— which is exactly why a reader needs to be told there are two.

`mcp-coverage.md` already argues `now_hardware_census` and
`now_machine_facts` are "adjacent and not merged" for good reasons. That
argument is about the rows; it does not reach the decoders underneath.

**Recommend:** leave both verbs; collapse the decoders — one `cpu_name`,
one BCD reader, one screen read with a stated coordinate space, one ROM
unit. Give the scene the depth it currently omits, since `census` already
knows it and the host's projection republishes a screen without it.
Document the OT pair as a deliberate two-mechanism answer; that one should
stay two.

### F11 — `mirror` judges the planes; the planes judge themselves

One shared table read (`peek/peek.c:408 now_peek_table()`, seven call
sites) and **two derivations over it**. `mirror/mirror_probe.c` has its
own `plane_format_compatible` (`:81-103`), `plane_capability` (`:105-113`)
and reachability checks, while `act/act_client.c`,
`content/qdtrace_cmd.c` and `peek/transitions_cmd.c` each gate their plane
independently. So `mirror` can report a plane `supported` while the verb
that uses it refuses, or the reverse.

Given how much of this arc has gone into telling "the plane is dead" apart
from "the plane is fine and the act was wrong", a status line that can be
wrong in that direction is expensive.

**Recommend:** one `plane_usable(plane)` predicate, called by `mirror` and
by each consumer's gate. Small change; removes a class of misdiagnosis.

## The tooling layer

### F12 — The tools reach the guest by three roads, and only one is the product's

`tools/now-agent` and `tools/mirror-corpus` go through the agent socket.
**Fifteen or more other tools bind their own TCP listener, impersonate the
host, and speak the frame protocol themselves.** A third group drives QEMU
over QMP.

The constants are safe: `contract/wire_limits.py` is imported by nine
files and `WireLimitsAgreementTests.testNoHarnessDeclaresItsOwnRevision`
fails on a bare literal. **The codec is not.** Eight sites hand-roll
pack/unpack — `askguest.py:59,118`, `gwprobe.py:69,82`,
`fakeguest.py:45,67`, `liveness-channel.py:55,86`,
`liveness-experiment.py:80,85`, `local-modal-starve.py:69,121`,
`shutdown-guest.py:197,224` — while `scripts/probes/nowwire.py:235` is the
only one that is a library, and its header documents four hard-won
behaviours (bulk reassembly, MacRoman decoding, ping/pong servicing,
`ok:false` as a result rather than a failure) the others re-derive in
part.

The sharpest instance is `tools/gwprobe.py:109-133`: a `scene()` that
answers the same `scene.request` as the host with **no delta handling, no
staleness rule and no IR gate**, all of which live in
`scripts/probes/scene.py` and `NOWMirrorSource.swift` — and
`tools/fidelity-sweep.py` builds its fixtures on it, then mixes in QMP
pixels and the lab's own harness, three transports in one measurement.
`askguest.py` decodes UTF-8 with `errors="replace"` where the contract
says MacRoman, so an option-key character in a filename becomes U+FFFD
there and survives through the host.

**Recommend:** make `scripts/probes/nowwire.py` the one client and port
the seven hand-rolled codecs onto it — mechanical, with a real payoff,
since each is a place a scene or a filename can be read differently from
how the product reads it. Then give `gwprobe.scene()` either the host's
document semantics or a name that says it lacks them. `fidelity-pair.py`,
`mirror-diff` and `mirror-gate` touch no transport and need nothing.
`mirror-corpus` reads three ways **on purpose**, to make the layers
disagree visibly; leave it.

Not a defect, worth naming: every `local-*` measurement removes the host
from the path deliberately, so none of their numbers is comparable to
`now_mirror_metrics`. Their headers say so; their names do not.

## The in-flight work

### F13 — The seventeen lanes, as of 03:44 UTC

Most are stacked rather than parallel — `lane-b` → `listview`, `lane-d` →
`scene-caps` and `lane-d` → `drag` — so the repeated files in their
diffstats are inheritance, not duplication. Two heads
(`018-open-mirror`, `018-anchor-acquisition`) moved during this audit;
**treat every line below as a snapshot.**

| Branch | Head at 03:44 | New surface |
|---|---|---|
| `018-desktop-pattern` | `bba4b19a` | `desktop` verb + contract + both coverage docs |
| `018-anchor-acquisition` | `3adc6674` | `cycle` verb (console + wire), anchor counters |
| `018-visibility` | `3f180973` | `mirror.extension.anchors` contract field, anchor counters |
| `018-open-mirror` | `c9b8cf91` | `host.show`/`host.shown`, `showmirror`, `mirror_open`, `now_mirror_open` |
| `018-headless` | `f6087b1b` | scene `backgroundOnly` + kind coverage |
| `018-listview` / `lane-b` | `6064a077` / `cad5f247` | scene title/rect publishability predicates, list-view geometry |
| `018-scene-caps` / `018-drag` / `lane-d` | `e21d3bea` / `4704a6fd` / `ac1ada50` | act menu probe, settlement, scene caps |
| `lane-a`, `lane-c`, `lane-e`, `slice-3`, `arm-census`, `procedural-chrome`, `image-discipline` | — | no new verbs, messages or MCP rows |

Three things will break or mislead at integration:

1. **`desktop` is wire-only.** It is in `commands.c` and the contract and
   **not** in `console_model.c`, and it is not named in
   `CommandParityTests`' `reachedByFallback`; `wireOnly` is deliberately
   empty. `testThePowerPCGuestsTwoFacesAgree` will fail. *(Fix: a console
   face, or a `reachedByFallback` entry if it takes no arguments.)*
2. **`cycle` is undeclared.** Served on both faces — correctly, one
   producer, two renderers — but `x-commands` does not declare it, which
   parity rule 3 forbids and `CommandParityTests.swift:820-850` checks.
3. **Two lanes carry the same `mirror_anchor.c` with different
   arithmetic.** `018-visibility` computes `age_ticks` with an explicit
   `NowPeekU32` cast, commented to explain that `unsigned long` is 32
   bits on the guest and 64 on the machine running its test;
   `018-anchor-acquisition` replaces it with a plain subtraction. **The
   last merged wins**, and the losing case reads as a broken test rather
   than a wrong number on a Macintosh — exactly what the removed comment
   predicted. *(Keep the cast.)*

`018-open-mirror` is the model of how to add surface: contract first, a
console face, a menu item, an agent verb and an MCP row, **one
implementation** behind all of them (`NOWMirrorWindow.show`), a new
`command-parity.md` asymmetry row with its reason, rows in both coverage
docs, and a written account of the harm the gap caused.

### F14 — Two published numbers already wrong, and one dead function

- `docs/contract-coverage.md:237` says *"Three of those 38"* against a
  registry this audit derives at **42** — a leftover, in the file whose
  own rule is *derive it, do not remember it*.
- `claude/018-desktop-pattern` honestly updates both coverage docs from 42
  to **43**. When `cycle` is declared it becomes 44, and that lane's prose
  will be wrong on arrival through nobody's carelessness — the failure
  `AGENTS.md` names as *"neither author did anything careless and the
  merge still produced a lie."*
- `now_peek_menu_titles` (`peek_read.c:354-400`) has no callers (F9).

**Recommend:** fix `:237` now; re-derive both documents **after** the 018
integration rather than in each lane, and treat every count in them as
void until then.

---

## What I could not determine

- **Whether any of these disagreements is currently visible on a running
  machine.** No VM was used. F2's disagreement has an on-metal witness
  from 2026-08-02 recorded in the source; the rest are static findings
  about code that can disagree, not observations that it did.
- **Whether F1's seven dead tools have ever been exercised over MCP.**
  The failure text reads as a missing host lane, so a caller who hit it
  would plausibly have concluded the host was not running rather than
  filing a defect. `docs/open-issues.md` is 690 KB and was not read in
  full.
- **Whether `mirror_drive`'s Finder gestures duplicate `reveal` /
  `now_reveal_item`.** `mirror-mcp-parity.md` calls them "adjacent, not
  equivalent" as of 2026-08-04; not re-verified.
- **The host-derived planes' overlap.** Desktop icons and per-process
  `visible` both come from AppleScript through the `script` verb and are
  merged host-side; whether `visible` and `modeOnlyBackground` can
  contradict each other was not established.

## Numbers that need re-deriving after the 018 integration

Everything in the table at the top, plus `contract-coverage.md`'s
42 / 39 / 13 and 48 / 23, `mcp-coverage.md`'s tool and gap tables, and the
whole of `mirror-mcp-parity.md`, which is dated 2026-08-04 and says so
itself.
