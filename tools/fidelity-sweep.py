#!/usr/bin/env python3
"""Capture MANY guest windows in one run, each beside the machine's own
pixels, so the host render can be judged against what the Macintosh drew
rather than signed off on its own.

This is the promoted form of a one-app scratch script (`panel-recapture`,
2026-08-06): same phases, a target LIST instead of one argument, and the
two guardrails that scratch version had learned by hand written down —

  * WHO ANSWERED. Every QEMU guest on this Mac sees the host as
    10.0.2.2, so any session's VM running any branch's build can dial
    this listener. `--expect-build auto` reads the hash out of THIS
    checkout's build products and refuses a foreign guest, exactly as
    tools/gwprobe.py does. Never type the hash.
  * THE SCENE WALK GOES STALE. Over a long session foreign windows stop
    coming back with addresses, and a target that cannot be found is
    reported as SKIPPED with the window list, not silently dropped — a
    sweep whose misses look like absences is a sweep that invents
    findings. `--max-targets` is the companion: re-boot every handful of
    targets rather than chaining a whole sweep on one boot.

Each target produces three files under --outdir:

    <label>.json        the drain, in FIXTURE shape (drop into
                        now-host/Tests/HostTests/Fixtures/ as
                        qdtrace-drain-<label>.json) with `provenance`
    <label>-scene.json  the scene the window address came from
    <label>-guest.ppm   QMP screendump, taken WHILE the window is front

Usage:

    tools/fidelity-sweep.py --port 5361 --qmp /private/tmp/nowvm-x/qmp.sock \\
        --anchor 1760 --vm nowvm-x --expect-build auto \\
        --outdir /private/tmp/sweep \\
        --target "Calculator" \\
        --target "Note Pad" \\
        --target "Date & Time=Macintosh HD:System Folder:Control Panels:Date & Time"

A target is `AppName` (already running, or launchable by name through the
anchor) or `AppName=Full:HFS:Path`. `AppName=-` fronts without launching,
which is how the Finder is captured.
"""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gwprobe  # noqa: E402
from sweeplimits import write_limits  # noqa: E402


# Stated in the artifacts, not only in whatever report a human writes
# afterwards. See tools/sweeplimits.py for why.
LIMITS = {
    "settled-capture-only": (
        "This tool renders a SETTLED capture. It never draws two "
        "consecutive live frames, so a STABILITY score derived from it "
        "means 'two independent captures composed to identical pixels' "
        "and says NOTHING about whether the live window flickers. "
        "tools/fidelity-live.py is the instrument for that."),
    "three-phases-not-one-instant": (
        "The agent surface, the host render and the guest pixels are "
        "not one instant. The sweep tool and the host app both bind the "
        "wire port the guest dials, so they cannot run together; a full "
        "sweep is capture pass, live agent-surface phase, capture pass, "
        "on one boot. Views 2 and 3 are simultaneous; view 1 is not."),
    "emulator-not-metal": (
        "Emulated mac99/OS 9 unless the run says otherwise. Nothing here "
        "is metal-verified."),
    "who-answered": (
        "--expect-build refuses a guest whose hello build does not match "
        "this checkout. A run without it is void, not annotated: every "
        "QEMU guest on this Mac dials 10.0.2.2."),
}


def read_expected_build(repo):
    """The build hash, READ from this checkout's products rather than
    typed — the same derivation scripts/build-guests uses."""
    out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "now-guest-builds",
                       hashlib.sha1(repo.encode()).hexdigest()[:12])
    gen = os.path.join(out, "ppc", "build_stamp_gen.h")
    with open(gen) as handle:
        for line in handle:
            if "NOW_SRC_HASH" in line:
                return line.split('"')[1]
    raise SystemExit("no NOW_SRC_HASH in %s — run scripts/build-guests" % gen)


