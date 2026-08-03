#include "software_module.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "proc_actions.h"
#include "software.h"
#include "software_layout.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"

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
static ControlRef g_front;
static ControlRef g_quit;
static ControlRef g_reveal;
static ControlRef g_rescan;
static Boolean g_browser_ok;
/* Button caches: hilite and shown state re-asserted only on change, so
   a selection change never flickers a control it does not alter. */
static short g_launch_hilite = -1;
static short g_reveal_hilite = -1;
static short g_launch_shown = -1;
static short g_front_shown = -1;
static short g_quit_shown = -1;

static DataBrowserItemDataUPP g_data_upp;
static DataBrowserItemNotificationUPP g_notify_upp;
static DataBrowserItemCompareUPP g_compare_upp;
/* Set while rebuilding the browser: RemoveDataBrowserItems fires a
   deselect for the selected row, whose notification would otherwise
   clobber the domain's selection mid-rebuild. */
static Boolean g_in_rebuild;

/* Duplicate groups, recomputed with the browser's contents: items
   sharing a name (case-folded) collapse under a closed container row.
   Parent rows live in their own item-id range, above any item index. */
#define kGroupIdBase 0x00010000UL
static short g_sorted[kSwMaxCap];     /* item indices, name order */
static short g_group_of[kSwMaxCap];   /* item -> group id, -1 = alone */
static short g_group_first[kSwMaxCap / 2];   /* gid -> pos in g_sorted */
static short g_group_size[kSwMaxCap / 2];
static int g_group_count;

/* What the browser holds right now - the diff base for the keystroke
   refilter, which adds and removes only the rows whose match CHANGED
   instead of rebuilding the list (the rebuild repainted the whole
   module per keystroke; redraw-and-damage.md calls that out). */
static unsigned char g_in_view[kSwMaxCap];
static unsigned char g_parent_in_view[kSwMaxCap / 2];

/* The selected item's full path, computed on selection change - never
   in draw, which must not touch the catalog. */
static char g_sel_path[224];

/* The person's chosen list width; 0 = the layout's default. Session
   state, like the sidebar selection - not worth a prefs field yet. */
static short g_split_w;

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

static void invalidate_detail(void)
{
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_lay.detail);
    }
}

static void refresh_sel_path(void)
{
    DomainState *d = dom();

    g_sel_path[0] = '\0';
    if (d->sel >= 0 && d->sel < d->count) {
        now_software_full_path(&d->items[d->sel].spec, g_sel_path,
                               sizeof g_sel_path);
    }
}

static void show_or_hide(ControlRef c, short *shown, short want)
{
    if (c == NULL || *shown == want) {
        return;
    }
    *shown = want;
    if (!g_visible) {
        return;
    }
    if (want) {
        ShowControl(c);
    } else {
        HideControl(c);
    }
}

/* The action row follows the selection: a dead app offers Launch, a
   running one Bring to Front / Quit (Launch shares Front's slot -
   they are never true together), and Show in Finder follows any
   selection at all. Caches keep un-changed controls untouched. */
static void sync_buttons(void)
{
    DomainState *d = dom();
    Boolean have = d->sel >= 0 && d->sel < d->count;
    Boolean running = have && d->items[d->sel].running;
    Boolean launchable = have && !running
        && (unsigned long)d->items[d->sel].type == kTypeAppl;
    short want;

    show_or_hide(g_launch, &g_launch_shown, (short)!running);
    show_or_hide(g_front, &g_front_shown, (short)running);
    show_or_hide(g_quit, &g_quit_shown, (short)running);

    want = launchable ? 0 : 255;
    if (g_launch != NULL && want != g_launch_hilite) {
        HiliteControl(g_launch, want);
        g_launch_hilite = want;
    }
    want = have ? 0 : 255;
    if (g_reveal != NULL && want != g_reveal_hilite) {
        HiliteControl(g_reveal, want);
        g_reveal_hilite = want;
    }
}

/* --- duplicate groups ---------------------------------------------------- */

static const SwPageItem *g_cmp_items;   /* qsort has no context arg */

