/* P9's only Cursor Device boundary.

   CursorDevices.h is explicit: PowerPC callers need Apple's corrected Mixed
   Mode transition because the original ROM/InterfaceLib transition for the
   Cursor Device Manager is wrong. Earlier candidates bypassed that correction
   with a generic PPC -> resident 68K service -> AADB trap path. It passed QEMU
   and repeatedly wedged the PowerBook.

   This module owns one synthetic absolute device for the PPC application's
   lifetime and calls it only from the ordinary/nested cooperative wire pump.
   The Extension never receives this pointer and never enters CDM for P9. */
#include "continuity_cursor.h"

#include <Carbon.h>
#include <CursorDevices.h>

#include <string.h>

#include "continuity_cdm_transition.h"
#include "mirror_debug.h"
#include "nowlog.h"

enum {
    kNowContinuityDeviceID = 'NOWc',
    kNowContinuityResolution = 72L << 16
};

static CursorDevicePtr gDevice;
static unsigned long gEpoch;
static unsigned long gMoveCount;
static unsigned long gButtonCount;
/* Manager button ledger. On this OS the Cursor Device record is upstream
   of low memory: a manager down whose up was lost keeps re-asserting
   MBState down after the epoch is gone, and the machine drags a phantom
   until real device input rewrites it (observed across a reconnect,
   2026-08-13 185037). The ledger survives epochs so the debt can be
   settled wherever task time next exists. */
static int gLedgerDown;
static NowContinuityCursorDiagnostics gDiagnostics;

static int device_point(Point *out)
{
    if (out == NULL || gDevice == NULL || gDevice->whichCursor == NULL)
        return 0;
    *out = gDevice->whichCursor->where;
    return 1;
}

static int checkpoint(unsigned long count)
{
    if (count <= 4 || count == 8 || count == 16 || count == 32)
        return 1;
    return (count % 30u) == 0;
}

int now_continuity_cursor_ready(void)
{
    CursorDevicePtr device = NULL;
    OSErr err;

    if (gDevice != NULL)
        return 1;
    err = now_cdm_new_device(&device);
    if (err != noErr || device == NULL) {
        now_log(kLogError, "mirror", "CDM PPC new failed err=%d device=%p",
                (int)err, (void *)device);
        return 0;
    }
    device->devID = (OSType)kNowContinuityDeviceID;
    device->devClass = (UInt8)kDeviceClassAbsolute;
    err = now_cdm_set_buttons(device, 1);
    if (err == noErr)
        err = now_cdm_units_per_inch(device,
                                    (Fixed)kNowContinuityResolution);
    if (err != noErr) {
        OSErr dispose_err = now_cdm_dispose_device(device);
        now_log(kLogError, "mirror",
                "CDM PPC configure failed err=%d dispose=%d",
                (int)err, (int)dispose_err);
        return 0;
    }
    gDevice = device;
    now_log(kLogInfo, "mirror", "CDM PPC device ready ptr=%p", (void *)device);
    now_log_flush();
    return 1;
}

void now_continuity_cursor_begin_epoch(unsigned long epoch)
{
    /* A prior epoch's unbalanced manager down is settled before this
       epoch takes over; the device outlives epochs and so does its debt. */
    (void)now_continuity_cursor_ensure_released("arm");
    gEpoch = epoch;
    gMoveCount = 0;
    gButtonCount = 0;
    memset(&gDiagnostics, 0, sizeof gDiagnostics);
    now_log(kLogInfo, "mirror", "CDM PPC epoch=%lu begin", epoch);
    now_log_flush();
}

/* Settle an unbalanced manager down wherever task time exists. Safe to
   call at any frequency: it is a no-op unless the ledger says down. */
long now_continuity_cursor_ensure_released(const char *reason)
{
    OSErr err;

    if (gDevice == NULL || !gLedgerDown)
        return 0;
    err = now_cdm_button_up(gDevice);
    now_log(err == noErr ? kLogWarn : kLogError, "mirror",
            "CDM PPC corrective up reason=%s err=%d",
            reason != NULL ? reason : "?", (int)err);
    if (err == noErr)
        gLedgerDown = 0;
    return (long)err;
}

