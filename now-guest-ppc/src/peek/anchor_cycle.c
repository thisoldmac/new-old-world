/*
 * anchor_cycle.c - see anchor_cycle.h. The one implementation behind the
 * `cycle` verb's two faces (docs/command-parity.md).
 */

#include "anchor_cycle.h"

#include <Processes.h>
#include <string.h>

#include "anchor_acquire.h"
#include "anchor_acquire_logic.h"
#include "axprocess.h"
#include "peek.h"

/* How long the whole cycle may take. A ceiling on a person's patience
   rather than a budget anyone should hit: a machine of a dozen
   applications that all pump finishes in a second or two, because every
   one of them leaves its turn the moment it has an anchor. */
enum { kCycleTotalTicks = 900 };          /* 15 s */

/* How long one application gets after it is brought forward. Generous
   next to the two-tick yields, because this one is waiting for a
   FOREIGN event loop to run - an application coming back from a long
   sleep with an update event to service may take several passes before
   it reaches WaitNextEvent again. */
enum { kCycleFrontTicks = 45 };           /* 0.75 s */

enum { kCycleYieldTicks = 2 };

/* Long enough to outlive the whole cycle, so the plane cannot go dark
   underneath it if a scene poll lapses while an application is front. */
enum { kCycleLeaseTicks = kCycleTotalTicks + 300 };

enum { kCycleMaxTargets = kNowPeekMaxAnchors };

static void note(NowAnchorCycleReport *out, const char *text)
{
    if (out != NULL && text != NULL) {
        strncpy(out->note, text, sizeof out->note - 1);
        out->note[sizeof out->note - 1] = '\0';
    }
}

/* The resident's own counters, straight off the table. Read twice - once
   before and once after - because a control that reports its own success
   is not evidence, and the pair is what separates "fronted things and
   acquired nothing" from a cycle that worked. */
static void sample(unsigned long *count, unsigned long *scans,
                   unsigned long *passes)
{
    const NowPeekTable *table = now_peek_table();

    *count = 0;
    *scans = 0;
    *passes = 0;
    if (table == NULL) {
        return;
    }
    *count = (unsigned long)table->anchor_count;
    *scans = (unsigned long)table->anchor_slot_scans;
    *passes = (unsigned long)table->anchor_event_passes;
}

static int plane_armed(void)
{
    const NowPeekTable *table = now_peek_table();

    return table != NULL
        && (table->arm_active & (NowPeekU32)kNowPeekTableCapAnchors) != 0;
}

static int has_anchor(const ProcessSerialNumber *psn)
{
    NowAxContext ctx;

    return now_ax_bind_process(psn, &ctx) == kNowPeekReadOk;
}

/* Yield without dequeuing anything: mask zero, the same yield
   now_peek_settle and act_client use. The main loop keeps its events. */
static void cycle_yield(void)
{
    EventRecord ev;

    /* Renew the writer heartbeat and republish the claim while we are
       not in our own event loop. Three seconds of writer lease is
       shorter than this cycle, and a lapsed writer makes the resident
       bypass arm_request entirely - the plane would go dark mid-cycle
       and the fronting would acquire nothing. */
    now_peek_idle();
    now_peek_claim_until(kNowPeekOwnerCycle,
                         (unsigned long)kNowPeekCapAnchors,
                         (unsigned long)TickCount() + kCycleLeaseTicks);
    (void)WaitNextEvent(0, &ev, (UInt32)kCycleYieldTicks, NULL);
}

/* Still there? A process that quit between enumeration and its turn is a
   vanished target, not a refusal, and the two want different words. */
static int process_alive(const ProcessSerialNumber *psn, Boolean *background)
{
    ProcessInfoRec info;
    Str31 name;

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    name[0] = 0;
    if (GetProcessInformation((ProcessSerialNumber *)psn, &info) != noErr) {
        return 0;
    }
    if (background != NULL) {
        *background = (info.processMode & modeOnlyBackground) != 0;
    }
    return 1;
}

