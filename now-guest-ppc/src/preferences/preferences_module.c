#include "preferences_module.h"
#include "control_kind.h"

#include <string.h>

#include "pump.h"
#include "workshop_sidebar.h"

/* The Preferences page: settings that belong to the WINDOW rather than
   to any one page in it.

   It deliberately does not gather the other pages' switches. "Log to
   disk" belongs beside the log it writes, the access tier belongs on the
   page that explains what it grants, and a preferences pane that
   collects every switch in the application is how a setting ends up two
   clicks from the thing it affects and explained by neither. What lands
   here is what has no other home: the shape of the rail itself.

   The rearrange gesture is a plain drag on the rail. A gesture nobody
   can see is a gesture nobody finds, so this page states it in words -
   that sentence IS the discoverability, and it is the reason this page
   exists rather than the preference living on alone. It used to say
   Option-drag, and that modifier is gone; a stale sentence here teaches
   a gesture that no longer works, which is worse than no sentence. */

enum {
    kMargin = 16,
    kGroupTitleInset = 16,    /* the group frame's own text inset */
    kLineHeight = 15,
    kCheckHeight = 16,
    kCheckWidth = 200,
    kButtonHeight = 20,
    kButtonWidth = 110,
    kGroupPad = 10
};

typedef struct {
    Rect sidebar_box;         /* group box around the rail settings */
    Rect collapse_check;
    Rect collapse_note;       /* one line under the checkbox */
    Rect arrange_note;        /* the drag-to-rearrange sentence */
    Rect reset_button;
} PrefsRects;

static WindowRef g_owner;
static Rect g_body;
static PrefsRects g_r;
static Boolean g_visible;

static ControlRef g_group;
static ControlRef g_collapse;
static ControlRef g_reset;

static void compute_rects(const Rect *body, PrefsRects *out)
{
    short left = (short)(body->left + kMargin);
    short right = (short)(body->right - kMargin);
    short top = (short)(body->top + kMargin);
    short inner_left = (short)(left + kGroupTitleInset);
    short y;

    /* The group's height is derived from what it holds, so a font that
       measures differently cannot leave the last control outside the
       frame. */
    y = (short)(top + kGroupPad + 8);
    out->collapse_check.left = inner_left;
    out->collapse_check.top = y;
    out->collapse_check.right = (short)(inner_left + kCheckWidth);
    out->collapse_check.bottom = (short)(y + kCheckHeight);

    y = (short)(out->collapse_check.bottom + 2);
    out->collapse_note.left = (short)(inner_left + 18);
    out->collapse_note.top = y;
    out->collapse_note.right = (short)(right - kGroupPad);
    out->collapse_note.bottom = (short)(y + kLineHeight);

    y = (short)(out->collapse_note.bottom + 10);
    out->arrange_note.left = inner_left;
    out->arrange_note.top = y;
    out->arrange_note.right = (short)(right - kGroupPad);
    out->arrange_note.bottom = (short)(y + kLineHeight);

    y = (short)(out->arrange_note.bottom + 6);
    out->reset_button.left = inner_left;
    out->reset_button.top = y;
    out->reset_button.right = (short)(inner_left + kButtonWidth);
    out->reset_button.bottom = (short)(y + kButtonHeight);

    out->sidebar_box.left = left;
    out->sidebar_box.top = top;
    out->sidebar_box.right = right;
    out->sidebar_box.bottom = (short)(out->reset_button.bottom + kGroupPad);
}

static void show_control(ControlRef control, Boolean visible)
{
    if (control == NULL) {
        return;
    }
    if (visible) {
        ShowControl(control);
    } else {
        HideControl(control);
    }
}

static OSErr prefs_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_body = *body;
    compute_rects(body, &g_r);

    CopyCStringToPascal("Sidebar", text);
    g_group = now_control_new(owner, &g_r.sidebar_box, text, false, 0, 0, 0,
                         kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Collapse to icons", text);
    g_collapse = now_control_new(owner, &g_r.collapse_check, text, false,
                            workshop_sidebar_collapsed() ? 1 : 0, 0, 1,
                            checkBoxProc, 0);
    CopyCStringToPascal("Reset Order", text);
    g_reset = now_control_new(owner, &g_r.reset_button, text, false, 0, 0, 0,
                         pushButProc, 0);
    if (g_group == NULL || g_collapse == NULL || g_reset == NULL) {
        return memFullErr;
    }
    return noErr;
}

