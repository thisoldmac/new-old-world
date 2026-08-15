#include "cloud_module.h"

#include <stdio.h>
#include <string.h>

#include "cloud_card_cache.h"
#include "cloud_contacts_view.h"
#include "cloud_drive_view.h"
#include "cloud_filter.h"
#include "cloud_layout.h"
#include "db_hilite.h"
#include "cloud_list_view.h"
#include "cloud_model.h"
#include "cloud_photos_view.h"
#include "cloud_preview_well.h"
#include "cloud_view.h"
#include "fileshare.h"
#include "json.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"
#include "workshop_scene_text.h"

/* The iCloud page: the modern machine's cloud, browsed from this one.
   One dropdown of services (cloud.report), and a render tailored to
   the chosen service. Photos and Contacts list rows (cloud.listing,
   paged straight through like the Files browser) with a card for the
   selected one (cloud.card) and Save, which asks for the row as an
   ordinary file into this machine's share (cloud.get -> file.offer).

   Drive is a real file browser HERE, not a signpost — but its
   transport is still the file family against the share, exactly as
   the contract's x-cloud prescribes: this page calls the same
   now_wire_list_host the Files page calls, and the listing hook
   follows whoever asked last ("a second request replaces the first"
   is already the wire's rule for the answer). One implementation,
   now genuinely two renderers. A double-clicked file pulls through
   now_wire_get_host into the downloads folder, and the card pane
   shows the pull moving.

   All cloud answers arrive through one raw-frame hook and are parsed
   by cloud_model.c, which the host cc tests; this file owns controls,
   rectangles and pixels, and decides nothing about the bytes.

   This file is the SHELL: the popup, Refresh, the status/placard, the
   conn_set_cloud_note hook, and which service is chosen. Everything
   about how a chosen service renders — Drive's file browser, Photos'
   generic listing+card, Contacts' address-book card — lives behind
   CloudViewOps (cloud_view.h) in cloud_drive_view.c, cloud_list_view.c
   and cloud_contacts_view.c, so a new service view is a new file, not
   a new branch in this one (view_for() below is the one place that
   still has to know the service names, the same way choosing drive
   mode already does). */

enum {
    kCloudServicesMenuID = 135
};

static WindowRef g_owner;
static Rect g_body;
static CloudLayout g_r;
static Boolean g_visible;

static ControlRef g_popup;
static ControlRef g_refresh;
static ControlRef g_save;
static ControlRef g_back;             /* drive mode only: the history
                                         pair, dimmed when its stack is
                                         empty rather than hidden */
static ControlRef g_fwd;
static ControlRef g_browser;          /* the SHELL's two-column list
                                         (Item/Detail); drive mode shows
                                         cloud_drive_view's own instead */
static MenuRef g_menu;

static CloudStore g_store;
static int g_service = -1;            /* index into g_store.services */
static int g_selected = -1;           /* row index: cloud rows, or in
                                         drive mode the view's own rows */
static Boolean g_loading;
static Boolean g_asked_once;
static Boolean g_in_rebuild;
static char g_status[128];

/* Contacts' card cache and the background walk that fills it -- see
   docs/icloud.md's contacts paragraph. The cache holds every card the
   prefetch (or an ordinary selection) has already asked for, keyed by
   item id; g_prefetch_next is this view's own cursor into g_store.rows,
   never rewound except by a fresh listing (reset_card_prefetch, below).
   g_prefetch_pending is true for exactly as long as the ONE
   outstanding cloud.detail ask (if any) is this walk's own, rather
   than a selection's — cloud_module.c owns both kinds of card ask, and
   this is the one flag that tells note_card() which kind just
   answered. Scoped to contacts only (g_contacts_mode gates every use
   below): Photos' own card asks are unaffected. */
static CloudCardCache g_card_cache;
static int g_prefetch_next;
static Boolean g_prefetch_pending;

/* The live search: a hand-drawn field driven from key(), the same
   reason software_module.c's is (this WaitNextEvent app cannot host an
   inline edit-text control). Filters whichever view is active, on
   every keystroke, over rows already fetched — never wire traffic.
   g_in_view is the diff base every add/remove against the shared Data
   Browser reads, indexed the same way item ids already are (index+1);
   it applies to whichever storage the active view reads (the shell's
   own g_store.rows outside drive mode, cloud_drive_view's own rows in
   it) because only one is ever shown at a time. */
static char g_search[48];
static Boolean g_search_focus;
static unsigned char g_in_view[kCloudMaxRows];
static int g_shown_rows;

/* Drive mode: the chosen service is drive and the share serves it.
   g_drive_mode is chrome bookkeeping only now (the button's title, the
   Save/Up enable rule) — cloud_drive_view.c owns everything else about
   browsing it. */
static Boolean g_drive_mode;
/* Contacts mode: the chosen service is contacts. Chrome bookkeeping
   only, the same shape as g_drive_mode — cloud_contacts_view.c owns
   everything about its own browser and card; this just says which of
   the three browsers active_browser() hands out. */
static Boolean g_contacts_mode;
static const CloudViewOps *g_view;

static char g_shown_status[128];
static Boolean g_shown_save_on;
static Boolean g_shown_back_on = true;   /* NewControl starts enabled;
                                            true here makes the first
                                            idle pass dim an empty
                                            history exactly once */
static Boolean g_shown_fwd_on = true;

/* The list the current mode is actually showing: drive mode swaps in
   cloud_drive_view's own four-column browser, photos mode swaps in
   cloud_photos_view's own, and contacts mode swaps in
   cloud_contacts_view's own two-column one — the shell's own control
   cannot change wardrobe per mode (RemoveDataBrowserTableViewColumn is
   not in the PB1400c's proven exports; cloud_drive_view.c says why in
   full, and the same evidence gap applies to any column set a service
   might want). Everything the shell does to "the list" — clearing, the
   search's diff, click routing, focus — goes through active_browser();
   every place that used to show/hide "g_browser or
   cloud_drive_view_browser()" by the g_drive_mode flag alone now goes
   through view_own_browser() so a THIRD and FOURTH view-owned control
   did not need their own flags threaded through every one of those
   sites. */
static ControlRef view_own_browser(void)
{
    if (g_drive_mode) {
        return cloud_drive_view_browser();
    }
    if (g_contacts_mode) {
        return cloud_contacts_view_browser();
    }
    if (g_view == cloud_photos_view_ops()) {
        return cloud_photos_view_browser();
    }
    return NULL;
}

static ControlRef active_browser(void)
{
    ControlRef own = view_own_browser();

    return own != NULL ? own : g_browser;
}

/* Declared with the rest of layout, below; forward-declared here
   because show_own_browser (right below) needs it and appears first
   in the file. */
static void show_control(ControlRef control, Boolean on);

/* Shows exactly one of the shell's shared browser / Drive's own /
   Photos' own / Contacts' own, per view_own_browser() — the shell owns
   visibility for all four the same way it already owned it for the
   first two. */