int now_peek_anchor_cycle(NowAnchorCycleReport *out)
{
    ProcessSerialNumber self;
    ProcessSerialNumber was_front;
    ProcessSerialNumber psn;
    ProcessSerialNumber targets[kCycleMaxTargets];
    short target_count = 0;
    short i;
    int had_front;
    NowPeekU32 deadline;

    if (out == NULL) {
        return 0;
    }
    memset(out, 0, sizeof *out);

    if (now_peek_table() == NULL) {
        note(out, "the NOW Extension is not active on this machine");
        return 0;
    }
    if (GetCurrentProcess(&self) != noErr) {
        note(out, "this process cannot name itself; nothing was disturbed");
        return 0;
    }

    /* ARM BEFORE ANYTHING MOVES, and refuse if it will not arm. Fronting
       applications while the plane is dark disturbs a person's machine
       and acquires nothing, which is the one outcome worse than not
       running at all. */
    now_peek_claim_until(kNowPeekOwnerCycle,
                         (unsigned long)kNowPeekCapAnchors,
                         (unsigned long)TickCount() + kCycleLeaseTicks);
    if (!now_peek_settle((unsigned long)kNowPeekCapAnchors, 60L)
        || !plane_armed()) {
        now_peek_release(kNowPeekOwnerCycle, (unsigned long)kNowPeekCapAnchors);
        note(out, "the anchor plane would not arm; nothing was disturbed");
        return 0;
    }
    out->armed = 1;
    sample(&out->before_count, &out->before_slot_scans,
           &out->before_event_passes);

    had_front = GetFrontProcess(&was_front) == noErr;

    /* THE INVISIBLE PASS FIRST. Whatever a wake reaches is a window that
       never flashes, and on a machine whose applications all pump this
       is most of them. */
    now_peek_anchor_acquire(1);

    /* Enumerate what is still missing. Taken as a list up front rather
       than walked live: fronting applications changes process order, and
       a cycle that re-enumerated as it went could visit one twice and
       another never. */
    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (target_count < (short)kCycleMaxTargets
           && GetNextProcess(&psn) == noErr) {
        Boolean same = false;
        Boolean background = false;

        if (SameProcess(&psn, &self, &same) == noErr && same) {
            continue;                 /* we are pumping by definition */
        }
        out->considered++;
        if (has_anchor(&psn)) {
            out->already++;
            continue;
        }
        if (!process_alive(&psn, &background)) {
            out->vanished++;
            continue;
        }
        if (background) {
            /* OUT OF SCOPE AND SAID SO. A background-only process has no
               user interface to bring forward; SetFrontProcess on one is
               meaningless, and the six on this machine that never
               acquire an anchor on ANY machine, driven or not, are
               exactly these. Counting them as failures would make an
               honest cycle read as a broken one forever. */
            out->background_only++;
            continue;
        }
        targets[target_count++] = psn;
    }
    /* Anything the wake reached is one this cycle does not have to front,
       and that is worth reporting rather than hiding inside `already`. */
    {
        NowAcquireStats stats;

        now_peek_anchor_acquire_stats(&stats);
        out->woken = (short)(stats.woken > 32767UL ? 32767UL : stats.woken);
    }

    out->complete = 1;
    deadline = (NowPeekU32)TickCount() + (NowPeekU32)kCycleTotalTicks;
    for (i = 0; i < target_count; ++i) {
        NowPeekU32 turn_ends;
        Boolean background = false;

        if (now_acquire_deadline_passed((NowPeekU32)TickCount(), deadline)) {
            /* Out of time. An interrupted cycle says so rather than
               letting a half-populated scene read as a whole one. */
            out->complete = 0;
            break;
        }
        if (!process_alive(&targets[i], &background)) {
            out->vanished++;          /* quit while we were elsewhere */
            continue;
        }
        if (SetFrontProcess(&targets[i]) != noErr) {
            out->refused++;
            continue;
        }
        out->fronted++;
        turn_ends = (NowPeekU32)TickCount() + (NowPeekU32)kCycleFrontTicks;
        for (;;) {
            if (has_anchor(&targets[i])) {
                break;
            }
            if (now_acquire_deadline_passed((NowPeekU32)TickCount(),
                                            turn_ends)) {
                break;
            }
            cycle_yield();
        }
        if (has_anchor(&targets[i])) {
            out->acquired++;
        } else {
            /* Came forward and still never pumped inside its turn - an
               application in a tight loop of its own, or one whose event
               loop is wedged. Named as a refusal, because from here the
               two are the same fact: it would not answer. */
            out->refused++;
        }
    }

    /* RESTORE, ON EVERY PATH OUT. This is below the loop and the loop's
       only exits are `break`s, so there is one way out of this function
       once anything has been fronted. */
    if (had_front && process_alive(&was_front, NULL)) {
        out->restored = SetFrontProcess(&was_front) == noErr;
        if (!out->restored) {
            note(out, "the application that was front would not come back");
        }
    } else if (had_front) {
        /* It quit while we were cycling. There is nothing to restore to,
           so we take the front ourselves rather than leaving whichever
           application happened to be last in the list holding it - a
           person should come back to the tool they invoked. */
        (void)SetFrontProcess(&self);
        note(out, "the application that was front has quit; NOW took the "
                  "front instead");
    }

    sample(&out->after_count, &out->after_slot_scans,
           &out->after_event_passes);
    now_peek_release(kNowPeekOwnerCycle, (unsigned long)kNowPeekCapAnchors);
    if (out->note[0] == '\0') {
        note(out, out->complete ? "every application got its turn"
                                : "the cycle ran out of time partway "
                                  "through; state is partial");
    }
    return 1;
}
