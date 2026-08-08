#include "mirror_log.h"

#include <stdio.h>
#include <string.h>

#include "nowlog.h"
#include "qdtrace.h"

/* Task time, application side. See mirror_log.h for why that sentence is
   the whole design and not a note. */

enum {
    /* The content counters are polled on a slow cadence rather than
       every pass. Two seconds is chosen against what it is reading: the
       resident bumps these inside foreign processes at draw time, so the
       question "did anything hook, skip or refuse" is answered just as
       well two seconds late, and the poll itself is a handful of loads
       off a system-heap block. */
    kMirrorLogPollTicks = 120
};

static const char *owner_name(int owner)
{
    switch (owner) {
    case kNowPeekOwnerScene:     return "scene";
    case kNowPeekOwnerProcesses: return "processes";
    case kNowPeekOwnerAct:       return "act";
    case kNowPeekOwnerContent:   return "content";
    case kNowPeekOwnerEvents:    return "events";
    case kNowPeekOwnerCycle:     return "cycle";
    case kNowPeekOwnerObserve:   return "observe";
    default:                     return "?";
    }
}

/* ---- the writer verdict --------------------------------------------- */

static int g_writer_said;
static MirrorWriterVerdict g_writer_verdict;
static unsigned long g_writer_session;

/* The last union this application published, kept so teardown can say
   what was still claimed when the process went away. */
static unsigned long g_requested;

void now_mirror_log_writer(MirrorWriterVerdict verdict, unsigned long session)
{
    if (g_writer_said && verdict == g_writer_verdict
        && session == g_writer_session) {
        return;                        /* the idle path's common case */
    }
    g_writer_said = 1;
    g_writer_verdict = verdict;
    g_writer_session = session;

    switch (verdict) {
    case kMirrorWriterOwned:
        now_log(kLogInfo, "mirror", "writer: this build owns the table, "
                "session %lu", session);
        break;
    case kMirrorWriterNoResident:
        now_log(kLogInfo, "mirror",
                "writer: no resident - 'NWex' silent or table rejected");
        break;
    case kMirrorWriterNoRegion:
        now_log(kLogWarn, "mirror",
                "writer: resident predates the writer lease; no plane arms");
        break;
    case kMirrorWriterNotCanonical:
        /* The one that took a rename to find. Warn, not info: the
           resident goes on reporting active with full capabilities while
           this is true, so an info line beside that would read as
           agreement rather than as the cause. */
        now_log(kLogWarn, "mirror",
                "writer: REFUSED - binary is not 'New Old World'/NOWo, "
                "no plane can arm");
        break;
    default:
        now_log(kLogWarn, "mirror",
                "writer: another live session owns the table");
        break;
    }
}

/* ---- arm and disarm requests ---------------------------------------- */

void now_mirror_log_request(int owner, unsigned long before,
                            unsigned long after)
{
    if (before == after) {
        return;                        /* asking for what is already asked */
    }
    g_requested = after;
    now_log(kLogInfo, "mirror", "arm request 0x%lx -> 0x%lx (%s)",
            before, after, owner_name(owner));
}

void now_mirror_log_disconnect(unsigned long before)
{
    if (before == 0) {
        return;
    }
    g_requested = 0;
    now_log(kLogInfo, "mirror", "disconnect: releasing planes 0x%lx", before);
}

/* ---- arm outcomes ---------------------------------------------------- */

/* Identical consecutive failures collapse. A scene poll at 4 Hz that
   cannot arm would otherwise write eight lines a second of one sentence,
   and with no log rotation on this guest (docs/logging.md) that is a
   disk leak as well as a heartbeat. The suppressed count is reported
   when the answer changes, so nothing is lost — only repeated. */
static char g_settle_why[48];
static unsigned long g_settle_caps;
static int g_settle_repeats;

static void settle_flush_repeats(void)
{
    if (g_settle_repeats > 0) {
        now_log(kLogWarn, "mirror", "settle 0x%lx: %.24s x%d more",
                g_settle_caps, g_settle_why, g_settle_repeats);
    }
    g_settle_repeats = 0;
    g_settle_why[0] = '\0';
    g_settle_caps = 0;
}

void now_mirror_log_settle(unsigned long caps, int armed, const char *why)
{
    if (armed) {
        if (g_settle_why[0] != '\0') {
            settle_flush_repeats();
            now_log(kLogInfo, "mirror", "settle 0x%lx: armed", caps);
        }
        return;                        /* a settle that just works is not news */
    }
    if (why == NULL) {
        why = "unknown";
    }
    if (caps == g_settle_caps && strcmp(why, g_settle_why) == 0) {
        ++g_settle_repeats;
        return;
    }
    settle_flush_repeats();
    g_settle_caps = caps;
    strncpy(g_settle_why, why, sizeof g_settle_why - 1);
    g_settle_why[sizeof g_settle_why - 1] = '\0';
    now_log(kLogWarn, "mirror", "settle 0x%lx failed: %.48s", caps, why);
}

/* ---- the Workshop page ----------------------------------------------- */

void now_mirror_log_page(const char *event)
{
    now_log(kLogInfo, "mirror", "page %.32s", event != NULL ? event : "?");
}

/* ---- the resident's own counters, read on a slow cadence -------------- */

/* Only what is logged is remembered, so a delta is a subtraction and not
   a second copy of the resident's bookkeeping. These are the resident's
   numbers surfaced, never recounted here. */
