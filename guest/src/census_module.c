#include "census_module.h"

#include <stdio.h>
#include <string.h>

#include "census.h"
#include "pump.h"

/* The Hardware census page. Split pane: the probe registry on the left with
   each probe's outcome, the selected probe's rows on the right. Two flat
   Data Browsers (the Files page proves one on this CarbonLib; two side by
   side is the same control, and stays until metal-verified). Probes run on
   a click - Run Census sweeps all, Rerun re-runs the selected one - and are
   answered by the same census core the wire serves (one data layer, two
   callers), so the page needs no connection to report this Mac.

   Everything here is guest-local: now_census_gather fills a bounded page,
   and Run walks the cursor to accumulate a probe's rows. idle() does
   nothing but keep the status placard honest; there is no per-pass work. */

enum {
    kMargin = 12,
    kListW = 188,             /* the probe list is fixed-width */
    kGap = 12,
    kButtonH = 20,
    kMaxDetail = 300,         /* accumulated rows for one probe */

    kColProbe = 'prob',
    kColOutcome = 'outc',
    kColName = 'name',
    kColRaw = 'raw ',
    kColMeaning = 'mean'
};

typedef struct {
    Rect list;                /* probe list browser */
    Rect detail;              /* selected-probe rows browser */
    Rect run_btn;
    Rect rerun_btn;
} CensusRects;

/* Per-probe column titles, matching the contract's x-census columns. */
typedef struct {
    const char *name;
    const char *col0;         /* the probe's first column title */
} ProbeCols;

static const ProbeCols k_cols[] = {
    { "gestalt", "Selector" },
    { "video",   "Field" },
    { "volumes", "Volume" },
};

static WindowRef g_owner;
static Rect g_body;
static CensusRects g_r;
static Boolean g_visible;

static ControlRef g_list;
static ControlRef g_detail;
static ControlRef g_run;
static ControlRef g_rerun;

static int g_probe_count;
static CensusOutcome g_outcome[16];   /* per probe; kCensusNotAttempted = unrun */
static char g_note[16][kCensusNoteCap];
static int g_selected;                /* selected probe index, or -1 */

static CensusRow g_detail_rows[kMaxDetail];
static int g_detail_count;
static char g_status[120];

/* --- layout ------------------------------------------------------------- */

static void compute_rects(const Rect *body, CensusRects *r)
{
    short x0 = (short)(body->left + kMargin);
    short top = (short)(body->top + 8);
    short right = (short)(body->right - kMargin);
    short buttons_y = (short)(body->bottom - (kButtonH + 8));
    short list_bottom = (short)(buttons_y - 10);
    short detail_left = (short)(x0 + kListW + kGap);

    SetRect(&r->list, x0, top, (short)(x0 + kListW), list_bottom);
    SetRect(&r->detail, detail_left, top, right, list_bottom);
    SetRect(&r->run_btn, x0, buttons_y, (short)(x0 + 116),
            (short)(buttons_y + kButtonH));
    SetRect(&r->rerun_btn, (short)(right - 128), buttons_y, right,
            (short)(buttons_y + kButtonH));
}

static void set_status(const char *text)
{
    snprintf(g_status, sizeof g_status, "%s", text);
    if (g_owner != NULL) {
        Rect content;

        GetWindowPortBounds(g_owner, &content);
        content.top = (short)(content.bottom - 23);
        InvalWindowRect(g_owner, &content);
    }
}

/* --- running probes (guest-local) --------------------------------------- */

static const char *probe_name(int index)
{
    return now_census_probe_name(index);
}

static const char *outcome_word(CensusOutcome o)
{
    return census_outcome_name(o);
}

/* Walk one probe's pages into g_detail_rows; returns the settled outcome. */
static CensusOutcome run_probe_into(const char *probe, CensusRow *rows,
                                    int cap, int *out_count)
{
    CensusPage page;
    long cursor = 0;
    int total = 0;
    CensusOutcome outcome = kCensusFailed;
    int first = 1;

    for (;;) {
        int i;

        if (now_census_gather(probe, cursor, &page) != 0) {
            outcome = kCensusRefused;
            break;
        }
        if (first) {
            outcome = page.outcome;
            first = 0;
        }
        for (i = 0; i < page.count && total < cap; i++) {
            rows[total++] = page.rows[i];
        }
        if (!page.more || total >= cap) {
            break;
        }
        cursor = page.next_cursor;
    }
    *out_count = total;
    return outcome;
}

