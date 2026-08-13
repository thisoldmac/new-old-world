/*
 * now_ext_cursor.c - P8, the drawn cursor follows what we act on.
 *
 * WHAT WAS WRONG, AND HOW IT WAS ESTABLISHED
 * -------------------------------------------
 * P4 and P7 both move the pointer the documented Inside Macintosh way:
 * write MTemp, RawMouse and MouseLocation, then copy CrsrCouple into
 * CrsrNew to ask the cursor VBL task for a redraw. Everything the
 * Toolbox READS follows those writes perfectly - GetMouse, StillDown,
 * the whole tracking-loop surface - and the SPRITE never moves. Five
 * resident moves, five screendump pairs, zero pixels changed each time
 * (2026-08-07, tools/local-cursor-sprite.py, emulated mac99/OS 9.1).
 *
 * The obvious suspect was the rig: an emulated pointing device reporting
 * over the top of our writes. IT IS NOT, and that matters more than the
 * fix, because it means metal is not a different case. Read from OUTSIDE
 * the guest through QMP, with nothing touching the host pointer, all
 * three globals held our value unchanged for seconds. Nothing overwrites
 * them. And every precondition the documented recipe needs was met:
 * CrsrCouple was 0xff (coupled), CrsrState 0 (drawable), CrsrObscure 0,
 * CrsrBusy 0 - and CrsrNew read back 0x00, meaning our request had been
 * CONSUMED. The task ran. It just did not draw.
 *
 * What did move the sprite was the emulated device, and its trail says
 * why: after it, the Cursor Device Manager's own CursorData record held
 * FRACTIONAL coordinates (419.63, 333.25) and the changed pixels boxed
 * the old sprite and the new one together. Our writes reach that record
 * too - it followed every move, exactly, to the integer - so the manager
 * knows where the cursor is and simply is not the thing we asked to
 * redraw it. **On Mac OS 8/9 the Cursor Device Manager owns the sprite,
 * and the low-memory globals are downstream of it rather than upstream.**
 *
 * SO THIS FILE CALLS THE MANAGER, BUT ONLY AT TASK TIME. The first metal
 * Continuity candidates treated `CursorDeviceMoveTo` as though calling it
 * from our arbitrary Time Manager task were equivalent to the ADB driver's
 * own interrupt path. Twice, the PowerBook stopped accepting clicks after
 * one or a few placements. The manager and QuickDraw therefore settle from
 * the next jGNE pass; interrupt time publishes low-memory state and one
 * preallocated latest-point debt only.
 *
 * THE LOW-MEMORY WRITES DID NOT GO AWAY, and that is deliberate. They
 * are what a tracking loop reads, they are what makes an act's click
 * land where the act says, and they work. This plane adds the redraw the
 * recipe was supposed to produce; it does not replace the half that was
 * never broken. When there is no manager, the old CrsrNew/CrsrCouple
 * line still runs, and is REPORTED as its own route so that a machine
 * quietly falling back is not read as a machine that worked.
 *
 * NOT FIGHTING A HUMAN
 * --------------------
 * A person at the machine moves the mouse; we move it somewhere else;
 * they move it back. That is a fight nobody wins and it is the one way
 * this plane could make a Macintosh worse to sit at. So before every
 * placement the resident asks whether the pointer is still where IT last
 * put it. If it is not, somebody else is driving, and for
 * kNowPeekCursorYieldTicks afterwards the sprite is left alone - the
 * position writes still happen, because an act must still land where it
 * says, and only the picture yields. Counted, in `yielded`, because a
 * courtesy nobody can observe is indistinguishable from a bug.
 *
 * A DRAG DOES NOT YIELD, and the asymmetry is the point. During a
 * gesture this plane IS the thing driving the pointer, so "the pointer
 * moved since we placed it" is not evidence of a person - it is the
 * acceleration of whatever else touched it, and yielding mid-drag would
 * leave the sprite stranded halfway through a gesture the application is
 * already tracking.
 */
#include <MacTypes.h>
#include <LowMem.h>
#include <Traps.h>
#include <Quickdraw.h>
#include <CursorDevices.h>

#include "peek_table.h"
#include "now_cursor_logic.h"
#include "now_ext_continuity_trace.h"
#include "now_ext_cursor_input.h"

/* CrsrNew and CrsrCouple are past where this toolchain's LowMem.h stops
   (CrsrBusy, 0x08CD), and are reached through VOLATILE POINTER VARIABLES
   rather than cast constants. GCC folds `*(volatile UInt8 *)0x08CE` into
   a dereference of a known-tiny address and rejects it under
   -Werror=array-bounds as "likely at address zero" - correct about every
   C program except one running inside a Macintosh's low memory. Making
   the POINTER volatile means the compiler must load it before each use,
   which is the narrowest possible way to say "I mean this address".
   The addresses moved HERE from now_ext_drag.c, which no longer needs
   them: one plane owns the cursor now, and two files spelling the same
   two addresses is how the pair drifts. */
static volatile UInt8 *volatile gCrsrNew = (volatile UInt8 *)0x08CEUL;
static volatile UInt8 *volatile gCrsrCouple = (volatile UInt8 *)0x08CFUL;
/* CrsrObscure (0x08D2). Non-zero means an application called
   ObscureCursor - "hide the arrow, the person is typing" - and the
   cursor stays invisible UNTIL THE MOUSE MOVES. SimpleText does it on
   every keystroke; so does every text editor on this machine.

   We are the mouse moving. Clearing it is what the pointing device's own
   driver does on the next report, and without it P8 draws faithfully
   into an invisible cursor: watched 2026-08-07, `route` correct,
   `by_device` climbing, CrsrObscure 0x01 and zero pixels, which is
   indistinguishable from the plane not working at all. */
static volatile UInt8 *volatile gCrsrObscure = (volatile UInt8 *)0x08D2UL;

