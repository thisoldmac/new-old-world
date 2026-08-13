/* ADB relative-device observer and opt-in injection spike for Continuity.

   The ADB Manager enters a device service routine at interrupt time, using a
   register ABI rather than an ordinary C call. now_ext_adb_observer.S owns
   that seam and calls the two bounded functions below around the incumbent
   handler. Passive mode leaves the packet, original data-area pointer, and
   original handler unchanged. The opt-in V7 experiment may rewrite only a
   standard two-byte register-0 packet before the incumbent sees it.

   Installation is lazy because SetADBInfo is a manager call and belongs in
   the PPC application's synchronous resident service, never an INIT-time or
   interrupt path. Unlinking is deliberately absent: another extension may
   have chained behind this handler, so recording stops while the transparent
   wrapper remains installed until reboot. */
#include "now_ext_adb_observer.h"

#include <DeskBus.h>
#include <LowMem.h>
#include <MacTypes.h>

#include <string.h>

#include "now_adb_injection_logic.h"
extern void now_ext_adb_observer_entry(void);

/* The assembly shim reads this symbol after restoring the interrupted ADB
   register frame. It must retain external linkage and the manager's exact
   routine-pointer type. */
ADBServiceRoutineUPP gNowADBObserverOriginalHandler;

static NowPeekContinuityCell *gCell;
static Ptr gOriginalDataArea;
static ADBAddress gAddress;
static Boolean gSelected;
static Boolean gInstalled;
static volatile Boolean gRecording;
static volatile Boolean gInjecting;
static volatile unsigned char gDepth;
static volatile Boolean gTraceActive;
static NowPeekADBTraceEntry *gTraceEntry;
static NowPeekU32 gTraceSeq;
static volatile NowPeekU32 gPhysicalSeq;

static NowPeekContinuityCell *observer_cell(NowPeekTable *table)
{
    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic)
        return NULL;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                     + sizeof(NowPeekContinuityCell)))
        return NULL;
    if (table->continuity_format
            != (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT)
        return NULL;
    return &table->continuity;
}

static NowPeekU32 pack_bytes(const unsigned char *bytes, unsigned first,
                             unsigned length)
{
    NowPeekU32 packed = 0;
    unsigned i;

    for (i = 0; i < 4; ++i) {
        packed <<= 8;
        if (first + i < length)
            packed |= (NowPeekU32)bytes[first + i];
    }
    return packed;
}

static void snapshot_before(NowPeekADBTraceEntry *entry)
{
    Point pt;

    pt = LMGetMouseLocation();
    entry->before_mouse_h = pt.h;
    entry->before_mouse_v = pt.v;
    pt = LMGetRawMouseLocation();
    entry->before_raw_h = pt.h;
    entry->before_raw_v = pt.v;
    pt = LMGetMouseTemp();
    entry->before_temp_h = pt.h;
    entry->before_temp_v = pt.v;
    entry->before_button = (NowPeekU32)LMGetMouseButtonState();
}

static void snapshot_after(NowPeekADBTraceEntry *entry)
{
    Point pt;

    pt = LMGetMouseLocation();
    entry->after_mouse_h = pt.h;
    entry->after_mouse_v = pt.v;
    pt = LMGetRawMouseLocation();
    entry->after_raw_h = pt.h;
    entry->after_raw_v = pt.v;
    pt = LMGetMouseTemp();
    entry->after_temp_h = pt.h;
    entry->after_temp_v = pt.v;
    entry->after_button = (NowPeekU32)LMGetMouseButtonState();
}

/* Called only by the register-preserving assembly shim. `buffer` is the ADB
   Manager's Pascal packet: one length byte followed by at most eight bytes. */
