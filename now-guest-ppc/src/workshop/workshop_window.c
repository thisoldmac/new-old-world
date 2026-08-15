#include "workshop_window.h"

#include <stdio.h>
#include <string.h>

#include "control_kind.h"
#include "nowlog.h"
#include "prefs.h"
#include "screen_bounds.h"
#include "proc_actions.h"
#include "workshop_layout.h"
#include "workshop_construct.h"
#include "workshop_registry.h"
#include "workshop_sidebar.h"
#include "wire.h"

static WindowRef g_window;
static WorkshopLayout g_lay;
static WorkshopModuleID g_selected = kWorkshopScreenshots;
static Boolean g_active;
/* Header readout cache; idle repaints the header only when the peer's
   name actually changes. */
static char g_shown_peer[40];

static WorkshopModuleInstance g_modules[kWorkshopModuleCount + 1];

static WorkshopModuleInstance *module_instance(WorkshopModuleID page_id)
{
    if ((int)page_id < 1 || (int)page_id > kWorkshopModuleCount) {
        return NULL;
    }
    return &g_modules[page_id];
}

static WorkshopModuleInstance *selected_instance(void)
{
    return module_instance(g_selected);
}

static const WorkshopModuleDefinition *selected_definition(void)
{
    WorkshopModuleInstance *instance = selected_instance();
    return instance != NULL ? instance->definition : NULL;
}

static const char *selected_placeholder(void)
{
    WorkshopModuleInstance *instance = selected_instance();
    if (instance == NULL || instance->definition == NULL) {
        return "This Workshop module is unavailable.";
    }
    if (!instance->admitted && instance->unavailable_reason != NULL) {
        return instance->unavailable_reason;
    }
    return instance->definition->pending;
}

static const WorkshopModuleOps *selected_ops(void)
{
    WorkshopModuleInstance *instance = selected_instance();
    return instance != NULL ? instance->ops : NULL;
}

static void invalidate_pane(void)
{
    if (g_window == NULL) {
        return;
    }
    InvalWindowRect(g_window, &g_lay.header);
    InvalWindowRect(g_window, &g_lay.body);
    InvalWindowRect(g_window, &g_lay.status);
}

static void compute_layout(void)
{
    Rect content;
    WorkshopRailSpec spec;

    GetWindowPortBounds(g_window, &content);
    /* The rail's density and scroll position are the sidebar's state, so
       the geometry is asked for rather than assumed - a grow, a density
       change and a scroll all land here and must agree. */
    workshop_sidebar_rail_spec(&spec);
    workshop_layout_compute(&content, &spec, &g_lay);
}

/* Standard bounds: the spec's content size, centered, clamped to the
   desktop so the title bar and grow box stay reachable at 640x480. */
static void standard_bounds(Rect *bounds)
{
    Rect screen;
    short w = kWorkshopStdContentW;
    short h = kWorkshopStdContentH;
    short left;
    short top;

    now_screen_desktop(&screen);
    if (screen.right <= screen.left || screen.bottom <= screen.top) {
        /* **UNKNOWN, so no clamp.** Nothing measured this machine's
           screen, and clamping to an empty rect would produce a window
           of nothing at all. The spec's own standard size is the honest
           answer: it fits the screen this app was designed for, and it
           is not a claim about the screen in front of the person. */
        SetRect(bounds, 8, 44, (short)(8 + w), (short)(44 + h));
        return;
    }
    if (screen.right - screen.left - 12 < w) {
        w = (short)(screen.right - screen.left - 12);
    }
    if (screen.bottom - screen.top - 32 < h) {
        h = (short)(screen.bottom - screen.top - 32);
    }
    if (w < kWorkshopMinContentW) {
        w = kWorkshopMinContentW;
    }
    if (h < kWorkshopMinContentH) {
        h = kWorkshopMinContentH;
    }
    left = (short)(screen.left + (screen.right - screen.left - w) / 2);
    top = (short)(screen.top + 24
                  + (screen.bottom - screen.top - 24 - h) / 3);
    SetRect(bounds, left, top, (short)(left + w), (short)(top + h));
}