/* _CursorDeviceDispatch. Passed whole, the way now_content.c passes
   _QDExtensions; NGetTrapAddress masks it. */
#define kNowCursorDeviceTrap 0xAADB
#define kNowUnimplementedTrap 0xA89F
#define kNowGetMouseTrap  0xA972
#define kNowStillDownTrap 0xA973
#define kNowButtonTrap    0xA974

/* OSErr, from the assembly shims - see now_ext_cursor_cdm.S for why they
   cannot be C declarations with TWOWORDINLINE. */
extern long now_cdm_move_to(void *device, long absX, long absY);
extern long now_cdm_next_device(void **device);
extern void now_cursor_getmouse_patch(void);
extern void now_cursor_stilldown_patch(void);
extern void now_cursor_button_patch(void);

/* Assembly-visible chain state. The incumbents are captured together before
   any trap is changed, so installation cannot leave one hook pointing at an
   uninitialised destination. Once installed, these links live until reboot. */
volatile unsigned char gNowCursorTrackingRedrawOwed = 0;
volatile unsigned char gNowCursorTrackingSourceActive = 0;
volatile unsigned char gNowCursorTrackingVirtualGetMouse = 0;
static volatile unsigned char gNowCursorTrackingHideGuestCursor = 0;
static volatile unsigned char gNowCursorTrackingCursorHidden = 0;
void *gNowCursorOldGetMouse = NULL;
void *gNowCursorOldStillDown = NULL;
void *gNowCursorOldButton = NULL;
static volatile unsigned short gNowCursorTrackingSourceSeq = 0;
static volatile short gNowCursorTrackingSourceH = 0;
static volatile short gNowCursorTrackingSourceV = 0;
static Point gNowCursorTrackingPressPoint;
static Boolean gNowCursorTrackingPressValid = false;
static NowPeekU32 gNowCursorTrackingConflictCount = 0;

static NowPeekTable *gTable = NULL;
static CursorDevicePtr gDevice = NULL;
static Point gLastPlaced;
static unsigned long gForeignTicks = 0;
static Boolean gBooted = false;
/* Has this resident ever actually moved the device? Until it has,
   gLastPlaced describes nothing and must not be compared against. */
static Boolean gEverPlaced = false;
/* A redraw this plane owes but could not perform where it was asked.
   The drawing route is QuickDraw and needs a real context; the drag
   vehicle runs at interrupt time and has none. So an interrupt-time
   placement records the debt and the next jGNE pass settles it - the
   same split P7 uses for its owed mouseUp, and for the same reason: the
   part that must not fail runs where it cannot, and the part that needs
   a context waits for one. */
static volatile Boolean gTaskApplyOwed = false;
static volatile NowPeekI32 gTaskH = 0;
static volatile NowPeekI32 gTaskV = 0;
static volatile NowPeekU32 gTaskApplySeq = 0;
static volatile NowPeekI32 gTaskAppliedH = 0;
static volatile NowPeekI32 gTaskAppliedV = 0;
/* Native-input observation is deliberately task-time sampling of both the
   CursorDevice record and RawMouse, not a Time Manager dereference and not
   the jGNE EventRecord. Real ADB/USB input updates RawMouse on every tested
   rig, while CursorData.where can remain at our last CursorDeviceMoveTo point.
   The system filter also runs before Event Manager commits its returned
   record, so treating A1 as an input notification misses real movement. */
static volatile NowPeekU32 gPhysicalInputSeq = 0;
static volatile NowPeekU32 gPhysicalSamples = 0;
static volatile NowPeekU32 gPhysicalChanges = 0;
static volatile NowPeekU32 gPhysicalTrigger = 0;
static volatile NowPeekU32 gDebtCancels = 0;
static unsigned gPhysicalButtons = 0;
static Boolean gPhysicalButtonsValid = false;
static Boolean gPhysicalValid = false;
static Point gPhysicalRawWhere;
static Boolean gPhysicalRawValid = false;
static Point gPhysicalReportedWhere;
static Point gOwnedDeviceWhere;
static Boolean gOwnedDeviceValid = false;
/* Cover more than one second of synthetic propagation at the maximum 60 Hz
   rate. The PowerPC Cursor Device can publish an older requested point after a
   tracking loop has advanced MouseLocation; eight entries aged that owned
   point out in 267 ms at 30 Hz and falsely classified it as physical input.
   Newest-first lookup keeps the ordinary cost near one comparison. */
enum { kOwnedHistoryCount = 64 };
typedef struct {
    volatile unsigned short seq;
    volatile Point point[kOwnedHistoryCount];
    volatile unsigned short next;
    volatile unsigned short used;
} OwnedPointHistory;
/* The PPC task and Continuity timer have separate single-writer histories.
   A shared ring let the timer interrupt a task-time index update and made
   native-input classification depend on a torn Point. */
static OwnedPointHistory gOwnedDeviceHistory;
static OwnedPointHistory gOwnedTrackingHistory;

int now_ext_cursor_boot(NowPeekTable *table);
void now_ext_cursor_rollback(NowPeekTable *table);
void now_ext_cursor_gne(NowPeekTable *table);
int now_ext_cursor_task_apply_state(NowPeekU32 *seq, NowPeekI32 *h,
                                    NowPeekI32 *v);
int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, unsigned flags);
NowPeekCursorCell *now_ext_cursor_cell(NowPeekTable *table);

static void remember_owned_history(OwnedPointHistory *history, Point pt)
{
    unsigned short next = history->next;
    unsigned short used = history->used;

    history->seq++;
    history->point[next] = pt;
    history->next = (unsigned short)((next + 1u) % kOwnedHistoryCount);
    if (used < kOwnedHistoryCount)
        history->used = (unsigned short)(used + 1u);
    history->seq++;
}

