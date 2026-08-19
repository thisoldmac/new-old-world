# Boot and Liveness Diagnosis

The most expensive emulator loops are not clicks — they are **blind waits** on a
guest whose state the agent cannot read: "is it still booting, or hung?" Reading a
single screenshot cannot answer that, and re-reading it harder is the loop. Two
deterministic techniques end it. Both share one principle: **sample over time and
compare**, never interpret one frame.

## Frame-differencing beats reading one screenshot

A single classic Mac boot frame is genuinely ambiguous. A centered floppy/disk
icon can mean "System is loading (then stalled)" or the "off" phase of a
blinking-`?` (ROM found no bootable System) — opposite conclusions. A gray screen,
a static desktop, a modal — all look the same held still.

Resolve it by capturing **N frames across time and diffing the bytes**:

- A blinking-`?` flickers — successive frames differ.
- A stalled boot is byte-static — frames a=b=c, zero differing bytes.
- Progress shows as changing pixels in the region that should be changing.

So "second frame identical after ~185s" is proof of stall, not a reason to shoot a
third. Decide from the diff, not the image.

## The program counter is the real boot oracle

When the framebuffer cannot distinguish hung from slow — especially before any
display init, or during 68K translation — drop below the screen and sample CPU
registers over time via QMP (`info registers` / `human-monitor-command`):

- **Constant NIP** (PowerPC program counter) across timed samples ⇒ a genuine
  tight busy-wait: the guest is stuck. Narrow to the exact poll (e.g. an SCC
  channel-A status read the ROM spins on).
- **Advancing NIP** across samples ⇒ slow-but-progressing (often translated-mode
  execution); keep waiting.
- **NIP pinned at a low reset/exception vector** (e.g. `0x00000004`) ⇒ the core is
  hard-wedged at the exception vector. `system_reset` is a **no-op** on it — do not
  loop resets; `stop` + fresh `launch` is the only recovery.

Register-NIP progress is ground truth for liveness. Do not certify "hung" from a
screendump delta alone, and do not certify "booted" from a launch that was never
confirmed by an identity-checked `ping`.

## Readiness is a request answered, not a socket opened

Cold boot to a serving harness runs ~55–75s (the improper-shutdown Disk First Aid
scan is included). The forwarded port accepts a TCP connect long before the guest
serves. Wait with a **bounded `ping` until-loop** that retries only transient
failures (connect refused, empty frame, reset) and stops on the first identified
reply — never a fixed `sleep`, never socket-open as "ready." Poll in a background
loop; a foreground `sleep` is frequently blocked by the tool harness.

## Reboot semantics are emulator-specific

- `system_reset` on mac99 drops to **OpenFirmware**, not a cold OS boot. A real
  power-cycle is `stop` + `launch` (a fresh QEMU process).
- A guest soft-restart and a substrate hard `reset` both tend to wedge at the reset
  vector. Prefer quit + relaunch.
- `loadvm` itself is fast and reliable (a running guest rewinds in well under a
  second), but the **host-forward and in-guest TCP listeners go stale across the
  snapshot/wake boundary**: re-inject the forward
  (`human-monitor-command hostfwd_add …`) and expect a settle, or rewind to the
  snapshot rather than fighting a dead socket. Expect a transient volume-not-yet-
  mounted error (`-35`) right after resume; retry after a short settle.
