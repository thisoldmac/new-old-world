#include "processes_module.h"

#include <stdio.h>
#include <string.h>

#include "confirm.h"
#include "peek.h"
#include "peek_read.h"
#include "prefs.h"
#include "proc_actions.h"
#include "processes_layout.h"
#include "pump.h"
#include "screenshot.h"

/* The Processes page: a Data Browser of everything the Process Manager
   reports on the left, the selected process on the right, and the two
   actions that are honest on this platform - bring to front, and ASK
   to quit. There is no force quit here because no safe one exists;
   a sent quit event keeps the row's PSN until the walk proves the
   process gone (the runner's reap-ladder lesson: removing it early
   makes a slow cooperative exit indistinguishable from a completed
   one).

   The walk itself runs at most once a second from idle() and diffs
   into the panes; TempFreeMem, never FreeMem, for the free figure -
   FreeMem sees only this application's heap, which Retro68's malloc
   drains at startup. */

enum {
    kMaxProcs = 32,
    kWalkIntervalTicks = 60,          /* once a second is plenty */
    kQuitPatienceTicks = 600,         /* 10 s before "no reply" */

    kColName = 'name',
    /* A non-process sentinel row: the "background" divider between the
       two groups. Well outside the process item-id range (1..32). */
    kDividerItem = 1000,

    kQuitNone = 0,
    kQuitAsked = 1,
    kQuitNoReply = 2
};

typedef struct {
    ProcessSerialNumber psn;
    char name[32];
    unsigned long type;
    unsigned long sig;
    long size_kb;
    long used_kb;
    unsigned long launched;           /* processLaunchDate: TICKS since
                                         boot, not a date */
    unsigned long active_time;        /* processActiveTime: CPU ticks */
    unsigned long mode;               /* processMode flags */
    Boolean self;
    Boolean is_front;                 /* the frontmost process */
    short kind;                       /* kProcKind* */
    short window_count;               /* -1 unknown, else windows open */
    short quit_state;
    unsigned long quit_ticks;
    IconRef icon;                     /* may be NULL; released on drop */
} ProcEntry;

static WindowRef g_owner;
static Rect g_body;
static ProcessesLayout g_r;
static Boolean g_visible;
static Boolean g_browser_ok;

static ControlRef g_browser;
static ControlRef g_front;
static ControlRef g_quit;
static ControlRef g_group;
static ControlRef g_capture;          /* "Front & Capture" in the group box */

/* Front & Capture runs in two steps so nothing nests an event loop: the
   click brings the target forward and arms a deadline; a later idle,
   once the target has come front and redrawn, reads its fresh window
   bounds, crops the capture, and restores NOW. */
static Boolean g_capture_pending;
static ProcessSerialNumber g_capture_target;
static ProcessSerialNumber g_capture_self;
static unsigned long g_capture_deadline;
static char g_capture_name[32];
static short g_capture_hilite = -1;

/* A transient message that outranks the process-count status line for a
   few seconds - capture feedback, which the per-second walk would
   otherwise overwrite immediately. */
static char g_notice[96];
static unsigned long g_notice_until;

static ProcEntry g_procs[kMaxProcs];
static int g_proc_count;
static int g_selected = -1;           /* index into g_procs, -1 = none */
static unsigned long g_next_walk;

/* Idle caches: repaint or re-hilite only on change. */
static char g_status[64];
static short g_front_hilite = -1;
static short g_quit_hilite = -1;
/* Set while rebuilding the browser: RemoveDataBrowserItems fires a
   deselect for the selected row, whose notification would otherwise
   clobber g_selected mid-rebuild. */
static Boolean g_in_rebuild;

/* The selected process's windows, read through the anchor plane on the
   throttled idle (the foreign read lives on the 1 Hz path, never in
   draw) and drawn in the detail pane. g_sel_win_psn is whose windows
   the cache holds, so a transient stale read for the SAME process can
   carry the last good result instead of blinking. */
static NowPeekWindowList g_sel_windows;
static NowPeekReadStatus g_sel_win_status = kNowPeekReadNoPlane;
static ProcessSerialNumber g_sel_win_psn;

/* Last-drawn stat strings, so a per-second refresh repaints only the
   fact line that actually changed - and the memory bar only when its
   pixel fill moves, not on every KB of jitter. */
static long g_shown_mem_fill = -1;
static char g_shown_mem[32];
static char g_shown_cpu[24];
static char g_shown_launched[32];
static char g_shown_freshness[24];    /* the window snapshot's "as of" */

/* Real UPPs, retained for the control's lifetime; the shape (and the
   reason it is not a cast) is files_browser_view.c. */
static DataBrowserItemDataUPP g_data_upp;
static DataBrowserItemNotificationUPP g_notify_upp;
static DataBrowserItemCompareUPP g_compare_upp;

/* --- the walk ----------------------------------------------------------- */

static Boolean same_psn(const ProcessSerialNumber *a,
                        const ProcessSerialNumber *b)
{
    return a->highLongOfPSN == b->highLongOfPSN
        && a->lowLongOfPSN == b->lowLongOfPSN;
}

static int find_by_psn(const ProcEntry *table, int count,
                       const ProcessSerialNumber *psn)
{
    int i;

    for (i = 0; i < count; ++i) {
        if (same_psn(&table[i].psn, psn)) {
            return i;
        }
    }
    return -1;
}

static void take_icon(ProcEntry *entry)
{
    if (GetIconRef(kOnSystemDisk, (OSType)entry->sig, (OSType)entry->type,
                   &entry->icon) != noErr) {
        if (GetIconRef(kOnSystemDisk, kSystemIconsCreator,
                       kGenericApplicationIcon, &entry->icon) != noErr) {
            entry->icon = NULL;
        }
    }
}

static void drop_icons(ProcEntry *table, int count)
{
    int i;

    for (i = 0; i < count; ++i) {
        if (table[i].icon != NULL) {
            ReleaseIconRef(table[i].icon);
            table[i].icon = NULL;
        }
    }
}

