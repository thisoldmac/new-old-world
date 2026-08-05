#include "workshop_sidebar.h"

#include <stdio.h>
#include <string.h>

#include "prefs.h"
#include "pump.h"
#include "wire.h"

/* The rail is one framed white panel drawn by hand: icon, bold title,
   quiet subtitle per row, the pinned utilities at the bottom behind a
   divider with the status lamp. A Data Browser cannot pin a row or
   draw two-line cells without custom-callback territory this CarbonLib
   has not proved, and the Console's hand-drawn scrollback set the
   precedent for an owned view; system look comes from the theme fonts
   and the system highlight color, not from imitation chrome.

   Three things the panel is NOT free to assume any more, all of them
   the person's to decide:

     - the ORDER of the nav rows, which they rearrange by Option-dragging
       a row (the Control Strip's gesture, and the only rearrange idiom
       this era has);
     - the DENSITY, rich (icon + title + subtitle) or compact (icon +
       title), which the Preferences page switches;
     - how far the list is SCROLLED, when the rows outnumber the space.

   So a rectangle in the layout is a SLOT, not a module, and the module a
   slot shows is g_order[scroll_top + slot]. The scroll bar is a real
   Control Manager one, created once and hidden whenever everything
   fits - a bar that is always present but usually dead is chrome
   charged against a 160-pixel-wide rail. */

enum {
    kIconInset = 8,           /* panel edge to icon */
    kIconSize = 16,
    kTextGap = 6,             /* icon to text */
    kTitleBaseline = 13,      /* within a rich row */
    kSubtitleBaseline = 25,
    /* One line, optically centred in an 18-pixel row. Hard-coded like
       the pair above, and for the same reason: the theme fonts here are
       fixed and a metrics query would be a runtime answer to a question
       the layout already settled. */
    kCompactBaseline = 13,
    kLampSize = 8,

    /* How far the mouse must travel before an Option-press becomes a
       drag. Without it, a hand that shifts one pixel while clicking
       rearranges the rail by accident. */
    kDragSlop = 3,

    kScreenshotsIconID = 129,
    kFilesIconID = 130,
    kConsoleIconID = 131,
    kConnectionIconID = 132,
    kProcessesIconID = 133,
    kHardwareIconID = 134,
    kLogsIconID = 135,
    kSoftwareIconID = 136,
    kMcpIconID = 137,
    kDiagnosticsIconID = 138,
    kNetworkingIconID = 139,
    kCloudIconID = 140,
    kChatIconID = 141,
    kPreferencesIconID = 142
};

/* The nav rows plus the three pinned ones ARE the module list. A count
   one short used to read PAST nav_rows[] and lay a row out over whatever
   followed it in the struct - which is precisely what happened when
   Networking went in on 2026-08-01 and the last three rows drew on top
   of each other. The array is indexed by SLOT now rather than by module,
   which removes that particular overrun, but the count still has to be
   right or the order table below is the wrong length.

   It lives here rather than beside kWorkshopNavRows because
   workshop_layout.h is compiled by the HOST cc for a native test and must
   stay free of Toolbox headers; workshop_module.h is not. This file
   already includes both, and it is the file that does the indexing. */
_Static_assert(kWorkshopNavRows + 3 == kWorkshopModuleCount,
               "nav rows + the three pinned rows must be every module");
/* The saved order stores nav ids, so the nav range must stay the
   contiguous prefix 1..kWorkshopNavRows that kWorkshopIsNavModule
   assumes. A page inserted between Chat and Preferences would break
   both at once, silently. */
_Static_assert((int)kWorkshopPreferences == kWorkshopNavRows + 1,
               "the pinned group must start right after the nav range");
/* Both sides cast: they are separate anonymous enums, and -Werror here
   treats comparing two of them as a defect. */
_Static_assert((int)kWorkshopNavRows <= (int)kNowSidebarOrderMax,
               "the saved order must have room for every nav row");

static WindowRef g_owner;
static WorkshopLayout g_lay;
static WorkshopSidebarSelectFn g_on_select;
static WorkshopSidebarRelayoutFn g_on_relayout;
static WorkshopModuleID g_selected = kWorkshopScreenshots;
static Boolean g_active = true;

/* The person's arrangement of the nav rows: module ids, in the order
   they appear. Seeded from prefs and sanitised, so it is always a
   permutation of 1..kWorkshopNavRows no matter what was on disk. */