def screendump(qmp_path, out_path):
    """QMP OBSERVES. It never drives this guest: mac99 has no ADB
    keyboard, and a posted click cannot select from a menu."""
    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(20)
        sock.connect(qmp_path)
        sock.recv(65536)
        sock.sendall(b'{"execute":"qmp_capabilities"}\n')
        time.sleep(0.4)
        sock.recv(65536)
        sock.sendall((json.dumps({"execute": "screendump",
                                  "arguments": {"filename": out_path}})
                      + "\n").encode())
        time.sleep(2.0)
        sock.recv(65536)
        sock.close()
        return os.path.exists(out_path)
    except Exception as exc:                                # noqa: BLE001
        print("  screendump failed: %s" % exc, flush=True)
        return False


class Sweep:
    def __init__(self, args):
        self.args = args
        expect = args.expect_build
        if expect == "auto":
            repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            expect = read_expected_build(repo)
            print("expecting build %s" % expect, flush=True)
        self.expect = expect
        self.guest = gwprobe.Guest(args.port, wait=args.wait,
                                   expect_build=expect)
        self.harness = None
        if args.anchor:
            lab = os.environ.get("NOW_LAB_ROOT",
                                 "/Users/michelle/Lab/Code/timbottu")
            sys.path.insert(0, os.path.join(lab, "mcp-classic"))
            from timbottu_mcp_classic.harness import Harness
            self.harness = Harness(host="127.0.0.1", port=args.anchor,
                                   expect_backing={"worker"})
            print("anchor: %s"
                  % self.harness.request("hello", {}).get("machineId"),
                  flush=True)

    def find_window(self, app, attempts=6):
        """Poll for a window carrying an ADDRESS. The first scene of a
        fresh connection can miss foreign processes: the scene claims the
        planes and the resident echoes on its next pass."""
        scene = None
        for _ in range(attempts):
            scene = self.guest.scene()
            best = None
            for win in scene.get("windows", []):
                if (win.get("app", "").lower() == app.lower()
                        and win.get("addr")):
                    if win.get("front") or best is None:
                        best = win
            if best is not None:
                return best, scene
            time.sleep(4)
        return None, scene

    def act(self, spec):
        """verb[:k=v,...] issued at the guest. `k` is int where it parses
        as one, because `menuact` wants numbers and `front` wants names
        and the spec cannot tell them apart on its own."""
        name, _, rest = spec.partition(":")
        args = {}
        for pair in filter(None, rest.split(",")):
            key, _, value = pair.partition("=")
            try:
                args[key] = int(value)
            except ValueError:
                args[key] = value
        reply = self.guest.command(name, args)
        print("  act %s -> %s" % (name, json.dumps(reply)[:200]), flush=True)
        return reply

    def capture(self, label, app, path):
        print("\n=== %s (%s) ===" % (label, app), flush=True)
        if self.args.reveal:
            # A reveal opens the enclosing window AND SELECTS the item,
            # which is the cheapest way to get a selected row into a
            # capture. Selection is drawn by INVERT on this machine, and
            # a corpus with no selection in it cannot show a fix to
            # invert working.
            self.act("reveal:target=%s" % self.args.reveal)
            time.sleep(5)
        if path and path != "-":
            if self.harness is not None:
                print("  launch: %s"
                      % self.harness.request("launch", {"path": path}),
                      flush=True)
            else:
                print("  launch: %s"
                      % json.dumps(self.guest.command(
                          "launch", {"target": path}))[:200], flush=True)
            time.sleep(self.args.launch_settle)
        self.guest.command("front", {"target": app})
        time.sleep(4)

        target, scene = self.find_window(app)
        if target is None:
            seen = [(w.get("app"), w.get("title")) for w in
                    (scene or {}).get("windows", [])]
            print("  SKIPPED: no %r window with an address; scene had %s"
                  % (app, seen), flush=True)
            return {"label": label, "app": app, "status": "no-window",
                    "windows": seen}
        addr = int(target["addr"])
        psn = target.get("psn", "0.0")
        print("  target %r addr 0x%08x psn %s rect %s"
              % (target.get("title"), addr, psn, target.get("rect")),
              flush=True)
        with open(os.path.join(self.args.outdir,
                               "%s-scene.json" % label), "w") as handle:
            json.dump(scene, handle, indent=1)

        hi, lo = (psn.split(".") + ["0"])[:2]
        floor = self.guest.command("qdtrace", {"op": "status"})
        cursor = (floor.get("output", {}).get("qdtrace", {})
                  .get("ring", {}).get("writeCursor", 0))
        started = self.guest.command("qdtrace", {
            "op": "start", "window": "0x%08x" % addr, "mode": "record",
            "ttlTicks": self.args.ttl,
            "serialHi": int(hi), "serialLo": int(lo)})
        if not started.get("ok"):
            print("  SKIPPED: qdtrace refused: %s"
                  % json.dumps(started)[:300], flush=True)
            return {"label": label, "app": app, "status": "arm-refused",
                    "reply": started}
        time.sleep(4)

        # Anything that puts the window into a NON-RESTING state goes
        # here, after the arm, so the transition itself is recorded.
        for spec in self.args.after:
            self.act(spec)
            time.sleep(3)
        for char in self.args.type_text or "":
            self.guest.command("key", {"char": ord(char)})
            time.sleep(0.3)

        records = []

        def pump(seconds):
            """Drain CONTINUOUSLY while the repaints happen. A source
            that draws faster than the ring holds laps the arm-time
            cursor, and a single drain afterwards resyncs to live and
            answers empty (measured 2026-08-06: 0 records against 915
            recorded ops)."""
            nonlocal cursor
            end = time.time() + seconds
            while time.time() < end:
                reply = self.guest.command(
                    "qdtrace", {"op": "drain", "cursor": str(cursor),
                                "maxRecords": 400})
                out = reply.get("output", {}).get("qdtrace", {})
                records.extend(out.get("ops", []))
                cursor = out.get("nextCursor", cursor)
                if not out.get("more"):
                    time.sleep(0.2)

        # Repaints are driven by FRONTING, not by resizing: a resize
        # reflows the window and the render then disagrees with the
        # screendump about a layout neither side got wrong.
        for _ in range(self.args.repaints):
            self.guest.command("front", {"target": "New Old World"})
            pump(3)
            self.guest.command("front", {"target": app})
            pump(5)

        # A FRONT/BACK CYCLE IS NOT ALWAYS AN INVALIDATION, and a sweep
        # that assumes it is reports a window the guest drew perfectly
        # as an empty capture. Monitors did exactly that on 2026-08-06:
        # fully drawn on the screendump, entirely inside NOW's window,
        # 0 records. Occluding a window does not oblige Mac OS to send
        # its application an update event.
        #
        # So when the cycle yields nothing, hide the application and
        # reveal it — that removes the window from the list and forces
        # a real update on return — and RECORD that the repaint was
        # escalated, because a capture obtained by a stronger poke is
        # evidence about a different moment than the others.
        forced = False
        if not records and self.args.force_repaint:
            print("  0 records from front/back — escalating to hide/reveal",
                  flush=True)
            self.guest.command("hide", {"target": app})
            pump(3)
            self.guest.command("reveal", {"target": app})
            pump(6)
            self.guest.command("front", {"target": app})
            pump(6)
            forced = True

        shot = os.path.join(self.args.outdir, "%s-guest.ppm" % label)
        got_shot = screendump(self.args.qmp, shot) if self.args.qmp else False
        status = (self.guest.command("qdtrace", {"op": "status"})
                  .get("output", {}).get("qdtrace", {}))
        pump(4)
        self.guest.command("qdtrace", {"op": "stop"})

        mix = {}
        for rec in records:
            mix.setdefault(rec.get("port"), {}).setdefault(rec.get("op"), 0)
            mix[rec["port"]][rec["op"]] += 1
        texts = sorted({r.get("text") for r in records
                        if r.get("op") == "text" and r.get("text")})
        print("  %d records, ports %s" % (len(records), json.dumps(mix)),
              flush=True)
        print("  %d distinct strings" % len(texts), flush=True)

        # FIXTURE SHAPE, so this drops straight into Fixtures/ and the
        # coverage test's decoder accepts it. `records` must agree with
        # len(ops) or NOWMirrorContentPlane refuses the drain.
        fixture = {
            "cmd": "drain", "ops": records, "cursor": 0,
            "nextCursor": cursor, "writeCursor": cursor, "pending": 0,
            "records": len(records), "wraps": 0, "more": False,
            "resync": False, "torn": False, "busy": False,
            "lostBytes": 0, "dropped": 0,
            "provenance": {
                "build": self.expect or "unverified",
                "vm": self.args.vm,
                "run": "fidelity-sweep %s (record mode, worlds hooked "
                       "at birth%s)" % (label,
                                        "; repaint forced by hide/reveal"
                                        if forced else ""),
                "capturedAt": self.args.date,
                "guest": "mac99/OS 9.1 emulated",
            },
        }
        # `indent=1` here once cost 700,000 lines of git history: a
        # 3,500-op capture spent ~17 lines saying what fits on one.
        # tools/fixture-store owns the house format so there is one
        # place that decides it; this writes and then normalises.
        out = os.path.join(self.args.outdir, "%s.json" % label)
        with open(out, "w") as handle:
            json.dump(fixture, handle, indent=1)
        subprocess.call([os.path.join(os.path.dirname(
            os.path.abspath(__file__)), "fixture-store"),
            "compact", "--apply", self.args.outdir])
        return {"label": label, "app": app, "status": "ok",
                "window": "0x%08x" % addr, "psn": psn,
                "title": target.get("title"), "rect": target.get("rect"),
                "records": len(records), "perPort": mix,
                "forcedRepaint": forced,
                "texts": texts, "screendump": got_shot,
                "qdext": status.get("qdext")}

    # ---- state hygiene -------------------------------------------------
    #
    # Sweep A (2026-08-07) VOIDED Date & Time's whole stability row: pass
    # 1 left the panel's own "Set Time Zone" modal open, pass 2 measured a
    # different world, and the two renders were of two different machines.
    # The dialog then stayed up for the rest of the run and contaminated
    # every later health check. `--quit-after` did not close it, because
    # asking an application to quit while it holds a modal does nothing.
    #
    # So: fingerprint the world before a target, try to put it back
    # after, and when it cannot be put back SAY SO on both rows — the
    # target that made the mess and the target that inherited it. A row
    # measured in a world the sweep does not recognise is not a lower
    # score, it is not a measurement.

    def world(self):
        """The set of windows and processes, as a comparable fingerprint.
        Titles are included because a modal is often the only window its
        application ever opens, so counting windows alone misses it."""
        try:
            scene = self.guest.scene()
        except Exception as exc:                            # noqa: BLE001
            return {"failed": str(exc)}
        wins = []
        for win in scene.get("windows", []):
            wins.append({"app": win.get("app"), "title": win.get("title"),
                         "kind": win.get("kind"), "ref": win.get("ref"),
                         "addr": win.get("addr")})
        return {"windows": wins,
                "processes": sorted(p.get("name") for p in
                                    scene.get("processes", []) if p.get("name"))}

    @staticmethod
    def _win_key(win):
        return (win.get("app"), win.get("title"), win.get("kind"))

    def _dismiss(self, win):
        """Try to close ONE window, cheapest route first. A modal is a
        dialog before it is a window: `ditemact` on its cancel item is
        the route that worked in sweep A (7.6 s on the Mail modal), and
        `winact close` is what a document window answers."""
        attempts = []
        ref = win.get("ref")
        kind = win.get("kind")
        if kind in (1, 2, 3):
            # Dialog Manager items 1 and 2 are OK and Cancel by
            # convention. Cancel FIRST: a sweep must never press the
            # button that commits a control panel's change.
            for item in (2, 1):
                if not ref:
                    break
                reply = self.guest.command("ditemact", {"element": ref,
                                                        "item": item})
                attempts.append(("ditemact:%d" % item, bool(reply.get("ok"))))
                if reply.get("ok"):
                    time.sleep(2)
                    return attempts
            reply = self.guest.command("key", {"char": 27})     # Escape
            attempts.append(("key:esc", bool(reply.get("ok"))))
            time.sleep(2)
            return attempts
        if ref:
            reply = self.guest.command("winact", {"window": ref,
                                                  "action": "close"})
            attempts.append(("winact:close", bool(reply.get("ok"))))
            time.sleep(2)
        return attempts

    def tidy(self, label, before, app=None, quit_app=False):
        """Return the world to `before`, and report honestly when it
        cannot be. The return value is attached to the target's own row
        AND, when it is not clean, to the next target's row."""
        report = {"target": label, "clean": None, "dismissed": [],
                  "residue": [], "attempts": []}
        if "windows" not in before:
            report["clean"] = False
            report["residue"] = [{"note": "no baseline world for this target"}]
            return report

        baseline = {self._win_key(w) for w in before["windows"]}
        for _ in range(3):
            now = self.world()
            if "windows" not in now:
                report["clean"] = False
                report["residue"] = [{"sceneFailed": now.get("failed")}]
                return report
            extra = [w for w in now["windows"]
                     if self._win_key(w) not in baseline]
            if not extra:
                break
            for win in extra:
                report["attempts"].append(
                    {"window": self._win_key(win),
                     "tried": self._dismiss(win)})
                report["dismissed"].append(self._win_key(win))
        # Quitting comes AFTER the windows are gone: an application
        # holding a modal ignores a quit, which is exactly how sweep A's
        # --quit-after read as success while leaving the dialog up.
        if quit_app and app:
            try:
                self.guest.command("quit", {"target": app})
                time.sleep(3)
            except Exception:                               # noqa: BLE001
                pass

        now = self.world()
        if "windows" not in now:
            report["clean"] = False
            report["residue"] = [{"sceneFailed": now.get("failed")}]
            return report
        residue = [w for w in now["windows"]
                   if self._win_key(w) not in baseline]
        report["residue"] = [self._win_key(w) for w in residue]
        report["clean"] = not residue
        if residue:
            print("  !! DIRTY EXIT after %s: %s — the next target is "
                  "measured in a world this sweep did not set up and its "
                  "row is marked contaminated"
                  % (label, json.dumps(report["residue"])), flush=True)
        return report

    def health(self):
        """A crashed application shows a dialog and reports nothing; a
        run's own counters read green through exactly that. So every
        sweep ends by asking the machine what windows exist."""
        try:
            post = self.guest.scene()
        except Exception as exc:                            # noqa: BLE001
            return [{"sceneFailed": str(exc)}]
        alerts = []
        for win in post.get("windows", []):
            title = (win.get("title") or "").lower()
            if win.get("kind") in (1, 2, 3) or "error" in title:
                alerts.append({"app": win.get("app"),
                               "title": win.get("title"),
                               "kind": win.get("kind")})
        if "Finder" not in [p.get("name") for p in post.get("processes", [])]:
            alerts.append({"gone": "Finder"})
        return alerts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True,
                        help="wire port this listens on (the guest dials it)")
    parser.add_argument("--qmp", help="QMP socket, for the screendumps")
    parser.add_argument("--anchor", type=int,
                        help="anchor worker port, for launching by HFS path")
    parser.add_argument("--vm", default="unknown",
                        help="VM run name, recorded in every provenance")
    parser.add_argument("--date", default=time.strftime("%Y-%m-%d"))
    parser.add_argument("--expect-build", default="auto",
                        help="refuse a guest whose hello build does not "
                             "match; 'auto' reads it from this checkout")
    parser.add_argument("--target", action="append", default=[],
                        help="Label/App, or App=HFS:path, or App=- to front "
                             "only. Repeatable.")
    parser.add_argument("--max-targets", type=int, default=0,
                        help="stop after N (the scene walk goes stale; "
                             "re-boot rather than chaining a long sweep)")
    parser.add_argument("--repaints", type=int, default=3)
    parser.add_argument("--force-repaint", action="store_true",
                        help="when the front/back cycle records nothing, "
                             "escalate to hide/reveal and say so in the "
                             "provenance")
    parser.add_argument("--launch-settle", type=float, default=10.0)
    parser.add_argument("--ttl", type=int, default=7200)
    parser.add_argument("--wait", type=int, default=180)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--reveal",
                        help="reveal this HFS path first: it opens the "
                             "enclosing Finder window AND selects the item, "
                             "which is how a SELECTED row gets into a "
                             "capture at all")
    parser.add_argument("--after", action="append", default=[],
                        help="verb[:k=v,...] issued AFTER arming, so the "
                             "transition into a non-resting state is "
                             "recorded. Repeatable.")
    parser.add_argument("--type", dest="type_text",
                        help="after arming, post these characters to the "
                             "front window — a caret and selected text are "
                             "drawn by invert and nothing in the corpus "
                             "has either")
    parser.add_argument("--no-hygiene", dest="hygiene", action="store_false",
                        default=True,
                        help="do NOT return the world to its pre-target "
                             "state between targets. Sweep A voided a row "
                             "this way; only pass this to reproduce that.")
    parser.add_argument("--quit-after", action="store_true",
                        help="ask each app to quit once captured, so a long "
                             "sweep does not exhaust the guest's heap")
    args = parser.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    sweep = Sweep(args)
    results = []
    contaminated_by = None
    for spec in args.target:
        if args.max_targets and len(results) >= args.max_targets:
            print("stopping at --max-targets", flush=True)
            break
        app, _, path = spec.partition("=")
        label = app.lower().replace(" ", "-").replace("&", "and")
        before = sweep.world() if args.hygiene else None
        try:
            result = sweep.capture(label, app, path or None)
        except Exception as exc:                            # noqa: BLE001
            print("  FAILED: %s" % exc, flush=True)
            result = {"label": label, "app": app,
                      "status": "error", "error": str(exc)}
        if contaminated_by:
            # Named on the row that INHERITED the mess, not only on the
            # row that made it: sweep A's void was discovered by reading
            # a screendump, which is not a property an instrument should
            # rely on a human noticing.
            result["contaminatedBy"] = contaminated_by
            result["contaminationNote"] = (
                "measured in a world %s left dirty; scores on this row "
                "are not comparable across passes" % contaminated_by)
        results.append(result)
        if args.hygiene:
            tidy = sweep.tidy(label, before, app=app,
                              quit_app=bool(args.quit_after and path
                                            and path != "-"))
            result["hygiene"] = tidy
            contaminated_by = None if tidy.get("clean") else label
        elif args.quit_after and path and path != "-":
            try:
                sweep.guest.command("quit", {"target": app})
                time.sleep(3)
            except Exception:                               # noqa: BLE001
                pass

    alerts = sweep.health()
    if alerts:
        print("\n!! POST-RUN HEALTH: %s" % json.dumps(alerts), flush=True)
    summary = {"vm": args.vm, "build": sweep.expect, "date": args.date,
               "results": results, "postRunAlerts": alerts,
               "limits": LIMITS, "hygiene": bool(args.hygiene)}
    with open(os.path.join(args.outdir, "sweep-summary.json"), "w") as handle:
        json.dump(summary, handle, indent=1)
    write_limits(args.outdir, "fidelity-sweep", LIMITS)
    print("\n%s" % json.dumps(
        [{k: r.get(k) for k in ("label", "status", "records", "window")}
         for r in results], indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
