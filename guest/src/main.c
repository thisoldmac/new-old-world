#include <Carbon.h>

#include <string.h>

#include <stdio.h>

#include "confirm.h"
#include "nowlog.h"
#include "fileshare.h"
#include "product_identity.h"
#include "files_module.h"
#include "files_browser_view.h"
#include "files_share_view.h"
#include "pump.h"
#include "screenshots_module.h"
#include "prefs.h"
#include "wire.h"
#include "workshop_layout.h"
#include "workshop_window.h"

enum {
    kFileMenuID = 129,
    kFileCloseItem = 1,
    kFileSharingItem = 3,
    kFileQuitItem = 5,
    kWindowsMenuID = 140,
    kWindowsWorkshopItem = 1,
    kViewMenuID = 141
};

static Boolean g_running = true;
static Rect g_screen_bounds;

static const unsigned char k_file_menu_title[] = {
    4, 'F', 'i', 'l', 'e'
};
static const unsigned char k_windows_menu_title[] = {
    7, 'W', 'i', 'n', 'd', 'o', 'w', 's'
};
static const unsigned char k_separator_menu_item[] = {
    2, '-', ' '
};
static const unsigned char k_close_menu_item[] = {
    7, 'C', 'l', 'o', 's', 'e', '/', 'W'
};
static const unsigned char k_quit_menu_item[] = {
    6, 'Q', 'u', 'i', 't', '/', 'Q'
};
static const unsigned char k_sharing_menu_item[] = {
    16, 'F', 'i', 'l', 'e', ' ', 'S', 'h', 'a', 'r', 'i', 'n', 'g',
    '.', '.', '.', ' '
};
static const unsigned char k_view_menu_title[] = {
    4, 'V', 'i', 'e', 'w'
};
static const unsigned char k_view_screenshots_item[] = {
    13, 'S', 'c', 'r', 'e', 'e', 'n', 's', 'h', 'o', 't', 's', '/', '1'
};
static const unsigned char k_view_files_item[] = {
    7, 'F', 'i', 'l', 'e', 's', '/', '2'
};
static const unsigned char k_view_console_item[] = {
    9, 'C', 'o', 'n', 's', 'o', 'l', 'e', '/', '3'
};
static const unsigned char k_view_processes_item[] = {
    11, 'P', 'r', 'o', 'c', 'e', 's', 's', 'e', 's', '/', '4'
};
static const unsigned char k_view_hardware_item[] = {
    10, 'H', 'a', 'r', 'd', 'w', 'a', 'r', 'e', '/', '5'
};
static const unsigned char k_view_software_item[] = {
    10, 'S', 'o', 'f', 't', 'w', 'a', 'r', 'e', '/', '6'
};
static const unsigned char k_view_logs_item[] = {
    6, 'L', 'o', 'g', 's', '/', '7'
};
static const unsigned char k_view_connection_item[] = {
    12, 'C', 'o', 'n', 'n', 'e', 'c', 't', 'i', 'o', 'n', '/', '8'
};
static const unsigned char k_workshop_menu_item[] = {
    8, 'W', 'o', 'r', 'k', 's', 'h', 'o', 'p'
};

static void create_menu_bar(void)
{
    MenuRef file_menu = NewMenu(kFileMenuID, k_file_menu_title);
    MenuRef view_menu = NewMenu(kViewMenuID, k_view_menu_title);
    MenuRef windows_menu = NewMenu(kWindowsMenuID, k_windows_menu_title);

    AppendMenu(file_menu, k_close_menu_item);
    AppendMenu(file_menu, k_separator_menu_item);
    AppendMenu(file_menu, k_sharing_menu_item);
    AppendMenu(file_menu, k_separator_menu_item);
    AppendMenu(file_menu, k_quit_menu_item);
    InsertMenu(file_menu, 0);
    /* View selects a Workshop module (Cmd-1..8, the item number IS the
       module ID); Windows reopens the one window. Every module lives in
       the Workshop now. */
    AppendMenu(view_menu, k_view_screenshots_item);
    AppendMenu(view_menu, k_view_files_item);
    AppendMenu(view_menu, k_view_console_item);
    AppendMenu(view_menu, k_view_processes_item);
    AppendMenu(view_menu, k_view_hardware_item);
    AppendMenu(view_menu, k_view_software_item);
    AppendMenu(view_menu, k_view_logs_item);
    AppendMenu(view_menu, k_view_connection_item);
    InsertMenu(view_menu, 0);
    AppendMenu(windows_menu, k_workshop_menu_item);
    InsertMenu(windows_menu, 0);
    DrawMenuBar();
}

