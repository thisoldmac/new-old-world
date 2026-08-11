#!/usr/bin/env python3
"""Photograph a Platinum push button WHILE IT IS HELD DOWN.

    tools/local-pressed-capture.py --port 15457 --qmp /private/tmp/nowvm-x/qmp.sock

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody.

WHY THIS EXISTS
---------------
Nothing in this project has ever seen a pressed control. Every capture
route screendumps AROUND an act - `tools/local-control-drive.py:19` sends
`ctlact` and shoots "before and after" - and the one tool that holds the
button down, `tools/local-drag-vehicle.py`, never screendumps at all. So
the corpus contains a great many quiescent desktops and not one pressed
button, and `docs/deriving-a-drawn-procedure.md:262` already says the same
thing about tabs: "there is no capture of ... a pressed tab ... anywhere in
the corpus."

That gap is why this script is a script and not a paragraph of inference.
The mirror is about to draw a pressed state, and a drawing nobody has
compared against the machine is exactly the confident wrong answer plan
018 exists to remove. **When the render and the machine disagree, the
machine is right, even when the render looks better** - which requires
first that the machine be photographed.

It is the two existing halves put together: the drag vehicle's `dragpress`
leaves the button down, and while it is down we screendump. Between the
two lies the only window in which a pressed control exists anywhere.

WHAT IT CANNOT PROMISE, AND WHY THAT IS THE INTERESTING PART
------------------------------------------------------------
A pressed button is drawn by the APPLICATION, inside `TrackControl`, and
`TrackControl` is precisely the state in which the application has stopped
calling `GetNextEvent` (docs/architecture.md:329). `dragpress` puts the
mouse button down in the low-memory globals; whether the application
notices depends on whether it is in a tracking loop at all.

So there are two possible outcomes and BOTH are findings:

  * the shots differ inside the control's rectangle - we have the machine's
    own pressed pixels, and the renderer gets a measured drawing;
  * the shots are identical - the button never drew itself pressed, and the
    honest conclusion is that a *guest-side* pressed state is not
    observable this way at all. That does not stop the mirror drawing its
    own press feedback; it means the drawing is the HOST's mark for the
    person's intent and must never be presented as mirrored guest state.

This script reports which happened and does not round either one up.
"""

import argparse
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402


def screendump(qmp_sock, out):
    """QMP observes pixels only; it is never an input route (tools/shot:3)."""
    ppm = out + ".ppm"
    lab = os.environ.get("NOW_LAB_ROOT", os.path.dirname(ROOT))
    subprocess.run([os.path.join(lab, "tools", "qmp"), qmp_sock, "screendump",
                    json.dumps({"filename": ppm})],
                   check=True, capture_output=True)
    return ppm


def read_ppm(path):
    """P6 binary PPM, as QEMU's screendump writes it (tools/fidelity-pair)."""
    with open(path, "rb") as fh:
        blob = fh.read()
    fields, at = [], 2
    while len(fields) < 3:
        while at < len(blob) and blob[at:at + 1].isspace():
            at += 1
        if blob[at:at + 1] == b"#":
            while blob[at:at + 1] not in (b"\n", b""):
                at += 1
            continue
        start = at
        while at < len(blob) and not blob[at:at + 1].isspace():
            at += 1
        fields.append(int(blob[start:at]))
    return fields[0], fields[1], blob[at + 1:]


def px(img, w, x, y):
    o = (y * w + x) * 3
    return img[o], img[o + 1], img[o + 2]


def crop_census(path, rect, label):
    """Every colour inside `rect`, most common first."""
    w, h, img = read_ppm(path)
    counts = {}
    for y in range(max(0, rect["t"]), min(h, rect["b"])):
        for x in range(max(0, rect["l"]), min(w, rect["r"])):
            counts[px(img, w, x, y)] = counts.get(px(img, w, x, y), 0) + 1
    total = sum(counts.values()) or 1
    print(f"  {label}: {total} px inside the rect, {len(counts)} colours")
    for rgb, n in sorted(counts.items(), key=lambda kv: -kv[1])[:8]:
        print(f"    #{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X}  {n:6d}"
              f"  {100.0 * n / total:5.1f}%")
    return counts


