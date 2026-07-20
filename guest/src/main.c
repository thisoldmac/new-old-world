#include <Carbon.h>

#include <string.h>

#include "console_win.h"
#include "shots_panel.h"
#include "prefs.h"
#include "settings_dialog.h"
#include "wire.h"

enum {
    kWindowMinWidth = 360,
    kWindowMinHeight = 240,
    kFileMenuID = 129,
    kFileCloseItem = 1,
    kFileQuitItem = 3,
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

static void create_menu_bar(void)
{
    MenuRef file_menu = NewMenu(kFileMenuID, k_file_menu_title);
    MenuRef windows_menu = NewMenu(kWindowsMenuID, k_windows_menu_title);

    AppendMenu(file_menu, k_close_menu_item);
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
        } else if (part == inContent && window != FrontWindow()) {
            SelectWindow(window);
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

int main(void)
{
    EventRecord event;
    AEEventHandlerUPP quit_handler;

    InitCursor();
    FlushEvents(everyEvent, 0);
    compute_screen_bounds();
    create_menu_bar();
    restore_session();
    conn_init();
    conn_set_shot_note(shots_panel_note);

    /* On CFM PowerPC a UPP is the tvector itself; the cast avoids
       NewAEEventHandlerUPP, a weakly-linked import that would resolve to
       NULL (and crash) on CarbonLib versions that lack it. */
    quit_handler = (AEEventHandlerUPP)handle_quit_apple_event;
    AEInstallEventHandler(kCoreEventClass, kAEQuitApplication,
                          quit_handler, 0, false);

    while (g_running) {
        conn_service();
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
    AERemoveEventHandler(kCoreEventClass, kAEQuitApplication,
                         quit_handler, false);
    shots_panel_close(false);
    console_win_close();
    return 0;
}