static WorkshopModuleID g_order[kWorkshopNavRows];
static Boolean g_compact;
static short g_scroll_top;

/* The scroll bar exists whenever the rail does, and is HIDDEN unless the
   list overflows - creating it lazily would mean creating a control
   during an update, which is how a control ends up drawn but not
   hit-testable. */
static ControlRef g_scroll;
static ControlActionUPP g_scroll_action_upp;

/* Connection caption cache: idle repaints the pinned row only when the
   words change, because during a transfer the loop runs unslept. */
static ConnPhase g_shown_phase = (ConnPhase)-1;
static char g_shown_detail[96];

static const struct {
    const char *title;
    const char *subtitle;
    short icon_id;
} k_rows[kWorkshopModuleCount + 1] = {
    { NULL, NULL, 0 },
    { "Screenshots", "Capture and stream", kScreenshotsIconID },
    { "Files", "Browse and exchange", kFilesIconID },
    { "Console", "Local commands", kConsoleIconID },
    { "Processes", "Running applications", kProcessesIconID },
    { "Hardware", "Census and probes", kHardwareIconID },
    { "Software", "What is installed", kSoftwareIconID },
    { "MCP", "Who may drive this Mac", kMcpIconID },
    { "Diagnostics", "Measure this Mac", kDiagnosticsIconID },
    { "Networking", "Link, address and ports", kNetworkingIconID },
    { "iCloud", "The other Mac's cloud", kCloudIconID },
    { "Chat", "Ask the other Mac's model", kChatIconID },
    { "Preferences", "How this window behaves", kPreferencesIconID },
    { "Logs", "This launch's events", kLogsIconID },
    { "Connection", NULL, kConnectionIconID }
};

/* ---- the person's order ------------------------------------------- */

/* Where a nav module sits in the arrangement, or -1 if it is pinned. */
static short nav_pos(WorkshopModuleID module)
{
    short i;

    for (i = 0; i < kWorkshopNavRows; ++i) {
        if (g_order[i] == module) {
            return i;
        }
    }
    return -1;
}

static void order_defaults(void)
{
    short i;

    for (i = 0; i < kWorkshopNavRows; ++i) {
        g_order[i] = (WorkshopModuleID)(i + 1);
    }
}

/* Whatever was on disk becomes a permutation: ids out of the nav range
   and repeats are dropped, then anything missing is appended in enum
   order. That is what makes a module added LATER simply arrive at the
   foot of a saved arrangement instead of invalidating it - and what
   makes a corrupt or truncated record cost nothing. */
static void order_adopt(const short *saved)
{
    Boolean seen[kWorkshopNavRows + 1];
    short n = 0;
    short i;

    memset(seen, 0, sizeof seen);
    for (i = 0; i < kNowSidebarOrderMax && n < kWorkshopNavRows; ++i) {
        short id = saved[i];

        if (id >= 1 && id <= kWorkshopNavRows && !seen[id]) {
            seen[id] = true;
            g_order[n++] = (WorkshopModuleID)id;
        }
    }
    for (i = 1; i <= kWorkshopNavRows; ++i) {
        if (!seen[i]) {
            g_order[n++] = (WorkshopModuleID)i;
        }
    }
}

static void order_persist(void)
{
    NowPrefs prefs;
    short i;

    now_prefs_load(&prefs);
    memset(prefs.sidebar_order, 0, sizeof prefs.sidebar_order);
    for (i = 0; i < kWorkshopNavRows; ++i) {
        prefs.sidebar_order[i] = (short)g_order[i];
    }
    prefs.sidebar_compact = g_compact;
    now_prefs_save(&prefs);
}

/* Lift one row out and drop it back in at `to`, everything between
   sliding up or down by one. `to` counts positions in the list BEFORE
   the lift, which is what a drop point between two visible rows means. */
static void order_move(short from, short to)
{
    WorkshopModuleID moved;
    short i;

    if (from < 0 || from >= kWorkshopNavRows || to < 0
        || to > kWorkshopNavRows) {
        return;
    }
    if (to > from) {
        --to;                         /* the lift closed the gap */
    }
    if (to == from) {
        return;
    }
    moved = g_order[from];
    if (to < from) {
        for (i = from; i > to; --i) {
            g_order[i] = g_order[i - 1];
        }
    } else {
        for (i = from; i < to; ++i) {
            g_order[i] = g_order[i + 1];
        }
    }
    g_order[to] = moved;
}

