#!/usr/bin/env python3
"""Point an already-staged clone's guest at a DIFFERENT host port.

Scratch instrument. spin-up-ppc bakes the dialling book at stage time; when
another session turns out to be listening on the port this clone was given,
re-running the whole spin-up to move it costs a cold boot. This writes the
same minimal V1 record stage-ext.py writes, quits NOW with Cmd-Q, and
launches it again so it reads the new book.
"""

import argparse
import os
import struct
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--anchor", type=int, required=True)
ap.add_argument("--port", type=int, required=True)
repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap.add_argument("--lab", default=os.environ.get("NOW_LAB_ROOT",
                                                os.path.dirname(repo)))
ap.add_argument("--app", default="New Old World")
a = ap.parse_args()

sys.path.insert(0, f"{a.lab}/mcp-classic")
from timbottu_mcp_classic.harness import Harness  # noqa: E402


def macbinary(name, ftype, creator, data):
    def crc16(raw):
        crc = 0
        for byte in raw:
            crc ^= byte << 8
            for _ in range(8):
                crc = ((crc << 1) ^ 0x1021 if crc & 0x8000 else crc << 1) & 0xFFFF
        return crc
    hdr = bytearray(128)
    pname = name.encode("mac_roman")[:31]
    hdr[1] = len(pname)
    hdr[2:2 + len(pname)] = pname
    hdr[65:69] = ftype
    hdr[69:73] = creator
    struct.pack_into(">I", hdr, 83, len(data))
    hdr[122] = hdr[123] = 129
    struct.pack_into(">H", hdr, 124, crc16(bytes(hdr[:124])))
    return bytes(hdr) + data + b"\0" * ((-len(data)) % 128)


h = Harness(host="127.0.0.1", port=a.anchor, expect_backing={"worker"})
record = struct.pack(">4shH64s", b"NOWp", 1, a.port, b"10.0.2.2")
name = f"{a.app} Prefs"
path = f"Macintosh HD:System Folder:Preferences:{name}"

front = [p for p in h.request("observe", {}).get("processes", [])
         if p.get("front")]
if front and front[0].get("name") == a.app:
    print(f"quitting {a.app}")
    h.request("key", {"code": 12, "char": ord("q"), "mods": 256})
    time.sleep(8)

blob = macbinary(name, b"pref", b"NOWo", record)
h.push_stream(path, blob, overwrite=True, pipeline=1)
print("prefs written:", h.request("stat", {"path": path}))
h.request("launch", {"path": f"Macintosh HD:TimBotTu:now-dev:{a.app}"})
print(f"launched; the guest should now dial 10.0.2.2:{a.port}")