static void refill_detail(void)
{
    if (g_detail == NULL) {
        return;
    }
    RemoveDataBrowserItems(g_detail, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    g_detail_count = 0;
    if (g_selected < 0 || g_outcome[g_selected] == kCensusNotAttempted) {
        return;                       /* nothing run for this probe yet */
    }
    {
        const char *probe = probe_name(g_selected);
        CensusOutcome o;
        DataBrowserItemID ids[kMaxDetail];
        int i;

        o = run_probe_into(probe, g_detail_rows, kMaxDetail, &g_detail_count);
        g_outcome[g_selected] = o;
        for (i = 0; i < g_detail_count; i++) {
            ids[i] = (DataBrowserItemID)(i + 1);
        }
        if (g_detail_count > 0) {
            AddDataBrowserItems(g_detail, kDataBrowserNoItem, g_detail_count,
                                ids, kDataBrowserItemNoProperty);
        }
    }
}

static void run_one(int index)
{
    const char *probe = probe_name(index);
    char note[kCensusNoteCap];
    int count = 0;
    CensusOutcome o;
    CensusPage page;

    /* First page carries the note; the full walk settles the outcome. */
    now_census_gather(probe, 0, &page);
    strncpy(note, page.note, sizeof note - 1);
    note[sizeof note - 1] = '\0';
    o = run_probe_into(probe, g_detail_rows, kMaxDetail, &count);
    g_outcome[index] = o;
    strncpy(g_note[index], note, sizeof g_note[index] - 1);
    g_note[index][sizeof g_note[index] - 1] = '\0';
    /* Repaint the outcome cell. */
    if (g_list != NULL) {
        UpdateDataBrowserItems(g_list, kDataBrowserNoItem, 0, NULL,
                               kDataBrowserItemNoProperty, kColOutcome);
    }
}

static void run_all(void)
{
    int i;

    for (i = 0; i < g_probe_count; i++) {
        run_one(i);
    }
    refill_detail();
    set_status("Census complete.");
}

static void status_for_selection(void)
{
    if (g_selected < 0) {
        set_status("Select a probe, or Run Census.");
        return;
    }
    if (g_outcome[g_selected] == kCensusNotAttempted) {
        set_status("Not run yet - Run Census, or Rerun.");
        return;
    }
    {
        char line[120];
        const char *note = g_note[g_selected];

        if (note[0] != '\0') {
            snprintf(line, sizeof line, "%s: %s.",
                     outcome_word(g_outcome[g_selected]), note);
        } else {
            snprintf(line, sizeof line, "%s - %d rows.",
                     outcome_word(g_outcome[g_selected]), g_detail_count);
        }
        set_status(line);
    }
}

/* --- the two browsers --------------------------------------------------- */

static OSStatus list_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    CFStringRef text = NULL;
    int index = (int)item - 1;

    (void)browser;
    if (changeValue || index < 0 || index >= g_probe_count) {
        return errDataBrowserPropertyNotSupported;
    }
    switch (property) {
    case kColProbe:
        text = CFStringCreateWithCString(NULL, probe_name(index),
                                         kCFStringEncodingMacRoman);
        break;
    case kColOutcome:
        if (g_outcome[index] == kCensusNotAttempted) {
            text = CFStringCreateWithCString(NULL, "-",
                                             kCFStringEncodingMacRoman);
        } else {
            text = CFStringCreateWithCString(NULL,
                                             outcome_word(g_outcome[index]),
                                             kCFStringEncodingMacRoman);
        }
        break;
    default:
        return errDataBrowserPropertyNotSupported;
    }
    if (text == NULL) {
        return memFullErr;
    }
    SetDataBrowserItemDataText(data, text);
    CFRelease(text);
    return noErr;
}

static void list_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    (void)browser;
    (void)item;
    if (message == kDataBrowserSelectionSetChanged) {
        Handle sel = NewHandle(0);

        if (sel != NULL) {
            if (GetDataBrowserItems(g_list, kDataBrowserNoItem, false,
                                    kDataBrowserItemIsSelected, sel) == noErr
                && GetHandleSize(sel) >= (Size)sizeof(DataBrowserItemID)) {
                DataBrowserItemID first;

                memcpy(&first, *sel, sizeof first);
                g_selected = (int)first - 1;
                refill_detail();
                status_for_selection();
            }
            DisposeHandle(sel);
        }
    }
}