static void on_sidebar_select(WorkshopModuleID module)
{
    workshop_select_module(module);
}

typedef struct ModuleConstruction {
    WorkshopModuleInstance *instance;
} ModuleConstruction;

static unsigned long module_begin(void *opaque)
{
    (void)opaque;
    return now_control_generation();
}

static int module_create(void *opaque)
{
    ModuleConstruction *construction = (ModuleConstruction *)opaque;
    const WorkshopModuleOps *ops = construction->instance->ops;
    return ops->create(g_window, &g_lay.body) == noErr;
}

static void module_dispose(void *opaque)
{
    ModuleConstruction *construction = (ModuleConstruction *)opaque;
    const WorkshopModuleOps *ops = construction->instance->ops;
    if (ops->dispose != NULL) ops->dispose();
}

static void module_rollback(void *opaque, unsigned long marker)
{
    (void)opaque;
    now_control_rollback_window_since(g_window, marker);
}

static void ensure_module_created(WorkshopModuleID module)
{
    WorkshopModuleInstance *instance = module_instance(module);

    if (instance != NULL && instance->admitted && instance->ops != NULL
        && !instance->created && instance->ops->create != NULL) {
        ModuleConstruction construction;
        NowWorkshopConstructOps transaction;

        construction.instance = instance;
        transaction.context = &construction;
        transaction.begin = module_begin;
        transaction.create = module_create;
        transaction.dispose = module_dispose;
        transaction.rollback = module_rollback;
        now_workshop_ensure_constructed(&instance->created, &transaction);
        if (!instance->created) {
            now_log(kLogWarn, "app", "%s construction failed; rolled back",
                    instance->definition->title);
        }
    }
}

/* A restored rectangle is only used when it still fits the desktop and
   the minimum size; anything else falls back to the standard bounds. */
static Boolean restorable_bounds(const Rect *r)
{
    Rect screen;
    RgnHandle desktop = GetGrayRgn();

    if (r->right - r->left < kWorkshopMinContentW
        || r->bottom - r->top < kWorkshopMinContentH) {
        return false;
    }
    if (desktop == NULL) {
        return true;
    }
    GetRegionBounds(desktop, &screen);
    return r->left >= screen.left - 8 && r->top >= screen.top + 12
        && r->left + 64 < screen.right && r->top < screen.bottom - 64;
}