/* ---- slots, and which module is in one ----------------------------- */

static short visible_slots(void)
{
    short n = g_lay.nav_visible;

    return (n < 1) ? 1 : n;
}

static short max_scroll(void)
{
    short m = (short)(kWorkshopNavRows - visible_slots());

    return m < 0 ? 0 : m;
}

static void clamp_scroll(void)
{
    if (g_scroll_top > max_scroll()) {
        g_scroll_top = max_scroll();
    }
    if (g_scroll_top < 0) {
        g_scroll_top = 0;
    }
}

/* The module drawn in a visible slot, or 0 when the slot is past the end
   of the list (which only happens if the arithmetic ever disagrees with
   the layout - drawing nothing is the honest answer). */
static WorkshopModuleID module_at_slot(short slot)
{
    short pos = (short)(g_scroll_top + slot);

    if (slot < 0 || slot >= visible_slots() || pos < 0
        || pos >= kWorkshopNavRows) {
        return (WorkshopModuleID)0;
    }
    return g_order[pos];
}

/* A module's rectangle, or NULL when it is a nav row scrolled out of
   sight. Every caller must handle the NULL: before scrolling existed
   this could not happen, and a row that is simply not on screen is now
   an ordinary state, not an error. */
static const Rect *row_rect(WorkshopModuleID module)
{
    short pos;
    short slot;

    if (module == kWorkshopConnection) {
        return &g_lay.conn_row;
    }
    if (module == kWorkshopLogs) {
        return &g_lay.logs_row;       /* pinned above Connection */
    }
    if (module == kWorkshopPreferences) {
        return &g_lay.prefs_row;      /* pinned above Logs */
    }
    pos = nav_pos(module);
    if (pos < 0) {
        return NULL;
    }
    slot = (short)(pos - g_scroll_top);
    if (slot < 0 || slot >= visible_slots()) {
        return NULL;                  /* scrolled out of sight */
    }
    return &g_lay.nav_rows[slot];
}

static void inval_row(WorkshopModuleID module)
{
    const Rect *r = row_rect(module);

    if (g_owner != NULL && r != NULL) {
        InvalWindowRect(g_owner, r);
    }
}

static void inval_nav_area(void)
{
    Rect area;

    if (g_owner == NULL) {
        return;
    }
    area = g_lay.rail_list;
    area.bottom = g_lay.conn_divider.top;
    InvalWindowRect(g_owner, &area);
}

/* Blit our own 'ics#' bytes rather than PlotIconID: an icon SUITE is
   assembled from the whole resource chain, and the System file's own
   deeper family member at the same ID wins on a color display - which
   is exactly what happened to ID 129 in the VM. CopyBits pair: mask
   punches the silhouette white, data lays the black art. */
static void plot_small_icon(short id, const Rect *dst_rect)
{
    Handle h = GetResource('ics#', id);
    BitMap art;
    BitMap mask;
    const BitMap *dst;
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    GrafPtr port;

    if (h == NULL || GetHandleSize(h) < 64) {
        return;
    }
    HLock(h);
    art.baseAddr = *h;
    art.rowBytes = 2;
    SetRect(&art.bounds, 0, 0, 16, 16);
    mask = art;
    mask.baseAddr = *h + 32;

    GetPort(&port);
    dst = GetPortBitMapForCopyBits(port);
    /* CopyBits colorizes with the port's fore and back colors; pin them
       so a themed background cannot tint the art. */
    GetBackColor(&saved_back);
    RGBForeColor(&black);
    RGBBackColor(&white);
    CopyBits(&mask, dst, &mask.bounds, dst_rect, srcBic, NULL);
    CopyBits(&art, dst, &art.bounds, dst_rect, srcOr, NULL);
    RGBBackColor(&saved_back);
    HUnlock(h);
}

/* Scrolling moves which module each slot shows; the slots themselves do
   not move, so nothing is relaid out - the nav area is simply repainted
   with a different stretch of the list in it. */
static void scroll_to(short top)
{
    short before = g_scroll_top;

    g_scroll_top = top;
    clamp_scroll();
    if (g_scroll_top == before) {
        return;
    }
    if (g_scroll != NULL) {
        SetControlValue(g_scroll, g_scroll_top);
    }
    inval_nav_area();
}

