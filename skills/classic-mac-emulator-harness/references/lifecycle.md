# Emulator Lifecycle Mechanics

The blessed lifecycle is launch → wait → identify → drive → stop. Each step has a
failure mode that this file makes explicit. The rules are portable; the concrete
commands live in [local-implementation.md](local-implementation.md).

## Launch: session-private clone, never the base

- **Clone the base image per session and boot the clone.** On APFS a copy-on-write
  clone (`cp -c`) is instant and costs no space until it diverges, so this is
  free. It is also what lets parallel sessions coexist: each agent boots its own
  point-in-time disk, so writes never corrupt another agent's boot and no
  image-lock collision occurs.
- **Boot the shared base read-write only to persist on purpose** — installing
  software or authoring a snapshot. Ordinary verification never does this.
- **One VM per disk image.** A second VM against the same disk is the image-lock
  corruption case. Guard against double-launch before booting.
- **Headless for automation** (`-display none`); an interactive display seat is
  for a human co-driving, and co-driving requires announcing before and after each
  agent-driven interaction so the shared pointer is safe to touch.
- **Own control socket, own forwarded port, own run directory** per instance, so
  a fleet of workers does not contend. Preflight the ports and fail fast, naming
  the holder, rather than silently binding a wrong one.

## Wait: request-level readiness only

The user-mode network stack accepts a host-forward TCP connection **before** the
guest service is listening. A successful `connect()` — or a port that shows as
open — is not readiness. Readiness is a real request answered:

- Poll `ping` (or the equivalent liveness verb) on a retry loop until it returns
  the guest's identity, then proceed.
- Budget for a cold boot taking minutes; a snapshot warm-resume answering in ~1s.

## Identify: prove you are talking to your VM

A stale instance, a wedged prior harness, or a leftover host-forward on the target
port will answer plausibly as a *different* machine — and a port-bind conflict
makes a fresh service fail to bind with no retry, so a new "launch" silently talks
to the old process. Before believing any reply:

- Confirm the intended port is actually free on the host before launching against
  it (a live listener means something is already there — pick another port).
- Check the build stamp / Git revision in the `ping`/`gestalt` reply against the
  binary you deployed. Identity-check first, conclude second.

## Drive: harness verbs, structured-first

- Act on the guest with semantic verbs (`launch`, `activate`, menu/AppleEvent
  actions), not coordinates. Injected input, even through the harness, goes to the
  **front** app and to a **pixel** — so `activate` the target and confirm it is
  visible before any positional action, and never trust a live mouse position.
- Read the guest with `observe` (structured state) first; escalate to region OCR
  and pixels only as the claim requires (see the SKILL evidence ladder).
- Cooperative scheduling can starve the harness: launching a foreground app that
  parks in a blocking input loop can take the control channel off the wire until
  that app yields. Keep an out-of-band recovery channel (a substrate key-send on
  the emulator) for exactly this.

## Stop: quit cleanly, reclaim the clone

- Ask the emulator to `quit` (optionally a guest power-down first). **Never**
  `pkill`/SIGKILL — a hard kill trips the host crash-health dialog that a human
  must dismiss, which is itself a silent wedge for an unattended agent.
- **Never `rm` a live control socket.** The listener survives on the unlinked
  inode; you orphan the VM and lose the clean-stop path.
- Let the stop tooling delete the session clone and its run artifacts (or preserve
  them deliberately as evidence). The shared base is never in the run directory,
  so a clone teardown cannot touch it.

## Recovery ladder (gentlest to hardest)

1. Clean `quit` / guest power-down over the control channel.
2. Emulator quit + relaunch — the reliable power-cycle. A guest soft-restart and a
   substrate hard `reset` both tend to wedge at the reset vector; do not rely on
   them.
3. Snapshot rollback (`loadvm`) to a known-good state — fast and non-destructive
   on a private clone.
4. Physical reboot — hardware only, human-attended.
