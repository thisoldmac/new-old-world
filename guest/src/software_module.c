#include "software_module.h"

#include <stdio.h>
#include <string.h>

#include "software.h"
#include "software_layout.h"
#include "pump.h"

/* Rung 3, the interactive cut. A domain pop-up over a scrollable item
   list and a detail pane, on the tested geometry. Applications stream in
   through the idle-paced sweep; the folder domains are a synchronous
   walk. Versions trickle in one fork-open per idle pass
   (now_software_read_version), cached on the row. Search is driven from
   key() into a hand-drawn field, because this WaitNextEvent app cannot
   host an inline edit-text control (the same reason Connection edits in a
   dialog - see workshop_window.c). Launch acts on the selected FSSpec.

   Landing next on this frame: Bring to Front / Quit (need the running
   process's PSN) and Show in Finder (a verified Finder reveal Apple
   Event), plus the selected item's full path in the detail. */

enum {
    kSwMaxItems = 512,        /* apps beyond this truncate, like the cache */
    kSwRowHeight = 14,
    kSwHeaderH = 16,
    kSwScrollW = 15,
    kSwDomainMenuID = 134,
    kTypeAppl = 0x4150504CUL   /* 'APPL' */
};

static const struct {
    const char *key;
    const char *label;
} k_domains_ui[] = {
    { "apps", "Applications" },
    { "extensions", "Extensions" },
    { "cdevs", "Control Panels" },
    { "startup", "Startup Items" },
    { "apple", "Apple Menu Items" }
};
enum { kSwDomainCount = 5 };

static WindowRef g_owner;
static Rect g_body;
static SoftwareLayout g_lay;
static Boolean g_visible;
static short g_font;

static SwPageItem g_items[kSwMaxItems];
static int g_count;
static short g_view[kSwMaxItems];   /* filtered item indices */
static int g_view_count;
static int g_sel = -1;              /* into g_view, or -1 */
static int g_top;                   /* first visible view row */
static int g_domain;                /* index into k_domains_ui */
static char g_search[48];
static Boolean g_sweeping;
static Boolean g_active = true;
static SweepState g_sweep;
static int g_trickle;               /* next g_items index to version */

static ControlRef g_popup;
static ControlRef g_scroll;
static ControlRef g_launch;
static ControlRef g_rescan;
static ControlActionUPP g_scroll_action;

/* --- geometry helpers --------------------------------------------------- */

static void content_rect(Rect *out)
{
    *out = g_lay.list;
    out->top = (short)(out->top + kSwHeaderH);
    out->right = (short)(out->right - kSwScrollW);
}

static void scrollbar_rect(Rect *out)
{
    *out = g_lay.list;
    out->left = (short)(out->right - kSwScrollW);
    out->top = (short)(out->top + kSwHeaderH);
}

static int visible_rows(void)
{
    Rect c;

    content_rect(&c);
    return (c.bottom - c.top) / kSwRowHeight;
}

/* --- controls ----------------------------------------------------------- */

static void show_control(ControlRef c, Boolean vis)
{
    if (c == NULL) {
        return;
    }
    if (vis) {
        ShowControl(c);
    } else {
        HideControl(c);
    }
}

static void sync_scrollbar(void)
{
    int max = g_view_count - visible_rows();

    if (max < 0) {
        max = 0;
    }
    if (g_top > max) {
        g_top = max;
    }
    if (g_top < 0) {
        g_top = 0;
    }
    if (g_scroll != NULL) {
        SetControlMaximum(g_scroll, (short)max);
        SetControlValue(g_scroll, (short)g_top);
    }
}

static void update_launch_enable(void)
{
    Boolean on = false;

    if (g_sel >= 0 && g_sel < g_view_count) {
        on = (unsigned long)g_items[g_view[g_sel]].type == kTypeAppl;
    }
    if (g_launch != NULL) {
        HiliteControl(g_launch, on ? 0 : 255);
    }
}

/* --- the filtered view -------------------------------------------------- */