static pascal void scroll_action(ControlRef control, ControlPartCode part)
{
    short page = (short)(visible_slots() - 1);
    short delta = 0;

    (void)control;
    if (page < 1) {
        page = 1;
    }
    switch (part) {
    case kControlUpButtonPart:
        delta = -1;
        break;
    case kControlDownButtonPart:
        delta = 1;
        break;
    case kControlPageUpPart:
        delta = (short)-page;
        break;
    case kControlPageDownPart:
        delta = page;
        break;
    default:
        return;
    }
    scroll_to((short)(g_scroll_top + delta));
    /* This IS the pump for the scroll bar's tracking loop: the action
       proc runs for as long as the button is held, and the wire is
       serviced from here rather than from now_pump_action, which cannot
       also do the scrolling. */
    now_wire_pump();
}

/* Bring a row into view, the least distance that does it. */
static void reveal_pos(short pos)
{
    if (pos < g_scroll_top) {
        scroll_to(pos);
    } else if (pos >= g_scroll_top + visible_slots()) {
        scroll_to((short)(pos - visible_slots() + 1));
    }
}

/* The bar mirrors the list: one unit per row, a page of what fits, and
   disabled-and-hidden the moment everything does. Called after any
   change to the layout, the scroll position or the row count. */
static void sync_scrollbar(void)
{
    Boolean wanted;

    if (g_scroll == NULL) {
        return;
    }
    clamp_scroll();
    wanted = g_lay.rail_scrolls;
    if (wanted) {
        MoveControl(g_scroll, g_lay.nav_scroll.left, g_lay.nav_scroll.top);
        SizeControl(g_scroll,
                    (short)(g_lay.nav_scroll.right - g_lay.nav_scroll.left),
                    (short)(g_lay.nav_scroll.bottom - g_lay.nav_scroll.top));
        SetControlMaximum(g_scroll, max_scroll());
        SetControlValue(g_scroll, g_scroll_top);
    }
    /* IsControlVisible before Show/Hide: both draw whatever they are
       passed, so calling them unconditionally is the flicker loop the
       start-here doc names, one repaint per layout pass. */
    if (wanted != IsControlVisible(g_scroll)) {
        if (wanted) {
            ShowControl(g_scroll);
        } else {
            HideControl(g_scroll);
        }
    }
}

void workshop_sidebar_load_prefs(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    g_compact = prefs.sidebar_compact;
    order_adopt(prefs.sidebar_order);
    g_scroll_top = 0;
}

void workshop_sidebar_rail_spec(WorkshopRailSpec *out)
{
    if (out == NULL) {
        return;
    }
    /* An unseeded rail is the rich, unscrolled, enum-ordered one - the
       shape this window had before any of it was a choice. */
    out->compact = g_compact;
    out->scroll_top = g_scroll_top;
}

void workshop_sidebar_set_relayout_fn(WorkshopSidebarRelayoutFn fn)
{
    g_on_relayout = fn;
}

Boolean workshop_sidebar_create(WindowRef owner, const WorkshopLayout *lay,
                                WorkshopSidebarSelectFn on_select)
{
    Str255 empty;

    g_owner = owner;
    g_lay = *lay;
    g_on_select = on_select;
    g_selected = kWorkshopScreenshots;
    g_active = true;
    g_shown_phase = (ConnPhase)-1;
    g_shown_detail[0] = '\0';
    if (g_order[0] == 0) {
        order_defaults();             /* never seeded: the enum order */
    }
    g_scroll_top = g_lay.nav_scroll_top;

    /* A UPP is not a cast on this runtime - carbon-upp-is-not-a-cast-on-cfm.
       Built before the control, so a failure costs nothing to unwind. */
    g_scroll_action_upp = NewControlActionUPP(scroll_action);
    if (g_scroll_action_upp == NULL) {
        return false;
    }
    empty[0] = 0;
    g_scroll = NewControl(owner, &g_lay.nav_scroll, empty, false, 0, 0, 0,
                          scrollBarProc, 0);
    if (g_scroll == NULL) {
        DisposeControlActionUPP(g_scroll_action_upp);
        g_scroll_action_upp = NULL;
        return false;
    }
    sync_scrollbar();                 /* shows it only if it is needed */
    return true;
}