/* The kind that drives grouping and the "Kind:" label. From
   processMode, not from guessing at the 'appe' type - the mode's
   modeOnlyBackground bit is the authority on what is faceless. */
static short kind_of(unsigned long type, unsigned long sig,
                     unsigned long mode)
{
    if (type == NOW_PEEK_4CC('F', 'N', 'D', 'R')
        || sig == NOW_PEEK_4CC('M', 'A', 'C', 'S')) {
        return kProcKindFinder;
    }
    if ((mode & modeOnlyBackground) != 0) {
        return kProcKindBackground;
    }
    return kProcKindApp;
}

static int walk_processes(ProcEntry *out, int max)
{
    ProcessSerialNumber psn = { 0, kNoProcess };
    ProcessSerialNumber self;
    ProcessSerialNumber front;
    Boolean have_self = GetCurrentProcess(&self) == noErr;
    Boolean have_front = GetFrontProcess(&front) == noErr;
    int count = 0;

    while (count < max && GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        Str31 name;
        ProcEntry *entry = &out[count];
        Boolean same = false;

        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        info.processAppSpec = NULL;
        name[0] = 0;
        if (GetProcessInformation(&psn, &info) != noErr) {
            continue;
        }
        memset(entry, 0, sizeof *entry);
        entry->psn = psn;
        memcpy(entry->name, name + 1, name[0]);
        entry->name[name[0]] = '\0';
        entry->type = info.processType;
        entry->sig = (unsigned long)info.processSignature;
        entry->size_kb = (long)(info.processSize / 1024);
        entry->used_kb =
            (long)((info.processSize - info.processFreeMem) / 1024);
        if (entry->used_kb < 0) {
            entry->used_kb = 0;
        }
        entry->launched = info.processLaunchDate;
        entry->active_time = info.processActiveTime;
        entry->mode = (unsigned long)info.processMode;
        entry->kind = kind_of(entry->type, entry->sig, entry->mode);
        entry->window_count = -1;         /* filled by the anchor read */
        entry->self = have_self && SameProcess(&psn, &self, &same) == noErr
            && same;
        same = false;
        entry->is_front = have_front
            && SameProcess(&psn, &front, &same) == noErr && same;
        ++count;
    }
    return count;
}

static void invalidate_detail(void)
{
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_r.detail);
    }
}

static void invalidate_line(const Rect *line)
{
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, line);
    }
}

static void rebuild_browser_items(void)
{
    DataBrowserItemID ids[kMaxProcs + 1];
    int n = 0;
    int apps = 0;
    int bg = 0;
    int i;

    if (g_browser == NULL) {
        return;
    }
    g_in_rebuild = true;              /* swallow the removal's deselect */
    RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    for (i = 0; i < g_proc_count; ++i) {
        ids[n++] = (DataBrowserItemID)(i + 1);
        if (g_procs[i].kind == kProcKindBackground) {
            ++bg;
        } else {
            ++apps;
        }
    }
    /* The divider only appears when both groups do. */
    if (apps > 0 && bg > 0) {
        ids[n++] = kDividerItem;
    }
    if (n > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, (UInt32)n, ids,
                            kDataBrowserItemNoProperty);
    }
    if (g_selected >= 0) {
        DataBrowserItemID sel = (DataBrowserItemID)(g_selected + 1);

        SetDataBrowserSelectedItems(g_browser, 1, &sel,
                                    kDataBrowserItemsAssign);
    }
    g_in_rebuild = false;
}

/* Refresh the table from the Process Manager. Membership changes
   rebuild the list; value-only changes repaint the detail if it shows
   them. Quit bookkeeping rides along: a quitting entry that vanished
   is done, one that overstayed becomes "no reply". */
static void refresh(void)
{
    ProcEntry fresh[kMaxProcs];
    int fresh_count = walk_processes(fresh, kMaxProcs);
    ProcessSerialNumber selected_psn;
    Boolean had_selection = false;
    /* list_changed = anything that reorders or re-captions a row (needs
       a browser rebuild); values_changed = detail-only (memory). */
    Boolean list_changed = fresh_count != g_proc_count;
    unsigned long now = TickCount();
    long free_kb = TempFreeMem() / 1024;
    char status[64];
    int i;

    if (g_selected >= 0 && g_selected < g_proc_count) {
        selected_psn = g_procs[g_selected].psn;
        had_selection = true;
    }

    for (i = 0; i < fresh_count; ++i) {
        int old = find_by_psn(g_procs, g_proc_count, &fresh[i].psn);

        /* The list badge: window count for foreground apps (a foreign
           read through the anchor plane); background rows carry none. A
           definitive read (Ok / no windows) updates it; a transient
           miss (stale anchor) CARRIES the last known count rather than
           flapping the badge to nothing and forcing a rebuild. */
        if (fresh[i].kind != kProcKindBackground) {
            short wc = 0;
            NowPeekReadStatus st =
                now_peek_window_count(&fresh[i].psn, &wc);

            if (st == kNowPeekReadOk) {
                fresh[i].window_count = wc;
            } else if (st == kNowPeekReadNoWindows) {
                fresh[i].window_count = 0;
            } else {
                fresh[i].window_count =
                    old >= 0 ? g_procs[old].window_count : -1;
            }
        }

        if (old < 0) {
            list_changed = true;
            take_icon(&fresh[i]);
            continue;
        }
        /* Carry what the walk cannot know: the quit state and the
           icon's refcount. */
        fresh[i].quit_state = g_procs[old].quit_state;
        fresh[i].quit_ticks = g_procs[old].quit_ticks;
        fresh[i].icon = g_procs[old].icon;
        g_procs[old].icon = NULL;
        if (old != i || strcmp(fresh[i].name, g_procs[old].name) != 0
            || fresh[i].is_front != g_procs[old].is_front
            || fresh[i].window_count != g_procs[old].window_count) {
            list_changed = true;      /* order or caption changed */
        }
        if (fresh[i].quit_state == kQuitAsked
            && now - fresh[i].quit_ticks > kQuitPatienceTicks) {
            fresh[i].quit_state = kQuitNoReply;
            list_changed = true;
        }
    }
    drop_icons(g_procs, g_proc_count);    /* releases only unclaimed ones */

    if (fresh_count > 0) {
        memcpy(g_procs, fresh, (size_t)fresh_count * sizeof fresh[0]);
    }
    g_proc_count = fresh_count;

    g_selected = -1;
    if (had_selection) {
        g_selected = find_by_psn(g_procs, g_proc_count, &selected_psn);
    }

    proc_status_text(g_proc_count, free_kb, status, sizeof status);
    strcpy(g_status, status);         /* placard diffing is the shell's */

    if (list_changed) {
        rebuild_browser_items();
        invalidate_detail();
    } else if (had_selection && g_selected < 0) {
        invalidate_detail();
    }
    /* The ticking stats (memory/CPU/launched) repaint per changed line
       in update_selected_stats, not here - so the bar does not flash on
       a CPU tick. */
}