static void remember_owned_device_point(Point pt)
{
    gOwnedDeviceWhere = pt;
    gOwnedDeviceValid = gDevice != NULL;
    if (!gOwnedDeviceValid)
        return;
    remember_owned_history(&gOwnedDeviceHistory, pt);
}

/* Continuity's held tracking path owns only MouseLocation. Remember it
   separately from the physical CursorDevice so the next native-input sample
   does not mistake the system's propagation of our own write for an ADB/USB
   report. The short history closes the race where the timer advances the
   latest point while the sampler classifies the preceding one. */
static void remember_owned_lowmem_point(Point pt)
{
    remember_owned_history(&gOwnedTrackingHistory, pt);
}

/* Read the held gesture's point without returning a torn h/v pair. The timer
   is the sole publisher; two bounded attempts cover one interrupt arriving
   between the task-time reader's fields. */
static Boolean continuity_tracking_source_point(Point *out)
{
    unsigned short attempt;

    if (out == NULL)
        return false;
    for (attempt = 0; attempt < 2; attempt++) {
        unsigned short before = gNowCursorTrackingSourceSeq;
        Boolean active;
        Point pt;

        if ((before & 1u) != 0)
            continue;
        active = gNowCursorTrackingSourceActive != 0;
        pt.h = gNowCursorTrackingSourceH;
        pt.v = gNowCursorTrackingSourceV;
        if (before == gNowCursorTrackingSourceSeq
                && (before & 1u) == 0 && active) {
            *out = pt;
            return true;
        }
    }
    return false;
}

static Boolean owned_history_contains(const OwnedPointHistory *history,
                                      Point pt)
{
    unsigned short before = history->seq;
    unsigned short used;
    unsigned short next;
    unsigned short i;
    Boolean matched = false;

    /* Treat an in-flight write as host-owned for this one sample. A false
       negative here revokes a valid drag; the next 16 ms tick can classify
       the stable history without weakening physical-input takeover. */
    if ((before & 1u) != 0)
        return true;
    used = history->used;
    next = history->next;
    if (used > kOwnedHistoryCount)
        return true;
    for (i = 0; i < used; i++) {
        unsigned short index = (unsigned short)(
            (next + kOwnedHistoryCount - 1u - i)
            & (kOwnedHistoryCount - 1u));

        if (history->point[index].h == pt.h
                && history->point[index].v == pt.v) {
            matched = true;
            break;
        }
    }
    if (before != history->seq || (history->seq & 1u) != 0)
        return true;
    return matched;
}

static Boolean is_recent_owned_device_point(Point pt)
{
    return owned_history_contains(&gOwnedDeviceHistory, pt)
        || owned_history_contains(&gOwnedTrackingHistory, pt);
}

static Boolean is_owned_or_pending_point(Point pt)
{
    if (gTaskApplyOwed
        && pt.h == (short)gTaskH && pt.v == (short)gTaskV)
        return true;
    return is_recent_owned_device_point(pt);
}

/* Publish the low-memory position left by the most recent task-time manager
   apply. The Time Manager reads only these resident globals; it never follows
   a CursorDevice pointer. Odd means the task-time writer is between fields. */
int now_ext_cursor_task_apply_state(NowPeekU32 *seq, NowPeekI32 *h,
                                    NowPeekI32 *v)
{
    NowPeekU32 before = gTaskApplySeq;

    if ((before & 1u) != 0)
        return 0;
    *h = gTaskAppliedH;
    *v = gTaskAppliedV;
    *seq = before;
    return before == gTaskApplySeq ? 1 : 0;
}

/* Sample native mouse motion only from RawMouse. Continuity
   deliberately does not inspect or mutate the physical CursorDevice record:
   the PowerBook 1400 trackpad owns that ADB-backed object, and treating it as
   our synthetic device produced two whole-system metal wedges. This routine
   is bounded low-memory/resident-state work so the timer samples immediately
   before each placement; that prevents a host point from overwriting an ADB
   report before optimistic takeover sees it. Recent host-owned points are
   excluded. Button state is tracked separately from position history. */
NowPeekU32 now_ext_cursor_physical_input_seq(void)
{
    Point raw;
    unsigned buttons;
    Boolean owned_raw;
    Boolean changed = false;
    NowPeekU32 trigger = 0;

    raw = LMGetRawMouseLocation();
    buttons = (LMGetMouseButtonState() & 0x80u) ? 0u : 1u;
    gPhysicalSamples++;
    owned_raw = is_owned_or_pending_point(raw);

    if (!gPhysicalRawValid) {
        if (!owned_raw) {
            gPhysicalRawWhere = raw;
            gPhysicalReportedWhere = raw;
            gPhysicalRawValid = true;
            gPhysicalValid = true;
        }
    } else if (!owned_raw
               && (raw.h != gPhysicalRawWhere.h
                   || raw.v != gPhysicalRawWhere.v)) {
        changed = true;
        trigger |= (NowPeekU32)kNowCursorInputTriggerPosition;
        gPhysicalReportedWhere = raw;
    }
    if (!owned_raw)
        gPhysicalRawWhere = raw;
    if (!gPhysicalButtonsValid) {
        gPhysicalButtons = buttons;
        gPhysicalButtonsValid = true;
    } else if (buttons != gPhysicalButtons) {
        changed = true;
        trigger |= (NowPeekU32)kNowCursorInputTriggerButton;
    }
    gPhysicalButtons = buttons;
    if (changed) {
        gPhysicalInputSeq++;
        gPhysicalChanges++;
        gPhysicalTrigger = trigger;
    }
    return gPhysicalInputSeq;
}

/* CursorDevicesGlue now performs P9's placement from the PPC application.
   The resident remembers the point only after the application publishes a
   successful result, so RawMouse takeover does not classify our own report as
   physical ADB/USB input. No Cursor Device pointer crosses this boundary. */