void workshop_sidebar_dispose(void)
{
    /* The control dies with the window; only the UPP is ours to release,
       and only after DisposeWindow has run. */
    if (g_scroll_action_upp != NULL) {
        DisposeControlActionUPP(g_scroll_action_upp);
        g_scroll_action_upp = NULL;
    }
    g_scroll = NULL;
    g_owner = NULL;
    g_on_select = NULL;
    g_on_relayout = NULL;
}

void workshop_sidebar_layout(const WorkshopLayout *lay)
{
    g_lay = *lay;
    /* The layout clamped the scroll against the slots that now fit; take
       its answer back, or a grow that made room would leave the rail
       scrolled past its own end. */
    g_scroll_top = g_lay.nav_scroll_top;
    sync_scrollbar();
}

Boolean workshop_sidebar_compact(void)
{
    return g_compact;
}

void workshop_sidebar_set_compact(Boolean compact)
{
    if (compact == g_compact) {
        return;
    }
    g_compact = compact;
    order_persist();
    /* Every row moves, so this is the window's to redo - the rail cannot
       recompute its own rectangles. */
    if (g_on_relayout != NULL) {
        g_on_relayout();
    }
}

void workshop_sidebar_reset_order(void)
{
    order_defaults();
    g_scroll_top = 0;
    order_persist();
    sync_scrollbar();
    inval_nav_area();
}

/* The system's highlight color, dimmed to plain gray when the window is
   in the background - the classic list convention. */
static void selection_color(RGBColor *out)
{
    if (!g_active) {
        out->red = 0xDDDD;
        out->green = 0xDDDD;
        out->blue = 0xDDDD;
        return;
    }
    LMGetHiliteRGB(out);
}

static void draw_row_in(WorkshopModuleID module, const Rect *r)
{
    Rect icon_rect;
    Str255 text;
    RGBColor black = { 0, 0, 0 };
    RGBColor gray = { 0x5555, 0x5555, 0x5555 };
    short text_left;
    short text_width;
    short title_base = g_compact ? kCompactBaseline : kTitleBaseline;

    if (module == g_selected) {
        RGBColor band;

        selection_color(&band);
        RGBForeColor(&band);
        PaintRect(r);
        RGBForeColor(&black);
    }

    SetRect(&icon_rect, (short)(r->left + kIconInset),
            (short)((r->top + r->bottom - kIconSize) / 2),
            (short)(r->left + kIconInset + kIconSize),
            (short)((r->top + r->bottom - kIconSize) / 2 + kIconSize));
    plot_small_icon(k_rows[module].icon_id, &icon_rect);

    text_left = (short)(icon_rect.right + kTextGap);
    text_width = (short)(r->right - text_left - 4);

    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    /* Compact Connection is the one row whose single line is not its
       title: the icon and the lamp already say which row it is, and what
       a person needs from it at a glance is the STATE. Every other row
       shows its name. */
    if (!(g_compact && module == kWorkshopConnection)) {
        MoveTo(text_left, (short)(r->top + title_base));
        CopyCStringToPascal(k_rows[module].title, text);
        TruncString(text_width, text, truncEnd);
        DrawString(text);
    }

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    if (module == kWorkshopConnection) {
        Rect lamp;
        RGBColor lamp_color;
        const char *detail = g_shown_detail;

        /* Lamp at the right edge, like the reference. The words beside
           it still carry the state on their own. */
        switch (g_shown_phase) {
        case kConnConnected:
            lamp_color.red = 0x0000;
            lamp_color.green = 0xAAAA;
            lamp_color.blue = 0x2222;
            break;
        case kConnConnecting:
        case kConnHandshaking:
        case kConnBackoff:
            lamp_color.red = 0xFFFF;
            lamp_color.green = 0x9999;
            lamp_color.blue = 0x0000;
            break;
        default:
            lamp_color.red = 0xCCCC;
            lamp_color.green = 0x2222;
            lamp_color.blue = 0x2222;
            break;
        }
        SetRect(&lamp, (short)(r->right - 6 - kLampSize),
                (short)((r->top + r->bottom - kLampSize) / 2),
                (short)(r->right - 6),
                (short)((r->top + r->bottom + kLampSize) / 2));
        RGBForeColor(&lamp_color);
        PaintOval(&lamp);
        RGBForeColor(&black);
        FrameOval(&lamp);

        text_width = (short)(lamp.left - text_left - 4);
        if (detail[0] == '\0') {
            detail = "No link";
        }
        if (module != g_selected) {
            RGBForeColor(&gray);
        }
        MoveTo(text_left, (short)(r->top + (g_compact ? kCompactBaseline
                                                      : kSubtitleBaseline)));
        CopyCStringToPascal(detail, text);
        TruncString(text_width, text, truncMiddle);
        DrawString(text);
        RGBForeColor(&black);
        return;
    }

    /* Compact is the title alone: the subtitle is the line it gives up,
       which is the whole point of the density. */
    if (g_compact) {
        return;
    }
    if (module != g_selected) {
        RGBForeColor(&gray);
    }
    MoveTo(text_left, (short)(r->top + kSubtitleBaseline));
    CopyCStringToPascal(k_rows[module].subtitle, text);
    TruncString(text_width, text, truncEnd);
    DrawString(text);
    RGBForeColor(&black);
}

