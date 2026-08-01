# The probe harnesses

**Ported from `timbottu/mirror/tests/` on 2026-07-31.** Wave 2B of
[../../docs/mirror-foldin-inventory.md](../../docs/mirror-foldin-inventory.md),
which says why this was the most under-valued item on the list:

> The roadmap's Phase 3 says "validate against an emulator" as though the
> harness needs writing. It does not — it exists, it has run, and its results
> are recorded. Porting these is cheaper than authoring an emulator pass and
> gives directly comparable numbers.

**Nothing here has been run.** These drive a live Macintosh; the port was done
on a bench with no hardware, no VM and no `NOW_METAL`. Running one is a
separate, attended decision. Every claim in this directory is about what the
code *says*, and where a number appears it is upstream's, taken on upstream's
machine.

## Why the port is not a transliteration

Two things did not survive the crossing, and pretending otherwise would have
produced harnesses that look like coverage and prove nothing.

**The transport inverts.** Mirror's probes DIAL the guest and speak
newline-delimited JSON. NOW's guest DIALS THE HOST, and every message is an
8-byte frame with a hello gate and guest-driven keepalive. So every probe here
is a *listener*. `nowwire.py` is that inversion, done once.

**The verb surface barely overlaps.** Mirror served 31 verbs; NOW serves 16
over the wire, and `launch` and `quit` are the only two in common. Mirror's
probes are built on `observe`, `axtree`, `ctlinvoke`, `menuinvoke`, `textget`,
`textset`, `script`, `mouseloc`, `key` — of which NOW had, at the crossing,
**none**.

**And a spelling is not a capability.** Two of those verbs crossed under
different names: NOW's control op is **`ctlact`** and its menu op is
**`menuact`**, declared in `contract/asyncapi.yaml` and served, while the
ported probes went on asking for `ctlinvoke` and `menuinvoke`. Reconciled
2026-07-31 — see the note at the top of `ctlinvoke-probe.py`. A harness that
refuses a machine over a name it could have looked up is the loud-refusal
machinery producing a confident wrong answer, which is worse than no harness.
**The wire names moved; the result labels did not**, so the numbers still diff
against `upstream/`.

So each harness had to be classified rather than translated.

## The three verdicts

| verdict | what it means |
|---|---|
| **runs** | works against a NOW guest today, wired to NOW's connection path, measurement intact |
| **refuses** | ported, but the guest does not serve what it measures. It **refuses loudly at the top, names every missing verb, and exits 2** — before a single trial |
| **not ported** | genuinely Mirror-only. Said so, and left upstream |

A refusing harness is not a stub. Its trial bodies, constants, oracles and
counting are all here and all written against NOW's spelling where NOW has
declared one. The day the verbs land, it reports.

**Exit codes are distinct on purpose.** `2` = this machine cannot be measured.
`1` = it was measured and the measurement is a finding. `0` = measured, clean.
A harness that could not run must never share a status with one that ran and
found nothing.

## The ledger

Every script in `mirror/tests/`, with its verdict.

### Ported

| upstream | here | verdict | needs from NOW |
|---|---|---|---|
| `nohijack-probe.py` (50 KB) | `nohijack-probe.py` | **refuses** | `observe`, `mouseloc`, `ctlact`, `menuact` (`textget`/`textset` for its text case). Its menu cases have a second, non-name blocker: `observe` emits no menu bar, and `menuact` wants a menu **id** where this file passes a ref |
| `trials.py` | `nowwire.py` + `tally.py` | **split** | the client half rewritten for NOW's transport; the **counting half ported wholesale and tested** |
| `textops-probe.py` | `textops-probe.py` | **refuses** | `observe` only — `textget`/`textset` are already declared in NOW's contract |
| `textops-explore.py` | `textops-explore.py` | **refuses** | `observe`, `textget` |
| `ctlinvoke-probe.py` | `ctlinvoke-probe.py` | **gated on `observe`** | `observe`, and `ctlact` — which NOW serves. The filename and the result label keep upstream's spelling; only `ACT_VERB` moved |
| `winact-probe.py` | `winact-probe.py` | **refuses** | `observe` only — `winact` is declared, with its exact args |
| `apple-event-probe.py` | `apple-event-probe.py` | **refuses** | `observe`, `apple_event`. Its `dirty` case additionally has no way to dirty a document and says so |
| `g1-probe.py` | `g1-probe.py` | **runs (2 of 3 cases)** | `stamp` and `launch` run today. `menus` needs `observe` |
| `h2-trials.py` + `h2-scroll.py` | `h2-items-probe.py` | **refuses** | `script`, `observe`, and a positional click. Three blockers, the most of any lane |
| `drive-sequence.py` | `drive-sequence.py` | **gated on `observe`** | `observe`, `winact`, `ctlact`, `launch`, `ps`. All-or-nothing by design |
| `h2-trials-result.json`, `p2-*.json` | `upstream/` | **preserved verbatim** | — see `upstream/PROVENANCE.md` |

### Not ported