void now_ext_cursor_remember_continuity_point(NowPeekI32 h, NowPeekI32 v)
{
    Point pt;

    pt.h = (short)h;
    pt.v = (short)v;
    remember_owned_device_point(pt);
}

/* The synthetic PPC Cursor Device normally draws its own report, but an
   application can leave either CrsrObscure or the sprite itself stale until
   the next physical mouse move. Continuity is that next movement. Clear the
   low-memory obscured state and always ask QuickDraw for one balanced redraw;
   CrsrObscure == 0 does not prove that the sprite is currently visible. This
   is called only from the PPC app's synchronous resident service in
   cooperative task time, never from a timer. */
void now_ext_cursor_reveal_continuity(void)
{
    *gCrsrObscure = 0;
    HideCursor();
    ShowCursor();
}

/* Called from Continuity's Time Manager task immediately after its sole
   position write. Resident memory only: this does not follow a CursorDevice,
   call a manager, or mutate another mouse global. */
void now_ext_cursor_remember_continuity_tracking_point(NowPeekI32 h,
                                                       NowPeekI32 v)
{
    Point pt;
    Boolean beginning = gNowCursorTrackingSourceActive == 0;

    pt.h = (short)h;
    pt.v = (short)v;
    if (beginning) {
        gNowCursorTrackingPressPoint = pt;
        gNowCursorTrackingPressValid = true;
        gNowCursorTrackingConflictCount = 0;
    }
    gNowCursorTrackingSourceSeq++;
    gNowCursorTrackingSourceH = pt.h;
    gNowCursorTrackingSourceV = pt.v;
    gNowCursorTrackingSourceActive = 1;
    gNowCursorTrackingSourceSeq++;
    remember_owned_lowmem_point(pt);
    gNowCursorTrackingRedrawOwed = 1; /* publish after the point is complete */
}

/* The held source is already published before this task-time call. Hide one
   native sprite only when the host explicitly selected the experiment; the
   host pointer remains visible over Mirror. The matching ShowCursor runs in
   task time on every normal and forced exit. */
void now_ext_cursor_begin_continuity_tracking_visuals(void)
{
    if (!gNowCursorTrackingHideGuestCursor
            || gNowCursorTrackingCursorHidden)
        return;
    HideCursor();
    gNowCursorTrackingCursorHidden = 1;
}

/* Release the held source without removing the three trap links. The links
   are permanent for this boot because a later extension may chain behind
   them; inactive they only test resident bytes and tail-chain. */
void now_ext_cursor_end_continuity_tracking(void)
{
    gNowCursorTrackingSourceSeq++;
    gNowCursorTrackingSourceActive = 0;
    gNowCursorTrackingSourceSeq++;
    gNowCursorTrackingRedrawOwed = 0;
    gNowCursorTrackingPressValid = false;
}

/* Epoch configuration is copied into one resident byte for the assembly hot
   path. Unknown bits were already masked by the application, but masking here
   keeps this entry safe if another resident caller appears later. */
void now_ext_cursor_configure_continuity_tracking(NowPeekU32 options)
{
    gNowCursorTrackingVirtualGetMouse =
        (options & (NowPeekU32)kNowPeekContinuityTrackingVirtualGetMouse)
            != 0;
    gNowCursorTrackingHideGuestCursor =
        (options & (NowPeekU32)kNowPeekContinuityTrackingHideGuestCursor)
            != 0;
}

/* Interrupt-safe held-point pin. This deliberately touches MouseLocation
   only: RawMouse, MTemp and the physical Cursor Device remain owned by the
   ADB/USB path, preserving optimistic local takeover. */
int now_ext_cursor_reassert_continuity_tracking(void)
{
    Point pt;

    if (!continuity_tracking_source_point(&pt))
        return 0;
    LMSetMouseLocation(pt);
    return 1;
}

/* Answer the Pascal _GetMouse out parameter from the held source. The
   assembly trampoline owns the Pascal stack cleanup; this C half only proves
   the option and source are still active, then writes the caller's Point. */
