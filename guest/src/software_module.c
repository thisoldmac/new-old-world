#include "software_module.h"

#include <stdio.h>
#include <string.h>

#include "software.h"
#include "software_layout.h"
#include "pump.h"

/* Rung 3, the Data Browser cut - rebuilt from the first metal round.
   What that round taught:

   - The list is a real Data Browser now (the processes_module pattern,
     metal-verified on CarbonLib 1.6), not hand-drawn rows: the page
     draws Platinum instead of System 6, and rows append and update
     natively - AddDataBrowserItems for arrivals, UpdateDataBrowserItems
     for one version cell - so the load no longer repaints the whole
     list per item. The flashing WAS the invalidation model.
   - Each domain's items persist in memory for the whole run; switching
     domains rebuilds the browser from the cache instead of rescanning.
     Rescan (or relaunch) is what re-reads the disk.
   - The module never touches the port's background color. That leak
     repainted every page white on the PowerBook.

   Search stays a hand-drawn field driven from key() - this WaitNextEvent
   app cannot host an inline edit-text control (the Connection-dialog
   reason) - but it accepts the click now and shows focus, so it reads
   as a field and not as a dead rectangle. */

#define SW_4CC(a, b, c, d)                                            \
    (((unsigned long)(a) << 24) | ((unsigned long)(b) << 16)          \
     | ((unsigned long)(c) << 8) | (unsigned long)(d))

enum {
    kColName    = SW_4CC('S', 'w', 'N', 'a'),
    kColVersion = SW_4CC('S', 'w', 'V', 'e'),
    kColSize    = SW_4CC('S', 'w', 'S', 'i'),
    kColState   = SW_4CC('S', 'w', 'S', 't')
};

enum {
    kSwDomainMenuID = 134,
    kSwDetailIcon = 32,
    kTypeAppl = SW_4CC('A', 'P', 'P', 'L')
};

static const struct {
    const char *key;
    const char *label;
    int cap;
} k_domains_ui[] = {
    { "apps", "Applications", 512 },
    { "extensions", "Extensions", 320 },
    { "cdevs", "Control Panels", 96 },
    { "startup", "Startup Items", 48 },
    { "apple", "Apple Menu Items", 96 }
};
enum { kSwDomainCount = 5, kSwMaxCap = 512 };

/* One domain's inventory, kept for the whole run. The sweep state is
   live only for apps and is resumable, so switching away mid-sweep
   pauses it and coming back continues it. */
typedef struct {
    SwPageItem *items;        /* NewPtr'd on first visit */
    int count;
    Boolean loaded;
    Boolean truncated;
    Boolean sweeping;
    SweepState sweep;
    int trickle;              /* next item index to version */
    int off_count;            /* cached for the status placard */
    int sel;                  /* item index, -1 = none */
} DomainState;

static WindowRef g_owner;
static Rect g_body;
static SoftwareLayout g_lay;
static Boolean g_visible;
static int g_domain;
static DomainState g_dom[kSwDomainCount];
static char g_search[48];
static Boolean g_search_focus;

static ControlRef g_popup;
static ControlRef g_browser;
static ControlRef g_detail_box;
static ControlRef g_launch;
static ControlRef g_rescan;
static Boolean g_browser_ok;
static short g_launch_hilite = -1;    /* idle-cache: re-hilite on change */

static DataBrowserItemDataUPP g_data_upp;
static DataBrowserItemNotificationUPP g_notify_upp;
static DataBrowserItemCompareUPP g_compare_upp;
/* Set while rebuilding the browser: RemoveDataBrowserItems fires a
   deselect for the selected row, whose notification would otherwise
   clobber the domain's selection mid-rebuild. */
static Boolean g_in_rebuild;

static DomainState *dom(void)
{
    return &g_dom[g_domain];
}

/* --- filtering ----------------------------------------------------------- */

static Boolean name_matches(const SwPageItem *it, const char *needle)
{
    char cname[64];
    long n = it->name[0] < 63 ? it->name[0] : 63;
    long qn = (long)strlen(needle);
    long i;

    if (qn == 0) {
        return true;
    }
    memcpy(cname, it->name + 1, (size_t)n);
    cname[n] = '\0';
    for (i = 0; i <= n - qn; ++i) {
        long j;

        for (j = 0; j < qn; ++j) {
            char a = cname[i + j], b = needle[j];

            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) {
                break;
            }
        }
        if (j == qn) {
            return true;
        }
    }
    return false;
}

