/* Cooperative PPC -> resident 68K bridge for Continuity V4.

   V3 established this no-argument bridge for resident arbitration and
   native-input observation. V4 carries point and primary-button requests over
   the same table. The PPC side calls the bounded transitions from Apple's
   CursorDevicesGlue algorithm, publishes each result, then enters the resident
   once more to commit it. No resident entry reaches CDM.

   This uses the same dispatch shape already metal-proven by census_trap.c:
   a real kM68kISA|kOld68kRTA RoutineDescriptor, CallUniversalProc resolved
   from InterfaceLib because Carbon does not import it, and a variadic call.
   No arguments cross the ABI; the versioned shared cell is the whole seam. */
#include "continuity_service.h"

#include <Carbon.h>
#include <MixedMode.h>
#include <string.h>

#include "continuity_cursor.h"
#include "mirror_debug.h"
#include "peek.h"
#include "continuity_selection.h"
#include "now_continuity_logic.h"
#include "nowlog.h"

/* C-stack 68K procedure, no result and no parameters. */
#define kContinuityServiceProcInfo ((ProcInfoType)kCStackBased)

#define BUILD_M68K_RD(procInfo) {                                  \
        _MixedModeMagic, kRoutineDescriptorVersion,                 \
        kSelectorsAreNotIndexable, 0, 0, 0, 0,                      \
        { { (procInfo), 0, kM68kISA | kOld68kRTA,                   \
            kProcDescriptorIsAbsolute | kUseCurrentISA,             \
            (ProcPtr)0, 0, 0 } } }

typedef long (*CallUPPProc)(UniversalProcPtr, ProcInfoType, ...);

static RoutineDescriptor gServiceRD =
    BUILD_M68K_RD(kContinuityServiceProcInfo);
static CallUPPProc gCallUPP;
static NowPeekU32 gServiceProc;
static int gResolverState;             /* 0 unknown, 1 ready, -1 unavailable */
static NowPeekU32 gLastTraceSeq;
static int gInvoking;

enum { kNowContinuityServiceApplyRounds = 4 };

/* Who is ACTUALLY front when a synthetic press lands? The menu bar and the
   application switcher are drawn from layer state, and both have shown Finder
   frontmost through double clicks that failed - but a click is dispatched
   against the Process Manager's front process, which is the only answer that
   can disagree usefully. Task time, so the Process Manager is legal here, and
   one line per press, so the FILE logger can carry it; now_log_memory would
   keep this evidence out of every uploaded log. */
static void log_front_process_at_down(NowPeekU32 generation)
{
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str31 name;
    char text[32];
    OSErr err;
    short length;

    name[0] = 0;
    err = GetFrontProcess(&psn);
    if (err != noErr) {
        now_log(kLogWarn, "mirror", "front at down generation=%lu err=%d",
                (unsigned long)generation, (int)err);
        return;
    }
    info.processInfoLength = (long)sizeof(info);
    info.processName = name;
    info.processAppSpec = NULL;
    err = GetProcessInformation(&psn, &info);
    if (err != noErr) {
        now_log(kLogWarn, "mirror",
                "front at down generation=%lu psn=%lu err=%d",
                (unsigned long)generation, (unsigned long)psn.lowLongOfPSN,
                (int)err);
        return;
    }
    /* A Str31 body cannot exceed 31 bytes, but the length byte comes from
       another process's record - bound it before copying either way. */
    length = (short)name[0];
    if (length > 31)
        length = 31;
    BlockMoveData(&name[1], text, (Size)length);
    text[length] = '\0';
    /* The success line is a per-press trace, so it is debug tier; the two
       warn exits above stay unconditional because a press whose front
       process cannot be read is the failure this helper exists to name. */
    if (now_mirror_debug_on()) {
        now_log(kLogInfo, "mirror",
                "front at down generation=%lu psn=%lu name=%s",
                (unsigned long)generation, (unsigned long)psn.lowLongOfPSN,
                text);
    }
}

static void record_button_timing(NowPeekContinuityCell *cell,
                                 NowPeekU32 generation, NowPeekU32 down,
                                 NowPeekU32 begin, NowPeekU32 end,
                                 NowPeekI32 error)
{
    /* Rolling: keep the LAST capacity edges. The first-N choice predates
       rapid-click testing and hid exactly the late-epoch double-click
       attempts that mattered (count=8 dropped=20+ across the 2026-08-13
       22:3x runs, every interesting pair in the dropped tail). `dropped`
       now counts overwritten entries, and the teardown printer walks the
       ring from its oldest surviving slot. */
    NowPeekU32 index = cell->event_timing_count
        % (NowPeekU32)kNowPeekContinuityEventTimingCapacity;
    NowPeekContinuityEventTiming *entry;

    if (cell->event_timing_count
            >= (NowPeekU32)kNowPeekContinuityEventTimingCapacity)
        cell->event_timing_dropped++;
    entry = &cell->event_timing[index];
    entry->write_seq++;
    entry->generation = generation;
    entry->down = down;
    entry->request_h = cell->request_h;
    entry->request_v = cell->request_v;
    entry->arrival_ticks = cell->event_request_arrival_ticks;
    entry->exposure_ticks = cell->event_request_exposure_ticks;
    entry->manager_begin_ticks = begin;
    entry->manager_end_ticks = end;
    entry->manager_error = error;
    entry->event_when = 0;
    entry->event_observed_ticks = 0;
    entry->event_h = 0;
    entry->event_v = 0;
    entry->write_seq++;
    cell->event_timing_count++;
}

