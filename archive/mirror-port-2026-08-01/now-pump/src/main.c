/*
 * now-pump - the act plane's posting context.
 *
 * A faceless 68K background application whose entire job is one thing NOW
 * cannot do from either of the places it already runs: queue a mouse
 * press, with `where` under its own control, from a CLASSIC process's own
 * context.
 *
 * WHY IT EXISTS. Three of the act ops arm a guarded trap patch in a
 * target process and then need that application to CALL the trap - which
 * a user does by clicking. Every other candidate is closed, each by a
 * measurement rather than by taste:
 *
 *   - the PowerPC application cannot post: PPostEvent and the low-memory
 *     mouse globals are CALL_NOT_IN_CARBON, and PostEvent hands back no
 *     queue element to stamp `where` on;
 *   - the resident filter CAN call PPostEvent (it is 68K, not Carbon) and
 *     does so today - and it does not deliver, because a background
 *     Carbon application's WaitNextEvent never falls through to the
 *     classic Event Manager, so the filter never runs in the posting
 *     context it needs (docs/open-issues.md, act-click-no-pass);
 *   - injecting mouse MOTION would need the emulator's QMP, which does
 *     not exist on metal and is forbidden in this plane.
 *
 * The sibling Mirror project answers this with an ordinary classic
 * application posting from its own context once the target has armed
 * (mirror guest/app/src/mirrorverbs.c, post_click_at, called from verb
 * context) and measures 20/20 on each window op. This file is the port of
 * that shape, minus the wire: NOTHING here inherits that measurement, and
 * nothing in this tree has watched a NOW click land.
 *
 * WHAT IT IS NOT. It speaks no wire, opens no port, reads no file and
 * shows no interface. Its whole interface is the shared table's pump cell
 * (contract/peek_table.h, P4b) and every decision it makes is made by
 * now_act_guard.c, which a host cc compiles and now-guest-shared/tests/
 * act_pump_test.c exercises. The Toolbox calls below are the part no test
 * here can reach, and they are deliberately the only part.
 *
 * WHY 68K on a PowerPC Mac. A 68K application's WaitNextEvent provably
 * reaches the classic Event Manager - that is the whole property being
 * bought - and it runs under emulation on every machine in the supported
 * range. There is no PowerPC advantage to trade for it: this process
 * computes nothing.
 *
 * TARGET CONTRACT. Classic 68K CODE-resource application, -mcpu=68000, no
 * segmentation. Mac OS 8.6-9.2.2 beside the NOW Extension (which is what
 * publishes the table it serves); System 7.1 would do as far as the calls
 * go, but the plane it serves is the PowerPC application's. Launched by
 * that application with LaunchApplication, and quit by a kAEQuitApplication
 * Apple Event - or by its own heartbeat watch, below.
 */
#include <AppleEvents.h>
#include <Dialogs.h>
#include <Events.h>
#include <Fonts.h>
#include <Gestalt.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <Menus.h>
#include <Processes.h>
#include <Quickdraw.h>
#include <TextEdit.h>

#include "now_act_guard.h"
#include "peek_table.h"

/* Idle sleep, in ticks. The pump must answer a click promptly - the
 * application arming a patch is already waiting on its own deadline - but
 * it must also not starve the applications it exists to drive, which is
 * the whole reason it is faceless. Two ticks is ~33 ms: a third of a
 * WaitNextEvent quantum against a 300-tick caller deadline. */
#define kPumpSleepTicks 2L

/* The event mask, and it is deliberately BROAD.
 *
 * everyEvent looks wrong for a process that injects clicks for ANOTHER
 * application to consume: it makes this one a rival consumer of its own
 * posted events. That reasoning is plausible and upstream MEASURED it
 * wrong - narrowing the mask took actuation from 9/20 to 0/20 on the
 * sibling project's agent (mirror docs/STATUS.md, 2026-07-29, N=20 per
 * configuration). Whatever the broad mask does for the Event Manager, the
 * application being driven needs it.
 *
 * The SIZE resource is what keeps the events away from us rather than the
 * mask: onlyBackground and dontGetFrontClicks mean a click belongs to the
 * application under the pointer, never to a process with no window. */
#define kPumpEventMask everyEvent

static int g_quit;

static pascal OSErr handle_quit_ae(const AppleEvent *event,
                                   AppleEvent *reply, long refcon);

/* We own the Toolbox; initialise it before any Manager call. Even a
 * faceless application initialises the Managers it never draws with: the
 * Event Manager's own dispatch assumes a running application, and
 * WaitNextEvent is the one call this process exists to make. */
static void pump_init_toolbox(void)
{
    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(NULL);
    /* No InitCursor, and no menu bar: this process must not perturb the
     * application it is driving, and the cursor belongs to the act plane
     * (which moves it to the click point) rather than to us. */
    MoreMasters();
    MoreMasters();
}

/* The extension's table, by the same Gestalt selector every other reader
 * uses. Absent means the NOW Extension is not installed on this Mac, and
 * a pump with no table has nothing to serve and no way to be asked for
 * anything: it exits rather than idling invisibly forever. */
static NowPeekTable *pump_find_table(void)
{
    long response = 0;

    if (Gestalt((OSType)kNowPeekGestaltSelector, &response) != noErr) {
        return NULL;
    }
    if (response == 0) {
        return NULL;
    }
    return (NowPeekTable *)response;
}

