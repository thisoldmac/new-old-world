"""Where the lab checkout is, answered once.

TWO ROOTS, and they are not the same: NOW owns the artifacts, the lab
checkout beside it owns the INSTRUMENTS — the emulator, `tools/qmp` and
the anchor-worker client. Nothing under `now-guest-*/` or `now-host/`
imports any of it; only the rig does.

Finding it was copy-pasted into a dozen rig tools in three different
shapes, and on 2026-08-07 that cost this scheme's first real user two
failures in one session:

  * `scripts/spin-up-ppc` needed `NOW_LAB_ROOT` set by hand, because a
    worktree under `/private/tmp` has NO SHARED ANCESTOR with the lab at
    all — the walk-up reaches `/` and finds nothing. Every copy assumed
    a worktree lives inside the checkout, and an agent lane's does not.
  * `tools/lane-ports reclaim` died on the import and reported
    **"clean shutdown FAILED and the VM is left up"** — a host-side
    setup error wearing a guest failure's words, one step from a power
    cut and a Disk First Aid boot.

One of the twelve copies also hardcodes a specific person's home
directory, which is the same defect with a longer fuse.

So: ask git. A worktree's `--git-common-dir` points at the MAIN clone's
`.git` wherever on the filesystem the worktree happens to sit, and the
lab checkout is above that. That is the one question — "which checkout
am I really part of" — and it has one answer here.
"""

import os
import subprocess
import sys

# tools/ lives in NOW; NOW's neighbour (or ancestor) is the lab.
_HERE = os.path.dirname(os.path.abspath(__file__))
NOW = os.path.abspath(os.path.join(_HERE, ".."))

# The exit code a rig tool uses for "I never reached the guest". Distinct
# from any refusal, so a caller cannot answer a missing import by
# accepting a dirty volume.
EXIT_RIG_MISSING = 3


def _walk_up(start):
    d = start
    while d and d != "/":
        if os.path.isdir(os.path.join(d, "mcp-classic")):
            return d
        d = os.path.dirname(d)
    return None


def find_lab(start=NOW):
    """The lab checkout, or None. `NOW_LAB_ROOT` always wins."""
    override = os.environ.get("NOW_LAB_ROOT")
    if override:
        return override
    found = _walk_up(start)
    if found:
        return found
    # No shared ancestor — the agent-worktree case. Git knows.
    try:
        out = subprocess.run(
            ["git", "-C", start, "rev-parse", "--path-format=absolute",
             "--git-common-dir"],
            capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return _walk_up(os.path.dirname(out.stdout.strip()))
    except Exception:
        pass
    return None


def import_harness(what="reach the guest"):
    """`(Harness, HarnessError)`, or exit 3 saying nothing was attempted.

    `what` completes the sentence "the guest was never asked to …", so
    the message names the thing that did NOT happen rather than the
    import that failed. A reader of that line decides whether to reach
    for `--power-cut`, and they must be told the machine is untouched.
    """
    lab = find_lab()
    if lab:
        sys.path.insert(0, os.path.join(lab, "mcp-classic"))
    try:
        from timbottu_mcp_classic.harness import Harness, HarnessError
        return Harness, HarnessError
    except ImportError as exc:
        sys.stderr.write(
            f"{os.path.basename(sys.argv[0])}: the rig is not reachable,\n"
            f"  so NOTHING WAS ASKED of the guest ({what}). This is not a\n"
            "  guest that refused.\n"
            f"    looked for mcp-classic under: {lab or '(nothing found)'}\n"
            f"    import said: {exc}\n"
            "  Set NOW_LAB_ROOT to the TimBotTu clone that contains\n"
            "  mcp-classic/, then re-run. Do NOT power-cut: the machine is\n"
            "  untouched and a power cut would dirty its volume for\n"
            "  nothing.\n")
        sys.exit(EXIT_RIG_MISSING)