static int cmp_by_name(const void *pa, const void *pb)
{
    short a = *(const short *)pa;
    short b = *(const short *)pb;
    const unsigned char *na = g_cmp_items[a].name;
    const unsigned char *nb = g_cmp_items[b].name;
    int len = na[0] < nb[0] ? na[0] : nb[0];
    int i;

    for (i = 1; i <= len; ++i) {
        char ca = (char)na[i], cb = (char)nb[i];

        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) {
            return ca < cb ? -1 : 1;
        }
    }
    if (na[0] != nb[0]) {
        return na[0] < nb[0] ? -1 : 1;
    }
    return a - b;                      /* stable for equal names */
}

static Boolean same_name(const SwPageItem *a, const SwPageItem *b)
{
    return EqualString(a->name, b->name, false, true);
}

/* Group items sharing a name. ASCII case-folded sort brings HFS-equal
   names adjacent (HFS compare is case-insensitive too); runs of two or
   more become one container. */
static void compute_groups(void)
{
    DomainState *d = dom();
    int i;

    g_group_count = 0;
    for (i = 0; i < d->count; ++i) {
        g_sorted[i] = (short)i;
        g_group_of[i] = -1;
    }
    if (d->count < 2) {
        return;
    }
    g_cmp_items = d->items;
    qsort(g_sorted, (size_t)d->count, sizeof g_sorted[0], cmp_by_name);
    i = 0;
    while (i < d->count) {
        int j = i + 1;

        while (j < d->count
               && same_name(&d->items[g_sorted[i]],
                            &d->items[g_sorted[j]])) {
            ++j;
        }
        if (j - i >= 2 && g_group_count < kSwMaxCap / 2) {
            int gid = g_group_count++;
            int k;

            g_group_first[gid] = (short)i;
            g_group_size[gid] = (short)(j - i);
            for (k = i; k < j; ++k) {
                g_group_of[g_sorted[k]] = (short)gid;
            }
        }
        i = j;
    }
}

/* One group's children, added under its container row. Shared by the
   rebuild and by kDataBrowserContainerOpened: closing a container
   REMOVES its children (the Data Browser's own behavior), so every
   reopen must put them back - the caret flipping over an empty group
   was the first metal report of this round. */
static void add_group_children(int gid)
{
    DataBrowserItemID kids[kSwMaxCap];
    UInt32 nk = 0;
    int k;

    if (g_browser == NULL || gid < 0 || gid >= g_group_count) {
        return;
    }
    for (k = 0; k < g_group_size[gid]; ++k) {
        kids[nk++] = (DataBrowserItemID)(
            g_sorted[g_group_first[gid] + k] + 1);
    }
    AddDataBrowserItems(g_browser,
                        (DataBrowserItemID)(kGroupIdBase + gid),
                        nk, kids, kDataBrowserItemNoProperty);
}

/* Repopulate the browser from the current domain's cache: filtered,
   duplicates collapsed under closed containers. The ONLY list-wide
   operation, and it runs on user intent or once at sweep end - never
   per arriving item; the third metal round's flashing was the batched
   sorted inserts this replaces. */
