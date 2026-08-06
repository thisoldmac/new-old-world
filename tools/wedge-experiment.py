"""Measure WHICH kind of guest-side block starves a background application.

The question 012 must answer before the resident picks a tick rate. The
Finder's alert starved every process on the guest for >90 s on
2026-08-05, but the mechanism was never established: `ModalDialog` calls
`GetNextEvent`, so a modal merely sitting there may starve nothing.

The observer is `tbt-worker` — a background-only application on its own
TCP port with no code in common with the wedge. If it keeps answering,
the machine is scheduling other processes; if it goes silent, it is not.

**The launch is a positive control, not a fire-and-forget.** The first
version of this swallowed a failed launch and reported "never went
silent", which is the instrument saying nothing happened and the reader
hearing that the block is harmless (drive-loop rule 2e).
"""
import sys, socket, time
sys.path.insert(0, "/Users/michelle/Lab/Code/timbottu/mcp-classic")
from timbottu_mcp_classic.harness import Harness

ANCHOR = 1700


def alive(timeout=2.0):
    """**Asks something that needs PROCESS time.**

    `hello` is answered below the application — measured 2026-08-05: it
    kept answering right through a spin wedge that `stat` could not
    survive. A probe answered at interrupt level cannot see application
    starvation, which is the whole quantity under test, so this asks for
    a File Manager call in the worker's own main loop instead."""
    socket.setdefaulttimeout(timeout)
    try:
        h = Harness(host="127.0.0.1", port=ANCHOR, expect_backing={"worker"})
        return bool(h.request("stat", {"path": "Macintosh HD:System Folder"}
                              ).get("exists"))
    except Exception:
        return False


def launch(path):
    """Returns the guest's own confirmation, or raises. Never swallowed."""
    socket.setdefaulttimeout(8.0)
    h = Harness(host="127.0.0.1", port=ANCHOR, expect_backing={"worker"})
    reply = h.request("launch", {"path": path})
    if not reply.get("launched"):
        raise RuntimeError(f"guest refused the launch: {reply}")
    return reply


def run(mode, seconds=20, watch=70):
    path = f"Macintosh HD:Desktop Folder:NOW Wedge {mode} {seconds}"
    print(f"\n=== {mode}, asked for {seconds}s ===", flush=True)
    for attempt in range(6):
        if alive():
            break
        time.sleep(5)
    else:
        print("  observer down before we began; aborting", flush=True)
        return
    reply = launch(path)                     # raises rather than lying
    print(f"  launched, psn {reply.get('serialLo')}", flush=True)

    t0 = time.time()
    samples = []
    while time.time() - t0 < watch:
        ok = alive()
        samples.append((round(time.time() - t0, 1), ok))
        # Stop once it has gone silent and come back for two clear reads.
        if len(samples) >= 3 and not any(s[1] for s in samples[:-2]) is False:
            pass
        if (any(not s[1] for s in samples)
                and samples[-1][1] and samples[-2][1]):
            break
        time.sleep(1.0)

    silent = [t for t, ok in samples if not ok]
    if not silent:
        print(f"  observer NEVER went silent over {round(time.time()-t0)}s"
              " — this block does not starve other applications", flush=True)
    else:
        back = next((t for t, ok in samples if ok and t > silent[-1]), None)
        print(f"  first silent at {silent[0]:.1f}s, last silent at "
              f"{silent[-1]:.1f}s"
              + (f", answering again by {back:.1f}s" if back else
                 ", still silent when we stopped"), flush=True)
        print(f"  starved for about {silent[-1] - silent[0] + 1:.0f}s of the "
              f"{seconds}s asked for", flush=True)
    print("  timeline:", "".join("." if ok else "X" for _, ok in samples),
          flush=True)


if __name__ == "__main__":
    for mode in sys.argv[1:]:
        run(mode)
        # Let the machine settle so one run cannot colour the next.
        time.sleep(10)