int now_ext_cursor_answer_continuity_getmouse(void *mouse_loc)
{
    Point pt;
    NowPeekContinuityCell *cell;

    if (!gNowCursorTrackingVirtualGetMouse || mouse_loc == NULL
            || !continuity_tracking_source_point(&pt))
        return 0;
    LMSetMouseLocation(pt);
    *(Point *)mouse_loc = pt;
    if (gTable != NULL
            && gTable->length
                >= (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                 + sizeof(NowPeekContinuityCell))
            && gTable->continuity_format
                == (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT) {
        cell = &gTable->continuity;
        cell->tracking_getmouse_answers++;
    }
    return 1;
}

/* Settle only the picture. This is entered from Toolbox hooks in
   the tracked application's task-time context. Clearing first makes nested
   GetMouse/StillDown/Button calls harmless; a timer interrupt that publishes
   a newer point during QuickDraw leaves a fresh debt for the next hook. */
void now_ext_cursor_settle_continuity_tracking(void)
{
    Point pt;
    Point live;
    Boolean moved;
    Boolean owed = gNowCursorTrackingRedrawOwed != 0;
    NowPeekContinuityCell *cell = NULL;

    if (gTable != NULL
            && gTable->length
                >= (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                 + sizeof(NowPeekContinuityCell))
            && gTable->continuity_format
                == (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT) {
        cell = &gTable->continuity;
        cell->tracking_settle_calls++;
    }

    if (!continuity_tracking_source_point(&pt)) {
        if (!owed)
            return;
        gNowCursorTrackingRedrawOwed = 0;
        return;
    }
    live = LMGetMouseLocation();
    moved = live.h != pt.h || live.v != pt.v;
    if (moved && cell != NULL) {
        cell->tracking_settle_moved++;
        gNowCursorTrackingConflictCount++;
        /* Preserve a bounded progression when NOW cannot drain the ring
           during a target's nested tracking loop. Powers of two retain the
           conflict's duration; every return to the press point is retained
           because that is the observed menu/drag jitter signature. */
        if (gNowCursorTrackingConflictCount <= 4u
                || (gNowCursorTrackingConflictCount
                    & (gNowCursorTrackingConflictCount - 1u)) == 0
                || (gNowCursorTrackingPressValid
                    && live.h == gNowCursorTrackingPressPoint.h
                    && live.v == gNowCursorTrackingPressPoint.v)) {
            now_ext_continuity_trace_tracking_conflict(
                (NowPeekI32)live.h, (NowPeekI32)live.v,
                (NowPeekI32)pt.h, (NowPeekI32)pt.v);
        }
    }
    /* The PowerBook's ADB path can republish its stationary physical point
       between host ticks. Reassert our held point on every tracking call.
       The baseline mode then lets the real Toolbox trap answer normally;
       Virtual GetMouse may answer its out parameter directly afterwards. */
    LMSetMouseLocation(pt);
    if (cell != NULL)
        cell->tracking_settle_reasserts++;
    if (gNowCursorTrackingCursorHidden) {
        gNowCursorTrackingRedrawOwed = 0;
        return;
    }
    if (!owed && !moved)
        return;
    gNowCursorTrackingRedrawOwed = 0;
    if (cell == NULL)
        return;
    *gCrsrObscure = 0;
    HideCursor();
    ShowCursor();
    cell->tracking_settle_redraws++;
    /* Hide/Show may itself enter manager glue. Put the sourced point back
       once more immediately before the patched trap tail-chains. */
    if (continuity_tracking_source_point(&pt)) {
        LMSetMouseLocation(pt);
        cell->tracking_settle_reasserts++;
    }
}

/* Normal mouse-up keeps the held source alive until the PPC application's
   corrected Cursor Device move and button-up have both returned. This final
   task-time step makes the last host point authoritative for the redraw,
   then removes the source and balances the optional HideCursor. */
void now_ext_cursor_complete_continuity_tracking(void)
{
    Point pt;
    Boolean have_point = continuity_tracking_source_point(&pt);

    now_ext_cursor_end_continuity_tracking();
    if (have_point)
        LMSetMouseLocation(pt);
    if (gNowCursorTrackingCursorHidden) {
        gNowCursorTrackingCursorHidden = 0;
        ShowCursor();
    } else if (have_point) {
        *gCrsrObscure = 0;
        HideCursor();
        ShowCursor();
    }
}

/* Install the three tracking-loop hooks lazily in the CURRENT process context.

   The act plane proved on metal that Toolbox trap dispatch can differ between
   process contexts: installing a patch while NOW is running does not imply the
   Finder's next MenuSelect/StillDown/GetMouse will see it. Continuity first
   installs here from NOW's arm path, then now_ext_cursor_gne() repeats this
   bounded check while the held source is active. The target process therefore
   installs its own links on the jGNE pass that returns the synthetic mouseDown,
   before it enters the nested tracking loop.

   The links are permanent for this boot. Another extension may subsequently
   chain behind us, so removing our link later could strand its incumbent
   pointer. */
int now_ext_cursor_enable_continuity_tracking(void)
{
    void *getmouse;
    void *stilldown;
    void *button;
    Boolean getmouse_ours;
    Boolean stilldown_ours;
    Boolean button_ours;

    if (gTable == NULL)
        return 0;

    getmouse = (void *)NGetTrapAddress(kNowGetMouseTrap, ToolTrap);
    stilldown = (void *)NGetTrapAddress(kNowStillDownTrap, ToolTrap);
    button = (void *)NGetTrapAddress(kNowButtonTrap, ToolTrap);
    if (getmouse == NULL || stilldown == NULL || button == NULL)
        return 0;
    getmouse_ours = getmouse == (void *)now_cursor_getmouse_patch;
    stilldown_ours = stilldown == (void *)now_cursor_stilldown_patch;
    button_ours = button == (void *)now_cursor_button_patch;
    if (getmouse_ours && stilldown_ours && button_ours)
        return 1;
    /* A mixed set cannot be repaired safely: saving one of our own shims as an
       incumbent would make that hook tail-chain to itself forever. Installation
       snapshots all three before changing any, so this means foreign mutation
       or a previously interrupted install and must fail closed. */
    if (getmouse_ours || stilldown_ours || button_ours)
        return 0;

    gNowCursorOldGetMouse = getmouse;
    gNowCursorOldStillDown = stilldown;
    gNowCursorOldButton = button;
    NSetTrapAddress((UniversalProcPtr)now_cursor_getmouse_patch,
                    kNowGetMouseTrap, ToolTrap);
    NSetTrapAddress((UniversalProcPtr)now_cursor_stilldown_patch,
                    kNowStillDownTrap, ToolTrap);
    NSetTrapAddress((UniversalProcPtr)now_cursor_button_patch,
                    kNowButtonTrap, ToolTrap);
    gTable->rest_state |=
        (NowPeekU16)kNowPeekRestCursorTrackingPatched;
    return 1;
}

/* MBState is shared with the physical driver. When Continuity deliberately
   changes it, advance the sampler's expected value so the next sample does
   not report our own transition as local takeover. A later ADB/USB change is
   still different and therefore wins. */
void now_ext_cursor_remember_continuity_button(unsigned down)
{
    gPhysicalButtons = down ? 1u : 0u;
    gPhysicalButtonsValid = true;
}

/* Revoking authority also revokes an interrupt-published redraw debt. Without
   this, the following jGNE pass can move the manager back to a stale host
   point after Continuity has already reported that the guest took over. */
void now_ext_cursor_cancel_task_apply(void)
{
    if (gTaskApplyOwed || gNowCursorTrackingRedrawOwed)
        gDebtCancels++;
    gTaskApplyOwed = false;
    now_ext_cursor_end_continuity_tracking();
    if (gNowCursorTrackingCursorHidden) {
        gNowCursorTrackingCursorHidden = 0;
        ShowCursor();
    }
}

void now_ext_cursor_input_diagnostics(NowCursorInputDiagnostics *out)
{
    if (out == NULL)
        return;
    out->sequence = gPhysicalInputSeq;
    out->samples = gPhysicalSamples;
    out->changes = gPhysicalChanges;
    out->trigger = gPhysicalTrigger;
    out->h = (NowPeekI32)gPhysicalReportedWhere.h;
    out->v = (NowPeekI32)gPhysicalReportedWhere.v;
    out->owned_h = (NowPeekI32)gOwnedDeviceWhere.h;
    out->owned_v = (NowPeekI32)gOwnedDeviceWhere.v;
    out->buttons = (NowPeekU32)gPhysicalButtons;
    out->physical_valid = gPhysicalValid ? 1u : 0u;
    out->owned_valid = gOwnedDeviceValid ? 1u : 0u;
    out->debt_cancels = gDebtCancels;
}

/* The cursor cell, or NULL when this table is too short to hold one.
   The accretive rule's other half, and the same check the drag cell
   makes: an application built against P8 talking to a resident that
   predates it must find NOTHING here rather than write past the end of a
   system-heap block sized by a different binary. */
NowPeekCursorCell *now_ext_cursor_cell(NowPeekTable *table)
{
    if (table == NULL) {
        return NULL;
    }
    if (table->magic != (NowPeekU32)kNowPeekTableMagic) {
        return NULL;
    }
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, cursor)
                                     + sizeof(NowPeekCursorCell))) {
        return NULL;
    }
    if (table->cursor_format != (NowPeekU32)kNowPeekCursorFormatV1) {
        return NULL;
    }
    return &table->cursor;
}

