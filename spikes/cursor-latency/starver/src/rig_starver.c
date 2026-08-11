/*
 * rig_starver.c - CursorRig's load generator. It exists to make the
 * guest busy in the specific ways that break cursor motion, on command,
 * repeatably.
 *
 * THIS IS A RIG. See README.md.
 *
 * It is not a garnish. "While the guest is doing other things" is the
 * condition under which the defect exists at all, and this lab has a
 * long documented history of instruments whose normal mode of operation
 * is the one condition under which the defect cannot appear. A cursor
 * measurement taken against an idle Finder answers a question nobody
 * asked.
 *
 * The profiles are shaped after what actually holds a classic Mac: a
 * tracking loop is not merely "CPU busy", it is an application spinning
 * on StillDown/GetMouse *without ever reaching WaitNextEvent*, which is
 * what stops every other application AND stops the event-loop moment
 * the cursor's picture is settled in. Those are two different harms and
 * the profiles separate them - kRigLoadPolite is heavy work that still
 * pumps, so a difference between it and kRigLoadSpin is attributable.
 *
 * Commands arrive through the resident's table, not over a socket. The
 * generator must not add traffic to the wire whose latency is being
 * measured.
 */

#include <Carbon.h>

#include "cursor_rig.h"

static RigTable *gTable;
static Boolean   gQuit;
static WindowRef gWindow;

static RigU32 now_ticks(void)
{
    return (RigU32)TickCount();
}

/* Work that cannot be optimised away and does not touch the Toolbox.
   The accumulator is returned so the compiler must keep the loop. */
static unsigned long grind(unsigned long seed)
{
    int i;

    for (i = 0; i < 20000; ++i) {
        seed = seed * 1103515245UL + 12345UL;
        seed ^= seed >> 7;
    }
    return seed;
}

static void run_spin(RigU32 until)
{
    unsigned long acc = 1;

    while (now_ticks() < until) {
        acc = grind(acc);
    }
    gTable->load_finished = (RigU32)acc & 1U;    /* keep the work honest */
}

/* The DragGrayRgn shape. StillDown and GetMouse are what a tracking
   loop calls, and calling them is not incidental: GetMouse reads the
   very low-memory location the resident writes, so this profile is also
   the one that proves an application in a tracking loop SEES the
   rig's positions. */
static void run_tracking(RigU32 until)
{
    Point where;

    while (now_ticks() < until) {
        GetMouse(&where);
        (void)StillDown();
    }
}

/* Screen contention rather than processor contention: QuickDraw into a
   window as fast as it will go. The cursor's picture is a blit too, and
   a rig that only ever measured CPU starvation would miss a pointer
   that stutters because something else owns the screen. */
static void run_drawing(RigU32 until)
{
    Rect r;
    short i = 0;
    GrafPtr save;

    if (gWindow == NULL) {
        run_spin(until);
        return;
    }
    GetPort(&save);
    SetPortWindowPort(gWindow);
    while (now_ticks() < until) {
        SetRect(&r, (short)(i % 200), (short)(i % 120),
                (short)((i % 200) + 60), (short)((i % 120) + 40));
        InvertRect(&r);
        i += 7;
    }
    SetPort(save);
}

/* Heavy, but it pumps. The contrast case: if the pointer is fine here
   and bad under kRigLoadSpin, the harm is the event loop and not the
   processor. */
static void run_polite(RigU32 until)
{
    EventRecord event;
    unsigned long acc = 1;

    while (now_ticks() < until) {
        acc = grind(acc);
        WaitNextEvent(everyEvent, &event, 0, NULL);
    }
    gTable->load_finished = (RigU32)acc & 1U;
}

static void run_profile(RigU32 profile, RigU32 ticks)
{
    RigU32 until = now_ticks() + ticks;

    gTable->load_started = now_ticks();
    gTable->load_running = 1;
    switch (profile) {
    case kRigLoadSpin:      run_spin(until);      break;
    case kRigLoadTracking:  run_tracking(until);  break;
    case kRigLoadDrawing:   run_drawing(until);   break;
    case kRigLoadPolite:    run_polite(until);    break;
    default:                                      break;   /* idle */
    }
    gTable->load_running = 0;
}

static Boolean find_table(void)
{
    long response = 0;

    if (Gestalt((OSType)kRigGestaltSelector, &response) != noErr) {
        return false;
    }
    gTable = (RigTable *)response;
    return gTable != NULL && gTable->magic == kRigTableMagic;
}

int main(void)
{
    EventRecord event;
    RigU32 seen = 0;
    Rect bounds;

    if (!find_table()) {
        ParamText((ConstStr255Param)"\pCursorRig Starver: the extension is "
                  "not resident.", (ConstStr255Param)"\p",
                  (ConstStr255Param)"\p", (ConstStr255Param)"\p");
        StopAlert(128, NULL);
        return 1;
    }
    seen = gTable->load_seq;

    /* A small window, off in a corner, only so kRigLoadDrawing has
       somewhere to draw. It is deliberately NOT where the rig drives
       the pointer. */
    SetRect(&bounds, 20, 60, 240, 200);
    gWindow = NewCWindow(NULL, &bounds, (ConstStr255Param)"\pRIG LOAD",
                         true, documentProc, (WindowRef)-1L, false, 0);

    while (!gQuit) {
        if (gTable->load_seq != seen) {
            seen = gTable->load_seq;
            run_profile(gTable->load_profile, gTable->load_ticks);
        }
        if (WaitNextEvent(everyEvent, &event, 2, NULL)) {
            if (event.what == keyDown
                && (event.modifiers & cmdKey) != 0
                && (char)(event.message & charCodeMask) == 'q') {
                gQuit = true;
            }
        }
    }
    if (gWindow != NULL) {
        DisposeWindow(gWindow);
    }
    return 0;
}