static int resolve_call_upp(void)
{
    CFragConnectionID conn = 0;
    Ptr main_addr = NULL;
    Str255 error_name;
    Str255 library_name;
    Str255 proc_name;
    Ptr address = NULL;
    CFragSymbolClass symbol_class;

    if (gResolverState != 0)
        return gResolverState == 1;
    gResolverState = -1;
    CopyCStringToPascal("InterfaceLib", library_name);
    if (GetSharedLibrary(library_name, kPowerPCCFragArch, kReferenceCFrag,
                         &conn, &main_addr, error_name) != noErr)
        return 0;
    CopyCStringToPascal("CallUniversalProc", proc_name);
    if (FindSymbol(conn, proc_name, &address, &symbol_class) != noErr)
        return 0;
    gCallUPP = (CallUPPProc)address;
    gResolverState = 1;
    return 1;
}

static int resident_ready(const NowPeekContinuityCell *cell)
{
    if (cell == NULL || cell->service_proc == 0 || !resolve_call_upp())
        return 0;
    if (gServiceProc != cell->service_proc) {
        gServiceProc = cell->service_proc;
        gServiceRD.routineRecords[0].procDescriptor =
            (ProcPtr)(unsigned long)gServiceProc;
    }
    return 1;
}

static int invoke_resident(const NowPeekContinuityCell *cell)
{
    if (!resident_ready(cell))
        return 0;
    (void)gCallUPP((UniversalProcPtr)&gServiceRD,
                   kContinuityServiceProcInfo);
    return 1;
}

static int trace_is_sampled(const NowPeekContinuityTraceEntry *entry)
{
    NowPeekU32 n;

    if (entry->event != (NowPeekU32)kNowPeekContinuityTraceRequest
            && entry->event != (NowPeekU32)kNowPeekContinuityTraceApplied)
        return entry->event
            != (NowPeekU32)kNowPeekContinuityTraceServiceEnter;
    n = (NowPeekU32)entry->arg0;
    return n <= 4u || n == 8u || n == 16u || n == 32u
        || (n % 30u) == 0;
}

static void drain_trace(const NowPeekContinuityCell *cell)
{
    NowPeekU32 newest = cell->trace_write_seq;
    NowPeekU32 available;
    NowPeekU32 first;
    NowPeekU32 seq;
    NowPeekU32 remaining;

    if (newest == 0 || newest == gLastTraceSeq)
        return;
    if (gLastTraceSeq == 0) {
        available = newest < (NowPeekU32)kNowPeekContinuityTraceCapacity
            ? newest : (NowPeekU32)kNowPeekContinuityTraceCapacity;
    } else {
        available = newest - gLastTraceSeq;
        /* The resident reserves zero as "no entry", so one arithmetic value
           is skipped when the sequence wraps. */
        if (newest < gLastTraceSeq)
            available--;
    }
    if (available > (NowPeekU32)kNowPeekContinuityTraceCapacity) {
        available = (NowPeekU32)kNowPeekContinuityTraceCapacity;
        if (gLastTraceSeq != 0) {
            now_log(kLogWarn, "mirror", "resident trace overrun old=%lu new=%lu",
                    (unsigned long)gLastTraceSeq, (unsigned long)newest);
        }
    }
    if (available == 0) {
        gLastTraceSeq = newest;
        return;
    }
    first = newest;
    for (remaining = 1; remaining < available; ++remaining) {
        first--;
        if (first == 0)
            first = 0xFFFFFFFFUL;
    }
    seq = first;
    for (remaining = available; remaining != 0; --remaining) {
        const NowPeekContinuityTraceEntry *entry =
            &cell->trace[(seq - 1u) % kNowPeekContinuityTraceCapacity];
        if (entry->seq != seq) {
            now_log(kLogWarn, "mirror", "resident trace torn wanted=%lu got=%lu",
                    (unsigned long)seq, (unsigned long)entry->seq);
            continue;
        }
        if (trace_is_sampled(entry)) {
            if (entry->event == kNowPeekContinuityTraceApplyError) {
                now_log(kLogError, "mirror",
                        "resident trace seq=%lu event=%lu ticks=%lu arg=%ld,%ld",
                        (unsigned long)entry->seq,
                        (unsigned long)entry->event,
                        (unsigned long)entry->ticks, (long)entry->arg0,
                        (long)entry->arg1);
            } else if (entry->event
                        == kNowPeekContinuityTraceKeyboardResult) {
                NowPeekU32 packed = (NowPeekU32)entry->arg1;
                /* A key that FAILED to apply is the product's story and
                   logs whatever the debug flag says; a key that worked is
                   a per-event trace. */
                if (now_mirror_debug_on()
                        || (packed & 0xFFFFu)
                            != (NowPeekU32)kNowPeekContinuityKeyErrorNone) {
                    now_log_memory(
                        (packed & 0xFFFFu) == kNowPeekContinuityKeyErrorNone
                            ? kLogInfo : kLogError,
                        "mirror",
                        "keyboard apply generation=%lu action=%lu error=%lu",
                        (unsigned long)(NowPeekU32)entry->arg0,
                        (unsigned long)((packed >> 16) & 0xFFFFu),
                        (unsigned long)(packed & 0xFFFFu));
                }
            } else if (entry->event
                        == kNowPeekContinuityTraceIdleSettle) {
                if (now_mirror_debug_on()) {
                    now_log(kLogInfo, "mirror",
                            "idle settle count=%lu max-gap=%lu ticks=%lu",
                                   (unsigned long)(NowPeekU32)entry->arg0,
                                   (unsigned long)(NowPeekU32)entry->arg1,
                                   (unsigned long)entry->ticks);
                }
            } else if (entry->event
                        == kNowPeekContinuityTraceEventObserved) {
                if (now_mirror_debug_on()) {
                    NowPeekU32 packed = (NowPeekU32)entry->arg0;
                    NowPeekU32 name = (NowPeekU32)entry->arg1;
                    char app[5];
                    int c;

                    app[0] = (char)((name >> 24) & 0xFFu);
                    app[1] = (char)((name >> 16) & 0xFFu);
                    app[2] = (char)((name >> 8) & 0xFFu);
                    app[3] = (char)(name & 0xFFu);
                    app[4] = '\0';
                    for (c = 0; c < 4; c++) {
                        if (app[c] < 0x20 || app[c] > 0x7E)
                            app[c] = '.';
                    }
                    now_log(kLogInfo, "mirror",
                            "synthetic event observed down=%lu "
                            "when-low=%lu ticks=%lu app=%s",
                                   (unsigned long)((packed >> 16) & 0xFFFFu),
                                   (unsigned long)(packed & 0xFFFFu),
                                   (unsigned long)entry->ticks, app);
                }
            } else if (now_mirror_debug_on()) {
                now_log_memory(kLogInfo, "mirror",
                               "resident trace seq=%lu event=%lu ticks=%lu arg=%ld,%ld",
                               (unsigned long)entry->seq,
                               (unsigned long)entry->event,
                               (unsigned long)entry->ticks, (long)entry->arg0,
                               (long)entry->arg1);
            }
        }
        seq++;
        if (seq == 0)
            seq = 1;
    }
    gLastTraceSeq = newest;
}