static void show_own_browser(Boolean visible)
{
    ControlRef own = view_own_browser();

    show_control(g_browser, visible && own == NULL);
    show_control(cloud_drive_view_browser(),
                 visible && own == cloud_drive_view_browser()
                     && own != NULL);
    show_control(cloud_photos_view_browser(),
                 visible && own == cloud_photos_view_browser()
                     && own != NULL);
    show_control(cloud_contacts_view_browser(),
                 visible && own == cloud_contacts_view_browser()
                     && own != NULL);
}

static void invalidate_detail(void)
{
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_r.detail);
    }
}

static void invalidate_status(void)
{
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_r.status);
    }
}

static void set_status(const char *line)
{
    snprintf(g_status, sizeof g_status, "%.120s", line);
    invalidate_status();
}

static void set_loading(Boolean loading)
{
    g_loading = loading;
}

static const CloudService *current_service(void)
{
    if (g_service < 0 || g_service >= g_store.service_count) {
        return NULL;
    }
    return &g_store.services[g_service];
}

/* --- asking (services and the list/card pair; Drive asks through its
   own view file) -------------------------------------------------- */

static void ask_services(void)
{
    char err[96];

    if (now_wire_cloud_services(err, sizeof err) != 0) {
        set_status(err);
        return;
    }
    g_loading = true;
    set_status("Asking what is on offer...");
}

/* A fresh listing invalidates every cached card and the walk's own
   place in it -- the rows an old cursor names may not even be the same
   contacts. Reached from ask_rows's cursor<=1 branch (a first page,
   a Refresh, or a service switch) rather than choose_service directly,
   because that is already the one place "the listing just restarted"
   is decided for every service, contacts included. */
static void reset_card_prefetch(void)
{
    cloud_card_cache_reset(&g_card_cache);
    g_prefetch_next = 0;
    g_prefetch_pending = false;
}

static void ask_rows(long cursor)
{
    const CloudService *service = current_service();
    char err[96];

    if (service == NULL) {
        return;
    }
    if (cursor <= 1) {
        cloud_store_reset_rows(&g_store, service->service);
        reset_card_prefetch();
        g_selected = -1;
        if (g_browser != NULL) {
            g_in_rebuild = true;
            RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                                   kDataBrowserItemNoProperty);
            g_in_rebuild = false;
        }
        invalidate_detail();
    }
    if (now_wire_cloud_list(service->service, cursor, err,
                            sizeof err) != 0) {
        g_loading = false;
        set_status(err);
        return;
    }
    g_loading = true;
    set_status("Reading...");
}

static void ask_card(void)
{
    const CloudService *service = current_service();
    char err[96];

    if (service == NULL || g_selected < 0
        || g_selected >= g_store.row_count) {
        return;
    }
    /* The old card stays visible until its replacement arrives:
       invalidating here AND on the reply flashed the half-body pane
       white twice per click, which read as the whole page redrawing
       per selection. One inval, in note_card, when there is something
       new to draw. */
    cloud_store_reset_card(&g_store);
    if (now_wire_cloud_detail(service->service,
                              g_store.rows[g_selected].item,
                              err, sizeof err) != 0) {
        set_status(err);
        return;
    }
    /* This ask, not any prefetch that happened to be outstanding, now
       owns the wire's one cloud.detail slot -- a live selection always
       outranks the background walk (docs/icloud.md: "pausing for any
       user-initiated ask"). Superseded or not, the prefetch's own
       reply (if it was mid-flight) can no longer arrive: a second ask
       replaces the first at the wire level (wire.c's g_cloud), so its
       reply's id will never again match and wire.c drops it before
       note_card ever sees it. Clearing the flag here, rather than only
       where a prefetch reply itself would have cleared it, is what
       keeps note_card's branch honest about which kind of ask this
       reply is actually answering. */
    g_prefetch_pending = false;
}

static void ask_save(void)
{
    const CloudService *service = current_service();
    char err[96];

    if (service == NULL || g_selected < 0
        || g_selected >= g_store.row_count) {
        return;
    }
    if (now_wire_cloud_get(service->service,
                           g_store.rows[g_selected].item,
                           g_view != NULL && g_view->save_size != NULL
                               ? g_view->save_size() : NULL,
                           err, sizeof err) != 0) {
        set_status(err);
        return;
    }
    set_status("Asking for it...");
}

/* --- the list, shared by both views -------------------------------- */

static void clear_list(void)
{
    ControlRef list = active_browser();

    g_selected = -1;
    g_shown_rows = 0;
    memset(g_in_view, 0, sizeof g_in_view);
    if (list != NULL) {
        g_in_rebuild = true;
        RemoveDataBrowserItems(list, kDataBrowserNoItem, 0, NULL,
                               kDataBrowserItemNoProperty);
        g_in_rebuild = false;
    }
}

/* --- the live search -------------------------------------------------- */

/* How many rows the active view's own storage holds — the shell's
   shared g_store.rows outside drive mode, cloud_drive_view's own count
   in it (that view keeps rows the shell's CloudStore never sees). */
static int active_row_count(void)
{
    if (g_drive_mode) {
        return cloud_drive_view_row_count();
    }
    return g_store.row_count;
}

/* Whichever view is active decides whether row `index` matches; NULL
   means "matches everything" (see cloud_view.h). */
static Boolean row_matches(int index, const char *needle)
{
    if (g_view == NULL || g_view->row_matches == NULL) {
        return true;
    }
    return g_view->row_matches(index, &g_store, needle);
}

/* [first, first + n) just arrived in the active view's row storage —
   note_listing's own rows, or (through CloudDriveHost.add_rows) Drive's.
   Adds to the shared Data Browser only the ones the live search
   currently admits, and marks them in g_in_view so a later keystroke's
   refilter_browser() can diff against them. The batch buffer is 16
   wide but the LOOP is not capped: nothing shared states that a
   caller's page is 16, and rows a bigger page put in the store but
   never in the browser were invisible until a keystroke's refilter
   silently revealed them. */
static void filter_and_add(int first, int n)
{
    ControlRef list = active_browser();
    DataBrowserItemID ids[16];
    char needle[48];
    UInt32 got = 0;
    int i;

    cloud_filter_lower(g_search, needle, sizeof needle);
    for (i = 0; i < n; ++i) {
        int idx = first + i;

        if (idx < 0 || idx >= kCloudMaxRows) {
            continue;
        }
        if (row_matches(idx, needle)) {
            g_in_view[idx] = 1;
            ids[got++] = (DataBrowserItemID)(idx + 1);
            ++g_shown_rows;
            if (got == 16 && list != NULL) {
                AddDataBrowserItems(list, kDataBrowserNoItem, got,
                                    ids, kDataBrowserItemNoProperty);
                got = 0;
            }
        } else {
            g_in_view[idx] = 0;
        }
    }
    if (got > 0 && list != NULL) {
        AddDataBrowserItems(list, kDataBrowserNoItem, got, ids,
                            kDataBrowserItemNoProperty);
    }
}