/* Queue one press, or several, at a point of our choosing.
 *
 * Carried from ext/src/now_ext_act.c's act_post_click, which is itself the
 * port of Mirror's post_click_at, with the two things that path could not
 * carry: the modifiers and the press count. Both are the caller's, and
 * both are stamped on the queue ELEMENT rather than left to the machine's
 * live state - which is the whole reason this uses PPostEvent and not
 * PostEvent. The ADB (metal) or emulated (emu) mouse VBL can overwrite
 * MouseLocation between our write and the application's dequeue, and the
 * click would then land wherever the real pointer happens to be. For this
 * plane that is not a cosmetic bug: the point IS the guard's identity
 * check, so a click that lands elsewhere is refused by our own patch.
 *
 * Returns 1 when every event was queued. */
static int pump_post_click(long h, long v, long mods, long count)
{
    Point pt;
    long  i;

    pt.h = (short)h;
    pt.v = (short)v;

    /* Cosmetic, plus applications that re-read GetMouse for themselves.
     * The authoritative location is stamped per event below. */
    LMSetMouseTemp(pt);
    LMSetRawMouseLocation(pt);
    LMSetMouseLocation(pt);

    for (i = 0; i < count; i++) {
        EvQElPtr down = NULL;
        EvQElPtr up = NULL;

        if (i > 0) {
            /* A gap between the presses of a set, well under GetDblTime,
             * so a double-click reads as one gesture rather than as two
             * clicks that happened to be adjacent. */
            unsigned long start = (unsigned long)TickCount();

            while ((unsigned long)TickCount() - start < 3UL) {
            }
        }
        LMSetMouseButtonState(0x00);          /* button down */
        if (PPostEvent(mouseDown, 0, &down) != noErr || down == NULL) {
            LMSetMouseButtonState(0x80);
            return 0;
        }
        down->evtQWhere = pt;
        down->evtQModifiers = (short)mods;
        LMSetMouseButtonState(0x80);          /* button up */
        if (PPostEvent(mouseUp, 0, &up) != noErr || up == NULL) {
            return 0;
        }
        up->evtQWhere = pt;
        up->evtQModifiers = (short)mods;
    }
    return 1;
}

static pascal OSErr handle_quit_ae(const AppleEvent *event,
                                   AppleEvent *reply, long refcon)
{
    (void)event;
    (void)reply;
    (void)refcon;
    /* The application's own teardown at the end of a host session, and
     * the Finder's at shutdown, arrive the same way. Set the flag rather
     * than exiting here: the loop below still owes the table a detach,
     * and a pump that vanished without writing one reads afterwards
     * exactly like a pump that crashed. */
    g_quit = 1;
    return noErr;
}

static void pump_install_quit_handler(void)
{
    AEEventHandlerUPP upp = NewAEEventHandlerUPP(handle_quit_ae);

    if (upp == NULL) {
        return;                     /* the heartbeat still reaps us */
    }
    (void)AEInstallEventHandler(kCoreEventClass, kAEQuitApplication, upp,
                                0, false);
}

int main(void)
{
    NowPeekTable    *table;
    NowPeekActPump  *pump;
    unsigned long    started;
    int              seen_session = 0;

    pump_init_toolbox();
    pump_install_quit_handler();

    table = pump_find_table();
    pump = now_act_pump(table);
    if (pump == NULL) {
        /* No extension, or one that predates this handshake. Nothing to
         * serve and no channel to say so on - the application that
         * launched us sees pump_state stay at None and reports THAT,
         * which is the honest shape of this failure. */
        return 0;
    }

    started = (unsigned long)TickCount();

    /* One pump per machine. A second one would double every click - two
     * presses where the caller asked for one - and the caller would see
     * its own request succeed, so nothing downstream could catch it. The
     * already-running pump keeps the job; this process is the one that
     * yields, because it is the one that knows it is late. */
    if (now_act_pump_alive(pump, started)) {
        return 0;
    }

    now_act_pump_attach(pump, started);

    while (!g_quit) {
        EventRecord      event;
        NowActClickOrder order;
        unsigned long    now;

        if (WaitNextEvent(kPumpEventMask, &event, kPumpSleepTicks, NULL)) {
            if (event.what == kHighLevelEvent) {
                (void)AEProcessAppleEvent(&event);
            }
            /* Everything else is dropped on purpose. This process owns no
             * window, no menu bar and no document; an event that reached
             * it either belongs to nobody or was never ours to act on. */
        }

        now = (unsigned long)TickCount();
        now_act_pump_beat(pump, now);

        /* The click, from THIS process's context - which is the entire
         * reason this application exists. The filter has already armed
         * the patch in the target's own context by the time the request
         * appears here, so the order is the one Mirror measured: arm
         * first, then press. */
        if (now_act_pump_click_due(pump, &order)) {
            int ok = pump_post_click(order.h, order.v, order.mods,
                                     order.count);

            now_act_pump_click_done(pump, order.ticket,
                                    ok ? (unsigned long)kNowPeekActErrNone
                                       : (unsigned long)
                                             kNowPeekActErrPostFailed);
        }

        if (now_act_session_alive(pump, now)) {
            seen_session = 1;
        }
        /* THE ORPHAN WATCH. The application launches this process and asks
         * it to quit at the end of a session - and neither half of that
         * survives a crash. A host that dies, or a guest application that
         * takes a Type 11, would otherwise leave a faceless process with
         * no window to close and nothing on screen to say it is there. A
         * component that can be orphaned by the failure of the thing that
         * started it is not optional in any useful sense. */
        if (now_act_pump_should_exit(pump, now, started, seen_session)) {
            break;
        }
    }

    /* Written before we go, so a reader can tell this from a crash: a
     * crash leaves Running behind a heartbeat that simply stops. */
    now_act_pump_detach(pump);
    return 0;
}