/* V14 drag observer drain. The resident sees drags from inside the
   dragging application; this is the only place that evidence can be got
   off the machine, so every line here is now_log and never
   now_log_memory - the crash-forensics buffer does not upload, and the
   last probe that forgot cost a full metal round (2026-08-13).

   TIERING. The lifecycle is ALWAYS ON: install state, a drag beginning,
   its identity, and its end. Those are four or five lines per gesture
   and they are the answer to the question this slice exists to ask. The
   per-sample ring is behind `mirrorlog`, because it is up to sixteen
   lines per drag and it is diagnosis rather than fact.

   THE NEGATIVE HAS ITS OWN LINE, and this is the point of the whole
   block. The Mac OS 9 Finder is a PowerPC application; whether its
   TrackDrag reaches the 68K trap table at all is what slice 1 measures.
   So the counters line prints whenever the install verdict or the first
   dispatch arrives, and it prints `dispatches` beside
   `trackdrag_entries` - "patched, and nothing came through" is a
   measurement, and it must not read the same as silence. */
static NowPeekU32 gLastDragInstall = 0xFFFFFFFFu;
static NowPeekU32 gLastDragSelftest = 0xFFFFFFFFu;
static NowPeekU32 gLastDragTracks = 0xFFFFFFFFu;
static NowPeekU32 gLastHandlerState = 0xFFFFFFFFu;
static NowPeekU32 gLastHandlerInstalls = 0xFFFFFFFFu;
static NowPeekU32 gLastHandlerCalls = 0xFFFFFFFFu;
static NowPeekU32 gLastHandlerRemoves = 0xFFFFFFFFu;
static NowPeekU32 gLastHandlerBegin = 0;
static NowPeekU32 gLastTracks = 0;
static NowPeekU32 gLastDragDispatches = 0;
static NowPeekU32 gLastDragBeginSeq = 0;
static NowPeekU32 gLastDragEndSeq = 0;
static NowPeekU32 gLastDragSamples = 0;

static const char *drag_item_status(NowPeekU32 status)
{
    switch (status) {
    case (NowPeekU32)kNowPeekDragObsItemHFS:     return "hfs";
    case (NowPeekU32)kNowPeekDragObsItemNoHFS:   return "no-hfs";
    case (NowPeekU32)kNowPeekDragObsItemPromise: return "promise";
    case (NowPeekU32)kNowPeekDragObsItemError:   return "error";
    default:                                     return "unknown";
    }
}

/* Lift one whole V15 identity record out of the cell. `handler_begin_seq`
   is odd while the resident is writing the record and bumped LAST when it
   is whole, so an odd read is a torn record and refuses rather than
   handing back half an identity. Read twice around the copy for the same
   reason: the resident writes from a foreign context and this is task
   time, not a critical section. */
static int read_drag_identity(const NowPeekDragObserve *obs,
                              NowContinuityDragIdentity *out)
{
    NowPeekU32 before = obs->handler_begin_seq;
    unsigned len;

    if (before == 0 || (before & 1u) != 0)
        return 0;
    memset(out, 0, sizeof *out);
    out->is_hfs = (obs->hitem_status == (NowPeekU32)kNowPeekDragObsItemHFS);
    out->vref = (short)obs->hfile_vrefnum;
    out->parid = (long)obs->hfile_parid;
    len = (unsigned)obs->hfile_name[0];
    if (len > 63u)
        return 0;
    BlockMoveData(obs->hfile_name, out->name, (long)len + 1);
    if (obs->handler_begin_seq != before)
        return 0;
    out->seq = (unsigned long)before;
    return 1;
}

int now_continuity_drag_identity(NowContinuityDragIdentity *out)
{
    const NowPeekTable *table = now_peek_table();

    if (out == NULL)
        return 0;
    if (table == NULL
            || table->magic != (NowPeekU32)kNowPeekTableMagic
            || table->length
                < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                               + sizeof(NowPeekContinuityCell))
            || table->continuity_format
                != (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT)
        return 0;
    return read_drag_identity(&table->continuity.drag_observe, out);
}

