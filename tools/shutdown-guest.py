#!/usr/bin/env python3
"""Ask an emulator guest to shut ITSELF down, and wait for it to go.

    tools/shutdown-guest.py <qmp.sock> --port <anchor> [--timeout 120]

WHY THIS IS NOT `tools/qmp <sock> quit`. QMP `quit` is a power cut. It
sets the volume's unclean bit, so the next boot is "Your computer did not
shut down properly" and a Disk First Aid pass - and `scripts/spin-up-ppc`
COLD-BOOTS for a living, because an INIT loads at boot and at no other
time. A rig that manufactures a dirty volume on every cycle spends its
time repairing the disk it is about to measure.

WHY IT IS NOT THE LAB'S `tools/shutdown-guest` EITHER. That one asks the
Finder through a guest agent's `script` verb. The lab's canonical anchor
worker - the one baked into the runner image every session clones - does
not have that verb, so it stops with "the agent refused the script verb"
and leaves the machine up. Measured 2026-08-05; its `hello` lists 24
tools and `script` is not among them.

HOW THIS ONE ASKS. A classic Mac shuts down from inside, so NOW stages a
small application that does nothing but call the Shutdown Manager
(tools/guest-shutdown, staged by tools/stage-ext.py) and this launches it
through the worker's `launch` verb. Every route that goes through the
human interface was tried first and is dead on this rig:

  * QMP keyboard events never arrive. mac99,via=pmu reports
    `has-adb=false`, so there is no ADB keyboard and no power key; neither
    `send-key` nor `input-send-event` moves a key in Key Caps.
  * QMP `abs` pointer events are refused outright - there is no absolute
    pointing device - and the `rel` ones that are accepted carry OS 9's
    pointer acceleration, so counted steps do not land where they aim.
  * The worker's own `click` verb closes a menu without selecting from it.

WHAT IT COSTS. The applet calls ShutDwnPower, which is what the Finder
itself ends up calling: shutdown procedures run, volumes are flushed and
unmounted, the power manager cuts power. It does NOT send quit
AppleEvents first - that part is the Finder's, and this skips it. So an
application holding unsaved work loses it. This politely quits the front
application first when it is not the Finder, which covers the ordinary
case, and it is still not a substitute for a person shutting a machine
down that somebody is using.

Exit 0 means QEMU exited, which only happens because the guest asked for
power off. Exit 1 means it did not, and the VM is left running and
untouched: deciding to kill an emulator that would not shut down is the
caller's business, not this file's.
"""
import argparse
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = os.path.abspath(os.path.join(HERE, ".."))

# The lab checkout owns the emulator and the anchor client; NOW owns the
# artifacts. Normally NOW's parent - but not from a git worktree, which
# sits several levels deeper and whose parent has no mcp-classic in it.
LAB = os.environ.get("NOW_LAB_ROOT")
if not LAB:
    LAB = NOW
    while LAB != "/" and not os.path.isdir(os.path.join(LAB, "mcp-classic")):
        LAB = os.path.dirname(LAB)
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError  # noqa: E402

DEV = os.environ.get("NOW_GUEST_DIR", "Macintosh HD:TimBotTu:now-dev")
APPLET = os.environ.get("NOW_SHUTDOWN_NAME", "NOW Shut Down")

# Cmd-Q as the front application sees it: virtual key 12 is 'q', and 256
# is cmdKey in the event record's modifiers. Measured working through the
# worker's `key` verb on 2026-08-05 - it is a posted event, which is why
# it reaches an application's menu handling while a posted CLICK cannot
# reach a menu's tracking loop.
CMD_Q = {"code": 12, "char": ord("q"), "mods": 256}


def qmp_alive(sock_path):
    """Is QEMU still answering? A dead socket IS the success signal.

    One connection per call and no reuse: the socket file is unlinked when
    QEMU exits, so a stale connection would keep reporting a machine that
    is gone."""
    if not os.path.exists(sock_path):
        return False
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(sock_path)
        f = s.makefile("rwb")
        f.readline()                                   # the greeting
        f.write(b'{"execute":"qmp_capabilities"}\n')
        f.flush()
        f.readline()
        f.write(b'{"execute":"query-status"}\n')
        f.flush()
        while True:
            line = f.readline()
            if not line:
                return False
            reply = json.loads(line)
            if "return" in reply:
                return True
            if "error" in reply:
                return False
    except (OSError, ValueError):
        return False
    finally:
        s.close()


