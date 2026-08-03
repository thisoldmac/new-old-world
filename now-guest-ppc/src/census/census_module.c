#include "census_module.h"

#include <stdio.h>
#include <string.h>

#include "census.h"
#include "pump.h"
#include "wire.h"                 /* now_wire_pump, for the divider drag loop */
#include "control_kind.h"

/* The Hardware census page. A hand-drawn probe rail on the left - the
   Workshop sidebar's own two-line idiom, because a probe registry is
   navigation, not a table, and its outcome belongs in a subtitle rather
   than a sortable column. One Data Browser on the right holds the selected
   probe's rows (Fact/Value, Selector/Meaning - the raw column is gone from
   the list), and a drawn detail pane below carries the full reading of the
   selected row: an attr's every set bit, a version's three encodings, an
   Overview fact's provenance.

   Everything is guest-local: probes run on request and are answered by the
   same census core the wire serves. A run is NOT synchronous - it advances
   one page per idle() pass so the cooperatively-scheduled machine keeps
   redrawing, pumping the wire and answering the mouse throughout, instead
   of wedging for the seconds a full sweep (SCSI especially) takes. */

enum {
    kMargin = 12,
    kRailDefaultW = 168,      /* the rail starts here; drag the divider wider */
    kRailMinW = 130,
    kRailMaxW = 360,
    kDivW = 8,                /* the draggable divider strip */
    /* Two-line rail row. 25 fits all fourteen probes at the standard
       window (~371 px of rail for 352 px of rows); below about the minimum
       window the tail clips (draw_rail bounds the rows). The rail genuinely
       needs a vertical scroll bar rather than shorter rows now - the next
       probe (the witness tier) that lands. */
    kRowH = 25,
    kButtonH = 20,
    kDetailH = 132,
    kMaxDetailLines = 12,
    kDetailLineCap = 72,
    kPoolRows = 768,          /* every probe's rows cached here, packed */

    kColName = 'cnam',
    kColValue = 'cval'
};

typedef struct {
    Rect rail;
    Rect divider;             /* between rail and browser; drag to resize */
    Rect browser;
    Rect detail;
    Rect run_btn;
    Rect rerun_btn;
} CensusRects;

static WindowRef g_owner;
static Rect g_body;
static CensusRects g_r;
static Boolean g_visible;
static short g_rail_w = kRailDefaultW;     /* current rail width; user-dragged */

/* Cursor arbitration: watch while a probe runs, the resize cursor over the
   divider, arrow otherwise - set only on change. */
enum { kCurArrow = 0, kCurWatch, kCurResize };
static int g_cursor = kCurArrow;

/* The hand-drawn hover tooltip (HMDisplayTag is Mac OS X only), shown when
   a rail row's text is truncated and the mouse rests on it. */
static int g_hover_row = -1;
static Point g_hover_pt;
static unsigned long g_hover_since;
static Boolean g_tip_shown;
static Rect g_tip_rect;
static char g_tip_text[96];

static void hide_tip(void);     /* used by census_show, defined with the tip */

static ControlRef g_browser;
static ControlRef g_run;
static ControlRef g_rerun;

static int g_probe_count;
static CensusOutcome g_outcome[16];       /* kCensusNotAttempted = unrun */
static char g_subtitle[16][48];           /* rail's quiet line, per probe */
static int g_sel_probe;                   /* selected rail row, or -1 */

/* Every probe's rows are cached in one packed pool, so re-selecting a
   probe after a run shows its results instantly instead of re-scanning
   (which for SCSI would mean another bus scan). Each probe owns a slice
   [start, start+count); a fresh gather appends at the pool's end. */
static CensusRow g_pool[kPoolRows];
static int g_pool_used;
static int g_probe_start[16];
static int g_probe_rows[16];
static int g_sel_row;                     /* selected row within g_sel_probe */

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
    short rail_r = (short)(x0 + g_rail_w);
    short bx = (short)(rail_r + kDivW + 6);
    short detail_top = (short)(col_bottom - kDetailH);

    SetRect(&r->rail, x0, top, rail_r, col_bottom);
    SetRect(&r->divider, rail_r, top, (short)(rail_r + kDivW), col_bottom);
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