void now_ext_adb_observer_begin(Ptr buffer, NowPeekU32 command)
{
    NowPeekContinuityCell *cell;
    NowPeekADBTraceEntry *entry;
    const unsigned char *packet = (const unsigned char *)buffer;
    unsigned length;
    NowPeekU32 seq;
    NowPeekU32 packet_seq;
    NowPeekU32 packet_epoch;
    NowPeekU32 flags;
    NowPeekI32 want_h;
    NowPeekI32 want_v;
    Point current;
    NowADBInjectionResult injection;

    gDepth++;
    if (gDepth != 1) {
        if (gCell != NULL)
            gCell->adb_observer_reentries++;
        return;
    }
    gTraceActive = false;
    cell = gCell;
    if (!gRecording || cell == NULL)
        return;

    cell->adb_observer_callbacks++;
    seq = gTraceSeq + 1u;
    if (seq == 0)
        seq = 1;
    entry = &cell->adb_trace[(seq - 1u) % kNowPeekADBTraceCapacity];
    entry->seq = 0;                  /* invalidate before overwriting */
    entry->epoch = cell->adb_observer_epoch;
    entry->ticks = (NowPeekU32)LMGetTicks();
    entry->command = command;
    length = packet == NULL ? 0u : (unsigned)packet[0];
    if (length > 8u)
        length = 8u;
    entry->data_length = (NowPeekU32)length;
    entry->data_0_3 = packet == NULL ? 0u
        : pack_bytes(packet + 1, 0, length);
    entry->data_4_7 = packet == NULL ? 0u
        : pack_bytes(packet + 1, 4, length);
    snapshot_before(entry);
    gTraceEntry = entry;
    gTraceSeq = seq;
    gTraceActive = true;

    if (!gInjecting || packet == NULL || length != 2u)
        return;
    packet_seq = cell->packet_seq;
    packet_epoch = cell->packet_epoch;
    want_h = cell->want_h;
    want_v = cell->want_v;
    flags = cell->flags;
    if (packet_seq != cell->packet_seq
            || packet_epoch != cell->adb_observer_epoch
            || !(flags & (NowPeekU32)kNowPeekContinuityInside))
        return;
    current = LMGetMouseLocation();
    injection = now_adb_injection_rewrite(
        (unsigned)command, (unsigned char *)buffer + 1, length,
        current.h, current.v, (short)want_h, (short)want_v);
    if (injection.classification == kNowADBInjectionPhysical) {
        cell->adb_injection_physical++;
        gPhysicalSeq++;
        return;
    }
    if (injection.classification != kNowADBInjectionCarrier)
        return;
    cell->adb_injection_packets++;
    cell->adb_injection_carriers++;
    if (injection.clamped)
        cell->adb_injection_clamps++;
}

/* Called after the incumbent handler returns. No manager, allocation,
   QuickDraw, logging, file, or network call is permitted here. */
void now_ext_adb_observer_end(void)
{
    NowPeekADBTraceEntry *entry;

    if (gDepth == 0)
        return;
    if (gDepth != 1) {
        gDepth--;
        return;
    }
    if (gTraceActive && gCell != NULL) {
        entry = gTraceEntry;
        snapshot_after(entry);
        entry->seq = gTraceSeq;      /* commit the complete entry last */
        gCell->adb_trace_write_seq = gTraceSeq;
    }
    gTraceActive = false;
    gTraceEntry = NULL;
    gDepth--;
}

static void mark_state(NowPeekContinuityCell *cell, NowPeekU32 state,
                       OSErr result)
{
    cell->adb_observer_state = state;
    cell->adb_observer_install_result = (NowPeekI32)result;
}

static int current_handler_is(ADBServiceRoutineUPP handler)
{
    ADBDataBlock current;

    memset(&current, 0, sizeof current);
    if (GetADBInfo(&current, gAddress) != noErr)
        return 0;
    return current.dbServiceRtPtr == handler
        && current.dbDataAreaAddr == gOriginalDataArea;
}