static OSStatus detail_data(ControlRef browser, DataBrowserItemID item,
                            DataBrowserPropertyID property,
                            DataBrowserItemDataRef data, Boolean changeValue)
{
    const CensusRow *row;
    CFStringRef text = NULL;
    int index = (int)item - 1;

    (void)browser;
    if (changeValue || index < 0 || index >= g_detail_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_detail_rows[index];
    switch (property) {
    case kColName:
        text = CFStringCreateWithCString(NULL, row->name,
                                         kCFStringEncodingMacRoman);
        break;
    case kColRaw:
        text = CFStringCreateWithCString(NULL, row->raw,
                                         kCFStringEncodingMacRoman);
        break;
    case kColMeaning:
        text = CFStringCreateWithCString(NULL, row->meaning,
                                         kCFStringEncodingMacRoman);
        break;
    default:
        return errDataBrowserPropertyNotSupported;
    }
    if (text == NULL) {
        return memFullErr;
    }
    SetDataBrowserItemDataText(data, text);
    CFRelease(text);
    return noErr;
}

static void detail_notify(ControlRef browser, DataBrowserItemID item,
                          DataBrowserItemNotification message)
{
    (void)browser;
    (void)item;
    (void)message;
}

/* Real UPPs, held for the controls' lifetime (a UPP is a routine
   descriptor here, not a cast pointer: carbon-upp-is-not-a-cast-on-cfm). */
static DataBrowserItemDataUPP g_list_data_upp;
static DataBrowserItemNotificationUPP g_list_notify_upp;
static DataBrowserItemDataUPP g_detail_data_upp;
static DataBrowserItemNotificationUPP g_detail_notify_upp;

static void dispose_upps(void)
{
    if (g_list_data_upp != NULL) {
        DisposeDataBrowserItemDataUPP(g_list_data_upp);
        g_list_data_upp = NULL;
    }
    if (g_list_notify_upp != NULL) {
        DisposeDataBrowserItemNotificationUPP(g_list_notify_upp);
        g_list_notify_upp = NULL;
    }
    if (g_detail_data_upp != NULL) {
        DisposeDataBrowserItemDataUPP(g_detail_data_upp);
        g_detail_data_upp = NULL;
    }
    if (g_detail_notify_upp != NULL) {
        DisposeDataBrowserItemNotificationUPP(g_detail_notify_upp);
        g_detail_notify_upp = NULL;
    }
}

static OSStatus add_column(ControlRef browser, DataBrowserPropertyID id,
                           const char *title, UInt16 width, Boolean isName,
                           DataBrowserTableViewColumnIndex at)
{
    DataBrowserListViewColumnDesc col;
    OSStatus err;

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = id;
    col.propertyDesc.propertyType = kDataBrowserTextType;
    col.propertyDesc.propertyFlags =
        isName ? kDataBrowserListViewSelectionColumn : 0;
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = 40;
    col.headerBtnDesc.maximumWidth = 500;
    col.headerBtnDesc.titleOffset = 0;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnFontStyle.flags = 0;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, title, kCFStringEncodingMacRoman);
    err = AddDataBrowserListViewColumn(browser, &col, at);
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    if (err == noErr) {
        SetDataBrowserTableViewNamedColumnWidth(browser, id, width);
    }
    return err;
}

/* --- module ops --------------------------------------------------------- */

static OSErr census_create(WindowRef owner, const Rect *body)
{
    DataBrowserCallbacks cb;
    Str255 text;
    int i;

    g_owner = owner;
    g_body = *body;
    g_status[0] = '\0';
    g_selected = -1;
    g_detail_count = 0;
    g_probe_count = now_census_probe_count();
    for (i = 0; i < g_probe_count && i < 16; i++) {
        g_outcome[i] = kCensusNotAttempted;
        g_note[i][0] = '\0';
    }
    compute_rects(body, &g_r);

    if (CreateDataBrowserControl(owner, &g_r.list, kDataBrowserListView,
                                 &g_list) != noErr) {
        g_list = NULL;
        return memFullErr;
    }
    if (CreateDataBrowserControl(owner, &g_r.detail, kDataBrowserListView,
                                 &g_detail) != noErr) {
        g_detail = NULL;
        return memFullErr;
    }
    g_list_data_upp = NewDataBrowserItemDataUPP(list_data);
    g_list_notify_upp = NewDataBrowserItemNotificationUPP(list_notify);
    g_detail_data_upp = NewDataBrowserItemDataUPP(detail_data);
    g_detail_notify_upp = NewDataBrowserItemNotificationUPP(detail_notify);
    if (g_list_data_upp == NULL || g_list_notify_upp == NULL
        || g_detail_data_upp == NULL || g_detail_notify_upp == NULL) {
        dispose_upps();
        return memFullErr;
    }

    memset(&cb, 0, sizeof cb);
    cb.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&cb);
    cb.u.v1.itemDataCallback = g_list_data_upp;
    cb.u.v1.itemNotificationCallback = g_list_notify_upp;
    SetDataBrowserCallbacks(g_list, &cb);
    memset(&cb, 0, sizeof cb);
    cb.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&cb);
    cb.u.v1.itemDataCallback = g_detail_data_upp;
    cb.u.v1.itemNotificationCallback = g_detail_notify_upp;
    SetDataBrowserCallbacks(g_detail, &cb);

    add_column(g_list, kColProbe, "Probe", 100, true, 0);
    add_column(g_list, kColOutcome, "Outcome", 80, false, 1);
    SetDataBrowserListViewHeaderBtnHeight(g_list, 16);
    SetDataBrowserHasScrollBars(g_list, false, true);

    add_column(g_detail, kColName, "Field", 130, true, 0);
    add_column(g_detail, kColRaw, "Raw", 96, false, 1);
    add_column(g_detail, kColMeaning, "Meaning", 220, false, 2);
    SetDataBrowserListViewHeaderBtnHeight(g_detail, 16);
    SetDataBrowserHasScrollBars(g_detail, false, true);

    /* Populate the probe list once; outcomes fill in as probes run. */
    {
        DataBrowserItemID ids[16];

        for (i = 0; i < g_probe_count && i < 16; i++) {
            ids[i] = (DataBrowserItemID)(i + 1);
        }
        AddDataBrowserItems(g_list, kDataBrowserNoItem, g_probe_count, ids,
                            kDataBrowserItemNoProperty);
    }

    CopyCStringToPascal("Run Census", text);
    g_run = NewControl(owner, &g_r.run_btn, text, false, 0, 0, 1,
                       pushButProc, 0);
    CopyCStringToPascal("Rerun", text);
    g_rerun = NewControl(owner, &g_r.rerun_btn, text, false, 0, 0, 1,
                         pushButProc, 0);
    if (g_run == NULL || g_rerun == NULL) {
        return memFullErr;
    }
    HideControl(g_list);
    HideControl(g_detail);
    return noErr;
}

