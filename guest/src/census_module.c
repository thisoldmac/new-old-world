#include "census_module.h"

#include <stdio.h>
#include <string.h>

#include "census.h"
#include "pump.h"

/* The Hardware census page. A hand-drawn probe rail on the left - the
   Workshop sidebar's own two-line idiom, because a probe registry is
   navigation, not a table, and its outcome belongs in a subtitle rather
   than a sortable column. One Data Browser on the right holds the selected
   probe's rows (Fact/Value, Selector/Meaning - the raw column is gone from
   the list), and a drawn detail pane below carries the full reading of the
   selected row: an attr's every set bit, a version's three encodings, an
   Overview fact's provenance.

   Everything is guest-local: probes run on a click and are answered by the
   same census core the wire serves. idle() does nothing - a census is a
   click, never a poll. */

enum {
    kMargin = 12,
    kRailW = 168,
    kRowH = 32,               /* two-line rail row, like the sidebar */
    kGap = 14,
    kButtonH = 20,
    kDetailH = 132,
    kMaxDetailLines = 12,
    kDetailLineCap = 72,
    kMaxRows = 320,           /* accumulated rows for one probe */

    kColName = 'cnam',
    kColValue = 'cval'
};

typedef struct {
    Rect rail;
    Rect browser;
    Rect detail;
    Rect run_btn;
    Rect rerun_btn;
} CensusRects;

static WindowRef g_owner;
static Rect g_body;
static CensusRects g_r;
static Boolean g_visible;

static ControlRef g_browser;
static ControlRef g_run;
static ControlRef g_rerun;

static int g_probe_count;
static CensusOutcome g_outcome[16];       /* kCensusNotAttempted = unrun */
static char g_subtitle[16][48];           /* rail's quiet line, per probe */
static int g_sel_probe;                   /* selected rail row, or -1 */

static CensusRow g_rows[kMaxRows];
static int g_row_count;
static int g_sel_row;                     /* selected browser row, or -1 */

static char g_detail[kMaxDetailLines][kDetailLineCap];
static int g_detail_count;
static char g_status[120];

/* --- layout ------------------------------------------------------------- */

static void compute_rects(const Rect *body, CensusRects *r)
{
    short x0 = (short)(body->left + kMargin);
    short top = (short)(body->top + 8);
    short right = (short)(body->right - kMargin);
    short buttons_y = (short)(body->bottom - (kButtonH + 8));
    short col_bottom = (short)(buttons_y - 10);
    short bx = (short)(x0 + kRailW + kGap);
    short detail_top = (short)(col_bottom - kDetailH);

    SetRect(&r->rail, x0, top, (short)(x0 + kRailW), col_bottom);
    SetRect(&r->browser, bx, top, right, (short)(detail_top - 8));
    SetRect(&r->detail, bx, detail_top, right, col_bottom);
    SetRect(&r->run_btn, x0, buttons_y, (short)(x0 + 116),
            (short)(buttons_y + kButtonH));
    SetRect(&r->rerun_btn, (short)(right - 132), buttons_y, right,
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

static const char *probe_name(int i)
{
    return now_census_probe_name(i);
}

/* --- running probes ----------------------------------------------------- */

/* Walk a probe's pages into g_rows; return the settled outcome and a short
   subtitle for the rail. */
static CensusOutcome run_probe(const char *probe, char *subtitle,
                               long sub_cap)
{
    CensusPage page;
    long cursor = 0;
    CensusOutcome outcome = kCensusFailed;
    int first = 1;

    g_row_count = 0;
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
        for (i = 0; i < page.count && g_row_count < kMaxRows; i++) {
            g_rows[g_row_count++] = page.rows[i];
        }
        if (!page.more || g_row_count >= kMaxRows) {
            break;
        }
        cursor = page.next_cursor;
    }
    if (page.note[0] != '\0') {
        snprintf(subtitle, sub_cap, "%s", page.note);
    } else {
        snprintf(subtitle, sub_cap, "%s - %d rows",
                 census_outcome_name(outcome), g_row_count);
    }
    return outcome;
}

/* Recompute the detail lines for the selected browser row. */
static void refresh_detail(void)
{
    g_detail_count = 0;
    if (g_sel_probe < 0 || g_sel_row < 0 || g_sel_row >= g_row_count) {
        return;
    }
    g_detail_count = now_census_row_detail(
        probe_name(g_sel_probe), g_rows[g_sel_row].name,
        g_rows[g_sel_row].raw, (char *)g_detail, kMaxDetailLines,
        kDetailLineCap);
}

/* Load the selected probe's rows into the browser (running it fresh). */
static void load_selected_probe(void)
{
    DataBrowserItemID ids[kMaxRows];
    int i;

    if (g_browser == NULL || g_sel_probe < 0) {
        return;
    }
    RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    g_row_count = 0;
    g_sel_row = -1;
    if (g_outcome[g_sel_probe] == kCensusNotAttempted) {
        refresh_detail();
        InvalWindowRect(g_owner, &g_r.detail);
        return;
    }
    g_outcome[g_sel_probe] = run_probe(probe_name(g_sel_probe),
                                       g_subtitle[g_sel_probe],
                                       sizeof g_subtitle[0]);
    for (i = 0; i < g_row_count; i++) {
        ids[i] = (DataBrowserItemID)(i + 1);
    }
    if (g_row_count > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, g_row_count, ids,
                            kDataBrowserItemNoProperty);
        g_sel_row = 0;
    }
    refresh_detail();
    InvalWindowRect(g_owner, &g_r.detail);
}