/* --- running probes, one page per event-loop pass ----------------------- *
 * The machine is cooperatively scheduled, so gathering every probe in one
 * synchronous loop wedges it for the whole run (SCSI alone selects seven
 * targets, each waiting out its timeout). Instead a run is a state machine
 * that does exactly ONE page in idle() and returns, so between pages the
 * loop redraws the rail, pumps the wire and answers the mouse. Because
 * each page invalidates a rectangle, WaitNextEvent never sleeps mid-run -
 * the redraw paces it. */

static Boolean g_pumping;               /* a gather is in progress */
static Boolean g_sweep;                 /* Run Census (all probes) vs one */
static int g_pump_probe;                /* probe currently being gathered */
static long g_pump_cursor;
static Boolean g_pump_first;            /* capture outcome from first page */

static void rail_row_rect(int i, Rect *out)
{
    SetRect(out, g_r.rail.left, (short)(g_r.rail.top + 2 + i * kRowH),
            g_r.rail.right, (short)(g_r.rail.top + 2 + (i + 1) * kRowH));
}

static void inval_rail_row(int i)
{
    Rect r;

    rail_row_rect(i, &r);
    InvalWindowRect(g_owner, &r);
}

/* The n-th cached row of the selected probe, or NULL. */
static const CensusRow *sel_row_at(int n)
{
    if (g_sel_probe < 0 || n < 0 || n >= g_probe_rows[g_sel_probe]) {
        return NULL;
    }
    return &g_pool[g_probe_start[g_sel_probe] + n];
}

/* Recompute the detail lines for the selected browser row. */
static void refresh_detail(void)
{
    const CensusRow *row = sel_row_at(g_sel_row);

    g_detail_count = 0;
    if (row == NULL) {
        return;
    }
    g_detail_count = now_census_row_detail(
        probe_name(g_sel_probe), row->name, row->raw, (char *)g_detail,
        kMaxDetailLines, kDetailLineCap);
}

/* The watch, so the user knows NOW owns the machine while a probe runs.
   The animated variant cannot spin through a blocking Toolbox call (no
   callback fires inside it), so a static watch is the honest signal;
   re-asserted each page in case an update reset it. */
static void apply_cursor(int want)
{
    static const ThemeCursor themes[] = {
        kThemeArrowCursor, kThemeWatchCursor, kThemeResizeLeftRightCursor
    };

    if (want != g_cursor) {
        g_cursor = want;
        SetThemeCursor(themes[want]);
    }
}

static void set_busy(Boolean busy)
{
    if (busy) {
        apply_cursor(kCurWatch);
    } else {
        apply_cursor(kCurArrow);
    }
}

static void run_button_title(const char *title)
{
    Str255 t;

    if (g_run != NULL) {
        CopyCStringToPascal(title, t);
        SetControlTitle(g_run, t);
    }
}

/* Show a probe's already-cached rows in the browser, no gather. */
static void display_probe(int probe)
{
    DataBrowserItemID ids[kPoolRows];
    int n, i;

    if (g_browser == NULL || probe < 0) {
        return;
    }
    g_sel_probe = probe;
    RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    n = g_probe_rows[probe];
    for (i = 0; i < n; i++) {
        ids[i] = (DataBrowserItemID)(i + 1);
    }
    if (n > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, n, ids,
                            kDataBrowserItemNoProperty);
    }
    g_sel_row = (n > 0) ? 0 : -1;
    refresh_detail();
    InvalWindowRect(g_owner, &g_r.detail);
}

/* Begin gathering `probe`. sweep = keep going through every probe after
   this one (Run Census); otherwise stop when this one is done (a rail
   selection of an un-cached probe, or Rerun). Rows are appended to the
   pool and shown live when the probe is the selected one. */
