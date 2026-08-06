#!/usr/bin/env python3
"""Stage the GWorld spike onto a booted guest, run it, pull its report.

    run-spike.py --anchor 1702 --bin /path/NowGWorld.bin

Uses the lab's anchor worker (the same route tools/stage-ext.py takes),
because the spike is an applet the rig launches by name and its result
is a file on the guest's Desktop.
"""
import argparse, os, sys, time

LAB = os.environ.get("NOW_LAB_ROOT", "/Users/michelle/Lab/Code/timbottu")
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--anchor", type=int, required=True)
ap.add_argument("--bin", required=True)
ap.add_argument("--dir", default="Macintosh HD:TimBotTu:now-dev")
ap.add_argument("--name", default="NOW GWorld")
ap.add_argument("--wait", type=float, default=25.0)
ap.add_argument("--out", default="gworld-report.txt")
a = ap.parse_args()

h = Harness(host="127.0.0.1", port=a.anchor, expect_backing={"worker"})
hello = h.request("hello", {})
print("anchor hello: machine %s" % hello.get("machineId"))

dest = "%s:%s" % (a.dir, a.name)
blob = open(a.bin, "rb").read()
print("pushing %d bytes -> %s" % (len(blob), dest))
try:
    h.push_stream(dest, blob, overwrite=True, pipeline=1)
except HarnessError as e:
    # The measured anchor quirk; the verify below still has to pass.
    if "-43" not in str(e):
        raise
    print("  (tolerated: %s)" % e)

st = h.request("stat", {"path": dest})
print("  staged: type=%s creator=%s data=%s rsrc=%s"
      % (st.get("type"), st.get("creator"), st.get("dataSize"),
         st.get("rsrcSize")))
if not st.get("exists") or (st.get("rsrcSize") or 0) <= 0:
    raise SystemExit("stage verify failed: %s" % st)

# The report from any previous run must not be mistaken for this one's.
report = "Macintosh HD:Desktop Folder:NOW GWorld Report.txt"
try:
    h.request("delete", {"path": report})
    print("  removed a previous report")
except HarnessError:
    pass

print("launching %s" % dest)
print(h.request("launch", {"path": dest}))
time.sleep(a.wait)

for attempt in range(6):
    try:
        mb = h.pull_file(report)
        data = getattr(mb, "data", None) or getattr(mb, "data_fork", b"")
        if not data:
            raise HarnessError("empty", "report file has no data fork")
        break
    except HarnessError as e:
        print("  report not there yet (%s)" % e)
        time.sleep(6)
else:
    raise SystemExit("the spike wrote no report; look at the screen")

text = data.decode("mac-roman", "replace").replace("\r", "\n")
open(a.out, "w").write(text)
print("=" * 60)
print(text)
print("=" * 60)
print("saved to %s" % a.out)