Boolean workshop_open(void)
{
    Rect bounds;
    Str255 title;
    NowPrefs prefs;

    /* SHOW THE APPLICATION FIRST. Hiding NOW leaves it frontmost (see
       proc_actions.h), so Windows > Workshop stays reachable while every
       window it could select is invisible - and SelectWindow on a hidden
       application shows nothing. Every route that promises a Workshop page
       comes through here, so the repair belongs here rather than in each
       menu item. */
    now_proc_show_self();

    if (g_window != NULL) {
        SelectWindow(g_window);
        return true;
    }
    if (!workshop_registry_prepare(g_modules, kWorkshopModuleCount + 1,
                                   NULL, NULL)) {
        now_log(kLogError, "app", "Workshop module registry is incomplete");
        return false;
    }
    now_prefs_load(&prefs);
    /* Before the first compute_layout, never after: the rail's density
       decides its row height, and therefore every rectangle in the
       window that the rail's width does not already fix. */
    workshop_sidebar_load_prefs();
    workshop_sidebar_set_relayout_fn(workshop_resized);
    if (restorable_bounds(&prefs.workshop_rect)) {
        bounds = prefs.workshop_rect;
    } else {
        standard_bounds(&bounds);
    }
    CreateNewWindow(kDocumentWindowClass, kWindowStandardDocumentAttributes,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return false;
    }
    CopyCStringToPascal("New Old World", title);
    SetWTitle(g_window, title);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive,
                             true);
    /* No root control on this window, on purpose. A root control turns
       the group-box controls into embedders, and an embedded control
       only receives clicks when HIToolbox's standard Carbon Event
       handler routes them - which this WaitNextEvent app does not
       install (same reason as confirm.c's kWindowStandardHandler ban).
       With a root control the "Other Mac" group swallowed clicks to its
       popup, checkbox and button; without it the controls are flat
       siblings the classic Control Manager hit-tests directly. It also
       did not make edit-text usable - text entry lives in a real
       DIALOG (conn_edit_dialog.c), which has its own window and its own
       Dialog-Manager text handling. */
    compute_layout();
    if (!workshop_sidebar_create(g_window, &g_lay, on_sidebar_select)) {
        now_control_dispose_window(g_window);
        g_window = NULL;
        workshop_sidebar_dispose();
        return false;
    }
    g_shown_peer[0] = '\0';
    g_selected = kWorkshopScreenshots;
    if (prefs.workshop_module >= 1
        && prefs.workshop_module <= kWorkshopModuleCount
        && prefs.workshop_module != (short)g_selected) {
        workshop_select_module((WorkshopModuleID)prefs.workshop_module);
    } else {
        WorkshopModuleInstance *initial;

        ensure_module_created(g_selected);
        initial = selected_instance();
        if (initial != NULL && initial->created && initial->ops != NULL
            && initial->ops->show != NULL) {
            initial->ops->show(true);
        }
        workshop_sidebar_set_selection(g_selected);
    }
    ShowWindow(g_window);
    SelectWindow(g_window);
    return true;
}

void workshop_close(Boolean quitting)
{
    int i;

    if (g_window == NULL) {
        return;
    }
    /* The session rides in the prefs file, like the old windows'. A
       user-close (quitting false) and quit teardown (quitting true, and
       we are only here because the window still existed) both write
       workshop_open_at_quit directly from the argument: the field means
       exactly "was the Workshop open when this session last ended", and
       that is precisely what each caller knows at its own call site. */
    {
        NowPrefs prefs;
        Rect bounds;

        now_prefs_load(&prefs);
        GetWindowBounds(g_window, kWindowContentRgn, &bounds);
        prefs.workshop_rect = bounds;
        prefs.workshop_module = (short)g_selected;
        prefs.workshop_open_at_quit = quitting;
        now_prefs_save(&prefs);
    }
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        WorkshopModuleInstance *instance = &g_modules[i];

        if (instance->created && instance->ops != NULL
            && instance->ops->dispose != NULL) {
            instance->ops->dispose();
        }
        instance->created = 0;
    }
    now_control_dispose_window(g_window);          /* takes the controls with it */
    g_window = NULL;
    workshop_sidebar_dispose();       /* after, never before */
}

Boolean workshop_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

WindowRef workshop_ref(void)
{
    return g_window;
}

void workshop_select_module(WorkshopModuleID module)
{
    WorkshopModuleInstance *old_instance;
    WorkshopModuleInstance *new_instance;
    const WorkshopModuleOps *old_ops;
    RgnHandle saved_clip;

    if (g_window == NULL || (int)module < 1
        || (int)module > kWorkshopModuleCount) {
        return;
    }
    workshop_sidebar_set_selection(module);
    if (module == g_selected) {
        return;
    }
    /* HideControl erases each control on the spot and ShowControl
       paints it back, so a switch used to repaint the pane piecemeal
       and then a second time at the update event. Clip the direct
       draws away for the swap; the controls still mark themselves
       hidden or visible, and the invalidation below repaints every
       pixel the clipped calls would have touched - once. */
    SetPortWindowPort(g_window);
    saved_clip = NewRgn();
    if (saved_clip != NULL) {
        Rect none = { 0, 0, 0, 0 };

        GetClip(saved_clip);
        ClipRect(&none);
    }
    old_instance = selected_instance();
    old_ops = old_instance != NULL ? old_instance->ops : NULL;
    if (old_instance != NULL && old_ops != NULL && old_instance->created
        && old_ops->show != NULL) {
        old_ops->show(false);
    }
    g_selected = module;
    ensure_module_created(module);
    new_instance = selected_instance();
    if (new_instance != NULL && new_instance->ops != NULL
        && new_instance->created && new_instance->ops->show != NULL) {
        new_instance->ops->show(true);
    }
    if (saved_clip != NULL) {
        SetClip(saved_clip);
        DisposeRgn(saved_clip);
    }
    invalidate_pane();
}

