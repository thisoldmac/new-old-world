"""How a trial is COUNTED. Ported from `archive/mirror-standalone-2026-08-09/tests/trials.py` and
the `summarize` in `nohijack-probe.py`.

This file is the reason the port is worth anything. The scripts around it can
be re-pointed at a different wire and a different verb spelling; the numbers
they produce are only comparable to upstream's if a trial is counted the same
way it was counted there. Changing anything here silently destroys the
comparison — 18/20 versus 0/19 stops meaning what it meant.

So this half is PURE (no sockets, no guest, no time), lives on its own, and is
covered by `tests/tally_test.py`, which is wired into `scripts/test-native`.
A probe that miscounts is the one defect that would poison every number it
produces, and it is the one defect a machineless bench can actually catch.

## The rules, and where each came from

**1. Two rates, counted separately, because they fail independently.**

    reply rate       did the verb answer at all (vs. failing to talk)
    actuation rate   did the guest actually DO the thing

**2. `ok:false` is a REPLY.** The guest saying `not_actionable` is a working
verb reporting a fact. Upstream's note: conflating that with a transport
failure "is how a healthy act plane got written up as broken."

**3. Actuation needs an oracle in the GUEST, never the verb's own say-so.**
The reply says the event was posted, which is not evidence the front app
acted. NOW's contract says the same thing in its own words about the act
plane: "an ok reply means the event was handed to the addressed element's own
application, never that the window moved or the text changed... There is
deliberately no `performed` field for a responder to set true."

**4. An invalid trial is DROPPED, not scored.** From `nohijack-probe.py`:
a click that missed its target "is not a failure to hijack — it is not a
trial." Scoring it would report a clean no-hijack that never tested anything.
Dropped trials are reported as their own number, so a run that dropped half
its trials cannot read as a clean run.

**5. Rates are over the SCORED set,** i.e. the denominator is trials-minus-
dropped. This is why `Tally.n` is not `len(trials)`.

**6. A hijack is a FINDING, not a crash.** It is reported and it sets the exit
status, because that number gates every later act op.
"""

from __future__ import annotations


class Trial(dict):
    """One trial's record. A dict so it serialises straight to the run's JSON
    alongside upstream's, whose per-trial keys these deliberately reuse."""

    def __init__(self, index: int, **fields):
        super().__init__(trial=index, **fields)

    @property
    def valid(self) -> bool:
        # Absent means valid: a case with no way for a trial to miss (the text
        # cases drive nothing positional) does not have to say so every time.
        return bool(self.get("valid", True))


def summarize(name: str, trials, *, quiet: bool = False) -> dict:
    """Score only the trials whose stimulus landed where the case aimed it.

    Verbatim in behaviour from `nohijack-probe.summarize`, including its
    reason: "A click that missed is not evidence of a guard holding — it is
    evidence of nothing, and averaging it in would manufacture the exact false
    green this project keeps having to retract."
    """
    scored = [t for t in trials if bool(t.get("valid", True))]
    n = len(scored)
    dropped = len(trials) - n
    hijacks = sum(1 for t in scored if t.get("hijacked"))
    chained = sum(1 for t in scored if t.get("chained"))
    if not quiet:
        print(f"    armed requests that fired on the wrong target: "
              f"{hijacks}/{n}")
        print(f"    the real click did its own thing:               "
              f"{chained}/{n}")
        if dropped:
            print(f"    dropped (the stimulus missed its target):       "
                  f"{dropped}")
    return {"case": name, "n": n, "dropped": dropped, "hijacks": hijacks,
            "chained": chained, "trials": list(trials)}