/* --- actions ------------------------------------------------------------ */

static void bring_to_front(void)
{
    if (g_selected >= 0 && g_selected < g_proc_count) {
        now_proc_bring_to_front(&g_procs[g_selected].psn);
    }
}

static void ask_to_quit(void)
{
    ProcEntry *entry;
    char heading[64];

    if (g_selected < 0 || g_selected >= g_proc_count) {
        return;
    }
    entry = &g_procs[g_selected];
    if (entry->self || entry->quit_state != kQuitNone) {
        return;
    }
    snprintf(heading, sizeof heading, "Ask \"%.31s\" to quit?",
             entry->name);
    if (!now_confirm(heading,
                     "A busy application can decline, or take a while.",
                     "Quit")) {
        return;
    }
    if (now_proc_ask_quit(&entry->psn) != noErr) {
        entry->quit_state = kQuitNoReply;
    } else {
        entry->quit_state = kQuitAsked;
        entry->quit_ticks = TickCount();
    }
    rebuild_browser_items();          /* the row caption changed */
    invalidate_detail();
    g_next_walk = 0;                  /* watch for the exit promptly */
}

/* A message that outranks the process count for a few seconds. */
static void set_notice(const char *msg)
{
    snprintf(g_notice, sizeof g_notice, "%s", msg);
    g_notice_until = TickCount() + 60 * 8;      /* ~8 seconds */
}

/* Step one of Front & Capture (main-loop code, from the button): bring
   the selected process forward and arm the deferred capture. Nothing
   nests a loop - the main loop gives the target time to come front, and
   a later idle finishes the job. */
static void front_and_capture(void)
{
    if (g_selected < 0 || g_selected >= g_proc_count) {
        return;
    }
    if (g_sel_win_status != kNowPeekReadOk || g_sel_windows.count < 1) {
        set_notice("No readable window to capture for this process.");
        return;
    }
    if (GetCurrentProcess(&g_capture_self) != noErr) {
        return;
    }
    g_capture_target = g_procs[g_selected].psn;
    snprintf(g_capture_name, sizeof g_capture_name, "%.31s",
             g_procs[g_selected].name);
    SetFrontProcess(&g_capture_target);
    g_capture_pending = true;
    /* ~0.75 s for the target to come front and redraw before we read the
       framebuffer; the main loop's WaitNextEvent yields do the waiting. */
    g_capture_deadline = TickCount() + 45;
    {
        char msg[80];

        snprintf(msg, sizeof msg, "Bringing %s forward to capture...",
                 g_capture_name);
        set_notice(msg);
    }
}

/* Step two (from idle, once the deadline passes): read the now-front
   target's fresh window bounds, crop the capture to them, restore NOW. */
static void do_capture(void)
{
    NowPeekWindowList w;
    Rect rect;
    ShotStats stats;
    char err[96];
    char msg[120];
    NowPrefs prefs;

    g_capture_pending = false;
    if (now_peek_windows_for_psn(&g_capture_target, &w) != kNowPeekReadOk
        || w.count < 1) {
        SetFrontProcess(&g_capture_self);
        set_notice("The window could not be read for capture.");
        return;
    }
    SetRect(&rect, w.windows[0].left, w.windows[0].top,
            w.windows[0].right, w.windows[0].bottom);
    now_prefs_load(&prefs);
    if (now_screenshot_rect(&rect, prefs.shot_depth, true, &stats, err,
                            sizeof err) != 0) {
        SetFrontProcess(&g_capture_self);
        snprintf(msg, sizeof msg, "Capture failed: %.80s", err);
        set_notice(msg);
        return;
    }
    SetFrontProcess(&g_capture_self);         /* back to NOW */
    snprintf(msg, sizeof msg,
             "Captured %s - %d x %d - saved \"%.24s\" on the Desktop",
             g_capture_name, stats.width, stats.height, stats.saved_name);
    set_notice(msg);
}

/* --- the list ----------------------------------------------------------- */

