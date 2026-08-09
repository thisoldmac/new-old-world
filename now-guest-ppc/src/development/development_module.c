#include "development_module.h"

#include <stdio.h>
#include <string.h>

#include "control_kind.h"
#include "development_layout.h"
#include "development_toolchain_mac.h"
#include "fileshare.h"
#include "prefs.h"
#include "pump.h"

static WindowRef g_owner;
static Boolean g_visible;
static DevelopmentLayout g_r;
static ControlRef g_projects_box;
static ControlRef g_projects_choose;
static ControlRef g_toolchain_box;
static ControlRef g_toolchain_register;
static ControlRef g_jobs_box;
static ControlRef g_cancel;
static char g_problem[160];

static void show_control(ControlRef control, Boolean visible)
{
    if (control == NULL) return;
    if (visible) ShowControl(control); else HideControl(control);
}

static void move_control(ControlRef control, const Rect *r)
{
    if (control == NULL) return;
    MoveControl(control, r->left, r->top);
    SizeControl(control, (SInt16)(r->right - r->left),
                (SInt16)(r->bottom - r->top));
}

static OSErr development_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_problem[0] = '\0';
    development_layout_compute(body, &g_r);
    CopyCStringToPascal("Projects", text);
    g_projects_box = now_control_new(owner, &g_r.projects_box, text, false,
        0, 0, 0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Choose Projects Folder...", text);
    g_projects_choose = now_control_new(owner, &g_r.projects_choose, text,
        false, 0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("Toolchains", text);
    g_toolchain_box = now_control_new(owner, &g_r.toolchain_box, text, false,
        0, 0, 0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Register MPW Folder...", text);
    g_toolchain_register = now_control_new(owner, &g_r.register_toolchain,
        text, false, 0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("Build Jobs", text);
    g_jobs_box = now_control_new(owner, &g_r.jobs_box, text, false,
        0, 0, 0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Cancel Job", text);
    g_cancel = now_control_new(owner, &g_r.cancel_job, text, false,
        0, 0, 1, pushButProc, 0);
    if (g_projects_box == NULL || g_projects_choose == NULL
        || g_toolchain_box == NULL || g_toolchain_register == NULL
        || g_jobs_box == NULL || g_cancel == NULL) return memFullErr;
    HiliteControl(g_cancel, 255);
    return noErr;
}

static void development_dispose(void)
{
    g_owner = NULL;
    g_projects_box = g_projects_choose = NULL;
    g_toolchain_box = g_toolchain_register = NULL;
    g_jobs_box = g_cancel = NULL;
}

static void development_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_projects_box, visible);
    show_control(g_projects_choose, visible);
    show_control(g_toolchain_box, visible);
    show_control(g_toolchain_register, visible);
    show_control(g_jobs_box, visible);
    show_control(g_cancel, visible);
}

static void development_layout(const Rect *body)
{
    development_layout_compute(body, &g_r);
    move_control(g_projects_box, &g_r.projects_box);
    move_control(g_projects_choose, &g_r.projects_choose);
    move_control(g_toolchain_box, &g_r.toolchain_box);
    move_control(g_toolchain_register, &g_r.register_toolchain);
    move_control(g_jobs_box, &g_r.jobs_box);
    move_control(g_cancel, &g_r.cancel_job);
}

static void draw_line(const Rect *r, const char *text)
{
    Str255 ptext;
    MoveTo(r->left, (short)(r->top + 12));
    CopyCStringToPascal(text, ptext);
    TruncString((short)(r->right - r->left), ptext, truncMiddle);
    DrawString(ptext);
}

static void development_draw(void)
{
    NowPrefs prefs;
    char line[180];

    if (g_owner == NULL || !g_visible) return;
    now_prefs_load(&prefs);
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    snprintf(line, sizeof line, "Projects root: %s",
             prefs.projects_root[0] ? prefs.projects_root : "Not chosen");
    draw_line(&g_r.projects_path, line);
    if (prefs.toolchain_root[0]) {
        snprintf(line, sizeof line, "MPW: %s (%s)", prefs.toolchain_root,
                 prefs.toolchain_qualified ? "qualified" : "not qualified");
    } else {
        strcpy(line, "No MPW toolchain is registered.");
    }
    draw_line(&g_r.toolchain_status, line);
    draw_line(&g_r.jobs_status, "No build job is active.");
}

static int choose_root(Boolean toolchain)
{
    short vref;
    long dir;
    char why[160];
    char path[128];
    NowPrefs prefs;
    int chosen = now_files_choose_folder(toolchain ? "Choose the MPW folder"
                                                   : "Choose the Projects folder",
                                         &vref, &dir, why, sizeof why);
    if (chosen <= 0) {
        if (chosen < 0) strncpy(g_problem, why, sizeof g_problem - 1);
        return chosen;
    }
    if (!now_files_dir_path(vref, dir, path, sizeof path)) {
        strcpy(g_problem, "The chosen folder could not be named.");
        return -1;
    }
    now_prefs_load(&prefs);
    if (toolchain) {
        DevToolchain measured;
        prefs.toolchain_vref = vref;
        prefs.toolchain_dir = dir;
        strncpy(prefs.toolchain_root, path, sizeof prefs.toolchain_root - 1);
        prefs.toolchain_qualified =
            dev_toolchain_measure(vref, dir, &measured) == noErr;
        if (!prefs.toolchain_qualified) {
            strcpy(g_problem,
                   "The folder must contain ToolServer and Tools:MrC.");
        }
    } else {
        prefs.projects_vref = vref;
        prefs.projects_dir = dir;
        strncpy(prefs.projects_root, path, sizeof prefs.projects_root - 1);
    }
    if (now_prefs_save(&prefs) != noErr) {
        strcpy(g_problem, "The folder was chosen but could not be remembered.");
        return -1;
    }
    if (!toolchain || prefs.toolchain_qualified) g_problem[0] = '\0';
    InvalWindowRect(g_owner, toolchain ? &g_r.toolchain_status
                                      : &g_r.projects_path);
    return 1;
}

static Boolean development_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    (void)event;
    if (!g_visible || FindControl(local, g_owner, &control) == 0) return false;
    if (control == g_projects_choose || control == g_toolchain_register) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            choose_root(control == g_toolchain_register);
        }
        return true;
    }
    return control == g_cancel;
}

static void development_activate(Boolean active)
{
    ControlRef controls[] = { g_projects_choose, g_toolchain_register };
    int i;
    for (i = 0; i < 2; ++i) {
        if (controls[i] == NULL) continue;
        if (active) ActivateControl(controls[i]); else DeactivateControl(controls[i]);
    }
}

static void development_status(char *out, long cap)
{
    if (g_problem[0]) {
        strncpy(out, g_problem, (size_t)cap - 1);
        out[cap - 1] = '\0';
    } else {
        strncpy(out, "Toolchains are human-registered; builds are headless.",
                (size_t)cap - 1);
        out[cap - 1] = '\0';
    }
}

static const WorkshopModuleOps k_ops = {
    development_create, development_dispose, development_show,
    development_layout, development_draw, development_click, NULL,
    development_activate, NULL, development_status, NULL
};

const WorkshopModuleOps *development_module_ops(void) { return &k_ops; }
