#include <Carbon.h>

#include <string.h>

#include <stdio.h>

#include "confirm.h"
#include "continuity_intake.h"
#include "carbon_warning.h"
#include "nowlog.h"
#include "fileshare.h"
#include "product_identity.h"
#include "proc_actions.h"
#include "proc_roster.h"
#include "files_module.h"
#include "files_browser_view.h"
#include "files_share_view.h"
#include "pump.h"
#include "screen_bounds.h"
#include "screenshots_module.h"
#include "prefs.h"
#include "wire.h"
#include "observe.h"
#include "mirror_log.h"
#include "peek.h"
#include "scene_collect.h"
#include "act_cmds.h"
#include "workshop_drop.h"
#include "workshop_layout.h"
#include "workshop_window.h"
#include "receive_progress.h"
#include "update_install.h"
#include "about_box.h"

enum {
    kAppleMenuID = 128,
    kAppleAboutItem = 1,
    kFileMenuID = 129,
    kFileCloseItem = 1,
    kFileSharingItem = 3,
    kFileQuitItem = 5,
    kEditMenuID = 142,
    kEditCopyItem = 1,
    kEditPreferencesItem = 3,
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
/* The Edit menu carries Copy and Preferences, and that pairing is the
   whole editing model this application has.

   It used to carry Preferences alone, and the reason written here was
   sound: this window has no keyboard-focus machinery (workshop_window.c
   says why), the Chat and Console text fields are classic TextEdit each
   owning its own TEHandle, so there was no "the focused field" for an
   Edit command to act on, and four greyed items would have advertised an
   editing model that did not exist.

   Copy arrives by going around that problem rather than solving it. The
   MODULE answers - `WorkshopModuleOps.copy_text`, "what is selected on
   me, as plain text" - so there is no focused field to find and no
   TEHandle to hand over. For most pages the honest answer is the whole
   page as text, which is what a person reaching for Copy on a page of
   facts actually wants. A page that has nothing worth handing someone
   leaves the op NULL and the item greys, which is a true report rather
   than a command that quietly does nothing.

   Cut and Paste stay absent: they need a writable selection, which is
   the focus problem again and not one Copy had to solve. Preferences is
   where the era's HIG puts it, so it stays. */
static const unsigned char k_edit_menu_title[] = {
    4, 'E', 'd', 'i', 't'
};
static const unsigned char k_edit_copy_item[] = {
    6, 'C', 'o', 'p', 'y', '/', 'C'
};
static const unsigned char k_edit_preferences_item[] = {
    14, 'P', 'r', 'e', 'f', 'e', 'r', 'e', 'n', 'c', 'e', 's',
    '.', '.', '.'
};
static const unsigned char k_view_menu_title[] = {
    4, 'V', 'i', 'e', 'w'
};
static const unsigned char k_view_screenshots_item[] = {
    11, 'S', 'c', 'r', 'e', 'e', 'n', 's', 'h', 'o', 't', 's'
};
static const unsigned char k_view_files_item[] = {
    5, 'F', 'i', 'l', 'e', 's'
};
static const unsigned char k_view_console_item[] = {
    7, 'C', 'o', 'n', 's', 'o', 'l', 'e'
};
static const unsigned char k_view_processes_item[] = {
    9, 'P', 'r', 'o', 'c', 'e', 's', 's', 'e', 's'
};
static const unsigned char k_view_hardware_item[] = {
    8, 'H', 'a', 'r', 'd', 'w', 'a', 'r', 'e'
};
static const unsigned char k_view_software_item[] = {
    8, 'S', 'o', 'f', 't', 'w', 'a', 'r', 'e'
};
static const unsigned char k_view_mcp_item[] = {
    3, 'M', 'C', 'P'
};
static const unsigned char k_view_diagnostics_item[] = {
    11, 'D', 'i', 'a', 'g', 'n', 'o', 's', 't', 'i', 'c', 's'
};
/* The item NUMBER is the module id (see the handler below), so every
   module needs an item and they must appear in enum order. Networking
   landed without one, which silently made Cmd-9 "Logs" select Networking
   and Cmd-0 "Connection" select Logs, and left Connection unreachable
   from this menu.

   No item carries a Cmd-key any more (I4a): the numbers ran out at ten
   pages and the rail is the navigation - a shortcut that stops working
   past the tenth module is worse than no shortcut. */
static const unsigned char k_view_networking_item[] = {
    10, 'N', 'e', 't', 'w', 'o', 'r', 'k', 'i', 'n', 'g'
};
static const unsigned char k_view_icloud_item[] = {
    6, 'i', 'C', 'l', 'o', 'u', 'd'
};
static const unsigned char k_view_chat_item[] = {
    4, 'C', 'h', 'a', 't'
};
static const unsigned char k_view_mirror_item[] = {
    6, 'M', 'i', 'r', 'r', 'o', 'r'
};
static const unsigned char k_view_development_item[] = {
    11, 'D', 'e', 'v', 'e', 'l', 'o', 'p', 'm', 'e', 'n', 't'
};
static const unsigned char k_view_web_item[] = {
    3, 'W', 'e', 'b'
};
static const unsigned char k_view_preferences_item[] = {
    11, 'P', 'r', 'e', 'f', 'e', 'r', 'e', 'n', 'c', 'e', 's'
};
static const unsigned char k_view_logs_item[] = {
    4, 'L', 'o', 'g', 's'
};
static const unsigned char k_view_connection_item[] = {
    10, 'C', 'o', 'n', 'n', 'e', 'c', 't', 'i', 'o', 'n'
};
static const unsigned char k_workshop_menu_item[] = {
    10, 'W', 'o', 'r', 'k', 's', 'h', 'o', 'p', '/', 'O'
};

static void create_menu_bar(void)
{
    /* GetMenu, not NewMenu: the Apple-glyph title character Rez encoded
       from the `apple` keyword in app.r's MENU 128 has to come from the
       resource - NewMenu takes an ordinary Pascal string and cannot
       produce it. */
    MenuRef apple_menu = GetMenu(kAppleMenuID);
    MenuRef file_menu = NewMenu(kFileMenuID, k_file_menu_title);
    MenuRef edit_menu = NewMenu(kEditMenuID, k_edit_menu_title);
    MenuRef view_menu = NewMenu(kViewMenuID, k_view_menu_title);
    MenuRef windows_menu = NewMenu(kWindowsMenuID, k_windows_menu_title);

    if (apple_menu != NULL) {
        /* The standard OS 9 idiom: whatever aliases live in the Apple
           Menu Items folder appear below the separator app.r already
           placed at item 2. Selecting one is handled in
           handle_menu_choice via OpenDeskAcc. */
        AppendResMenu(apple_menu, 'DRVR');
        InsertMenu(apple_menu, 0);
    }
    AppendMenu(file_menu, k_close_menu_item);
    AppendMenu(file_menu, k_separator_menu_item);
    AppendMenu(file_menu, k_sharing_menu_item);
    AppendMenu(file_menu, k_separator_menu_item);
    AppendMenu(file_menu, k_quit_menu_item);
    InsertMenu(file_menu, 0);
    AppendMenu(edit_menu, k_edit_copy_item);
    AppendMenu(edit_menu, k_separator_menu_item);
    AppendMenu(edit_menu, k_edit_preferences_item);
    InsertMenu(edit_menu, 0);
    /* View selects a Workshop module (the item number IS the module ID);
       no item carries a Cmd-key (I4a - the rail is the navigation).
       Windows reopens the one window. Every module lives in the
       Workshop now. */
    AppendMenu(view_menu, k_view_screenshots_item);
    AppendMenu(view_menu, k_view_files_item);
    AppendMenu(view_menu, k_view_console_item);
    AppendMenu(view_menu, k_view_processes_item);
    AppendMenu(view_menu, k_view_hardware_item);
    AppendMenu(view_menu, k_view_software_item);
    AppendMenu(view_menu, k_view_mcp_item);
    AppendMenu(view_menu, k_view_diagnostics_item);
    AppendMenu(view_menu, k_view_networking_item);
    AppendMenu(view_menu, k_view_icloud_item);
    AppendMenu(view_menu, k_view_chat_item);
    AppendMenu(view_menu, k_view_mirror_item);
    AppendMenu(view_menu, k_view_development_item);
    AppendMenu(view_menu, k_view_web_item);
    AppendMenu(view_menu, k_view_preferences_item);
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
    NowProcRosterIter it;
    NowProcRosterRow row;
    NowProcRosterRow me;
    Boolean same = false;

    if (GetCurrentProcess(&self) != noErr || !now_proc_roster_read(&self, &me)) {
        return false;
    }
    now_proc_roster_begin(&it);
    while (now_proc_roster_next(&it, &row)) {
        if (row.creator != (unsigned long)PRODUCT_CREATOR_CODE) {
            continue;
        }
        /* Match by NAME, not merely by creator. The stale instance a
           redeploy leaves behind runs from a trashed file that still
           carries the same name, so this still catches it — while a
           deliberately duplicated copy (a second guest, on another
           port, for another host) is a different name and is allowed
           to run alongside. */
        if (!EqualString(row.pname, me.pname, false, false)) {
            continue;
        }
        if (row.is_self) {
            continue;
        }
        (void)same;
        /* Ask and re-read, through the one fronting answer: this launch
           is about to end quietly, so the last thing it does had better
           be something that happened rather than something dispatched. */
        (void)now_proc_front_confirm(&row.psn, 0);
        return true;
    }
    return false;
}

static void compute_screen_bounds(void)
{
    now_screen_desktop(&g_screen_bounds);
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

/* The window a person means when they press a key or Cmd-W.
 *
 * FrontWindow() includes the receive windoid, which floats: while a file
 * is landing it IS the front window, and every `workshop_is(FrontWindow())`
 * test would answer false - Cmd-W would stop closing the Workshop and
 * keystrokes would stop reaching it, for the length of a transfer.
 *
 * Carbon has FrontNonFloatingWindow for exactly this, and it is declared
 * for CarbonLib 1.0. It is not used here because this application has
 * only ever two windows and knows which is which, and a symbol declared
 * in these headers is not proof CarbonLib 1.6 exports it - GetControlKind
 * is the one that cost this project a link failure (control_kind.h). */
static WindowRef front_document_window(void)
{
    WindowRef front = FrontWindow();

    return now_receive_progress_is(front) ? workshop_ref() : front;
}

static void close_front_window(void)
{
    if (workshop_is(front_document_window())) {
        workshop_close(false);        /* user-initiated: records closed */
    }
}

/* Run before the Menu Manager tracks anything - both a click in the bar
   and a Command-key, because MenuKey resolves an item without ever
   drawing the menu and a stale enable state would let Copy fire on a
   page that cannot answer. Only the items whose availability actually
   changes are touched; everything else is unconditionally live. */
static void adjust_menus(void)
{
    MenuRef edit_menu = GetMenuHandle(kEditMenuID);

    if (edit_menu == NULL) {
        return;
    }
    if (workshop_can_copy()) {
        EnableMenuItem(edit_menu, kEditCopyItem);
    } else {
        DisableMenuItem(edit_menu, kEditCopyItem);
    }
}

static void handle_menu_choice(long choice)
{
    if (HiWord(choice) == kAppleMenuID) {
        if (LoWord(choice) == kAppleAboutItem) {
            now_about_box_show();
        }
        /* Everything past the separator is an Apple Menu Items folder
           alias, enumerated by AppendResMenu('DRVR') so the menu looks
           and populates like every other OS 9 application's. Opening one
           is deliberately NOT wired: OpenDeskAcc is the classic call for
           it and TARGET_API_MAC_CARBON does not declare it - CarbonLib
           does not run 68K CODE-resource desk accessories. Selecting an
           item here highlights and does nothing, which is honest: this
           app cannot open it, so it does not pretend to. */
    } else if (HiWord(choice) == kFileMenuID) {
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
    } else if (HiWord(choice) == kEditMenuID) {
        if (LoWord(choice) == kEditCopyItem) {
            (void)workshop_copy();   /* greyed unless the page can answer */
        } else if (LoWord(choice) == kEditPreferencesItem) {
            if (workshop_open()) {
                workshop_select_module(kWorkshopPreferences);
            }
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

/* A wire callback may run inside one of the nested pumps documented in
   pump.h. Creating or disposing Toolbox UI there made Windows > Workshop
   report success without showing a window. Keep one serialized choice and
   execute it as soon as conn_service returns to the application's main loop,
   which is the same ownership context as a real MenuSelect. */
static long g_pending_menu_choice;

static int queue_menu_choice(long choice)
{
    if (choice == 0 || g_pending_menu_choice != 0) {
        return 0;
    }
    g_pending_menu_choice = choice;
    return 1;
}

static int queue_window_close(WindowRef window)
{
    if (!workshop_is(window)) {
        return 0;
    }
    return queue_menu_choice(((long)kFileMenuID << 16) | kFileCloseItem);
}

static void dispatch_pending_menu_choice(void)
{
    long choice = g_pending_menu_choice;

    if (choice == 0) {
        return;
    }
    g_pending_menu_choice = 0;
    handle_menu_choice(choice);
}

static void handle_mouse_down(const EventRecord *event)
{
    WindowRef window;
    short part = FindWindow(event->where, &window);

    if (part == inMenuBar) {
        long choice;

        adjust_menus();
        choice = MenuSelect(event->where);
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
    /* The receive windoid floats above the Workshop, so it is hit first
       and answers for itself (receive_progress.h). It is the only other
       window this loop routes to; confirm.c's modal runs its own. */
    if (now_receive_progress_is(window)) {
        now_receive_progress_click(event, part);
        return;
    }
    if (workshop_is(window)) {
        if (part == inDrag) {
            DragWindow(window, event->where, &g_screen_bounds);
        } else if (part == inGoAway) {
            if (TrackGoAway(window, event->where)) {
                workshop_close(false);    /* user-initiated: records closed */
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
            /* front_document_window, not FrontWindow: with the receive
               windoid floating above, every click here would otherwise
               be spent selecting a window that is already the active
               one and can never be "front". */
            if (window != front_document_window()) {
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
        long choice;

        adjust_menus();
        choice = MenuKey(key);
        handle_menu_choice(choice);
        HiliteMenu(0);
    } else if (workshop_is(front_document_window())) {
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

/* The Finder dropping files on NOW's icon, and the launch that carries
   the same event when someone opens a document with this application.
 *
   This application SENT kAEOpenDocuments in four places and had never
   answered one, which is why app.r's FREF said 'APPL' and nothing else:
   an application that advertises documents it cannot open is worse than
   one that advertises none. Both halves change together — the document
   FREF and this handler — or the Finder offers a drop that goes nowhere.
 *
   It queues and returns. Sending from inside AEProcessAppleEvent would
   start a transfer underneath the event loop that has to pump it. */
static pascal OSErr handle_open_documents_apple_event(const AppleEvent *event,
                                                       AppleEvent *reply,
                                                       long refcon)
{
    (void)refcon;
    return now_drop_open_documents(event, reply);
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
    AEEventHandlerUPP open_documents_handler;

    InitCursor();
    FlushEvents(everyEvent, 0);
    if (another_instance_is_running()) {
        return 0;
    }
    compute_screen_bounds();
    create_menu_bar();
    now_act_set_self_menu_handler(queue_menu_choice);
    now_act_set_self_window_close_handler(queue_window_close);
    /* The Workshop is the primary window; the remaining old module
       windows stay reachable from the menus until each one moves in. If
       the shell cannot build its navigation, say so once - the rest of
       the app still works the old way.

       Opening it is gated on whether the last session left it open:
       workshop_close records a deliberate user-close, and a file that
       predates the field defaults to open, the behavior every existing
       machine already has. */
    {
        NowPrefs launch_prefs;

        now_prefs_load(&launch_prefs);
        if (launch_prefs.workshop_open_at_quit && !workshop_open()) {
            static const unsigned char k_empty[] = { 0 };
            Str255 message;

            CopyCStringToPascal("The Workshop window could not be created. "
                                "The Windows menu still works.", message);
            ParamText(message, k_empty, k_empty, k_empty);
            StopAlert(200, now_pump_modal_filter());
        }
    }
    /* Log first: a hang during connection setup is precisely the case
       the log exists for, and the old order left none. The in-memory ring
       is always live; the saved switch only governs the disk file, which
       is on unless the Logs page turned it off. */
    {
        NowPrefs log_prefs;
        now_prefs_load(&log_prefs);
        now_log_set_retention(log_prefs.log_retention);
        now_log_set_disk(log_prefs.log_to_disk);
    }
    /* Arm the reference registry before anything can ask for a
       reference. Every entry point arms it lazily too, so this is not
       required for correctness - it is for the SEED: at startup the
       clock, the stack address and Random() are further apart than they
       will be at the first request, and the seed is the whole reason a
       reference cannot be computed from what a caller can see. */
    now_observe_init();
    conn_init();
    conn_set_shot_note(screenshots_module_note);
    conn_set_file_note(files_share_note);
    conn_set_listing(files_browser_listing);
    conn_set_get_note(files_browser_note);
    now_carbon_warning_show_if_needed();

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
    /* Same construction rule, same failure posture: without the handler
       the Finder's drop simply is not answered, which is the state this
       application was in before it had one. */
    open_documents_handler =
        NewAEEventHandlerUPP(handle_open_documents_apple_event);
    if (open_documents_handler != NULL) {
        AEInstallEventHandler(kCoreEventClass, kAEOpenDocuments,
                              open_documents_handler, 0, false);
    } else {
        now_log(kLogWarn, "app",
                "odoc: no handler UPP; Finder icon drops will not answer");
    }

    while (g_running) {
        /* WATCHED, NOT READ. Cross-application stacking order exists
           nowhere to be asked for on this machine - each application has
           its own WindowList - so it is reconstructed from the order
           applications came to the front, and that is only observable by
           an application that was running at the time. One trap per
           pass, here rather than at scene time, because a scene collected
           after the fact sees only where the machine ended up.
           front_order.h carries the argument; scene_collect.c does the
           ordering. */
        now_scene_note_front_process();
        conn_service();
        dispatch_pending_menu_choice();
        workshop_idle();
        /* Whether or not the Workshop is open: a file the host pushes
           arrives without anyone here having asked for it, so its
           progress cannot live on a page. */
        now_receive_progress_idle();
        /* Also whether or not the Workshop is open: a file dropped on
           NOW's icon in the Finder arrives with no window involved. This
           is the ONLY place a dropped file is sent - both handlers only
           ever queued (workshop_drop.h). */
        now_drop_idle();
        /* The writer heartbeat, renewed because this loop is running -
           which is the fact it exists to prove. Renewed anywhere else it
           measures something else; see now_peek_idle's header comment
           for the flap that taught this. */
        now_peek_idle();
        /* The Mirror's slow observer: it reads the counters the resident
           bumps INSIDE foreign processes and writes only what changed.
           It is here, at task time, rather than in a hook, because a
           hook is bounded and allocation-free by construction and a disk
           write there would change the timing of the thing it measures.
           mirror_log.h carries the boundary in full. */
        now_mirror_log_idle();
        ask_about_replacing();
        /* NEVER SLEEP ZERO. A zero sleep tells WaitNextEvent to return
           at once, so this application spins and, on a cooperatively
           scheduled Macintosh, nothing else runs. That is survivable for
           a wire that only answers questions about ITSELF. It is fatal
           for a mirror: the anchor plane captures a process's A5 when
           that process PUMPS, so starving every other application of
           time starves the mirror of everything except the front window.
         *
           Watched 2026-08-03: the mirror could open Macintosh HD and
           then could not see the window it had just opened, and the
           scene carried exactly one window - ours - for as long as
           anyone looked. One tick still yields; it does not cost the
           wire anything a person can measure.
         *
           The number itself now lives in wire.c (conn_sleep_ticks), for
           the reason this loop's whole cost turned out to be it: a
           request arriving into an idle connection waits out the sleep
           before conn_service ever looks at the socket, and a constant
           spelled here could not be measured, reported or changed
           without a rebuild. */
        if (!WaitNextEvent(everyEvent, &event,
                           (UInt32)conn_sleep_ticks(), NULL)) {
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
            if (now_receive_progress_is((WindowRef)event.message)) {
                BeginUpdate((WindowRef)event.message);
                now_receive_progress_draw();
                EndUpdate((WindowRef)event.message);
            } else if (workshop_is((WindowRef)event.message)) {
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
                set_window_active(front_document_window(),
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
    /* Before the connection goes, because closing it releases every
       wire-owned plane: this is the last moment the Mirror's own state is
       still the state a crash would have been in. A launch whose log has
       no `mirror teardown` line is one where teardown did not run — the
       same reading docs/logging.md gives a file with no `stopped`. */
    now_mirror_log_teardown();

    now_log(kLogInfo, "app", "quit: closing connection");
    now_log_flush();
    conn_shutdown();
    now_continuity_shutdown();

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
    if (open_documents_handler != NULL) {
        AERemoveEventHandler(kCoreEventClass, kAEOpenDocuments,
                             open_documents_handler, false);
        DisposeAEEventHandlerUPP(open_documents_handler);
        open_documents_handler = NULL;
    }
    /* Deliberately before workshop_close, which is the next step but
       one: RemoveTrackingHandler takes the WindowRef the handler was
       installed on, so the window must still exist when it runs.
       workshop_close calls the same remove and finds nothing left. */
    now_drop_shutdown();

    now_log(kLogInfo, "app", "quit: disposing window");
    now_log_flush();
    now_receive_progress_shutdown();
    workshop_close(true);   /* quit teardown: records open iff it existed */

    now_log(kLogInfo, "app", "quit: clean");
    now_log_close();
    return 0;
}
