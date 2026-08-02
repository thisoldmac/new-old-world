#!/usr/bin/env python3
"""A staged Mirror agent must be told which port to serve.

Mirror's agent reads a text file called `mirror.port` sitting beside it,
once, at launch (`mirror/guest/app/src/main.c :: read_port`, reached
through `set_dir_to_app`). On 2026-08-02 a guest kept the base image's
own copy of that file, so a freshly staged agent bound a stale port: the
process existed, NOW's Mirror page said "Running", and every connection
from a host Mirror hit a QEMU forward with nothing behind it and was
reset. Nothing about that failure looked like a staging failure.

So `tools/stage-ext.py`'s optional Mirror bundle WRITES the file rather
than inheriting whatever the image had. This gates that it still does.

None of `tools/stage-ext.py` can run here - it opens a socket to a live
anchor worker the moment it is imported - so what is legible from here is
its source text, the same reasoning `pump_staging_source_test.py` gives
for gating a staging script this way.

Six checks:

  1. The bundle is OPTIONAL and named: `NOW_STAGE_MIRROR` gates it and
     `NOW_MIRROR_DIR` says where Mirror is. A bundle that installed three
     resident INITs on every guest by default would be this script
     deciding what a machine is for.
  2. `mirror.port` is written by name. Not implied, not left to Mirror's
     own stager, which this script does not call.
  3. It is written with `overwrite` true. Mirror's tools/stage-agent.py
     already paid for this one: the base image carries a mirror.port, so
     without overwrite every fresh clone dies on that single line AFTER
     all the pushes have succeeded, which reads exactly like a deploy
     failure and is not one.
  4. It is written with `truncate` true. A shorter port written over a
     longer one otherwise leaves the tail of the old number behind, and
     `14200` is a port a person reads straight past.
  5. It is VERIFIED off the guest as a TEXT file with a data fork, not
     believed because the write returned - the rule the whole script is
     built on. A `mirror.port` with an empty data fork names nothing.
  6. All three of Mirror's INITs are staged and verified by RESOURCE fork
     size, because that is where an INIT's code lives; NOW's Mirror page
     reports on them and they load at boot only.

MUTATION WATCH: change `"overwrite": True` to `"overwrite": False` in
`write_verified` and check 3 must fail by name; delete the
`want_type="TEXT"` argument from the mirror.port call and check 5 must
fail by name.

Run with: python3 mirror_port_staging_source_test.py
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "stage-ext.py"

failures = []


def check(ok: bool, what: str) -> None:
    if not ok:
        failures.append(what)


text = SRC.read_text()

# 1. Optional, and gated by name. Both variables, because the gate without
#    a way to point at a checkout is a gate nobody outside this tree can
#    pass.
check(re.search(r'STAGE_MIRROR\s*=\s*os\.environ\.get\(\s*"NOW_STAGE_MIRROR"',
                text) is not None,
      "stage-ext.py no longer reads NOW_STAGE_MIRROR - the Mirror bundle "
      "is either gone or no longer optional, and three resident INITs is "
      "not a thing to install on every guest by default")
check(re.search(r'MIRROR_DIR\s*=\s*os\.environ\.get\(\s*"NOW_MIRROR_DIR"',
                text) is not None,
      "stage-ext.py no longer reads NOW_MIRROR_DIR, so the bundle can "
      "only ever stage one checkout's build")
check(re.search(r"if STAGE_MIRROR\s*:", text) is not None,
      "the Mirror bundle is no longer behind `if STAGE_MIRROR:` - it "
      "would run on every guest")

# 2-4. mirror.port is written, over whatever was there, at length zero
#      first. The write call is found once and all three properties are
#      read off the same call: a test that found `overwrite` anywhere in
#      the file would pass on the app's push_stream and prove nothing
#      about this file.
write_call = re.search(
    r'h\.request\(\s*"write"\s*,\s*\{(.{0,400}?)\}\s*\)', text, re.DOTALL)
check(write_call is not None,
      "no h.request(\"write\", ...) call remains - mirror.port is not "
      "being written at all, so a staged agent inherits whatever port "
      "the base image named")
if write_call:
    args = write_call.group(1)
    check(re.search(r'"overwrite"\s*:\s*True', args) is not None,
          "mirror.port is written without overwrite - every clone of an "
          "image that already carries one dies on this line AFTER all "
          "the pushes succeeded, which reads like a deploy failure")
    check(re.search(r'"truncate"\s*:\s*True', args) is not None,
          "mirror.port is written without truncate - a shorter port "
          "written over a longer one leaves the old number's tail behind")

check('mirror.port' in text,
      "stage-ext.py no longer names mirror.port anywhere")
port_write = re.search(
    r'write_verified\(\s*f"\{MIRROR_DEV\}:mirror\.port"', text)
check(port_write is not None,
      "mirror.port is not staged into the agent's own folder under "
      "MIRROR_DEV - the agent resolves it beside ITSELF and nowhere else")

# 5. Verified off the guest, not believed. TEXT because that is what the
#    agent's fopen expects to find, and a data fork because the number is
#    the entire file.
port_verify = re.search(
    r'write_verified\(f"\{MIRROR_DEV\}:mirror\.port".{0,200}?'
    r'want_type="TEXT".{0,80}?min_data=', text, re.DOTALL)
check(port_verify is not None,
      "the mirror.port write is not verified as a TEXT file with a "
      "non-empty data fork - a file that landed empty names no port, and "
      "the write returning is not evidence it did not")

# 6. The three residents, by resource fork. NOW's Mirror page reports on
#    exactly these three and they load at boot only, so a bundle that
#    stages the agent alone produces a page with three "Not loaded" rows
#    and no explanation.
for name in ("AXPeek", "QDPeek", "Portal"):
    check(name in text,
          f"the Mirror bundle no longer stages {name}, which NOW's Mirror "
          f"page reads a Gestalt selector for")
init_push = re.search(
    r'push_verified\(f"\{EXTENSIONS\}:\{name\}".{0,200}?'
    r'want_type="INIT".{0,80}?min_rsrc=', text, re.DOTALL)
check(init_push is not None,
      "Mirror's INITs are not verified by RESOURCE fork size and type - "
      "an INIT's code lives in the resource fork, so a file with the "
      "right name and an empty one boot-loads nothing whatever")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    raise SystemExit(f"{len(failures)} failure(s)")
print("mirror_port_staging_source: ok")