static void drain_drag_observe(const NowPeekContinuityCell *cell)
{
    const NowPeekDragObserve *obs = &cell->drag_observe;
    NowPeekU32 begin_seq = obs->begin_seq;
    NowPeekU32 end_seq = obs->end_seq;

    /* The instrument's own state, before any drag. Printed when the
       verdict changes and when the very first Drag Manager call of the
       machine's life comes through, so "installed and never called" is
       something a reader is told rather than something they infer from
       an absence of drag lines. */
    /* Printed on any state change AND on any new Drag Manager traffic
       while the gate is on. The 0 -> nonzero edge alone was not enough:
       the emulator round of 2026-08-16 could show that the FIRST two
       dispatches were the control's own and could not show whether any
       arrived later, which is the same counter being asked two
       questions. `trackdrag_entries` is included because a drag is what
       the whole plane is for and its arrival must never be a silence. */
    if (obs->install_state != gLastDragInstall
            || obs->selftest_state != gLastDragSelftest
            || obs->trackdrag_entries != gLastDragTracks
            || (obs->dispatches != 0 && gLastDragDispatches == 0)
            || (now_mirror_debug_on()
                && obs->dispatches != gLastDragDispatches)) {
        now_log(kLogInfo, "mirror",
                "drag obs install=%lu passes=%lu disp=%lu track=%lu "
                "ret=%lu reent=%lu control=%lu/%lu err=%ld",
                (unsigned long)obs->install_state,
                (unsigned long)obs->install_passes,
                (unsigned long)obs->dispatches,
                (unsigned long)obs->trackdrag_entries,
                (unsigned long)obs->trackdrag_returns,
                (unsigned long)obs->reentries,
                (unsigned long)obs->selftest_state,
                (unsigned long)obs->selftest_seen,
                (long)obs->selftest_err);
        gLastDragInstall = obs->install_state;
        gLastDragSelftest = obs->selftest_state;
        gLastDragTracks = obs->trackdrag_entries;
    }
    gLastDragDispatches = obs->dispatches;

    if (begin_seq != gLastDragBeginSeq) {
        /* Odd means the resident is mid-write; leave the baseline alone
           and read it whole on the next pass. */
        if ((begin_seq & 1u) == 0) {
            char name[64];
            unsigned len = (unsigned)obs->file_name[0];
            unsigned i;

            if (len > 62u)
                len = 62u;
            for (i = 0; i < len; ++i) {
                unsigned char c = obs->file_name[i + 1u];

                name[i] = (c < 0x20u || c > 0x7Eu) ? '.' : (char)c;
            }
            name[len] = '\0';
            now_log(kLogInfo, "mirror",
                    "drag begin seq=%lu tk=%lu a5=%08lx ref=%08lx "
                    "at=%ld,%ld org=%ld,%ld attr=%lx mod=%04lx",
                    (unsigned long)begin_seq,
                    (unsigned long)obs->begin_ticks,
                    (unsigned long)obs->entry_a5,
                    (unsigned long)obs->drag_ref,
                    (long)obs->event_where_h, (long)obs->event_where_v,
                    (long)obs->origin_h, (long)obs->origin_v,
                    (unsigned long)obs->entry_attributes,
                    (unsigned long)obs->event_modifiers);
            /* The identity, from the drag reference itself. No selection
               was consulted anywhere to produce this line - that is the
               whole reason the plane exists. `items` is the honest count
               and `what` describes ITEM ONE only; an over-count is
               visible as items>1 rather than folded into the name. */
            now_log(kLogInfo, "mirror",
                    "drag item seq=%lu items=%lu what=%s err=%ld "
                    "type=%08lx cr=%08lx vref=%ld par=%lu name=%s",
                    (unsigned long)begin_seq,
                    (unsigned long)obs->item_count,
                    drag_item_status(obs->item_status),
                    (long)obs->item_err,
                    (unsigned long)obs->file_type,
                    (unsigned long)obs->file_creator,
                    (long)obs->file_vrefnum,
                    (unsigned long)obs->file_parid, name);
            gLastDragBeginSeq = begin_seq;
            gLastDragSamples = 0;
        }
    }

    /* The sample ring: what the Drag Manager believes against what we are
       driving. Debug tier - this is the diagnosis behind the fact. */
    if (now_mirror_debug_on() && obs->sample_count != gLastDragSamples) {
        NowPeekU32 total = obs->sample_count;
        NowPeekU32 fresh;
        NowPeekU32 n;

        if (total < gLastDragSamples)
            gLastDragSamples = 0;            /* a new drag reset the ring */
        fresh = total - gLastDragSamples;
        if (fresh > (NowPeekU32)kNowPeekDragObsSampleCapacity)
            fresh = (NowPeekU32)kNowPeekDragObsSampleCapacity;
        for (n = total - fresh; n != total; ++n) {
            const NowPeekDragObsSample *s =
                &obs->samples[n % (NowPeekU32)kNowPeekDragObsSampleCapacity];

            now_log(kLogInfo, "mirror",
                    "drag look n=%lu sel=%lu tk=%lu dm=%ld,%ld "
                    "pin=%ld,%ld raw=%ld,%ld lm=%ld,%ld attr=%lx err=%ld",
                    (unsigned long)(n + 1u), (unsigned long)s->selector,
                    (unsigned long)s->ticks,
                    (long)s->dm_mouse_h, (long)s->dm_mouse_v,
                    (long)s->dm_pinned_h, (long)s->dm_pinned_v,
                    (long)s->lm_raw_h, (long)s->lm_raw_v,
                    (long)s->lm_mouse_h, (long)s->lm_mouse_v,
                    (unsigned long)s->attributes, (long)s->err);
        }
        gLastDragSamples = total;
    }

    /* ---- V15, the registration route -------------------------------
       Its counters are printed on ANY change, always on. `installs`
       without `calls` is the registration route failing the same way
       the trap route did, and that sentence has to be sayable. */
    if (obs->handler_state != gLastHandlerState
            || obs->handler_installs != gLastHandlerInstalls
            || obs->handler_calls != gLastHandlerCalls
            || obs->handler_removes != gLastHandlerRemoves) {
        now_log(kLogInfo, "mirror",
                "drag handler state=%lu err=%ld inst=%lu rem=%lu ctx=%lu "
                "calls=%lu enter=%lu/%lu in=%lu leave=%lu/%lu reent=%lu",
                (unsigned long)obs->handler_state,
                (long)obs->handler_err,
                (unsigned long)obs->handler_installs,
                (unsigned long)obs->handler_removes,
                (unsigned long)obs->handler_contexts,
                (unsigned long)obs->handler_calls,
                (unsigned long)obs->handler_enter_handler,
                (unsigned long)obs->handler_enter_window,
                (unsigned long)obs->handler_in_window,
                (unsigned long)obs->handler_leave_window,
                (unsigned long)obs->handler_leave_handler,
                (unsigned long)obs->handler_reentries);
        /* V16. WHICH applications hold a registration, printed with the
           counters rather than behind a debug gate: on 2026-08-16 the
           count alone could not distinguish "the route never registers in
           the Finder" from "the Finder was not pumping", and those are
           opposite findings. One line per row, because the name is the
           half that answers it and kLogLineMax is 120. */
        {
            NowPeekU32 rows = obs->reg_count;
            NowPeekU32 n;

            if (rows > (NowPeekU32)kNowPeekDragObsRegCapacity)
                rows = (NowPeekU32)kNowPeekDragObsRegCapacity;
            for (n = 0; n < rows; ++n) {
                const NowPeekDragObsReg *reg = &obs->regs[n];
                char rname[32];
                unsigned len = (unsigned)reg->name[0];
                unsigned i;

                if (len > 30u)
                    len = 30u;
                for (i = 0; i < len; ++i) {
                    unsigned char c = reg->name[i + 1u];

                    rname[i] = (c < 0x20u || c > 0x7Eu) ? '.' : (char)c;
                }
                rname[len] = '\0';
                now_log(kLogInfo, "mirror",
                        "drag handler reg n=%lu/%lu a5=%08lx tk=%lu app=%s",
                        (unsigned long)(n + 1u),
                        (unsigned long)obs->reg_count,
                        (unsigned long)reg->a5,
                        (unsigned long)reg->ticks, rname);
            }
        }
        gLastHandlerState = obs->handler_state;
        gLastHandlerInstalls = obs->handler_installs;
        gLastHandlerCalls = obs->handler_calls;
        gLastHandlerRemoves = obs->handler_removes;
    }

    if (obs->handler_begin_seq != gLastHandlerBegin
            && (obs->handler_begin_seq & 1u) == 0) {
        char hname[64];
        unsigned len = (unsigned)obs->hfile_name[0];
        unsigned i;

        if (len > 62u)
            len = 62u;
        for (i = 0; i < len; ++i) {
            unsigned char c = obs->hfile_name[i + 1u];

            hname[i] = (c < 0x20u || c > 0x7Eu) ? '.' : (char)c;
        }
        hname[len] = '\0';
        /* THE IDENTITY, from a live DragRef the Drag Manager handed us,
           with no selection consulted anywhere. */
        /* TWO lines because kLogLineMax is 120 and the NAME is the half
           that matters - the first emulator round of this route printed
           a complete, correct identity and cut it off two characters
           into the creator code. The click probe already splits for
           exactly this reason. */
        now_log(kLogInfo, "mirror",
                "drag handler item seq=%lu a5=%08lx ref=%08lx tk=%lu "
                "items=%lu what=%s err=%ld",
                (unsigned long)obs->handler_begin_seq,
                (unsigned long)obs->handler_a5,
                (unsigned long)obs->handler_drag_ref,
                (unsigned long)obs->handler_first_ticks,
                (unsigned long)obs->hitem_count,
                drag_item_status(obs->hitem_status),
                (long)obs->hitem_err);
        now_log(kLogInfo, "mirror",
                "drag handler file seq=%lu type=%08lx cr=%08lx "
                "vref=%ld par=%lu name=%s",
                (unsigned long)obs->handler_begin_seq,
                (unsigned long)obs->hfile_type,
                (unsigned long)obs->hfile_creator,
                (long)obs->hfile_vrefnum,
                (unsigned long)obs->hfile_parid, hname);
        /* FROM DIAGNOSTIC TO PRODUCT STATE. Slice 1B stopped at the two
           lines above; this is the same record becoming a generation the
           host may bind. Only an HFS first item qualifies - a text drag
           or a promise names no file this side could serve, and the
           publish must not invent one.

           THE LATENCY IS MEASURED HERE RATHER THAN ASSERTED. `tk` is the
           resident's TickCount at EnterHandler and this is task time in
           the application, so the difference is exactly the interval the
           whole route depends on fitting inside a gesture: the person is
           still dragging toward the edge, and the cross is seconds
           away. */
        if (obs->hitem_status == (NowPeekU32)kNowPeekDragObsItemHFS) {
            NowContinuityDragIdentity ident;

            if (read_drag_identity(obs, &ident)
                    && now_continuity_selection_note_drag(&ident)) {
                now_log(kLogInfo, "mirror",
                        "drag bind seq=%lu latency=%lu ticks name=%s",
                        ident.seq,
                        (unsigned long)((NowPeekU32)TickCount()
                                        - obs->handler_first_ticks),
                        hname);
            }
        }
        gLastHandlerBegin = obs->handler_begin_seq;
        gLastTracks = 0;
    }

    /* THE TARGETING STREAM. What window the Drag Manager believes the
       drag is over, beside the point this resident is driving, at the
       instant it believed it. This is slice 3's question and it is
       always on rather than debug tier - it is the whole reason the
       route was tried. */
    if (obs->track_count != gLastTracks) {
        NowPeekU32 total = obs->track_count;
        NowPeekU32 fresh;
        NowPeekU32 n;

        if (total < gLastTracks)
            gLastTracks = 0;
        fresh = total - gLastTracks;
        if (fresh > (NowPeekU32)kNowPeekDragObsTrackCapacity)
            fresh = (NowPeekU32)kNowPeekDragObsTrackCapacity;
        for (n = total - fresh; n != total; ++n) {
            const NowPeekDragObsTrack *t =
                &obs->tracks[n % (NowPeekU32)kNowPeekDragObsTrackCapacity];

            now_log(kLogInfo, "mirror",
                    "drag track n=%lu msg=%lu win=%08lx tk=%lu "
                    "dm=%ld,%ld pin=%ld,%ld raw=%ld,%ld lm=%ld,%ld "
                    "attr=%lx err=%ld",
                    (unsigned long)(n + 1u), (unsigned long)t->message,
                    (unsigned long)t->window, (unsigned long)t->ticks,
                    (long)t->dm_mouse_h, (long)t->dm_mouse_v,
                    (long)t->dm_pinned_h, (long)t->dm_pinned_v,
                    (long)t->lm_raw_h, (long)t->lm_raw_v,
                    (long)t->lm_mouse_h, (long)t->lm_mouse_v,
                    (unsigned long)t->attributes, (long)t->err);
        }
        gLastTracks = total;
    }

    if (end_seq != gLastDragEndSeq && (end_seq & 1u) == 0) {
        now_log(kLogInfo, "mirror",
                "drag end seq=%lu err=%ld tk=%lu elapsed=%lu "
                "final=%ld,%ld looks=%lu dropped=%lu",
                (unsigned long)end_seq, (long)obs->result,
                (unsigned long)obs->end_ticks,
                (unsigned long)(obs->end_ticks - obs->begin_ticks),
                (long)obs->final_h, (long)obs->final_v,
                (unsigned long)obs->sample_count,
                (unsigned long)obs->sample_dropped);
        gLastDragEndSeq = end_seq;
    }
}

