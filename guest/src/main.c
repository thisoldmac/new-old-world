#include <Carbon.h>

#include <string.h>

#include <stdio.h>

#include "confirm.h"
#include "host_browser.h"
#include "console_win.h"
#include "fileshare.h"
#include "product_identity.h"
#include "share_panel.h"
#include "pump.h"
#include "shots_panel.h"
#include "prefs.h"
#include "settings_dialog.h"
#include "wire.h"

enum {
    kWindowMinWidth = 360,
    kWindowMinHeight = 240,
    kFileMenuID = 129,
    kFileCloseItem = 1,
    kFileSharingItem = 3,
    kFileQuitItem = 5,
    kWindowsMenuID = 140,
    kWindowsScreenshotsItem = 1,
    kWindowsConsoleItem = 2,
    kWindowsConnectionItem = 3
};

static Boolean g_running = true;
static Rect g_screen_bounds;

static const unsigned char k_file_menu_title[] = {
    4, 'F', 'i', 'l', 'e'
};
static const unsigned char k_windows_menu_title[] = {
    7, 'W', 'i', 'n', 'd', 'o', 'w', 's'
};
static const unsigned char k_screenshots_menu_item[] = {
    13, 'S', 'c', 'r', 'e', 'e', 'n', 's', 'h', 'o', 't', 's', '/', 'S'
};
static const unsigned char k_console_menu_item[] = {
    9, 'C', 'o', 'n', 's', 'o', 'l', 'e', '/', 'L'
};
static const unsigned char k_connection_menu_item[] = {
    13, 'C', 'o', 'n', 'n', 'e', 'c', 't', 'i', 'o', 'n', 0xC9, '/', 'K'
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

static void create_menu_bar(void)
{
    MenuRef file_menu = NewMenu(kFileMenuID, k_file_menu_title);
    MenuRef windows_menu = NewMenu(kWindowsMenuID, k_windows_menu_title);

    AppendMenu(file_menu, k_close_menu_item);
    AppendMenu(file_menu, k_separator_menu_item);
    AppendMenu(file_menu, k_sharing_menu_item);
    AppendMenu(file_menu, k_separator_menu_item);
    AppendMenu(file_menu, k_quit_menu_item);
    InsertMenu(file_menu, 0);
    /* Modules live in the Windows menu; there is no main app window. */
    AppendMenu(windows_menu, k_screenshots_menu_item);
    AppendMenu(windows_menu, k_console_menu_item);
    AppendMenu(windows_menu, k_connection_menu_item);
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

static void close_front_window(void)
{
    WindowRef front = FrontWindow();

    if (share_panel_is(front)) {
        share_panel_close();
        return;
    }
    if (host_browser_is(front)) {
        host_browser_close();
        return;
    }
    if (shots_panel_is(front)) {
        shots_panel_close(true);
    } else if (console_win_is(front)) {
        console_win_close();
    }
}

/* The session (which windows are open, and where the panel sits) rides in
   the prefs file, so a relaunch restores what was on screen. */
static void save_session(void)
{
    NowPrefs prefs;
    Rect bounds;

    now_prefs_load(&prefs);
    prefs.panel_open = shots_panel_ref() != NULL;
    if (shots_panel_ref() != NULL) {
        GetWindowBounds(shots_panel_ref(), kWindowContentRgn, &bounds);
        prefs.panel_rect = bounds;
    }
    prefs.console_open = console_win_ref() != NULL;
    now_prefs_save(&prefs);
}

static void restore_session(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    if (prefs.panel_open) {
        shots_panel_open();
    }
    if (prefs.console_open) {
        console_win_open();
    }
}

static void handle_menu_choice(long choice)
{
    if (HiWord(choice) == kFileMenuID) {
        if (LoWord(choice) == kFileCloseItem) {
            close_front_window();
        } else if (LoWord(choice) == kFileSharingItem) {
            share_panel_open();
        } else if (LoWord(choice) == kFileQuitItem) {
            g_running = false;
        }
    } else if (HiWord(choice) == kWindowsMenuID) {
        if (LoWord(choice) == kWindowsScreenshotsItem) {
            shots_panel_open();
        } else if (LoWord(choice) == kWindowsConsoleItem) {
            console_win_open();
        } else if (LoWord(choice) == kWindowsConnectionItem) {
            now_settings_dialog_run();
        }
    }
}

static void handle_mouse_down(const EventRecord *event)
{
    WindowRef window;
    Point local;
    short part = FindWindow(event->where, &window);

    if (part == inMenuBar) {
        long choice = MenuSelect(event->where);
        handle_menu_choice(choice);
        HiliteMenu(0);
        return;
    }
    if (console_win_is(window)) {
        if (part == inDrag) {
            DragWindow(window, event->where, &g_screen_bounds);
        } else if (part == inGoAway) {
            if (TrackGoAway(window, event->where)) {
                console_win_close();
            }
        } else if (part == inGrow) {
            Rect limits;
            long size;

            SetRect(&limits, 280, 160, 2048, 2048);
            size = GrowWindow(window, event->where, &limits);
            if (size != 0) {
                SizeWindow(window, LoWord(size), HiWord(size), true);
                console_win_invalidate();
            }
        } else if (part == inZoomIn || part == inZoomOut) {
            if (TrackBox(window, event->where, part)) {
                SetPortWindowPort(window);
                ZoomWindow(window, part, false);
                console_win_invalidate();
            }
        } else if (part == inContent && window != FrontWindow()) {
            SelectWindow(window);
        }
        return;
    }
    if (share_panel_is(window)) {
        if (part == inDrag) {
            DragWindow(window, event->where, &g_screen_bounds);
        } else if (part == inGoAway) {
            if (TrackGoAway(window, event->where)) {
                share_panel_close();
            }
        } else if (part == inContent) {
            if (window != FrontWindow()) {
                SelectWindow(window);
                return;
            }
            local = event->where;
            SetPortWindowPort(window);
            GlobalToLocal(&local);
            share_panel_click(local);
        }
        return;
    }
    if (host_browser_is(window)) {
        if (part == inDrag) {
            DragWindow(window, event->where, &g_screen_bounds);
        } else if (part == inGoAway) {
            if (TrackGoAway(window, event->where)) {
                host_browser_close();
            }
        } else if (part == inContent) {
            if (window != FrontWindow()) {
                SelectWindow(window);
                return;
            }
            /* The list wants the click in GLOBAL coordinates: it does
               its own tracking, so it converts for itself. */
            host_browser_click(event);
        }
        return;
    }
    if (shots_panel_is(window)) {
        if (part == inDrag) {
            DragWindow(window, event->where, &g_screen_bounds);
        } else if (part == inGoAway) {
            if (TrackGoAway(window, event->where)) {
                shots_panel_close(true);
            }
        } else if (part == inContent) {
            if (window != FrontWindow()) {
                SelectWindow(window);
                return;
            }
            local = event->where;
            SetPortWindowPort(window);
            GlobalToLocal(&local);
            shots_panel_click(local);
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
    } else if (console_win_is(FrontWindow())) {
        console_win_key(key);
    } else if (host_browser_is(FrontWindow())) {
        host_browser_key(event);
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
    restore_session();
    conn_init();
    conn_set_shot_note(shots_panel_note);
    conn_set_file_note(share_panel_note);
    conn_set_listing(host_browser_listing);

    /* On CFM PowerPC a UPP is the tvector itself; the cast avoids
       NewAEEventHandlerUPP, a weakly-linked import that would resolve to
       NULL (and crash) on CarbonLib versions that lack it. */
    quit_handler = (AEEventHandlerUPP)handle_quit_apple_event;
    AEInstallEventHandler(kCoreEventClass, kAEQuitApplication,
                          quit_handler, 0, false);

    while (g_running) {
        conn_service();
        share_panel_idle();
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
            if (console_win_is((WindowRef)event.message)) {
                BeginUpdate(console_win_ref());
                console_win_draw();
                EndUpdate(console_win_ref());
            } else if (shots_panel_is((WindowRef)event.message)) {
                BeginUpdate(shots_panel_ref());
                shots_panel_draw();
                EndUpdate(shots_panel_ref());
            } else if (share_panel_is((WindowRef)event.message)) {
                BeginUpdate(share_panel_ref());
                share_panel_draw();
                EndUpdate(share_panel_ref());
            } else if (host_browser_is((WindowRef)event.message)) {
                BeginUpdate(host_browser_ref());
                host_browser_draw();
                EndUpdate(host_browser_ref());
            }
            break;
        case kHighLevelEvent:
            AEProcessAppleEvent(&event);
            break;
        default:
            break;
        }
    }

    save_session();
    conn_shutdown();
    now_pump_shutdown();
    AERemoveEventHandler(kCoreEventClass, kAEQuitApplication,
                         quit_handler, false);
    shots_panel_close(false);
    console_win_close();
    return 0;
}
