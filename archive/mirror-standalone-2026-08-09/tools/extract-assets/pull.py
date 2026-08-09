"""Live, read-only resource-fork pull off an anchor worker via the harness wire.

`pull_forks` fetches the rsrc fork of each source file and caches it under
`cache_dir` so the parse/render stages can re-run without hitting the guest
again. Nothing is written back to the guest.
"""

from __future__ import annotations

import os
import sys
import time

# Sources we depend on, resolved against a live OS 9.1 guest.
SOURCES = {
    "System.rsrc":   "Macintosh HD:System Folder:System",
    "Chicago.rsrc":  "Macintosh HD:System Folder:Fonts:Chicago",
    "Charcoal.rsrc": "Macintosh HD:System Folder:Fonts:Charcoal",
    "Geneva.rsrc":   "Macintosh HD:System Folder:Fonts:Geneva",
}


def _harness(repo: str, port: int):
    sys.path.insert(0, os.path.join(repo, "mcp-classic"))
    from timbottu_mcp_classic.harness import Harness
    return Harness(host="127.0.0.1", port=port, expect_backing={"worker"}, timeout=120)


def pull_forks(repo: str, port: int, cache_dir: str) -> dict[str, str]:
    """Pull every source's rsrc fork into cache_dir. Returns name -> path."""
    os.makedirs(cache_dir, exist_ok=True)
    h = _harness(repo, port)
    try:
        ver = h.version()
        print(f"worker {ver.get('version')} @ :{port} — pulling {len(SOURCES)} forks")
        out = {}
        for name, path in SOURCES.items():
            t = time.time()
            f = h.pull_file(path, fork="rsrc", pipeline=4)
            dest = os.path.join(cache_dir, name)
            with open(dest, "wb") as fh:
                fh.write(f.rsrc_fork)
            out[name] = dest
            print(f"  {name}: {len(f.rsrc_fork)} B in {time.time()-t:.1f}s")
        return out
    finally:
        h.close()