static void draw_header(void)
{
    const WorkshopModuleDefinition *definition = selected_definition();
    Str255 text;
    char peer[40];
    short right_edge = (short)(g_lay.header.right - 12);

    if (definition == NULL) {
        return;
    }
    DrawThemePlacard(&g_lay.header,
                     g_active ? kThemeStateActive : kThemeStateInactive);
    workshop_sidebar_draw_toggle();
    UseThemeFont(kThemeEmphasizedSystemFont, smSystemScript);
    MoveTo(g_lay.header_text_left, (short)(g_lay.header.top + 16));
    CopyCStringToPascal(definition->title, text);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo(g_lay.header_text_left, (short)(g_lay.header.top + 31));
    CopyCStringToPascal(definition->blurb, text);
    TruncString((short)(right_edge - g_lay.header_text_left - 90), text,
                truncEnd);
    DrawString(text);

    if (conn_is_connected()) {
        conn_peer_label(peer, sizeof peer);
        CopyCStringToPascal(peer, text);
        TruncString(120, text, truncEnd);
        MoveTo((short)(right_edge - StringWidth(text)),
               (short)(g_lay.header.top + 16));
        DrawString(text);
    }
}

static void draw_status(void)
{
    WorkshopModuleInstance *instance = selected_instance();
    Str255 text;
    char line[120];
    const WorkshopModuleOps *ops = selected_ops();

    DrawThemePlacard(&g_lay.status,
                     g_active ? kThemeStateActive : kThemeStateInactive);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo((short)(g_lay.status.left + 10), (short)(g_lay.status.top + 15));
    if (instance != NULL && ops != NULL && instance->created
        && ops->status_text != NULL) {
        ops->status_text(line, sizeof line);
    } else {
        strcpy(line, "Nothing to report yet.");
    }
    CopyCStringToPascal(line, text);
    TruncString((short)(g_lay.grow_safe.left - g_lay.status.left - 14),
                text, truncEnd);
    DrawString(text);
}

static void draw_placeholder_body(void)
{
    WorkshopModuleInstance *instance = selected_instance();
    Str255 text;

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo((short)(g_lay.body.left + 16), (short)(g_lay.body.top + 28));
    CopyCStringToPascal(selected_placeholder(), text);
    TruncString((short)(g_lay.body.right - g_lay.body.left - 32), text,
                truncEnd);
    DrawString(text);
    MoveTo((short)(g_lay.body.left + 16), (short)(g_lay.body.top + 44));
    CopyCStringToPascal(
        instance != NULL && !instance->admitted
            ? "The current product profile does not admit this module."
            : "It moves into the Workshop in a later arc.",
        text);
    DrawString(text);
}

