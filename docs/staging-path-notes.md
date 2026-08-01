# Staging path: notes from the upstream read (lane audit/staging-path)

Status: in progress, 2026-08-01. Emulator only. Nothing here has run on metal.

## The gap

`scripts/build-guests` builds `ext/` (NowExt.bin) and nothing deploys it.
`tools/` holds only `fakeguest.py` and `mb_rename.py`. `scripts/deploy-68k` is
68K-app-only and never names the Extensions folder. Three of NOW's four planes
(anchors P1, content P3, act P4) live in that INIT, so:

- qdtrace answers content-plane-absent everywhere (docs/emu-readiness.md:534-538)
- actselftest, a hard precondition (docs/emu-readiness.md:251-300), can never run
- the no-hijack / menu lanes' oracles have nothing to measure

## Upstream authority (mirror/tools/, commits 5c822b0, f42cb09, a82cc8f)

`spin-up.sh` = boot fresh clone -> stage -> flush wait -> cold reboot -> verify.
`stage-agent.py` = push MacBinary through the *baked anchor worker* on guest
port 1400 and verify by fork size.

Hard-won facts the upstream encodes, to honour verbatim:

1. **An INIT loads at BOOT ONLY**, and OS 9 ignores QMP `system_powerdown`, so
   the reboot must be a hard QMP `quit` + relaunch without `-loadvm`. A stage
   without that silently leaves the old INIT resident.
2. **Wait for the volume flush** before the power-off (upstream sleeps 20s);
   the post-reboot `stat` is the real guardrail.
3. **Verify by fork size / type**, not by exit code. The INIT's code is in the
   RESOURCE fork, so `min_rsrc` is the load-bearing assertion.
4. **`catalog dates err -43` on push is a KNOWN anchor quirk**, measured
   2026-07-29 on mac99/os91-runner: every byte arrives and the timestamps do
   update. Tolerate exactly that string — and still require the verify to pass.
   Never tolerate it blindly.
5. **`mkdir` is FSpDirCreate**: one level, no parents, -48 if the leaf exists.
   Walk the chain and treat only "already exists" as success.
6. **Ports must be probed free, not hardcoded** — another session may hold one.
   Upstream advances in steps of 2 from a base.
7. **Session-private clone, always** (`tbt_clone_disk` in the lab's
   `tools/lib.sh`); never boot the shared base.
8. `overwrite=True` on config-file writes: the base image may already carry one,
   and without it a fresh clone dies *after* every push succeeded.
9. A fresh clone always shows the boot-time Disk First Aid modal after a hard
   power-off; upstream dismisses it by spamming QMP `send-key ret` while polling.

## Instance 61 (host port 1461) belongs to the human. Not touched.