/* WHERE THIS IS DRAINED FROM, and why it is not the Continuity service.
   `now_continuity_service_invoke` only runs while an EPOCH runs, and a
   drag observed by the resident has nothing to do with whether a host is
   driving: the act plane arms the observer too, and the first emulator
   round drained nothing at all for exactly this reason. So the entry
   point is the Mirror's slow idle observer in main.c - which exists to
   read counters the resident bumped inside foreign processes and write
   only what changed, at task time rather than in a hook, which is this
   drain's own description word for word. */
void now_continuity_drag_observe_idle(void)
{
    const NowPeekTable *table = now_peek_table();

    if (table == NULL
            || table->magic != (NowPeekU32)kNowPeekTableMagic
            || table->length
                < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                               + sizeof(NowPeekContinuityCell))
            || table->continuity_format
                != (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT)
        return;
    drain_drag_observe(&table->continuity);
}

/* V11 deep click probe drain. Uploadable evidence, so now_log and never
   now_log_memory - this ring exists to be diffed off-machine, and the last
   probe that printed to the crash-forensics buffer cost a full metal round
   before anyone noticed the log it fed never uploads (2026-08-13).
   The ring is rolling; total count drives the window, and anything the
   drain arrived too late for is COUNTED rather than silently absent. Two
   lines per entry because kLogLineMax is 120. */