void workshop_draw(void)
{
    WorkshopModuleInstance *instance = selected_instance();
    RgnHandle visible;
    const WorkshopModuleOps *ops = selected_ops();

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    /* Erase only what nothing below paints for itself: the module body,
       and the sidebar gutter outside the rail panel (stale after a
       grow). The placards fill their own faces and the rail erases its
       own panel white; the old full-port erase painted the rail rows
       theme-gray a beat before the rail repainted them, one visible
       flicker per page switch. BeginUpdate has already clipped the
       visRgn, so each erase touches only invalidated pixels. */
    EraseRect(&g_lay.body);
    {
        RgnHandle gutter = NewRgn();
        RgnHandle rail = NewRgn();

        if (gutter != NULL && rail != NULL) {
            RectRgn(gutter, &g_lay.sidebar);
            RectRgn(rail, &g_lay.rail_list);
            DiffRgn(gutter, rail, gutter);
            EraseRgn(gutter);
        } else {
            EraseRect(&g_lay.sidebar);
        }
        if (gutter != NULL) {
            DisposeRgn(gutter);
        }
        if (rail != NULL) {
            DisposeRgn(rail);
        }
    }

    draw_header();
    draw_status();

    /* One control pass: UpdateControls draws just the controls the
       update region touches. The DrawControls that used to precede it
       drew every control in the window a second time. */
    visible = NewRgn();
    if (visible != NULL) {
        GetPortVisibleRegion(GetWindowPort(g_window), visible);
        UpdateControls(g_window, visible);
        DisposeRgn(visible);
    }

    /* Module text goes over the controls: group-box interiors are the
       module's canvas, so labels and values land after the frames. */
    if (instance != NULL && ops != NULL && instance->created
        && ops->draw != NULL) {
        ops->draw();
    } else {
        draw_placeholder_body();
    }
    workshop_sidebar_draw();

    /* The grow icon, without the scroll-bar delimiter lines DrawGrowIcon
       would run up both edges: clip it to the corner. */
    visible = NewRgn();
    if (visible != NULL) {
        GetClip(visible);
        ClipRect(&g_lay.grow_safe);
        DrawGrowIcon(g_window);
        SetClip(visible);
        DisposeRgn(visible);
    }
}

void workshop_click(const EventRecord *event)
{
    WorkshopModuleInstance *instance = selected_instance();
    Point local = event->where;
    const WorkshopModuleOps *ops = selected_ops();

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GlobalToLocal(&local);
    /* Before the module: the button lives in the header placard, which
       belongs to this window rather than to whatever page is showing. */
    if (workshop_sidebar_toggle_click(local)) {
        return;
    }
    if (instance != NULL && ops != NULL && instance->created
        && ops->click != NULL
        && ops->click(event, local)) {
        return;
    }
    workshop_sidebar_click(event, local);
}

Boolean workshop_key(const EventRecord *event)
{
    WorkshopModuleInstance *instance = selected_instance();
    char c = (char)(event->message & charCodeMask);
    const WorkshopModuleOps *ops = selected_ops();

    if (g_window == NULL) {
        return false;
    }
    if (instance != NULL && ops != NULL && instance->created
        && ops->key != NULL
        && ops->key(event)) {
        return true;
    }
    if (c == '\t') {
        AdvanceKeyboardFocus(g_window);
        return true;
    }
    return workshop_sidebar_key(event);
}

void workshop_activate(Boolean active)
{
    WorkshopModuleInstance *instance = selected_instance();
    Rect content;

    if (g_window == NULL) {
        return;
    }
    g_active = active;
    workshop_sidebar_activate(active);
    if (instance != NULL && instance->created && instance->ops != NULL
        && instance->ops->activate != NULL) {
        instance->ops->activate(active);
    }
    /* Placards and the grow icon change with activation. */
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &content);
    InvalWindowRect(g_window, &content);
}