static void row_caption(const ProcEntry *entry, char *out, long cap)
{
    if (entry->quit_state == kQuitAsked) {
        snprintf(out, (size_t)cap, "%s (quitting...)", entry->name);
        return;
    }
    if (entry->quit_state == kQuitNoReply) {
        snprintf(out, (size_t)cap, "%s (no reply)", entry->name);
        return;
    }
    if (entry->is_front) {
        snprintf(out, (size_t)cap, "%s  (front)", entry->name);
    } else if (entry->window_count == 1) {
        snprintf(out, (size_t)cap, "%s  1 window", entry->name);
    } else if (entry->window_count > 1) {
        snprintf(out, (size_t)cap, "%s  %d windows", entry->name,
                 entry->window_count);
    } else {
        snprintf(out, (size_t)cap, "%s", entry->name);
    }
}

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const ProcEntry *entry;
    CFStringRef text;
    char caption[48];

    (void)browser;
    if (item == kDividerItem) {
        /* The one non-process row: the group separator. The Data
           Browser itself is told the row is not selectable, so it
           behaves like a rule, not a list item; the text is a run of
           MacRoman em dashes (0xD1) that reads as one. */
        if (property == kDataBrowserItemIsSelectableProperty) {
            SetDataBrowserItemDataBooleanValue(data, false);
            return noErr;
        }
        if (property != kColName) {
            return errDataBrowserPropertyNotSupported;
        }
        text = CFStringCreateWithCString(
            NULL, "\xD1\xD1\xD1\xD1\xD1\xD1  background  "
                  "\xD1\xD1\xD1\xD1\xD1\xD1",
            kCFStringEncodingMacRoman);
        if (text == NULL) {
            return memFullErr;
        }
        SetDataBrowserItemDataText(data, text);
        CFRelease(text);
        return noErr;
    }
    if (changeValue || property != kColName) {
        return errDataBrowserPropertyNotSupported;
    }
    if (item < 1 || item > (DataBrowserItemID)g_proc_count) {
        return errDataBrowserPropertyNotSupported;
    }
    entry = &g_procs[item - 1];
    if (entry->icon != NULL) {
        SetDataBrowserItemDataIcon(data, entry->icon);
    }
    row_caption(entry, caption, sizeof caption);
    text = CFStringCreateWithCString(NULL, caption,
                                     kCFStringEncodingMacRoman);
    if (text == NULL) {
        return memFullErr;
    }
    SetDataBrowserItemDataText(data, text);
    CFRelease(text);
    return noErr;
}

static void item_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    (void)browser;
    /* Notifications fired by our own rebuild are not user intent - the
       removal deselects the selected row, which we must not act on. */
    if (g_in_rebuild || item == kDividerItem) {
        return;
    }
    if (message == kDataBrowserItemSelected) {
        g_selected = (int)item - 1;
        invalidate_detail();
        g_next_walk = 0;              /* re-read this process's window now */
    } else if (message == kDataBrowserItemDeselected
               && g_selected == (int)item - 1) {
        g_selected = -1;
        invalidate_detail();
        g_next_walk = 0;
    }
}

static char ascii_lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

/* Group order: the front process pins to the top, then applications,
   then the divider, then background-only processes; within a group, by
   name. Kind (static) and front-ness are the sort axes - window state
   is not, so a row never jumps when a window opens or closes. */
static short rank_of(DataBrowserItemID item)
{
    const ProcEntry *e;

    if (item == kDividerItem) {
        return 2;
    }
    if (item < 1 || item > (DataBrowserItemID)g_proc_count) {
        return 4;
    }
    e = &g_procs[item - 1];
    if (e->is_front) {
        return 0;
    }
    return e->kind == kProcKindBackground ? 3 : 1;
}

static Boolean item_compare(ControlRef browser, DataBrowserItemID a,
                            DataBrowserItemID b,
                            DataBrowserPropertyID property)
{
    short ra = rank_of(a);
    short rb = rank_of(b);
    const char *na;
    const char *nb;

    (void)browser;
    (void)property;
    if (ra != rb) {
        return ra < rb;
    }
    /* Same rank: only two processes (apps, or background) ever tie -
       front and divider are unique - so a plain name compare orders
       them. */
    if (a < 1 || a > (DataBrowserItemID)g_proc_count || b < 1
        || b > (DataBrowserItemID)g_proc_count) {
        return a < b;
    }
    na = g_procs[a - 1].name;
    nb = g_procs[b - 1].name;
    while (*na != '\0' && *nb != '\0'
           && ascii_lower(*na) == ascii_lower(*nb)) {
        ++na;
        ++nb;
    }
    return ascii_lower(*na) < ascii_lower(*nb);
}

static void dispose_callbacks(void)
{
    if (g_data_upp != NULL) {
        DisposeDataBrowserItemDataUPP(g_data_upp);
        g_data_upp = NULL;
    }
    if (g_notify_upp != NULL) {
        DisposeDataBrowserItemNotificationUPP(g_notify_upp);
        g_notify_upp = NULL;
    }
    if (g_compare_upp != NULL) {
        DisposeDataBrowserItemCompareUPP(g_compare_upp);
        g_compare_upp = NULL;
    }
}

static Boolean create_browser(void)
{
    DataBrowserCallbacks callbacks;
    DataBrowserListViewColumnDesc col;

    if (CreateDataBrowserControl(g_owner, &g_r.list, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;
        return false;
    }
    memset(&callbacks, 0, sizeof callbacks);
    callbacks.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&callbacks);
    g_data_upp = NewDataBrowserItemDataUPP(item_data);
    g_notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
    g_compare_upp = NewDataBrowserItemCompareUPP(item_compare);
    if (g_data_upp == NULL || g_notify_upp == NULL
        || g_compare_upp == NULL) {
        dispose_callbacks();
        DisposeControl(g_browser);
        g_browser = NULL;
        return false;
    }
    callbacks.u.v1.itemDataCallback = g_data_upp;
    callbacks.u.v1.itemNotificationCallback = g_notify_upp;
    callbacks.u.v1.itemCompareCallback = g_compare_upp;
    if (SetDataBrowserCallbacks(g_browser, &callbacks) != noErr) {
        return false;
    }

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = kColName;
    col.propertyDesc.propertyType = kDataBrowserIconAndTextType;
    col.propertyDesc.propertyFlags = kDataBrowserListViewSortableColumn
        | kDataBrowserListViewSelectionColumn;
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = 40;
    col.headerBtnDesc.maximumWidth = 400;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, "Name", kCFStringEncodingMacRoman);
    if (AddDataBrowserListViewColumn(g_browser, &col, 0) != noErr) {
        if (col.headerBtnDesc.titleString != NULL) {
            CFRelease(col.headerBtnDesc.titleString);
        }
        return false;
    }
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    SetDataBrowserTableViewNamedColumnWidth(
        g_browser, kColName,
        (UInt16)(g_r.list.right - g_r.list.left - 16));
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    SetDataBrowserSortProperty(g_browser, kColName);
    HideControl(g_browser);
    return true;
}