def rate_summary(name: str, trials, *, quiet: bool = False) -> dict:
    """The OTHER shape: reply rate and actuation rate, `trials.py`'s form.

    Used by the probes that measure a verb rather than a guard — textops,
    ctlinvoke, winact, apple-event, g1's launch case. Kept separate from
    `summarize` rather than merged with it, because merging them would mean
    one denominator serving two questions and it is exactly that kind of tidy
    that loses a distinction upstream paid for.
    """
    scored = [t for t in trials if bool(t.get("valid", True))]
    n = len(scored)
    dropped = len(trials) - n
    replied = sum(1 for t in scored if t.get("replied"))
    actuated = sum(1 for t in scored if t.get("actuated"))
    if not quiet:
        print(f"    replied  (the verb answered at all):  {replied}/{n}")
        print(f"    actuated (the guest actually did it): {actuated}/{n}")
        if dropped:
            print(f"    dropped  (not a trial):               {dropped}")
    return {"case": name, "n": n, "dropped": dropped, "replied": replied,
            "actuated": actuated, "trials": list(trials)}


def replied(reply: dict) -> bool:
    """Rule 2. An `ok:false` answer IS a reply.

    `reply` is the whole reply object as `GuestLink.read_result` returns it.
    A trial that never got one passes None here.
    """
    return isinstance(reply, dict) and reply.get("type") in (
        "command.result", "exec.result", "error")


def hijacked(reply, oracle_fired: bool) -> bool:
    """Rule 3 and rule 6, in the one place the no-hijack case needs them.

    Upstream's line, kept: an armed request counts as having fired if EITHER
    the responder said it fired (`ok`) OR the guest's own independent oracle
    says the armed action happened. The `or` is deliberate and is not
    redundancy — a responder that fired but lied would be caught by the
    oracle, and an oracle that cannot see the effect (a menu case where the
    folder was created and then deleted by something else) would be caught by
    the reply. Either alone is a weaker test than the pair.
    """
    return bool(isinstance(reply, dict) and reply.get("ok")) or bool(oracle_fired)


def paged_to_minimum(after, minimum) -> bool:
    """The control case's armed-oracle, and the trap it exists to avoid.

    The armed part is `inPageUp` and a page in the case's window is the WHOLE
    range, so a hijack lands the bar on its MINIMUM. Any smaller decrease is
    NOT the armed request: upstream saw one trial move exactly one line up
    with the patch reporting it never fired, and notes that scoring "went up"
    as a hijack "would have published that as a leak."

    Returns False on missing data rather than guessing. A trial that could not
    read the control back is not a trial that saw no hijack.
    """
    if after is None or minimum is None:
        return False
    return after <= minimum


def moved_own_way(before, after) -> bool:
    """The control case's chain-through oracle: DIRECTION.

    The armed part moves the bar up, the real click's part moves it down, so
    an increase can only be the click's own doing and a decrease can only be
    the request's. Upstream: "no single reading can be read both ways."
    """
    if before is None or after is None:
        return False
    return after > before


def exit_status(results) -> int:
    """Rule 6. A hijack is a finding, and the finding is the exit status.

    `baseline` and `window` are excluded exactly as upstream excludes them:
    the baseline case measures the machine with nothing armed (a "hijack"
    there would be a broken oracle, reported as such), and the window sweep is
    a calibration that is SUPPOSED to hijack at short delays — that is what it
    measures.
    """
    total = sum(r.get("hijacks", 0) for r in results
                if r.get("case") not in ("window", "baseline"))
    return 1 if total else 0


def print_summary(results) -> None:
    print("\n--- summary ---")
    for r in results:
        if r.get("case") == "window":
            continue
        if "hijacks" in r:
            print(f"{r['case']:10} hijacks {r['hijacks']}/{r['n']}   "
                  f"clean chain-through {r['chained']}/{r['n']}"
                  + (f"   dropped {r['dropped']}" if r.get("dropped") else ""))
        else:
            print(f"{r['case']:10} replied {r['replied']}/{r['n']}   "
                  f"actuated {r['actuated']}/{r['n']}"
                  + (f"   dropped {r['dropped']}" if r.get("dropped") else ""))
