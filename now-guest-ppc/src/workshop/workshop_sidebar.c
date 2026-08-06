#include "workshop_sidebar.h"
#include "control_kind.h"

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
    kPreferencesIconID = 142,
    kMirrorIconID = 143
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
static Boolean g_collapsed;
static short g_scroll_top;

/* The hand-drawn help tag for a collapsed icon.

   Carbon's Help Manager on this toolchain offers only HELP TAGS
   (HMSetControlHelpContent / HMDisplayTag) - the classic HMShowBalloon
   is not in these headers at all - and help tags are a Mac OS X
   facility: under Mac OS 9 with CarbonLib nothing displays them. Wiring
   them would have shipped a feature that is invisible on every machine
   this app runs on, so the tag is drawn here, by the same hand that
   draws every other pixel in this rail.

   It is armed from idle, which must stay free: the work per pass is one
   GetMouse and two comparisons, and nothing is drawn unless the row
   under the pointer actually changed. */
static WorkshopModuleID g_tag_module;   /* 0 = no tag showing */
static Rect g_tag_rect;                 /* what to invalidate to take it back */
static Point g_tag_mouse;               /* where the pointer was last seen */
static short g_tag_dwell;               /* passes it has rested there */

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
    { "Mirror", "Its extensions and agent", kMirrorIconID },
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
    prefs.sidebar_collapsed = g_collapsed;
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

static void draw_nav_rows(void);

/* Scrolling moves which module each slot shows; the slots themselves do
   not move, so nothing is relaid out - the nav area is simply repainted
   with a different stretch of the list in it.

   It repaints DIRECTLY rather than invalidating, because the live scroll
   bar calls this from inside TrackControl: an invalidation would not be
   serviced until the tracking loop returned, so the rail would sit frozen
   under a moving thumb and jump at the drop. Immediate feedback during
   tracking is the documented exception to update-event ownership, and
   the drawing is the same function the update path calls, so the next
   ordinary update reproduces it from the same state. */
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
    if (g_owner != NULL) {
        SetPortWindowPort(g_owner);
        draw_nav_rows();
    }
}

