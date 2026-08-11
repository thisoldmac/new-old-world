/*
 * NOW-68K - guest client for the PowerBook 180c (33 MHz 68030, 4 MB RAM,
 * System 7.1, MacTCP - Open Transport cannot link on Retro68 68K, ASLM).
 * Dial-out only: the human types host/port/timeout by hand each launch.
 * No preferences or persistence in this pass; a fixed-interval redial the
 * human starts and stops from the window is the next milestone.
 *
 * This milestone is the skeleton: Toolbox init, a log that opens before any
 * connection setup work, one window, and an event loop with a real way out.
 * Connection setup itself is the next milestone - window.h's placeholder
 * shell exists so this proves BUILDS AND LAUNCHES on the target first.
 */
#include <Events.h>
#include <Quickdraw.h>
#include <Fonts.h>
#include <MacWindows.h>
#include <Menus.h>
#include <TextEdit.h>
#include <Dialogs.h>
#include <AppleEvents.h>
#include <Processes.h>
#include <Devices.h>
#include <Files.h>
#include <Memory.h>
#include <SegLoad.h>
#include <string.h>

#include "window.h"
#include "conwin.h"
#include "log.h"
#include "wire68.h"

#define kSleepTicks     6L      /* idle yield; no adaptive rate yet - nothing
                                   to drain between events until MacTCP lands */
#define kMenuBarID      128
#define kAppleMenuID    128
#define kFileMenuID     129
#define kWindowsMenuID  130
#define kAboutItem      1
#define kQuitItem       1
#define kConsoleItem    1

static int g_quit = 0;

/* THERE ARE TWO WINDOWS NOW, so nothing below may assume which one an event
 * is for. Until the interactive console landed (conwin.h - a deliberate,
 * argued exception to this guest's one-window rule) every event went
 * straight to window.c, and an update or a keystroke meant for the console
 * would have been drawn or typed into the connection panel instead. Every
 * routed event goes through here, and the window it names comes from the
 * event itself: (WindowPtr)message for update/activate, FindWindow's
 * `which` for a click, FrontWindow() for a key. */
static void route_event(EventRecord *event, WindowPtr target)
{
    if (conwin_owns(target)) {
        conwin_handle_event(event);
    } else {
        window_handle_event(event);
    }
}

static void init_toolbox(void)
{
    /* Both before anything allocates. The application heap will hold a ~100 KB
     * CODE handle, Toolbox handles and a MacTCP receive buffer inside 384 KB;
     * without these two the master-pointer blocks get interleaved with real
     * allocations and the heap fragments into a NewHandle failure hours in. */
    MaxApplZone();
    MoreMasters();
    MoreMasters();

    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(NULL);
    InitCursor();
}

/* Anchor cwd to the app's own folder before the log or any future config
 * file opens by relative name. Rumpus deposits builds on the Desktop, which
 * is NOT always the launch default dir - now/AGENTS.md and appe's
 * set_dir_to_app hit this already; skip it and the log silently misses. */
static void chdir_to_app_folder(void)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    FSSpec              spec;

    if (GetCurrentProcess(&psn) != noErr) {
        return;
    }
    memset(&info, 0, sizeof(info));
    info.processInfoLength = sizeof(info);
    info.processAppSpec    = &spec;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return;
    }
    (void)HSetVol(NULL, spec.vRefNum, spec.parID);
}

/* Without a menu bar there is no Cmd-Q and no About, and the only way to end
 * a run on the PowerBook is Special > Restart. That is not an acceptable
 * cost per test cycle on someone's laptop. */
static void init_menus(void)
{
    Handle    bar;
    MenuHandle apple;

    bar = GetNewMBar(kMenuBarID);
    if (bar == NULL) {
        now68k_log("menus: MBAR 128 missing");
        return;
    }
    SetMenuBar(bar);
    DisposeHandle(bar);

    apple = GetMenuHandle(kAppleMenuID);
    if (apple != NULL) {
        AppendResMenu(apple, 'DRVR');
    }
    DrawMenuBar();
}

static void do_menu(long choice)
{
    short menuID = (short)(choice >> 16);
    short item   = (short)(choice & 0xFFFF);
    Str255 daName;

    switch (menuID) {
    case kAppleMenuID:
        if (item == kAboutItem) {
            window_show_about();
        } else {
            GetMenuItemText(GetMenuHandle(kAppleMenuID), item, daName);
            (void)OpenDeskAcc(daName);
        }
        break;
    case kFileMenuID:
        if (item == kQuitItem) {
            g_quit = 1;
        }
        break;
    case kWindowsMenuID:
        if (item == kConsoleItem) {
            conwin_show();
        }
        break;
    default:
        break;
    }
    HiliteMenu(0);
}

/* Answers the Finder's Shut Down / Restart quit broadcast. Without this,
 * WaitNextEvent still DELIVERS the high-level event, but nothing processes
 * it, so the Finder waits forever for an application that will never quit. */
static pascal OSErr handle_quit_ae(const AppleEvent *ae, AppleEvent *reply,
                                   long refcon)
{
    (void)ae;
    (void)reply;
    (void)refcon;
    g_quit = 1;
    return noErr;
}

