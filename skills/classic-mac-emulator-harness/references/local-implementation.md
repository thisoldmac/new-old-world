# Local Implementation Pointer (timbottu)

This file is **environment-specific**, not portable doctrine. It names the concrete
tooling that implements the blessed lifecycle on the desk that holds a harness
checkout. If the tooling moves or is absent, the doctrine in `SKILL.md`,
`lifecycle.md`, and `anti-patterns.md` still holds; re-point this file, do not
rewrite those.

The harness lives in the `timbottu` repository; the desk that holds one knows
where its checkout is, and every command below is relative to that checkout's
root. Its `AGENTS.md > Operating the VM` and `docs/05`, `docs/06`, `docs/10`,
`docs/26`, `docs/29`, `docs/44` are the upstream authority for everything below.
Verify a path exists before relying on it.

## Lifecycle commands

- **Launch (headless, session-private clone):**
  `tools/launch --machine mac99 --headless` — clones the base to
  `run/session.qcow2` (removed on stop), opens `run/qmp.sock`, forwards the harness
  port. Use `--machine q800` for 68K. Add `--instance N` for a parallel worker
  (own run dir `run/i-N`, host port `1400+N` → guest `:1400`). Warm-resume with
  `--loadvm runner-ready` when the ready snapshot exists.
- **Stop (clean quit, reclaim clone):** `tools/stop` (or `tools/stop --instance N`,
  `--keep` to preserve evidence). Sends a guest power-down then QMP `quit`; refuses
  to `pkill`.
- **Substrate (QMP) one-shots:** `tools/qmp run/qmp.sock <command> [json-args]` —
  e.g. `query-status`, `screendump '{"filename":"…","format":"png"}'`,
  `snapshot-load`, `quit`. Add a live host-forward without a VM restart:
  `tools/qmp run/qmp.sock human-monitor-command '{"command-line":"hostfwd_add net0 tcp:127.0.0.1:1401-:1401"}'`.
- **Readiness:** poll the harness `ping` (retry loop) until it returns the build /
  Git identity — do not treat the forwarded port opening as readiness.

## Control channel (harness plane)

- Blessed consumer entrypoint: the `mcp` server (`timbottu_mcp`, Streamable HTTP,
  loopback-only on its configured port) for the 0.7 runtime. The legacy
  `mcp-classic` FastMCP server is the developer workbench for the raw wire
  surface.
- Raw one-shot workbench client: `tools/hc <verb> [args…] --host 127.0.0.1 --port
  1400 --timeout N` (args are positional — always pass `--host`/`--port`, and
  identity-check the reply). First-contact sequence: `ping` → `gestalt` → `observe`.
- Deploy over the network, never CD media: `tools/push <local.bin>
  "Volume:Folder:App" 127.0.0.1 <port>` (MacBinary), FTP fallback over the
  forwarded `2121→21` + PASV `3000-3020`. HFS colon paths only (`Macintosh
  HD:TimBotTu:…`), never POSIX slashes.

## Assets and toolchain (env-overridable)

- mac99 base image: an OS 9.1 runner qcow2, named by `TIMBOTTU_IMAGE`; ready
  snapshot tag `runner-ready`.
- QEMU binaries (source-built, SDL display): the harness checkout's own QEMU
  build tree (`qemu-system-ppc`, `qemu-system-m68k`, `qemu-img`); override with
  `TIMBOTTU_QEMU` / `TIMBOTTU_QEMU_IMG`.
- Retro68 PPC toolchain: `powerpc-apple-macos/cmake/retroppc.toolchain.cmake`
  inside a Retro68 build tree, named by `TBT_RETRO68_TOOLCHAIN`.
- Reference headless rig: `next/tools/run-emulator-spike` (preflight-gates tools,
  assets, and ports; launches a session-private mac99 clone; waits request-level;
  stages; and QMP-`quit`s only its own exact-PID VM on cleanup).

## Profile status on this machine (2026-07)

- **mac99** — usable; PowerPC / Mac OS 9.1.
- **q800** — usable; 68K.
- **pb1400** — the emulator cannot yet boot an OS; not a verification target.