/* --- module ops --------------------------------------------------------- */

static OSErr procs_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_body = *body;
    processes_layout_compute(body, &g_r);
    g_proc_count = 0;
    g_selected = -1;
    g_next_walk = 0;
    g_status[0] = '\0';
    g_front_hilite = -1;
    g_quit_hilite = -1;

    CopyCStringToPascal("Bring to Front", text);
    g_front = NewControl(owner, &g_r.front_btn, text, false, 0, 0, 1,
                         pushButProc, 0);
    CopyCStringToPascal("Ask to Quit", text);
    g_quit = NewControl(owner, &g_r.quit_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    CopyCStringToPascal("NOW Extension", text);
    g_group = NewControl(owner, &g_r.group, text, false, 0, 0, 1,
                         kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Front & Capture", text);
    g_capture = NewControl(owner, &g_r.capture_btn, text, false, 0, 0, 1,
                           pushButProc, 0);
    if (g_front == NULL || g_quit == NULL || g_group == NULL
        || g_capture == NULL) {
        return memFullErr;
    }
    /* A missing Data Browser costs the list, not the page: the detail
       pane explains, the way the Files page degrades. */
    g_browser_ok = create_browser();
    return noErr;
}

static void procs_dispose(void)
{
    /* workshop_close disposes this module BEFORE DisposeWindow, so the
       Data Browser is still live. Its disposal fires item notifications
       that reach item_data/item_notify through the UPPs and read the
       process model, so tear the control down FIRST - while both are
       valid - then free the UPPs and the model. Freeing the UPPs while
       the browser still held them let DisposeWindow later call through a
       freed transition vector: an intermittent system crash on quit. */
    if (g_browser != NULL) {
        DisposeControl(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    drop_icons(g_procs, g_proc_count);
    g_proc_count = 0;
    g_selected = -1;
    g_owner = NULL;
    g_front = NULL;
    g_quit = NULL;
    g_group = NULL;
    g_capture = NULL;
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

static void procs_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_browser, visible);
    show_control(g_front, visible);
    show_control(g_quit, visible);
    show_control(g_group, visible);
    show_control(g_capture, visible);
    /* Arm the anchor plane only while this page is the one consuming it,
       and release it on the way out - a machine whose user never opens
       Processes never runs the capture loop (the charter's rule). A
       no-op when the extension is absent. */
    if (visible) {
        now_peek_arm(kNowPeekCapAnchors);
        g_next_walk = 0;              /* a fresh page walks now */
        g_front_hilite = -1;
        g_quit_hilite = -1;
        memset(&g_sel_windows, 0, sizeof g_sel_windows);
        g_sel_win_status = kNowPeekReadNoPlane;   /* re-read on first idle */
        memset(&g_sel_win_psn, 0, sizeof g_sel_win_psn);
        g_shown_mem_fill = -1;
        g_shown_mem[0] = g_shown_cpu[0] = g_shown_launched[0] = '\0';
        g_shown_freshness[0] = '\0';
        g_capture_hilite = -1;
    } else {
        now_peek_disarm(kNowPeekCapAnchors);
    }
}

static void procs_layout(const Rect *body)
{
    g_body = *body;
    processes_layout_compute(body, &g_r);
    if (g_browser != NULL) {
        MoveControl(g_browser, g_r.list.left, g_r.list.top);
        SizeControl(g_browser, (SInt16)(g_r.list.right - g_r.list.left),
                    (SInt16)(g_r.list.bottom - g_r.list.top));
        SetDataBrowserTableViewNamedColumnWidth(
            g_browser, kColName,
            (UInt16)(g_r.list.right - g_r.list.left - 16));
    }
    if (g_front != NULL) {
        MoveControl(g_front, g_r.front_btn.left, g_r.front_btn.top);
    }
    if (g_quit != NULL) {
        MoveControl(g_quit, g_r.quit_btn.left, g_r.quit_btn.top);
    }
    if (g_group != NULL) {
        MoveControl(g_group, g_r.group.left, g_r.group.top);
        SizeControl(g_group, (SInt16)(g_r.group.right - g_r.group.left),
                    (SInt16)(g_r.group.bottom - g_r.group.top));
    }
    if (g_capture != NULL) {
        MoveControl(g_capture, g_r.capture_btn.left, g_r.capture_btn.top);
    }
}

static void draw_fact(const Rect *line, const char *label,
                      const char *value)
{
    Str255 text;
    short label_right = (short)(line->left + kProcFactLabelWidth);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    CopyCStringToPascal(label, text);
    MoveTo((short)(label_right - StringWidth(text)),
           (short)(line->top + 11));
    DrawString(text);
    CopyCStringToPascal(value, text);
    TruncString((short)(line->right - label_right - 8), text, truncEnd);
    MoveTo((short)(label_right + 8), (short)(line->top + 11));
    DrawString(text);
}

static void draw_mem_bar(const ProcEntry *entry)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor fill = { 0x7D7D, 0x9090, 0xB8B8 };
    Rect inner = g_r.mem_bar;
    long fill_w;

    RGBForeColor(&black);
    FrameRect(&g_r.mem_bar);
    InsetRect(&inner, 1, 1);
    EraseRect(&inner);
    fill_w = proc_mem_fill(entry->used_kb, entry->size_kb,
                           inner.right - inner.left);
    if (fill_w > 0) {
        Rect used = inner;

        used.right = (short)(used.left + fill_w);
        RGBForeColor(&fill);
        PaintRect(&used);
        RGBForeColor(&black);
    }
}

/* A one-pixel etched separator (dark line over white) across the detail
   width at y - the Platinum rule the HIG uses to divide a pane. */
static void draw_detail_rule(short y)
{
    RGBColor edge = { 0x8888, 0x8888, 0x8888 };
    RGBColor lite = { 0xFFFF, 0xFFFF, 0xFFFF };
    short x0 = (short)(g_r.detail.left + 12);
    short x1 = (short)(g_r.detail.right - 12);

    RGBForeColor(&edge);
    MoveTo(x0, y);
    LineTo(x1, y);
    RGBForeColor(&lite);
    MoveTo(x0, (short)(y + 1));
    LineTo(x1, (short)(y + 1));
    ForeColor(blackColor);
}

/* The Windows subsection for the selected process: a bold "Windows"
   header carrying the count or the read status (none open / no anchor
   yet / unreadable), then up to kProcDetailWindows title+size rows. A
   faceless background app is stated as such rather than chased. */
static void draw_window_facts(const ProcEntry *entry)
{
    Str255 text;
    char line[96];
    char value[40];
    int rows;
    int full;
    int i;

    if (entry->kind == kProcKindBackground) {
        snprintf(value, sizeof value, "none (background app)");
    } else {
        switch (g_sel_win_status) {
        case kNowPeekReadOk: {
            char fresh[24];

            /* Honest staleness: an actively-pumping app is live and
               gets no marker; a process whose snapshot has aged shows
               how old it is (the AXPeek/qdpeek discipline). */
            proc_freshness_text(
                (unsigned long)(TickCount() - g_sel_windows.stamp_ticks),
                fresh, sizeof fresh);
            if (fresh[0] != '\0') {
                snprintf(value, sizeof value, "%d%s  %s",
                         g_sel_windows.count,
                         g_sel_windows.more ? " (more)" : "", fresh);
            } else {
                snprintf(value, sizeof value, "%d%s", g_sel_windows.count,
                         g_sel_windows.more ? " (more)" : "");
            }
            break;
        }
        case kNowPeekReadNoWindows:
            snprintf(value, sizeof value, "none open");
            break;
        case kNowPeekReadNoAnchor:
            snprintf(value, sizeof value, "no anchor yet");
            break;
        case kNowPeekReadUnreadable:
            snprintf(value, sizeof value, "unreadable");
            break;
        /* Both mean the plane is live and this process's anchor is not
           trustworthy - a different statement from "not captured yet",
           and the reason they stopped being folded into it. Worded for
           someone who does not know what an anchor slot is. */
        case kNowPeekReadAmbiguous:
            snprintf(value, sizeof value, "unclear (two matches)");
            break;
        case kNowPeekReadMismatch:
            snprintf(value, sizeof value, "stale anchor");
            break;
        default:
            snprintf(value, sizeof value, "-");   /* no plane */
            break;
        }
    }
    /* Bold "Windows" header, so the subsection reads as its own group. */
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    CopyCStringToPascal("Windows", text);
    MoveTo(g_r.windows_line.left, (short)(g_r.windows_line.top + 11));
    DrawString(text);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    CopyCStringToPascal(value, text);
    MoveTo((short)(g_r.windows_line.left + 62),
           (short)(g_r.windows_line.top + 11));
    DrawString(text);

    if (entry->kind == kProcKindBackground) {
        return;
    }
    rows = kProcDetailWindows;
    full = g_sel_windows.count <= rows ? g_sel_windows.count : rows - 1;
    for (i = 0; i < full; ++i) {
        const NowPeekWindow *w = &g_sel_windows.windows[i];
        const Rect *r = &g_r.window_rows[i];

        snprintf(line, sizeof line, "%s  %d x %d",
                 w->title[0] != '\0' ? w->title : "(untitled)",
                 w->right - w->left, w->bottom - w->top);
        CopyCStringToPascal(line, text);
        TruncString((short)(r->right - r->left), text, truncEnd);
        MoveTo(r->left, (short)(r->top + 10));
        DrawString(text);
    }
    if (g_sel_windows.count > rows) {
        const Rect *r = &g_r.window_rows[rows - 1];

        snprintf(line, sizeof line, "... and %d more",
                 g_sel_windows.count - full);
        CopyCStringToPascal(line, text);
        MoveTo(r->left, (short)(r->top + 10));
        DrawString(text);
    }
}

static void draw_detail(void)
{
    Str255 text;
    char line[96];
    const ProcEntry *entry = NULL;

    if (g_selected >= 0 && g_selected < g_proc_count) {
        entry = &g_procs[g_selected];
    }

    if (entry == NULL) {
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        MoveTo(g_r.title_line.left, (short)(g_r.title_line.top + 12));
        CopyCStringToPascal(g_browser_ok ? "Select a process."
                                         : "The list is not available "
                                           "on this Mac.",
                            text);
        DrawString(text);
        return;
    }

    /* Title is the process name only - the window badge belongs to the
       list row, and duplicating it here can disagree (the badge's count
       walk and the detail's full walk validate differently). */
    if (entry->quit_state == kQuitAsked) {
        snprintf(line, sizeof line, "%s (quitting...)", entry->name);
    } else if (entry->quit_state == kQuitNoReply) {
        snprintf(line, sizeof line, "%s (no reply)", entry->name);
    } else {
        snprintf(line, sizeof line, "%s", entry->name);
    }
    UseThemeFont(kThemeEmphasizedSystemFont, smSystemScript);
    CopyCStringToPascal(line, text);
    TruncString((short)(g_r.title_line.right - g_r.title_line.left), text,
                truncEnd);
    MoveTo(g_r.title_line.left, (short)(g_r.title_line.top + 13));
    DrawString(text);
    draw_detail_rule((short)(g_r.title_line.bottom + 1));

    proc_kind_name(entry->kind, line, sizeof line);
    if (entry->is_front) {
        size_t n = strlen(line);

        snprintf(line + n, sizeof line - n, " (frontmost)");
    }
    draw_fact(&g_r.kind_line, "Kind:", line);
    {
        char type_four[5];
        char sig_four[5];

        proc_fourcc_text(entry->type, type_four);
        proc_fourcc_text(entry->sig, sig_four);
        snprintf(line, sizeof line, "%s / %s", type_four, sig_four);
        draw_fact(&g_r.type_line, "Type:", line);
    }
    proc_mem_text(entry->used_kb, entry->size_kb, line, sizeof line);
    draw_fact(&g_r.mem_line, "Memory:", line);
    draw_mem_bar(entry);
    proc_cpu_text(entry->active_time, line, sizeof line);
    draw_fact(&g_r.cpu_line, "CPU:", line);
    /* processLaunchDate is ticks since boot, not a 1904 date; the delta
       to now is the only honest reading (proc_uptime_text). */
    proc_uptime_text((long)(TickCount() - entry->launched), line,
                     sizeof line);
    draw_fact(&g_r.launched_line, "Launched:", line);

    draw_window_facts(entry);

    /* Menus: the anchor captures MenuList, but the walk is a later pass;
       the slot is here so it does not move when it arrives. A faceless
       background app has no menu bar to read. */
    draw_fact(&g_r.menus_line, "Menus:",
              entry->kind == kProcKindBackground ? "none (background app)"
                                                 : "not read yet");
}

static void procs_draw(void)
{
    Str255 text;
    char line[80];

    if (g_owner == NULL || !g_visible) {
        return;
    }
    if (!g_browser_ok) {
        RGBColor black = { 0, 0, 0 };

        RGBForeColor(&black);
        FrameRect(&g_r.list);
    }
    draw_detail();

    /* Group-box interiors are the module's canvas (workshop_window.c
       draws module text after the controls). */
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    now_peek_status_line(line, sizeof line);
    CopyCStringToPascal(line, text);
    TruncString((short)(g_r.peek_line.right - g_r.peek_line.left), text,
                truncEnd);
    MoveTo(g_r.peek_line.left, (short)(g_r.peek_line.top + 11));
    DrawString(text);
}

static Boolean procs_click(const EventRecord *event, Point local)
{
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (g_front != NULL && PtInRect(local, &g_r.front_btn)) {
        if (g_front_hilite == 0
            && TrackControl(g_front, local, now_pump_action()) != 0) {
            bring_to_front();
        }
        return true;
    }
    if (g_quit != NULL && PtInRect(local, &g_r.quit_btn)) {
        if (g_quit_hilite == 0
            && TrackControl(g_quit, local, now_pump_action()) != 0) {
            ask_to_quit();
        }
        return true;
    }
    if (g_capture != NULL && PtInRect(local, &g_r.capture_btn)) {
        if (g_capture_hilite == 0
            && TrackControl(g_capture, local, now_pump_action()) != 0) {
            front_and_capture();
        }
        return true;
    }
    if (g_browser != NULL && PtInRect(local, &g_r.list)) {
        /* The control runs its own tracking: selection and the header. */
        HandleControlClick(g_browser, local, event->modifiers, NULL);
        return true;
    }
    return false;
}

static Boolean procs_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    ControlRef focus = NULL;

    if (g_browser == NULL || !g_visible) {
        return false;
    }
    /* Only when the list has the focus: otherwise the arrows belong to
       the sidebar. */
    if (GetKeyboardFocus(g_owner, &focus) != noErr || focus != g_browser) {
        return false;
    }
    HandleControlKey(g_browser,
                     (SInt16)((event->message & keyCodeMask) >> 8), c,
                     event->modifiers);
    return true;
}