static void lower_needle(char *out, long cap)
{
    long i;

    for (i = 0; g_search[i] != '\0' && i < cap - 1; ++i) {
        char c = g_search[i];

        out[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    out[i] = '\0';
}

/* How many rows the browser holds right now. A cache, not a walk: the
   status placard polls every idle pass, and 512 substring matches per
   pass is not "nearly free". Maintained by rebuild/append. */
static int g_shown_rows;

/* --- the browser --------------------------------------------------------- */

static void update_launch_enable(void)
{
    DomainState *d = dom();
    short want = 255;

    if (d->sel >= 0 && d->sel < d->count
        && (unsigned long)d->items[d->sel].type == kTypeAppl) {
        want = 0;
    }
    if (g_launch != NULL && want != g_launch_hilite) {
        HiliteControl(g_launch, want);
        g_launch_hilite = want;
    }
}

static void invalidate_detail(void)
{
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_lay.detail);
    }
}

/* Repopulate the browser from the current domain's cache, filtered.
   This is the only whole-list operation left, and it runs on user
   intent (domain switch, keystroke, rescan) - never per arriving item. */
static void rebuild_browser(void)
{
    DataBrowserItemID ids[kSwMaxCap];
    DomainState *d = dom();
    char needle[48];
    UInt32 n = 0;
    int i;

    if (g_browser == NULL) {
        return;
    }
    lower_needle(needle, sizeof needle);
    g_in_rebuild = true;
    RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    for (i = 0; i < d->count; ++i) {
        if (name_matches(&d->items[i], needle)) {
            ids[n++] = (DataBrowserItemID)(i + 1);
        }
    }
    if (n > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, n, ids,
                            kDataBrowserItemNoProperty);
    }
    g_shown_rows = (int)n;
    if (d->sel >= 0) {
        if (d->sel < d->count
            && name_matches(&d->items[d->sel], needle)) {
            DataBrowserItemID sel = (DataBrowserItemID)(d->sel + 1);

            SetDataBrowserSelectedItems(g_browser, 1, &sel,
                                        kDataBrowserItemsAssign);
        } else {
            d->sel = -1;
        }
    }
    g_in_rebuild = false;
    update_launch_enable();
    invalidate_detail();
}

/* Append freshly swept items without touching the rows already there. */
static void append_items(int from, int to)
{
    DataBrowserItemID ids[kSwMaxCap];
    DomainState *d = dom();
    char needle[48];
    UInt32 n = 0;
    int i;

    if (g_browser == NULL || to <= from) {
        return;
    }
    lower_needle(needle, sizeof needle);
    for (i = from; i < to; ++i) {
        if (name_matches(&d->items[i], needle)) {
            ids[n++] = (DataBrowserItemID)(i + 1);
        }
    }
    if (n > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, n, ids,
                            kDataBrowserItemNoProperty);
        g_shown_rows += (int)n;
    }
}

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    DomainState *d = dom();
    const SwPageItem *it;
    char caption[64];
    CFStringRef text;

    (void)browser;
    if (changeValue) {
        return errDataBrowserPropertyNotSupported;
    }
    if (item < 1 || item > (DataBrowserItemID)d->count) {
        return errDataBrowserPropertyNotSupported;
    }
    it = &d->items[item - 1];
    switch (property) {
    case kColName: {
        long n = it->name[0] < 63 ? it->name[0] : 63;

        memcpy(caption, it->name + 1, (size_t)n);
        caption[n] = '\0';
        break;
    }
    case kColVersion:
        snprintf(caption, sizeof caption, "%s",
                 it->version_read ? it->version : "-");
        break;
    case kColSize:
        if (it->size_k >= 0) {
            sw_size_text(it->size_k * 1024L, caption, sizeof caption);
        } else {
            caption[0] = '\0';
        }
        break;
    case kColState:
        snprintf(caption, sizeof caption, "%s",
                 it->running ? "running" : (it->off ? "off" : ""));
        break;
    default:
        return errDataBrowserPropertyNotSupported;
    }
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
    DomainState *d = dom();

    (void)browser;
    /* Notifications fired by our own rebuild are not user intent. */
    if (g_in_rebuild) {
        return;
    }
    if (message == kDataBrowserItemSelected) {
        d->sel = (int)item - 1;
        update_launch_enable();
        invalidate_detail();
    } else if (message == kDataBrowserItemDeselected
               && d->sel == (int)item - 1) {
        d->sel = -1;
        update_launch_enable();
        invalidate_detail();
    }
}

