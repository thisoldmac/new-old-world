#!/usr/bin/env python3
"""Cover the trial-counting rules in scripts/probes/tally.py.

    python3 scripts/probes/tests/tally_test.py     # or via scripts/test-native

Why this test and not another. The probe harnesses drive a live Macintosh and
cannot run on a bench with no machine, so almost nothing about them is
checkable here. What IS checkable is the arithmetic that turns trials into a
number — and that is also the one defect that would poison every number the
harnesses produce, quietly, in a direction nobody would notice. A probe that
counts a dropped trial as a clean one reports a guard holding when nothing was
tested.

The rules are upstream's (timbottu/mirror/tests: trials.py and
nohijack-probe.py's summarize). If any assertion here has to change, the
ported harnesses have stopped being comparable to upstream's 18/20 → 0/19 and
somebody has to say so out loud.

MUTATIONS THIS HAS BEEN SEEN TO FAIL UNDER (2026-07-31, run by hand, tree
restored after each):

  * `summarize`: score every trial instead of only the valid ones
        -  scored = [t for t in trials if bool(t.get("valid", True))]
        +  scored = list(trials)
    -> red: dropped_trials_are_not_scored, dropped_do_not_inflate_the_denominator

  * `summarize`: count the denominator before dropping
        -  n = len(scored)
        +  n = len(trials)
    -> red: dropped_do_not_inflate_the_denominator, a_run_of_all_misses_is_zero_of_zero

  * `paged_to_minimum`: accept any decrease as the armed action
        -  return after <= minimum
        +  return after < 10000
    -> red: a_one_line_move_is_not_the_armed_page

  * `paged_to_minimum`: treat unreadable state as a negative rather than
    refusing to score
        -  if after is None or minimum is None: return False
        +  if after is None or minimum is None: return False  (unchanged)
        with the caller's `valid` flag removed instead
    -> red: an_unreadable_control_is_not_a_clean_trial

  * `hijacked`: drop the oracle half, trusting the reply alone
        -  return bool(...reply.get("ok")) or bool(oracle_fired)
        +  return bool(...reply.get("ok"))
    -> red: an_oracle_that_fires_is_a_hijack_even_if_the_reply_refused

  * `replied`: treat ok:false as a non-reply
        -  return isinstance(reply, dict) and reply.get("type") in (...)
        +  return isinstance(reply, dict) and bool(reply.get("ok"))
    -> red: ok_false_is_a_reply

  * `exit_status`: return 0 unconditionally
    -> red: a_hijack_sets_the_exit_status
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tally  # noqa: E402

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append(f"{name}: got {got!r}, want {want!r}")


def t(**kw):
    return dict(kw)


# --- rule 4 and 5: a dropped trial is not scored, and does not divide --------

def dropped_trials_are_not_scored():
    trials = [
        t(valid=True, hijacked=False, chained=True),
        t(valid=False, hijacked=True, chained=False),   # the click missed
        t(valid=True, hijacked=False, chained=True),
    ]
    r = tally.summarize("control", trials, quiet=True)
    # The invalid trial LOOKS like a hijack. It is not counted as one, because
    # the stimulus never landed on the target the case aimed at.
    check("dropped/hijacks", r["hijacks"], 0)
    check("dropped/dropped", r["dropped"], 1)


def dropped_do_not_inflate_the_denominator():
    trials = [t(valid=True, hijacked=True, chained=False)] \
        + [t(valid=False, hijacked=False, chained=False)] * 9
    r = tally.summarize("control", trials, quiet=True)
    # 1 hijack in 1 SCORED trial. Counting the ten would report 1/10 and read
    # as a guard that mostly holds.
    check("denominator/n", r["n"], 1)
    check("denominator/hijacks", r["hijacks"], 1)
    check("denominator/dropped", r["dropped"], 9)


def a_run_of_all_misses_is_zero_of_zero():
    trials = [t(valid=False, hijacked=False, chained=False)] * 20
    r = tally.summarize("menu", trials, quiet=True)
    # The failure mode this guards: 0/20 and 0/0 are both "no hijacks", and
    # only one of them is a measurement.
    check("all-miss/n", r["n"], 0)
    check("all-miss/dropped", r["dropped"], 20)


def valid_defaults_to_true():
    # A case with no positional stimulus does not have to say `valid` at all.
    r = tally.summarize("text", [t(hijacked=False, chained=True)], quiet=True)
    check("default-valid/n", r["n"], 1)


# --- rule 2: ok:false is a reply --------------------------------------------

def ok_false_is_a_reply():
    refusal = {"type": "command.result", "id": 3, "ok": False,
               "error": {"code": "not_actionable", "message": "no such window"}}
    check("reply/ok-false", tally.replied(refusal), True)


def ok_true_is_a_reply():
    check("reply/ok-true",
          tally.replied({"type": "command.result", "id": 1, "ok": True}), True)


def a_timeout_is_not_a_reply():
    check("reply/none", tally.replied(None), False)
    check("reply/junk", tally.replied({"nope": 1}), False)


def a_transport_error_frame_is_a_reply():
    # `{"type":"error","id":N,...}` is the guest answering, not the link dying.
    check("reply/error-frame",
          tally.replied({"type": "error", "id": 4, "code": "bad-args"}), True)


# --- rule 3: the oracle and the reply are an OR, and both halves matter ------

def an_oracle_that_fires_is_a_hijack_even_if_the_reply_refused():
    refusal = {"type": "command.result", "ok": False,
               "error": {"code": "not_taken"}}
    check("hijack/oracle-only", tally.hijacked(refusal, True), True)


def a_reply_that_fired_is_a_hijack_even_if_the_oracle_saw_nothing():
    fired = {"type": "command.result", "ok": True}
    check("hijack/reply-only", tally.hijacked(fired, False), True)


def neither_is_no_hijack():
    refusal = {"type": "command.result", "ok": False,
               "error": {"code": "not_taken"}}
    check("hijack/neither", tally.hijacked(refusal, False), False)


def a_missing_reply_still_scores_the_oracle():
    check("hijack/no-reply", tally.hijacked(None, True), True)
    check("hijack/no-reply-clean", tally.hijacked(None, False), False)


# --- the control case's two direction oracles -------------------------------

def a_one_line_move_is_not_the_armed_page():
    # Upstream saw exactly this: the bar moved one line up while the patch
    # reported it never fired. Scoring "went up" as a hijack would have
    # published a leak that was not there.
    check("page/one-line", tally.paged_to_minimum(after=49, minimum=0), False)
    check("page/to-min", tally.paged_to_minimum(after=0, minimum=0), True)
    check("page/below-min", tally.paged_to_minimum(after=-1, minimum=0), True)


def an_unreadable_control_is_not_a_clean_trial():
    # Refusing to answer is right; the CALLER must then mark the trial invalid
    # rather than let a False read as "the guard held".
    check("page/unreadable-after", tally.paged_to_minimum(None, 0), False)
    check("page/unreadable-min", tally.paged_to_minimum(0, None), False)


def direction_discriminates():
    check("dir/down", tally.moved_own_way(before=50, after=51), True)
    check("dir/up", tally.moved_own_way(before=50, after=0), False)
    check("dir/still", tally.moved_own_way(before=50, after=50), False)
    check("dir/unknown", tally.moved_own_way(before=None, after=50), False)


# --- rule 1: two rates, counted separately ----------------------------------

def reply_and_actuation_are_independent():
    trials = [
        t(replied=True, actuated=True),
        t(replied=True, actuated=False),    # answered, did nothing
        t(replied=False, actuated=False),   # never answered
        t(replied=True, actuated=False),
    ]
    r = tally.rate_summary("textset", trials, quiet=True)
    check("rates/replied", r["replied"], 3)
    check("rates/actuated", r["actuated"], 1)
    check("rates/n", r["n"], 4)


def rate_summary_drops_invalid_too():
    trials = [t(replied=True, actuated=True),
              t(valid=False, replied=True, actuated=True)]
    r = tally.rate_summary("textset", trials, quiet=True)
    check("rates/dropped-n", r["n"], 1)
    check("rates/dropped", r["dropped"], 1)


# --- rule 6: the finding is the exit status ---------------------------------

def a_hijack_sets_the_exit_status():
    check("exit/clean", tally.exit_status(
        [{"case": "control", "hijacks": 0}, {"case": "menu", "hijacks": 0}]), 0)
    check("exit/one", tally.exit_status(
        [{"case": "control", "hijacks": 0}, {"case": "menu", "hijacks": 1}]), 1)


def the_calibration_cases_do_not_set_it():
    # `window` sweeps the disarm window and is SUPPOSED to hijack at short
    # delays; `baseline` arms nothing. Neither is a finding.
    check("exit/window", tally.exit_status([{"case": "window", "hijacks": 9}]), 0)
    check("exit/baseline",
          tally.exit_status([{"case": "baseline", "hijacks": 3}]), 0)


# --- the recorded numbers still come out the way upstream reported them -----

def upstreams_two_numbers_reproduce():
    """The whole point of porting the counting rather than rewriting it.

    18/20 (the request that merely disarmed after one use rode the user's own
    press) and 0/19 (the variant that had to name its exact target) — quoted
    in NOW's own contract at contract/asyncapi.yaml, the act plane preamble.
    The 19 is 19 and not 20 because one trial's click missed and was dropped.
    """
    leaky = [t(valid=True, hijacked=True, chained=False)] * 18 \
        + [t(valid=True, hijacked=False, chained=True)] * 2
    r = tally.summarize("menu", leaky, quiet=True)
    check("upstream/18-of-20", (r["hijacks"], r["n"]), (18, 20))

    tight = [t(valid=True, hijacked=False, chained=True)] * 19 \
        + [t(valid=False, hijacked=False, chained=False)]
    r = tally.summarize("menu", tight, quiet=True)
    check("upstream/0-of-19", (r["hijacks"], r["n"], r["dropped"]),
          (0, 19, 1))


TESTS = [v for k, v in sorted(globals().items())
         if callable(v) and not k.startswith("_")
         and k not in ("check", "t") and getattr(v, "__module__", "") == "__main__"]


def main() -> int:
    for fn in TESTS:
        fn()
    if FAILURES:
        for f in FAILURES:
            print("FAIL " + f)
        print(f"\n{len(FAILURES)} failed of {len(TESTS)} checks")
        return 1
    print(f"tally: {len(TESTS)} checks ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
