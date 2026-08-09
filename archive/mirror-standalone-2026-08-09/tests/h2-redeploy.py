#!/usr/bin/env python3
"""Redeploy the mirror agent onto an already-booted session VM.

The agent is an application, not an INIT, so it needs no cold reboot: quit it,
push the new binary through the anchor, launch it again. (Extensions DO need a
boot — if you changed one, use tools/spin-up.sh.)

The build stamp is checked after the relaunch. That check is the point: a
deploy that silently no-op'd and left the OLD agent serving is how a lane
measures a binary it did not build.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
MIRROR = HERE.parent
sys.path.insert(0, str(HERE))
from h2probe import agent_call, anchor, ports          # noqa: E402

ANCHOR_PORT, AGENT_PORT = ports()

before = agent_call("hello")["result"]["build"]
print("running build:", before)

try:
    agent_call("quit", tries=1, timeout=5)
except Exception as e:                                  # noqa: BLE001
    print("quit:", e)
time.sleep(3)

env = dict(os.environ, MIRROR_ANCHOR_PORT=str(ANCHOR_PORT))
r = subprocess.run([sys.executable, str(MIRROR / "tools/stage-agent.py")],
                   env=env, capture_output=True, text=True)
print(r.stdout[-800:], r.stderr[-800:])
# stage-agent.py also (re)writes mirror.port, and its `write` is not
# idempotent — on a re-stage it fails "exists: file exists". The port file is
# already correct on a booted session, so the agent push landing is the thing
# that matters; anything else is a real failure.
if r.returncode != 0 and "mirror-agent     type=APPL" not in r.stdout:
    r.check_returncode()

h = anchor()
h.request("launch", {"path": "Macintosh HD:TimBotTu:mirror-dev:mirror-agent"})
time.sleep(4)
after = agent_call("hello")["result"]["build"]
print("now serving build:", after)
if after == before:
    sys.exit("build stamp UNCHANGED — the deploy did not land")