static Boolean name_matches(const SwPageItem *it, const char *needle)
{
    char cname[64];
    long n = it->name[0] < 63 ? it->name[0] : 63;
    const char *p;
    long qn = (long)strlen(needle);
    long i;

    if (qn == 0) {
        return true;
    }
    memcpy(cname, it->name + 1, (size_t)n);
    cname[n] = '\0';
    for (i = 0; i <= n - qn; ++i) {
        long j = 0;

        for (p = cname + i; j < qn; ++j) {
            char a = p[j], b = needle[j];

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

static void rebuild_view(void)
{
    char needle[48];
    int i;

    for (i = 0; g_search[i] != '\0'; ++i) {
        char c = g_search[i];
        needle[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    needle[i] = '\0';

    g_view_count = 0;
    for (i = 0; i < g_count; ++i) {
        if (name_matches(&g_items[i], needle)) {
            g_view[g_view_count++] = (short)i;
        }
    }
    if (g_sel >= g_view_count) {
        g_sel = g_view_count > 0 ? 0 : -1;
    }
    sync_scrollbar();
}

/* --- filling ------------------------------------------------------------ */

static Boolean collect_app(const FSSpec *spec, void *ctx)
{
    (void)ctx;
    if (g_count >= kSwMaxItems) {
        return false;
    }
    now_software_item_fill(spec, false, &g_items[g_count]);
    g_count += 1;
    return g_count < kSwMaxItems;
}

static void invalidate_body(void)
{
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_lay.list);
        InvalWindowRect(g_owner, &g_lay.detail);
    }
}

static void select_domain(int idx)
{
    Boolean trunc = false;

    if (idx < 0 || idx >= kSwDomainCount) {
        idx = 0;
    }
    now_software_sweep_end(&g_sweep);
    g_domain = idx;
    g_count = 0;
    g_sel = -1;
    g_top = 0;
    g_trickle = 0;
    g_sweeping = false;
    if (g_popup != NULL) {
        SetControlValue(g_popup, (short)(idx + 1));
    }

    if (strcmp(k_domains_ui[idx].key, "apps") == 0) {
        now_software_sweep_begin(&g_sweep, NULL);
        g_sweeping = !g_sweep.done;
        if (g_sweep.done) {           /* no boot volume: nothing to stream */
            now_software_sweep_end(&g_sweep);
        }
    } else {
        g_count = now_software_page_folder(k_domains_ui[idx].key, g_items,
                                           kSwMaxItems, &trunc);
        if (g_count < 0) {
            g_count = 0;
        }
    }
    rebuild_view();
    if (g_view_count > 0) {
        g_sel = 0;
    }
    update_launch_enable();
    invalidate_body();
}

/* --- actions ------------------------------------------------------------ */

static void launch_selected(void)
{
    LaunchParamBlockRec lp;
    SwPageItem *it;

    if (g_sel < 0 || g_sel >= g_view_count) {
        return;
    }
    it = &g_items[g_view[g_sel]];
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

/* --- drawing ------------------------------------------------------------ */

static void p2c_n(const unsigned char *p, char *out, long budget)
{
    long n = p[0];

    if (n > budget) {
        n = budget;
    }
    if (n < 0) {
        n = 0;
    }
    memcpy(out, p + 1, (size_t)n);
    out[n] = '\0';
}

static void draw_at(short x, short y, const char *s)
{
    Str255 t;

    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

/* The system highlight, dimmed to plain gray when the window is not
   frontmost - the sidebar's rule, so a selected row matches the user's
   Appearance theme instead of an imitation blue. */
static void selection_color(RGBColor *out)
{
    if (g_active) {
        LMGetHiliteRGB(out);
    } else {
        out->red = out->green = out->blue = 0xCCCC;
    }
}

static void draw_list(void)
{
    Rect content, row;
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor hilite;
    RGBColor black = { 0, 0, 0 };
    short x_state, x_size, x_ver, name_cap;
    int vis = visible_rows();
    int i;
    short y;

    content_rect(&content);
    x_state = (short)(content.right - 4 - 66);
    x_size = (short)(x_state - 46);
    x_ver = (short)(x_size - 46);
    name_cap = (short)((x_ver - 6 - (content.left + 4)) / 6);
    if (name_cap < 4) {
        name_cap = 4;
    }
    if (name_cap > 40) {
        name_cap = 40;
    }

    /* header */
    TextFont(g_font);
    TextSize(9);
    RGBForeColor(&black);
    draw_at((short)(content.left + 4), (short)(g_lay.list.top + 11), "Name");
    draw_at(x_ver, (short)(g_lay.list.top + 11), "Version");
    draw_at(x_size, (short)(g_lay.list.top + 11), "Size");
    draw_at(x_state, (short)(g_lay.list.top + 11), "State");

    /* body */
    RGBBackColor(&white);
    EraseRect(&content);
    TextSize(10);
    for (i = 0; i < vis; ++i) {
        int vi = g_top + i;
        SwPageItem *it;
        char buf[80];

        if (vi >= g_view_count) {
            break;
        }
        it = &g_items[g_view[vi]];
        row = content;
        row.top = (short)(content.top + i * kSwRowHeight);
        row.bottom = (short)(row.top + kSwRowHeight);
        if (vi == g_sel) {
            selection_color(&hilite);
            RGBForeColor(&hilite);
            PaintRect(&row);
            RGBForeColor(&black);
        }
        y = (short)(row.top + kSwRowHeight - 3);
        p2c_n(it->name, buf, name_cap);
        if (it->off) {
            /* dim disabled items by appending a marker; a real gray text
               color per run is a refinement */
        }
        draw_at((short)(content.left + 4), y, buf);
        draw_at(x_ver, y, it->version_read ? it->version : "-");
        if (it->size_k >= 0) {
            sw_size_text(it->size_k * 1024L, buf, sizeof buf);
            draw_at(x_size, y, buf);
        }
        draw_at(x_state, y,
                it->running ? "running" : (it->off ? "off" : ""));
    }
    RGBBackColor(&white);
}

static void draw_detail(void)
{
    Rect d = g_lay.detail;
    RGBColor black = { 0, 0, 0 };
    SwPageItem *it;
    char buf[96];
    short x, y;

    RGBForeColor(&black);
    x = (short)(d.left + 10);
    if (g_sel < 0 || g_sel >= g_view_count) {
        TextSize(10);
        draw_at(x, (short)(d.top + 20), "Select an item.");
        return;
    }
    it = &g_items[g_view[g_sel]];

    TextSize(11);
    p2c_n(it->name, buf, 40);
    draw_at(x, (short)(d.top + 18), buf);

    TextSize(10);
    y = (short)(d.top + 40);
    snprintf(buf, sizeof buf, "Version   %s",
             it->version_read ? (it->version[0] ? it->version : "none")
                              : "reading...");
    draw_at(x, y, buf);
    y = (short)(y + 16);
    {
        char kind[24];
        sw_kind_text(it->type, it->creator, kind, sizeof kind);
        snprintf(buf, sizeof buf, "Kind      %s", kind);
        draw_at(x, y, buf);
    }
    y = (short)(y + 16);
    if (it->size_k >= 0) {
        char sz[16];
        sw_size_text(it->size_k * 1024L, sz, sizeof sz);
        snprintf(buf, sizeof buf, "Size      %s", sz);
        draw_at(x, y, buf);
    }
    y = (short)(y + 16);
    snprintf(buf, sizeof buf, "State     %s",
             it->running ? "running" : (it->off ? "disabled (off)"
                                                : "not running"));
    draw_at(x, y, buf);
}

static void draw_search(void)
{
    Rect f = g_lay.toolbar_search;
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };

    RGBForeColor(&black);
    FrameRect(&f);
    RGBBackColor(&white);
    InsetRect(&f, 1, 1);
    EraseRect(&f);
    TextFont(g_font);
    TextSize(10);
    if (g_search[0] == '\0') {
        RGBColor gray = { 0x9999, 0x9999, 0x9999 };
        RGBForeColor(&gray);
        draw_at((short)(f.left + 3), (short)(f.bottom - 4), "search");
        RGBForeColor(&black);
    } else {
        char shown[64];
        snprintf(shown, sizeof shown, "%s|", g_search);
        draw_at((short)(f.left + 3), (short)(f.bottom - 4), shown);
    }
}

/* --- module ops --------------------------------------------------------- */

static ControlRef make_popup(const Rect *bounds, short menu_id)
{
    Str255 empty;

    empty[0] = 0;
    return NewControl(g_owner, bounds, empty, false, popupTitleLeftJust,
                      menu_id, 0, popupMenuProc, 0);
}

static void scroll_action(ControlRef c, ControlPartCode part)
{
    int delta = 0;

    switch (part) {
    case kControlUpButtonPart:   delta = -1; break;
    case kControlDownButtonPart: delta = 1; break;
    case kControlPageUpPart:     delta = -(visible_rows() - 1); break;
    case kControlPageDownPart:   delta = visible_rows() - 1; break;
    default: return;
    }
    g_top += delta;
    sync_scrollbar();
    (void)c;
    InvalWindowRect(g_owner, &g_lay.list);
}

static OSErr software_create(WindowRef owner, const Rect *body)
{
    Str255 text;
    Rect sb;

    g_owner = owner;
    g_body = *body;
    software_layout_compute(body, &g_lay);
    if (g_font == 0) {
        CopyCStringToPascal("Geneva", text);
        GetFNum(text, &g_font);
    }
    g_scroll_action = NewControlActionUPP(scroll_action);
    if (g_scroll_action == NULL) {
        return memFullErr;
    }
    g_popup = make_popup(&g_lay.toolbar_popup, kSwDomainMenuID);
    scrollbar_rect(&sb);
    text[0] = 0;
    g_scroll = NewControl(owner, &sb, text, false, 0, 0, 0, scrollBarProc, 0);
    CopyCStringToPascal("Launch", text);
    g_launch = NewControl(owner, &g_lay.launch_btn, text, false, 0, 0, 0,
                          pushButProc, 0);
    CopyCStringToPascal("Rescan", text);
    g_rescan = NewControl(owner, &g_lay.rescan_btn, text, false, 0, 0, 0,
                          pushButProc, 0);
    if (g_popup == NULL || g_scroll == NULL || g_launch == NULL
        || g_rescan == NULL) {
        return memFullErr;
    }
    g_search[0] = '\0';
    select_domain(0);                 /* Applications: begins the sweep */
    return noErr;
}

static void software_dispose(void)
{
    now_software_sweep_end(&g_sweep);
    if (g_scroll_action != NULL) {
        DisposeControlActionUPP(g_scroll_action);
        g_scroll_action = NULL;
    }
    g_popup = g_scroll = g_launch = g_rescan = NULL;
    g_owner = NULL;
}

static void software_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_popup, visible);
    show_control(g_scroll, visible);
    show_control(g_launch, visible);
    show_control(g_rescan, visible);
    if (visible) {
        update_launch_enable();
    }
}

static void software_layout_op(const Rect *body)
{
    Rect sb;

    g_body = *body;
    software_layout_compute(body, &g_lay);
    if (g_popup != NULL) {
        MoveControl(g_popup, g_lay.toolbar_popup.left,
                    g_lay.toolbar_popup.top);
    }
    if (g_scroll != NULL) {
        scrollbar_rect(&sb);
        MoveControl(g_scroll, sb.left, sb.top);
        SizeControl(g_scroll, (short)(sb.right - sb.left),
                    (short)(sb.bottom - sb.top));
    }
    if (g_launch != NULL) {
        MoveControl(g_launch, g_lay.launch_btn.left, g_lay.launch_btn.top);
    }
    if (g_rescan != NULL) {
        MoveControl(g_rescan, g_lay.rescan_btn.left, g_lay.rescan_btn.top);
    }
    sync_scrollbar();
}

static void software_draw(void)
{
    RGBColor black = { 0, 0, 0 };

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    RGBForeColor(&black);
    FrameRect(&g_lay.list);
    FrameRect(&g_lay.detail);
    draw_list();
    draw_detail();
    draw_search();
    RGBForeColor(&black);
}

static Boolean software_click(const EventRecord *event, Point local)
{
    ControlRef c = NULL;
    ControlPartCode part;
    Rect content;

    (void)event;
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    part = FindControl(local, g_owner, &c);
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
    if (c == g_scroll) {
        if (part == kControlIndicatorPart) {
            if (TrackControl(c, local, NULL) != 0) {
                g_top = GetControlValue(g_scroll);
                sync_scrollbar();
                InvalWindowRect(g_owner, &g_lay.list);
            }
        } else {
            TrackControl(c, local, g_scroll_action);
        }
        return true;
    }
    if (c == g_launch) {
        if (TrackControl(c, local, now_pump_action()) != 0) {
            launch_selected();
        }
        return true;
    }
    if (c == g_rescan) {
        if (TrackControl(c, local, now_pump_action()) != 0) {
            g_search[0] = '\0';
            select_domain(g_domain);
        }
        return true;
    }
    content_rect(&content);
    if (PtInRect(local, &content)) {
        int row = (local.v - content.top) / kSwRowHeight + g_top;
        if (row >= 0 && row < g_view_count) {
            g_sel = row;
            update_launch_enable();
            InvalWindowRect(g_owner, &g_lay.list);
            InvalWindowRect(g_owner, &g_lay.detail);
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
    if (ch == '\b' || ch == 0x7F) {           /* backspace / delete */
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
        return false;                          /* arrows etc.: not ours */
    }
    g_top = 0;
    rebuild_view();
    update_launch_enable();
    InvalWindowRect(g_owner, &g_lay.list);
    InvalWindowRect(g_owner, &g_lay.detail);
    InvalWindowRect(g_owner, &g_lay.toolbar_search);
    return true;
}

static void software_activate(Boolean active)
{
    g_active = active;
    if (g_owner != NULL && g_visible && g_sel >= 0) {
        InvalWindowRect(g_owner, &g_lay.list);
    }
}

static void software_idle(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    if (g_sweeping) {
        now_software_sweep_step(&g_sweep, collect_app, NULL);
        if (g_sweep.done) {
            g_sweeping = false;
            now_software_mark_running(g_items, g_count);
            now_software_sweep_end(&g_sweep);
        }
        rebuild_view();
        if (g_sel < 0 && g_view_count > 0) {
            g_sel = 0;
            update_launch_enable();
        }
        InvalWindowRect(g_owner, &g_lay.list);
        return;
    }
    /* Version trickle: one fork open per pass, cached on the row. */
    while (g_trickle < g_count && g_items[g_trickle].version_read) {
        ++g_trickle;
    }
    if (g_trickle < g_count) {
        SwPageItem *it = &g_items[g_trickle];

        now_software_read_version(&it->spec, it->version, sizeof it->version);
        it->version_read = true;
        ++g_trickle;
        InvalWindowRect(g_owner, &g_lay.list);
        if (g_sel >= 0 && g_view[g_sel] == g_trickle - 1) {
            InvalWindowRect(g_owner, &g_lay.detail);
        }
    }
}

static void software_status_text(char *out, long cap)
{
    int off = -1;

    if (g_domain != 0) {              /* folder domains track disabled */
        int i;
        off = 0;
        for (i = 0; i < g_count; ++i) {
            if (g_items[i].off) {
                ++off;
            }
        }
    }
    sw_status_text(k_domains_ui[g_domain].label, g_view_count, g_count,
                   off, g_sweeping, out, cap);
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