static void draw_row(WorkshopModuleID module)
{
    const Rect *r = row_rect(module);

    if (r != NULL) {
        draw_row_in(module, r);
    }
}

void workshop_sidebar_draw(void)
{
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    Pattern gray;
    int i;

    if (g_owner == NULL) {
        return;
    }
    SetPortWindowPort(g_owner);

    /* The panel: white ground behind every row, framed like a list. The
       scroll bar's own rectangle is left out of the erase - it paints
       its whole face itself, and erasing under it first is one visible
       flash of white per update. */
    GetBackColor(&saved_back);
    RGBBackColor(&white);
    if (g_lay.rail_scrolls) {
        RgnHandle panel = NewRgn();
        RgnHandle bar = NewRgn();

        if (panel != NULL && bar != NULL) {
            RectRgn(panel, &g_lay.rail_list);
            RectRgn(bar, &g_lay.nav_scroll);
            DiffRgn(panel, bar, panel);
            EraseRgn(panel);
        } else {
            EraseRect(&g_lay.rail_list);
        }
        if (panel != NULL) {
            DisposeRgn(panel);
        }
        if (bar != NULL) {
            DisposeRgn(bar);
        }
    } else {
        EraseRect(&g_lay.rail_list);
    }
    RGBBackColor(&saved_back);
    FrameRect(&g_lay.rail_list);

    /* Nav rows by SLOT: which module a slot holds is the person's order
       and the scroll position, not the enum. */
    for (i = 0; i < visible_slots(); ++i) {
        WorkshopModuleID module = module_at_slot((short)i);

        if (module != (WorkshopModuleID)0) {
            draw_row_in(module, &g_lay.nav_rows[i]);
        }
    }
    draw_row(kWorkshopPreferences);
    draw_row(kWorkshopLogs);
    draw_row(kWorkshopConnection);

    GetQDGlobalsGray(&gray);
    PenPat(&gray);
    PaintRect(&g_lay.conn_divider);
    PenNormal();

    /* Last, and only when it is on screen: the erase above deliberately
       spared its face, but the frame and the rows are drawn over the
       panel it lives in, so it settles the pixels it owns. */
    if (g_scroll != NULL && g_lay.rail_scrolls) {
        Draw1Control(g_scroll);
    }
}

/* Which slot boundary a point is nearest: 0 is above the first visible
   row, visible_slots() is below the last. Returned as a position in the
   whole list, so the caller never has to add the scroll offset back. */
static short drop_pos(Point where)
{
    short row_h = g_lay.row_height;
    short slot;

    if (row_h < 1) {
        row_h = 1;
    }
    slot = (short)((where.v - g_lay.nav_rows[0].top + row_h / 2) / row_h);
    if (slot < 0) {
        slot = 0;
    }
    if (slot > visible_slots()) {
        slot = visible_slots();
    }
    return (short)(g_scroll_top + slot);
}

/* The insertion line, drawn in XOR so drawing it a second time in the
   same place erases it exactly - the classic drag feedback, and the only
   kind that costs no repaint of the rows underneath. */