typedef struct {
    int seen;                          /* a block was found at all       */
    NowContentU32 active_a5;
    NowContentU32 active_mode;
    NowContentU32 hooked_ports;
    NowContentU32 installs, uninstalls, repairs;
    NowContentU32 skipped_ports, dropped;
    NowContentU32 refused_no_target, refused_wrong_context, refused_expired;
    NowContentU32 retires;
} MirrorContentSeen;

static MirrorContentSeen g_last;
static UInt32 g_next_poll;
static int g_polled_once;

/* NowQDStatus is a few hundred bytes and this is called from the event
   loop; static rather than automatic keeps it off the stack of a
   cooperatively scheduled application that also runs nested Toolbox
   loops. Single-threaded and task time, so a static is safe. */
static NowQDStatus g_status;

void now_mirror_log_idle(void)
{
    NowContentBlock *block;
    MirrorContentSeen now_seen;

    if (g_polled_once && (long)(TickCount() - g_next_poll) < 0) {
        return;
    }
    g_next_poll = TickCount() + kMirrorLogPollTicks;
    g_polled_once = 1;

    block = now_qdtrace_block();
    now_qdtrace_status(block, 0, &g_status);

    memset(&now_seen, 0, sizeof now_seen);
    now_seen.seen = (block != NULL && g_status.outcome == kNowQDDrainOk);
    if (now_seen.seen) {
        now_seen.active_a5 = g_status.active_a5;
        now_seen.active_mode = g_status.active_mode;
        now_seen.hooked_ports = g_status.hooked_ports;
        now_seen.installs = g_status.counters.installs;
        now_seen.uninstalls = g_status.counters.uninstalls;
        now_seen.repairs = g_status.counters.repairs;
        now_seen.skipped_ports = g_status.counters.skipped_ports;
        now_seen.dropped = g_status.counters.dropped;
        now_seen.refused_no_target = g_status.counters.refused_no_target;
        now_seen.refused_wrong_context = g_status.counters.refused_wrong_context;
        now_seen.refused_expired = g_status.counters.refused_expired;
        now_seen.retires = g_status.counters.retires;
    }

    if (now_seen.seen != g_last.seen) {
        now_log(kLogInfo, "mirror", "content plane block %s",
                now_seen.seen ? "present" : "gone");
    }
    if (!now_seen.seen) {
        g_last = now_seen;
        return;
    }

    /* What is hooked, and in whom. `active_a5` is the resident's own word
       for what actually happened, which is a different question from what
       was requested — a request the resident never honoured shows here as
       a zero that never moved. */
    if (now_seen.active_a5 != g_last.active_a5
        || now_seen.active_mode != g_last.active_mode
        || now_seen.hooked_ports != g_last.hooked_ports) {
        now_log(kLogInfo, "mirror",
                "content active a5 0x%lx mode %lu, %lu port(s) hooked",
                (unsigned long)now_seen.active_a5,
                (unsigned long)now_seen.active_mode,
                (unsigned long)now_seen.hooked_ports);
    }
    if (now_seen.installs != g_last.installs
        || now_seen.uninstalls != g_last.uninstalls
        || now_seen.repairs != g_last.repairs) {
        now_log(kLogInfo, "mirror",
                "content hooks +%lu in, +%lu out, +%lu repaired",
                (unsigned long)(now_seen.installs - g_last.installs),
                (unsigned long)(now_seen.uninstalls - g_last.uninstalls),
                (unsigned long)(now_seen.repairs - g_last.repairs));
    }
    /* The honesty counters. `skipped_ports` is the resident's word for a
       port it declined - not a colour port, already hooked, table full,
       or the application has its own procs - and it is counted rather
       than reported per port precisely because the decision is made
       inside a hook. */
    if (now_seen.skipped_ports != g_last.skipped_ports
        || now_seen.dropped != g_last.dropped) {
        now_log(kLogWarn, "mirror",
                "content skipped +%lu port(s), dropped +%lu record(s)",
                (unsigned long)(now_seen.skipped_ports - g_last.skipped_ports),
                (unsigned long)(now_seen.dropped - g_last.dropped));
    }
    if (now_seen.refused_no_target != g_last.refused_no_target
        || now_seen.refused_wrong_context != g_last.refused_wrong_context
        || now_seen.refused_expired != g_last.refused_expired
        || now_seen.retires != g_last.retires) {
        now_log(kLogWarn, "mirror",
                "content refused +%lu no-target +%lu wrong-a5 +%lu expired, "
                "+%lu retired",
                (unsigned long)(now_seen.refused_no_target
                                - g_last.refused_no_target),
                (unsigned long)(now_seen.refused_wrong_context
                                - g_last.refused_wrong_context),
                (unsigned long)(now_seen.refused_expired
                                - g_last.refused_expired),
                (unsigned long)(now_seen.retires - g_last.retires));
    }
    g_last = now_seen;
}

/* ---- teardown --------------------------------------------------------- */

void now_mirror_log_teardown(void)
{
    settle_flush_repeats();
    now_log(kLogInfo, "mirror",
            "teardown: session %lu, still requesting 0x%lx, %lu port(s) hooked",
            g_writer_session, g_requested,
            (unsigned long)g_last.hooked_ports);
    /* Flushed for the reason every teardown breadcrumb is: the stage a
       crash did not survive has to be on the platter before it. A launch
       whose log has no line above ended without this running at all. */
    now_log_flush();
}