static void census_dispose(void)
{
    g_owner = NULL;
    g_list = NULL;
    g_detail = NULL;
    g_run = NULL;
    g_rerun = NULL;
    dispose_upps();
}

static void census_show(Boolean visible)
{
    g_visible = visible;
    if (g_list != NULL) {
        if (visible) { ShowControl(g_list); } else { HideControl(g_list); }
    }
    if (g_detail != NULL) {
        if (visible) { ShowControl(g_detail); } else { HideControl(g_detail); }
    }
    if (g_run != NULL) {
        if (visible) { ShowControl(g_run); } else { HideControl(g_run); }
    }
    if (g_rerun != NULL) {
        if (visible) { ShowControl(g_rerun); } else { HideControl(g_rerun); }
    }
}

static void size_to(ControlRef c, const Rect *r)
{
    if (c == NULL) {
        return;
    }
    MoveControl(c, r->left, r->top);
    SizeControl(c, (SInt16)(r->right - r->left),
                (SInt16)(r->bottom - r->top));
}

static void census_layout(const Rect *body)
{
    g_body = *body;
    compute_rects(body, &g_r);
    size_to(g_list, &g_r.list);
    size_to(g_detail, &g_r.detail);
    size_to(g_run, &g_r.run_btn);
    size_to(g_rerun, &g_r.rerun_btn);
}

static void census_draw(void)
{
    /* Browsers and buttons draw themselves; the page has no custom art. */
}

static Boolean census_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    if (control == g_list || control == g_detail) {
        HandleControlClick(control, local, event->modifiers, NULL);
        return true;
    }
    if (control == g_run) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            set_status("Running census...");
            run_all();
        }
        return true;
    }
    if (control == g_rerun) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            if (g_selected < 0) {
                set_status("Select a probe to rerun.");
            } else {
                run_one(g_selected);
                refill_detail();
                status_for_selection();
            }
        }
        return true;
    }
    return false;
}

static Boolean census_key(const EventRecord *event)
{
    (void)event;
    return false;
}

static void census_activate(Boolean active)
{
    ControlRef controls[4];
    int i;

    controls[0] = g_list;
    controls[1] = g_detail;
    controls[2] = g_run;
    controls[3] = g_rerun;
    for (i = 0; i < 4; i++) {
        if (controls[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(controls[i]);
        } else {
            DeactivateControl(controls[i]);
        }
    }
}

static void census_idle(void)
{
    /* Probes never run here - a census is a click, not a poll. */
}

static void census_status_text(char *out, long cap)
{
    if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_status);
    } else {
        snprintf(out, (size_t)cap, "Passive census - probes run on request.");
    }
}

static const WorkshopModuleOps k_ops = {
    census_create,
    census_dispose,
    census_show,
    census_layout,
    census_draw,
    census_click,
    census_key,
    census_activate,
    census_idle,
    census_status_text
};

const WorkshopModuleOps *census_module_ops(void)
{
    (void)k_cols;              /* per-probe column titles: slice-2 refinement */
    return &k_ops;
}
