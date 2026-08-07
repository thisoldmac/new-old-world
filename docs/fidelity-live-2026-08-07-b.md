# Live-frame flicker, B side — 2026-08-07

The second measurement `tools/fidelity-live.py` has ever produced.

The instrument was built for one purpose — to see flicker that a settled
capture structurally cannot — and until this page it had run **once**.
Sweep B did not run it and said so; sweep C could not, because
`mirror_read --intention snapshot` closed the connection without
replying. That transport defect is fixed
(`AgentIntegrationLocalServer.finish` encoded with `try?` and returned on
failure while its `defer` closed the socket, so **any** response over
64 KB hung up with no error frame), and this is the A/B the whole of
plan 018 is bracketed by, finally taken twice.

Compare row for row against
[the A side](fidelity-live-2026-08-07-a.md).

## WHICH RIG — read before quoting a number

| | |
|---|---|
| **Tree** | `claude/019-flicker-bc`, forked from `claude/019-integration-7` at `1a35e96f`. The only source change is the instrument's own two new assertions (below). |
| **Guest build** | `d9a78b62a414 2026-08-07T20:10:31Z`, asserted by the tool's new `--expect-build auto` against the host's `session_health` **before every one of the traces**, and recorded in each report's `rig` block. |
| **Base image** | `~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`, sha256 `c466baa9a5455c343908e12197d68e57ffc7f07c140276a90c97a5ae2a137d70` — the shared oracle, whose newest receipt is a **deferral**, so its baked resident predates the round-6 ext merge. That does not reach this run: `scripts/spin-up-ppc` clones it and stages **this checkout's** ext and app, then cold-boots so the INIT loads. |
| **Resident** | the guest's own `mirror` after the cold boot: lifecycle `active`, capabilities `511`, sourceManifest `ad1b8d35302e`, buildFingerprint `1247f064b341` — matching the local build exactly. `actselftest` → `abi-agreed`. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1. Lane block **384** (`tools/lane-ports`): anchor **15072**, wire **15073**, run dir `/private/tmp/nowvm-f384`, qmp `/private/tmp/nowvm-f384/qmp.sock`. |
| **Host app** | `scripts/build-host-app` into `/private/tmp/f384-host`, launched `--open-mirror` with **both** `NOW_PREFS_SUFFIX=f384` and `NOW_AGENT_SOCKET_SUFFIX=f384`, listening on 15073. |
| **Artifacts** | `/private/tmp/f384-live/` — `*-frames.jsonl` traces, `*-flicker.json` reports, guest screendumps, `LIMITS.md`. |

Emulator-verified at best. Nothing here touched metal.

**Also running on this Mac during these traces**, named because a shared
machine is part of a measurement's rig: `claude/019-sweep-d`'s own VM and
another session's, on their own lane blocks. Neither this lane's wire
(15073) nor its agent socket (`…now-agent-501-f384`) is reachable from
them, and the `--expect-build` assertion below is what turns that from a
belief into a check.