void workshop_idle(void)
{
    char peer[40];
    char status[120];
    static char shown_status[120];
    const WorkshopModuleOps *ops;
    int i;

    if (g_window == NULL) {
        return;
    }
    workshop_sidebar_idle();
    workshop_sidebar_tag_idle();
    peer[0] = '\0';
    if (conn_is_connected()) {
        conn_peer_label(peer, sizeof peer);
    }
    if (strcmp(peer, g_shown_peer) != 0) {
        strcpy(g_shown_peer, peer);
        InvalWindowRect(g_window, &g_lay.header);
    }
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        WorkshopModuleInstance *instance = &g_modules[i];

        if (instance->created && instance->ops != NULL
            && instance->ops->idle != NULL) {
            instance->ops->idle();
        }
    }
    /* The status placard mirrors the selected module's line; repaint
       only on change, and only the placard. */
    ops = selected_ops();
    {
        WorkshopModuleInstance *instance = selected_instance();
        if (instance != NULL && ops != NULL && instance->created
            && ops->status_text != NULL) {
            ops->status_text(status, sizeof status);
            if (strcmp(status, shown_status) != 0) {
                strcpy(shown_status, status);
                InvalWindowRect(g_window, &g_lay.status);
            }
        }
    }
}

void workshop_resized(void)
{
    Rect content;
    int i;

    if (g_window == NULL) {
        return;
    }
    compute_layout();
    workshop_sidebar_layout(&g_lay);
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        WorkshopModuleInstance *instance = &g_modules[i];

        if (instance->created && instance->ops != NULL
            && instance->ops->layout != NULL) {
            instance->ops->layout(&g_lay.body);
        }
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &content);
    InvalWindowRect(g_window, &content);
}

void workshop_describe_scene(const WorkshopSceneWriter *writer)
{
    WorkshopModuleInstance *instance = selected_instance();
    const WorkshopModuleDefinition *definition = selected_definition();
    const WorkshopModuleOps *ops = selected_ops();
    Rect text;
    char line[120];
    char peer[40];

    if (g_window == NULL || definition == NULL) {
        return;
    }

    workshop_scene_add(writer, kWorkshopScenePlacard, "", &g_lay.header,
                       g_active);
    workshop_scene_add(writer, kWorkshopScenePlacard, "", &g_lay.status,
                       g_active);
    workshop_sidebar_describe_scene(writer);

    SetRect(&text, (short)(g_lay.header.left + 12),
            (short)(g_lay.header.top + 4),
            (short)(g_lay.header.right - 12),
            (short)(g_lay.header.top + 19));
    workshop_scene_add(writer, kWorkshopSceneStaticText,
                       definition->title, &text, true);
    SetRect(&text, (short)(g_lay.header.left + 12),
            (short)(g_lay.header.top + 19),
            (short)(g_lay.header.right - 102),
            (short)(g_lay.header.top + 35));
    workshop_scene_add(writer, kWorkshopSceneStaticText,
                       definition->blurb, &text, true);
    if (conn_is_connected()) {
        conn_peer_label(peer, sizeof peer);
        SetRect(&text, (short)(g_lay.header.right - 132),
                (short)(g_lay.header.top + 4),
                (short)(g_lay.header.right - 12),
                (short)(g_lay.header.top + 19));
        workshop_scene_add(writer, kWorkshopSceneStaticText, peer, &text,
                           true);
    }

    if (instance != NULL && ops != NULL && instance->created
        && ops->describe_scene != NULL) {
        ops->describe_scene(writer);
    } else if (instance == NULL || ops == NULL || !instance->created) {
        SetRect(&text, (short)(g_lay.body.left + 16),
                (short)(g_lay.body.top + 16),
                (short)(g_lay.body.right - 16),
                (short)(g_lay.body.top + 34));
        workshop_scene_add(writer, kWorkshopSceneStaticText,
                           selected_placeholder(), &text, true);
    }

    if (instance != NULL && ops != NULL && instance->created
        && ops->status_text != NULL) {
        ops->status_text(line, sizeof line);
    } else {
        strcpy(line, "Nothing to report yet.");
    }
    SetRect(&text, (short)(g_lay.status.left + 10),
            (short)(g_lay.status.top + 3),
            (short)(g_lay.grow_safe.left - 4),
            (short)(g_lay.status.top + 19));
    workshop_scene_add(writer, kWorkshopSceneStaticText, line, &text, true);
}