static void toggle_drop_line(short pos)
{
    short slot = (short)(pos - g_scroll_top);
    Rect line;
    short y;

    if (slot < 0 || slot > visible_slots()) {
        return;
    }
    if (slot == visible_slots()) {
        y = g_lay.nav_rows[slot - 1].bottom;
    } else {
        y = g_lay.nav_rows[slot].top;
    }
    /* Pulled inside the list at the two ends, so the line is never drawn
       half over the panel frame. */
    if (y >= g_lay.nav_rows[visible_slots() - 1].bottom - 1) {
        y = (short)(g_lay.nav_rows[visible_slots() - 1].bottom - 2);
    }
    if (y <= g_lay.nav_rows[0].top) {
        y = g_lay.nav_rows[0].top;
    }
    SetRect(&line, g_lay.nav_rows[0].left, y, g_lay.nav_rows[0].right,
            (short)(y + 2));
    PenMode(patXor);
    PaintRect(&line);
    PenNormal();
}

/* Option-drag, the Control Strip's gesture and the only rearrange idiom
   this era has. A nested tracking loop, so it pumps the wire: a finger
   resting on a row would otherwise stop the connection for as long as
   the drag lasts, which is exactly the defect pump.h exists for.

   The drag reaches only rows that are ON SCREEN - it does not scroll the
   list under itself. Rearranging past the edge of a scrolled rail means
   dropping, scrolling, and dragging again; that is a real limitation and
   it is in docs/open-issues.md rather than hidden here. */
static void drag_row(short from_pos, Point start)
{
    Point last = start;
    short shown = -1;
    Boolean armed = false;

    while (StillDown()) {
        Point now_pt;

        now_wire_pump();              /* the rule: every nested loop pumps */
        GetMouse(&now_pt);
        if (!armed) {
            short dv = (short)(now_pt.v - start.v);
            short dh = (short)(now_pt.h - start.h);

            if (dv < 0) {
                dv = (short)-dv;
            }
            if (dh < 0) {
                dh = (short)-dh;
            }
            if (dv < kDragSlop && dh < kDragSlop) {
                continue;             /* a click, not yet a drag */
            }
            armed = true;
        }
        if (now_pt.v == last.v && shown >= 0) {
            continue;
        }
        last = now_pt;
        {
            short want = drop_pos(now_pt);

            if (want != shown) {
                if (shown >= 0) {
                    toggle_drop_line(shown);
                }
                toggle_drop_line(want);
                shown = want;
            }
        }
    }
    if (shown >= 0) {
        toggle_drop_line(shown);      /* erase before anything repaints */
    }
    if (!armed || shown < 0) {
        return;                       /* an Option-click that never moved */
    }
    order_move(from_pos, shown);
    order_persist();
    inval_nav_area();
}

Boolean workshop_sidebar_click(const EventRecord *event, Point local)
{
    int i;

    if (g_owner == NULL) {
        return false;
    }
    /* The scroll bar first: it sits inside the panel, so a row hit test
       would otherwise claim its clicks. */
    if (g_scroll != NULL && g_lay.rail_scrolls
        && PtInRect(local, &g_lay.nav_scroll)) {
        ControlRef hit = NULL;
        ControlPartCode part = FindControl(local, g_owner, &hit);

        if (hit == g_scroll) {
            if (part == kControlIndicatorPart) {
                /* The thumb tracks as an outline and reports at release;
                   the Control Manager calls no action proc for it, which
                   is why this one is NULL rather than unpumped by
                   oversight. */
                if (TrackControl(g_scroll, local, NULL) != 0) {
                    scroll_to(GetControlValue(g_scroll));
                }
            } else {
                TrackControl(g_scroll, local, g_scroll_action_upp);
            }
            return true;
        }
    }

    for (i = 0; i < visible_slots(); ++i) {
        WorkshopModuleID module = module_at_slot((short)i);

        if (module == (WorkshopModuleID)0
            || !PtInRect(local, &g_lay.nav_rows[i])) {
            continue;
        }
        if ((event->modifiers & optionKey) != 0) {
            drag_row((short)(g_scroll_top + i), local);
            return true;              /* a rearrange never also selects */
        }
        if (module != g_selected && g_on_select != NULL) {
            g_on_select(module);
        }
        return true;
    }

    /* The pinned group is not rearrangeable, so Option means nothing on
       it and it is an ordinary click. */
    {
        const WorkshopModuleID pinned[3] = {
            kWorkshopPreferences, kWorkshopLogs, kWorkshopConnection
        };

        for (i = 0; i < 3; ++i) {
            const Rect *r = row_rect(pinned[i]);

            if (r != NULL && PtInRect(local, r)) {
                if (pinned[i] != g_selected && g_on_select != NULL) {
                    g_on_select(pinned[i]);
                }
                return true;
            }
        }
    }
    return PtInRect(local, &g_lay.rail_list);
}