static NowPeekU32 gLastClickProbeCount = 0;

static void drain_click_probe(NowPeekContinuityCell *cell)
{
    NowPeekU32 total = cell->click_probe_count;
    NowPeekU32 fresh;
    NowPeekU32 n;

    /* The cell can reset underneath an armed drain, and the unsigned
       subtraction below then reads the reset as four billion fresh entries:
       2026-08-14 printed ~23 all-zero rows at n=4294967273 before anyone
       could tell that from a real overrun. Re-baseline out loud instead. */
    if (total < gLastClickProbeCount) {
        now_log(kLogWarn, "mirror", "click probe reset total=%lu last=%lu",
                (unsigned long)total, (unsigned long)gLastClickProbeCount);
        gLastClickProbeCount = total;
        if (total == 0)
            return;
    }
    if (total == gLastClickProbeCount)
        return;
    fresh = total - gLastClickProbeCount;
    if (fresh > (NowPeekU32)kNowPeekContinuityClickProbeCapacity) {
        NowPeekU32 missed = fresh
            - (NowPeekU32)kNowPeekContinuityClickProbeCapacity;

        cell->click_probe_overwritten += missed;
        now_log(kLogWarn, "mirror",
                "click probe overran drain missed=%lu total=%lu",
                (unsigned long)missed, (unsigned long)total);
        fresh = (NowPeekU32)kNowPeekContinuityClickProbeCapacity;
    }
    for (n = total - fresh; n != total; ++n) {
        NowPeekContinuityClickProbe snap;
        const NowPeekContinuityClickProbe *slot =
            &cell->click_probe[n
                % (NowPeekU32)kNowPeekContinuityClickProbeCapacity];
        NowPeekU32 before = slot->write_seq;
        char app[5];
        int c;

        snap = *slot;
        if ((before & 1u) != 0 || slot->write_seq != before) {
            now_log(kLogWarn, "mirror", "click probe torn n=%lu",
                    (unsigned long)(n + 1u));
            continue;
        }
        app[0] = (char)((snap.observer >> 24) & 0xFFu);
        app[1] = (char)((snap.observer >> 16) & 0xFFu);
        app[2] = (char)((snap.observer >> 8) & 0xFFu);
        app[3] = (char)(snap.observer & 0xFFu);
        app[4] = '\0';
        for (c = 0; c < 4; c++) {
            if (app[c] < 0x20 || app[c] > 0x7E)
                app[c] = '.';
        }
        now_log(kLogInfo, "mirror",
                "click probe n=%lu st=%lu tk=%lu what=%lu when=%lu "
                "at=%ld,%ld mod=%04lx app=%s",
                (unsigned long)(n + 1u), (unsigned long)snap.cell_state,
                (unsigned long)snap.ticks, (unsigned long)snap.what,
                (unsigned long)snap.when,
                (long)snap.where_h, (long)snap.where_v,
                (unsigned long)snap.modifiers, app);
        now_log(kLogInfo, "mirror",
                "click probe n=%lu msg=%08lx mb=%02lx mbt=%lu m=%ld,%ld "
                "r=%ld,%ld t=%ld,%ld dbl=%lu q=%lu/%lu",
                (unsigned long)(n + 1u), (unsigned long)snap.message,
                (unsigned long)snap.mb_state, (unsigned long)snap.mb_ticks,
                (long)snap.mouse_h, (long)snap.mouse_v,
                (long)snap.raw_h, (long)snap.raw_v,
                (long)snap.temp_h, (long)snap.temp_v,
                (unsigned long)snap.double_time,
                (unsigned long)snap.queue_mouse_depth,
                (unsigned long)snap.queue_next_when);
    }
    gLastClickProbeCount = total;
}