static void rebuild_browser(void)
{
    DataBrowserItemID roots[kSwMaxCap];
    DomainState *d = dom();
    char needle[48];
    UInt32 n_roots = 0;
    int shown = 0;
    int i;

    if (g_browser == NULL) {
        return;
    }
    compute_groups();
    lower_needle(needle, sizeof needle);
    g_in_rebuild = true;
    RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    memset(g_in_view, 0, sizeof g_in_view);
    memset(g_parent_in_view, 0, sizeof g_parent_in_view);
    for (i = 0; i < d->count; ++i) {
        int idx = g_sorted[i];
        int gid = g_group_of[idx];

        if (!name_matches(&d->items[idx], needle)) {
            continue;
        }
        shown += 1;
        if (gid < 0) {
            roots[n_roots++] = (DataBrowserItemID)(idx + 1);
            g_in_view[idx] = 1;
        } else if (i == g_group_first[gid]) {
            roots[n_roots++] = (DataBrowserItemID)(kGroupIdBase + gid);
            g_parent_in_view[gid] = 1;
        }
    }
    if (n_roots > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, n_roots, roots,
                            kDataBrowserItemNoProperty);
    }
    {
        int gid;

        for (gid = 0; gid < g_group_count; ++gid) {
            /* Members share the name, so the filter that admitted the
               parent admits every child. */
            if (g_parent_in_view[gid]) {
                add_group_children(gid);
            }
        }
    }
    g_shown_rows = shown;
    if (d->sel >= 0
        && !(d->sel < d->count
             && name_matches(&d->items[d->sel], needle))) {
        d->sel = -1;
    }
    if (d->sel < 0) {
        /* Land on the first ungrouped row, so the detail pane has
           something to say and the buttons something to act on. */
        for (i = 0; i < d->count; ++i) {
            int idx = g_sorted[i];

            if (g_group_of[idx] < 0
                && name_matches(&d->items[idx], needle)) {
                d->sel = idx;
                break;
            }
        }
    }
    if (d->sel >= 0) {
        DataBrowserItemID sel = (DataBrowserItemID)(d->sel + 1);

        SetDataBrowserSelectedItems(g_browser, 1, &sel,
                                    kDataBrowserItemsAssign);
    }
    g_in_rebuild = false;
    refresh_sel_path();
    sync_buttons();
    invalidate_detail();
}

/* The keystroke path: adjust the browser by DIFF - remove rows whose
   match ended, add rows whose match began - and touch the detail pane
   only if the selection itself changed. The full rebuild repaints the
   whole module and belongs to content changes (populate, domain
   switch, rescan), not to typing; component-level damage is the
   redraw contract's default. Group tables are untouched: the filter
   never changes the domain's contents. */
static void refilter_browser(void)
{
    DomainState *d = dom();
    char needle[48];
    int old_sel = d->sel;
    int i;

    if (g_browser == NULL) {
        return;
    }
    lower_needle(needle, sizeof needle);
    g_in_rebuild = true;
    for (i = 0; i < d->count; ++i) {
        DataBrowserItemID id = (DataBrowserItemID)(i + 1);
        Boolean want;

        if (g_group_of[i] >= 0) {
            continue;                  /* grouped: the parent decides */
        }
        want = name_matches(&d->items[i], needle);
        if (want && !g_in_view[i]) {
            AddDataBrowserItems(g_browser, kDataBrowserNoItem, 1, &id,
                                kDataBrowserItemNoProperty);
            g_in_view[i] = 1;
            g_shown_rows += 1;
        } else if (!want && g_in_view[i]) {
            RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 1, &id,
                                   kDataBrowserItemNoProperty);
            g_in_view[i] = 0;
            g_shown_rows -= 1;
        }
    }
    for (i = 0; i < g_group_count; ++i) {
        DataBrowserItemID pid = (DataBrowserItemID)(kGroupIdBase + i);
        Boolean want = name_matches(
            &d->items[g_sorted[g_group_first[i]]], needle);

        if (want && !g_parent_in_view[i]) {
            AddDataBrowserItems(g_browser, kDataBrowserNoItem, 1, &pid,
                                kDataBrowserItemNoProperty);
            add_group_children(i);
            g_parent_in_view[i] = 1;
            g_shown_rows += g_group_size[i];
        } else if (!want && g_parent_in_view[i]) {
            /* Children first, explicitly - no reliance on a container
               removal cascading - then the parent row. */
            RemoveDataBrowserItems(g_browser, pid, 0, NULL,
                                   kDataBrowserItemNoProperty);
            RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 1,
                                   &pid, kDataBrowserItemNoProperty);
            g_parent_in_view[i] = 0;
            g_shown_rows -= g_group_size[i];
        }
    }
    /* A selection whose row just left the view clears; one that stays
       needs nothing - the row was never removed. No auto-pick while
       typing: the detail changing under every keystroke was half the
       churn being fixed. */
    if (d->sel >= 0
        && !(d->sel < d->count
             && name_matches(&d->items[d->sel], needle))) {
        d->sel = -1;
    }
    g_in_rebuild = false;
    if (d->sel != old_sel) {
        refresh_sel_path();
        sync_buttons();
        invalidate_detail();
    }
}

