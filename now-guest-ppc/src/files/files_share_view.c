#include "files_share_view.h"

#include <stdio.h>
#include <string.h>

#include "fileshare.h"
#include "files_run.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"

/* What this half looks like, and why each row is the shape it is:

     My Shared Folder            <peer> can browse everything in here.
     Sharing:  Macintosh HD:Lab:
     (o) One folder   ( ) The whole startup disk    [Choose Folder...]
     [Send File...]   [===== the send's own bar =====]
     Received files are saved in: Downloads      [Change...]  [Open Folder]

   THREE THINGS CHANGED SHAPE, each because the old one lied a little:

   - the choice is two RADIO buttons. It was a checkbox that disabled a
     button: the same mutual exclusion, expressed only as an enable state
     a person had to notice twice to learn from.
   - "Sharing:" names the one line that is true under either answer -
     what a request from the other Mac actually resolves against
     (fileshare.c::now_files_root_name is emphatic about that being the
     only honest thing to show). The prose line that used to restate it
     underneath is gone; the caption beside the heading says the part the
     path does not, which is what the other Mac may DO with it.
   - where files land is a static label with its own [Change...]. It was
     a push button whose TITLE was the setting - "Get files into:
     Downloads" - which reads as a readout right up until it is clicked,
     and left "Open" beside it naming nothing.

   The progress bar moved onto the Send row. It measures a send; it used
   to float above the buttons with nothing saying which direction it was
   about, on a page whose other half is a download. */

typedef struct {
    Rect sharing_label;
    Rect sharing_value;
    Rect folder_radio;
    Rect disk_radio;
    Rect choose_btn;
    Rect send_btn;
    Rect progress;
    Rect into_label;
    Rect into_value;
    Rect change_btn;
    Rect open_btn;
} ShareRects;

static WindowRef g_owner;
static Rect g_area;                   /* the whole half, for invalidation */
static ShareRects g_r;
static Boolean g_visible;

static ControlRef g_folder;
static ControlRef g_disk;
static ControlRef g_choose;
static ControlRef g_send;
static ControlRef g_change;
static ControlRef g_open;
static ControlRef g_bar;

static char g_note[128];
/* Idle caches: enable state and bar value repaint only on change. */
static short g_send_hilite = -1;
static Boolean g_bar_shown;
static short g_bar_value = -1;
/* The two values this half draws, held rather than asked for.

   BOTH ANSWERS COST A FILE. now_files_root_name and
   now_files_downloads_name each load preferences from disk, and this
   page is walked by more than the update event: describe_scene runs
   whenever the host looks at the window, and Edit>Copy runs the same
   walk again. A page that reads two files every time somebody looks at
   it is the idle-path defect wearing a different hat - the panel this
   view descends from once starved a live transfer doing exactly that.

   So they are re-read at the moments they can change: the page appearing,
   and the two clicks that change them. */
static char g_shown_root[160];
static char g_shown_into[64];

static void refresh_values(void)
{
    now_files_root_name(g_shown_root, sizeof g_shown_root);
    now_files_downloads_name(g_shown_into, sizeof g_shown_into);
}

static void take_rects(const FilesLayoutRects *r)
{
    g_r.sharing_label = r->sharing_label;
    g_r.sharing_value = r->sharing_value;
    g_r.folder_radio = r->folder_radio;
    g_r.disk_radio = r->disk_radio;
    g_r.choose_btn = r->choose_btn;
    g_r.send_btn = r->send_btn;
    g_r.progress = r->progress;
    g_r.into_label = r->into_label;
    g_r.into_value = r->into_value;
    g_r.change_btn = r->change_btn;
    g_r.open_btn = r->open_btn;

    /* The half, as one rectangle: from the heading's line down. */
    g_area = r->mine_heading;
    g_area.right = r->open_btn.right;
    g_area.bottom = r->open_btn.bottom;
    g_area.left = r->mine_heading.left;
}

/* Boot-volume sharing changes only when a radio is clicked, so
   preferences are read THEN - never on the idle path (the panel this
   view descends from once starved a transfer doing that). */
static void sync_share_controls(void)
{
    NowPrefs prefs;

    if (g_folder == NULL) {
        return;
    }
    now_prefs_load(&prefs);
    SetControlValue(g_folder, prefs.share_boot ? 0 : 1);
    SetControlValue(g_disk, prefs.share_boot ? 1 : 0);
    /* Choosing a folder is meaningless while the whole disk is shared,
       and the radio above now says why - the enable state is the echo of
       the choice rather than the only place it is stated. */
    HiliteControl(g_choose, prefs.share_boot ? 255 : 0);
}

