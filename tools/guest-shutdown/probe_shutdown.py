"""Bench: drive one shutdown route on an ALREADY-BOOTED guest and watch.

Not a gate. This is the instrument used on 2026-08-06 to find a route
that actually leaves the volume unmounted, kept because the next person
asking "why not just X" should be able to re-run X in two minutes.

    probe_shutdown.py <wire-port> <run-dir> finder|applet|<x-command>

It listens for the guest, runs the route, and then reports every 10s:
whether QEMU is still resident, and a screendump so the machine's own
screen is the evidence rather than an exit code.
"""
import json, os, socket, struct, subprocess, sys, time

WIRE = int(sys.argv[1])
RUN = sys.argv[2]
ROUTE = sys.argv[3]
QMPUI = os.path.join(RUN, "qmp-ui.sock")
PIDF = os.path.join(RUN, "qemu.pid")


def frame(p):
    return struct.pack(">BBHI", 0, 1, 0, len(p)) + p


def shot(tag):
    out = f"/private/tmp/probe-{tag}.ppm"
    s = socket.socket(socket.AF_UNIX)
    s.connect(QMPUI)
    f = s.makefile("rwb")

    def rd():
        while True:
            line = f.readline()
            if not line:
                return None
            m = json.loads(line)
            if "event" not in m:
                return m
    rd()
    f.write(b'{"execute":"qmp_capabilities"}\n')
    f.flush()
    rd()
    f.write(json.dumps({"execute": "screendump",
                        "arguments": {"filename": out}}).encode() + b"\n")
    f.flush()
    rd()
    s.close()
    subprocess.run(["sips", "-s", "format", "png", out, "--out",
                    out.replace(".ppm", ".png")],
                   capture_output=True)
    return out.replace(".ppm", ".png")


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", WIRE))
srv.listen(1)
srv.settimeout(300)
print(f"listening on {WIRE}", flush=True)
c, _ = srv.accept()
c.settimeout(90)
buf = b""


def rf():
    global buf
    while True:
        if len(buf) >= 8:
            ch, fl, t, n = struct.unpack(">BBHI", buf[:8])
            if len(buf) >= 8 + n:
                p, buf = buf[8:8 + n], buf[8 + n:]
                return ch, p
        d = c.recv(65536)
        if not d:
            raise EOFError
        buf += d


_, p = rf()
print("guest:", json.loads(p).get("build"), flush=True)
c.sendall(frame(json.dumps({"type": "hello", "contract": 1, "side": "host",
                            "version": "0.0", "name": "probe"}).encode()))
rid = 900


def cmd(name, args=None, wait=True, timeout=60):
    global rid
    rid += 1
    m = {"type": "command.request", "id": rid, "name": name}
    if args:
        m["args"] = args
    c.sendall(frame(json.dumps(m).encode()))
    if not wait:
        return None
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            ch, p = rf()
        except (socket.timeout, EOFError):
            return {"note": "no reply — the machine may be going down"}
        if ch == 0:
            r = json.loads(p.decode("utf-8", "replace"))
            if r.get("id") == rid:
                return r
    return {"note": "timed out"}


def scene():
    global rid
    rid += 1
    c.sendall(frame(json.dumps({"type": "scene.request", "id": rid}).encode()))
    doc = b""
    while True:
        ch, p = rf()
        if ch == 0 and json.loads(
                p.decode("utf-8", "replace")).get("type") == "scene.end":
            break
        if ch == 1:
            doc += p
    return json.loads(doc.decode("utf-8", "replace"))


if ROUTE == "finder":
    print("front Finder:", cmd("front", {"target": "Finder"}), flush=True)
    time.sleep(3)
    scene()
    time.sleep(3)
    s = scene()
    mb = s.get("menubar") or {}
    print("menubar app:", mb.get("app"), flush=True)
    sp = next((m for m in mb.get("menus", [])
               if (m.get("title") or "").strip().lower() == "special"), None)
    it = next((i for i in sp.get("items", [])
               if "shut down" in (i.get("title") or "").lower()), None)
    # serialHi/serialLo are REQUIRED by menuact and are not optional in
    # practice: a menu bar belongs to one exact process, and without the
    # serial the guest refuses with `bad-request` rather than guessing.
    # A probe that sent the act fire-and-forget got that refusal and threw
    # it away, then reported "the Finder cannot be shut down this way" —
    # which was never established. The scene hands the number over.
    fp = next(p for p in s.get("processes", []) if p.get("front"))
    hi, lo = (int(x) for x in fp["psn"].split("."))
    print(f"Special id={sp.get('id')} item={it.get('index')} "
          f"{it.get('title')!r}; front {fp['name']} psn {hi}.{lo}", flush=True)
    print("menuact REPLY:", cmd("menuact",
                                {"menu": sp.get("id"), "item": it.get("index"),
                                 "titleLeft": sp.get("left"),
                                 "serialHi": hi, "serialLo": lo}, timeout=45),
          flush=True)
else:
    print(f"{ROUTE} REPLY:", cmd(ROUTE, timeout=45), flush=True)

pid = int(open(PIDF).read().strip())
t0 = time.time()
while time.time() - t0 < 240:
    time.sleep(10)
    try:
        os.kill(pid, 0)
        alive = True
    except ProcessLookupError:
        alive = False
    el = int(time.time() - t0)
    if not alive:
        print(f"+{el}s QEMU EXITED ON ITS OWN — real power-off", flush=True)
        sys.exit(0)
    print(f"+{el}s QEMU still resident; {shot(f'{ROUTE}-{el}')}", flush=True)
print("QEMU never exited.", flush=True)
sys.exit(1)