def worker_answers(port):
    """Is anything on the guest still serving? The shutdown procedures quit
    every application, the baked worker included, so this going quiet is
    the machine reporting its own death.

    A fresh Harness per call for the same reason qmp_alive opens a fresh
    socket: a held connection reports the machine that WAS there."""
    try:
        Harness(host="127.0.0.1", port=port,
                expect_backing={"worker"}).request("hello", {})
        return True
    except Exception:
        return False


def wait_for_disk_quiet(sock_path, disk, settle=8.0, cap=120.0):
    """Block until the VM's disk image stops changing.

    The completion signal the worker cannot give (see the caller). Size
    and mtime together catch both a growing qcow2 and a rewrite in
    place. `settle` is how long unchanged counts as finished; `cap`
    stops a machine that never settles from blocking forever, and says
    so rather than pretending it settled.
    """
    if disk is None:
        disk = os.path.join(os.path.dirname(os.path.abspath(sock_path)),
                            "session.qcow2")
    if not os.path.exists(disk):
        return f"no disk at {disk} to watch, waited {settle:.0f}s blind"
    t0 = time.time()
    last = None
    steady_since = None
    while time.time() - t0 < cap:
        st = os.stat(disk)
        now = (st.st_size, st.st_mtime)
        if now != last:
            last, steady_since = now, time.time()
        elif time.time() - steady_since >= settle:
            return (f"disk quiet for {settle:.0f}s after "
                    f"{time.time() - t0:.0f}s")
        time.sleep(1.0)
    return (f"disk STILL being written {cap:.0f}s after the worker went "
            f"quiet - quitting anyway, and this image should be checked")


def quit_a_shut_down_machine(sock_path):
    """QMP `quit` on a guest that has ALREADY unmounted its volume.

    This is not the power cut rule 1 forbids, and the difference is the
    whole point. That rule is about quitting a RUNNING machine, which sets
    the unclean-volume bit and puts Disk First Aid in the next boot. Here
    the Shutdown Manager has already run its procedures, quit every
    application and unmounted the disk; QEMU is merely still resident
    because mac99's emulated power-off does not terminate the process.
    Measured 2026-08-05: quitting at exactly this point and cold-booting
    gave a clean boot in 156 s with no repair modal."""
    if not os.path.exists(sock_path):
        return
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(sock_path)
        f = s.makefile("rwb")
        f.readline()
        f.write(b'{"execute":"qmp_capabilities"}\n')
        f.flush()
        f.readline()
        f.write(b'{"execute":"quit"}\n')
        f.flush()
    except OSError:
        pass
    finally:
        s.close()


def front_process(h):
    for p in h.request("observe", {}).get("processes", []):
        if p.get("front"):
            return p
    return None