| upstream | why |
|---|---|
| `h2probe.py`, `h2calib.py` | client plumbing for Mirror's wire and its `ports` file. Superseded by `nowwire.py` and `oracles.py`; porting them would be two clients for one link |
| `h2-explore.py`, `h2-calibrate.py` | scratch calibration against Mirror's `script` verb and its icon offsets. Both are exploration, both are re-derived in ten minutes once `script` exists, and neither carries a recorded result. `h2-items-probe.py` keeps the constant that mattered (`ICON = 32`) |
| `h2-serve-check.py`, `agent-session.py` | drive **MirrorApp's `--serve` unix socket** and the fifteen methods of `mcp/mirror-service-ipc.toml`. That is Mirror's host binary and Mirror's own IPC contract. NOW's agent surface is its own (`docs/agent-integration.md`) and is covered by the `AgentIntegration*` Swift suites |
| `mirror-service-e2e.py`, `mirror-service-protocol-test.py` | the same service socket — an end-to-end task through it, and its wire-contract edges. NOW's equivalents are `HostTests/AgentIntegration*` and `GuestWireConformanceTests` respectively, and both already exist |
| `h2-redeploy.py` | Mirror's redeploy through the TimBotTu anchor worker. NOW has `scripts/deploy-68k`, whose `--handoff` mode does the same job better |
| `h2-mutations.sh` | mutates **MirrorKit Swift sources that do not exist here**. Its *discipline* did cross: see `tests/tally_test.py`, whose header records the six mutations the counting logic was watched to fail under |
| `_slowtrace.py` | a four-line monkey-patch that times slow calls. Re-writing it is cheaper than maintaining a port, and `GuestLink` is one class to wrap |

## What was done to preserve comparability

The numbers are only comparable if a trial is counted the same way. The
measures taken, and the places it could have been lost:

- **`tally.py` is upstream's counting, ported wholesale**, and is the only
  file here with a test. `tests/tally_test.py` is wired into
  `scripts/test-native` (51 → 52) and its header records **six mutations it
  has been watched to fail under**. The one that matters: scoring a dropped
  trial turns upstream's recorded **0-of-19 into 0-of-20**, which is a
  different claim about a machine reached by a one-line tidy.
- **Dropped trials stay dropped.** A stimulus that missed its target is *not a
  trial*, is excluded from the numerator *and the denominator*, and is
  reported as its own count.
- **`ok:false` is still a reply.** Reply rate and actuation rate are counted
  separately because they fail independently.
- **Actuation still needs a guest-side oracle**, never the verb's own report.
  NOW's contract independently insists on the same thing for its act plane:
  *"There is deliberately no `performed` field for a responder to set true."*
- **Upstream's constants are kept**: N=20, arm delay 1.5 s, stale delay 10 s,
  the disarm sweep, `ICON = 32`, the Control Manager part codes 20/21/22/23
  and 10/11 (and the note that **12 and 13 are not part codes**), the
  off-screen `titleLeft` of 4000, and the menu item-1 row at y=28.
- **Per-trial record keys are upstream's**, so a NOW run's `--json` diffs
  field-for-field against `upstream/`.

### Where comparability is knowingly broken

Stated here rather than discovered later:

1. **`g1-probe.py`'s launch oracle is weaker.** Upstream required the
   launched app's *window*. NOW has no observation, so the oracle is `ps` — and
   a process exists before its window does. Report it as `launch/ps`, never
   against upstream's `launch/window`, and **re-run** it when `observe` lands
   rather than back-filling.
2. **`nohijack-probe.py`'s tracking probe uses `vers`, not `ping`.** Upstream
   sent `ping` as a verb. On NOW's wire ping is guest-driven keepalive and the
   host must never initiate it. The oracle is the *latency*, not the verb, so
   the substitution is safe — but a reader comparing the two files will notice.
3. **Different implementations.** Upstream measured a trap-patch Portal on
   Mirror's guest. NOW's act plane is not that code. A 0/20 here would be
   evidence about NOW's guard; agreeing with upstream is corroboration, not
   the same measurement.

### One thing the crossing improved

Upstream's strongest oracle — a folder on disk, created by a hijacked Finder
File/New Folder — needed a **second guest process** to read: Mirror's probes
imported `timbottu_mcp_classic.harness.Harness` and drove the TimBotTu anchor
worker purely to `stat` and `delete` a path, because Mirror's guest could not
read its own filesystem.

NOW's can. `ls` is wire-served and `file.trash` is a typed control message,
both on the link the probe already holds. So that oracle crosses with **no
second process, no second port, and no dependency on another project's
client** — and every `--anchor-port` argument is gone. See `oracles.py`.

## Files

| file | what it is |
|---|---|
| `nowwire.py` | the transport: listen, hello gate, keepalive, command plane, typed message plane, rowArray reading, `require_verbs` |
| `tally.py` | **how a trial is counted.** Pure, tested, and the reason the numbers mean anything |
| `oracles.py` | guest-state oracles on NOW's own surface (`ls`, `file.trash`, `ps`) |
| `qmp.py` | the real mouse, from outside the guest: QMP input plus the pin/learn-hop/replay calibration |
| `tests/tally_test.py` | the one automated gate. Run by `scripts/test-native` |
| `upstream/` | upstream's recorded results, verbatim. Read `PROVENANCE.md` first |

## Running one

They refuse without `NOW_METAL`, because they move the mouse, click menus,
create and delete folders, and in one case close windows.

```sh
export NOW_METAL=1
export NOW_METAL_PORT=5252          # the port THIS host listens on
export NOW_METAL_GUEST="PowerBook 1400c"   # refuse any other machine

python3 scripts/probes/g1-probe.py --case stamp
```

`--expect-guest` / `NOW_METAL_GUEST` is not optional discipline. Every QEMU
guest on this Mac sees the host as `10.0.2.2` and any session's VM can answer
the listener; a number attributed to the wrong machine is worse than no
number.

**The one to run first is `g1-probe.py --case stamp`.** It is the only thing
here that can tell you whether the ported transport talks to a real Macintosh
rather than to `tools/fakeguest.py`, and it changes nothing on the machine.

## corpus_impact

`corpus_impact: none` — a port, and an audit of what could and could not
cross. No new measurement was taken: nothing here has been run, and the only
numbers in this directory are upstream's, preserved in `upstream/` with their
provenance and their limits stated. The finding that *would* be new — NOW's
own hijack rate — is exactly what `nohijack-probe.py` is checked in to make
possible, and it is not claimed here.
