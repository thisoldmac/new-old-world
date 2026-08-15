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

#include "continuity_cursor.h"
#include "mirror_debug.h"
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
            int barrier;

            /* THE EDGE WAITS FOR ITS OWN POSITION. A round applies the
               position request above and then acts on it here, and until
               2026-08-15 those were adjacent instructions - so a release
               could be dispatched against the point the guest still
               believed in rather than the one just requested. The host had
               already done its half (settle to the press origin in its own
               packet, release in the next); the wire is a latest-state
               mailbox and both packets carried the SAME point, so nothing
               about packet ordering was ever the missing guarantee. This
               is. See now_continuity_button_barrier. */
            barrier = now_continuity_cursor_await_exposure(&exposure);
            /* One FILE-logged line per edge, naming applied against exposed:
               a metal round can then read whether the barrier held, how
               long, and whether it had to expire - which "the icon dropped
               in the wrong place" cannot distinguish on its own. */
            now_log(barrier == kNowContinuityBarrierExpired
                        ? kLogWarn : kLogInfo,
                    "mirror",
                    "button edge gen=%lu down=%lu applied=%ld,%ld "
                    "exposed=%ld,%ld waited=%lu %s",
                    (unsigned long)event_generation,
                    (unsigned long)event_down,
                    exposure.request_h, exposure.request_v,
                    exposure.observed_h, exposure.observed_v,
                    exposure.waited_ticks,
                    barrier == kNowContinuityBarrierExpired ? "expired"
                        : (exposure.waited_ticks != 0 ? "settled"
                                                      : "exposed"));

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
