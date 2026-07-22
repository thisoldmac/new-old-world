#include "workshop_sidebar.h"

#include <stdio.h>
#include <string.h>

#include "wire.h"

/* The rail is one framed white panel drawn by hand: icon, bold title,
   quiet subtitle per row, Connection pinned at the bottom behind a
   divider with the status lamp. A Data Browser cannot pin a row or
   draw two-line cells without custom-callback territory this CarbonLib
   has not proved, and the Console's hand-drawn scrollback set the
   precedent for an owned view; system look comes from the theme fonts
   and the system highlight color, not from imitation chrome. */

enum {
    kIconInset = 8,           /* panel edge to icon */
    kIconSize = 16,
    kTextGap = 6,             /* icon to text */
    kTitleBaseline = 13,      /* within a row */
    kSubtitleBaseline = 25,
    kLampSize = 8,

    kScreenshotsIconID = 129,
    kFilesIconID = 130,
    kConsoleIconID = 131,
    kConnectionIconID = 132,
    kProcessesIconID = 133,
    kHardwareIconID = 134,
    kLogsIconID = 135
};

static WindowRef g_owner;
static WorkshopLayout g_lay;
static WorkshopSidebarSelectFn g_on_select;
static WorkshopModuleID g_selected = kWorkshopScreenshots;
static Boolean g_active = true;

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
    { "Logs", "This launch's events", kLogsIconID },
    { "Connection", NULL, kConnectionIconID }
};

static const Rect *row_rect(WorkshopModuleID module)
{
    if (module == kWorkshopConnection) {
        return &g_lay.conn_row;
    }
    if (module == kWorkshopLogs) {
        return &g_lay.logs_row;       /* pinned above Connection */
    }
    return &g_lay.nav_rows[module - 1];
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

Boolean workshop_sidebar_create(WindowRef owner, const WorkshopLayout *lay,
                                WorkshopSidebarSelectFn on_select)
{
    g_owner = owner;
    g_lay = *lay;
    g_on_select = on_select;
    g_selected = kWorkshopScreenshots;
    g_active = true;
    g_shown_phase = (ConnPhase)-1;
    g_shown_detail[0] = '\0';
    return true;
}

void workshop_sidebar_dispose(void)
{
    g_owner = NULL;
    g_on_select = NULL;
}

void workshop_sidebar_layout(const WorkshopLayout *lay)
{
    g_lay = *lay;
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

static void draw_row(WorkshopModuleID module)
{
    const Rect *r = row_rect(module);
    Rect icon_rect;
    Str255 text;
    RGBColor black = { 0, 0, 0 };
    RGBColor gray = { 0x5555, 0x5555, 0x5555 };
    short text_left;
    short text_width;

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
    MoveTo(text_left, (short)(r->top + kTitleBaseline));
    CopyCStringToPascal(k_rows[module].title, text);
    TruncString(text_width, text, truncEnd);
    DrawString(text);

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
        MoveTo(text_left, (short)(r->top + kSubtitleBaseline));
        CopyCStringToPascal(detail, text);
        TruncString(text_width, text, truncMiddle);
        DrawString(text);
        RGBForeColor(&black);
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

    /* The panel: white ground behind every row, framed like a list. */
    GetBackColor(&saved_back);
    RGBBackColor(&white);
    EraseRect(&g_lay.rail_list);
    RGBBackColor(&saved_back);
    FrameRect(&g_lay.rail_list);

    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        draw_row((WorkshopModuleID)i);
    }

    GetQDGlobalsGray(&gray);
    PenPat(&gray);
    PaintRect(&g_lay.conn_divider);
    PenNormal();
}

Boolean workshop_sidebar_click(const EventRecord *event, Point local)
{
    int i;

    (void)event;
    if (g_owner == NULL) {
        return false;
    }
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        if (PtInRect(local, row_rect((WorkshopModuleID)i))) {
            if ((WorkshopModuleID)i != g_selected && g_on_select != NULL) {
                g_on_select((WorkshopModuleID)i);
            }
            return true;
        }
    }
    return PtInRect(local, &g_lay.rail_list);
}

Boolean workshop_sidebar_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    int next = (int)g_selected;

    if (g_owner == NULL) {
        return false;
    }
    if (c == 0x1E) {              /* up arrow charCode */
        --next;
    } else if (c == 0x1F) {       /* down arrow charCode */
        ++next;
    } else {
        return false;
    }
    if (next < 1 || next > kWorkshopModuleCount) {
        return true;              /* consumed; the list does not wrap */
    }
    if (g_on_select != NULL) {
        g_on_select((WorkshopModuleID)next);
    }
    return true;
}

void workshop_sidebar_activate(Boolean active)
{
    if (g_owner == NULL || active == g_active) {
        return;
    }
    g_active = active;
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
    const Rect *old_row;

    if (g_owner == NULL || module == g_selected || (int)module < 1
        || (int)module > kWorkshopModuleCount) {
        return;
    }
    old_row = row_rect(g_selected);
    g_selected = module;
    InvalWindowRect(g_owner, old_row);
    InvalWindowRect(g_owner, row_rect(module));
}