int now_continuity_service_ready(const NowPeekContinuityCell *cell)
{
    return resident_ready(cell) && now_continuity_cursor_ready();
}

int now_continuity_service_invoke(NowPeekContinuityCell *cell)
{
    NowPeekU32 status_seq;
    NowPeekU32 request_seq;
    NowPeekU32 event_generation;
    NowPeekU32 event_down;
    NowPeekI32 h;
    NowPeekI32 v;
    long err;
    int published_result;
    int round;

    if (cell == NULL || gInvoking)
        return cell != NULL;
    gInvoking = 1;
    /* A dead epoch must not leave the manager ledger asserting a phantom
       hold: the Cursor Device record is upstream of low memory and keeps
       republishing MBState down until real input rewrites it. This is the
       first task time after any exit path, including lease death with no
       re-arm. No-op while the epoch is live or the ledger is balanced. */
    if (cell->state != (NowPeekU32)kNowPeekContinuityStateActive)
        (void)now_continuity_cursor_ensure_released("inactive");
    for (round = 0; round < kNowContinuityServiceApplyRounds; ++round) {
        if (!invoke_resident(cell)) {
            gInvoking = 0;
            return 0;
        }
        drain_trace(cell);
        drain_click_probe(cell);
        status_seq = cell->status_seq;
        if ((status_seq & 1u) != 0)
            break;
        request_seq = cell->request_position_seq;
        h = cell->request_h;
        v = cell->request_v;
        event_generation = cell->event_request_generation;
        event_down = cell->event_request_down;
        if (status_seq != cell->status_seq)
            break;

        published_result = 0;
        if (cell->enabled
                && cell->state == (NowPeekU32)kNowPeekContinuityStateActive
                && request_seq != 0
                && now_continuity_sequence_newer(
                    request_seq, cell->apply_result_seq)) {
            err = now_continuity_cursor_move((unsigned long)cell->epoch,
                                             (unsigned long)request_seq,
                                             (long)h, (long)v);
            cell->apply_result_err = (NowPeekI32)err;
            cell->apply_result_seq = request_seq; /* publish result last */
            published_result = 1;
        }

        /* One resident commit can expose the next edge in the same ordered
           packet: applying the preceding up releases its deferred down. Keep
           draining this synchronous task-time handshake until it is quiet. */
        if (event_generation != 0
                && (event_generation != cell->event_result_generation
                    || event_down != cell->event_result_down)) {
            NowPeekU32 manager_begin;
            NowPeekU32 manager_end;
            NowContinuityCursorExposure exposure;
            NowContinuityCursorDiagnostics applied;
            int barrier;

            /* THE EDGE'S OWN POSITION, RECONCILED FIRST. The apply above is
               gated on an ACTIVE epoch, and the cross-edge handoff ends the
               epoch in the same breath as the release it settles - so on
               precisely the path the barrier exists for, the settled point
               never reaches the Cursor Device and this side's last applied
               point stays where the target's drag loop starved it. The
               resident has already put low memory on the settled point; the
               Cursor Device record is UPSTREAM of low memory, so leaving it
               stale is not a wrong reading but a pending re-assertion, and
               the barrier below would then hold this edge against a point
               nothing will ever return to (metal 2026-08-15: applied=501,446
               against an exposed 504,451 that was the host's settled origin
               exactly, expiring the full 30-tick bound). Deliberately outside
               the resident's request/result handshake: it publishes no
               apply_result, because the resident commits only the exact
               request it published and this reconcile has no sequence of its
               own. See now_continuity_settle_before_edge. */
            now_continuity_cursor_diagnostics(&applied);
            if (now_continuity_settle_before_edge(
                    cell->exit_reason, 1,
                    request_seq != 0 || cell->applied_position_seq != 0,
                    applied.requested_valid,
                    h, v,
                    (NowPeekI32)applied.requested_h,
                    (NowPeekI32)applied.requested_v)) {
                long settle_err = now_continuity_cursor_move(
                    (unsigned long)cell->epoch,
                    (unsigned long)request_seq, (long)h, (long)v);
                now_log(settle_err == 0 ? kLogInfo : kLogWarn, "mirror",
                        "button edge settle gen=%lu at=%ld,%ld from=%ld,%ld "
                        "state=%lu reason=%lu err=%ld",
                        (unsigned long)event_generation, (long)h, (long)v,
                        applied.requested_valid ? applied.requested_h : -1,
                        applied.requested_valid ? applied.requested_v : -1,
                        (unsigned long)cell->state,
                        (unsigned long)cell->exit_reason, settle_err);
            }

            /* THE EDGE WAITS FOR ITS OWN POSITION. A round applies the
               position request above and then acts on it here, and until
               2026-08-15 those were adjacent instructions - so a release
               could be dispatched against the point the guest still
               believed in rather than the one just requested. The host had
               already done its half (settle to the press origin in its own
               packet, release in the next); the wire is a latest-state
               mailbox and both packets carried the SAME point, so nothing
               about packet ordering was ever the missing guarantee. This
               is. See now_continuity_button_barrier.

               A release (event_down == 0) waits against the longer
               kNowContinuityExposureDeadlineTicksRelease bound: it follows
               a settle inside the guest's own drag loop, where correctness
               is a real file's location, not feel. An ordinary press keeps
               the tight kNowContinuityExposureDeadlineTicksPress bound. See
               now_continuity_logic.h for the argument and
               now_continuity_cursor_await_exposure for the worst-case
               spin cost of each. */
            /* Re-read: the barrier's target is the edge's own point, and
               this side may only WAIT for it while it genuinely holds it.
               A settle suppressed because the human's own hand ended the
               epoch leaves the target unheld, and the honest answer there
               is unaskable rather than half a second of spinning against a
               point nothing is moving toward. A REFUSED manager move is
               not distinguished here: `requested_*` has always meant what
               this side asked for, the refusal logs its own error line, and
               teaching this read to second-guess it would put two meanings
               on one field. */
            now_continuity_cursor_diagnostics(&applied);
            barrier = now_continuity_cursor_await_exposure(&exposure,
                event_down == 0,
                applied.requested_valid
                    && applied.requested_h == (long)h
                    && applied.requested_v == (long)v,
                (long)h, (long)v);
            /* One FILE-logged line per edge, naming applied against exposed:
               a metal round can then read whether the barrier held, how
               long, and whether it had to expire - which "the icon dropped
               in the wrong place" cannot distinguish on its own. The
               deadline rides along so an `expired` line names the bound it
               was measured against without a reader needing to know which
               edge type maps to which constant. `applied` always names a
               point this side really applied - on an `unheld` line that is
               the last one, not the edge's, because a field called applied
               must never print a point nobody applied. */
            now_log(barrier == kNowContinuityBarrierExpired
                        ? kLogWarn : kLogInfo,
                    "mirror",
                    "button edge gen=%lu down=%lu applied=%ld,%ld "
                    "exposed=%ld,%ld via=%s waited=%lu deadline=%lu %s",
                    (unsigned long)event_generation,
                    (unsigned long)event_down,
                    exposure.request_valid ? exposure.request_h
                        : (applied.requested_valid ? applied.requested_h : -1),
                    exposure.request_valid ? exposure.request_v
                        : (applied.requested_valid ? applied.requested_v : -1),
                    exposure.observed_h, exposure.observed_v,
                    exposure.observed_is_record ? "record" : "global",
                    exposure.waited_ticks,
                    exposure.deadline_ticks,
                    barrier == kNowContinuityBarrierExpired ? "expired"
                        : (!exposure.request_valid ? "unheld"
                        : (exposure.waited_ticks != 0 ? "settled"
                                                      : "exposed")));

            /* The manager call runs BETWEEN resident invokes, where status_seq
               is even, so the resident's mid-invoke guard cannot see it at all.
               This flag is what the interrupt-press delivery checks before it
               cancels an exposed request - without it, a delivery can retract
               an edge this side has already read and is a few instructions
               from serving. Set it first, then re-read the request: whichever
               of the two wins the race, both sides now know it happened. */
            cell->button_manager_busy = 1;
            if (cell->event_request_generation != event_generation
                    || cell->event_request_down != event_down) {
                /* The delivery got there first. Serving the snapshot now would
                   drive the manager for an edge nobody is waiting on, so leave
                   this round unpublished and read the new request on the next
                   resident invoke. */
                cell->button_manager_busy = 0;
            } else {
                manager_begin = (NowPeekU32)TickCount();
                err = now_continuity_cursor_button(
                    (unsigned long)cell->epoch,
                    (unsigned long)event_generation, event_down != 0);
                manager_end = (NowPeekU32)TickCount();
                record_button_timing(cell, event_generation, event_down,
                                     manager_begin, manager_end,
                                     (NowPeekI32)err);
                if (event_down != 0 && err == noErr)
                    log_front_process_at_down(event_generation);
                /* The resident's interrupt-time release flips MBState before
                   this manager call runs, so CursorDeviceButtonUp sees no
                   transition and posts nothing: across every logged run, no
                   synthetic mouseUp event has ever entered the queue
                   (event=0 on all up rows). A target that pairs a down
                   against the last mouseUp EVENT can therefore never see a
                   double click, whatever the recognition window. Complete
                   the stream here, in ordinary task time. The queue element
                   takes its point from the mouse global, which the resident's
                   tracking completion has already settled to the release
                   point. PostEvent is CarbonLib 1.0+; the jGNE observer will
                   now record these ups, which is also the proof they landed. */
                if (event_down == 0 && err == noErr)
                    (void)PostEvent(mouseUp, 0);
                cell->event_result_down = event_down;
                cell->event_result_err = (NowPeekI32)err;
                cell->event_result_generation = event_generation;
                /* Published; the delivery is free to cancel from here. */
                cell->button_manager_busy = 0;
                published_result = 1;
            }
        }
        if (!published_result)
            break;
    }
    /* Every application result needs one resident entry that commits it. A
       fourth result is already abnormal, but still settle it before returning
       rather than leaving the manager and wire acknowledgement divergent. */
    if (round == kNowContinuityServiceApplyRounds) {
        if (!invoke_resident(cell)) {
            gInvoking = 0;
            return 0;
        }
        drain_trace(cell);
        drain_click_probe(cell);
    }
    gInvoking = 0;
    return 1;
}

void now_continuity_service_begin_epoch(unsigned long epoch)
{
    now_continuity_cursor_begin_epoch(epoch);
}

void now_continuity_service_shutdown(void)
{
    now_continuity_cursor_shutdown();
}