/* Mac OS normally refuses to launch an app twice — but it matches by
   FILE, and deploying over the wire replaces the file (Rumpus moves the
   old one to the Trash and writes a new one). The running instance then
   keeps executing from the trashed file while the fresh file launches
   as a SECOND process, and the two fight over the one connection the
   host allows: the stale one holds the wire and the new one is refused
   busy, with nothing on screen explaining why.

   So match by creator instead of by file. If another NOW is already
   running, bring it to the front and let this launch end quietly — the
   human sees the app they already had, which is the honest outcome. */
static Boolean another_instance_is_running(void)
{
    ProcessSerialNumber self;
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str31 name;
    Str31 self_name;
    Boolean same = false;

    if (GetCurrentProcess(&self) != noErr) {
        return false;
    }
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = self_name;
    self_name[0] = 0;
    if (GetProcessInformation(&self, &info) != noErr) {
        return false;
    }
    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (GetNextProcess(&psn) == noErr) {
        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        name[0] = 0;
        if (GetProcessInformation(&psn, &info) != noErr) {
            continue;
        }
        if (info.processSignature != PRODUCT_CREATOR_CODE) {
            continue;
        }
        /* Match by NAME, not merely by creator. The stale instance a
           redeploy leaves behind runs from a trashed file that still
           carries the same name, so this still catches it — while a
           deliberately duplicated copy (a second guest, on another
           port, for another host) is a different name and is allowed
           to run alongside. */
        if (!EqualString(name, self_name, false, false)) {
            continue;
        }
        if (SameProcess(&psn, &self, &same) == noErr && same) {
            continue;
        }
        SetFrontProcess(&psn);
        return true;
    }
    return false;
}

static void compute_screen_bounds(void)
{
    RgnHandle desktop = GetGrayRgn();

    if (desktop != NULL) {
        GetRegionBounds(desktop, &g_screen_bounds);
    } else {
        SetRect(&g_screen_bounds, 0, 20, 800, 600);
    }
}

/* Activation routing (activateEvt and the osEvt foreground switch —
   SIZE says doesActivateOnFGSwitch, a promise that the APPLICATION
   activates its own windows). One window remains. */
static Boolean is_our_window(WindowRef window)
{
    return window != NULL && workshop_is(window);
}

static void set_window_active(WindowRef window, Boolean active)
{
    if (workshop_is(window)) {
        workshop_activate(active);
    }
}

static void close_front_window(void)
{
    if (workshop_is(FrontWindow())) {
        workshop_close();
    }
}

static void handle_menu_choice(long choice)
{
    if (HiWord(choice) == kFileMenuID) {
        if (LoWord(choice) == kFileCloseItem) {
            close_front_window();
        } else if (LoWord(choice) == kFileSharingItem) {
            /* File Sharing lives on the Workshop's Files page now. */
            if (workshop_open()) {
                workshop_select_module(kWorkshopFiles);
            }
        } else if (LoWord(choice) == kFileQuitItem) {
            g_running = false;
        }
    } else if (HiWord(choice) == kViewMenuID) {
        /* The item numbers are the module IDs. */
        if (LoWord(choice) >= 1 && LoWord(choice) <= kWorkshopModuleCount) {
            if (workshop_open()) {
                workshop_select_module((WorkshopModuleID)LoWord(choice));
            }
        }
    } else if (HiWord(choice) == kWindowsMenuID) {
        if (LoWord(choice) == kWindowsWorkshopItem) {
            workshop_open();
        }
    }
}