/* The keystroke path: adjust the browser by DIFF against g_in_view —
   remove rows whose match just ended, add rows whose match just began
   — rather than a full rebuild, the same redraw-economy reason
   software_module.c's refilter_browser exists. A selection whose row
   left the view clears; the notification that would otherwise do that
   is suppressed by g_in_rebuild (RemoveDataBrowserItems fires a
   deselect the rebuild itself caused, not the person), so this clears
   it explicitly instead. */
static void refilter_browser(void)
{
    ControlRef list = active_browser();
    char needle[48];
    int count = active_row_count();
    int i;

    if (list == NULL) {
        return;
    }
    cloud_filter_lower(g_search, needle, sizeof needle);
    g_in_rebuild = true;
    for (i = 0; i < count && i < kCloudMaxRows; ++i) {
        DataBrowserItemID id = (DataBrowserItemID)(i + 1);
        Boolean want = row_matches(i, needle);

        if (want && !g_in_view[i]) {
            AddDataBrowserItems(list, kDataBrowserNoItem, 1, &id,
                                kDataBrowserItemNoProperty);
            g_in_view[i] = 1;
            g_shown_rows += 1;
        } else if (!want && g_in_view[i]) {
            RemoveDataBrowserItems(list, kDataBrowserNoItem, 1, &id,
                                   kDataBrowserItemNoProperty);
            g_in_view[i] = 0;
            g_shown_rows -= 1;
        }
    }
    g_in_rebuild = false;
    if (g_selected >= 0 && !(g_selected < count && g_in_view[g_selected])) {
        g_selected = -1;
        cloud_store_reset_card(&g_store);
        if (g_view != NULL && g_view->select != NULL) {
            g_view->select(&g_r, &g_store, -1);
        }
        invalidate_detail();
    }
}

/* --- the dropdown ------------------------------------------------------- */

/* The popup's menu, asked for the blessed way. Under CarbonLib the
   classic popupMenuProc procID resolves to the Appearance popup, whose
   menu is reached through GetControlData — GetMenuHandle only finds it
   if the CDEF put it in the menu list, which is the CDEF's business,
   not a promise. Fall back to the menu list for older paths, and say
   so out loud when both come up empty: a silent NULL here is a
   dropdown stuck on "(none)" with nothing to explain it. */
static MenuRef popup_menu(void)
{
    MenuRef menu = NULL;
    Size got = 0;

    if (g_popup != NULL
        && GetControlData(g_popup, kControlEntireControl,
                          kControlPopupButtonMenuHandleTag,
                          sizeof menu, (Ptr)&menu, &got) == noErr
        && got == (Size)sizeof menu && menu != NULL) {
        return menu;
    }
    return GetMenuHandle(kCloudServicesMenuID);
}

static void rebuild_popup(void)
{
    int i;

    g_menu = popup_menu();
    if (g_menu == NULL) {
        set_status("The services menu is missing (resource 135)");
        return;
    }
    while (CountMenuItems(g_menu) > 0) {
        DeleteMenuItem(g_menu, 1);
    }
    for (i = 0; i < g_store.service_count; ++i) {
        Str255 label;

        /* Appended as a placeholder then renamed: AppendMenu interprets
           metacharacters, and a label is data, not a menu program. */
        CopyCStringToPascal("x", label);
        AppendMenu(g_menu, label);
        CopyCStringToPascal(g_store.services[i].label, label);
        SetMenuItemText(g_menu, (short)(i + 1), label);
    }
    if (g_store.service_count == 0) {
        Str255 none;

        CopyCStringToPascal("(none)", none);
        AppendMenu(g_menu, none);
    }
    if (g_popup != NULL) {
        SetControlMaximum(g_popup, CountMenuItems(g_menu));
        SetControlValue(g_popup,
                        (short)(g_service >= 0 ? g_service + 1 : 1));
        Draw1Control(g_popup);
    }
}

/* Defined with the rest of layout, below; declared here because
   choose_service() needs it and appears first in the file.
   show_control itself was already forward-declared above, for
   show_own_browser. */
static void apply_layout(void);

static void retitle_button(void)
{
    Str255 text;

    if (g_save == NULL) {
        return;
    }
    CopyCStringToPascal(g_drive_mode ? "Up" : "Save to this Mac", text);
    SetControlTitle(g_save, text);
}

/* Which view renders the chosen service's card: drive gets its own
   file browser, contacts its own address-book card, everything else
   the generic listing+card. A new tailored view is a new branch here
   and a new file, never a change to an existing view's file. */
static const CloudViewOps *view_for(const CloudService *service,
                                    Boolean drive_mode)
{
    if (drive_mode) {
        return cloud_drive_view_ops();
    }
    if (strcmp(service->service, "contacts") == 0) {
        return cloud_contacts_view_ops();
    }
    if (strcmp(service->service, "photos") == 0) {
        return cloud_photos_view_ops();
    }
    return cloud_list_view_ops();
}

static void choose_service(int index)
{
    const CloudService *service;

    if (index < 0 || index >= g_store.service_count) {
        return;
    }
    /* The outgoing view's per-selection state goes first: the photos
       preview must not sit in memory behind a Contacts card. Its own
       controls leave the stage with it — the shell shows/hides only
       what the shell owns. */
    if (g_view != NULL && g_view->select != NULL) {
        g_view->select(&g_r, &g_store, -1);
    }
    if (g_view != NULL && g_view->show != NULL) {
        g_view->show(false);
    }
    g_service = index;
    service = &g_store.services[g_service];
    cloud_store_reset_rows(&g_store, service->service);
    /* A new service means a new list; a needle typed against the old
       one filtering it invisibly is the stale-search bug the popup
       click path used to clear on its own. Cleared HERE, where every
       route to a service change converges — Refresh and the first
       report included. */
    g_search[0] = '\0';
    g_shown_rows = 0;
    memset(g_in_view, 0, sizeof g_in_view);
    g_drive_mode = strcmp(service->service, "drive") == 0
        && strcmp(service->state, "serving") == 0;
    g_contacts_mode = !g_drive_mode
        && strcmp(service->service, "contacts") == 0;
    cloud_drive_view_activate(g_drive_mode);
    g_view = view_for(service, g_drive_mode);
    /* Drive and list mode share the same split (cloud_layout.c reuses
       one list/detail layout for every mode) but differ in list_top
       and in the pane's own furniture - recompute and move every
       control before anything below draws into them. */
    apply_layout();
    retitle_button();
    clear_list();
    /* Four browsers, one shown: view_own_browser() owns which is the
       page's, and the history pair exists only where a history does.
       Hidden is for the browsers the mode does not use; empty-history
       dimming is cloud_idle's HiliteControl diff, never a hide. */
    if (g_owner != NULL && g_visible) {
        show_own_browser(true);
        show_control(g_back, g_drive_mode);
        show_control(g_fwd, g_drive_mode);
        if (g_view != NULL && g_view->show != NULL) {
            g_view->show(true);       /* the incoming view's own
                                         controls, placed by the
                                         apply_layout above */
        }
    }
    invalidate_detail();
    /* The list control's own resize repaints itself, but the area a
       shrinking control vacates is not the Toolbox's job to erase, and
       this file draws the card pane's text by hand rather than through
       a control - so a mode switch invalidates the whole body once
       rather than risk stale pixels from the pane that just changed
       shape or disappeared. Not idle-path work: this runs only on a
       service pick. */
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_body);
    }
    if (g_drive_mode) {
        if (g_view != NULL && g_view->reset_for_service != NULL) {
            g_view->reset_for_service(service);
        }
    } else if (strcmp(service->state, "serving") == 0
               && cloud_service_listable(service->service)) {
        ask_rows(1);
    } else {
        /* The pane's words are the service's own: state and detail from
           the report, drawn by the active view's draw(). */
        set_status(service->detail[0] != '\0' ? service->detail
                                              : service->state);
    }
}

