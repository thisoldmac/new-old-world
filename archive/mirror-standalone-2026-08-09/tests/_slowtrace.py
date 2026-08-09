"""Scratch: log any wire call slower than 1.5s, then run the probe."""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import trials

_orig = trials.Agent.call


def _timed(self, verb, args=None, retries=3):
    t0 = time.time()
    try:
        return _orig(self, verb, args, retries)
    finally:
        dt = time.time() - t0
        if dt > 1.5:
            print(f"      SLOW {dt:5.1f}s {verb} {str(args)[:70]}", flush=True)


trials.Agent.call = _timed

sys.argv = ["textops-probe.py"] + sys.argv[1:]
t0 = time.time()
exec(compile(open(os.path.join(HERE, "textops-probe.py")).read(),
             "textops-probe.py", "exec"),
     {"__name__": "__main__", "__file__": os.path.join(HERE,
                                                       "textops-probe.py")})
print("total", time.time() - t0)
