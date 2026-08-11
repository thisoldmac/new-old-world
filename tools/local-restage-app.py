#!/usr/bin/env python3
"""Put a freshly built guest app on an already-staged clone and relaunch it.

Scratch instrument. The INIT is resident after spin-up-ppc's cold boot and
this changes only the application, so a second cold boot buys nothing: quit
NOW with a posted Cmd-Q, push the new binary, launch it again.
"""

import argparse
import os
import subprocess
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--anchor", type=int, required=True)
ap.add_argument("--bin", required=True)
repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap.add_argument("--lab", default=os.environ.get(
    "NOW_LAB_ROOT", os.path.dirname(repo)))
ap.add_argument("--app", default="New Old World")
a = ap.parse_args()

sys.path.insert(0, f"{a.lab}/mcp-classic")
from timbottu_mcp_classic.harness import Harness  # noqa: E402

h = Harness(host="127.0.0.1", port=a.anchor, expect_backing={"worker"})
path = f"Macintosh HD:TimBotTu:now-dev:{a.app}"

front = [p for p in h.request("observe", {}).get("processes", [])
         if p.get("front")]
if front and front[0].get("name") == a.app:
    print(f"quitting {a.app}")
    h.request("key", {"code": 12, "char": ord("q"), "mods": 256})
    for _ in range(15):
        time.sleep(2)
        names = [p.get("name") for p in h.request("observe", {}).get(
            "processes", [])]
        if a.app not in names:
            break
    else:
        sys.exit(f"{a.app} would not quit; refusing to overwrite a running app")

try:
    h.push_stream(path, open(a.bin, "rb").read(), overwrite=True, pipeline=1)
except Exception as exc:               # the measured anchor quirk, only
    if "catalog dates" not in f"{exc}":
        raise
    print(f"  [warn] {exc} (known anchor quirk; the stat below is the proof)")
print("staged:", h.request("stat", {"path": path}))
h.request("launch", {"path": path})
print("launched")