static void run_all(void)
{
    int i;

    for (i = 0; i < g_probe_count; i++) {
        g_outcome[i] = run_probe(probe_name(i), g_subtitle[i],
                                 sizeof g_subtitle[0]);
    }
    InvalWindowRect(g_owner, &g_r.rail);
    load_selected_probe();
    set_status("Census complete.");
}

/* --- the rows browser --------------------------------------------------- */

static OSStatus rows_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    CFStringRef text = NULL;
    int index = (int)item - 1;
    const CensusRow *row;

    (void)browser;
    if (changeValue || index < 0 || index >= g_row_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_rows[index];
    switch (property) {
    case kColName:
        text = CFStringCreateWithCString(NULL, row->name,
                                         kCFStringEncodingMacRoman);
        break;
    case kColValue:
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

static void rows_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    (void)browser;
    (void)item;
    if (message == kDataBrowserSelectionSetChanged) {
        Handle sel = NewHandle(0);

        if (sel != NULL) {
            if (GetDataBrowserItems(g_browser, kDataBrowserNoItem, false,
                                    kDataBrowserItemIsSelected, sel) == noErr
                && GetHandleSize(sel) >= (Size)sizeof(DataBrowserItemID)) {
                DataBrowserItemID first;

                memcpy(&first, *sel, sizeof first);
                g_sel_row = (int)first - 1;
                refresh_detail();
                InvalWindowRect(g_owner, &g_r.detail);
            }
            DisposeHandle(sel);
        }
    }
}

static DataBrowserItemDataUPP g_data_upp;
static DataBrowserItemNotificationUPP g_notify_upp;

static void dispose_upps(void)
{
    if (g_data_upp != NULL) {
        DisposeDataBrowserItemDataUPP(g_data_upp);
        g_data_upp = NULL;
    }
    if (g_notify_upp != NULL) {
        DisposeDataBrowserItemNotificationUPP(g_notify_upp);
        g_notify_upp = NULL;
    }
}

static void add_column(DataBrowserPropertyID id, const char *title,
                       UInt16 width, Boolean isName,
                       DataBrowserTableViewColumnIndex at)
{
    DataBrowserListViewColumnDesc col;

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
    if (AddDataBrowserListViewColumn(g_browser, &col, at) == noErr) {
        SetDataBrowserTableViewNamedColumnWidth(g_browser, id, width);
    }
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
}

/* Columns are added once and kept: removing and re-adding them (to retitle
   per probe) leaves the list unable to display its items - the bug the v2
   layout shipped with. A single neutral Field/Value pair reads correctly
   for every probe; the caption rows and the header placard say which probe
   is showing. */

/* --- the drawn probe rail ----------------------------------------------- */

static int rail_row_at(Point local)
{
    int i;

    for (i = 0; i < g_probe_count; i++) {
        Rect row;

        SetRect(&row, g_r.rail.left, (short)(g_r.rail.top + 2 + i * kRowH),
                g_r.rail.right, (short)(g_r.rail.top + 2 + (i + 1) * kRowH));
        if (PtInRect(local, &row)) {
            return i;
        }
    }
    return -1;
}

static void draw_rail(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor gray = { 0x5555, 0x5555, 0x5555 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    int i;

    RGBForeColor(&white);
    PaintRect(&g_r.rail);
    RGBForeColor(&black);
    FrameRect(&g_r.rail);

    for (i = 0; i < g_probe_count; i++) {
        Rect row;
        Str255 text;
        short base = (short)(g_r.rail.top + 2 + i * kRowH);

        SetRect(&row, (short)(g_r.rail.left + 1), base,
                (short)(g_r.rail.right - 1), (short)(base + kRowH));
        if (i == g_sel_probe) {
            RGBColor band;
            LMGetHiliteRGB(&band);      /* the system list-highlight color */
            RGBForeColor(&band);
            PaintRect(&row);
            RGBForeColor(&black);
        }
        UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
        MoveTo((short)(row.left + 12), (short)(base + 14));
        CopyCStringToPascal(probe_name(i), text);
        text[1] = (unsigned char)(text[1] >= 'a' && text[1] <= 'z'
                                  ? text[1] - 32 : text[1]);   /* Titlecase */
        DrawString(text);

        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        RGBForeColor(&gray);
        MoveTo((short)(row.left + 12), (short)(base + 27));
        if (g_outcome[i] == kCensusNotAttempted) {
            CopyCStringToPascal("not run yet", text);
        } else {
            CopyCStringToPascal(g_subtitle[i], text);
            TruncString((short)(row.right - row.left - 16), text, truncEnd);
        }
        DrawString(text);
        RGBForeColor(&black);
    }
}

/* --- the drawn detail pane ---------------------------------------------- */

static void draw_detail(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor gray = { 0x5555, 0x5555, 0x5555 };
    Str255 text;
    const char *title = "Detail";
    int i;
    short y;

    /* etched group box */
    {
        RGBColor light = { 0x8888, 0x8888, 0x8888 };
        Rect box = g_r.detail;
        box.top = (short)(box.top + 5);
        RGBForeColor(&light);
        FrameRect(&box);
        RGBForeColor(&black);
    }
    if (g_sel_probe >= 0 && g_sel_row >= 0 && g_sel_row < g_row_count) {
        title = g_rows[g_sel_row].name;
        while (*title == ' ') {
            title++;                    /* Overview facts are indented */
        }
    }
    /* title breaks the top rule */
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    {
        RGBColor bg;
        Rect cap;
        short w;

        CopyCStringToPascal(title, text);
        w = StringWidth(text);
        SetRect(&cap, (short)(g_r.detail.left + 10), g_r.detail.top,
                (short)(g_r.detail.left + 16 + w), (short)(g_r.detail.top + 12));
        GetThemeBrushAsColor(kThemeBrushDialogBackgroundActive, 32, true, &bg);
        RGBForeColor(&bg);
        PaintRect(&cap);
        RGBForeColor(&black);
        MoveTo((short)(g_r.detail.left + 16), (short)(g_r.detail.top + 10));
        DrawString(text);
    }

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    y = (short)(g_r.detail.top + 30);
    for (i = 0; i < g_detail_count; i++) {
        /* a blank line spaces the block, a summary line goes gray */
        if (g_detail[i][0] == '\0') {
            y = (short)(y + 8);
            continue;
        }
        if (strstr(g_detail[i], "clear -") != NULL
            || strstr(g_detail[i], "candidates") != NULL
            || strstr(g_detail[i], "source") != NULL) {
            RGBForeColor(&gray);
        }
        MoveTo((short)(g_r.detail.left + 16), y);
        CopyCStringToPascal(g_detail[i], text);
        TruncString((short)(g_r.detail.right - g_r.detail.left - 26), text,
                    truncEnd);
        DrawString(text);
        RGBForeColor(&black);
        y = (short)(y + 14);
    }
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
    g_sel_probe = 0;
    g_sel_row = -1;
    g_row_count = 0;
    g_detail_count = 0;
    g_probe_count = now_census_probe_count();
    for (i = 0; i < g_probe_count && i < 16; i++) {
        g_outcome[i] = kCensusNotAttempted;
        g_subtitle[i][0] = '\0';
    }
    compute_rects(body, &g_r);

    if (CreateDataBrowserControl(owner, &g_r.browser, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;
        return memFullErr;
    }
    g_data_upp = NewDataBrowserItemDataUPP(rows_data);
    g_notify_upp = NewDataBrowserItemNotificationUPP(rows_notify);
    if (g_data_upp == NULL || g_notify_upp == NULL) {
        dispose_upps();
        return memFullErr;
    }
    memset(&cb, 0, sizeof cb);
    cb.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&cb);
    cb.u.v1.itemDataCallback = g_data_upp;
    cb.u.v1.itemNotificationCallback = g_notify_upp;
    SetDataBrowserCallbacks(g_browser, &cb);
    add_column(kColName, "Field", 150, true, 0);
    add_column(kColValue, "Value", 200, false, 1);
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);

    CopyCStringToPascal("Run Census", text);
    g_run = NewControl(owner, &g_r.run_btn, text, false, 0, 0, 1,
                       pushButProc, 0);
    CopyCStringToPascal("Rerun", text);
    g_rerun = NewControl(owner, &g_r.rerun_btn, text, false, 0, 0, 1,
                         pushButProc, 0);
    if (g_run == NULL || g_rerun == NULL) {
        return memFullErr;
    }
    HideControl(g_browser);
    return noErr;
}

static void census_dispose(void)
{
    g_owner = NULL;
    g_browser = NULL;
    g_run = NULL;
    g_rerun = NULL;
    dispose_upps();
}

static void census_show(Boolean visible)
{
    g_visible = visible;
    if (g_browser != NULL) {
        if (visible) { ShowControl(g_browser); } else { HideControl(g_browser); }
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
    size_to(g_browser, &g_r.browser);
    size_to(g_run, &g_r.run_btn);
    size_to(g_rerun, &g_r.rerun_btn);
}

static void census_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    draw_rail();
    draw_detail();
}

static Boolean census_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    int hit;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    hit = rail_row_at(local);
    if (hit >= 0) {
        if (hit != g_sel_probe) {
            int prev = g_sel_probe;
            g_sel_probe = hit;
            {
                Rect a, b;
                SetRect(&a, g_r.rail.left,
                        (short)(g_r.rail.top + 2 + prev * kRowH),
                        g_r.rail.right,
                        (short)(g_r.rail.top + 2 + (prev + 1) * kRowH));
                SetRect(&b, g_r.rail.left,
                        (short)(g_r.rail.top + 2 + hit * kRowH),
                        g_r.rail.right,
                        (short)(g_r.rail.top + 2 + (hit + 1) * kRowH));
                InvalWindowRect(g_owner, &a);
                InvalWindowRect(g_owner, &b);
            }
            load_selected_probe();
        }
        return true;
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    if (control == g_browser) {
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
        if (TrackControl(control, local, now_pump_action()) != 0
            && g_sel_probe >= 0) {
            g_outcome[g_sel_probe] = kCensusNotAttempted;
            load_selected_probe();
            InvalWindowRect(g_owner, &g_r.rail);
        }
        return true;
    }
    return false;
}

static Boolean census_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);

    /* Up/Down move the probe selection when the browser lacks focus. */
    if (g_sel_probe < 0 || g_probe_count == 0) {
        return false;
    }
    if (c == 0x1E && g_sel_probe > 0) {                 /* up arrow */
        g_sel_probe--;
    } else if (c == 0x1F && g_sel_probe < g_probe_count - 1) {  /* down */
        g_sel_probe++;
    } else {
        return false;
    }
    InvalWindowRect(g_owner, &g_r.rail);
    load_selected_probe();
    return true;
}

static void census_activate(Boolean active)
{
    ControlRef controls[3];
    int i;

    controls[0] = g_browser;
    controls[1] = g_run;
    controls[2] = g_rerun;
    for (i = 0; i < 3; i++) {
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
    /* A census is a click, never a poll. */
}

static void census_status_text(char *out, long cap)
{
    if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_status);
    } else {
        snprintf(out, (size_t)cap,
                 "Passive census - probes run on request. Nothing is a guess.");
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
    return &k_ops;
}