static char ascii_lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

static short state_rank(const SwPageItem *it)
{
    if (it->running) {
        return 0;
    }
    return it->off ? 1 : 2;
}

static Boolean item_compare(ControlRef browser, DataBrowserItemID a,
                            DataBrowserItemID b,
                            DataBrowserPropertyID property)
{
    DomainState *d = dom();
    const SwPageItem *ia;
    const SwPageItem *ib;

    (void)browser;
    if (a < 1 || a > (DataBrowserItemID)d->count || b < 1
        || b > (DataBrowserItemID)d->count) {
        return a < b;
    }
    ia = &d->items[a - 1];
    ib = &d->items[b - 1];
    switch (property) {
    case kColSize:
        if (ia->size_k != ib->size_k) {
            return ia->size_k < ib->size_k;
        }
        break;
    case kColVersion: {
        int cmp = strcmp(ia->version, ib->version);

        if (cmp != 0) {
            return cmp < 0;
        }
        break;
    }
    case kColState:
        if (state_rank(ia) != state_rank(ib)) {
            return state_rank(ia) < state_rank(ib);
        }
        break;
    default:
        break;
    }
    {
        /* Name is the axis and the tie-break, HFS-casually: ASCII
           case-folded, byte order beyond that. */
        const unsigned char *na = ia->name;
        const unsigned char *nb = ib->name;
        int i;
        int len = na[0] < nb[0] ? na[0] : nb[0];

        for (i = 1; i <= len; ++i) {
            char ca = ascii_lower((char)na[i]);
            char cb = ascii_lower((char)nb[i]);

            if (ca != cb) {
                return ca < cb;
            }
        }
        return na[0] < nb[0];
    }
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

static Boolean add_column(DataBrowserPropertyID prop, const char *title,
                          UInt16 min_w, UInt16 max_w,
                          DataBrowserTableViewColumnIndex index)
{
    DataBrowserListViewColumnDesc col;
    OSStatus err;

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = prop;
    col.propertyDesc.propertyType = kDataBrowserTextType;
    /* Every column is a selection column: with four narrow columns a
       click anywhere in the row must select it, or the page feels dead
       to the right of the name (found driving the emulator). */
    col.propertyDesc.propertyFlags = kDataBrowserListViewSortableColumn
        | kDataBrowserListViewSelectionColumn;
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = min_w;
    col.headerBtnDesc.maximumWidth = max_w;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, title, kCFStringEncodingMacRoman);
    err = AddDataBrowserListViewColumn(g_browser, &col, index);
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    return err == noErr;
}

static void size_columns(void)
{
    short list_w = (short)(g_lay.list.right - g_lay.list.left);
    short name_w = (short)(list_w - kSwColVersion - kSwColSize
                           - kSwColState - 20);

    if (name_w < 80) {
        name_w = 80;
    }
    SetDataBrowserTableViewNamedColumnWidth(g_browser, kColName,
                                            (UInt16)name_w);
    SetDataBrowserTableViewNamedColumnWidth(g_browser, kColVersion,
                                            kSwColVersion);
    SetDataBrowserTableViewNamedColumnWidth(g_browser, kColSize,
                                            kSwColSize);
    SetDataBrowserTableViewNamedColumnWidth(g_browser, kColState,
                                            kSwColState);
}