/* Is the manager actually there? A trap word whose entry equals
   _Unimplemented's is a trap the ROM does not serve, and issuing it
   would run whatever _Unimplemented does - which on a Macintosh is not a
   polite error return. Every plane in this extension that reaches for a
   trap asks this first; the one that did not is not in the tree any
   more. */
static Boolean cursor_manager_present(void)
{
    UniversalProcPtr here =
        NGetTrapAddress(kNowCursorDeviceTrap, ToolTrap);
    UniversalProcPtr unimpl =
        NGetTrapAddress(kNowUnimplementedTrap, ToolTrap);
    return here != NULL && here != unimpl;
}

/* Put the pointer somewhere, and make the machine agree that it is
   there - both halves, in the order that matters.
 *
 * Returns the kNowPeekCursorRoute* that served it. `owned` is 1 when the
 * caller is holding the pointer for the duration of a gesture and must
 * never yield.
 *
 * INTERRUPT-SAFE: the P7 drag task calls this every tick. Continuity has a
 * narrower MouseLocation-only path in now_ext_continuity.c. The
 * interrupt branch returns after low-memory writes and a preallocated debt;
 * it neither dereferences Cursor Device records nor calls a manager. */
int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, unsigned flags)
{
    NowPeekCursorCell *cell = now_ext_cursor_cell(gTable);
    Point pt;
    Point raw;
    unsigned long now;
    int route;

    pt.h = (short)h;
    pt.v = (short)v;

    if (flags & kNowCursorPlaceInterrupt) {
        /* This is deliberately the complete interrupt-time surface. A call
           that is safe inside an ADB driver's private interrupt contract is
           not thereby safe inside an unrelated Time Manager callback. */
        LMSetMouseTemp(pt);
        LMSetRawMouseLocation(pt);
        LMSetMouseLocation(pt);
        remember_owned_lowmem_point(pt);
        gTaskH = h;
        gTaskV = v;
        if (flags & kNowCursorPlaceApplicationRedraw) {
            /* A low-memory byte, not QuickDraw: a real device report clears
               this before the cursor is redrawn too. The PPC application
               performs the balanced HideCursor/ShowCursor at task time. */
            *gCrsrObscure = 0;
        } else {
            gTaskApplyOwed = true;   /* publish after the coordinates */
        }
        if (cell != NULL) {
            cell->seq++;
            cell->asked++;
            cell->at_h = h;
            cell->at_v = v;
            cell->by_lowmem++;
            cell->route = (NowPeekU32)kNowPeekCursorRouteLowMem;
            cell->seq++;
        }
        return kNowPeekCursorRouteLowMem;
    }

    /* WHO MOVED IT LAST, asked of the MANAGER rather than of RawMouse.
       It was RawMouse, and that was wrong in a way only driving found:
       between placements, with nothing holding the globals, RawMouse
       drifts back to the pointing device's own position - so every act
       after any device motion looked like a person had just moved the
       mouse, and the plane yielded forever. Four acts in a row reported
       `yielded` on a machine nobody was sitting at (2026-08-07).

       CursorData.where is the manager's own idea of the pointer. Only a
       real device moves it, and our own CursorDeviceMoveTo, whose value
       we already know. Asked BEFORE our writes, or the answer is always
       "us". */
    now = (unsigned long)LMGetTicks();
    if (gDevice != NULL && gDevice->whichCursor != NULL) {
        raw = gDevice->whichCursor->where;
    } else {
        raw = LMGetRawMouseLocation();
    }
    if (now_cursor_is_foreign((NowPeekI32)raw.h, (NowPeekI32)raw.v,
                              (NowPeekI32)gLastPlaced.h,
                              (NowPeekI32)gLastPlaced.v,
                              gEverPlaced ? 1 : 0)) {
        gForeignTicks = now;
    }

    /* The position, always. An act must land where it says whether or
       not the picture is allowed to follow, and a tracking loop reads
       these and not the sprite. This is the half that was never broken
       and it is not conditional on anything. */
    LMSetMouseTemp(pt);
    LMSetRawMouseLocation(pt);
    LMSetMouseLocation(pt);
    /* gLastPlaced IS NOT UPDATED HERE, and that is the second half of
       the same defect.
     *
       It tracks where this resident last moved the DEVICE, because the
       device's own record is what the foreign check reads. Setting it
       here recorded points we had decided NOT to move the device to, so
       one yield poisoned every placement after it: the device still held
       the pointer's real position, `gLastPlaced` held the point we
       declined to use, the two could never agree again, and the plane
       yielded for the rest of the boot. Driven 2026-08-07 - `asked 2,
       yielded 2`, the two acts minutes apart and the 60-tick courtesy
       window long expired. It is assigned on the branches below, each of
       which has actually moved the device. */

    if (cell != NULL) {
        cell->seq++;                        /* odd: writing */
        cell->asked++;
        cell->at_h = h;
        cell->at_v = v;
    }

    if (now_cursor_should_yield((NowPeekU32)now, (NowPeekU32)gForeignTicks,
                                (flags & kNowCursorPlaceOwned) ? 1 : 0,
                                (NowPeekU32)kNowPeekCursorYieldTicks)) {
        route = kNowPeekCursorRouteYielded;
        if (cell != NULL) {
            cell->yielded++;
        }
    } else {
        /* THE ONLY ROUTE THAT MOVES THE PICTURE, and it is the crudest
           of the three.

           Everything upstream is already correct by the time we get
           here: the low-memory globals hold the point, and the Cursor
           Device Manager's own record does too - CursorDeviceMoveTo
           answers noErr and `where` reads back exactly right, verified
           from outside the guest. What none of that does is DRAW. On
           Mac OS 9 the blit happens somewhere in the pointing device's
           own interrupt path, and neither CrsrNew nor a direct call
           through JCrsrTask reaches it; both were tried and both left
           the arrow where the emulated device had last put it.

           HideCursor erases the sprite from wherever it is actually
           drawn; ShowCursor draws it at the current mouse position,
           which is the one we just wrote. The SHAPE is preserved -
           this pair is a nesting counter, not a cursor setter - so an
           application's own SetCursor still decides what is drawn.

           It needs a real context: HideCursor and ShowCursor are
           QuickDraw and are not interrupt-safe. The act plane has one,
           because it runs inside the target application's jGNE filter.
           The drag vehicle does not, which is why the flag exists and
           why a drag still reports `device` and is still invisible. */
        (void)now_cdm_move_to(gDevice, (long)h, (long)v);
        remember_owned_device_point(pt);
        *gCrsrObscure = 0;
        HideCursor();
        ShowCursor();
        gTaskApplyOwed = false;
        route = kNowPeekCursorRouteQuickDraw;
        if (cell != NULL) {
            cell->by_device++;
        }
    }

    /* Every branch above except the yield has moved the pointer - by the
       manager where there is one, and by RawMouse where there is not,
       which is the same global the foreign check falls back to reading.
       So this is exactly "where we last put it", and the yield branch
       deliberately leaves it alone: see the note beside the low-memory
       writes for the boot this cost. */
    if (route != kNowPeekCursorRouteYielded) {
        gLastPlaced = pt;
        gEverPlaced = true;
    }

    if (cell != NULL) {
        cell->route = (NowPeekU32)route;
        cell->seq++;                        /* even: settled */
    }
    return route;
}