static void dispatch_mouse_down(EventRecord *event)
{
    WindowPtr which;
    short     part = FindWindow(event->where, &which);

    switch (part) {
    case inMenuBar:
        /* MenuSelect blocks for as long as a human rests on a pulled-down
         * menu, and it takes no action-proc callback on this Toolbox (unlike
         * TrackControl, which window.c already drives via a pump action proc
         * - see now-guest-ppc/src/core/pump.h and docs/guest-ui-start-here.md, where the
         * PowerPC guest documents this exact stall as unavoidable). Pumping
         * immediately before and after bounds the stall to the interaction
         * itself instead of letting it compound with whatever else is
         * pending; it does not make the menu-down window pump. Defect 14. */
        wire_idle();
        do_menu(MenuSelect(event->where));
        wire_idle();
        break;
    case inSysWindow:
        SystemClick(event, which);
        break;
    case inGoAway:
        /* The window is created with a close box; one that does nothing is
         * worse than none, because it reads as a hang. */
        /* Same bounded, uncallbacked stall as MenuSelect above - TrackGoAway
         * has no action proc either. Defect 14. */
        wire_idle();
        if (TrackGoAway(which, event->where)) {
            /* Closing the CONSOLE closes a window; closing the main panel
             * is still how a human ends the run. Getting this backwards
             * would make the console's close box quit the application,
             * dropping a live connection to dismiss a text window. */
            if (conwin_owns(which)) {
                conwin_close();
            } else {
                g_quit = 1;
            }
        }
        wire_idle();
        break;
    case inDrag:
        /* Same bounded, uncallbacked stall as MenuSelect above. Defect 14. */
        wire_idle();
        DragWindow(which, event->where, &qd.screenBits.bounds);
        wire_idle();
        break;
    case inContent:
        if (which != FrontWindow()) {
            SelectWindow(which);
        } else {
            route_event(event, which);
        }
        break;
    default:
        break;
    }
}

int main(void)
{
    EventRecord event;

    init_toolbox();
    chdir_to_app_folder();

    /* The log opens before any connection setup work. There is none yet in
     * this milestone, but that ordering IS the point: a hang during connect
     * must not be the case that leaves zero log lines. */
    now68k_log_open();
    now68k_log("main: toolbox init done");

    init_menus();
    /* After the log opens, before the window is created, per wire68.h. */
    wire_init();
    window_init();
    now68k_log("main: window init done");

    {
        AEEventHandlerUPP quitUPP = NewAEEventHandlerUPP(handle_quit_ae);
        if (quitUPP != NULL) {
            (void)AEInstallEventHandler(kCoreEventClass, kAEQuitApplication,
                                        quitUPP, 0, false);
        } else {
            now68k_log("main: quit-AE UPP allocation failed");
        }
    }

    now68k_log("main: entering event loop");
    while (!g_quit) {
        /* Route the idle sleep through wire_sleep_ticks rather than the
         * hardcoded constant: it collapses to 0 while a round trip is in
         * flight, so a MacTCP completion is not paced by up to kSleepTicks'
         * worth of idle sleep. A round trip crosses this path several times
         * (recv-done -> send -> send-done -> re-post recv), so the hardcoded
         * value cost up to 100 ms of added latency per crossing. Defect 15. */
        if (WaitNextEvent(everyEvent, &event, wire_sleep_ticks(kSleepTicks), NULL)) {
            switch (event.what) {
            case kHighLevelEvent:
                (void)AEProcessAppleEvent(&event);
                break;
            case mouseDown:
                dispatch_mouse_down(&event);
                break;
            case keyDown:
            case autoKey:
                if ((event.modifiers & cmdKey) != 0) {
                    do_menu(MenuKey((short)(event.message & charCodeMask)));
                } else {
                    /* A key belongs to whoever has the focus, which on this
                     * Toolbox is the front window - there is no other
                     * keyboard-focus notion to consult. */
                    route_event(&event, FrontWindow());
                }
                break;
            case updateEvt:
            case activateEvt:
                /* Both name their window in event.message, and BOTH must be
                 * routed by it rather than by the front window: an update
                 * for the window BEHIND is exactly the case that arrives
                 * when the front one moves, and an activate for the window
                 * losing focus names the loser, not the winner.
                 *
                 * main.c does NOT open an update cycle of its own: each
                 * window module owns exactly one balanced BeginUpdate/
                 * EndUpdate around its single painter (window.c's
                 * draw_page, conwin.c's draw_all). The UI skill's lexical
                 * redraw audit flags this line because it cannot follow
                 * the delegation; the delegation is the design. */
                route_event(&event, (WindowPtr)event.message);
                break;
            default:
                /* osEvt (suspend/resume) lands here and names no window -
                 * it is the whole application changing layer, so both
                 * windows need it. The SIZE resource claims activation
                 * handling, so this must actually reach them or a
                 * backgrounded window keeps a highlighted title bar. */
                window_handle_event(&event);
                conwin_handle_event(&event);
                break;
            }
        }
        wire_idle();
        window_idle();
        conwin_idle();   /* returns immediately while the console is closed
                             or behind - see conwin.c */
    }

    now68k_log("main: quit");
    /* Every exit path funnels here through g_quit - the quit Apple Event,
     * Cmd-Q, the close box, and the never-pressed-Connect case all just set
     * g_quit and fall out of the loop into this one cleanup. Must run before
     * window_dispose so the panel is still coherent while `bye` drains, and
     * it must run on every path: without it the stream's rcvBuff stays
     * pointed into our BSS after ExitToShell and the .IPP driver goes on
     * writing into memory the Process Manager has since handed to another
     * application. Defect 3. */
    wire_shutdown();
    conwin_dispose();   /* before window_dispose only for symmetry with the
                            order they were created in; neither depends on
                            the other */
    window_dispose();
    now68k_log_close();
    return 0;
}