/* --- the wire's answers ------------------------------------------------- */

static void note_report(const char *reply)
{
    int first;
    int i;

    g_loading = false;
    cloud_parse_report(reply, &g_store);
    /* Older hosts may report their former download-size setting as a legacy
       defaultSize hint. Current hosts omit it because the guest owns this
       choice; absence selects the view's own safe bounded default. */
    for (i = 0; i < g_store.service_count; ++i) {
        if (strcmp(g_store.services[i].service, "photos") == 0) {
            cloud_photos_view_note_default_size(
                g_store.services[i].default_size);
            break;
        }
    }
    first = cloud_first_listable(&g_store);
    if (first < 0 && g_store.service_count > 0) {
        first = 0;
    }
    g_service = first;
    rebuild_popup();
    if (g_store.service_count == 0) {
        set_status("The other Mac offers no cloud services");
        return;
    }
    choose_service(first);
}

static void note_listing(const char *reply)
{
    g_loading = false;
    cloud_parse_listing(reply, &g_store);
    if (g_store.more && g_store.row_count < kCloudMaxRows) {
        /* Mid-listing: rows land in the STORE only. Touching the Data
           Browser here repainted the whole control once per 16-row
           wire page — eight full-pane flashes for a photo library,
           watched on the PowerBook 2026-08-02. The browser is mutated
           once, below, when the listing settles. */
        ask_rows(g_store.cursor);
        return;
    }
    filter_and_add(0, g_store.row_count);
    {
        char line[64];

        cloud_listing_status(&g_store, line, sizeof line);
        set_status(line);
    }
}

/* The ONE outstanding cloud.detail ask has settled -- either the card
   the person is looking at (g_prefetch_pending false: an ordinary
   selection, or the prefetch's own reply for whatever row is CURRENTLY
   selected, which reads identically either way) or a prefetch reply
   for some other, unselected row. Either way the answer is worth
   keeping: a selection's own card is cached too, so revisiting it
   later costs nothing. */
static void note_card(const char *reply)
{
    if (g_prefetch_pending) {
        char item[64];
        CloudCardRow rows[kCloudMaxCardRows];
        int count;

        g_prefetch_pending = false;
        count = cloud_parse_card_rows(reply, item, sizeof item,
                                      rows, kCloudMaxCardRows);
        if (item[0] != '\0') {
            cloud_card_cache_put(&g_card_cache, item, rows, count);
        }
        /* Move the walk on regardless of outcome: a malformed or
           empty reply for this row is still a row this pass has
           tried, and re-asking it forever would be the burst the
           prefetch is not allowed to make. */
        ++g_prefetch_next;
        return;                    /* never touches the shown card --
                                       the person is not looking at
                                       this contact right now, and
                                       cloud_module.c's own selected
                                       row asks through the branch
                                       below, never this one. */
    }
    cloud_parse_card(reply, &g_store);
    if (g_contacts_mode && g_store.card_item[0] != '\0') {
        cloud_card_cache_put(&g_card_cache, g_store.card_item,
                             g_store.card, g_store.card_count);
    }
    invalidate_detail();
}

/* The get's outcome watch: armed when the offer is noted, disarmed by
   the wire's receive-outcome seam. One long compare per idle pass
   while armed, nothing at all otherwise. */
static Boolean g_watch_get;
static long g_watch_seq;

static void note_get_under_way(const char *offer)
{
    char name[64];
    char where[96];
    char line[160];
    short vref;
    long dir;

    name[0] = '\0';
    now_json_find_text(offer, "name", name, sizeof name);
    /* Where it is actually landing: the chosen folder when the photos
       view registered one, the shared folder otherwise. One catalog
       climb per offer, never per pass. */
    if (now_wire_cloud_get_destination_get(&vref, &dir)
        && now_files_dir_path(vref, dir, where, sizeof where)) {
        snprintf(line, sizeof line, "Receiving %.40s into %.60s",
                 name[0] != '\0' ? name : "the file", where);
    } else if (name[0] != '\0') {
        snprintf(line, sizeof line,
                 "Receiving %.40s into the shared folder", name);
    } else {
        strcpy(line, "Receiving into the shared folder");
    }
    set_status(line);
    /* Watch it to the end: the status above must be REPLACED by the
       outcome when the receive settles, not worn forever — the bug
       this seam exists to fix. */
    g_watch_get = true;
    g_watch_seq = now_wire_receive_outcome(NULL, 0);
}

static void cloud_answers(int kind, const char *reply)
{
    switch (kind) {
    case kCloudAnswerReport:      note_report(reply); break;
    case kCloudAnswerListing:     note_listing(reply); break;
    case kCloudAnswerCard:        note_card(reply); break;
    case kCloudAnswerGetUnderWay: note_get_under_way(reply); break;
    case kCloudAnswerError:
        g_loading = false;
        set_status(reply);
        break;
    default:
        break;
    }
}