/* The arrows walk the rail as SEEN - the person's arrangement, then the
   pinned group - not the enum. Before rearranging existed the two were
   the same thing. */
static short visual_index(WorkshopModuleID module)
{
    if (module == kWorkshopPreferences) {
        return kWorkshopNavRows;
    }
    if (module == kWorkshopLogs) {
        return (short)(kWorkshopNavRows + 1);
    }
    if (module == kWorkshopConnection) {
        return (short)(kWorkshopNavRows + 2);
    }
    return nav_pos(module);
}

static WorkshopModuleID module_at_visual(short index)
{
    if (index < 0 || index >= kWorkshopModuleCount) {
        return (WorkshopModuleID)0;
    }
    if (index < kWorkshopNavRows) {
        return g_order[index];
    }
    switch (index - kWorkshopNavRows) {
    case 0:
        return kWorkshopPreferences;
    case 1:
        return kWorkshopLogs;
    default:
        return kWorkshopConnection;
    }
}

Boolean workshop_sidebar_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    short here;
    short next;
    WorkshopModuleID module;

    if (g_owner == NULL) {
        return false;
    }
    here = visual_index(g_selected);
    if (here < 0) {
        return false;
    }
    if (c == 0x1E) {              /* up arrow charCode */
        next = (short)(here - 1);
    } else if (c == 0x1F) {       /* down arrow charCode */
        next = (short)(here + 1);
    } else {
        return false;
    }
    if (next < 0 || next >= kWorkshopModuleCount) {
        return true;              /* consumed; the list does not wrap */
    }
    module = module_at_visual(next);
    if (module != (WorkshopModuleID)0 && g_on_select != NULL) {
        g_on_select(module);
    }
    return true;
}

void workshop_sidebar_activate(Boolean active)
{
    if (g_owner == NULL || active == g_active) {
        return;
    }
    g_active = active;
    /* The bar is a real control and must go grey with the window like
       any other; the hand-drawn rows follow g_active in selection_color.
       Guarded on a CHANGE by the early return above, because both calls
       redraw whatever they are passed. */
    if (g_scroll != NULL) {
        if (active) {
            ActivateControl(g_scroll);
        } else {
            DeactivateControl(g_scroll);
        }
    }
    InvalWindowRect(g_owner, &g_lay.rail_list);
}

void workshop_sidebar_idle(void)
{
    ConnSnapshot snap;
    char detail[96];

    if (g_owner == NULL) {
        return;
    }
    /* Short, purpose-built words: the row is narrow, and a truncated
       status line reads worse than a plain one. */
    conn_snapshot(&snap);
    switch (snap.phase) {
    case kConnConnected:
        if (snap.peer_name[0] != '\0') {
            snprintf(detail, sizeof detail, "%.40s", snap.peer_name);
        } else {
            strcpy(detail, "Connected");
        }
        break;
    case kConnConnecting:
    case kConnHandshaking:
        strcpy(detail, "Connecting...");
        break;
    case kConnBackoff:
        snprintf(detail, sizeof detail, "Retry in %ld s",
                 snap.retry_in_secs);
        break;
    case kConnNeedsCarbonLib:
        strcpy(detail, "No CarbonLib 1.6");
        break;
    default:
        strcpy(detail, "No link");
        break;
    }
    if (snap.phase == g_shown_phase
        && strcmp(detail, g_shown_detail) == 0) {
        return;
    }
    g_shown_phase = snap.phase;
    strcpy(g_shown_detail, detail);
    InvalWindowRect(g_owner, &g_lay.conn_row);
}

void workshop_sidebar_set_selection(WorkshopModuleID module)
{
    short pos;

    if (g_owner == NULL || module == g_selected || (int)module < 1
        || (int)module > kWorkshopModuleCount) {
        return;
    }
    inval_row(g_selected);            /* NULL-safe: it may be scrolled away */
    g_selected = module;
    /* Selecting a row that is not on screen - from the View menu, from
       the arrows, or from a restored session - scrolls it into view
       rather than highlighting something nobody can see. */
    pos = nav_pos(module);
    if (pos >= 0) {
        reveal_pos(pos);
    }
    inval_row(module);
}