def quit_front_application(h):
    """Give whatever is in front a chance to save itself before the applet
    takes the machine down without asking. The Finder has no Quit, so it
    is left alone; anything else gets Cmd-Q and up to ten seconds."""
    front = front_process(h)
    if front is None or front.get("signature") == "MACS":
        return
    name = front.get("name")
    print(f"  quitting the front application ({name}) first")
    try:
        h.request("key", CMD_Q)
    except HarnessError as exc:
        print(f"  [warn] could not post Cmd-Q: {exc}")
        return
    deadline = time.time() + 10
    while time.time() < deadline:
        time.sleep(1)
        now_front = front_process(h)
        if now_front is None or now_front.get("signature") == "MACS":
            print("  the Finder is front again")
            return
    print(f"  [warn] {name} is still front; shutting down over it")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sock", help="the VM's qmp.sock")
    ap.add_argument("--port", type=int, required=True,
                    help="host port forwarded to the guest's anchor worker")
    ap.add_argument("--timeout", type=int, default=120,
                    help="seconds to wait for QEMU to exit (default 120)")
    ap.add_argument("--applet", default=f"{DEV}:{APPLET}",
                    help="HFS path of the staged shutdown applet")
    ap.add_argument("--disk", default=None,
                    help="the VM's disk image, watched for the writes that "
                         "outlast the worker; defaults to session.qcow2 "
                         "beside the qmp socket")
    a = ap.parse_args()

    if not qmp_alive(a.sock):
        print(f"nothing answering QMP at {a.sock}; no machine to shut down",
              file=sys.stderr)
        return 1

    h = Harness(host="127.0.0.1", port=a.port, expect_backing={"worker"})

    # Fail on a MISSING applet rather than on a launch that quietly did
    # nothing: "the file is not staged" and "the guest ignored us" are
    # different problems with different cures, and only one of them is
    # about this rig at all.
    st = h.request("stat", {"path": a.applet})
    if not st.get("exists"):
        print(f"no shutdown applet at {a.applet} - stage it first "
              f"(NOW_SHUTDOWN_BIN=... tools/stage-ext.py, built by "
              f"scripts/build-guests 68k)", file=sys.stderr)
        return 1

    quit_front_application(h)

    print(f"  launching {a.applet}")
    try:
        h.request("launch", {"path": a.applet})
    except HarnessError as exc:
        print(f"the worker would not launch the applet: {exc}", file=sys.stderr)
        return 1

    # WAIT FOR THE MACHINE, NOT FOR QEMU. This polled qmp_alive alone and
    # therefore always timed out: mac99's emulated power-off does not
    # terminate the process, so the guest shuts down perfectly and QEMU
    # sits there with a frozen last frame. Watched 2026-08-05 - the Finder
    # and the baked worker both gone, every application quit, and the
    # script still waiting for an exit that cannot come.
    #
    # The worker going quiet is the honest signal: it is an application,
    # the shutdown procedures quit it, and it was answering moments ago
    # (this function has already made two successful requests through it).
    t0 = time.time()
    while time.time() - t0 < a.timeout:
        if not qmp_alive(a.sock):
            print(f"guest shut itself down and QEMU exited "
                  f"({int(time.time() - t0)}s)")
            return 0
        if not worker_answers(a.port):
            # TWICE, and the second time is not caution for its own sake.
            # One silent poll can be a refused connect, a busy moment or a
            # timeout on a machine that is still perfectly alive — and the
            # action this signal authorises is a QMP quit, which on a live
            # machine IS the power cut rule 1 forbids. A transient must not
            # be able to reach that. The first clean run of this path
            # reported the worker silent on its very first poll (0 s after
            # the applet launched), which is plausible — the applet is a
            # 68K binary whose whole body is ShutDwnPower and the worker is
            # one of the applications it quits — but "plausible" is not the
            # standard for something that can corrupt a volume.
            time.sleep(3)
            if worker_answers(a.port):
                continue
            elapsed = int(time.time() - t0)
            # WAIT FOR THE DISK, NOT FOR THE WORKER. **The worker going
            # quiet means shutdown STARTED, not that it finished.** The
            # Shutdown Manager quits applications first and flushes and
            # unmounts volumes after, so the worker - an application - is
            # gone while the volume is still being written. A fixed five
            # second sleep here was not enough on 2026-08-06: two images
            # were preserved as the Mirror oracle with the volume still
            # marked mounted, and every clone of them opened with Disk
            # First Aid. `qemu-img check` passed both, because it
            # validates the container and cannot see the filesystem.
            #
            # So watch the disk instead: quit only once the image has
            # stopped changing. That is the machine telling us it has
            # finished, rather than us assuming from an application's
            # silence.
            quiesced = wait_for_disk_quiet(a.sock, a.disk)
            print(f"guest shut itself down ({elapsed}s); {quiesced}; QEMU "
                  f"is still resident because mac99 does not power off, so "
                  f"quitting the already-unmounted machine")
            quit_a_shut_down_machine(a.sock)
            deadline = time.time() + 30
            while time.time() < deadline and qmp_alive(a.sock):
                time.sleep(1)
            return 0
        time.sleep(2)

    print(f"guest still running {a.timeout}s after the applet was launched, "
          f"and its worker is still answering - so it did not shut down. "
          f"Left alone deliberately: look at a screendump before deciding "
          f"to quit it.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