static void handle_mouse_down(const EventRecord *event)
{
    WindowRef window;
    short part = FindWindow(event->where, &window);

    if (part == inMenuBar) {
        long choice = MenuSelect(event->where);
        handle_menu_choice(choice);
        HiliteMenu(0);
        return;
    }
    /* WindowShade. The Workshop asks for
       kWindowStandardDocumentAttributes, so it draws a collapse box; a
       control that is drawn and does nothing is worse than one that is
       absent. */
    if (part == inCollapseBox && is_our_window(window)) {
        if (TrackBox(window, event->where, part)) {
            CollapseWindow(window, !IsWindowCollapsed(window));
        }
        return;
    }
    if (workshop_is(window)) {
        if (part == inDrag) {
            DragWindow(window, event->where, &g_screen_bounds);
        } else if (part == inGoAway) {
            if (TrackGoAway(window, event->where)) {
                workshop_close();
            }
        } else if (part == inGrow) {
            Rect limits;
            long size;

            SetRect(&limits, kWorkshopMinContentW, kWorkshopMinContentH,
                    2048, 2048);
            size = GrowWindow(window, event->where, &limits);
            if (size != 0) {
                SizeWindow(window, LoWord(size), HiWord(size), true);
                workshop_resized();
            }
        } else if (part == inZoomIn || part == inZoomOut) {
            if (TrackBox(window, event->where, part)) {
                SetPortWindowPort(window);
                ZoomWindow(window, part, false);
                workshop_resized();
            }
        } else if (part == inContent) {
            if (window != FrontWindow()) {
                SelectWindow(window);
                return;
            }
            workshop_click(event);
        }
        return;
    }
}

static void handle_key_down(const EventRecord *event)
{
    char key = (char)(event->message & charCodeMask);

    if ((event->modifiers & cmdKey) != 0) {
        long choice = MenuKey(key);
        handle_menu_choice(choice);
        HiliteMenu(0);
    } else if (workshop_is(FrontWindow())) {
        workshop_key(event);
    }
}

static pascal OSErr handle_quit_apple_event(const AppleEvent *event,
                                             AppleEvent *reply,
                                             long refcon)
{
    (void)event;
    (void)reply;
    (void)refcon;
    g_running = false;
    return noErr;
}

/* The wire holds a send that the other machine says would replace
   something, and raises a flag rather than asking — a modal opened from
   a network callback nests inside whatever loop is running (pump.h).
   Here, at the top of the event loop, asking is safe. */
static void ask_about_replacing(void)
{
    char name[64];
    char heading[96];
    char detail[128];
    char peer[40];

    if (!now_wire_send_pending_replace(name, sizeof name)) {
        return;
    }
    conn_peer_label(peer, sizeof peer);
    snprintf(heading, sizeof heading, "Replace \"%.31s\"?", name);
    snprintf(detail, sizeof detail,
             "%.20s already has a file with this name. The old one goes "
             "to its Trash.", peer);
    now_wire_send_resolve_replace(now_confirm(heading, detail, "Replace"));
}

