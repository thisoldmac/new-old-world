# Emulator Anti-Patterns

Each entry is a way agents have actually looped while driving a classic Mac
emulator, drawn from real session transcripts, with the move that ended the loop.
When a session is stuck, match the symptom here before improvising. The governing
escape hatch is the **circuit breaker** in `SKILL.md`: after a few failed tries at
the same action, stop and change strategy — do not grind.

## Contents

- Arguing with the cursor
- Trusting a connection as readiness
- Talking to the wrong machine
- Killing the VM the wrong way
- Grinding the base image into corruption
- Poisoning the single listener
- Starving the harness off the wire
- Rebooting and reload thrash
- Deploying through media
- Screenshot papercuts
- Routing to a non-bootable profile

## Arguing with the cursor (the primary, genuinely unwinnable loop)

**Symptom:** screenshot → estimate coordinates → synthetic move/click → screenshot
→ "it didn't land" → re-estimate, for many turns, never converging.

**Cause — and why it does not converge:** the guest pointer is relative-only with
no working absolute mode, and *both* ways out are blocked at once. Closed-loop
correction (read cursor position, adjust) is **starved by the very operation you
are driving** — a modal Toolbox loop such as `MenuSelect` does not yield to the
harness, so position feedback stops exactly when you need it. Open-loop
dead-reckoning is **non-deterministic**: guest mouse acceleration swings the
compensation factor roughly 0.6×–1.6× with event pacing (2ms vs 3ms) and with
cursor velocity *carried over from the previous action*. A separate failure feeds
it: the renderer's hit-box, the host's estimate, and the guest's real framebuffer
geometry are computed independently and disagree, so a "correct" click lands
outside the real control.

**Fix:** do not drive the GUI by pixels. Reach the outcome with semantic verbs
(`launch`, `activate`, menu/AppleEvent actions) or keyboard equivalents (Cmd-S
instead of clicking Save). If a pixel action is truly unavoidable: localize the
cursor by frame-differencing against a clean desktop, move in 1px steps, send
click pairs as tight batches, avoid screen edges (the locator clamps at 0). If it
still will not converge, **defer the primitive** — this loop has consumed whole
sessions for a non-critical click.

## Trusting a connection as readiness (boot-race loop)

**Symptom:** launch "succeeds," the first real request refuses/resets/hangs, agent
retries the whole launch.

**Cause:** the user-mode network stack (SLIRP) accepts the TCP connect before the
guest service is listening, and even resets on first data while the in-guest Open
Transport listener settles; a first connection can also race ARP resolution.

**Fix — the single most reliable pattern agents converged on:** a **bounded
`ping` until-loop**, never a fixed `sleep`. Retry only on transient
connect/empty-frame/reset failures; never retry a semantic error. Budget a cold
boot at ~55–75s (the improper-shutdown Disk First Aid scan stretches it). Foreground
`sleep` is often blocked by the tool harness anyway — poll in a background
until-loop.

## Talking to the wrong machine (stale-instance hesitation and silent misread)

**Symptom:** either the agent stalls on "is that VM stale or another session's?",
or results look plausible but contradict the change just made.

**Cause:** leftover VMs, half-alive host-forwards, or a leftover scope file
silently scoping a spawn; a port-bind conflict makes a new service fail with no
retry, so you talk to the old process; on a shared host, other sessions' VMs are
live and must be left alone.

**Fix:** launch your own `--instance N` (own port, run dir, and disk). Confirm the
port is free first; identity-check the build/Git stamp in the `ping`/`gestalt`
reply before trusting any result. Enumerate running QEMUs and leave other
sessions' guests alone — never borrow or kill them.

## Killing the VM the wrong way (crash dialog + cross-session collateral)

**Symptom:** the VM is gone but the next launch is blocked; a host crash dialog
waits for a human; or *another session's* VM died.

**Cause:** a hard SIGKILL of a live guest trips the macOS crash-reporter dialog
that needs manual dismissal; a broad `pkill -f <pattern>` on a shared multi-agent
host matches and kills a parallel session's VM (observed: a broad kill took out
another session's guest on a different port).

**Fix:** stop with QMP `quit` (optionally a guest power-down first) — the clean
path. If QMP is truly gone and the VM is wedged, kill **the exact PID from the
pidfile**, never a name pattern, never SIGKILL a still-live guest. An unclean exit
boots into the Disk First Aid modal next time; dismiss it with a QMP
`send-key ret` (it is harmless — "repairs completed successfully").