static pascal void scroll_action(ControlRef control, ControlPartCode part)
{
    short page = (short)(visible_slots() - 1);
    short delta = 0;

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
    case kControlIndicatorPart:
        /* The live variant calls the action proc for the thumb too, which
           the plain scrollBarProc never did - that is what makes the list
           follow the thumb instead of jumping at the drop. */
        scroll_to(GetControlValue(control));
        now_wire_pump();
        return;
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

/* Where the bar lives, INCLUDING when the layout says there is none.

   The layout reports an empty nav_scroll while everything fits, which is
   the honest description of "no bar" - but a control must never be
   CREATED at an empty rectangle. The live CDEF will not render a bar
   that was born 0x0 and resized later: it appeared on a relaunch into a
   small window and stayed invisible when the same window was dragged
   down to the same size, which is the difference between the two paths.
   (The plain scrollBarProc tolerated it, which is why this only showed
   up when the CDEF changed.) So creation uses a real strip and
   visibility is Show/Hide's business, where it belongs. */
static void scroll_bar_rect(Rect *out)
{
    if (g_lay.rail_scrolls) {
        *out = g_lay.nav_scroll;
        return;
    }
    *out = g_lay.nav_rows[0];
    out->left = (short)(out->right - kWorkshopRailScrollWidth);
    out->bottom = g_lay.nav_rows[visible_slots() - 1].bottom;
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
        Rect bar;

        scroll_bar_rect(&bar);
        MoveControl(g_scroll, bar.left, bar.top);
        SizeControl(g_scroll, (short)(bar.right - bar.left),
                    (short)(bar.bottom - bar.top));
        SetControlMaximum(g_scroll, max_scroll());
        SetControlValue(g_scroll, g_scroll_top);
        /* The thumb's SIZE, in the same units as the value: how many rows
           the bar can see out of the whole list. The Appearance scroll
           bar draws the indicator proportionally from this - a rail one
           row short of fitting gets a nearly full-length thumb, which is
           the honest picture of how little there is to scroll.

           Whether it is DRAWN proportionally is the system's call, not
           ours: Smart Scrolling is a control-panel setting, and with it
           off the thumb is a fixed block. Setting the view size is
           correct either way, and deliberately does not second-guess the
           person's setting. */
        SetControlViewSize(g_scroll, visible_slots());
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
    g_collapsed = prefs.sidebar_collapsed;
    order_adopt(prefs.sidebar_order);
    g_scroll_top = 0;
}

void workshop_sidebar_rail_spec(WorkshopRailSpec *out)
{
    if (out == NULL) {
        return;
    }
    /* An unseeded rail is the rich, expanded, unscrolled, enum-ordered
       one - the shape this window had before any of it was a choice. */
    out->compact = g_compact;
    out->collapsed = g_collapsed;
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
    Rect bar;

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
    /* The LIVE variant, not scrollBarProc: it is the one that takes a
       view size for a proportional thumb, and the one that calls the
       action proc while the thumb moves. Already proven to compile and
       run here by network_module.c, whose bar is the same CDEF.
       SetControlViewSize is CarbonLib 1.0 and later, well under this
       app's 1.6 floor. */
    scroll_bar_rect(&bar);
    g_scroll = now_control_new(owner, &bar, empty, false, 0, 0, 0,
                          kControlScrollBarLiveProc, 0);
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

/* One definition of what the link's colour means, read by both the
   expanded row and the collapsed one. Two copies of this switch is
   exactly how a lamp ends up green in one state and amber in the other. */
static void connection_lamp_color(RGBColor *out)
{
    switch (g_shown_phase) {
    case kConnConnected:
        out->red = 0x0000;
        out->green = 0xAAAA;
        out->blue = 0x2222;
        break;
    case kConnConnecting:
    case kConnHandshaking:
    case kConnBackoff:
        out->red = 0xFFFF;
        out->green = 0x9999;
        out->blue = 0x0000;
        break;
    default:
        out->red = 0xCCCC;
        out->green = 0x2222;
        out->blue = 0x2222;
        break;
    }
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

    /* Collapsed: the band, the icon centred in it, and nothing else. The
       lamp still rides on Connection, because the one thing a person
       needs from a collapsed rail at a glance is whether the link is up -
       that is the whole reason the row is pinned in the first place. */
    if (g_collapsed) {
        Rect icon;

        if (module == g_selected) {
            RGBColor band;

            selection_color(&band);
            RGBForeColor(&band);
            PaintRect(r);
            RGBForeColor(&black);
        }
        SetRect(&icon, (short)((r->left + r->right - kIconSize) / 2),
                (short)((r->top + r->bottom - kIconSize) / 2),
                (short)((r->left + r->right + kIconSize) / 2),
                (short)((r->top + r->bottom + kIconSize) / 2));
        plot_small_icon(k_rows[module].icon_id, &icon);
        if (module == kWorkshopConnection) {
            Rect lamp;
            RGBColor lamp_color;

            connection_lamp_color(&lamp_color);
            SetRect(&lamp, (short)(r->right - 4 - kLampSize / 2),
                    (short)(r->top + 3),
                    (short)(r->right - 4 + kLampSize / 2),
                    (short)(r->top + 3 + kLampSize));
            RGBForeColor(&lamp_color);
            PaintOval(&lamp);
            RGBForeColor(&black);
            FrameOval(&lamp);
        }
        return;
    }

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
        connection_lamp_color(&lamp_color);
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

/* Every visible slot, white ground and all. The ONE place the nav list
   is painted: the update path calls it, and so does scroll_to during
   live tracking, so a scrolled rail and a redrawn one cannot disagree.
   Which module a slot holds is the person's order and the scroll
   position, never the enum. */
static void draw_nav_rows(void)
{
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    Rect area;
    short i;

    /* The rows do not tile their own background - a shorter list after a
       scroll to the end would leave the last row's pixels behind. */
    area = g_lay.nav_rows[0];
    area.bottom = g_lay.nav_rows[visible_slots() - 1].bottom;
    GetBackColor(&saved_back);
    RGBBackColor(&white);
    EraseRect(&area);
    RGBBackColor(&saved_back);

    for (i = 0; i < visible_slots(); ++i) {
        WorkshopModuleID module = module_at_slot(i);

        if (module != (WorkshopModuleID)0) {
            draw_row_in(module, &g_lay.nav_rows[i]);
        }
    }
}

/* ---- the collapsed rail's help tag --------------------------------- */

/* Takes back whatever the tag covered. It is drawn OUTSIDE the rail, over
   the module's own pixels, so hiding it is an invalidation rather than an
   erase: the page underneath - controls included - repaints itself. */
static void hide_tag(void)
{
    if (g_tag_module == (WorkshopModuleID)0) {
        return;
    }
    g_tag_module = (WorkshopModuleID)0;
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_tag_rect);
    }
}

/* The classic help-tag look: pale yellow, one-pixel black frame, small
   system font, sitting to the RIGHT of the icon it explains. */
static void draw_tag(void)
{
    RGBColor cream = { 0xFFFF, 0xFFFF, 0xCCCC };
    RGBColor black = { 0, 0, 0 };
    RGBColor saved_back;
    Str255 text;

    if (g_tag_module == (WorkshopModuleID)0 || g_owner == NULL) {
        return;
    }
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    CopyCStringToPascal(k_rows[g_tag_module].title, text);

    GetBackColor(&saved_back);
    RGBBackColor(&cream);
    EraseRect(&g_tag_rect);
    RGBBackColor(&saved_back);
    RGBForeColor(&black);
    FrameRect(&g_tag_rect);
    MoveTo((short)(g_tag_rect.left + 5), (short)(g_tag_rect.top + 12));
    DrawString(text);
}

/* Where a tag for this row would sit, and how big. Kept beside the draw
   so the rectangle the tag is ERASED by is the one it was drawn in. */
static void tag_rect_for(WorkshopModuleID module, const Rect *row, Rect *out)
{
    short w;

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    {
        Str255 text;

        CopyCStringToPascal(k_rows[module].title, text);
        w = (short)(StringWidth(text) + 10);
    }
    out->left = (short)(g_lay.sidebar.right + 4);
    out->top = (short)(row->top + 2);
    out->right = (short)(out->left + w);
    out->bottom = (short)(out->top + 16);
}

void workshop_sidebar_draw(void)
{
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    Pattern gray;

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

    draw_nav_rows();
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

/* The row being dragged, as a gray outline that follows the pointer -
   the same feedback Mac OS gives for a dragged window, and the reason
   DragGrayRgn exists. Gray pattern in XOR so the frame is the classic
   dotted one and a second draw in the same place erases it exactly,
   whatever it was drawn over.

   Clamped to the nav list: an outline free to wander would XOR over the
   pinned group and the window frame, and a person dragging a row is
   never trying to drop it on Connection. */
static void toggle_drag_outline(short top)
{
    Rect frame;
    Pattern gray;
    short row_h = g_lay.row_height;
    short lo = g_lay.nav_rows[0].top;
    short hi = (short)(g_lay.nav_rows[visible_slots() - 1].bottom - row_h);

    if (top < lo) {
        top = lo;
    }
    if (top > hi) {
        top = hi;
    }
    SetRect(&frame, g_lay.nav_rows[0].left, top, g_lay.nav_rows[0].right,
            (short)(top + row_h));
    GetQDGlobalsGray(&gray);
    PenPat(&gray);
    PenMode(patXor);
    FrameRect(&frame);
    PenNormal();
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
    short slot = (short)(from_pos - g_scroll_top);
    short grab = (short)(start.v - g_lay.nav_rows[slot].top);
    short shown_pos = -1;             /* insertion line, -1 = none drawn */
    short shown_top = 0;              /* outline, valid while shown_pos >= 0 */
    Boolean armed = false;

    while (StillDown()) {
        Point now_pt;
        short want_pos;
        short want_top;

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
        want_pos = drop_pos(now_pt);
        want_top = (short)(now_pt.v - grab);
        if (shown_pos >= 0 && want_pos == shown_pos && want_top == shown_top) {
            continue;                 /* nothing moved; do not redraw */
        }
        /* Erase both, then draw both. Erasing first matters: the outline
           and the line can overlap, and XOR feedback only cancels when it
           is undone in the state it was drawn in. */
        if (shown_pos >= 0) {
            toggle_drop_line(shown_pos);
            toggle_drag_outline(shown_top);
        }
        toggle_drag_outline(want_top);
        toggle_drop_line(want_pos);
        shown_pos = want_pos;
        shown_top = want_top;
    }
    if (shown_pos >= 0) {
        toggle_drop_line(shown_pos);  /* erase before anything repaints */
        toggle_drag_outline(shown_top);
    }
    if (!armed || shown_pos < 0) {
        return;                       /* an Option-click that never moved */
    }
    order_move(from_pos, shown_pos);
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

        /* The part is not needed any more - one TrackControl serves every
           part of a live bar - but FindControl still has to run to learn
           WHICH control was hit. */
        (void)FindControl(local, g_owner, &hit);
        if (hit == g_scroll) {
            /* One call for every part, thumb included. With the plain
               scrollBarProc the indicator had to be tracked with a NULL
               action and read at release, because the Control Manager
               called no action proc for it; the LIVE variant does, so the
               same proc drives arrows, pages and thumb - and the wire is
               pumped for all three instead of stopping for the one a
               finger rests on longest. */
            TrackControl(g_scroll, local, g_scroll_action_upp);
            scroll_to(GetControlValue(g_scroll));  /* settle on release */
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

/* Runs every pass, so it costs one GetMouse and two comparisons unless
   the answer actually changed. Only a COLLAPSED rail has anything to
   explain - expanded rows carry their own names. */
void workshop_sidebar_tag_idle(void)
{
    Point where;
    WorkshopModuleID over = (WorkshopModuleID)0;
    short i;

    if (g_owner == NULL || !g_collapsed) {
        hide_tag();
        return;
    }
    if (FrontWindow() != g_owner) {
        hide_tag();               /* a background window explains nothing */
        return;
    }
    SetPortWindowPort(g_owner);
    GetMouse(&where);
    if (where.h != g_tag_mouse.h || where.v != g_tag_mouse.v) {
        g_tag_mouse = where;
        g_tag_dwell = 0;
        hide_tag();               /* moving means the old tag is stale */
        return;
    }
    if (g_tag_module != (WorkshopModuleID)0) {
        return;                   /* already explaining this one */
    }
    /* Rest before speaking. Roughly a third of a second of event-loop
       passes, which is the era's own tag delay and, more to the point,
       stops a tag flashing at every icon a pointer crosses on its way
       somewhere else. */
    if (g_tag_dwell < 20) {
        ++g_tag_dwell;
        return;
    }
    for (i = 0; i < visible_slots(); ++i) {
        if (PtInRect(where, &g_lay.nav_rows[i])) {
            over = module_at_slot(i);
            break;
        }
    }
    if (over == (WorkshopModuleID)0) {
        const WorkshopModuleID pinned[3] = {
            kWorkshopPreferences, kWorkshopLogs, kWorkshopConnection
        };

        for (i = 0; i < 3; ++i) {
            const Rect *r = row_rect(pinned[i]);

            if (r != NULL && PtInRect(where, r)) {
                over = pinned[i];
                break;
            }
        }
    }
    if (over == (WorkshopModuleID)0) {
        return;
    }
    {
        const Rect *row = row_rect(over);

        if (row == NULL) {
            return;
        }
        tag_rect_for(over, row, &g_tag_rect);
    }
    g_tag_module = over;
    draw_tag();
}

Boolean workshop_sidebar_collapsed(void)
{
    return g_collapsed;
}

void workshop_sidebar_set_collapsed(Boolean collapsed)
{
    if (collapsed == g_collapsed) {
        return;
    }
    hide_tag();                   /* it belongs to the state being left */
    g_collapsed = collapsed;
    g_tag_dwell = 0;
    order_persist();
    /* The rail's WIDTH changes, so every module's body rect changes with
       it - this is the window's to redo, not the rail's. */
    if (g_on_relayout != NULL) {
        g_on_relayout();
    }
}

/* The collapse button: a small bevel button in the header's left edge,
   pointing the way the rail will go. Guillemets are MacRoman C7/C8, so
   they are safe through DrawString - a UTF-8 arrow would be mojibake. */
void workshop_sidebar_draw_toggle(void)
{
    Str255 text;
    Rect r = g_lay.rail_toggle;
    ThemeButtonDrawInfo info;

    if (g_owner == NULL) {
        return;
    }
    /* A real draw info, not NULL: with no state to render, DrawThemeButton
       draws no bevel at all and the glyph sits bare on the placard. */
    info.state = g_active ? kThemeStateActive : kThemeStateInactive;
    info.value = kThemeButtonOff;
    info.adornment = kThemeAdornmentNone;
    DrawThemeButton(&r, kThemeSmallBevelButton, &info, NULL, NULL, NULL, 0);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    text[0] = 1;
    text[1] = g_collapsed ? 0xC8 : 0xC7;      /* » expands, « collapses */
    MoveTo((short)((r.left + r.right - StringWidth(text)) / 2),
           (short)(r.top + 12));
    DrawString(text);
}

Boolean workshop_sidebar_toggle_click(Point local)
{
    if (g_owner == NULL || !PtInRect(local, &g_lay.rail_toggle)) {
        return false;
    }
    /* Tracked by hand rather than with a control, because this button is
       drawn by hand: the header placard is ours, and a real control there
       would be the only one in the window not owned by a module. */
    workshop_sidebar_set_collapsed((Boolean)!g_collapsed);
    return true;
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

void workshop_sidebar_describe_scene(const WorkshopSceneWriter *writer)
{
    int i;

    if (g_owner == NULL) {
        return;
    }
    /* The rail's manually drawn structure is still structure.  Carry the
       panel, selection and text as data; only the 16x16 resource art is an
       explicit visual placeholder at this stage. */
    workshop_scene_add(writer, kWorkshopScenePanel, "",
                       &g_lay.rail_list, true);
    workshop_scene_add(writer, kWorkshopSceneSeparator, "",
                       &g_lay.conn_divider, true);
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        WorkshopModuleID module = (WorkshopModuleID)i;
        const Rect *row = row_rect(module);
        Rect icon;
        Rect title;
        Rect subtitle;
        const char *detail = k_rows[module].subtitle;

        if (module == g_selected) {
            workshop_scene_add(writer, kWorkshopSceneSelectionBand, "",
                               row, true);
        }
        SetRect(&icon, (short)(row->left + kIconInset),
                (short)((row->top + row->bottom - kIconSize) / 2),
                (short)(row->left + kIconInset + kIconSize),
                (short)((row->top + row->bottom - kIconSize) / 2
                        + kIconSize));
        workshop_scene_add(writer, kWorkshopSceneIcon,
                           k_rows[module].title, &icon, true);

        SetRect(&title, (short)(icon.right + kTextGap),
                (short)(row->top + 3), (short)(row->right - 4),
                (short)(row->top + 16));
        workshop_scene_add(writer, kWorkshopSceneStaticText,
                           k_rows[module].title, &title, true);

        if (module == kWorkshopConnection) {
            detail = g_shown_detail[0] != '\0' ? g_shown_detail : "No link";
        }
        if (detail != NULL) {
            SetRect(&subtitle, title.left, (short)(row->top + 15),
                    title.right, (short)(row->top + 29));
            workshop_scene_add(writer, kWorkshopSceneStaticText, detail,
                               &subtitle, true);
        }
    }
}