static void sync_send_control(void)
{
    short want;

    if (g_send == NULL || !g_visible) {
        return;
    }
    want = (conn_is_connected()
            && now_wire_send_state(NULL, NULL, NULL, 0) == kSendNothing)
        ? 0 : 255;
    if (want != g_send_hilite) {
        g_send_hilite = want;
        HiliteControl(g_send, want);
    }
}

Boolean files_share_create(WindowRef owner, const FilesLayoutRects *r)
{
    Str255 text;

    g_owner = owner;
    take_rects(r);
    g_note[0] = '\0';
    g_send_hilite = -1;
    g_bar_shown = false;
    g_bar_value = -1;
    refresh_values();

    /* Least first: the narrower answer is the one a person should have
       to move away from, not toward. */
    CopyCStringToPascal("One folder", text);
    g_folder = now_control_new(owner, &g_r.folder_radio, text, false, 1, 0, 1,
                               radioButProc, 0);
    CopyCStringToPascal("The whole startup disk", text);
    g_disk = now_control_new(owner, &g_r.disk_radio, text, false, 0, 0, 1,
                             radioButProc, 0);
    CopyCStringToPascal("Choose Folder...", text);
    g_choose = now_control_new(owner, &g_r.choose_btn, text, false, 0, 0, 1,
                               pushButProc, 0);
    CopyCStringToPascal("Send File...", text);
    g_send = now_control_new(owner, &g_r.send_btn, text, false, 0, 0, 1,
                             pushButProc, 0);
    CopyCStringToPascal("Change...", text);
    g_change = now_control_new(owner, &g_r.change_btn, text, false, 0, 0, 1,
                               pushButProc, 0);
    CopyCStringToPascal("Open Folder", text);
    g_open = now_control_new(owner, &g_r.open_btn, text, false, 0, 0, 1,
                             pushButProc, 0);
    /* Native determinate bar; scaled to 0..1000 below. */
    text[0] = 0;
    g_bar = now_control_new(owner, &g_r.progress, text, false, 0, 0, 1000,
                            kControlProgressBarProc, 0);
    if (g_folder == NULL || g_disk == NULL || g_choose == NULL
        || g_send == NULL || g_change == NULL || g_open == NULL
        || g_bar == NULL) {
        return false;
    }
    sync_share_controls();
    return true;
}

void files_share_dispose(void)
{
    g_owner = NULL;
    g_folder = NULL;
    g_disk = NULL;
    g_choose = NULL;
    g_send = NULL;
    g_change = NULL;
    g_open = NULL;
    g_bar = NULL;
}

static void show_control(ControlRef control, Boolean visible)
{
    if (control == NULL) {
        return;
    }
    if (visible) {
        ShowControl(control);
    } else {
        HideControl(control);
    }
}

void files_share_layout(const FilesLayoutRects *r)
{
    take_rects(r);
    if (g_folder == NULL) {
        return;
    }
    MoveControl(g_folder, g_r.folder_radio.left, g_r.folder_radio.top);
    MoveControl(g_disk, g_r.disk_radio.left, g_r.disk_radio.top);
    MoveControl(g_choose, g_r.choose_btn.left, g_r.choose_btn.top);
    MoveControl(g_send, g_r.send_btn.left, g_r.send_btn.top);
    MoveControl(g_change, g_r.change_btn.left, g_r.change_btn.top);
    MoveControl(g_open, g_r.open_btn.left, g_r.open_btn.top);
    MoveControl(g_bar, g_r.progress.left, g_r.progress.top);
    SizeControl(g_bar, (SInt16)(g_r.progress.right - g_r.progress.left),
                (SInt16)(g_r.progress.bottom - g_r.progress.top));
}

void files_share_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_folder, visible);
    show_control(g_disk, visible);
    show_control(g_choose, visible);
    show_control(g_send, visible);
    show_control(g_change, visible);
    show_control(g_open, visible);
    show_control(g_bar, visible && g_bar_shown);
    if (visible) {
        g_send_hilite = -1;
        refresh_values();
        sync_share_controls();
        sync_send_control();
    }
}