static int install_observer(NowPeekTable *table, NowPeekContinuityCell *cell)
{
    ADBDataBlock found;
    ADBSetInfoBlock replacement;
    ADBAddress found_address = (ADBAddress)-1;
    short count;
    short i;
    unsigned matches = 0;
    OSErr err;

    if (!gSelected) {
        count = CountADBs();
        for (i = 1; i <= count; ++i) {
            ADBDataBlock candidate;
            ADBAddress address;

            memset(&candidate, 0, sizeof candidate);
            address = GetIndADB(&candidate, i);
            if (address < 0 || candidate.origADBAddr != 3)
                continue;
            matches++;
            if (matches == 1) {
                found = candidate;
                found_address = address;
            }
        }
        cell->adb_observer_device_count = (NowPeekU32)matches;
        if (matches == 0) {
            mark_state(cell, (NowPeekU32)kNowPeekADBObserverUnavailable,
                       noErr);
            return 0;
        }
        if (matches != 1 || found.dbServiceRtPtr == NULL) {
            mark_state(cell, (NowPeekU32)kNowPeekADBObserverConflict,
                       paramErr);
            return 0;
        }

        gCell = cell;
        gAddress = found_address;
        gOriginalDataArea = found.dbDataAreaAddr;
        gNowADBObserverOriginalHandler = found.dbServiceRtPtr;
        gSelected = true;
        cell->adb_observer_address = (NowPeekI32)found_address;
        cell->adb_observer_handler_id = (NowPeekI32)found.devType;
    }

    if (current_handler_is(
            (ADBServiceRoutineUPP)now_ext_adb_observer_entry)) {
        gInstalled = true;
        table->rest_state |= (NowPeekU16)kNowPeekRestADBObserverInstalled;
        mark_state(cell, (NowPeekU32)kNowPeekADBObserverInstalled, noErr);
        return 1;
    }
    if (!current_handler_is(gNowADBObserverOriginalHandler)) {
        mark_state(cell, (NowPeekU32)kNowPeekADBObserverConflict, paramErr);
        return 0;
    }

    replacement.siService = (ADBServiceRoutineUPP)now_ext_adb_observer_entry;
    replacement.siDataAreaAddr = gOriginalDataArea;
    err = SetADBInfo(&replacement, gAddress);
    if (!current_handler_is(
            (ADBServiceRoutineUPP)now_ext_adb_observer_entry)) {
        if (err == noErr)
            err = paramErr;
        mark_state(cell, (NowPeekU32)kNowPeekADBObserverInstallFailed, err);
        return 0;
    }
    gInstalled = true;
    cell->adb_observer_installs++;
    table->rest_state |= (NowPeekU16)kNowPeekRestADBObserverInstalled;
    mark_state(cell, (NowPeekU32)kNowPeekADBObserverInstalled, noErr);
    return 1;
}

void now_ext_adb_observer_start(NowPeekTable *table, NowPeekU32 epoch,
                                unsigned inject)
{
    NowPeekContinuityCell *cell = observer_cell(table);
    ADBSetInfoBlock replacement;
    OSErr err;

    if (cell == NULL)
        return;
    gRecording = false;
    gInjecting = false;
    cell->adb_observer_epoch = epoch;
    if (!gInstalled && !install_observer(table, cell))
        return;

    if (!current_handler_is(
            (ADBServiceRoutineUPP)now_ext_adb_observer_entry)) {
        /* ADBReInit may restore exactly the handler we wrapped. Reinstall only
           in that provable case; any other handler is somebody else's chain. */
        if (!current_handler_is(gNowADBObserverOriginalHandler)) {
            mark_state(cell, (NowPeekU32)kNowPeekADBObserverConflict,
                       paramErr);
            return;
        }
        replacement.siService =
            (ADBServiceRoutineUPP)now_ext_adb_observer_entry;
        replacement.siDataAreaAddr = gOriginalDataArea;
        err = SetADBInfo(&replacement, gAddress);
        if (err != noErr
                || !current_handler_is(
                    (ADBServiceRoutineUPP)now_ext_adb_observer_entry)) {
            if (err == noErr)
                err = paramErr;
            mark_state(cell, (NowPeekU32)kNowPeekADBObserverInstallFailed,
                       err);
            return;
        }
        cell->adb_observer_installs++;
    }
    gCell = cell;
    gInjecting = inject != 0;
    gRecording = true;              /* publish recording authority last */
    mark_state(cell, (NowPeekU32)kNowPeekADBObserverRecording, noErr);
}

void now_ext_adb_observer_stop(void)
{
    gRecording = false;             /* callback sees idle before state does */
    gInjecting = false;
    if (gCell != NULL && gInstalled)
        mark_state(gCell, (NowPeekU32)kNowPeekADBObserverInstalled, noErr);
}

NowPeekU32 now_ext_adb_observer_physical_seq(void)
{
    return gPhysicalSeq;
}

void now_ext_adb_observer_rollback(NowPeekTable *table)
{
    /* Installation is lazy and cannot have happened during the INIT's install
       transaction. If this ever becomes reachable after installation, retain
       the table pointer: the live ADB chain still owns the wrapper. */
    gRecording = false;
    gInjecting = false;
    if (!gInstalled) {
        gCell = NULL;
        gSelected = false;
        gNowADBObserverOriginalHandler = NULL;
        gOriginalDataArea = NULL;
    } else if (table != NULL) {
        table->rest_state |= (NowPeekU16)kNowPeekRestADBObserverInstalled;
    }
}