/* --- the list control --------------------------------------------------- */

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const CloudRow *row;
    CFStringRef text = NULL;

    /* This callback serves the SHELL's browser only: drive mode's rows
       draw through cloud_drive_view.c's own control and item_data. */
    (void)browser;
    if (changeValue || item < 1
        || item > (DataBrowserItemID)g_store.row_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_store.rows[item - 1];
    switch (property) {
    case kCloudColTitle:
        text = CFStringCreateWithCString(NULL, row->title,
                                         kCFStringEncodingMacRoman);
        break;
    case kCloudColSubtitle:
        text = CFStringCreateWithCString(NULL, row->subtitle,
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

/* A row was picked (index >= 0) or the selection cleared (-1): the
   three steps every service's selection takes -- g_selected, the
   card ask, and telling whichever view is active. Shared by the
   shell's own browser's notification (below) and, through
   CloudContactsHost.row_selected, Contacts' own browser -- one
   implementation of "what a selection means" regardless of which
   control the click landed on. */
static void note_row_selected(int index)
{
    if (index < 0) {
        if (g_selected < 0) {
            return;                   /* already cleared: idempotent */
        }
        g_selected = -1;
        cloud_store_reset_card(&g_store);
        if (g_view != NULL && g_view->select != NULL) {
            g_view->select(&g_r, &g_store, -1);
        }
        invalidate_detail();
        return;
    }
    g_selected = index;
    /* Contacts only: a cached card (the prefetch's own, or an earlier
       selection's) draws instantly and asks the wire nothing; a miss
       still asks, exactly as before, and that ask's own reply gets
       cached too (note_card). Every other service keeps asking on
       every selection, unchanged. */
    if (g_contacts_mode && index < g_store.row_count
        && cloud_card_cache_get(&g_card_cache, g_store.rows[index].item,
                                g_store.card, &g_store.card_count)) {
        strncpy(g_store.card_item, g_store.rows[index].item,
               sizeof g_store.card_item - 1);
        g_store.card_item[sizeof g_store.card_item - 1] = '\0';
        invalidate_detail();
    } else {
        ask_card();
    }
    if (g_view != NULL && g_view->select != NULL) {
        g_view->select(&g_r, &g_store, g_selected);
    }
}

/* Contacts' own browser needs to know when the shell is mutating
   items on its own behalf, the same way this file's g_in_rebuild
   already guards its own browser's notifications, below. */
static Boolean shell_in_rebuild(void)
{
    return g_in_rebuild;
}

/* The Data Browser fires Deselected(old) around Selected(new): a
   click on row 2 delivers Deselected(1) then Selected(2) (or the
   other order), and an unconditional clear-on-deselect throws away
   the selection the new click just made. This is the ONE place that
   comparison happens -- the shell's own browser routes through it
   below, and CloudContactsHost.row_deselected hands it Contacts'
   own browser's deselect index too, so the guard exists once for
   both controls rather than once correctly here and once missing
   there. (cloud_drive_view.c's own browser needs no entry here: its
   selection is a private index into its own listing, not this
   file's g_selected, so its own local guard is a different fact,
   not a duplicate of this one.) */
static void note_row_deselected(int index)
{
    if (g_selected == index) {
        note_row_selected(-1);
    }
}

static void item_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    (void)browser;
    /* Notifications fired by our own rebuild are not user intent.
       Drive and Contacts modes' selections never arrive here at all:
       those browsers have their own notification callbacks. */
    if (g_in_rebuild) {
        return;
    }
    if (message == kDataBrowserItemSelected) {
        note_row_selected((int)item - 1);
    } else if (message == kDataBrowserItemDeselected) {
        note_row_deselected((int)item - 1);
    }
}

static DataBrowserItemDataUPP g_data_upp;
static DataBrowserItemNotificationUPP g_notify_upp;

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
}

static OSStatus add_column(DataBrowserPropertyID id, const char *title,
                           UInt16 width,
                           DataBrowserTableViewColumnIndex at)
{
    DataBrowserListViewColumnDesc col;
    OSStatus err;

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = id;
    col.propertyDesc.propertyType = kDataBrowserTextType;
    col.propertyDesc.propertyFlags = 0;
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = 40;
    col.headerBtnDesc.maximumWidth = 400;
    col.headerBtnDesc.titleOffset = 0;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnFontStyle.flags = 0;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, title, kCFStringEncodingMacRoman);
    err = AddDataBrowserListViewColumn(g_browser, &col, at);
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    if (err == noErr) {
        SetDataBrowserTableViewNamedColumnWidth(g_browser, id, width);
    }
    return err;
}

/* --- module ops --------------------------------------------------------- */

