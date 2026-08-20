---
name: classic-mac-emulator-harness
description: Drive a classic Macintosh emulator (QEMU mac99 for PowerPC/CarbonLib, q800 for 68K) headlessly and deterministically to verify classic Mac OS 8.6–9.2.2 software, without falling into synthetic-cursor or screenshot-and-click loops. Use when a classic Mac task needs to launch, boot, observe, drive, or tear down an emulated guest for acceptance testing or runtime diagnosis — booting a session-private clone, waiting for readiness, controlling by in-guest OS-API verbs, capturing evidence, and stopping cleanly. Use the peer platform and UI skills for build, packaging, and layout; use this skill for the emulator control plane itself.
---

# Classic Mac Emulator Harness

Verifying classic Mac software on an emulator is a **control-plane** problem, not
a build problem. An agent that drives the guest through the wrong plane does not
merely go slow — it enters an unwinnable loop. This skill blesses the plane, the
lifecycle, and the evidence order that make emulator verification deterministic,
and names the anti-patterns that produce the "arguing with the cursor" failure.

The doctrine here is portable to any harnessed classic Mac emulator. The concrete
local tooling that implements it is named in
[local-implementation.md](references/local-implementation.md); treat that file as
the environment-specific pointer, and this file plus the other references as the
rules that outlive any particular tool.

## Break the Loop Before It Grinds

The failure this skill exists to prevent is the infinite loop, not the slow task.
Adopt a **circuit breaker**: if the same action fails about three times without
progress, stop repeating it and change strategy — read the code, grep the prior
fix for this exact problem, switch planes, or defer the primitive. Repeating a
click, a reset, a relaunch, or a readiness poll that is not converging burns whole
sessions and, for unclean stops, damages the disk. Some emulator loops (see the
cursor loop in [anti-patterns.md](references/anti-patterns.md)) are structurally
unwinnable; recognizing one early and deferring it is the correct outcome, not a
failure. Three misses on the same target is the signal to stop guessing.

## Choose the Blessed Plane First

Two planes can move a classic Mac guest. They are not equivalent, and the choice
is the single largest determinant of whether verification converges.

- **Harness plane (blessed).** In-guest OS-API control over a JSON/TCP channel:
  semantic verbs such as `ping`, `gestalt`, `observe`, `launch`, `activate`,
  `stat`/`read`/`write`, and `capture`. Deterministic, cheap on the wire,
  reasoned over as structured state, and identical on emulator and real hardware.
  This is the agent's primary and default path.
- **Substrate plane (restricted).** External emulator god-mode over QMP. Use it
  **only** for `screendump`, snapshot `save`/`load`, live host-forward add, and a
  clean `quit`. It is emulator-only and does not exist on hardware; anything you
  build on it cannot be moved to metal.

**Synthetic pointer input is retired from both agent paths.** On mac99 + Mac OS 9,
QMP synthetic mouse events are unreliable: there is no working absolute pointer,
two coexisting pointers (ADB and USB) misroute events, and the software cursor is
not reliably present in a `screendump`, so the agent cannot even confirm where the
pointer landed. Driving the GUI by screenshot-aim-click is therefore a loop with
no exit condition. Act on windows and applications by **semantic verbs**
(`launch("App")`, `activate`, menu/AppleEvent actions), never by coordinates.

## Run the Blessed Lifecycle

Read [lifecycle.md](references/lifecycle.md) for the full mechanics. The spine:

1. **Launch a session-private clone, headless.** Never boot the shared base
   image; never launch a second VM against one disk (image-lock corruption). The
   default is a throwaway per-session clone with its own control socket and its
   own forwarded port. Add `--headless` (`-display none`) for automated runs.
2. **Wait at the request level, not the socket level.** The host-forward accepts
   a TCP connection before the guest is listening, so a successful `connect()`
   proves nothing. Poll a real `ping` until the guest answers with its identity.
3. **Verify identity before trusting a reply.** A stale VM or a leftover forward
   on the same port answers plausibly as a different machine. Check the build/Git
   stamp in the `ping`/`gestalt` reply before believing any result.
4. **Drive through harness verbs**, preferring structured state over pixels.
5. **Stop cleanly by asking the emulator to quit.** QMP `quit` is the clean path.
   Never SIGKILL a still-live guest — a hard kill trips the host crash-health
   dialog that needs a human to dismiss — and never use a broad `pkill -f <pattern>`
   on a shared host: it will match and kill another session's VM. If QMP is gone
   and the VM is wedged, kill the **exact PID from the pidfile**, never a name
   pattern. Never `rm` a live control socket — the listener survives on the
   unlinked inode and you orphan the VM. Repeated unclean exits also ratchet real
   HFS damage into the disk, which is another reason the boot disk is a throwaway
   clone.

Warm-resume from a ready snapshot instead of cold-booting when a saved state
exists; it turns a multi-minute boot into a ~1s serving target. `loadvm` is fast
and reliable, but the host-forward and in-guest listeners go stale across the
snapshot/wake boundary — re-inject the forward or rewind, do not trust the old
socket. When you cannot tell whether a guest is hung or merely slow, read
[boot-and-liveness.md](references/boot-and-liveness.md): diff frames over time and
sample the program counter — never certify state from one screenshot.

## Select the Machine Profile by ISA

Same lifecycle, different profile. Match the profile to the artifact's runtime,
not to convenience.

- **mac99** — PowerPC, Mac OS 9.x. The primary profile for CFM/CarbonLib (PPC)
  work. Requires a PowerPC CPU model the New World ROM accepts; ADB mouse only.
- **q800** — Quadra 800, 68K. The profile for 68K work. Boots via an overlay so
  snapshot save/load is available; the 68K sandbox for INIT and Toolbox 68K
  artifacts.
- **pb1400** — PowerBook 1400. **Not a usable verification target: the emulator
  cannot yet boot an OS.** Do not route acceptance testing to pb1400 or report a
  pb1400 launch as evidence, regardless of what other documents imply. Reassess
  only when a boot is demonstrated.

An emulator gives repeatability, not hardware equivalence. It does not settle
timing, driver, extension-conflict, networking, or memory-pressure claims; those
remain physical-hardware rows owned by the peer platform skill.

## Order the Evidence Structural-First

Escalate only as far as the claim requires; each step up costs more and is more
loop-prone. Read [anti-patterns.md](references/anti-patterns.md) for the traps at
each rung.

1. **Structured state** — `observe` returns front window, menus, modal, focus,
   and cursor shape as JSON. LLM-native, tiny on the wire, impossible to fake with
   substrate god-mode. Start here.
2. **Region text** — native region capture plus host-side OCR when you need a
   label the structured state does not carry.
3. **Targeted pixels** — a cropped capture of a known region for visual truth.
4. **Full-screen capture** — last resort only. It is slow (a full-colour metal
   screenshot is tens of seconds) and downscaling destroys OCR; reach for it only
   when a human must look at the whole frame.

Never begin an interaction by capturing the screen. Begin by asking the guest
what it is showing.

## Report the Verification Faithfully

State the machine profile and OS row, the plane each action used (harness vs
substrate), the readiness check performed, the evidence rung reached, and residual
uncertainty. Do not report "runs on the emulator" from a launch that was never
confirmed by an identity-checked `ping`, and do not promote an emulator result
into a hardware claim.
