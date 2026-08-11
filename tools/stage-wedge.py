#!/usr/bin/env python3
"""Put the wedge applet on a running clone, under the three names that are
its three arguments.

    NOW_ANCHOR_PORT=1702 tools/stage-wedge.py spin 40

`tools/guest-wedge` is launched BY NAME and the name IS the argument
(`NOW Wedge spin 40` — mode and duration), so one binary is pushed once
per experiment under whatever name that experiment needs.

**Into `Macintosh HD:TimBotTu:now-dev`, and never the Desktop Folder.**
Launching from the Desktop Folder resets the anchor worker's connection,
which costs the observer the experiment is measured with — measured, and
the reason `tools/wedge-experiment.py`'s own path constant is now the
wrong one to copy.
"""

import os
import sys

sys.path.insert(0, os.environ.get(
    "NOW_LAB_MCP", os.path.expanduser("~/Lab/Code/timbottu/mcp-classic")))
from timbottu_mcp_classic.harness import Harness, HarnessError  # noqa: E402

ANCHOR = int(os.environ.get("NOW_ANCHOR_PORT", "1700"))
DEV = "Macintosh HD:TimBotTu:now-dev"
OUT = os.environ.get("NOW_BUILD_OUT", "")
WEDGE = os.environ.get("NOW_WEDGE_BIN", "")

mode = sys.argv[1] if len(sys.argv) > 1 else "spin"
seconds = sys.argv[2] if len(sys.argv) > 2 else "40"

if not WEDGE:
    if not OUT:
        raise SystemExit("set NOW_WEDGE_BIN or NOW_BUILD_OUT")
    WEDGE = f"{OUT}/wedge/NowWedge.bin"
if not os.path.exists(WEDGE):
    raise SystemExit(f"no wedge binary at {WEDGE} — run scripts/build-guests")

name = f"NOW Wedge {mode} {seconds}"
path = f"{DEV}:{name}"
blob = open(WEDGE, "rb").read()
h = Harness(host="127.0.0.1", port=ANCHOR, expect_backing={"worker"})
print(f"== stage {name} ==")
try:
    h.push_stream(path, blob, overwrite=True, pipeline=1)
except HarnessError as exc:
    # The measured anchor quirk, and only this string. The stat below is
    # what actually proves the bytes landed.
    if "catalog dates" not in f"{exc}":
        raise
    print(f"  [warn] {exc} (known anchor quirk; proving the bytes instead)")
st = h.request("stat", {"path": path})
if not st.get("exists") or int(st.get("rsrcSize") or 0) < 1024:
    raise SystemExit(f"{path} did not land: {st}")
print(f"  [OK ] {name}  type={st.get('type')} creator={st.get('creator')} "
      f"rsrc={st.get('rsrcSize')}")
print(f"launch it with: {path}")
