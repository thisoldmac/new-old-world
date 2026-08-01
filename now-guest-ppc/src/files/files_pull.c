#include "files_pull.h"

#include <stdio.h>
#include <string.h>

/* No Toolbox here - see the header. */

/* A 32-bit signed type on the guest AND on the host that runs the native
   test. This is not decoration: the guest's `long` is 32 bits and the
   test host's is 64, so an overflow guard written in `long` is INVISIBLE
   to the test - the mutation that deletes it passes. Watched happening on
   2026-07-31, which is why the arithmetic below is in this type. */
#if defined(__LP64__) || defined(_LP64)
typedef int PullWide;
#else
typedef long PullWide;
#endif

static NowPullCanceller g_canceller;

void now_pull_set_canceller(NowPullCanceller fn)
{
    g_canceller = fn;
}

Boolean now_pull_have_canceller(void)
{
    return g_canceller != 0;
}

int now_pull_cancel(char *err, long cap)
{
    if (g_canceller == 0) {
        if (err != 0 && cap > 0) {
            snprintf(err, (size_t)cap,
                     "This Mac cannot stop a transfer yet.");
        }
        return -1;
    }
    return g_canceller(err, cap);
}

/* --- state -------------------------------------------------------------- */

void now_pull_reset(PullView *v)
{
    if (v == 0) {
        return;
    }
    v->phase = kPullIdle;
    v->received = 0;
    v->expected = 0;
    v->name[0] = '\0';
}

void now_pull_asked(PullView *v, const char *name)
{
    if (v == 0) {
        return;
    }
    v->phase = kPullAsking;
    v->received = 0;
    v->expected = 0;
    if (name == 0) {
        v->name[0] = '\0';
    } else {
        strncpy(v->name, name, kPullNameMax - 1);
        v->name[kPullNameMax - 1] = '\0';
    }
}

void now_pull_observe(PullView *v, Boolean active, Boolean receiving,
                      long received, long expected)
{
    if (v == 0) {
        return;
    }
    if (!active) {
        /* The wire says nothing is in flight. Whatever the pane thought,
           the pull is over - finished, refused, timed out or stopped.
           The name survives the reset so a closing line can still say
           which file it was about. */
        char kept[kPullNameMax];

        strcpy(kept, v->name);
        now_pull_reset(v);
        strcpy(v->name, kept);
        return;
    }
    if (received < 0) {
        received = 0;
    }
    if (expected < 0) {
        expected = 0;
    }
    v->received = received;
    v->expected = expected;
    if (v->phase == kPullIdle) {
        /* Live without this pane having asked: a pull started somewhere
           else this side can still show and still stop. */
        v->phase = receiving ? kPullReceiving : kPullAsking;
        return;
    }
    if (v->phase == kPullAsking && receiving) {
        v->phase = kPullReceiving;
    }
    /* kPullStopping is deliberately sticky while the wire still reports
       the transfer: the press has happened, and re-arming Stop for the
       pass or two before the teardown lands would invite a second press
       at something already gone. */
}

void now_pull_stopping(PullView *v)
{
    if (v == 0 || v->phase == kPullIdle) {
        return;
    }
    v->phase = kPullStopping;
}

/* --- what the person sees ----------------------------------------------- */

int now_pull_percent(const PullView *v)
{
    long pct;

    if (v == 0 || v->expected <= 0) {
        return -1;
    }
    if (v->received <= 0) {
        return 0;
    }
    if (v->received > 20000000L) {
        /* Past the multiply's safe range. Both sides to K first: the
           lost precision is under a thousandth of a percent. */
        PullWide got_k = (PullWide)(v->received / 1024);
        PullWide want_k = (PullWide)(v->expected / 1024);

        pct = want_k > 0 ? got_k * 100 / want_k : 100;
    } else {
        pct = (PullWide)v->received * 100 / (PullWide)v->expected;
    }
    if (pct < 0) {
        pct = 0;
    }
    if (pct > 100) {
        /* More bytes than the sender promised. Reported as complete
           rather than as an impossible number; the discrepancy is the
           receiver's problem to fail on, not the placard's to shout
           about. */
        pct = 100;
    }
    return (int)pct;
}

/* Rounded up, so a 900-byte file reads "1 K" rather than "0 K" - a
   transfer that says zero looks like a transfer that has not started. */
static long as_k(long bytes)
{
    if (bytes <= 0) {
        return 0;
    }
    return (bytes + 1023) / 1024;
}

static const char *pull_name(const PullView *v)
{
    return v->name[0] != '\0' ? v->name : "the file";
}

void now_pull_note(const PullView *v, char *out, long cap)
{
    int pct;

    if (out == 0 || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (v == 0 || v->phase == kPullIdle) {
        return;
    }
    switch (v->phase) {
    case kPullAsking:
        /* Not "Getting... 0 K". Nothing has been got, and a zero that
           never moves is what a hung transfer looks like. */
        snprintf(out, (size_t)cap, "Asking for %.31s...", pull_name(v));
        return;
    case kPullStopping:
        snprintf(out, (size_t)cap, "Stopping %.31s...", pull_name(v));
        return;
    default:
        break;
    }
    pct = now_pull_percent(v);
    if (pct >= 0) {
        snprintf(out, (size_t)cap, "Getting %.31s - %d%% of %ld K",
                 pull_name(v), pct, as_k(v->expected));
    } else {
        /* No size from the sender. The count still moves, which is the
           minimum honest indication: it says bytes are arriving without
           claiming to know how many are left. */
        snprintf(out, (size_t)cap, "Getting %.31s - %ld K so far",
                 pull_name(v), as_k(v->received));
    }
}

void now_pull_stopped_note(const PullView *v, char *out, long cap)
{
    if (out == 0 || cap <= 0) {
        return;
    }
    if (v == 0) {
        out[0] = '\0';
        return;
    }
    snprintf(out, (size_t)cap,
             "Stopped getting %.31s - nothing was kept. Ready.",
             pull_name(v));
}

Boolean now_pull_can_stop(const PullView *v)
{
    if (v == 0 || g_canceller == 0) {
        return 0;
    }
    return (Boolean)(v->phase == kPullAsking || v->phase == kPullReceiving);
}

long now_pull_step(const PullView *v)
{
    long within;

    if (v == 0 || v->phase == kPullIdle) {
        return 0;
    }
    if (v->phase == kPullAsking) {
        within = 0;
    } else if (v->expected > 0) {
        within = now_pull_percent(v);
    } else {
        within = v->received / 4096;
    }
    /* Phase in the high part so a transition always changes the step,
       even when the counts happen to land on the same bucket. */
    return (long)v->phase * 1000000L + within;
}
