# Test drive

One command. It boots a throwaway `mac99` clone, stages the extension and
the agent, cold-reboots to load the INIT, launches the agent, proves the
wire, and opens the mirror window:

```bash
MIRROR_DISPLAY=1 tools/spin-up.sh
```

Takes about three minutes, most of it two OS 9 boots. You get a `cocoa`
window (the real guest screen) **and** the MirrorApp window (the mirror,
drawn host-side from semantic state). Put them side by side — that
comparison is the whole point.

When you're done:

```bash
tools/stop-mirror.sh
```

It quits the VM through QMP, never `pkill`, and deletes the clone. The
shared base image is untouched.

## One flag that matters

The rig launches with **`--scope all`**. `--scope front` walks only the *front
application*, so every other app's windows are missing from the scene entirely —
which looks exactly like windows being hidden, and was mistaken for a rendering
regression once. If windows you can see in the guest are absent from the mirror,
check that flag first.

## What to look at

The mirror is drawn from **structure, not pixels**. Every window, control,
and menu on the left came over the wire as data and was re-drawn in
Platinum on the right.

- **Move a guest window, or switch apps.** The mirror follows: geometry,
  z-order, and the menu bar all track the real front application.
- **Open something with real controls** — Graphing Calculator is the good
  one. You should see its actual menus, the `Graph` button drawn at its
  true position, and scrollbar thumbs at their real values.
- **Window interiors are blank on purpose.** The content plane is
  deliberately unsourced, so you get correct chrome around empty space.
  That is the design, not a missing feature.

What I'd most like your eye on is **Platinum fidelity** — the grays, the
title-bar widgets, the font weights, the button shapes. I can verify the
data pipeline and the app's own offscreen render, but whether it *looks*
right is a judgment I can't make. A render I took on 2026-07-29 is
committed as `render-2026-07-29-graphcalc.png` if you want a before.

## Known limits

**`axdo` is fine.** An earlier version of this page warned it wedged the
session; that was my test client's bug, not the guest's, and it is retracted
in [STATUS.md](STATUS.md). It answers honestly, including
`not_actionable` when a control is hidden or disabled — which most of
Graphing Calculator's controls are.

**Keyboard actuation runs out.** `key` actuates about nine times per boot and
then stops for the rest of that boot, reproduced three times. Replies keep
succeeding, so it looks fine from the outside — the first few presses always
work, which is exactly what makes a short manual test misleading.

**Talk to the agent over one connection.** It serves a single connection
serially; a fresh socket per request races its accept and gets refused, which
surfaces as a connection reset. `MirrorApp` does the right thing already.

## If it doesn't come up

- `run/qemu.log` — the emulator's own output.
- The agent's log lives in the guest at
  `Macintosh HD:TimBotTu:mirror-dev:mirror.log`; read it through the anchor
  worker on the port `spin-up.sh` printed.
- `spin-up.sh` picks free ports and prints them, so a stale VM from an
  earlier run can't collide — but it will refuse to start if you pin ports
  that are busy.