## Grinding the base image into corruption (slow-burn ratchet)

**Symptom:** over a session the guest degrades — missing files, `Where_have_all_my_
files_gone?` artifacts, hfsutils/machfs misreading the volume.

**Cause:** each force-quit/`system_reset` leaves HFS dirty; repeated unclean exits
accumulate **real** filesystem damage, and if you booted the shared base that
damage is permanent.

**Fix:** always boot a session-private clone so the damage is thrown away on stop;
exit cleanly via the harness shutdown/QMP `quit`; treat a cold boot after an
unclean exit as expected-repair, not a new bug.

## Poisoning the single listener with a second connection

**Symptom:** the in-guest harness stops answering — even `ping` — and stays deaf
across a reboot.

**Cause:** the guest listener is a single-threaded cooperative loop. Opening a
**second** live connection to it (e.g. a poller plus a CLI snapshot on the same
port) resets connections and can wedge the listener until a fresh single client.

**Fix:** route every consumer through **one shared client**. Prove a feature with a
single-client capture→replay rather than a live multi-request poller. This is the
concrete form of "a healthy guest can look wedged."

## Starving the harness off the wire (cooperative scheduling)

**Symptom:** the harness goes silent right after a launch or a heavy verb; a
"healthy" guest is indistinguishable from a crashed one.

**Cause:** classic Mac OS is cooperative. A blocking guest operation (a large
`entire contents` enumeration, a foreground app parked in a blocking input loop, a
synchronous `OTConnect` to an unreachable host that blocks before first draw) takes
the single-threaded harness off the wire.

**Fix:** before concluding "dead," cross-check with a second cheap verb (`echo`) —
a timed-out `list` with a healthy `echo` is a starve, not a crash. Stop hammering
in the foreground; watch for recovery with a background poll. Time requests to land
in a gap between the guest's own contending pollers. Keep an out-of-band recovery
channel (QMP `send-key`) for a modal block.

## Rebooting the wrong way / reload thrash

**Symptom:** minutes of blind waiting after a reset that never boots; or one cold
reboot per config change, each ~2 minutes.

**Cause:** QMP `system_reset` on mac99 drops to **OpenFirmware**, not a cold OS
boot; and reloading in-guest config (e.g. a worker's verb scope) needs a full cold
boot to take effect.

**Fix:** for a real power-cycle use a fresh launch (`stop` + `launch`), not
`system_reset`. Before a reload-reboot, enumerate *every* scope/verb the run will
need and apply them in one pass, so you pay the cold-boot cost once. See
[boot-and-liveness.md](boot-and-liveness.md) for telling hung from slow.

## Deploying through media (silent stale mounts)

**Symptom:** a rebuilt `.dsk`/CD is iterated by hot-swap, but the guest keeps
running the old bits and the result is confidently wrong — no error.

**Cause:** CD hot-swap leaves stale Finder mounts (`-2806`/`-35`); the medium can
also be locked (`ide1-cd0 is locked`).

**Fix:** deploy over the network (FTP + MacBinary), not media. If you must swap
media, `eject` (force) then `blockdev-change-medium`, and make the build
**self-identifying** so a stale relaunch is detectable rather than silent.

## Screenshot papercuts

**Symptom:** unreadable captures, garbled text, wrong format.

**Cause:** QMP `screendump` writes PPM regardless of file extension; downscaling
destroys OCR; MacRoman high bytes garble if decoded as UTF-8; host-screen capture
hijacks the operator's desktop and is unreliable.

**Fix:** pass an explicit format or convert; read structured state before pixels;
fix text garble at the decoder (MacRoman), not by re-shooting; use in-guest capture,
never host-screen grab. For "did it change / hung or slow," diff frames over time
rather than reading one harder — see [boot-and-liveness.md](boot-and-liveness.md).

## Routing to a non-bootable profile (pb1400)

**Symptom:** attempts to bring an OS up on pb1400.

**Cause:** the pb1400 QEMU model cannot boot an OS — no SWIM floppy controller, it
stalls before the first HFS read; it is an Old-World modeling target, not a boot
target.

**Fix:** use mac99 (PPC) or q800 (68K, including floppy-boot work). Do not treat a
pb1400 launch as evidence.