static void procs_activate(Boolean active)
{
    ControlRef controls[5];
    int i;

    controls[0] = g_browser;
    controls[1] = g_front;
    controls[2] = g_quit;
    controls[3] = g_group;
    controls[4] = g_capture;
    for (i = 0; i < 5; ++i) {
        if (controls[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(controls[i]);
        } else {
            DeactivateControl(controls[i]);
        }
    }
    if (active) {
        g_front_hilite = -1;          /* re-derive the dimming */
        g_quit_hilite = -1;
        g_capture_hilite = -1;
        if (g_browser != NULL && g_visible && g_owner != NULL) {
            SetKeyboardFocus(g_owner, g_browser, kControlFocusNextPart);
        }
    }
}

/* Read the selected process's windows into the cache the detail pane
   draws. On the throttled path (foreign memory), only on change. */
/* Window content only - NOT the capture stamp. The stamp advances on
   every pump (once a second for an active app) while the windows are
   unchanged, so comparing it would repaint the whole pane every second;
   the freshness phrase is coarse and gated separately. */
static Boolean windows_content_equal(const NowPeekWindowList *a,
                                     const NowPeekWindowList *b)
{
    return a->count == b->count && a->more == b->more
        && memcmp(a->windows, b->windows, sizeof a->windows) == 0;
}

static void refresh_selected_windows(void)
{
    NowPeekWindowList w;
    NowPeekWindowList desired;
    NowPeekReadStatus st;
    NowPeekReadStatus desired_st;
    ProcessSerialNumber psn;
    Boolean new_sel;
    Boolean had_definitive;

    if (g_selected < 0 || g_selected >= g_proc_count) {
        if (g_sel_win_status != kNowPeekReadNoPlane
            || g_sel_windows.count != 0) {
            memset(&g_sel_windows, 0, sizeof g_sel_windows);
            g_sel_win_status = kNowPeekReadNoPlane;
            invalidate_detail();
        }
        return;
    }
    psn = g_procs[g_selected].psn;
    new_sel = !same_psn(&psn, &g_sel_win_psn);

    memset(&w, 0, sizeof w);
    if (g_procs[g_selected].kind == kProcKindBackground) {
        /* A faceless background app has no user windows; do not chase an
           anchor that will only go stale. */
        st = kNowPeekReadNoWindows;
    } else {
        st = now_peek_windows_for_psn(&psn, &w);
    }

    /* Carry the last DEFINITIVE read (windows, or confirmed none) across
       a transient stale/unreadable blip for the SAME process, so an idle
       backgrounded app's readout persists instead of blinking. A new
       selection, or one with no good prior read, shows the reason. */
    had_definitive = g_sel_win_status == kNowPeekReadOk
        || g_sel_win_status == kNowPeekReadNoWindows;
    desired = g_sel_windows;
    desired_st = g_sel_win_status;
    if (st == kNowPeekReadOk || st == kNowPeekReadNoWindows) {
        desired = w;
        desired_st = st;
    } else if (new_sel || !had_definitive) {
        memset(&desired, 0, sizeof desired);
        desired_st = st;
    }
    g_sel_win_psn = psn;

    if (desired_st != g_sel_win_status
        || !windows_content_equal(&desired, &g_sel_windows)) {
        g_sel_windows = desired;
        g_sel_win_status = desired_st;
        invalidate_detail();
    } else {
        /* Same windows, newer capture: keep the stamp current so the
           freshness readout stays live, but do NOT repaint - the coarse
           "as of" phrase is gated in update_selected_stats. */
        g_sel_windows.stamp_ticks = desired.stamp_ticks;
    }
}

/* Repaint only the fact line whose displayed value changed. The memory
   bar is gated on its pixel fill, not raw KB, so sub-pixel jitter never
   flashes it; the CPU line updates each second, the launch line only
   when the minute rolls. */
static void update_selected_stats(void)
{
    const ProcEntry *e;
    char buf[32];
    long fill;

    if (g_selected < 0 || g_selected >= g_proc_count) {
        g_shown_mem_fill = -1;
        g_shown_mem[0] = g_shown_cpu[0] = '\0';
        g_shown_launched[0] = g_shown_freshness[0] = '\0';
        return;
    }
    e = &g_procs[g_selected];

    proc_mem_text(e->used_kb, e->size_kb, buf, sizeof buf);
    if (strcmp(buf, g_shown_mem) != 0) {
        strcpy(g_shown_mem, buf);
        invalidate_line(&g_r.mem_line);
    }
    fill = proc_mem_fill(e->used_kb, e->size_kb,
                         g_r.mem_bar.right - g_r.mem_bar.left - 2);
    if (fill != g_shown_mem_fill) {
        g_shown_mem_fill = fill;
        invalidate_line(&g_r.mem_bar);
    }
    proc_cpu_text(e->active_time, buf, sizeof buf);
    if (strcmp(buf, g_shown_cpu) != 0) {
        strcpy(g_shown_cpu, buf);
        invalidate_line(&g_r.cpu_line);
    }
    proc_uptime_text((long)(TickCount() - e->launched), buf, sizeof buf);
    if (strcmp(buf, g_shown_launched) != 0) {
        strcpy(g_shown_launched, buf);
        invalidate_line(&g_r.launched_line);
    }

    /* The window snapshot's freshness ticks past its coarse boundaries
       (live -> a moment ago -> N min ago); repaint the header only when
       the shown phrase actually changes. */
    if (g_sel_win_status == kNowPeekReadOk) {
        proc_freshness_text(
            (unsigned long)(TickCount() - g_sel_windows.stamp_ticks), buf,
            sizeof buf);
    } else {
        buf[0] = '\0';
    }
    if (strcmp(buf, g_shown_freshness) != 0) {
        strcpy(g_shown_freshness, buf);
        invalidate_line(&g_r.windows_line);
    }
}

static void procs_idle(void)
{
    short want_front;
    short want_quit;
    short want_capture;
    const ProcEntry *entry = NULL;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    /* Finish a deferred Front & Capture once the target has had time to
       come forward and redraw. Runs even while NOW is in the background,
       which is exactly when it must. */
    if (g_capture_pending && TickCount() >= g_capture_deadline) {
        do_capture();
    }
    if (TickCount() >= g_next_walk) {
        g_next_walk = TickCount() + kWalkIntervalTicks;
        refresh();
        refresh_selected_windows();   /* the foreign read, throttled */
        update_selected_stats();      /* per-line stat repaints */
    }
    if (g_selected >= 0 && g_selected < g_proc_count) {
        entry = &g_procs[g_selected];
    }
    /* HiliteControl redraws unconditionally; only on change. */
    want_front = (short)(entry != NULL ? 0 : 255);
    want_quit = (short)((entry != NULL && !entry->self
                         && entry->quit_state == kQuitNone)
                            ? 0
                            : 255);
    /* Capture needs a window we could actually read through the plane. */
    want_capture = (short)((g_sel_win_status == kNowPeekReadOk
                            && g_sel_windows.count >= 1 && !g_capture_pending)
                               ? 0
                               : 255);
    if (want_front != g_front_hilite && g_front != NULL) {
        g_front_hilite = want_front;
        HiliteControl(g_front, want_front);
    }
    if (want_quit != g_quit_hilite && g_quit != NULL) {
        g_quit_hilite = want_quit;
        HiliteControl(g_quit, want_quit);
    }
    if (want_capture != g_capture_hilite && g_capture != NULL) {
        g_capture_hilite = want_capture;
        HiliteControl(g_capture, want_capture);
    }
}

static void procs_status_text(char *out, long cap)
{
    if (g_notice[0] != '\0' && TickCount() < g_notice_until) {
        snprintf(out, (size_t)cap, "%s", g_notice);
    } else if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_status);
    } else {
        snprintf(out, (size_t)cap, "Reading the process list...");
    }
}

static const WorkshopModuleOps k_ops = {
    procs_create,
    procs_dispose,
    procs_show,
    procs_layout,
    procs_draw,
    procs_click,
    procs_key,
    procs_activate,
    procs_idle,
    procs_status_text
};

const WorkshopModuleOps *processes_module_ops(void)
{
    return &k_ops;
}