static OSErr cloud_create(WindowRef owner, const Rect *body)
{
    DataBrowserCallbacks callbacks;
    CloudDriveHost host;
    const CloudViewOps *drive_ops = cloud_drive_view_ops();
    Str255 text;

    g_owner = owner;
    g_body = *body;
    g_drive_mode = false;
    g_contacts_mode = false;
    cloud_layout_compute(&g_body, g_drive_mode, &g_r);
    cloud_store_reset(&g_store);
    g_service = -1;
    g_selected = -1;
    reset_card_prefetch();
    g_view = cloud_list_view_ops();
    g_status[0] = '\0';
    g_shown_status[0] = '\0';
    g_shown_save_on = false;
    g_shown_back_on = true;           /* fresh controls start enabled;
                                         the first idle dims them once */
    g_shown_fwd_on = true;
    g_search[0] = '\0';
    g_search_focus = false;
    memset(g_in_view, 0, sizeof g_in_view);
    g_shown_rows = 0;
    g_watch_get = false;

    /* The dropdown's menu: a placeholder resource the report rewrites.
       The popup CDEF inserts it into the hierarchical list, which is
       where GetMenuHandle finds it again. */
    text[0] = 0;
    g_popup = now_control_new(owner, &g_r.popup, text, false,
                         popupTitleLeftJust, kCloudServicesMenuID, 0,
                         popupMenuProc, 0);
    g_menu = popup_menu();
    CopyCStringToPascal("Refresh", text);
    g_refresh = now_control_new(owner, &g_r.refresh_btn, text, false, 0, 0, 1,
                           pushButProc, 0);
    CopyCStringToPascal("Save to this Mac", text);
    g_save = now_control_new(owner, &g_r.save_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    /* The history pair, drive mode's chrome: created against the
       list-mode anti-rects (apply_layout places them when the mode
       turns on) and shown only there. "<" and ">" over "Back"/"Fwd"
       because the toolbar row shares 470 points with four other
       controls on the smallest honest screen. */
    CopyCStringToPascal("<", text);
    g_back = now_control_new(owner, &g_r.back_btn, text, false, 0, 0, 1,
                             pushButProc, 0);
    CopyCStringToPascal(">", text);
    g_fwd = now_control_new(owner, &g_r.fwd_btn, text, false, 0, 0, 1,
                            pushButProc, 0);
    if (g_popup == NULL || g_refresh == NULL || g_save == NULL
        || g_back == NULL || g_fwd == NULL) {
        return memFullErr;
    }

    if (CreateDataBrowserControl(owner, &g_r.list, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;             /* the pane says so; no hard fail */
    } else {
        /* Recorded, or the mirror never sees it: the scene lists
           the controls this application remembers making. */
        now_control_adopt(owner, g_browser, kNowControlProcDataBrowser);
        memset(&callbacks, 0, sizeof callbacks);
        callbacks.version = kDataBrowserLatestCallbacks;
        InitDataBrowserCallbacks(&callbacks);
        g_data_upp = NewDataBrowserItemDataUPP(item_data);
        g_notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
        if (g_data_upp == NULL || g_notify_upp == NULL) {
            now_control_dispose(g_browser);
            g_browser = NULL;
            dispose_callbacks();
        } else {
            callbacks.u.v1.itemDataCallback = g_data_upp;
            callbacks.u.v1.itemNotificationCallback = g_notify_upp;
            if (SetDataBrowserCallbacks(g_browser, &callbacks) != noErr
                || add_column(kCloudColTitle, "Item", 200, 0) != noErr
                || add_column(kCloudColSubtitle, "Detail", 130, 1) != noErr) {
                now_control_dispose(g_browser);
                g_browser = NULL;
                dispose_callbacks();
            } else {
                SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
                SetDataBrowserHasScrollBars(g_browser, false, true);
                now_browser_fill_hilite(g_browser);
                HideControl(g_browser);
            }
        }
    }

    if (drive_ops->create != NULL) {
        drive_ops->create(owner);
    }
    /* Photos' create records the window, registers the wire's preview
       hook, and (2026-08-02) builds its own Name/Size/Modified Data
       Browser — which needs the store pointer and the shell's own
       notify UPP bound BEFORE create runs, the way this view's own
       controls need g_r placed before they are shown. A NULL
       notify_upp here (g_browser's own creation failed above) is
       handled the same defensive way a NULL g_data_upp already is:
       the view degrades its own control, not the page. The wire's ONE
       cloud.preview hook is registered once, below, for the shared
       well — not per view. */
    {
        const CloudViewOps *photos_ops = cloud_photos_view_ops();
        CloudPhotosHost photos_host;

        photos_host.store = &g_store;
        photos_host.notify_upp = g_notify_upp;
        cloud_photos_view_bind(&photos_host);
        if (photos_ops->create != NULL) {
            photos_ops->create(owner);
        }
    }
    /* Contacts' create builds its own browser; bound after, the same
       order drive's own create/bind already keeps (creation does not
       need the host, only later requests do). */
    {
        const CloudViewOps *contacts_ops = cloud_contacts_view_ops();
        CloudContactsHost contacts_host;

        if (contacts_ops->create != NULL) {
            contacts_ops->create(owner);
        }
        contacts_host.row_selected = note_row_selected;
        contacts_host.row_deselected = note_row_deselected;
        contacts_host.in_rebuild = shell_in_rebuild;
        cloud_contacts_view_bind(&contacts_host, &g_store);
    }
    cloud_preview_well_init();
    host.clear_list = clear_list;
    host.invalidate_detail = invalidate_detail;
    host.set_status = set_status;
    host.set_loading = set_loading;
    host.add_rows = filter_and_add;
    cloud_drive_view_bind(&host);
    cloud_drive_view_activate(false);

    conn_set_cloud_note(cloud_answers);
    return noErr;
}

static void cloud_dispose(void)
{
    conn_set_cloud_note(NULL);
    cloud_photos_view_dispose();
    cloud_drive_view_dispose();
    cloud_contacts_view_dispose();
    cloud_preview_well_dispose();
    /* The Data Browser goes BEFORE its UPPs: disposal fires item
       notifications through them (files_browser_view.c and the finding
       carbon-upp-is-not-a-cast-on-cfm carry the full story). */
    if (g_browser != NULL) {
        now_control_dispose(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    g_popup = NULL;
    g_refresh = NULL;
    g_save = NULL;
    g_back = NULL;
    g_fwd = NULL;
    g_menu = NULL;
    g_owner = NULL;
    g_view = NULL;
    g_watch_get = false;
    reset_card_prefetch();
}

static void show_control(ControlRef control, Boolean on)
{
    if (control == NULL) {
        return;
    }
    if (on) {
        ShowControl(control);
    } else {
        HideControl(control);
    }
}

/* The one action button, worn per mode: Up in the drive browser
   (enabled off the root), Save for a selected row elsewhere -- except
   Contacts, whose cloud.get the contract refuses not-listable (x-cloud,
   contacts): the card is the deliverable, so the button never earns a
   place, the same way drive_mode's own listable check already keeps
   it off Drive. */
static Boolean action_applies(void)
{
    const CloudService *service = current_service();

    if (g_drive_mode) {
        return !cloud_drive_view_at_root();
    }
    return service != NULL && g_selected >= 0
        && g_selected < g_store.row_count
        && cloud_service_listable(service->service)
        && strcmp(service->service, "contacts") != 0;
}

static void cloud_show(Boolean visible)
{
    g_visible = visible;
    if (!visible) {
        /* A hidden page holds no focus; keys typed on the next page
           must not land in this one's search field. */
        g_search_focus = false;
    }
    show_control(g_popup, visible);
    show_control(g_refresh, visible);
    show_control(g_save, visible && action_applies());
    /* One browser on stage per mode; the history pair is drive chrome. */
    show_own_browser(visible);
    show_control(g_back, visible && g_drive_mode);
    show_control(g_fwd, visible && g_drive_mode);
    if (g_view != NULL && g_view->show != NULL) {
        g_view->show(visible);
    }
    if (visible && !g_asked_once && conn_is_connected()) {
        g_asked_once = true;
        ask_services();
    }
}

/* Recomputes g_r from g_body/g_drive_mode and moves every shell
   control to match — the body of the old cloud_layout() op, pulled out
   so choose_service() can call it too: drive and list mode use
   different rectangles (cloud_layout.c's drive variant), and a service
   pick changes g_drive_mode without a grow/zoom event to trigger the
   Workshop's own layout() call. */
static void apply_layout(void)
{
    Rect action;

    cloud_layout_compute(&g_body, g_drive_mode, &g_r);
    if (g_popup != NULL) {
        MoveControl(g_popup, g_r.popup.left, g_r.popup.top);
        SizeControl(g_popup, (SInt16)(g_r.popup.right - g_r.popup.left),
                    (SInt16)(g_r.popup.bottom - g_r.popup.top));
    }
    if (g_refresh != NULL) {
        MoveControl(g_refresh, g_r.refresh_btn.left, g_r.refresh_btn.top);
        SizeControl(g_refresh,
                    (SInt16)(g_r.refresh_btn.right - g_r.refresh_btn.left),
                    (SInt16)(g_r.refresh_btn.bottom - g_r.refresh_btn.top));
    }
    /* The one action button, worn per mode (see action_applies()): Up
       rides the toolbar row in drive mode, Save sits in the card pane
       otherwise. Its RECT moves with its title; save_btn is the
       anti-rect while up_btn is live, and vice versa, so this needs no
       mode check beyond picking which field. */
    action = g_drive_mode ? g_r.up_btn : g_r.save_btn;
    if (g_save != NULL) {
        MoveControl(g_save, action.left, action.top);
        SizeControl(g_save, (SInt16)(action.right - action.left),
                    (SInt16)(action.bottom - action.top));
    }
    if (g_back != NULL) {
        MoveControl(g_back, g_r.back_btn.left, g_r.back_btn.top);
        SizeControl(g_back,
                    (SInt16)(g_r.back_btn.right - g_r.back_btn.left),
                    (SInt16)(g_r.back_btn.bottom - g_r.back_btn.top));
    }
    if (g_fwd != NULL) {
        MoveControl(g_fwd, g_r.fwd_btn.left, g_r.fwd_btn.top);
        SizeControl(g_fwd,
                    (SInt16)(g_r.fwd_btn.right - g_r.fwd_btn.left),
                    (SInt16)(g_r.fwd_btn.bottom - g_r.fwd_btn.top));
    }
    /* g_r fits exactly one mode, so only the browser that mode shows
       is sized from it; the others keep their stale geometry, hidden,
       until their own mode's apply_layout runs. Drive's, Photos' and
       Contacts' own browsers are placed by their own view's layout op,
       below. */
    if (view_own_browser() == NULL && g_browser != NULL) {
        MoveControl(g_browser, g_r.list.left, g_r.list.top);
        SizeControl(g_browser, (SInt16)(g_r.list.right - g_r.list.left),
                    (SInt16)(g_r.list.bottom - g_r.list.top));
    }
    if (g_view != NULL && g_view->layout != NULL) {
        g_view->layout(&g_r);
    }
}

static void cloud_layout(const Rect *body)
{
    g_body = *body;
    apply_layout();
}

/* This page positions by baseline; the describing face derives the rect
   from the baseline and a right edge. A NULL writer draws as before. */
static void emit_at(const WorkshopSceneWriter *writer, short x, short y,
                    short right, const char *s)
{
    Str255 t;

    if (writer != NULL) {
        Rect where;

        SetRect(&where, x, (short)(y - 11), right, (short)(y + 3));
        workshop_scene_add(writer, kWorkshopSceneStaticText, s, &where,
                           true);
        return;
    }
    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

static void draw_at(short x, short y, const char *s)
{
    emit_at(NULL, x, y, 0, s);
}

/* The search field: software_module.c's hand-drawn shape exactly — a
   framed white well, a plain focus ring (not Aqua) when it has focus,
   the placeholder word when it does not and is empty. Fore-painted
   only, never a background change (RGBBackColor is port state on the
   one shared Workshop window). */
static void emit_search(const WorkshopSceneWriter *writer)
{
    Rect f = g_r.toolbar_search;
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };

    if (writer != NULL) {
        Rect inner = f;

        InsetRect(&inner, 3, 1);
        workshop_scene_add(writer, kWorkshopScenePanel, "", &f, true);
        workshop_scene_add(writer, kWorkshopSceneStaticText,
                           g_search[0] != '\0' ? g_search : "search",
                           &inner, true);
        return;
    }
    RGBForeColor(&black);
    FrameRect(&f);
    if (g_search_focus) {
        Rect ring = f;

        InsetRect(&ring, -2, -2);
        FrameRect(&ring);
    }
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

/* Echo a keystroke into the field directly — the redraw contract's
   immediate-feedback exception, typing echo being its canonical case
   (software_module.c's echo_search_delta, same shape). Erases only from
   the end of the unchanged prefix to the field's right edge, so nothing
   is invalidated: a real update reproduces these exact pixels from
   g_search, and a whole-field invalidate reads as a white blink per key
   on metal. */
static void echo_search_delta(const char *old_text)
{
    Rect f = g_r.toolbar_search;
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
        InvalWindowRect(g_owner, &g_r.toolbar_search);
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

static void cloud_draw(void)
{
    const CloudService *service = current_service();

    if (g_owner == NULL || !g_visible) {
        return;
    }
    /* The status line. */
    emit_at(NULL, (short)(g_r.status.left + 2),
            (short)(g_r.status.bottom - 3), 0, g_status);

    emit_search(NULL);

    /* The card pane: whichever view is active draws it. */
    if (g_view != NULL && g_view->draw != NULL) {
        g_view->draw(&g_r, &g_store, service, g_selected);
    }
}

static Boolean cloud_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (PtInRect(local, &g_r.toolbar_search)) {
        if (!g_search_focus) {
            g_search_focus = true;
            InvalWindowRect(g_owner, &g_r.toolbar_search);
        }
        return true;
    }
    if (g_search_focus) {
        g_search_focus = false;
        InvalWindowRect(g_owner, &g_r.toolbar_search);
    }
    if (PtInRect(local, &g_r.list)) {
        ControlRef list = active_browser();

        if (list != NULL) {
            HandleControlClick(list, local, event->modifiers, NULL);
            return true;
        }
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    /* A control the shell does not own gets offered to the active view
       BEFORE the generic track below: the view knows which action proc
       its control needs (photos' Size popup wants the popup CDEF's
       own, not now_pump_action). */
    if (control != g_popup && control != g_refresh && control != g_save
        && control != g_back && control != g_fwd
        && g_view != NULL && g_view->control_click != NULL
        && g_view->control_click(control, event, local)) {
        return true;
    }
    if (control == g_popup) {
        short before = GetControlValue(g_popup);

        /* Popup CDEFs run their own action; -1L is the documented
           value, and now_pump_action would starve the wire less than
           the menu loop already does (nested-loops.md). */
        TrackControl(control, local, (ControlActionUPP)-1L);
        if (GetControlValue(g_popup) != before) {
            /* A new service's rows are not what the old search text
               was about — software_module.c clears its own search the
               same way on a domain switch. */
            g_search[0] = '\0';
            choose_service(GetControlValue(g_popup) - 1);
            InvalWindowRect(g_owner, &g_r.toolbar_search);
        }
        return true;
    }
    if (TrackControl(control, local, now_pump_action()) == 0) {
        return control == g_refresh || control == g_save
            || control == g_back || control == g_fwd;
    }
    if (control == g_refresh) {
        ask_services();
        return true;
    }
    if (control == g_back) {
        cloud_drive_view_go_back();
        return true;
    }
    if (control == g_fwd) {
        cloud_drive_view_go_forward();
        return true;
    }
    if (control == g_save) {
        if (g_view != NULL && g_view->click != NULL) {
            g_view->click(event, local);
        } else {
            ask_save();
        }
        return true;
    }
    return false;
}

static Boolean cloud_key(const EventRecord *event)
{
    ControlRef focus = NULL;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (g_search_focus) {
        char ch = (char)(event->message & charCodeMask);
        char old_text[48];
        long n;

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
            return false;              /* arrows and kin are not ours */
        }
        refilter_browser();
        echo_search_delta(old_text);
        return true;
    }
    {
        ControlRef list = active_browser();

        if (list == NULL) {
            return false;
        }
        if (GetKeyboardFocus(g_owner, &focus) != noErr || focus != list) {
            return false;
        }
        if (g_view != NULL && g_view->key != NULL
            && g_view->key(event, g_selected)) {
            return true;
        }
        HandleControlKey(list,
                         (SInt16)((event->message & keyCodeMask) >> 8),
                         (char)(event->message & charCodeMask),
                         event->modifiers);
    }
    return true;
}

static void cloud_activate(Boolean active)
{
    /* All four browsers follow the window: a hidden one must not wake
       in yesterday's activation state when its mode returns. */
    ControlRef lists[4];
    int i;

    lists[0] = g_browser;
    lists[1] = cloud_drive_view_browser();
    lists[2] = cloud_photos_view_browser();
    lists[3] = cloud_contacts_view_browser();
    for (i = 0; i < 4; ++i) {
        if (lists[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(lists[i]);
        } else {
            DeactivateControl(lists[i]);
        }
    }
}

/* One step of the Contacts card prefetch: ask cloud.detail for the
   next un-cached listed row, but only while the wire's single
   cloud-ask slot is genuinely free -- no page still loading, no
   selection's own ask in flight, and (g_prefetch_pending) no earlier
   prefetch ask still awaiting an answer. That last check is what
   keeps this to "one ask in flight, ever": drive_card_prefetch runs
   once per idle pass, and every pass but the one that just got an
   answer finds g_prefetch_pending still true and does nothing. A
   refusal or a dropped connection is silent here on purpose -- the
   same row is tried again next pass once the wire recovers, and a
   status line for a background courtesy fetch would drown out
   whatever the page is actually telling the person right now. */
static void drive_card_prefetch(void)
{
    const CloudService *service;
    char err[96];

    if (!g_contacts_mode || g_owner == NULL || !g_visible) {
        return;
    }
    if (g_prefetch_pending || now_wire_cloud_pending()) {
        return;
    }
    while (g_prefetch_next < g_store.row_count
           && cloud_card_cache_get(&g_card_cache,
                                   g_store.rows[g_prefetch_next].item,
                                   NULL, NULL)) {
        ++g_prefetch_next;
    }
    if (g_prefetch_next >= g_store.row_count) {
        return;                    /* every listed row is cached (or
                                       the list is still empty) */
    }
    service = current_service();
    if (service == NULL
        || now_wire_cloud_detail(service->service,
                                 g_store.rows[g_prefetch_next].item,
                                 err, sizeof err) != 0) {
        return;                    /* try again next idle pass */
    }
    g_prefetch_pending = true;
}

static void cloud_idle(void)
{
    Boolean save_on;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    /* The page may have been opened before the connection finished; the
       first ask fires as soon as there is a wire to ask on. One flag
       check per pass, and only until it has happened once. */
    if (!g_asked_once && conn_is_connected()) {
        g_asked_once = true;
        ask_services();
    }
    drive_card_prefetch();
    if (g_view != NULL && g_view->idle != NULL) {
        g_view->idle(&g_r);
    }
    /* The receive the page said "Receiving..." about has ended when
       the wire's outcome sequence moves: replace the status with how
       it went, once, and stand down. The listing status returns with
       the next natural update. */
    if (g_watch_get) {
        char line[96];

        if (now_wire_receive_outcome(line, sizeof line) != g_watch_seq) {
            g_watch_get = false;
            set_status(line[0] != '\0' ? line : "Done");
        }
    }
    /* Show/hide is the cheap operation that is safe every pass; the
       rectangle repaints only when the answer changed. Invalidate
       wherever the button actually IS - up_btn in drive mode,
       save_btn otherwise, the same choice apply_layout() made when it
       last moved g_save there. */
    save_on = action_applies();
    if (save_on != g_shown_save_on) {
        Rect action = g_drive_mode ? g_r.up_btn : g_r.save_btn;

        g_shown_save_on = save_on;
        show_control(g_save, g_visible && save_on);
        InvalWindowRect(g_owner, &action);
    }
    /* The history pair dims, never hides, when its stack is empty —
       and HiliteControl repaints whatever it is handed, so it runs
       only on a change of answer (the g_shown_* discipline every
       module keeps for exactly this). */
    if (g_drive_mode) {
        Boolean on = cloud_drive_view_can_back();

        if (g_back != NULL && on != g_shown_back_on) {
            g_shown_back_on = on;
            HiliteControl(g_back, (ControlPartCode)(on ? 0 : 255));
        }
        on = cloud_drive_view_can_forward();
        if (g_fwd != NULL && on != g_shown_fwd_on) {
            g_shown_fwd_on = on;
            HiliteControl(g_fwd, (ControlPartCode)(on ? 0 : 255));
        }
    }
    if (strcmp(g_status, g_shown_status) != 0) {
        strcpy(g_shown_status, g_status);
        invalidate_status();
    }
}

static void cloud_status_text(char *out, long cap)
{
    const CloudService *service = current_service();

    /* ALWAYS write: the Workshop hands a stack buffer, and leaving it
       untouched drew a different garbage string every pass — watched
       on the PowerBook. The page's own news outranks the service line,
       because it is where errors land. */
    if (cap < 1) {
        return;
    }
    out[0] = '\0';
    if (g_loading) {
        snprintf(out, (size_t)cap, "Asking...");
    } else if (g_search[0] != '\0'
               && g_shown_rows < active_row_count()) {
        /* The filter's truth outranks the listing's news: a placard
           saying "128 of many" over a three-row list is the page
           contradicting itself. software_module's rule, verbatim. */
        snprintf(out, (size_t)cap, "%d of %d shown", g_shown_rows,
                 active_row_count());
    } else if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%.120s", g_status);
    } else if (service != NULL) {
        snprintf(out, (size_t)cap, "%.30s - %.60s", service->label,
                 service->detail[0] != '\0' ? service->detail
                                            : service->state);
    }
}

/* What this FILE draws: the status line and the hand-drawn search field.
   The listing is a DataBrowser and the toolbar is controls, so both
   already reach the host through control_kind.

   The card pane's interior is drawn by whichever CloudViewOps is active
   (drive, photos, contacts, list), those live in sibling files, and each
   now carries its own describe entry (cloud_view.h) — this shell just
   delegates to it, the same delegation cloud_draw already does for
   pixels. A future fifth view that leaves describe NULL still reports
   the pane's own RECT below, so an observer never sees LESS than "this
   region exists and is not empty chrome" even when a view has nothing
   further to say. */
static void cloud_describe_scene(const WorkshopSceneWriter *writer)
{
    const CloudService *service = current_service();

    emit_at(writer, (short)(g_r.status.left + 2),
            (short)(g_r.status.bottom - 3), g_r.status.right, g_status);
    emit_search(writer);
    workshop_scene_add(writer, kWorkshopScenePanel, "", &g_r.detail_text,
                       true);
    if (g_view != NULL && g_view->describe != NULL) {
        g_view->describe(writer, &g_r, &g_store, service, g_selected);
    }
}

/* Edit>Copy: the status line, the search field and whichever view's
   card is on stage — exactly what cloud_describe_scene reports, one
   walk, so nothing here can drift from either.

   Served by pointing this page's own describe_scene at a buffer instead
   of at the host, so what lands on the clipboard is by construction what
   the page describes, which is by construction what it drew. */
static long cloud_copy_text(char *out, long cap)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter writer;

    workshop_scene_text_begin(&sink, &writer, out, cap);
    cloud_describe_scene(&writer);
    return workshop_scene_text_end(&sink);
}

static const WorkshopModuleOps k_ops = {
    cloud_create,
    cloud_dispose,
    cloud_show,
    cloud_layout,
    cloud_draw,
    cloud_click,
    cloud_key,
    cloud_activate,
    cloud_idle,
    cloud_status_text,
    cloud_describe_scene,
    cloud_copy_text
};

const WorkshopModuleOps *cloud_module_ops(void)
{
    return &k_ops;
}
