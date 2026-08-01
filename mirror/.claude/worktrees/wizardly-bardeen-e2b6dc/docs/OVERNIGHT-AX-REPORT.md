# Overnight AX report (2026-07-16)

Focus: wire the AX verb surface into the plumbing, extend coverage across the
fleet, leave "juicy ax" for the mirror app to wire up. Emu-only (metal is
attended). Branch `claude/timbuktu-desktop-mirror-4722b4`.

## TL;DR

- **Freshened with main** (19 commits: 0.7 stack, workshop plugins, app-control,
  parity changes) — clean merge, worker builds, my AX verbs survived, all gates
  green.
- **Wired `mouseloc` end to end** — classified + registered across docs/30
  matrix, workshop-parity ledger + instruments, control-tools registry +
  generated Swift/C/digest projections. `verbcov` / `workshop-parity` /
  `control-contract` / `data check` all green.
- **mac99 (PPC) AX coverage: COMPLETE on merged main** — Rungs A/B/C/D
  (windows/controls, refs+axdo, scope=all, menus **and** dialog TextEdit) plus
  the new surface (control value/min/max/checked, `mouseloc`, `click` mods,
  `axdo` count/mods/text) — all verified live.
- **q800 (68K) coverage: BLOCKED, diagnosed** — the toolkit worker deploys and
  *starts* on 68K (session model works), but its MacTCP passive-open fails
  `-23009` (commandTimeout). It's a networking fix, not a deploy problem.
  Finding: `q800-toolkit-worker-mactcp-serve`.
- **A mirror-ready mac99 guest is left RUNNING** for you to point the mirror app
  at this morning (see below).

## The live mirror-ready guest (use this today)

A headless mac99 clone is up with AXPeek loaded + a merged-main toolkit worker,
on **remapped host ports** (to avoid the other session's VM on 1400/1410-19):

- **host 1700** → guest anchor (launch/observe/put/…); build `worker`.
- **host 1710** → toolkit worker `mac99-mirror-mrg`, scope includes
  `axtree, axdo, observe, click, key, type, activate, launch, mouseloc`.
  `axtree {scope:"all"|"front"}` returns live trees (`axpeek-context`,
  `bytesScanned=0`).
- QMP at `/tmp/tbtm/run/qmp.sock` (for the emu drag path).

Quick check: `python3 -c "import sys;sys.path.insert(0,'mcp');from
timbottu_mcp_classic.harness import Harness;print(Harness(host='127.0.0.1',port=1710,
expect_backing={'toolkit','worker'}).request('axtree',{'scope':'front'}))"`.

To rebuild from scratch: `scratchpad/launch-mirror.sh` (warm) → `mac99-stage.py`
→ `launch-mirror-cold.sh` (cold) → launch the worker via the anchor. `tools/stop`
won't find it (custom run dir `/tmp/tbtm/run`) — QMP `quit` + `rm` the clone.

## What the mirror app can wire up (the juicy ax)

All live on the 1710 worker, both PPC now (68K once the MacTCP fix lands):

| Capability | Verb | New this cycle |
|---|---|---|
| Window/control/menu trees | `axtree {scope}` | control `value/min/max/checked`, `scrollbar` role |
| Dialog text | `axtree` (kind==2 → `textEdit`) | Rung-D verified on mac99 |
| Click a control by ref | `axdo {ref, count?, mods?, text?}` | count (dbl-click), mods, type-by-ref |
| Point click | `click {x,y,button?,mods?}` | mods; button≥2 = Control-click |
| Keys / menu shortcuts | `key {code,char,mods}` | (keycode matters — Finder matches keycode) |
| Cursor position | `mouseloc` | new; closed-loop drag seed |
| App control | `launch`/`activate`/`apple-event` | (from main) |

Full map + gotchas (rect order, keycode, drag=emu-only): `CONTROL-SURFACE.md`.

## Commits on the branch

- `feat(ax)` — the verb surface (control values, mouseloc, click mods, axdo args).
- `spike(mirror)` — mirror prototype, control-surface map, workshop-applet plan.
- `wire(ax)` — mouseloc classified + registered across the surface (gates green).
- `finding(q800)` — the MacTCP-serve blocker.
- (uncommitted) finding edits + this report — commit pending.

## Attended-metal checklist (needs you — I did NOT touch metal)

To close the fleet, each metal machine needs an attended pass (reboot/wedge
hazards):
1. **Q950** (68K metal) — the q800 sibling. First fix q800's MacTCP serve
   (`q800-toolkit-worker-mactcp-serve`); then AXPeek + toolkit worker + run the
   axtree rungs. Rung C/D were pending on Q950 pre-cycle.
2. **PB1400c** (PPC metal) — AXPeek was live here 2026-07-10; re-run axtree with
   the new verb surface (control values, mouseloc). Metal wedge history — attended.
3. **Wallstreet PBG3** — off-stock target; AXPeek install + axtree if in scope.

## Open items / next

- **q800/68K MacTCP serve `-23009`** — the one thing blocking 68K coverage
  (retry around passive-open? readiness race? merged-main regression vs the stock
  harness?). Highest-leverage AX follow-up.
- **Extended-verb MCP tool args** — `axdo` count/mods/text and `click` mods work
  on the wire but the MCP tool schemas (`ui-action/v1`, `point-input/v1`) don't
  expose them yet; agents-over-MCP would want them (the mirror app uses the wire
  directly, so lower priority).
- **The native Swift mirror applet** — `WORKSHOP-FOLDIN.md` is the build spec;
  the live 1710 guest is a ready target to develop against.