static void begin_gather(int probe, Boolean sweep)
{
    if (g_browser == NULL || probe < 0) {
        return;
    }
    if (sweep) {
        int i;

        g_pool_used = 0;                /* a full run repacks the pool */
        for (i = 0; i < g_probe_count; i++) {
            g_probe_rows[i] = 0;
        }
    }
    g_pumping = true;
    g_sweep = sweep;
    g_pump_probe = probe;
    g_pump_cursor = 0;
    g_pump_first = true;
    if (probe == g_sel_probe) {
        RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                               kDataBrowserItemNoProperty);
        g_sel_row = -1;
        g_detail_count = 0;
        InvalWindowRect(g_owner, &g_r.detail);
    }
    HiliteControl(g_rerun, 255);        /* no reruns mid-run */
    run_button_title(sweep ? "Stop" : "Run Census");
    set_busy(true);
    inval_rail_row(probe);
}

static void end_gather(const char *status)
{
    g_pumping = false;
    HiliteControl(g_rerun, 0);
    run_button_title("Run Census");
    set_busy(false);
    set_status(status);
}

/* One page of work - called from idle() while a gather is live. */
static void pump_step(void)
{
    CensusPage page;
    const char *probe;
    int processed;
    int i;

    set_busy(true);                     /* re-assert through updates */
    probe = probe_name(g_pump_probe);
    if (now_census_gather(probe, g_pump_cursor, &page) != 0) {
        page.count = 0;
        page.outcome = kCensusRefused;
        page.more = 0;
        snprintf(page.note, sizeof page.note, "unknown probe");
    }
    if (g_pump_first) {                 /* open this probe's pool slice */
        g_outcome[g_pump_probe] = page.outcome;
        g_probe_start[g_pump_probe] = g_pool_used;
        g_probe_rows[g_pump_probe] = 0;
        g_pump_first = false;
    }
    /* Append the page to the pool; live-fill the browser if it is shown. */
    {
        DataBrowserItemID ids[kCensusPageMax];
        int added = 0;

        for (i = 0; i < page.count && g_pool_used < kPoolRows; i++) {
            g_pool[g_pool_used++] = page.rows[i];
            g_probe_rows[g_pump_probe]++;
            if (g_pump_probe == g_sel_probe) {
                ids[added++] = (DataBrowserItemID)g_probe_rows[g_pump_probe];
            }
        }
        if (added > 0) {
            AddDataBrowserItems(g_browser, kDataBrowserNoItem, added, ids,
                                kDataBrowserItemNoProperty);
            if (g_sel_row < 0) {
                g_sel_row = 0;
                refresh_detail();
                InvalWindowRect(g_owner, &g_r.detail);
            }
        }
    }
    /* The rail subtitle animates while pages follow, then settles. */
    if (page.more) {
        snprintf(g_subtitle[g_pump_probe], sizeof g_subtitle[0],
                 "scanning... %d rows", g_probe_rows[g_pump_probe]);
        g_pump_cursor = page.next_cursor;
    } else if (page.note[0] != '\0') {
        snprintf(g_subtitle[g_pump_probe], sizeof g_subtitle[0], "%.44s",
                 page.note);
    } else {
        snprintf(g_subtitle[g_pump_probe], sizeof g_subtitle[0], "%s - %d rows",
                 census_outcome_name(g_outcome[g_pump_probe]),
                 g_probe_rows[g_pump_probe]);
    }

    processed = g_pump_probe;
    if (!page.more) {
        if (g_sweep && g_pump_probe + 1 < g_probe_count) {
            g_pump_probe++;
            g_pump_cursor = 0;
            g_pump_first = true;
        } else if (g_sweep) {
            end_gather("Census complete.");
        } else {
            char done[120];

            snprintf(done, sizeof done, "%s.", g_subtitle[processed]);
            end_gather(done);
        }
    }
    /* Repaint the row we just touched AND the newly-current one, so a
       finished probe stops reading "scanning..." the moment it is done -
       otherwise several rows look busy at once. */
    inval_rail_row(processed);
    if (g_pumping && g_pump_probe != processed) {
        inval_rail_row(g_pump_probe);
    }
    if (g_pumping && g_sweep) {
        char s[80];

        snprintf(s, sizeof s, "Scanning %s...", probe_name(g_pump_probe));
        set_status(s);
    }
}