void files_share_content(const WorkshopSceneWriter *writer)
{
    files_run(writer, &g_r.sharing_label, false, false, truncEnd, "Sharing:");
    files_run(writer, &g_r.sharing_value, false, true, truncMiddle,
              g_shown_root);
    files_run(writer, &g_r.into_label, false, false, truncEnd,
              "Received files are saved in:");
    files_run(writer, &g_r.into_value, false, true, truncMiddle,
              g_shown_into);
}

void files_share_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    files_share_content(NULL);
}

Boolean files_share_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    (void)event;
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    if (control != g_folder && control != g_disk && control != g_choose
        && control != g_send && control != g_change && control != g_open) {
        return false;
    }
    if (TrackControl(control, local, now_pump_action()) == 0) {
        return true;
    }
    if (control == g_folder || control == g_disk) {
        NowPrefs prefs;
        Boolean want_disk = (Boolean)(control == g_disk);

        now_prefs_load(&prefs);
        if ((Boolean)(prefs.share_boot != 0) != want_disk) {
            prefs.share_boot = want_disk;
            if (now_prefs_save(&prefs) != noErr) {
                snprintf(g_note, sizeof g_note,
                         "Could not save that setting");
            } else {
                g_note[0] = '\0';
            }
        }
        /* Both radios follow preferences rather than the click: a save
           that failed must leave the page showing what is actually
           shared, not what was asked for. */
        sync_share_controls();
        refresh_values();
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_choose) {
        char why[128];
        int rc = now_files_choose_root(why, sizeof why);

        if (rc > 0) {
            g_note[0] = '\0';
        } else if (rc < 0) {
            snprintf(g_note, sizeof g_note, "Not shared: %.100s", why);
        }
        refresh_values();
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_send) {
        FSSpec spec;
        char why[128];
        int rc = now_files_pick_file(&spec, why, sizeof why);

        if (rc > 0 && now_wire_send_file(&spec, why, sizeof why) < 0) {
            snprintf(g_note, sizeof g_note, "%.110s", why);
        } else if (rc < 0) {
            snprintf(g_note, sizeof g_note, "%.110s", why);
        } else if (rc > 0) {
            g_note[0] = '\0';
        }
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_change) {
        char why[128];
        int rc = now_files_choose_downloads(why, sizeof why);

        if (rc > 0) {
            /* The row itself now says where files land, so the outcome
               is on screen; the placard says nothing rather than
               narrating what a person can already read. */
            g_note[0] = '\0';
        } else if (rc < 0) {
            snprintf(g_note, sizeof g_note, "%.110s", why);
        }
        refresh_values();
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_open) {
        if (now_files_reveal_downloads() != kFilesOK) {
            snprintf(g_note, sizeof g_note, "Could not open that folder");
            InvalWindowRect(g_owner, &g_area);
        }
    }
    return true;
}

void files_share_activate(Boolean active)
{
    ControlRef controls[7];
    int i;

    controls[0] = g_folder;
    controls[1] = g_disk;
    controls[2] = g_choose;
    controls[3] = g_send;
    controls[4] = g_change;
    controls[5] = g_open;
    controls[6] = g_bar;
    for (i = 0; i < 7; ++i) {
        if (controls[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(controls[i]);
        } else {
            DeactivateControl(controls[i]);
        }
    }
    if (active && g_visible) {
        /* Send and Choose carry their own enable state; re-derive it
           rather than assuming everything is enabled. */
        g_send_hilite = -1;
        sync_share_controls();
        sync_send_control();
    }
}

/* Every event-loop pass: in-memory reads, and control updates only when
   a shown value would actually change. */
void files_share_idle(void)
{
    long sent = 0, total = 0;
    SendPhase phase;
    Boolean moving;
    short value;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    sync_send_control();
    phase = now_wire_send_state(&sent, &total, NULL, 0);
    /* Only once bytes are moving: an empty bar sitting at zero while
       the host has not answered reads as "stuck" when the truth is
       "waiting" - the status line already says which. */
    moving = (Boolean)(phase == kSendSending && total > 0);
    value = moving ? (short)(1000L * sent / total) : 0;
    if (moving != g_bar_shown) {
        g_bar_shown = moving;
        show_control(g_bar, g_visible && moving);
    }
    if (moving && value != g_bar_value) {
        g_bar_value = value;
        SetControlValue(g_bar, value);
    }
}

void files_share_status(char *out, long cap)
{
    snprintf(out, (size_t)cap, "%s", g_note);
}

void files_share_note(const char *line)
{
    if (g_owner == NULL) {
        return;
    }
    snprintf(g_note, sizeof g_note, "%.120s", line);
}