static void prefs_dispose(void)
{
    /* Controls die with the window; no UPP is constructed here. */
    g_owner = NULL;
    g_group = NULL;
    g_collapse = NULL;
    g_reset = NULL;
}

static void prefs_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_group, visible);
    show_control(g_collapse, visible);
    show_control(g_reset, visible);
    if (visible && g_collapse != NULL) {
        /* The rail can be collapsed without this page - the header button
           does it, and a saved setting is read at launch - so the box
           states what IS rather than what it last set. */
        SetControlValue(g_collapse, workshop_sidebar_collapsed() ? 1 : 0);
    }
}

static void move_control(ControlRef control, const Rect *r)
{
    if (control == NULL) {
        return;
    }
    MoveControl(control, r->left, r->top);
    SizeControl(control, (SInt16)(r->right - r->left),
                (SInt16)(r->bottom - r->top));
}

static void prefs_layout(const Rect *body)
{
    g_body = *body;
    compute_rects(body, &g_r);
    move_control(g_group, &g_r.sidebar_box);
    move_control(g_collapse, &g_r.collapse_check);
    move_control(g_reset, &g_r.reset_button);
}

/* Drawn with a NULL writer, described with one. Two faces, one walk. */
static void emit_line(const WorkshopSceneWriter *writer, const Rect *r,
                      const char *line)
{
    Str255 text;

    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopSceneStaticText, line, r, true);
        return;
    }
    MoveTo(r->left, (short)(r->top + 11));
    CopyCStringToPascal(line, text);
    TruncString((short)(r->right - r->left), text, truncEnd);
    DrawString(text);
}

static void prefs_content(const WorkshopSceneWriter *writer)
{
    emit_line(writer, &g_r.collapse_note,
              "Icons only. Rest the pointer on one to read its name.");
    /* Plain hyphen and plain quotes: a drawable string here is MacRoman,
       and a UTF-8 dash renders as mojibake through DrawString. */
    emit_line(writer, &g_r.arrange_note,
              "To rearrange the sidebar, drag a row up or down.");
}

static void prefs_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    prefs_content(NULL);
}

static void prefs_describe_scene(const WorkshopSceneWriter *writer)
{
    prefs_content(writer);
}

static Boolean prefs_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    (void)event;
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    if (control == g_collapse) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            Boolean want = (Boolean)(GetControlValue(g_collapse) == 0);

            SetControlValue(g_collapse, want ? 1 : 0);
            /* Same shape as the density: the rail's WIDTH changes, so the
               window relays out and nothing here invalidates by hand. */
            workshop_sidebar_set_collapsed(want);
        }
        return true;
    }
    if (control == g_reset) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            workshop_sidebar_reset_order();
        }
        return true;
    }
    return false;
}

static void prefs_activate(Boolean active)
{
    ControlRef controls[3];
    int i;

    controls[0] = g_group;
    controls[1] = g_collapse;
    controls[2] = g_reset;
    for (i = 0; i < 3; ++i) {
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

static void prefs_status_line(char *out, long cap)
{
    const char *line = workshop_sidebar_collapsed()
                           ? "Icons only. Drag a row to rearrange."
                           : "Drag a row to rearrange the sidebar.";

    strncpy(out, line, (size_t)(cap - 1));
    out[cap - 1] = '\0';
}

/* No idle op: nothing on this page changes on its own, and an idle that
   runs every pass to discover that is the cost the start-here doc names.
   No key op either - the checkbox and the button are reached by mouse,
   and this window has no keyboard focus machinery to hang one on. */
static const WorkshopModuleOps k_ops = {
    prefs_create,
    prefs_dispose,
    prefs_show,
    prefs_layout,
    prefs_draw,
    prefs_click,
    NULL,
    prefs_activate,
    NULL,
    prefs_status_line,
    prefs_describe_scene
};

const WorkshopModuleOps *preferences_module_ops(void)
{
    return &k_ops;
}
