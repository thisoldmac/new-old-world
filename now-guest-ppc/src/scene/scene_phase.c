/* Where a scene's time went. See scene_phase.h for why this exists and
   why the clock is injected rather than called. */

#include "scene_phase.h"

#include <string.h>

static unsigned long (*g_clock)(void);

static unsigned long g_us[kNowScenePhaseCount];
static int           g_stack[kNowScenePhaseDepthMax];
static int           g_depth;
static int           g_dropped;        /* enters the stack had no room for */
static unsigned long g_mark;           /* clock at the last transition */
static unsigned long g_reads;
static unsigned long g_faults;
static int           g_measured;

/* Nanoseconds per clock read, measured once. Nanoseconds because a read
   that costs under a microsecond would otherwise calibrate to zero and
   the self-report would flatter itself. */
static unsigned long g_clock_ns;
static int           g_calibrated;

static const char *const g_names[kNowScenePhaseCount] = {
    "enumerate",
    "bind",
    "windows",
    "controls",
    "menubar",
    "semantics",
    "refs",
    "encode"
};

void now_scene_phase_set_clock(unsigned long (*clock_us)(void))
{
    g_clock = clock_us;
    g_calibrated = 0;
    g_clock_ns = 0;
}

void now_scene_phase_calibrate(void)
{
    enum { kSamples = 64 };
    unsigned long first, last;
    int i;

    if (g_calibrated || g_clock == NULL) {
        return;
    }
    g_calibrated = 1;
    first = g_clock();
    for (i = 0; i < kSamples; ++i) {
        (void)g_clock();
    }
    last = g_clock();
    /* kSamples + 1 reads separate `first` from `last`. Unsigned
       subtraction is correct across the counter's wrap, which is the
       only thing that can happen between two adjacent reads. */
    g_clock_ns = (unsigned long)(((last - first) * 1000UL)
                                 / (unsigned long)(kSamples + 1));
}

void now_scene_phase_reset(void)
{
    memset(g_us, 0, sizeof g_us);
    g_depth = 0;
    g_dropped = 0;
    g_reads = 0;
    g_faults = 0;
    g_mark = 0;
    g_measured = 0;
}

void now_scene_phase_enter(int phase)
{
    unsigned long now;

    if (g_clock == NULL || phase < 0 || phase >= kNowScenePhaseCount) {
        return;
    }
    if (g_depth >= kNowScenePhaseDepthMax) {
        /* Counted and dropped, but still POPPED by its matching leave -
           otherwise one over-deep seam would misfile every phase after
           it, which is a far worse failure than one missing number. */
        ++g_dropped;
        ++g_faults;
        return;
    }
    now = g_clock();
    ++g_reads;
    g_measured = 1;
    if (g_depth > 0) {
        g_us[g_stack[g_depth - 1]] += now - g_mark;
    }
    g_stack[g_depth++] = phase;
    g_mark = now;
}

void now_scene_phase_leave(int phase)
{
    unsigned long now;

    if (g_clock == NULL || phase < 0 || phase >= kNowScenePhaseCount) {
        return;
    }
    if (g_dropped > 0) {
        --g_dropped;                   /* the enter this matches was dropped */
        return;
    }
    if (g_depth <= 0 || g_stack[g_depth - 1] != phase) {
        /* A seam left a phase it was not in. The stack is left alone:
           unwinding it on a guess would spread one wrong number over
           several. */
        ++g_faults;
        return;
    }
    now = g_clock();
    ++g_reads;
    g_us[g_stack[--g_depth]] += now - g_mark;
    g_mark = now;
}

int now_scene_phase_reporting(void)
{
    return g_clock != NULL && g_measured;
}

const char *now_scene_phase_name(int phase)
{
    if (phase < 0 || phase >= kNowScenePhaseCount) {
        return "";
    }
    return g_names[phase];
}

unsigned long now_scene_phase_us(int phase)
{
    if (phase < 0 || phase >= kNowScenePhaseCount) {
        return 0;
    }
    return g_us[phase];
}

unsigned long now_scene_phase_clock_reads(void)
{
    return g_reads;
}

unsigned long now_scene_phase_clock_us(void)
{
    /* Rounded to the nearest microsecond rather than truncated: a
       measurement overhead that always reads low is the one kind of
       error this number exists to rule out. */
    return (g_reads * g_clock_ns + 500UL) / 1000UL;
}

unsigned long now_scene_phase_faults(void)
{
    return g_faults;
}