/* --- the rows browser --------------------------------------------------- */

static OSStatus rows_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    CFStringRef text = NULL;
    int index = (int)item - 1;
    const CensusRow *row = sel_row_at(index);

    (void)browser;
    if (changeValue || row == NULL) {
        return errDataBrowserPropertyNotSupported;
    }
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
    RgnHandle save_clip;
    int i;

    RGBForeColor(&white);
    PaintRect(&g_r.rail);
    RGBForeColor(&black);
    FrameRect(&g_r.rail);

    /* Bound the rows to the rail: with fourteen probes the list is taller
       than a shrunk-down window, and an unclipped row would paint over the
       button strip below. Clipping truncates the tail cleanly - the honest
       stopgap until the rail carries a scroll bar (the witness tier). */
    save_clip = NewRgn();
    if (save_clip != NULL) {
        GetClip(save_clip);
    }
    ClipRect(&g_r.rail);

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
        MoveTo((short)(row.left + 12), (short)(base + 12));
        CopyCStringToPascal(probe_name(i), text);
        text[1] = (unsigned char)(text[1] >= 'a' && text[1] <= 'z'
                                  ? text[1] - 32 : text[1]);   /* Titlecase */
        DrawString(text);

        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        RGBForeColor(&gray);
        MoveTo((short)(row.left + 12), (short)(base + 22));
        if (g_subtitle[i][0] == '\0') {
            CopyCStringToPascal("not run yet", text);
        } else {
            CopyCStringToPascal(g_subtitle[i], text);
            TruncString((short)(row.right - row.left - 16), text, truncEnd);
        }
        DrawString(text);
        RGBForeColor(&black);
    }

    if (save_clip != NULL) {
        SetClip(save_clip);
        DisposeRgn(save_clip);
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
    {
        const CensusRow *sel = sel_row_at(g_sel_row);

        if (sel != NULL) {
            title = sel->name;
            while (*title == ' ') {
                title++;                /* Overview facts are indented */
            }
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
    g_pool_used = 0;
    g_detail_count = 0;
    g_probe_count = now_census_probe_count();
    for (i = 0; i < g_probe_count && i < 16; i++) {
        g_outcome[i] = kCensusNotAttempted;
        g_subtitle[i][0] = '\0';
        g_probe_rows[i] = 0;
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
    g_run = now_control_new(owner, &g_r.run_btn, text, false, 0, 0, 1,
                       pushButProc, 0);
    CopyCStringToPascal("Rerun", text);
    g_rerun = now_control_new(owner, &g_r.rerun_btn, text, false, 0, 0, 1,
                         pushButProc, 0);
    if (g_run == NULL || g_rerun == NULL) {
        return memFullErr;
    }
    HideControl(g_browser);
    return noErr;
}

static void census_dispose(void)
{
    /* Dispose the Data Browser BEFORE its UPPs: workshop_close disposes
       this module ahead of DisposeWindow, so the control is still live,
       and its disposal fires item notifications through these UPPs.
       Freeing them first let DisposeWindow later call a freed transition
       vector - an intermittent system crash on quit. */
    if (g_browser != NULL) {
        DisposeControl(g_browser);
        g_browser = NULL;
    }
    dispose_upps();
    g_owner = NULL;
    g_run = NULL;
    g_rerun = NULL;
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
    if (!visible) {
        hide_tip();
        g_hover_row = -1;
        set_busy(false);                /* don't leave the watch on other pages */
        return;
    }
    /* First arrival: fill Overview so the page is not blank, cheaply and
       non-blocking. Everything else waits for Run Census. */
    if (!g_pumping && g_subtitle[g_sel_probe][0] == '\0') {
        begin_gather(g_sel_probe, false);
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

/* --- the resize divider ------------------------------------------------- */

/* Drag the divider with a ghost line (XOR, so no full redraw per move),
   committing the new rail width on mouse-up. Pumps the wire so a transfer
   keeps moving while the user drags. */
static void track_divider(void)
{
    short min_x = (short)(g_r.rail.left + kRailMinW);
    short max_x = (short)(g_r.rail.left + kRailMaxW);
    short top = g_r.rail.top;
    short bottom = g_r.rail.bottom;
    short last = -1;
    Point pt;
    Pattern gray;

    SetPortWindowPort(g_owner);
    GetQDGlobalsGray(&gray);
    PenMode(patXor);
    PenPat(&gray);
    while (StillDown()) {
        now_wire_pump();
        GetMouse(&pt);
        if (pt.h < min_x) { pt.h = min_x; }
        if (pt.h > max_x) { pt.h = max_x; }
        if (pt.h != last) {
            if (last >= 0) {
                MoveTo(last, top); LineTo(last, bottom);   /* erase old */
            }
            MoveTo(pt.h, top); LineTo(pt.h, bottom);       /* draw new */
            last = pt.h;
        }
    }
    if (last >= 0) {
        MoveTo(last, top); LineTo(last, bottom);           /* erase final */
    }
    PenNormal();
    if (last >= 0) {
        g_rail_w = (short)(last - g_r.rail.left);
        census_layout(&g_body);
        InvalWindowRect(g_owner, &g_body);
    }
}

/* --- the hover tooltip -------------------------------------------------- */

static void hide_tip(void)
{
    if (g_tip_shown) {
        g_tip_shown = false;
        InvalWindowRect(g_owner, &g_tip_rect);
    }
}

/* Is row i's title or subtitle wider than the rail can show? */
static Boolean row_truncated(int i, const char **which)
{
    Str255 t;
    short avail = (short)(g_r.rail.right - g_r.rail.left - 28);

    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    CopyCStringToPascal(probe_name(i), t);
    if (StringWidth(t) > avail) {
        *which = probe_name(i);
        return true;
    }
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    CopyCStringToPascal(g_subtitle[i][0] ? g_subtitle[i] : "not run yet", t);
    if (StringWidth(t) > avail) {
        *which = g_subtitle[i][0] ? g_subtitle[i] : "not run yet";
        return true;
    }
    return false;
}

static void show_tip(int row)
{
    const char *text = NULL;
    Str255 t;
    short w, x, y;

    if (!row_truncated(row, &text) || text == NULL) {
        return;
    }
    snprintf(g_tip_text, sizeof g_tip_text, "%s", text);
    CopyCStringToPascal(g_tip_text, t);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    w = (short)(StringWidth(t) + 12);
    x = (short)(g_r.rail.left + 16);
    y = (short)(g_r.rail.top + 2 + (row + 1) * kRowH);
    if (x + w > g_body.right - 4) {
        x = (short)(g_body.right - 4 - w);
    }
    SetRect(&g_tip_rect, x, y, (short)(x + w), (short)(y + 16));
    g_tip_shown = true;
    InvalWindowRect(g_owner, &g_tip_rect);
}

static void draw_tip(void)
{
    RGBColor tip = { 0xFFFF, 0xFFFF, 0xCCCC };   /* the classic pale tag */
    RGBColor black = { 0, 0, 0 };
    Str255 t;

    RGBForeColor(&tip);
    PaintRect(&g_tip_rect);
    RGBForeColor(&black);
    FrameRect(&g_tip_rect);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo((short)(g_tip_rect.left + 6), (short)(g_tip_rect.top + 12));
    CopyCStringToPascal(g_tip_text, t);
    DrawString(t);
}

/* Called each idle pass: keep the cursor honest and raise a tooltip when
   the mouse rests on a truncated row. */
static void hover_idle(void)
{
    Point pt;
    int row;
    int want;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    GetMouse(&pt);

    /* cursor: watch wins while running, else resize over the divider */
    if (g_pumping) {
        want = kCurWatch;
    } else if (PtInRect(pt, &g_r.divider)) {
        want = kCurResize;
    } else {
        want = kCurArrow;
    }
    apply_cursor(want);

    if (g_pumping) {
        hide_tip();
        return;
    }
    row = rail_row_at(pt);
    if (row != g_hover_row || pt.h < g_hover_pt.h - 2 || pt.h > g_hover_pt.h + 2
        || pt.v < g_hover_pt.v - 2 || pt.v > g_hover_pt.v + 2) {
        hide_tip();
        g_hover_row = row;
        g_hover_pt = pt;
        g_hover_since = TickCount();
    } else if (row >= 0 && !g_tip_shown
               && TickCount() - g_hover_since > 30) {
        show_tip(row);
    }
}

static void census_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    draw_rail();
    {
        /* a native themed separator down the middle of the divider strip */
        Rect sep = g_r.divider;
        sep.left = (short)(sep.left + kDivW / 2);
        sep.right = (short)(sep.left + 2);
        DrawThemeSeparator(&sep, kThemeStateActive);
    }
    draw_detail();
    if (g_tip_shown) {
        draw_tip();                     /* on top of everything */
    }
}

static Boolean census_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    int hit;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (!g_pumping && PtInRect(local, &g_r.divider)) {
        hide_tip();
        track_divider();
        return true;
    }
    hit = rail_row_at(local);
    if (hit >= 0) {
        /* Ignore rail selection mid-run: the gather owns the browser, and
           a probe it has not reached has no rows cached to show. */
        if (hit != g_sel_probe && !g_pumping) {
            int prev = g_sel_probe;

            inval_rail_row(prev);
            inval_rail_row(hit);
            if (g_probe_rows[hit] > 0
                || g_outcome[hit] != kCensusNotAttempted) {
                display_probe(hit);         /* cached - instant, no scan */
            } else {
                g_sel_probe = hit;
                begin_gather(hit, false);   /* never run - scan it */
            }
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
            if (g_pumping && g_sweep) {
                end_gather("Census stopped.");
            } else {
                int i;
                for (i = 0; i < g_probe_count; i++) {
                    g_subtitle[i][0] = '\0';
                    g_outcome[i] = kCensusNotAttempted;
                }
                InvalWindowRect(g_owner, &g_r.rail);
                set_status("Running census...");
                begin_gather(0, true);   /* sweep every probe */
            }
        }
        return true;
    }
    if (control == g_rerun) {
        if (TrackControl(control, local, now_pump_action()) != 0
            && g_sel_probe >= 0 && !g_pumping) {
            begin_gather(g_sel_probe, false);
        }
        return true;
    }
    return false;
}

static Boolean census_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);

    int next;

    /* Up/Down move the probe selection when the browser lacks focus. */
    if (g_sel_probe < 0 || g_probe_count == 0 || g_pumping) {
        return false;                   /* a run owns the selection */
    }
    if (c == 0x1E && g_sel_probe > 0) {                 /* up arrow */
        next = g_sel_probe - 1;
    } else if (c == 0x1F && g_sel_probe < g_probe_count - 1) {  /* down */
        next = g_sel_probe + 1;
    } else {
        return false;
    }
    inval_rail_row(g_sel_probe);
    inval_rail_row(next);
    if (g_probe_rows[next] > 0 || g_outcome[next] != kCensusNotAttempted) {
        display_probe(next);
    } else {
        g_sel_probe = next;
        begin_gather(next, false);
    }
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
    /* A run advances one page per pass, so the loop redraws and pumps the
       wire between pages instead of wedging for the whole census. */
    if (g_pumping && g_owner != NULL && g_visible) {
        pump_step();
    }
    hover_idle();               /* cursor over the divider, and tooltips */
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
