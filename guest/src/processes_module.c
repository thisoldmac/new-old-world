#include "processes_module.h"

#include <stdio.h>
#include <string.h>

#include "confirm.h"
#include "peek.h"
#include "peek_read.h"
#include "processes_layout.h"
#include "pump.h"

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
    Boolean self;
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

static ProcEntry g_procs[kMaxProcs];
static int g_proc_count;
static int g_selected = -1;           /* index into g_procs, -1 = none */
static unsigned long g_next_walk;

/* Idle caches: repaint or re-hilite only on change. */
static char g_status[64];
static short g_front_hilite = -1;
static short g_quit_hilite = -1;
/* The anchor-plane readout (group box, second line), refreshed on the
   throttled idle so it tracks the front app even while NOW is in the
   background - the foreign read lives on the 1 Hz path, never in draw. */
static char g_shown_bounds[48];

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

static int walk_processes(ProcEntry *out, int max)
{
    ProcessSerialNumber psn = { 0, kNoProcess };
    ProcessSerialNumber self;
    Boolean have_self = GetCurrentProcess(&self) == noErr;
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
        entry->self = have_self && SameProcess(&psn, &self, &same) == noErr
            && same;
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

static void rebuild_browser_items(void)
{
    DataBrowserItemID ids[kMaxProcs];
    int i;

    if (g_browser == NULL) {
        return;
    }
    RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    for (i = 0; i < g_proc_count; ++i) {
        ids[i] = (DataBrowserItemID)(i + 1);
    }
    if (g_proc_count > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem,
                            (UInt32)g_proc_count, ids,
                            kDataBrowserItemNoProperty);
    }
    if (g_selected >= 0) {
        DataBrowserItemID sel = (DataBrowserItemID)(g_selected + 1);

        SetDataBrowserSelectedItems(g_browser, 1, &sel,
                                    kDataBrowserItemsAssign);
    }
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
    Boolean membership_changed = fresh_count != g_proc_count;
    Boolean values_changed = false;
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

        if (old < 0) {
            membership_changed = true;
            take_icon(&fresh[i]);
            continue;
        }
        /* Carry what the walk cannot know: the quit state and the
           icon's refcount. */
        fresh[i].quit_state = g_procs[old].quit_state;
        fresh[i].quit_ticks = g_procs[old].quit_ticks;
        fresh[i].icon = g_procs[old].icon;
        g_procs[old].icon = NULL;
        if (old != i || strcmp(fresh[i].name, g_procs[old].name) != 0) {
            membership_changed = true;
        }
        if (fresh[i].used_kb != g_procs[old].used_kb
            || fresh[i].size_kb != g_procs[old].size_kb) {
            values_changed = true;
        }
        if (fresh[i].quit_state == kQuitAsked
            && now - fresh[i].quit_ticks > kQuitPatienceTicks) {
            fresh[i].quit_state = kQuitNoReply;
            membership_changed = true;    /* the row's caption changed */
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

    if (membership_changed) {
        rebuild_browser_items();
        invalidate_detail();
    } else if (values_changed && g_selected >= 0) {
        invalidate_detail();
    } else if (had_selection && g_selected < 0) {
        invalidate_detail();
    }
}

/* --- actions ------------------------------------------------------------ */

static OSErr send_quit_event(const ProcessSerialNumber *psn)
{
    AEAddressDesc target;
    AppleEvent event;
    AppleEvent reply;
    OSErr err;

    err = AECreateDesc(typeProcessSerialNumber, psn, sizeof *psn, &target);
    if (err != noErr) {
        return err;
    }
    err = AECreateAppleEvent(kCoreEventClass, kAEQuitApplication, &target,
                             kAutoGenerateReturnID, kAnyTransactionID,
                             &event);
    AEDisposeDesc(&target);
    if (err != noErr) {
        return err;
    }
    err = AESend(&event, &reply, kAENoReply | kAENeverInteract,
                 kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    AEDisposeDesc(&event);
    return err;
}

static void bring_to_front(void)
{
    if (g_selected >= 0 && g_selected < g_proc_count) {
        SetFrontProcess(&g_procs[g_selected].psn);
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
    if (send_quit_event(&entry->psn) != noErr) {
        entry->quit_state = kQuitNoReply;
    } else {
        entry->quit_state = kQuitAsked;
        entry->quit_ticks = TickCount();
    }
    rebuild_browser_items();          /* the row caption changed */
    invalidate_detail();
    g_next_walk = 0;                  /* watch for the exit promptly */
}

/* --- the list ----------------------------------------------------------- */

static void row_caption(const ProcEntry *entry, char *out, long cap)
{
    if (entry->quit_state == kQuitAsked) {
        snprintf(out, (size_t)cap, "%s (quitting...)", entry->name);
    } else if (entry->quit_state == kQuitNoReply) {
        snprintf(out, (size_t)cap, "%s (no reply)", entry->name);
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
    if (changeValue || property != kColName || item < 1
        || item > (DataBrowserItemID)g_proc_count) {
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

static Boolean item_compare(ControlRef browser, DataBrowserItemID a,
                            DataBrowserItemID b,
                            DataBrowserPropertyID property)
{
    const char *na;
    const char *nb;

    (void)browser;
    (void)property;
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
    if (g_front == NULL || g_quit == NULL || g_group == NULL) {
        return memFullErr;
    }
    /* A missing Data Browser costs the list, not the page: the detail
       pane explains, the way the Files page degrades. */
    g_browser_ok = create_browser();
    return noErr;
}

static void procs_dispose(void)
{
    drop_icons(g_procs, g_proc_count);
    g_proc_count = 0;
    g_selected = -1;
    g_owner = NULL;
    g_browser = NULL;
    g_front = NULL;
    g_quit = NULL;
    g_group = NULL;
    dispose_callbacks();
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
    /* Arm the anchor plane only while this page is the one consuming it,
       and release it on the way out - a machine whose user never opens
       Processes never runs the capture loop (the charter's rule). A
       no-op when the extension is absent. */
    if (visible) {
        now_peek_arm(kNowPeekCapAnchors);
        g_next_walk = 0;              /* a fresh page walks now */
        g_front_hilite = -1;
        g_quit_hilite = -1;
        g_shown_bounds[0] = '\0';     /* re-read on the first idle */
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

    UseThemeFont(kThemeEmphasizedSystemFont, smSystemScript);
    row_caption(entry, line, sizeof line);
    CopyCStringToPascal(line, text);
    TruncString((short)(g_r.title_line.right - g_r.title_line.left), text,
                truncEnd);
    MoveTo(g_r.title_line.left, (short)(g_r.title_line.top + 13));
    DrawString(text);

    proc_kind_text(entry->type, line, sizeof line);
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
    /* processLaunchDate is ticks since boot, not a 1904 date; the delta
       to now is the only honest reading (proc_uptime_text). */
    proc_uptime_text((long)(TickCount() - entry->launched), line,
                     sizeof line);
    draw_fact(&g_r.launched_line, "Launched:", line);
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

    /* The anchor-plane readout, from the idle-refreshed cache (the
       foreign read happens there, never here). Empty when there is no
       plane, so the group box shows only its status line. */
    if (g_shown_bounds[0] != '\0') {
        CopyCStringToPascal(g_shown_bounds, text);
        TruncString((short)(g_r.peek_line.right - g_r.peek_line.left),
                    text, truncEnd);
        MoveTo(g_r.peek_line.left, (short)(g_r.peek_line.top + 25));
        DrawString(text);
    }
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
    ControlRef controls[4];
    int i;

    controls[0] = g_browser;
    controls[1] = g_front;
    controls[2] = g_quit;
    controls[3] = g_group;
    for (i = 0; i < 4; ++i) {
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
        if (g_browser != NULL && g_visible && g_owner != NULL) {
            SetKeyboardFocus(g_owner, g_browser, kControlFocusNextPart);
        }
    }
}

/* The group box's second line: the SELECTED process's window, read
   through the anchor plane, or why it could not be read. Empty when
   there is no anchor plane at all (an M0 extension or none) or nothing
   is selected, so the line simply does not appear. */
static void format_peek_bounds(char *out, long cap)
{
    unsigned long caps = 0;
    NowPeekBounds b;

    out[0] = '\0';
    if (now_peek_status(&caps) != kNowPeekActive
        || (caps & kNowPeekCapAnchors) == 0
        || g_selected < 0 || g_selected >= g_proc_count) {
        return;                       /* no plane, or nothing selected */
    }
    switch (now_peek_window_for_psn(&g_procs[g_selected].psn, &b)) {
    case kNowPeekReadOk:
        snprintf(out, (size_t)cap, "Window: %d x %d at (%d, %d)",
                 b.right - b.left, b.bottom - b.top, b.left, b.top);
        break;
    case kNowPeekReadNoWindows:
        snprintf(out, (size_t)cap, "Window: none open");
        break;
    case kNowPeekReadNoAnchor:
        snprintf(out, (size_t)cap, "Window: no anchor yet");
        break;
    case kNowPeekReadUnreadable:
        snprintf(out, (size_t)cap, "Window: unreadable");
        break;
    default:
        break;                        /* NoPlane: leave empty */
    }
}

static void procs_idle(void)
{
    short want_front;
    short want_quit;
    const ProcEntry *entry = NULL;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    if (TickCount() >= g_next_walk) {
        char bounds[48];

        g_next_walk = TickCount() + kWalkIntervalTicks;
        refresh();
        /* The one foreign read, on the throttled path and only on
           change - so a backgrounded NOW tracks the front app without
           touching foreign memory every event-loop pass. */
        format_peek_bounds(bounds, sizeof bounds);
        if (strcmp(bounds, g_shown_bounds) != 0) {
            Rect line;

            strcpy(g_shown_bounds, bounds);
            line = g_r.peek_line;
            line.bottom = (short)(g_r.peek_line.top + 30);   /* both lines */
            InvalWindowRect(g_owner, &line);
        }
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
    if (want_front != g_front_hilite && g_front != NULL) {
        g_front_hilite = want_front;
        HiliteControl(g_front, want_front);
    }
    if (want_quit != g_quit_hilite && g_quit != NULL) {
        g_quit_hilite = want_quit;
        HiliteControl(g_quit, want_quit);
    }
}

static void procs_status_text(char *out, long cap)
{
    if (g_status[0] != '\0') {
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
