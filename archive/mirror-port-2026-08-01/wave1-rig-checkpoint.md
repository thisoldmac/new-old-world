# Wave 1 rig checkpoint — UNVERIFIED, session in progress

Overnight parity session, rig lane, branch `claude/mirror-parity-overnight`.
This is a scratch checkpoint per the session's commit-early rule, not a
published doc — delete or fold into docs/local once the wave is done.

## Job 1 — guest cross-build: DONE (builds only, not run)

```
touch now-guest-ppc/src/core/build_stamp.c
export NOW_PPC_TOOLCHAIN=/Users/michelle/Lab/Tools/Retro68-build/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake
export NOW68K_TOOLCHAIN=/Users/michelle/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
scripts/build-guests both
```

Result: `now-guest-ppc: ok`, `now-guest-68k: ok`, `ext: ok`.

Artifacts land in a path keyed to this worktree's absolute path (hashed),
not a shared drawer:

```
$TMPDIR/now-guest-builds/3943a54def31/ppc/New Old World.bin   <- canonical PPC app
$TMPDIR/now-guest-builds/3943a54def31/ext/NowExt.bin          <- 68K INIT
$TMPDIR/now-guest-builds/3943a54def31/m68k/now-guest-68k.bin
```

Builds only. Nothing here proves behaviour (AGENTS.md).

## Job 2 — emulator: DONE, VM left running

Accidentally launched a stray default-mode VM from `tools/launch` (no
args) while checking usage, at the shared top-level
`/Users/michelle/Lab/Code/timbottu/run` using the classic port block. It
was mine (this session, pid 43297) so I tore it down immediately with
`tools/stop` (QMP quit) rather than leaving it. Did not touch any other
VM (`now/run`, `mirror/run`, `mirror-lane-p2-text-ops/run`, or the
untracked `/tmp/qemu-ws-...` one) — those predate this session or belong
to other checkouts.

Ran `scripts/spin-up-ppc` from this worktree (its own run dir, `<worktree
root>/run`, distinct from the shared checkout's `now/run`). Passed
`NOW_WIRE_PORT=5252` because another "New Old World" host app on this Mac
held 5250 at the time — that made the script's *own* internal wire check
time out (the guest's prefs are unset on this fresh clone, so it dials the
compiled default `10.0.2.2:5250` regardless of what I told the script to
listen on; `NOW_WIRE_PORT` only moves the listener, not the guest's
target). Everything through the cold reboot and file-survival check
still passed. That other host app quit on its own a little later, freeing
5250, and a manual `tools/askguest.py --port 5250` then caught the
guest's next retry:

- `hello.build` = `e830cc53f6c1 2026-08-01T07:57:38Z`, byte-for-byte the
  same as `build_stamp_gen.h` from the Job 1 build — stamps agree.
- `actselftest` → `abi-agreed`, answered `0x03E70007`, read back the same
  — the act plane's trap ABI holds on this machine.
- `qdtrace op=status` and `axsnap` both answered normally.

Baseline screenshot: `docs/local/wave1-baseline-guest.png` (800x600,
`tools/snap` full-res over the anchor port), guest sitting on the
Screenshots module of the Workshop, "Connection: Retry in 3s" visible —
i.e. auto-reconnect is doing exactly what it should between one-shot
`askguest.py` sessions. Did not attempt a host-app pane render; not
blocking on it per the brief.

### Reaching this VM for later waves

```
name       : NOW spin-up  (qemu-system-ppc, this worktree's own clone)
run dir    : /Users/michelle/Lab/Code/timbottu/now/.claude/worktrees/now-mirror-audit-1db1e4/run
qemu pid   : 48434  (run/qemu.pid)
disk       : run/session.qcow2  (disposable clone of ~/Lab/Assets/os91-qemu/os91-runner.qcow2)
qmp        : run/qmp.sock        (control) / run/qmp-ui.sock (host-app-only, don't touch)
anchor port: 127.0.0.1:1706      (the base image's baked worker — tools/snap, stage-ext.py)
wire port  : guest dials 10.0.2.2:5250 (compiled default; no custom prefs saved on
             this clone) — check `lsof -nP -iTCP:5250 -sTCP:LISTEN` is clear, THEN
             `python3 tools/askguest.py --port 5250 <verbs...>` to talk to it.
             (5252 was only this session's failed workaround attempt; ignore it.)
stop       : /Users/michelle/Lab/Code/timbottu/tools/qmp run/qmp.sock quit   # QMP quit, never pkill
             or: tools/stop (from this worktree; no --instance, this is the plain run/ dir)
```

VM is LEFT RUNNING for later waves, per the brief.