/* Settle a redraw the interrupt-time caller could not perform.
 *
 * Called from the core's jGNE pass, in whatever process is pumping,
 * which is the first moment since the placement that QuickDraw may be
 * called at all. It is deliberately NOT gated on the act plane being
 * armed: the debt is a picture that disagrees with the machine, and
 * disarming the plane does not make the arrow correct again.
 *
 * Native movement is sampled from the driver-owned CursorData record before
 * this routine runs. The debt itself is owned input and always settles the
 * latest point; letting the manager's stale record veto it recreates the
 * fight this task-time split is meant to remove. */
void now_ext_cursor_gne(NowPeekTable *table)
{
    NowPeekCursorCell *cell;
    Point pt;
    NowPeekI32 h;
    NowPeekI32 v;
    long err = 0;

    (void)table;
    /* The active source is published before the target dequeues mouseDown.
       Install in that target's trap context on this very jGNE pass; an install
       performed only by NOW cannot protect a Finder/Menu Manager tracking loop. */
    if (gNowCursorTrackingSourceActive)
        (void)now_ext_cursor_enable_continuity_tracking();
    if (!gNowCursorTrackingSourceActive
            && gNowCursorTrackingCursorHidden) {
        /* A timer may revoke a starved release source, but it may not enter
           QuickDraw. The first subsequent task-time pass balances the hide
           without restoring a stale host point over native input. */
        gNowCursorTrackingCursorHidden = 0;
        ShowCursor();
    }
    if (!gTaskApplyOwed) {
        return;
    }
    /* Snapshot after observing the debt. A timer may publish a newer point
       while this task-time apply runs; only clear the debt if the snapshot
       is still current afterwards. */
    h = gTaskH;
    v = gTaskV;
    pt.h = (short)h;
    pt.v = (short)v;
    gTaskApplySeq++;                  /* odd: manager apply in progress */
    if (gDevice != NULL)
        err = now_cdm_move_to(gDevice, (long)h, (long)v);
    remember_owned_device_point(pt);
    *gCrsrObscure = 0;
    HideCursor();
    ShowCursor();
    gLastPlaced = pt;
    gEverPlaced = true;
    pt = LMGetRawMouseLocation();
    gTaskAppliedH = (NowPeekI32)pt.h;
    gTaskAppliedV = (NowPeekI32)pt.v;
    gTaskApplySeq++;                  /* even: applied position committed */
    if (gTaskH == h && gTaskV == v)
        gTaskApplyOwed = false;
    cell = now_ext_cursor_cell(gTable);
    if (cell != NULL) {
        cell->seq++;
        cell->route = (NowPeekU32)kNowPeekCursorRouteQuickDraw;
        if (err != 0)
            cell->last_err = (NowPeekI32)err;
        else
            cell->by_device++;
        cell->seq++;
    }
}