static OSStatus set_text(DataBrowserItemDataRef data, const char *caption)
{
    CFStringRef text = CFStringCreateWithCString(NULL, caption,
                                                 kCFStringEncodingMacRoman);

    if (text == NULL) {
        return memFullErr;
    }
    SetDataBrowserItemDataText(data, text);
    CFRelease(text);
    return noErr;
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
    if (item >= kGroupIdBase
        && item < kGroupIdBase + (DataBrowserItemID)g_group_count) {
        /* A duplicate group's container row: the shared name, the
           member count where a version would be, aggregate size and
           state. Discloses, never selects (the divider pattern). */
        int gid = (int)(item - kGroupIdBase);
        int k;

        if (property == kDataBrowserItemIsContainerProperty) {
            SetDataBrowserItemDataBooleanValue(data, true);
            return noErr;
        }
        if (property == kDataBrowserItemIsSelectableProperty) {
            SetDataBrowserItemDataBooleanValue(data, false);
            return noErr;
        }
        switch (property) {
        case kColName: {
            const SwPageItem *first =
                &d->items[g_sorted[g_group_first[gid]]];
            long n = first->name[0] < 63 ? first->name[0] : 63;

            memcpy(caption, first->name + 1, (size_t)n);
            caption[n] = '\0';
            break;
        }
        case kColVersion:
            snprintf(caption, sizeof caption, "%d items",
                     g_group_size[gid]);
            break;
        case kColSize: {
            long total = 0;

            for (k = 0; k < g_group_size[gid]; ++k) {
                const SwPageItem *m =
                    &d->items[g_sorted[g_group_first[gid] + k]];

                if (m->size_k > 0) {
                    total += m->size_k;
                }
            }
            sw_size_text(total * 1024L, caption, sizeof caption);
            break;
        }
        case kColState: {
            Boolean any_running = false;

            for (k = 0; k < g_group_size[gid]; ++k) {
                if (d->items[g_sorted[g_group_first[gid] + k]].running) {
                    any_running = true;
                }
            }
            snprintf(caption, sizeof caption, "%s",
                     any_running ? "running" : "");
            break;
        }
        default:
            return errDataBrowserPropertyNotSupported;
        }
        return set_text(data, caption);
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
    (void)text;
    return set_text(data, caption);
}

static void item_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    DomainState *d = dom();

    /* Notifications fired by our own rebuild are not user intent. */
    if (g_in_rebuild) {
        return;
    }
    if (item >= kGroupIdBase) {
        /* Reopening a container must restore the children its close
           removed. The count check makes the re-add idempotent, so a
           spurious open notification cannot double the rows. */
        if (message == kDataBrowserContainerOpened) {
            UInt32 have = 0;

            GetDataBrowserItemCount(browser, item, false,
                                    kDataBrowserItemAnyState, &have);
            if (have == 0) {
                add_group_children((int)(item - kGroupIdBase));
            }
        }
        return;
    }
    (void)browser;
    if (message == kDataBrowserItemSelected) {
        d->sel = (int)item - 1;
        refresh_sel_path();
        sync_buttons();
        invalidate_detail();
    } else if (message == kDataBrowserItemDeselected
               && d->sel == (int)item - 1) {
        d->sel = -1;
        refresh_sel_path();
        sync_buttons();
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

/* The item a row id stands for; a container row is represented by its
   first member, which carries the shared name. */
static const SwPageItem *rep_item(DataBrowserItemID id)
{
    DomainState *d = dom();

    if (id >= kGroupIdBase
        && id < kGroupIdBase + (DataBrowserItemID)g_group_count) {
        return &d->items[g_sorted[g_group_first[id - kGroupIdBase]]];
    }
    if (id >= 1 && id <= (DataBrowserItemID)d->count) {
        return &d->items[id - 1];
    }
    return NULL;
}

static Boolean item_compare(ControlRef browser, DataBrowserItemID a,
                            DataBrowserItemID b,
                            DataBrowserPropertyID property)
{
    const SwPageItem *ia = rep_item(a);
    const SwPageItem *ib = rep_item(b);

    (void)browser;
    if (ia == NULL || ib == NULL) {
        return a < b;
    }
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
    /* Full-row selection bar, not the text-hugging default. A text cell
       hilites only behind its glyphs under the MINIMAL style, so a
       selected row reads as three disconnected patches; FILL hilite
       spans each cell edge-to-edge, the one continuous bar a person
       expects (CarbonLib 1.1+, and we floor at 1.6). */
    SetDataBrowserTableViewHiliteStyle(g_browser,
                                       kDataBrowserTableViewFillHilite);
    /* Duplicate groups disclose in the Name column (CarbonLib 1.1+). */
    SetDataBrowserListViewDisclosureColumn(g_browser, kColName, false);
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

/* Echo a keystroke into the field directly - the immediate-feedback
   exception in the redraw contract (typing echo is its canonical
   case). Erase only from the end of the unchanged prefix to the
   field's right edge - that span covers the old caret, a removed
   character, and the placeholder - then draw the new tail and caret.
   Nothing is invalidated: the full draw_search reproduces these exact
   pixels from g_search at any real update, and the whole-field
   invalidate this replaces read as a white blink per key on metal. */
static void echo_search_delta(const char *old_text)
{
    Rect f = g_lay.toolbar_search;
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RgnHandle saved_clip;
    Rect tail;
    long prefix = 0;
    short x;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    saved_clip = NewRgn();
    if (saved_clip == NULL) {
        /* No region to restore the clip with: fall back to the update
           path rather than leave port state wrong. */
        InvalWindowRect(g_owner, &g_lay.toolbar_search);
        return;
    }
    GetClip(saved_clip);
    InsetRect(&f, 1, 1);
    ClipRect(&f);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    while (old_text[prefix] != '\0' && g_search[prefix] != '\0'
           && old_text[prefix] == g_search[prefix]) {
        ++prefix;
    }
    x = (short)(f.left + 3 + TextWidth(g_search, 0, (short)prefix));
    tail = f;
    if (x > tail.left) {
        tail.left = x;
    }
    RGBForeColor(&white);
    PaintRect(&tail);
    RGBForeColor(&black);
    MoveTo(x, (short)(f.bottom - 4));
    if (g_search[prefix] != '\0') {
        DrawText(g_search, (short)prefix,
                 (short)(strlen(g_search) - prefix));
    }
    if (g_search_focus) {
        DrawText("|", 0, 1);
    }
    SetClip(saved_clip);
    DisposeRgn(saved_clip);
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
    y = (short)(y + 15);

    /* Where: the full path, wrapped over two lines, broken after a
       colon when one is near the split so segments stay whole. The
       path was computed at selection time, never here. */
    if (g_sel_path[0] != '\0') {
        long len = (long)strlen(g_sel_path);
        long split = len;
        char line[64];

        draw_at(x, y, "Where:");
        y = (short)(y + 13);
        if (len > 44) {
            long p;

            split = 44;
            for (p = 44; p > 24; --p) {
                if (g_sel_path[p - 1] == ':') {
                    split = p;
                    break;
                }
            }
        }
        memcpy(line, g_sel_path, (size_t)(split < 60 ? split : 60));
        line[split < 60 ? split : 60] = '\0';
        draw_at((short)(x + 8), y, line);
        if (split < len) {
            y = (short)(y + 13);
            snprintf(line, sizeof line, "%.48s%s", g_sel_path + split,
                     len - split > 48 ? "..." : "");
            draw_at((short)(x + 8), y, line);
        }
    }
}

/* --- module ops --------------------------------------------------------- */

static ControlRef make_popup(const Rect *bounds, short menu_id)
{
    Str255 empty;

    empty[0] = 0;
    return now_control_new(g_owner, bounds, empty, false, popupTitleLeftJust,
                      menu_id, 0, popupMenuProc, 0);
}

static OSErr software_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_body = *body;
    software_layout_compute_split(body, g_split_w, &g_lay);
    g_launch_hilite = -1;
    g_search[0] = '\0';
    g_search_focus = false;

    g_popup = make_popup(&g_lay.toolbar_popup, kSwDomainMenuID);
    text[0] = 0;
    g_detail_box = now_control_new(owner, &g_lay.detail, text, false, 0, 0, 1,
                              kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Launch", text);
    g_launch = now_control_new(owner, &g_lay.launch_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    CopyCStringToPascal("Bring to Front", text);
    g_front = now_control_new(owner, &g_lay.front_btn, text, false, 0, 0, 1,
                         pushButProc, 0);
    CopyCStringToPascal("Quit", text);
    g_quit = now_control_new(owner, &g_lay.quit_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    CopyCStringToPascal("Show in Finder", text);
    g_reveal = now_control_new(owner, &g_lay.reveal_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    CopyCStringToPascal("Rescan", text);
    g_rescan = now_control_new(owner, &g_lay.rescan_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    if (g_popup == NULL || g_detail_box == NULL || g_launch == NULL
        || g_front == NULL || g_quit == NULL || g_reveal == NULL
        || g_rescan == NULL) {
        return memFullErr;
    }
    g_launch_shown = g_front_shown = g_quit_shown = -1;
    g_reveal_hilite = -1;
    /* A missing Data Browser costs the list, not the page - the
       processes_module degrade. */
    g_browser_ok = create_browser();
    select_domain(0);                 /* Applications: begins the sweep */
    return noErr;
}

static void software_dispose(void)
{
    int i;

    /* Order matters, and the window does NOT take the browser first:
       workshop_close disposes this module BEFORE DisposeWindow, so the
       Data Browser is still live here. Disposing it fires item
       notifications (removal, maybe a deselect), which reach item_data
       and item_notify through the UPPs and read the domain model. So
       tear the control down FIRST, while both are still valid; only
       then free the UPPs and the model. Freeing the UPPs while the
       browser still holds them let DisposeWindow later call through a
       freed transition vector - an intermittent system crash on quit. */
    if (g_browser != NULL) {
        DisposeControl(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
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
    g_popup = g_detail_box = g_launch = g_front = g_quit
        = g_reveal = g_rescan = NULL;
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
    if (g_reveal != NULL) {
        if (visible) ShowControl(g_reveal); else HideControl(g_reveal);
    }
    if (g_rescan != NULL) {
        if (visible) ShowControl(g_rescan); else HideControl(g_rescan);
    }
    if (visible) {
        /* Launch / Front / Quit visibility follows the selection. */
        g_launch_shown = g_front_shown = g_quit_shown = -1;
        g_launch_hilite = -1;
        g_reveal_hilite = -1;
        sync_buttons();
    } else {
        if (g_launch != NULL) HideControl(g_launch);
        if (g_front != NULL) HideControl(g_front);
        if (g_quit != NULL) HideControl(g_quit);
        g_launch_shown = g_front_shown = g_quit_shown = -1;
    }
}

static void software_layout_op(const Rect *body)
{
    g_body = *body;
    software_layout_compute_split(body, g_split_w, &g_lay);
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
    if (g_front != NULL) {
        MoveControl(g_front, g_lay.front_btn.left, g_lay.front_btn.top);
    }
    if (g_quit != NULL) {
        MoveControl(g_quit, g_lay.quit_btn.left, g_lay.quit_btn.top);
    }
    if (g_reveal != NULL) {
        MoveControl(g_reveal, g_lay.reveal_btn.left, g_lay.reveal_btn.top);
    }
    if (g_rescan != NULL) {
        MoveControl(g_rescan, g_lay.rescan_btn.left, g_lay.rescan_btn.top);
    }
}

/* The splitter drag: a custom StillDown loop, so it pumps the wire
   itself every pass (the nested-loops.md rule). Feedback is the classic
   gray XOR outline; the real layout moves once, on release. Pen state
   is PORT state on the shared window - saved and restored, the
   background-color lesson applied before it bites twice. */
static void track_splitter(void)
{
    PenState saved;
    Pattern gray;
    Point p;
    short min_x, max_x, line_x, new_x;
    Rect band = g_lay.splitter;

    SetPortWindowPort(g_owner);
    GetPenState(&saved);
    GetQDGlobalsGray(&gray);
    PenMode(patXor);
    PenPat(&gray);

    min_x = (short)(g_body.left + kSwMargin + kSwListMin);
    max_x = (short)(g_body.right - kSwMargin - kSwDetailMin - kSwPaneGap);
    line_x = g_lay.splitter.left;
    MoveTo(line_x, band.top);
    LineTo(line_x, band.bottom);
    while (StillDown()) {
        conn_service();               /* the wire never stops for a drag */
        GetMouse(&p);
        new_x = p.h;
        if (new_x < min_x) {
            new_x = min_x;
        }
        if (new_x > max_x) {
            new_x = max_x;
        }
        if (new_x != line_x) {
            MoveTo(line_x, band.top);
            LineTo(line_x, band.bottom);
            line_x = new_x;
            MoveTo(line_x, band.top);
            LineTo(line_x, band.bottom);
        }
    }
    MoveTo(line_x, band.top);
    LineTo(line_x, band.bottom);
    SetPenState(&saved);

    g_split_w = (short)(line_x - (g_body.left + kSwMargin));
    software_layout_op(&g_body);
    InvalWindowRect(g_owner, &g_body);
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
    /* The splitter's grip: three quiet dots between the panes. */
    {
        short cx = (short)((g_lay.splitter.left
                            + g_lay.splitter.right) / 2);
        short cy = (short)((g_lay.splitter.top
                            + g_lay.splitter.bottom) / 2);
        Rect dot;
        int i;

        for (i = -1; i <= 1; ++i) {
            SetRect(&dot, (short)(cx - 1), (short)(cy + i * 6 - 1),
                    (short)(cx + 1), (short)(cy + i * 6 + 1));
            PaintRect(&dot);
        }
    }
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
    if (PtInRect(local, &g_lay.splitter)) {
        track_splitter();
        return true;
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
    if (c == g_front || c == g_quit) {
        if (TrackControl(c, local, now_pump_action()) != 0) {
            DomainState *d = dom();
            ProcessSerialNumber psn;

            /* The PSN is found at ACT time, fresh - the row's running
               flag may be minutes old, and acting on a stale PSN would
               poke whatever recycled it. */
            if (d->sel >= 0 && d->sel < d->count
                && now_software_find_psn(&d->items[d->sel].spec, &psn)) {
                if (c == g_front) {
                    now_proc_bring_to_front(&psn);
                } else {
                    now_proc_ask_quit(&psn);
                }
            }
        }
        return true;
    }
    if (c == g_reveal) {
        if (g_reveal_hilite == 0
            && TrackControl(c, local, now_pump_action()) != 0) {
            DomainState *d = dom();

            if (d->sel >= 0 && d->sel < d->count) {
                now_software_reveal(&d->items[d->sel].spec);
            }
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
    char old_text[48];
    long n;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    memcpy(old_text, g_search, sizeof old_text);
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
    refilter_browser();
    echo_search_delta(old_text);
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
        /* The browser is fed NOTHING mid-sweep: batched sorted inserts
           shuffled the visible rows and flashed the list a dozen times
           (third metal round). The status placard counts the arrivals;
           the list populates ONCE when the sweep completes. */
        now_software_sweep_step(&d->sweep, collect_app, d);
        if (d->sweep.done) {
            d->sweeping = false;
            now_software_mark_running(d->items, d->count);
            now_software_sweep_end(&d->sweep);
            rebuild_browser();
        }
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
    software_status_text,
    NULL
};

const WorkshopModuleOps *software_module_ops(void)
{
    return &k_ops;
}
