/* Cooperative PPC -> resident 68K bridge for Continuity V2.

   V3 keeps this no-argument bridge for resident arbitration and native-input
   observation only. The resident publishes a point and returns; the PPC side
   calls the bounded PPC transition from Apple's CursorDevicesGlue algorithm,
   publishes the result, then enters the resident once more to commit it. No
   resident entry reaches CDM.

   This uses the same dispatch shape already metal-proven by census_trap.c:
   a real kM68kISA|kOld68kRTA RoutineDescriptor, CallUniversalProc resolved
   from InterfaceLib because Carbon does not import it, and a variadic call.
   No arguments cross the ABI; the versioned shared cell is the whole seam. */
#include "continuity_service.h"

#include <Carbon.h>
#include <MixedMode.h>

#include "continuity_cursor.h"
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
            now_log(entry->event == kNowPeekContinuityTraceApplyError
                        ? kLogError : kLogInfo,
                    "mirror", "resident trace seq=%lu event=%lu ticks=%lu arg=%ld,%ld",
                    (unsigned long)entry->seq, (unsigned long)entry->event,
                    (unsigned long)entry->ticks, (long)entry->arg0,
                    (long)entry->arg1);
        }
        seq++;
        if (seq == 0)
            seq = 1;
    }
    gLastTraceSeq = newest;
}

int now_continuity_service_ready(const NowPeekContinuityCell *cell)
{
    return resident_ready(cell) && now_continuity_cursor_ready();
}

int now_continuity_service_invoke(NowPeekContinuityCell *cell)
{
    NowPeekU32 status_seq;
    NowPeekU32 request_seq;
    NowPeekI32 h;
    NowPeekI32 v;
    long err;

    if (cell == NULL || gInvoking)
        return cell != NULL;
    gInvoking = 1;
    if (!invoke_resident(cell)) {
        gInvoking = 0;
        return 0;
    }
    drain_trace(cell);
    status_seq = cell->status_seq;
    if ((status_seq & 1u) != 0
            || !cell->enabled
            || cell->state != (NowPeekU32)kNowPeekContinuityStateActive) {
        gInvoking = 0;
        return 1;
    }
    request_seq = cell->request_position_seq;
    h = cell->request_h;
    v = cell->request_v;
    if (status_seq != cell->status_seq
            || request_seq == 0
            || !now_continuity_sequence_newer(request_seq,
                                               cell->apply_result_seq)) {
        gInvoking = 0;
        return 1;
    }
    err = now_continuity_cursor_move((unsigned long)cell->epoch,
                                     (unsigned long)request_seq,
                                     (long)h, (long)v);
    cell->apply_result_err = (NowPeekI32)err;
    cell->apply_result_seq = request_seq;        /* publish result last */
    if (!invoke_resident(cell)) {
        gInvoking = 0;
        return 0;
    }
    drain_trace(cell);
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