/* Ask the manager for a device, once, at boot.
 *
 * The capability bit is published only if BOTH the trap is implemented
 * and a device came back, so an application never arms a plane that
 * cannot fire - the same rule P7's install follows. A machine with no
 * cursor device is not a broken machine and this is not an error: every
 * act and every drag behaves exactly as it did before P8, and the
 * picture is the only thing missing. That is the resident-component
 * charter's whole rule about optional components, and it is why the
 * fallback below is a route and not a failure. */
int now_ext_cursor_boot(NowPeekTable *table)
{
    NowPeekCursorCell *cell;
    void *device = NULL;

    if (table == NULL || gBooted) {
        return 0;
    }
    gTable = table;
    gBooted = true;
    gLastPlaced.h = 0;
    gLastPlaced.v = 0;
    gEverPlaced = false;
    gPhysicalValid = false;
    gPhysicalButtonsValid = false;
    gPhysicalRawValid = false;
    gPhysicalReportedWhere.h = 0;
    gPhysicalReportedWhere.v = 0;
    gOwnedDeviceValid = false;
    gOwnedDeviceHistory.seq = 0;
    gOwnedDeviceHistory.next = 0;
    gOwnedDeviceHistory.used = 0;
    gOwnedTrackingHistory.seq = 0;
    gOwnedTrackingHistory.next = 0;
    gOwnedTrackingHistory.used = 0;
    gNowCursorTrackingRedrawOwed = 0;
    gNowCursorTrackingSourceActive = 0;
    gNowCursorTrackingHideGuestCursor = 0;
    gNowCursorTrackingCursorHidden = 0;
    gNowCursorTrackingSourceSeq = 0;
    gNowCursorTrackingSourceH = 0;
    gNowCursorTrackingSourceV = 0;
    gNowCursorOldGetMouse = NULL;
    gNowCursorOldStillDown = NULL;
    gNowCursorOldButton = NULL;

    /* THE CELL IS REACHED DIRECTLY HERE, and only here.
       now_ext_cursor_cell() checks `magic`, and at boot MAGIC HAS NOT
       COMMITTED YET - the core writes it last, deliberately, so that a
       reader which sees the table the instant it becomes valid finds
       every plane already advertised. So the accessor answers NULL for
       the resident's own table during its own boot, and the first build
       of this plane used it: cursor_format was zeroed, the capability
       bit was never published, `mouseloc` reported no rows, and the
       whole plane read exactly like a machine whose Cursor Device
       Manager had no device. Watched 2026-08-07, caps=255.

       P7's boot writes `table->drag.state` directly for the same reason.
       The LENGTH check is kept, because that one is about the block this
       binary allocated and is meaningful now. */
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, cursor)
                                     + sizeof(NowPeekCursorCell))) {
        now_ext_cursor_rollback(table);
        return 0;
    }
    table->cursor_format = (NowPeekU32)kNowPeekCursorFormatV1;
    cell = &table->cursor;
    cell->seq = 0;
    cell->route = (NowPeekU32)kNowPeekCursorRouteNone;
    cell->asked = 0;
    cell->by_device = 0;
    cell->by_lowmem = 0;
    cell->yielded = 0;
    cell->last_err = 0;
    cell->device_found = 0;

    if (!cursor_manager_present()) {
        return 1;                    /* optional capability, valid absence */
    }
    /* NULL in, first device out - the manager's own idiom. A non-zero
       OSErr or a NULL device both mean the same thing here and are not
       distinguished, because there is nothing different to do about
       them. */
    if (now_cdm_next_device(&device) != 0 || device == NULL) {
        return 1;                    /* optional capability, valid absence */
    }
    gDevice = (CursorDevicePtr)device;
    cell->device_found = 1;
    table->caps |= (NowPeekU32)kNowPeekTableCapCursor;
    return 1;
}

void now_ext_cursor_rollback(NowPeekTable *table)
{
    if (table != NULL) {
        table->cursor_format = 0;
        table->caps &= ~(NowPeekU32)kNowPeekTableCapCursor;
        table->cursor.device_found = 0;
    }
    gTable = NULL;
    gDevice = NULL;
    gLastPlaced.h = 0;
    gLastPlaced.v = 0;
    gForeignTicks = 0;
    gBooted = false;
    gEverPlaced = false;
    gTaskApplyOwed = false;
    gNowCursorTrackingRedrawOwed = 0;
    gNowCursorTrackingSourceActive = 0;
    gNowCursorTrackingSourceSeq = 0;
    gNowCursorTrackingSourceH = 0;
    gNowCursorTrackingSourceV = 0;
    gTaskH = 0;
    gTaskV = 0;
    gTaskApplySeq = 0;
    gTaskAppliedH = 0;
    gTaskAppliedV = 0;
    gPhysicalInputSeq = 0;
    gPhysicalSamples = 0;
    gPhysicalChanges = 0;
    gPhysicalTrigger = 0;
    gDebtCancels = 0;
    gPhysicalButtons = 0;
    gPhysicalButtonsValid = false;
    gPhysicalValid = false;
    gPhysicalRawValid = false;
    gOwnedDeviceValid = false;
    gOwnedDeviceHistory.seq = 0;
    gOwnedDeviceHistory.next = 0;
    gOwnedDeviceHistory.used = 0;
    gOwnedTrackingHistory.seq = 0;
    gOwnedTrackingHistory.next = 0;
    gOwnedTrackingHistory.used = 0;
    gNowCursorOldGetMouse = NULL;
    gNowCursorOldStillDown = NULL;
    gNowCursorOldButton = NULL;
}