static Boolean create_browser(void)
{
    DataBrowserCallbacks callbacks;

    if (CreateDataBrowserControl(g_owner, &g_lay.list, kDataBrowserListView,
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
    if (!add_column(kColName, "Name", 80, 400, 0)
        || !add_column(kColVersion, "Version", 40, 100, 1)
        || !add_column(kColSize, "Size", 40, 100, 2)
        || !add_column(kColState, "State", 40, 100, 3)) {
        return false;
    }
    size_columns();
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    SetDataBrowserSortProperty(g_browser, kColName);
    HideControl(g_browser);
    return true;
}

/* --- domain data --------------------------------------------------------- */

static void refresh_off_count(DomainState *d)
{
    int i;

    d->off_count = 0;
    for (i = 0; i < d->count; ++i) {
        if (d->items[i].off) {
            ++d->off_count;
        }
    }
}

static Boolean collect_app(const FSSpec *spec, void *ctx)
{
    DomainState *d = (DomainState *)ctx;

    if (d->count >= k_domains_ui[0].cap) {
        d->truncated = true;
        return false;
    }
    now_software_item_fill(spec, false, &d->items[d->count]);
    d->count += 1;
    return d->count < k_domains_ui[0].cap;
}

/* (Re)read one domain from the disk into its cache. Folder domains are
   a synchronous walk; apps clears and starts the resumable sweep, which
   idle then feeds. */
static void load_domain(int idx)
{
    DomainState *d = &g_dom[idx];

    if (d->items == NULL) {
        d->items = (SwPageItem *)NewPtr(
            (long)sizeof(SwPageItem) * k_domains_ui[idx].cap);
        if (d->items == NULL) {
            d->count = 0;             /* honest degrade: an empty domain */
            d->loaded = true;
            return;
        }
    }
    now_software_sweep_end(&d->sweep);
    d->count = 0;
    d->truncated = false;
    d->sweeping = false;
    d->trickle = 0;
    d->off_count = 0;
    d->sel = -1;
    if (idx == 0) {
        now_software_sweep_begin(&d->sweep, NULL);
        d->sweeping = !d->sweep.done;
        if (d->sweep.done) {
            now_software_sweep_end(&d->sweep);
        }
    } else {
        Boolean trunc = false;
        int n = now_software_page_folder(k_domains_ui[idx].key, d->items,
                                         k_domains_ui[idx].cap, &trunc);

        d->count = n > 0 ? n : 0;
        d->truncated = trunc;
        refresh_off_count(d);
    }
    d->loaded = true;
}

/* Switch the page to a domain: from the cache when it is already
   loaded - the first metal round's feedback - from the disk only on
   the first visit. */
static void select_domain(int idx)
{
    if (idx < 0 || idx >= kSwDomainCount) {
        idx = 0;
    }
    g_domain = idx;
    if (g_popup != NULL) {
        SetControlValue(g_popup, (short)(idx + 1));
    }
    if (!g_dom[idx].loaded) {
        load_domain(idx);
    }
    rebuild_browser();
}

/* --- actions ------------------------------------------------------------- */

static void launch_selected(void)
{
    LaunchParamBlockRec lp;
    DomainState *d = dom();
    SwPageItem *it;

    if (d->sel < 0 || d->sel >= d->count) {
        return;
    }
    it = &d->items[d->sel];
    if ((unsigned long)it->type != kTypeAppl) {
        return;
    }
    memset(&lp, 0, sizeof lp);
    lp.launchBlockID = extendedBlock;
    lp.launchEPBLength = extendedBlockLen;
    lp.launchControlFlags = launchContinue | launchNoFileFlags;
    lp.launchAppSpec = &it->spec;
    LaunchApplication(&lp);
}

/* The selected item's icon, acquired on first selection and kept for
   the run - never for every row; the desktop database lookup is cheap
   but 512 of them are not a scroll's price. */
static IconRef selection_icon(SwPageItem *it)
{
    if (it->icon != NULL) {
        return it->icon;
    }
    if (GetIconRef(it->spec.vRefNum, it->creator, it->type,
                   &it->icon) != noErr) {
        if (GetIconRef(kOnSystemDisk, kSystemIconsCreator,
                       (unsigned long)it->type == kTypeAppl
                           ? kGenericApplicationIcon
                           : kGenericDocumentIcon,
                       &it->icon) != noErr) {
            it->icon = NULL;
        }
    }
    return it->icon;
}

static void release_icons(void)
{
    int d;
    int i;

    for (d = 0; d < kSwDomainCount; ++d) {
        if (g_dom[d].items == NULL) {
            continue;
        }
        for (i = 0; i < g_dom[d].count; ++i) {
            if (g_dom[d].items[i].icon != NULL) {
                ReleaseIconRef(g_dom[d].items[i].icon);
                g_dom[d].items[i].icon = NULL;
            }
        }
    }
}

/* --- drawing ------------------------------------------------------------- */

static void draw_at(short x, short y, const char *s)
{
    Str255 t;

    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

static void draw_search(void)
{
    Rect f = g_lay.toolbar_search;
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };

    RGBForeColor(&black);
    FrameRect(&f);
    if (g_search_focus) {
        Rect ring = f;

        InsetRect(&ring, -2, -2);
        FrameRect(&ring);             /* a plain focus ring, not Aqua */
    }
    /* Fore-painted, never a background change: RGBBackColor is port
       state on the one shared Workshop window. */
    InsetRect(&f, 1, 1);
    RGBForeColor(&white);
    PaintRect(&f);
    RGBForeColor(&black);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    if (g_search[0] == '\0' && !g_search_focus) {
        RGBColor gray = { 0x9999, 0x9999, 0x9999 };

        RGBForeColor(&gray);
        draw_at((short)(f.left + 3), (short)(f.bottom - 4), "search");
        RGBForeColor(&black);
    } else {
        char shown[64];

        snprintf(shown, sizeof shown, "%s%s", g_search,
                 g_search_focus ? "|" : "");
        draw_at((short)(f.left + 3), (short)(f.bottom - 4), shown);
    }
}

static void draw_detail(void)
{
    DomainState *d = dom();
    RGBColor black = { 0, 0, 0 };
    SwPageItem *it;
    char buf[96];
    short x = (short)(g_lay.detail.left + 14);
    short y;

    RGBForeColor(&black);
    if (d->sel < 0 || d->sel >= d->count) {
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        draw_at(x, (short)(g_lay.detail.top + 24), "Select an item.");
        return;
    }
    it = &d->items[d->sel];

    {
        IconRef icon = selection_icon(it);

        if (icon != NULL) {
            Rect r;

            r.left = x;
            r.top = (short)(g_lay.detail.top + 12);
            r.right = (short)(r.left + kSwDetailIcon);
            r.bottom = (short)(r.top + kSwDetailIcon);
            PlotIconRef(&r, kAlignNone, kTransformNone,
                        kIconServicesNormalUsageFlag, icon);
        }
    }

    UseThemeFont(kThemeEmphasizedSystemFont, smSystemScript);
    {
        long n = it->name[0] < 40 ? it->name[0] : 40;

        memcpy(buf, it->name + 1, (size_t)n);
        buf[n] = '\0';
    }
    draw_at((short)(x + kSwDetailIcon + 10),
            (short)(g_lay.detail.top + 26), buf);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    y = (short)(g_lay.detail.top + 12 + kSwDetailIcon + 18);
    snprintf(buf, sizeof buf, "Version:  %s",
             it->version_read ? (it->version[0] ? it->version : "none")
                              : "reading...");
    draw_at(x, y, buf);
    y = (short)(y + 15);
    {
        char kind[24];

        sw_kind_text(it->type, it->creator, kind, sizeof kind);
        snprintf(buf, sizeof buf, "Kind:  %s", kind);
        draw_at(x, y, buf);
    }
    y = (short)(y + 15);
    if (it->size_k >= 0) {
        char sz[16];

        sw_size_text(it->size_k * 1024L, sz, sizeof sz);
        snprintf(buf, sizeof buf, "Size:  %s on disk", sz);
        draw_at(x, y, buf);
        y = (short)(y + 15);
    }
    snprintf(buf, sizeof buf, "State:  %s",
             it->running ? "running"
                         : (it->off ? "disabled (off)" : "not running"));
    draw_at(x, y, buf);
}

/* --- module ops --------------------------------------------------------- */

static ControlRef make_popup(const Rect *bounds, short menu_id)
{
    Str255 empty;

    empty[0] = 0;
    return NewControl(g_owner, bounds, empty, false, popupTitleLeftJust,
                      menu_id, 0, popupMenuProc, 0);
}

static OSErr software_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_body = *body;
    software_layout_compute(body, &g_lay);
    g_launch_hilite = -1;
    g_search[0] = '\0';
    g_search_focus = false;

    g_popup = make_popup(&g_lay.toolbar_popup, kSwDomainMenuID);
    text[0] = 0;
    g_detail_box = NewControl(owner, &g_lay.detail, text, false, 0, 0, 1,
                              kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Launch", text);
    g_launch = NewControl(owner, &g_lay.launch_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    CopyCStringToPascal("Rescan", text);
    g_rescan = NewControl(owner, &g_lay.rescan_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    if (g_popup == NULL || g_detail_box == NULL || g_launch == NULL
        || g_rescan == NULL) {
        return memFullErr;
    }
    /* A missing Data Browser costs the list, not the page - the
       processes_module degrade. */
    g_browser_ok = create_browser();
    select_domain(0);                 /* Applications: begins the sweep */
    return noErr;
}

static void software_dispose(void)
{
    int i;

    for (i = 0; i < kSwDomainCount; ++i) {
        now_software_sweep_end(&g_dom[i].sweep);
    }
    release_icons();
    for (i = 0; i < kSwDomainCount; ++i) {
        if (g_dom[i].items != NULL) {
            DisposePtr((Ptr)g_dom[i].items);
            g_dom[i].items = NULL;
        }
        g_dom[i].loaded = false;
        g_dom[i].count = 0;
    }
    /* The window took the controls with it; the UPPs are ours, and are
       disposed only now that the browser is gone. */
    dispose_callbacks();
    g_popup = g_browser = g_detail_box = g_launch = g_rescan = NULL;
    g_owner = NULL;
}

static void software_show(Boolean visible)
{
    g_visible = visible;
    if (g_popup != NULL) {
        if (visible) ShowControl(g_popup); else HideControl(g_popup);
    }
    if (g_browser != NULL) {
        if (visible) ShowControl(g_browser); else HideControl(g_browser);
    }
    if (g_detail_box != NULL) {
        if (visible) ShowControl(g_detail_box);
        else HideControl(g_detail_box);
    }
    if (g_launch != NULL) {
        if (visible) ShowControl(g_launch); else HideControl(g_launch);
    }
    if (g_rescan != NULL) {
        if (visible) ShowControl(g_rescan); else HideControl(g_rescan);
    }
    if (visible) {
        g_launch_hilite = -1;         /* re-assert after reshow */
        update_launch_enable();
    }
}

static void software_layout_op(const Rect *body)
{
    g_body = *body;
    software_layout_compute(body, &g_lay);
    if (g_popup != NULL) {
        MoveControl(g_popup, g_lay.toolbar_popup.left,
                    g_lay.toolbar_popup.top);
    }
    if (g_browser != NULL) {
        MoveControl(g_browser, g_lay.list.left, g_lay.list.top);
        SizeControl(g_browser, (short)(g_lay.list.right - g_lay.list.left),
                    (short)(g_lay.list.bottom - g_lay.list.top));
        size_columns();
    }
    if (g_detail_box != NULL) {
        MoveControl(g_detail_box, g_lay.detail.left, g_lay.detail.top);
        SizeControl(g_detail_box,
                    (short)(g_lay.detail.right - g_lay.detail.left),
                    (short)(g_lay.detail.bottom - g_lay.detail.top));
    }
    if (g_launch != NULL) {
        MoveControl(g_launch, g_lay.launch_btn.left, g_lay.launch_btn.top);
    }
    if (g_rescan != NULL) {
        MoveControl(g_rescan, g_lay.rescan_btn.left, g_lay.rescan_btn.top);
    }
}

static void software_draw(void)
{
    RGBColor black = { 0, 0, 0 };

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    draw_search();
    draw_detail();
    RGBForeColor(&black);
}

static Boolean software_click(const EventRecord *event, Point local)
{
    ControlRef c = NULL;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (PtInRect(local, &g_lay.toolbar_search)) {
        if (!g_search_focus) {
            g_search_focus = true;
            InvalWindowRect(g_owner, &g_lay.toolbar_search);
        }
        return true;
    }
    if (g_search_focus) {
        g_search_focus = false;
        InvalWindowRect(g_owner, &g_lay.toolbar_search);
    }
    if (g_browser != NULL && PtInRect(local, &g_lay.list)) {
        /* The control runs its own tracking: selection and the header. */
        HandleControlClick(g_browser, local, event->modifiers, NULL);
        return true;
    }
    FindControl(local, g_owner, &c);
    if (c == g_popup) {
        if (TrackControl(c, local, (ControlActionUPP)-1L) != 0) {
            int v = GetControlValue(g_popup) - 1;

            if (v != g_domain) {
                g_search[0] = '\0';
                select_domain(v);
                InvalWindowRect(g_owner, &g_lay.toolbar_search);
            }
        }
        return true;
    }
    if (c == g_launch) {
        if (g_launch_hilite == 0
            && TrackControl(c, local, now_pump_action()) != 0) {
            launch_selected();
        }
        return true;
    }
    if (c == g_rescan) {
        if (TrackControl(c, local, now_pump_action()) != 0) {
            load_domain(g_domain);
            rebuild_browser();
        }
        return true;
    }
    return false;
}

static Boolean software_key(const EventRecord *event)
{
    char ch = (char)(event->message & charCodeMask);
    long n;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (ch == '\b' || ch == 0x7F) {
        n = (long)strlen(g_search);
        if (n > 0) {
            g_search[n - 1] = '\0';
        }
    } else if (ch >= ' ' && ch < 0x7F) {
        n = (long)strlen(g_search);
        if (n < (long)sizeof g_search - 1) {
            g_search[n] = ch;
            g_search[n + 1] = '\0';
        }
    } else {
        return false;                  /* arrows and kin are not ours */
    }
    rebuild_browser();
    InvalWindowRect(g_owner, &g_lay.toolbar_search);
    return true;
}

static void software_activate(Boolean active)
{
    (void)active;
}

static void software_idle(void)
{
    DomainState *d = dom();

    if (g_owner == NULL || !g_visible || d->items == NULL) {
        return;
    }
    if (d->sweeping) {
        int before = d->count;

        now_software_sweep_step(&d->sweep, collect_app, d);
        if (d->sweep.done) {
            d->sweeping = false;
            now_software_mark_running(d->items, d->count);
            now_software_sweep_end(&d->sweep);
            /* Running arrived for every row at once; one refresh of the
               State column, by explicit ids - a one-time cost at sweep
               end, not a per-item pattern. */
            if (g_browser != NULL && d->count > 0) {
                DataBrowserItemID ids[kSwMaxCap];
                int i;

                for (i = 0; i < d->count; ++i) {
                    ids[i] = (DataBrowserItemID)(i + 1);
                }
                UpdateDataBrowserItems(g_browser, kDataBrowserNoItem,
                                       (UInt32)d->count, ids,
                                       kDataBrowserItemNoProperty,
                                       kColState);
            }
        }
        append_items(before, d->count);
        return;
    }
    /* Version trickle: one fork open per pass, one CELL repainted -
       never the list. */
    while (d->trickle < d->count && d->items[d->trickle].version_read) {
        ++d->trickle;
    }
    if (d->trickle < d->count) {
        SwPageItem *it = &d->items[d->trickle];
        DataBrowserItemID id = (DataBrowserItemID)(d->trickle + 1);

        now_software_read_version(&it->spec, it->version,
                                  sizeof it->version);
        it->version_read = true;
        ++d->trickle;
        if (g_browser != NULL) {
            UpdateDataBrowserItems(g_browser, kDataBrowserNoItem, 1, &id,
                                   kDataBrowserItemNoProperty,
                                   kColVersion);
        }
        if (d->sel == (int)id - 1) {
            invalidate_detail();
        }
    }
}

static void software_status_text(char *out, long cap)
{
    DomainState *d = dom();

    sw_status_text(k_domains_ui[g_domain].label, g_shown_rows, d->count,
                   g_domain == 0 ? -1 : d->off_count, d->sweeping, out,
                   cap);
}

static const WorkshopModuleOps k_ops = {
    software_create,
    software_dispose,
    software_show,
    software_layout_op,
    software_draw,
    software_click,
    software_key,
    software_activate,
    software_idle,
    software_status_text
};

const WorkshopModuleOps *software_module_ops(void)
{
    return &k_ops;
}