int main(void)
{
    EventRecord event;
    AEEventHandlerUPP quit_handler;

    InitCursor();
    FlushEvents(everyEvent, 0);
    if (another_instance_is_running()) {
        return 0;
    }
    compute_screen_bounds();
    create_menu_bar();
    /* The Workshop is the primary window; the remaining old module
       windows stay reachable from the menus until each one moves in. If
       the shell cannot build its navigation, say so once - the rest of
       the app still works the old way. */
    if (!workshop_open()) {
        static const unsigned char k_empty[] = { 0 };
        Str255 message;

        CopyCStringToPascal("The Workshop window could not be created. "
                            "The Windows menu still works.", message);
        ParamText(message, k_empty, k_empty, k_empty);
        StopAlert(200, now_pump_modal_filter());
    }
    /* Log first: a hang during connection setup is precisely the case
       the log exists for, and the old order left none. The in-memory ring
       is always live; the saved switch only governs the disk file, which
       is on unless the Logs page turned it off. */
    {
        NowPrefs log_prefs;
        now_prefs_load(&log_prefs);
        now_log_set_disk(log_prefs.log_to_disk);
    }
    conn_init();
    conn_set_shot_note(screenshots_module_note);
    conn_set_file_note(files_share_note);
    conn_set_listing(files_browser_listing);
    conn_set_get_note(files_browser_note);

    /* A real UPP, not a cast. The old comment here claimed "on CFM
       PowerPC a UPP is the tvector itself" - that is true on Mach-O and
       false on this runtime, where MixedMode.h makes a UPP a routine
       descriptor. The same belief cost a Type 3 in the Data Browser
       spike; this one survived only because the Apple Event Manager
       happens to tolerate a bare pointer.

       If the constructor is unavailable the handler is simply not
       installed: an installer that wants us to quit will hang waiting,
       which is a known and survivable outcome, where a bad pointer is
       a crash in someone else's transfer. */
    quit_handler = NewAEEventHandlerUPP(handle_quit_apple_event);
    if (quit_handler != NULL) {
        AEInstallEventHandler(kCoreEventClass, kAEQuitApplication,
                              quit_handler, 0, false);
    }

    while (g_running) {
        conn_service();
        workshop_idle();
        ask_about_replacing();
        if (!WaitNextEvent(everyEvent, &event,
                           conn_wants_fast_pump() ? 0 : 6, NULL)) {
            continue;
        }
        switch (event.what) {
        case mouseDown:
            handle_mouse_down(&event);
            break;
        case keyDown:
            /* autoKey is deliberately ignored: a held Return must not
               machine-gun the capture history. */
            handle_key_down(&event);
            break;
        case updateEvt:
            if (workshop_is((WindowRef)event.message)) {
                BeginUpdate(workshop_ref());
                workshop_draw();
                EndUpdate(workshop_ref());
            }
            break;
        case activateEvt:
            set_window_active((WindowRef)event.message,
                              (event.modifiers & activeFlag) != 0);
            break;
        case osEvt:
            /* Suspend and resume. The high byte of the message names the
               kind of osEvt; only this one concerns us. */
            if (((event.message >> 24) & 0x0FF) == suspendResumeMessage) {
                set_window_active(FrontWindow(),
                                  (event.message & resumeFlag) != 0);
            }
            break;
        case kHighLevelEvent:
            AEProcessAppleEvent(&event);
            break;
        default:
            break;
        }
    }

    /* Teardown leaves a flushed breadcrumb before each step and closes
       the log LAST, so a crash here (a reboot-class one lived in Data
       Browser disposal) ends the log ON the stage it did not survive
       instead of at a "stopped" written too early to catch it. Each
       breadcrumb is forced to the platter; the disk cache would lose an
       ordinary line in the crash. A clean quit runs to "quit: clean"
       and then "stopped". */
    now_log(kLogInfo, "app", "quit: closing connection");
    now_log_flush();
    conn_shutdown();

    now_log(kLogInfo, "app", "quit: stopping pump");
    now_log_flush();
    now_pump_shutdown();

    /* Only remove what was installed, and dispose the descriptor. The
       handler was installed conditionally (the constructor can fail)
       but removed unconditionally, and its UPP was never released. */
    now_log(kLogInfo, "app", "quit: removing handlers");
    now_log_flush();
    if (quit_handler != NULL) {
        AERemoveEventHandler(kCoreEventClass, kAEQuitApplication,
                             quit_handler, false);
        DisposeAEEventHandlerUPP(quit_handler);
        quit_handler = NULL;
    }

    now_log(kLogInfo, "app", "quit: disposing window");
    now_log_flush();
    workshop_close();

    now_log(kLogInfo, "app", "quit: clean");
    now_log_close();
    return 0;
}