long now_continuity_cursor_button(unsigned long epoch,
                                  unsigned long generation, int down)
{
    OSErr err;

    if (gDevice == NULL || epoch == 0 || epoch != gEpoch
            || generation == 0)
        return paramErr;
    if (down && gDiagnostics.requested_valid) {
        gDiagnostics.press_h = gDiagnostics.requested_h;
        gDiagnostics.press_v = gDiagnostics.requested_v;
        gDiagnostics.press_valid = 1;
    }
    gButtonCount++;
    /* The begin/return pair is a per-press trace: in-memory only (the
       source test below this file guards that) and now ALSO debug tier,
       because even memory lines churn the same 2000-line ring `tail`
       reads. The error branch stays unconditional. */
    if (now_mirror_debug_on()) {
        now_log_memory(kLogInfo, "mirror",
                       "CDM PPC button begin epoch=%lu n=%lu generation=%lu down=%d",
                       epoch, gButtonCount, generation, down ? 1 : 0);
    }
    err = down ? now_cdm_button_down(gDevice)
               : now_cdm_button_up(gDevice);
    if (err == noErr)
        gLedgerDown = down ? 1 : 0;
    if (err == noErr) {
        if (now_mirror_debug_on()) {
            now_log_memory(kLogInfo, "mirror",
                           "CDM PPC button return epoch=%lu n=%lu generation=%lu down=%d err=%d",
                           epoch, gButtonCount, generation, down ? 1 : 0,
                           (int)err);
        }
    } else {
        now_log(kLogError, "mirror",
                "CDM PPC button return epoch=%lu n=%lu generation=%lu down=%d err=%d",
                epoch, gButtonCount, generation, down ? 1 : 0, (int)err);
    }
    return (long)err;
}

long now_continuity_cursor_move(unsigned long epoch, unsigned long sequence,
                                long h, long v)
{
    Point device_before;
    Point device_after;
    unsigned long before;
    unsigned long after;
    OSErr err;
    int durable;

    if (gDevice == NULL || epoch == 0 || epoch != gEpoch)
        return paramErr;
    gMoveCount++;
    if (device_point(&device_before)) {
        gDiagnostics.samples++;
        gDiagnostics.device_point_valid = 1;
        gDiagnostics.before_h = device_before.h;
        gDiagnostics.before_v = device_before.v;
        if (gDiagnostics.after_lag_pending) {
            if (gDiagnostics.requested_valid
                    && device_before.h == (short)gDiagnostics.requested_h
                    && device_before.v == (short)gDiagnostics.requested_v)
                gDiagnostics.after_lag_caught_up++;
            else
                gDiagnostics.after_lag_persisted++;
            gDiagnostics.after_lag_pending = 0;
        }
        if (gDiagnostics.requested_valid
                && (device_before.h != (short)gDiagnostics.requested_h
                    || device_before.v != (short)gDiagnostics.requested_v)) {
            gDiagnostics.before_request_mismatches++;
        }
        if (gDiagnostics.press_valid && gDiagnostics.requested_valid
                && (gDiagnostics.requested_h != gDiagnostics.press_h
                    || gDiagnostics.requested_v != gDiagnostics.press_v)
                && device_before.h == (short)gDiagnostics.press_h
                && device_before.v == (short)gDiagnostics.press_v) {
            gDiagnostics.press_reversions++;
        }
    }
    /* Checkpoint-sampled AND debug-gated: the sampling bounds the rate,
       the gate keeps even the samples out of the ring by default. */
    durable = checkpoint(gMoveCount) && now_mirror_debug_on();
    if (durable) {
        now_log_memory(kLogInfo, "mirror",
                       "CDM PPC move begin epoch=%lu n=%lu seq=%lu at=%ld,%ld",
                       epoch, gMoveCount, sequence, h, v);
    }
    before = TickCount();
    err = now_cdm_move_to(gDevice, h, v);
    after = TickCount();
    if (device_point(&device_after)) {
        gDiagnostics.device_point_valid = 1;
        gDiagnostics.after_h = device_after.h;
        gDiagnostics.after_v = device_after.v;
        if (device_after.h != (short)h || device_after.v != (short)v) {
            gDiagnostics.after_request_mismatches++;
            gDiagnostics.after_lag_pending = 1;
        }
    }
    gDiagnostics.requested_h = h;
    gDiagnostics.requested_v = v;
    gDiagnostics.requested_valid = 1;
    if (err != noErr) {
        now_log(kLogError, "mirror",
                "CDM PPC move failed epoch=%lu n=%lu seq=%lu err=%d ticks=%lu",
                epoch, gMoveCount, sequence, (int)err, after - before);
    } else if (durable) {
        now_log_memory(kLogInfo, "mirror",
                       "CDM PPC move return epoch=%lu n=%lu seq=%lu ticks=%lu",
                       epoch, gMoveCount, sequence, after - before);
    }
    return (long)err;
}

void now_continuity_cursor_diagnostics(NowContinuityCursorDiagnostics *out)
{
    if (out != NULL)
        *out = gDiagnostics;
}

void now_continuity_cursor_shutdown(void)
{
    OSErr err;

    if (gDevice == NULL)
        return;
    (void)now_continuity_cursor_ensure_released("shutdown");
    err = now_cdm_dispose_device(gDevice);
    now_log(err == noErr ? kLogInfo : kLogError, "mirror",
            "CDM PPC device dispose err=%d", (int)err);
    gDevice = NULL;
    gEpoch = 0;
    gMoveCount = 0;
    gButtonCount = 0;
    memset(&gDiagnostics, 0, sizeof gDiagnostics);
}