def diff_rect(a, b, rect):
    """Which pixels inside `rect` changed, and how."""
    wa, ha, ia = read_ppm(a)
    wb, hb, ib = read_ppm(b)
    if (wa, ha) != (wb, hb):
        print(f"  the two shots are different sizes ({wa}x{ha} vs {wb}x{hb})")
        return None
    changed, moves = 0, {}
    for y in range(max(0, rect["t"]), min(ha, rect["b"])):
        for x in range(max(0, rect["l"]), min(wa, rect["r"])):
            p, q = px(ia, wa, x, y), px(ib, wb, x, y)
            if p != q:
                changed += 1
                moves[(p, q)] = moves.get((p, q), 0) + 1
    return changed, moves


def any_control(doc, want):
    """A PUSH BUTTON with a ref and a real rectangle, by preference.

    The first version of this took the first control with a rectangle and
    got a scroll bar, which would have answered a different question: a
    scroll bar's pressed arrow is a different drawn procedure from a push
    button's pressed face, and the renderer's `drawButton` is what this run
    is about. `want` names the semantic kind so the target is chosen rather
    than stumbled upon.
    """
    fallback = None
    for w in doc.get("windows") or []:
        for c in w.get("controls") or []:
            r = c.get("rect") or {}
            if not c.get("ref"):
                continue
            if r.get("r", 0) - r.get("l", 0) < 8:
                continue
            if r.get("b", 0) - r.get("t", 0) < 8:
                continue
            kind = (c.get("semantic") or {}).get("kind")
            if kind == want or c.get("role") == "button":
                return c, w
            fallback = fallback or (c, w)
    return fallback or (None, None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--wait", type=int, default=240)
    ap.add_argument("--expect-build", default="auto")
    ap.add_argument("--shots", default="/tmp/pressed-capture")
    ap.add_argument("--kind", default="pushButton",
                    help="semantic kind to aim at (pushButton, checkBox, ...)")
    args = ap.parse_args()

    os.makedirs(args.shots, exist_ok=True)
    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = str(link.hello.get("build") or "")
    print(f"guest build: {build}")
    want = None if args.expect_build == "auto" else args.expect_build
    if want and want not in build:
        raise SystemExit(f"WRONG BUILD: wanted {want!r}, got {build!r}")

    print("\n== 0. the build under test, and its drag capability ==")
    ext = (link.command("mirror", timeout=60).get("mirror") or {}) \
        .get("extension") or {}
    caps = ext.get("capabilities") or 0
    print(f"  resident {ext.get('lifecycle')}  caps={caps} ({bin(caps)})")
    # Bit 7 is kNowPeekTableCapDrag. This is also the capability assertion
    # AGENTS.md requires before believing anything this guest says: every
    # QEMU guest on this Mac sees the host as 10.0.2.2 and any session's VM
    # can answer this listener.
    if not caps & 0x80:
        print("  FAIL: this resident advertises no drag vehicle (bit 7 "
              "clear); nothing below could hold a button down.")
        return 1
    print("  bit 7 set: the drag vehicle is the one under test.")

    doc = None
    for _ in range(12):
        doc = link.scene(full=True, timeout=120)[0]
        if "ok" in [p.get("bind") for p in (doc.get("processes") or [])]:
            break
        time.sleep(2)
    ctl, win = any_control(doc, args.kind)
    if ctl is None:
        print("FAIL: no control with a ref and a real rect; nothing to press.")
        return 1

    r = ctl["rect"]
    # Controls are content-relative; the shot is screen-absolute, and
    # `dragpress` wants GLOBAL h/v. The window's rect is its STRUCTURE
    # rect - its top is the top of the title bar - so the content origin
    # is one title bar lower. Measured on this guest 2026-08-07: the
    # button the scene put at content (172,423) has its border at screen
    # (200,493), and the window rect is (28,50): dx=0, dy=20 =
    # Platinum.titlebarHeight.
    #
    # The first run of this script omitted the 20 and pressed 54 px above
    # the button, into flat dialog grey. It then reported "0 of 2600 px
    # changed" and concluded the machine draws no pressed state - a
    # false negative produced entirely by the rig. Hence the guard below.
    wr = (win or {}).get("rect") or {}
    TITLEBAR = 20
    ox, oy = wr.get("l", 0), wr.get("t", 0) + TITLEBAR
    screen = {"l": r["l"] + ox, "t": r["t"] + oy,
              "r": r["r"] + ox, "b": r["b"] + oy}
    point = {"h": (screen["l"] + screen["r"]) // 2,
             "v": (screen["t"] + screen["b"]) // 2}
    print(f"\n== 1. the target ==")
    print(f"  {ctl.get('title') or ctl['ref']!r} "
          f"role={ctl.get('role')} in window {(win or {}).get('title')!r}")
    print(f"  content-relative {r}, window at ({ox},{oy}) → screen {screen}")

    before = screendump(args.qmp, os.path.join(args.shots, "1-before"))
    print(f"  shot BEFORE: {before}")
    census = crop_census(before, screen, "before")
    # THE RIG GUARD. A push button has a border, a face and a label, so its
    # rectangle is never one flat colour. If it is, the mapping above is
    # wrong and we are looking at empty dialog face - in which case "nothing
    # changed while the button was held" is a statement about the rig and
    # not about the machine, and reporting it as a finding would be the
    # false negative this run exists to avoid.
    if len(census) < 3:
        print(f"  ABORT: the target rectangle holds {len(census)} colour(s). "
              "A push button is never flat, so this rect is not on the "
              "button and any verdict from it would be about the rig.")
        return 1

    print("\n== 2. hold the button down, and shoot while it is down ==")
    reply = link.command("dragpress", dict(element=ctl["ref"], idle=300,
                                           cap=900, **point), timeout=120)
    rows = nowwire.GuestLink.rows(reply, "dragpress")
    d = {row[0]: row[1] for row in rows if len(row) >= 2}
    print(f"  dragpress says: {d}")
    if d.get("Button") != "down":
        print("  FAIL: the button is not down; there is nothing to photograph.")
        return 1
    session = int(d["Session"])
    try:
        # Give the application a beat to notice and redraw, if it ever will.
        time.sleep(1.5)
        during = screendump(args.qmp, os.path.join(args.shots, "2-during"))
        print(f"  shot DURING: {during}")
    finally:
        # ALWAYS let go. A mouse left down is the one failure the resident's
        # dead-man exists for, and this side must not be why it has to fire.
        try:
            link.command("dragrelease", {"session": session}, timeout=60)
            print("  released.")
        except Exception as exc:                       # noqa: BLE001
            print(f"  release failed ({exc}); the dead-man will fire.")

    time.sleep(1.5)
    after = screendump(args.qmp, os.path.join(args.shots, "3-after"))
    print(f"  shot AFTER: {after}")

    print("\n== 3. THE QUESTION: did the machine draw it pressed? ==")
    crop_census(during, screen, "during")
    got = diff_rect(before, during, screen)
    if got is None:
        return 1
    changed, moves = got
    area = (screen["r"] - screen["l"]) * (screen["b"] - screen["t"])
    print(f"\n  {changed} of {area} px inside the control changed between "
          f"BEFORE and DURING ({100.0 * changed / max(1, area):.1f}%)")
    for (p, q), n in sorted(moves.items(), key=lambda kv: -kv[1])[:10]:
        print(f"    #{p[0]:02X}{p[1]:02X}{p[2]:02X} → "
              f"#{q[0]:02X}{q[1]:02X}{q[2]:02X}   {n} px")

    if changed == 0:
        print("\n  FINDING: the control did not change while the button was "
              "held.\n  The application never drew a pressed state — it is "
              "not in a tracking\n  loop, so there is no guest-side pressed "
              "pixel to mirror. A host-side\n  pressed mark is then the "
              "HOST's own mark for the person's intent and\n  must not be "
              "presented as mirrored guest state.")
    else:
        print("\n  FINDING: the machine drew something. The colour moves "
              "above are the\n  measured Platinum pressed state for this "
              "control — use them, not a\n  darken filter.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
